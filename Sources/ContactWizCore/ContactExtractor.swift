import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct ExtractionResult: Sendable {
    public enum Method: String, Sendable {
        case foundationModel = "Apple Intelligence"
        case heuristic = "Built-in rules"
    }

    public var contact: Contact
    public var method: Method
    /// Why the on-device model was not used, when it wasn't.
    public var fallbackReason: String?
}

/// Turns OCR lines into a `Contact`, preferring Apple's on-device Foundation
/// Model and falling back to `HeuristicParser`. Model output is checked
/// against the OCR text so hallucinated phone numbers or emails are dropped.
public enum ContactExtractor {
    public static func extract(from lines: [RecognizedLine], useFoundationModel: Bool = true) async -> ExtractionResult {
        let heuristic = HeuristicParser.parse(lines)
        guard useFoundationModel else {
            return ExtractionResult(contact: heuristic, method: .heuristic, fallbackReason: "Apple Intelligence turned off")
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let reason = FoundationModelExtractor.unavailableReason {
                return ExtractionResult(contact: heuristic, method: .heuristic, fallbackReason: reason)
            }
            do {
                let generated = try await FoundationModelExtractor.extract(lines)
                let merged = merge(model: generated, heuristic: heuristic, sourceText: lines.map(\.text).joined(separator: "\n"))
                return ExtractionResult(contact: merged, method: .foundationModel, fallbackReason: nil)
            } catch {
                return ExtractionResult(contact: heuristic, method: .heuristic, fallbackReason: error.localizedDescription)
            }
        }
        #endif
        return ExtractionResult(contact: heuristic, method: .heuristic, fallbackReason: "Requires macOS 26 or later")
    }

