import Foundation
import Network

/// A one-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect
/// (Google's recommended flow for desktop apps).
final class LoopbackServer: @unchecked Sendable {
    enum Failure: LocalizedError {
        case couldNotStart
        case timedOut

        var errorDescription: String? {
            switch self {
            case .couldNotStart: "Could not start the local sign-in listener."
            case .timedOut: "Google sign-in timed out."
            }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "contactwiz.loopback")
    private var redirectContinuation: CheckedContinuation<[String: String], Error>?
    private var pendingResult: Result<[String: String], Error>?
    private var finished = false
    private var startContinuationResumed = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the port the OS assigned.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self, listener] state in
                // Runs on `queue`, which confines `startContinuationResumed`.
                guard let self, !self.startContinuationResumed else { return }
                switch state {
                case .ready:
                    self.startContinuationResumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed, .cancelled:
                    self.startContinuationResumed = true
                    continuation.resume(throwing: Failure.couldNotStart)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser to hit the redirect URI; returns its query parameters.
    func waitForRedirect(timeout: TimeInterval = 300) async throws -> [String: String] {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(Failure.timedOut))
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pending = self.pendingResult {
                    self.pendingResult = nil
                    continuation.resume(with: pending)
                } else {
                    self.redirectContinuation = continuation
                }
            }
        }
    }

    func stop() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let parameters = Self.queryParameters(fromRequest: request)
            let isRedirect = parameters["code"] != nil || parameters["error"] != nil

            let body = isRedirect
                ? "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:80px\"><h2>ContactWiz is signed in.</h2><p>You can close this tab and return to the app.</p></body></html>"
                : "Not found"
            let status = isRedirect ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

            if isRedirect { self.finish(.success(parameters)) }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !finished else { return }
        finished = true
        listener.cancel()
        if let continuation = redirectContinuation {
            redirectContinuation = nil
            continuation.resume(with: result)
        } else {
            pendingResult = result
        }
    }

    static func queryParameters(fromRequest request: String) -> [String: String] {
        // "GET /?code=...&state=... HTTP/1.1"
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }
}
