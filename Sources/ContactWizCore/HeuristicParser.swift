import Foundation
import NaturalLanguage

/// Rule-based extraction from OCR lines: data detectors for phones, links and
/// addresses, NaturalLanguage name tagging, and keyword heuristics for name,
/// title and organization. Works everywhere; also used to backfill what the
/// language model misses.
public enum HeuristicParser {
    public static func parse(_ recognized: [RecognizedLine]) -> Contact {
        let lines = recognized
            .map { line -> RecognizedLine in
                var line = line
                line.text = line.text.trimmed
                return line
            }
            .filter { !$0.text.isEmpty }
        let texts = lines.map(\.text)

        var contact = Contact()
        var consumed = Set<Int>()

        extractEmails(texts, into: &contact, consumed: &consumed)
        extractPhonesAndLinks(texts, into: &contact, consumed: &consumed)
        extractAddress(texts, into: &contact, consumed: &consumed)
        extractPeopleAndCompany(lines, into: &contact, consumed: &consumed)

        if contact.organization.isEmpty, let domain = workEmailDomain(contact) {
            contact.organization = organizationName(fromDomain: domain)
        }
        if contact.fullName.isEmpty, let email = contact.emails.first?.value {
            applyName(nameFromEmail(email) ?? "", to: &contact)
        }
        if contact.phones.count > 0, !contact.organization.isEmpty {
            // Unlabeled numbers on a business card are most often work lines.
            contact.phones = contact.phones.map { phone in
                var phone = phone
                if phone.label == .other { phone.label = .work }
                return phone
            }
        } else {
            contact.phones = contact.phones.map { phone in
                var phone = phone
                if phone.label == .other { phone.label = .mobile }
                return phone
            }
        }
        return contact
    }

    public static func parse(text: String) -> Contact {
        parse(text.components(separatedBy: .newlines).map { RecognizedLine(text: $0) })
    }

    // MARK: - Emails, phones, links

