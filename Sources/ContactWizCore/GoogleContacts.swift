import CryptoKit
import Foundation

/// Signs in to Google (OAuth 2.0 for desktop apps: loopback redirect + PKCE)
/// and creates contacts with the People API.
///
/// Needs a "Desktop app" OAuth client from Google Cloud Console with the
/// People API enabled; see README.
public final class GoogleContacts: @unchecked Sendable {
    public enum Failure: LocalizedError {
        case missingClientCredentials
        case notSignedIn
        case authorizationDenied(String)
        case stateMismatch
        case http(Int, String)
        case invalidClientFile(String)

        public var errorDescription: String? {
            switch self {
            case .missingClientCredentials: "Add your Google OAuth client ID and secret in Settings first."
            case .notSignedIn: "Sign in to Google first."
            case .authorizationDenied(let reason): "Google sign-in was not completed (\(reason))."
            case .stateMismatch: "Google sign-in response did not match the request."
            case .http(let status, let body): "Google returned HTTP \(status): \(body)"
            case .invalidClientFile(let reason): reason
            }
        }
    }

    public struct CreatedContact: Sendable {
        /// e.g. "people/c1234567890"
        public var resourceName: String
        /// Opens the contact in Google Contacts, in the signed-in account.
        public var webURL: URL
    }

    private enum Key {
        static let clientID = "google.clientID"
        static let clientSecret = "google.clientSecret"
        static let refreshToken = "google.refreshToken"
        static let accountEmail = "google.accountEmail"
    }

    private static let scopes = "https://www.googleapis.com/auth/contacts openid email"

    public static let shared = GoogleContacts()

    private let lock = NSLock()
    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var activeServer: LoopbackServer?

    public init() {}

    // MARK: Configuration