    /// Loads the on-device model ahead of the first extraction (the first load can take ~20s).
    public static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), FoundationModelExtractor.unavailableReason == nil {
            LanguageModelSession(instructions: FoundationModelExtractor.instructions).prewarm()
        }
        #endif
    }

    public static var isFoundationModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return FoundationModelExtractor.unavailableReason == nil }
        #endif
        return false
    }

    /// Model values win when they are grounded in the OCR text; heuristics fill gaps.
    static func merge(model: Contact, heuristic: Contact, sourceText: String) -> Contact {
        let haystack = sourceText.lowercased()
        let haystackDigits = HeuristicParser.digits(sourceText)
        func grounded(_ value: String) -> Bool {
            let words = value.lowercased().split(separator: " ")
                .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
                .filter { $0.count > 1 }
            return !words.isEmpty && words.allSatisfy { haystack.contains($0) }
        }
        func pick(_ modelValue: String, _ fallback: String) -> String {
            grounded(modelValue) ? modelValue.trimmed : fallback
        }

        var result = Contact()
        let modelNameGrounded = grounded(model.fullName)
        let nameSource = modelNameGrounded ? model : heuristic
        result.namePrefix = nameSource.namePrefix
        result.givenName = nameSource.givenName
        result.middleName = nameSource.middleName
        result.familyName = nameSource.familyName
        result.nameSuffix = nameSource.nameSuffix
        result.organization = pick(model.organization, heuristic.organization)
        result.jobTitle = pick(model.jobTitle, heuristic.jobTitle)

        result.phones = model.phones.compactMap { phone in
            let digits = HeuristicParser.digits(phone.value)
            guard digits.count >= 6, haystackDigits.contains(digits) else { return nil }
            // Prefer the data detector's cleaner text ("+65 9123 4567", not "M +65 9123 4567").
            var phone = phone
            phone.value = heuristic.phones.first { HeuristicParser.digits($0.value) == digits }?.value
                ?? phone.value.replacingOccurrences(of: #"^[^+\d(]+"#, with: "", options: .regularExpression)
            return phone
        }
        for phone in heuristic.phones where !result.phones.contains(where: { HeuristicParser.digits($0.value) == HeuristicParser.digits(phone.value) }) {
            result.phones.append(phone)
        }

        result.emails = model.emails.filter { haystack.contains($0.value.lowercased().trimmed) && $0.value.contains("@") }
        for email in heuristic.emails where !result.emails.contains(where: { $0.value.caseInsensitiveCompare(email.value) == .orderedSame }) {
            result.emails.append(email)
        }

        result.websites = model.websites.filter { haystack.contains(strippedScheme($0.value).lowercased()) }
        for site in heuristic.websites where !result.websites.contains(where: { strippedScheme($0.value).caseInsensitiveCompare(strippedScheme(site.value)) == .orderedSame }) {
            result.websites.append(site)
        }

        result.address = grounded(model.address.street) || grounded(model.address.city) ? model.address : heuristic.address
        // The model sometimes repeats the postcode or city in the region field.
        let region = result.address.region.trimmed
        if region.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" })
            || region.caseInsensitiveCompare(result.address.city.trimmed) == .orderedSame
            || region.caseInsensitiveCompare(result.address.country.trimmed) == .orderedSame {
            result.address.region = ""
        }
        return result
    }

    private static func strippedScheme(_ url: String) -> String {
        url.trimmed.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

#if canImport(FoundationModels)
/// Guided generation against a runtime schema. (`DynamicGenerationSchema`
/// rather than `@Generable` so the package also builds with the Command Line
/// Tools, which don't ship the FoundationModels macro plugin.)
@available(macOS 26.0, *)
enum FoundationModelExtractor {
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is turned off in System Settings"
        case .unavailable(.modelNotReady): "The Apple Intelligence model is still downloading"
        case .unavailable: "Apple Intelligence is unavailable"
        }
    }

    static let instructions = """
        You extract contact details from text recognized (OCR) in a screenshot, such as a business card, \
        email signature, website, or social profile. Copy values exactly as they appear in the text. \
        Never invent or guess information that is not present; use empty strings and empty lists instead. \
        The contact is the single person (or business, if no person is named) the text describes. \
        Do not mistake a company, product, slogan, or job title for the person's name.
        """

    private static let stringFields: [(name: String, description: String)] = [
        ("namePrefix", "Honorific such as Dr., Mr., Ms.; empty if none"),
        ("givenName", "The person's first (given) name; empty if no person is named"),
        ("middleName", "Middle name(s) or initials; empty if none"),
        ("familyName", "The person's last (family) name"),
        ("nameSuffix", "Name suffix or credentials such as Jr., PhD, MBA; empty if none"),
        ("organization", "Company or organization name; empty if none"),
        ("jobTitle", "Job title or role; empty if none"),
        ("street", "Street address line(s), including building, suite or unit"),
        ("city", "City"),
        ("region", "State, province or region"),
        ("postalCode", "Postal or ZIP code"),
        ("country", "Country"),
    ]

    static func schema() throws -> GenerationSchema {
        let text = DynamicGenerationSchema(type: String.self)
        let phone = DynamicGenerationSchema(name: "Phone", properties: [
            .init(name: "number", description: "Phone number exactly as printed, including country code", schema: text),
            .init(name: "kind",
                  description: "mobile for M/Mobile/Cell/HP labels, fax for F/Fax, work for T/Tel/Office/Direct, home for H/Home, otherwise other",
                  schema: DynamicGenerationSchema(name: "PhoneKind", anyOf: PhoneLabel.allCases.map(\.rawValue))),
        ])
        var properties = stringFields.map { DynamicGenerationSchema.Property(name: $0.name, description: $0.description, schema: text) }
        properties += [
            .init(name: "phones", description: "Every phone number shown", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "Phone"))),
            .init(name: "emails", description: "Every email address shown", schema: DynamicGenerationSchema(arrayOf: text)),
            .init(name: "websites", description: "Websites and profile URLs shown, excluding email addresses",
                  schema: DynamicGenerationSchema(arrayOf: text)),
        ]
        return try GenerationSchema(root: DynamicGenerationSchema(name: "Contact", properties: properties), dependencies: [phone])
    }

    static func extract(_ lines: [RecognizedLine]) async throws -> Contact {
        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Recognized text, one line per row:\n\n" + lines.map(\.text).joined(separator: "\n")
        let response = try await session.respond(
            to: prompt,
            schema: try schema(),
            options: GenerationOptions(samplingMode: .greedy))
        return try contact(from: response.content)
    }

    static func contact(from content: GeneratedContent) throws -> Contact {
        func string(_ key: String) -> String { ((try? content.value(String.self, forProperty: key)) ?? "").trimmed }
        func strings(_ key: String) -> [String] {
            ((try? content.value([String].self, forProperty: key)) ?? []).map(\.trimmed).filter { !$0.isEmpty }
        }

        var contact = Contact()
        contact.namePrefix = string("namePrefix")
        contact.givenName = string("givenName")
        contact.middleName = string("middleName")
        contact.familyName = string("familyName")
        contact.nameSuffix = string("nameSuffix")
        contact.organization = string("organization")
        contact.jobTitle = string("jobTitle")
        contact.phones = ((try? content.value([GeneratedContent].self, forProperty: "phones")) ?? []).compactMap { phone in
            guard let number = try? phone.value(String.self, forProperty: "number"), !number.trimmed.isEmpty else { return nil }
            let kind = (try? phone.value(String.self, forProperty: "kind")).flatMap(PhoneLabel.init(rawValue:)) ?? .other
            return LabeledValue(label: kind, value: number.trimmed)
        }
        contact.emails = strings("emails").map { email in
            let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
            return LabeledValue(label: HeuristicParser.freeEmailDomains.contains(domain) ? .home : .work, value: email)
        }
        contact.websites = strings("websites").filter { !$0.contains("@") }.map(Website.init)
        contact.address = PostalAddress(
            street: string("street"), city: string("city"), region: string("region"),
            postalCode: string("postalCode"), country: string("country"))
        return contact
    }
}
#endif