    private static let emailRegex = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])

    static let freeEmailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yahoo.com", "ymail.com", "hotmail.com", "outlook.com", "live.com",
        "msn.com", "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "gmx.com",
        "mail.com", "yandex.com", "qq.com", "163.com", "126.com", "zoho.com",
    ]

    private static func extractEmails(_ texts: [String], into contact: inout Contact, consumed: inout Set<Int>) {
        for (index, text) in texts.enumerated() {
            for email in matches(emailRegex, in: text) {
                let value = email.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                guard !contact.emails.contains(where: { $0.value.caseInsensitiveCompare(value) == .orderedSame }) else { continue }
                let domain = value.split(separator: "@").last.map { $0.lowercased() } ?? ""
                contact.emails.append(.init(label: freeEmailDomains.contains(domain) ? .home : .work, value: value))
                consumed.insert(index)
            }
        }
    }

    private static let linkAndPhoneDetector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.link.rawValue)

    private static func extractPhonesAndLinks(_ texts: [String], into contact: inout Contact, consumed: inout Set<Int>) {
        for (index, text) in texts.enumerated() {
            let ns = text as NSString
            let results = linkAndPhoneDetector.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for (position, result) in results.enumerated() {
                switch result.resultType {
                case .phoneNumber:
                    guard let number = result.phoneNumber, digits(number).count >= 7 else { continue }
                    guard !contact.phones.contains(where: { digits($0.value) == digits(number) }) else { continue }
                    let previousEnd = position > 0 ? NSMaxRange(results[position - 1].range) : 0
                    let nextStart = position + 1 < results.count ? results[position + 1].range.location : ns.length
                    let before = ns.substring(with: NSRange(location: previousEnd, length: result.range.location - previousEnd))
                    let after = ns.substring(with: NSRange(location: NSMaxRange(result.range), length: nextStart - NSMaxRange(result.range)))
                    let label = phoneLabel(context: before) ?? phoneLabel(context: after) ?? .other
                    contact.phones.append(.init(label: label, value: number.trimmed))
                    consumed.insert(index)
                case .link:
                    guard let url = result.url, let scheme = url.scheme?.lowercased(),
                          scheme == "http" || scheme == "https" else { continue }
                    let shown = ns.substring(with: result.range)
                    guard !contact.websites.contains(where: { $0.value.caseInsensitiveCompare(shown) == .orderedSame }) else { continue }
                    contact.websites.append(Website(shown))
                    consumed.insert(index)
                default:
                    continue
                }
            }
        }
    }

    private static let phoneLabelPatterns: [(PhoneLabel, NSRegularExpression)] = ([
        (.fax, #"\bfax\b|(^|[^a-z])f\s*[:.)]"#),
        (.mobile, #"\b(mobile|mob|cell|cellular|handphone|hp|h/p|whatsapp|wa)\b|(^|[^a-z])m\s*[:.)]|\(m\)"#),
        (.home, #"\bhome\b|(^|[^a-z])h\s*[:.)]"#),
        (.work, #"\b(office|tel|telephone|phone|work|direct|dir|main|switchboard|ext)\b|(^|[^a-z])[todpw]\s*[:.)]"#),
    ] as [(PhoneLabel, String)]).map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: [.caseInsensitive])) }

    static func phoneLabel(context: String) -> PhoneLabel? {
        let text = context.trimmed
        guard !text.isEmpty else { return nil }
        // A lone letter such as "M  +65 9123 4567" or "F. 555 0199".
        let letters = text.lowercased().filter(\.isLetter)
        if letters.count == 1, text.count <= 3 {
            switch letters {
            case "m": return .mobile
            case "f": return .fax
            case "h": return .home
            case "t", "o", "d", "p", "w": return .work
            default: break
            }
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return phoneLabelPatterns.first { $0.1.firstMatch(in: text, range: range) != nil }?.0
    }

    // MARK: - Address

    private static let addressDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue)

    private static let streetRegex = try! NSRegularExpression(
        pattern: #"\d.*\b(street|st|road|rd|avenue|ave|boulevard|blvd|lane|ln|drive|dr|way|place|pl|court|ct|suite|ste|floor|fl|level|unit|building|bldg|tower|plaza|highway|hwy|jalan|jln|lorong)\b"#,
        options: [.caseInsensitive])

    private static func extractAddress(_ texts: [String], into contact: inout Contact, consumed: inout Set<Int>) {
        // Only lines not already used, so phone/email lines don't confuse the detector.
        let candidates = texts.indices.filter { !consumed.contains($0) }
        let joined = candidates.map { texts[$0] }.joined(separator: "\n")
        let ns = joined as NSString

        if let match = addressDetector.firstMatch(in: joined, range: NSRange(location: 0, length: ns.length)),
           let parts = match.addressComponents {
            contact.address = PostalAddress(
                street: parts[.street] ?? "",
                city: parts[.city] ?? "",
                region: parts[.state] ?? "",
                postalCode: parts[.zip] ?? "",
                country: parts[.country] ?? "")
            var offset = 0
            for index in candidates {
                let length = (texts[index] as NSString).length
                if NSIntersectionRange(NSRange(location: offset, length: length), match.range).length > 0 {
                    consumed.insert(index)
                }
                offset += length + 1
            }
            return
        }

        // Fallback: a line that looks like a street, plus the following line as city/postcode.
        for (position, index) in candidates.enumerated() {
            let text = texts[index]
            guard streetRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil else { continue }
            contact.address.street = text
            consumed.insert(index)
            if position + 1 < candidates.count {
                let next = candidates[position + 1]
                if texts[next].range(of: #"\b\d{4,6}\b"#, options: .regularExpression) != nil {
                    contact.address.city = texts[next]
                    consumed.insert(next)
                }
            }
            return
        }
    }

    // MARK: - Name, title, organization

    private static let titleRegex = try! NSRegularExpression(
        pattern: #"\b(ceo|cto|cfo|coo|cmo|cio|cso|cpo|vp|svp|evp|avp|md|gm|founder|co-founder|cofounder|president|director|manager|engineer|developer|designer|consultant|officer|head|lead|partner|executive|specialist|analyst|architect|associate|coordinator|assistant|advisor|adviser|attorney|lawyer|counsel|owner|principal|chairman|chairwoman|chairperson|secretary|administrator|representative|agent|scientist|professor|lecturer|chief|supervisor|strategist|producer|editor|writer|photographer|realtor|broker|accountant|auditor|technician|nurse|physician|surgeon|dentist|therapist|pharmacist|recruiter|intern|trainer|coach|teacher|planner|programmer|sales|marketing|operations|vice|senior|junior)\b"#,
        options: [.caseInsensitive])

    private static let strongOrgRegex = try! NSRegularExpression(
        pattern: #"\b(inc|incorporated|llc|llp|ltd|limited|corp|corporation|company|gmbh|plc|pty|pte|bhd|s\.a|s\.r\.l|b\.v)\b|\bco\.(\s|$)"#,
        options: [.caseInsensitive])

    private static let weakOrgRegex = try! NSRegularExpression(
        pattern: #"\b(group|holdings|technologies|technology|tech|solutions|systems|labs|studio|studios|partners|associates|ventures|capital|consulting|agency|bank|university|college|institute|school|hospital|clinic|foundation|international|global|industries|enterprises|services|media|software|networks|realty|properties|firm)\b"#,
        options: [.caseInsensitive])

    private static func extractPeopleAndCompany(_ lines: [RecognizedLine], into contact: inout Contact, consumed: inout Set<Int>) {
        let remaining = lines.indices.filter { !consumed.contains($0) }
        let maxHeight = lines.map(\.height).max() ?? 0

        // Organization: legal suffixes first, then industry words, then NL tagging.
        let orgIndex = remaining.first { has(strongOrgRegex, lines[$0].text) }
            ?? remaining.first { has(weakOrgRegex, lines[$0].text) && !has(titleRegex, lines[$0].text) }
            ?? remaining.first { coverage(of: .organizationName, in: lines[$0].text) >= 0.6 }
        if let orgIndex {
            let text = lines[orgIndex].text
            if has(titleRegex, text), let (title, org) = splitTitleAndOrg(text) {
                contact.jobTitle = title
                contact.organization = org
            } else {
                contact.organization = text
            }
            consumed.insert(orgIndex)
        }

        // Name: best-scoring line that looks like a person's name.
        var best: (index: Int, score: Double)?
        for (position, index) in remaining.enumerated() where !consumed.contains(index) {
            let text = lines[index].text
            let personCoverage = coverage(of: .personalName, in: text)
            let heuristic = looksLikeName(text, allowSingleWord: personCoverage >= 0.6)
            guard heuristic else { continue }
            var score = 2.0
            if personCoverage >= 0.6 { score += 3 }
            if has(titleRegex, text) { score -= 2.5 }
            if maxHeight > 0 { score += 2 * lines[index].height / maxHeight }
            score -= Double(position) * 0.1
            if best == nil || score > best!.score { best = (index, score) }
        }
        if let best, best.score > 1 {
            applyName(lines[best.index].text, to: &contact)
            consumed.insert(best.index)
        }

        // Title: first remaining line with a job keyword.
        if contact.jobTitle.isEmpty,
           let titleIndex = remaining.first(where: { !consumed.contains($0) && has(titleRegex, lines[$0].text) && !lines[$0].text.contains("@") }) {
            let text = lines[titleIndex].text
            if contact.organization.isEmpty, let (title, org) = splitTitleAndOrg(text) {
                contact.jobTitle = title
                contact.organization = org
            } else {
                contact.jobTitle = text
            }
            consumed.insert(titleIndex)
        }
    }

    private static func splitTitleAndOrg(_ text: String) -> (String, String)? {
        for separator in [" at ", " @ ", ", ", " | ", " · ", " • ", " - "] {
            let parts = text.components(separatedBy: separator)
            guard parts.count == 2 else { continue }
            let (a, b) = (parts[0].trimmed, parts[1].trimmed)
            if has(titleRegex, a), has(strongOrgRegex, b) || has(weakOrgRegex, b) { return (a, b) }
        }
        return nil
    }

    static let namePrefixes: Set<String> = ["mr", "mrs", "ms", "miss", "mx", "dr", "prof", "sir", "madam", "mdm", "dato", "datuk", "tan sri"]
    static let nameSuffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "phd", "md", "mba", "cpa", "cfa", "esq", "pe", "pmp", "dds", "rn"]

    static func looksLikeName(_ text: String, allowSingleWord: Bool) -> Bool {
        guard text.count <= 40, !text.contains("@"), text.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        let core = text.components(separatedBy: ",").first ?? text
        let words = core.split(separator: " ").map(String.init).filter { word in
            let key = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !namePrefixes.contains(key) && !nameSuffixes.contains(key)
        }
        guard (allowSingleWord ? 1 : 2)...4 ~= words.count else { return false }
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: ".'’-"))
        return words.allSatisfy { word in
            guard let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return false }
            return word.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// Splits a display name into vCard name parts, handling "Last, First", honorifics and credentials.
    static func applyName(_ raw: String, to contact: inout Contact) {
        var text = raw.trimmed
        guard !text.isEmpty else { return }
        if text == text.uppercased() { text = text.capitalized }

        var suffixes: [String] = []
        let commaParts = text.components(separatedBy: ",").map(\.trimmed).filter { !$0.isEmpty }
        if commaParts.count > 1 {
            let trailing = commaParts.dropFirst()
            if trailing.allSatisfy({ nameSuffixes.contains($0.lowercased().replacingOccurrences(of: ".", with: "")) }) {
                suffixes = Array(trailing)
                text = commaParts[0]
            } else if commaParts.count == 2 {
                text = commaParts[1] + " " + commaParts[0] // "Doe, Jane"
            }
        }

        var tokens = text.split(separator: " ").map(String.init)
        var prefixes: [String] = []
        while let first = tokens.first, tokens.count > 1,
              namePrefixes.contains(first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            prefixes.append(tokens.removeFirst())
        }
        while let last = tokens.last, tokens.count > 1,
              nameSuffixes.contains(last.lowercased().replacingOccurrences(of: ".", with: "")) {
            suffixes.insert(tokens.removeLast(), at: 0)
        }

        contact.namePrefix = prefixes.joined(separator: " ")
        contact.nameSuffix = suffixes.joined(separator: ", ")
        switch tokens.count {
        case 0: break
        case 1: contact.givenName = tokens[0]
        default:
            contact.givenName = tokens[0]
            contact.familyName = tokens[tokens.count - 1]
            contact.middleName = tokens[1..<(tokens.count - 1)].joined(separator: " ")
        }
    }

    static func nameFromEmail(_ email: String) -> String? {
        guard let local = email.split(separator: "@").first else { return nil }
        let parts = local.split(whereSeparator: { ".-_".contains($0) }).map(String.init)
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0.count > 1 && $0.allSatisfy(\.isLetter) }) else { return nil }
        return parts.map(\.capitalized).joined(separator: " ")
    }

    private static func workEmailDomain(_ contact: Contact) -> String? {
        contact.emails.lazy
            .compactMap { $0.value.split(separator: "@").last.map { $0.lowercased() } }
            .first { !freeEmailDomains.contains($0) }
    }

    static func organizationName(fromDomain domain: String) -> String {
        var labels = domain.split(separator: ".").map(String.init)
        if labels.first == "www" || labels.first == "mail" { labels.removeFirst() }
        guard labels.count >= 2 else { return labels.first?.capitalized ?? "" }
        let secondLevel: Set<String> = ["co", "com", "net", "org", "ac", "gov", "edu"]
        let name = labels.count >= 3 && secondLevel.contains(labels[labels.count - 2])
            ? labels[labels.count - 3]
            : labels[labels.count - 2]
        return name.replacingOccurrences(of: "-", with: " ").capitalized
    }

    // MARK: - Helpers

    /// Fraction of the line's letters tagged with `tag` by NaturalLanguage.
    private static func coverage(of tag: NLTag, in text: String) -> Double {
        let input = text == text.uppercased() ? text.capitalized : text
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = input
        var tagged = 0
        tagger.enumerateTags(in: input.startIndex..<input.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { found, range in
            if found == tag { tagged += input[range].filter(\.isLetter).count }
            return true
        }
        let letters = input.filter(\.isLetter).count
        return letters == 0 ? 0 : Double(tagged) / Double(letters)
    }

    private static func has(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func digits(_ text: String) -> String { text.filter(\.isNumber) }
}
