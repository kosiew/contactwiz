import Foundation

/// Serializes a `Contact` as vCard 3.0, the format Google Contacts' "Import" accepts.
public enum VCardWriter {
    public static func vCard(for contact: Contact) -> String {
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]

        let nameParts = [contact.familyName, contact.givenName, contact.middleName, contact.namePrefix, contact.nameSuffix]
        lines.append("N:" + nameParts.map { escape($0.trimmed) }.joined(separator: ";"))
        lines.append("FN:" + escape(contact.displayName))

        if !contact.organization.trimmed.isEmpty {
            lines.append("ORG:" + escape(contact.organization.trimmed))
        }
        if !contact.jobTitle.trimmed.isEmpty {
            lines.append("TITLE:" + escape(contact.jobTitle.trimmed))
        }
        for phone in contact.phones where !phone.value.trimmed.isEmpty {
            lines.append("TEL;TYPE=\(phoneType(phone.label)):" + escape(phone.value.trimmed))
        }
        for email in contact.emails where !email.value.trimmed.isEmpty {
            lines.append("EMAIL;TYPE=\(emailType(email.label)):" + escape(email.value.trimmed))
        }
        let address = contact.address
        if !address.isEmpty {
            let type = contact.organization.trimmed.isEmpty ? "HOME" : "WORK"
            let parts = ["", "", address.street, address.city, address.region, address.postalCode, address.country]
            lines.append("ADR;TYPE=\(type):" + parts.map { escape($0.trimmed) }.joined(separator: ";"))
        }
        for website in contact.websites where !website.value.trimmed.isEmpty {
            lines.append("URL:" + normalizedURL(website.value))
        }
        if !contact.note.trimmed.isEmpty {
            lines.append("NOTE:" + escape(contact.note.trimmed))
        }
        lines.append("END:VCARD")

        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func phoneType(_ label: PhoneLabel) -> String {
        switch label {
        case .mobile: "CELL"
        case .work: "WORK,VOICE"
        case .home: "HOME,VOICE"
        case .fax: "WORK,FAX"
        case .other: "VOICE"
        }
    }

    static func emailType(_ label: EmailLabel) -> String {
        switch label {
        case .work: "INTERNET,WORK"
        case .home: "INTERNET,HOME"
        case .other: "INTERNET"
        }
    }

    static func normalizedURL(_ raw: String) -> String {
        let value = raw.trimmed.replacingOccurrences(of: "\n", with: "")
        return value.contains("://") ? value : "https://" + value
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
    }

    /// Folds a content line so no physical line exceeds 75 octets (RFC 2425 §5.8.1),
    /// never splitting a UTF-8 character.
    static func fold(_ line: String) -> String {
        var result = ""
        var current = ""
        var currentBytes = 0
        var limit = 75
        for character in line {
            let bytes = String(character).utf8.count
            if currentBytes + bytes > limit {
                result += current + "\r\n "
                current = ""
                currentBytes = 0
                limit = 74 // the leading space counts toward the 75
            }
            current.append(character)
            currentBytes += bytes
        }
        return result + current
    }
}
