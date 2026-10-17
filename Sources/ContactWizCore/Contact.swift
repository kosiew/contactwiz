import Foundation

public enum PhoneLabel: String, CaseIterable, Identifiable, Sendable {
    case mobile, work, home, fax, other

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum EmailLabel: String, CaseIterable, Identifiable, Sendable {
    case work, home, other

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct LabeledValue<Label: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var label: Label
    public var value: String

    public init(label: Label, value: String) {
        self.label = label
        self.value = value
    }
}

public struct Website: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var value: String

    public init(_ value: String) { self.value = value }
}

public struct PostalAddress: Hashable, Sendable {
    public var street = ""
    public var city = ""
    public var region = ""
    public var postalCode = ""
    public var country = ""

    public init(street: String = "", city: String = "", region: String = "", postalCode: String = "", country: String = "") {
        self.street = street
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.country = country
    }

    public var isEmpty: Bool {
        [street, city, region, postalCode, country].allSatisfy { $0.trimmed.isEmpty }
    }
}

public struct Contact: Hashable, Sendable {
    public var namePrefix = ""
    public var givenName = ""
    public var middleName = ""
    public var familyName = ""
    public var nameSuffix = ""
    public var organization = ""
    public var jobTitle = ""
    public var phones: [LabeledValue<PhoneLabel>] = []
    public var emails: [LabeledValue<EmailLabel>] = []
    public var websites: [Website] = []
    public var address = PostalAddress()
    public var note = ""

    public init() {}

    public var fullName: String {
        [namePrefix, givenName, middleName, familyName, nameSuffix]
            .map(\.trimmed)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Name shown for the contact: the person's name, else company, else first email.
    public var displayName: String {
        if !fullName.isEmpty { return fullName }
        if !organization.trimmed.isEmpty { return organization.trimmed }
        if let email = emails.first(where: { !$0.value.trimmed.isEmpty }) { return email.value.trimmed }
        return "New Contact"
    }

    public var isEmpty: Bool { self == Contact() || (fullName.isEmpty && organization.trimmed.isEmpty && phones.isEmpty && emails.isEmpty) }

    public var suggestedFileName: String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = displayName.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "contact" : cleaned
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