    public var clientID: String {
        get { UserDefaults.standard.string(forKey: Key.clientID) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmed, forKey: Key.clientID) }
    }

    public var clientSecret: String {
        get { Keychain.read(Key.clientSecret) ?? "" }
        set { newValue.trimmed.isEmpty ? Keychain.delete(Key.clientSecret) : Keychain.write(newValue.trimmed, for: Key.clientSecret) }
    }

    public var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    public struct ClientCredentials: Equatable, Sendable {
        public var clientID: String
        public var clientSecret: String
    }

    /// Parses the `client_secret_….json` file Google Cloud Console offers
    /// for download after creating an OAuth client.
    public static func parseClientSecretFile(_ data: Data) throws -> ClientCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidClientFile("That file isn't a Google OAuth client JSON file.")
        }
        if json["web"] != nil {
            throw Failure.invalidClientFile("That's a “Web application” client. Create a “Desktop app” client instead.")
        }
        guard let installed = json["installed"] as? [String: Any],
              let id = (installed["client_id"] as? String)?.trimmed, !id.isEmpty,
              let secret = (installed["client_secret"] as? String)?.trimmed, !secret.isEmpty
        else { throw Failure.invalidClientFile("That file doesn't contain a Desktop app client ID and secret.") }
        return ClientCredentials(clientID: id, clientSecret: secret)
    }
    public var isSignedIn: Bool { Keychain.read(Key.refreshToken) != nil }
    public var accountEmail: String? { UserDefaults.standard.string(forKey: Key.accountEmail) }

    // MARK: Sign in / out

    /// Runs the browser sign-in. `openURL` opens the consent page in the user's browser.
    public func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws {
        guard isConfigured else { throw Failure.missingClientCredentials }

        let verifier = Self.randomURLSafeString(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafeString(byteCount: 16)

        let server = try LoopbackServer()
        lock.withLock { activeServer = server }
        defer { lock.withLock { activeServer = nil } }

        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
        ]
        openURL(components.url!)

        let parameters = try await server.waitForRedirect()
        if let error = parameters["error"] { throw Failure.authorizationDenied(error) }
        guard parameters["state"] == state else { throw Failure.stateMismatch }
        guard let code = parameters["code"] else { throw Failure.authorizationDenied("no code") }

        let token = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ])
        if let refresh = token.refresh_token { Keychain.write(refresh, for: Key.refreshToken) }
        if let email = token.id_token.flatMap(Self.email(fromIDToken:)) {
            UserDefaults.standard.set(email, forKey: Key.accountEmail)
        }
    }

    public func cancelSignIn() {
        lock.withLock { activeServer }?.stop()
    }

    public func signOut() {
        if let refresh = Keychain.read(Key.refreshToken) {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncoded(["token": refresh])
            URLSession.shared.dataTask(with: request).resume()
        }
        Keychain.delete(Key.refreshToken)
        UserDefaults.standard.removeObject(forKey: Key.accountEmail)
        lock.withLock {
            accessToken = nil
            accessTokenExpiry = .distantPast
        }
    }

    // MARK: Contacts

    public func createContact(_ contact: Contact) async throws -> CreatedContact {
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: "https://people.googleapis.com/v1/people:createContact?personFields=names")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.peopleAPIBody(for: contact))

        let data = try await send(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resourceName = json["resourceName"] as? String
        else { throw Failure.http(200, "Unexpected response from People API") }
        return CreatedContact(resourceName: resourceName, webURL: webURL(forResourceName: resourceName))
    }

    public func webURL(forResourceName resourceName: String) -> URL {
        let id = resourceName.replacingOccurrences(of: "people/", with: "")
        var components = URLComponents(string: "https://contacts.google.com/person/\(id)")!
        if let email = accountEmail { components.queryItems = [.init(name: "authuser", value: email)] }
        return components.url!
    }

    /// People API `Person` JSON for a contact.
    public static func peopleAPIBody(for contact: Contact) -> [String: Any] {
        func nonEmpty(_ dict: [String: String]) -> [String: String] { dict.filter { !$0.value.trimmed.isEmpty } }
        var body: [String: Any] = [:]

        let name = nonEmpty([
            "honorificPrefix": contact.namePrefix, "givenName": contact.givenName,
            "middleName": contact.middleName, "familyName": contact.familyName,
            "honorificSuffix": contact.nameSuffix,
        ])
        if !name.isEmpty { body["names"] = [name] }

        let organization = nonEmpty(["name": contact.organization, "title": contact.jobTitle])
        if !organization.isEmpty { body["organizations"] = [organization] }

        let phones = contact.phones.filter { !$0.value.trimmed.isEmpty }.map { phone -> [String: String] in
            let type: String = switch phone.label {
            case .mobile: "mobile"
            case .work: "work"
            case .home: "home"
            case .fax: "workFax"
            case .other: "other"
            }
            return ["value": phone.value.trimmed, "type": type]
        }
        if !phones.isEmpty { body["phoneNumbers"] = phones }

        let emails = contact.emails.filter { !$0.value.trimmed.isEmpty }.map {
            ["value": $0.value.trimmed, "type": $0.label.rawValue]
        }
        if !emails.isEmpty { body["emailAddresses"] = emails }

        let urls = contact.websites.filter { !$0.value.trimmed.isEmpty }.map {
            ["value": VCardWriter.normalizedURL($0.value), "type": "work"]
        }
        if !urls.isEmpty { body["urls"] = urls }

        if !contact.address.isEmpty {
            var address = nonEmpty([
                "streetAddress": contact.address.street, "city": contact.address.city,
                "region": contact.address.region, "postalCode": contact.address.postalCode,
                "country": contact.address.country,
            ])
            address["type"] = contact.organization.trimmed.isEmpty ? "home" : "work"
            body["addresses"] = [address]
        }

        if !contact.note.trimmed.isEmpty {
            body["biographies"] = [["value": contact.note.trimmed, "contentType": "TEXT_PLAIN"]]
        }
        return body
    }

    // MARK: Tokens

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Double
        var refresh_token: String?
        var id_token: String?
    }

    private func validAccessToken() async throws -> String {
        if let token = lock.withLock({ accessTokenExpiry > Date().addingTimeInterval(60) ? accessToken : nil }) {
            return token
        }
        guard isConfigured else { throw Failure.missingClientCredentials }
        guard let refresh = Keychain.read(Key.refreshToken) else { throw Failure.notSignedIn }
        do {
            let token = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh])
            return token.access_token
        } catch Failure.http(400, let body) where body.contains("invalid_grant") {
            // Revoked or expired (test-mode refresh tokens last 7 days).
            Keychain.delete(Key.refreshToken)
            throw Failure.notSignedIn
        }
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = fields
        all["client_id"] = clientID
        all["client_secret"] = clientSecret
        request.httpBody = Self.formEncoded(all)

        let token = try JSONDecoder().decode(TokenResponse.self, from: try await send(request))
        lock.withLock {
            accessToken = token.access_token
            accessTokenExpiry = Date().addingTimeInterval(token.expires_in)
        }
        return token
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: Helpers

    private static func formEncoded(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncoded
    }

    /// Reads the `email` claim. The token came straight from Google's token
    /// endpoint over TLS, so the signature isn't re-verified.
    static func email(fromIDToken token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["email"] as? String
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
