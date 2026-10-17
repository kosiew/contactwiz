// Plain-executable checks: the Command Line Tools ship neither XCTest nor
// the Swift Testing macro plugin. Run with `swift run contactwiz-checks`.
@testable import ContactWizCore
import Foundation

enum HeuristicParserTests {
    static func businessCard() {
        let contact = HeuristicParser.parse(text: """
            JANE A. DOE
            Senior Product Manager
            Acme Widgets Inc.
            M: +1 (415) 555-0134
            T: +1 415 555 0100
            Fax: +1 415 555 0199
            jane.doe@acmewidgets.com
            www.acmewidgets.com
            """)
        expect(contact.givenName == "Jane")
        expect(contact.middleName == "A.")
        expect(contact.familyName == "Doe")
        expect(contact.jobTitle == "Senior Product Manager")
        expect(contact.organization == "Acme Widgets Inc.")
        expect(contact.phones.map(\.label) == [.mobile, .work, .fax])
        expect(contact.emails.map(\.value) == ["jane.doe@acmewidgets.com"])
        expect(contact.emails.first?.label == .work)
        expect(contact.websites.map(\.value) == ["www.acmewidgets.com"])
    }

    static func titleAndCompanyOnOneLine() {
        let contact = HeuristicParser.parse(text: """
            Marcus Lee
            Software Engineer at Globex Technologies
            marcus@gmail.com
            """)
        expect(contact.givenName == "Marcus")
        expect(contact.familyName == "Lee")
        expect(contact.jobTitle == "Software Engineer")
        expect(contact.organization == "Globex Technologies")
        expect(contact.emails.first?.label == .home)
    }

    static func fallsBackToEmailForNameAndCompany() {
        let contact = HeuristicParser.parse(text: "Reach me: priya.sharma@initech.co.uk")
        expect(contact.givenName == "Priya")
        expect(contact.familyName == "Sharma")
        expect(contact.organization == "Initech")
    }

    static func namePartsWithHonorificsAndCredentials() {
        var contact = Contact()
        HeuristicParser.applyName("Dr. Emily Chen, PhD", to: &contact)
        expect(contact.namePrefix == "Dr.")
        expect(contact.givenName == "Emily")
        expect(contact.familyName == "Chen")
        expect(contact.nameSuffix == "PhD")

        contact = Contact()
        HeuristicParser.applyName("Smith, John", to: &contact)
        expect(contact.givenName == "John")
        expect(contact.familyName == "Smith")
    }
}

enum VCardWriterTests {
    static func writesEscapedCRLFCard() {
        var contact = Contact()
        contact.givenName = "Jane"
        contact.familyName = "Doe"
        contact.organization = "Acme, Inc; West"
        contact.phones = [.init(label: .mobile, value: "+1 415 555 0134")]
        contact.emails = [.init(label: .work, value: "jane@acme.com")]
        contact.websites = [Website("acme.com")]
        contact.note = "Met at\nWWDC"

        let card = VCardWriter.vCard(for: contact)
        expect(card.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0\r\n"))
        expect(card.hasSuffix("END:VCARD\r\n"))
        expect(card.contains("N:Doe;Jane;;;\r\n"))
        expect(card.contains("FN:Jane Doe\r\n"))
        expect(card.contains("ORG:Acme\\, Inc\\; West\r\n"))
        expect(card.contains("TEL;TYPE=CELL:+1 415 555 0134\r\n"))
        expect(card.contains("EMAIL;TYPE=INTERNET,WORK:jane@acme.com\r\n"))
        expect(card.contains("URL:https://acme.com\r\n"))
        expect(card.contains("NOTE:Met at\\nWWDC\r\n"))
    }

    static func foldsLongLinesWithoutSplittingCharacters() {
        let line = "NOTE:" + String(repeating: "é", count: 100)
        let folded = VCardWriter.fold(line)
        for physical in folded.components(separatedBy: "\r\n") {
            expect(physical.utf8.count <= 75)
        }
        expect(folded.replacingOccurrences(of: "\r\n ", with: "") == line)
    }
}

enum GoogleContactsTests {
    static func peopleAPIBody() {
        var contact = Contact()
        contact.givenName = "Jane"
        contact.familyName = "Doe"
        contact.jobTitle = "CTO"
        contact.phones = [.init(label: .fax, value: "123 4567")]
        let body = GoogleContacts.peopleAPIBody(for: contact)
        expect((body["names"] as? [[String: String]])?.first == ["givenName": "Jane", "familyName": "Doe"])
        expect((body["organizations"] as? [[String: String]])?.first == ["title": "CTO"])
        expect((body["phoneNumbers"] as? [[String: String]])?.first == ["value": "123 4567", "type": "workFax"])
        expect(body["addresses"] == nil)
    }

    static func parsesDesktopClientFile() {
        let file = #"{"installed":{"client_id":"123.apps.googleusercontent.com","client_secret":"GOCSPX-x","redirect_uris":["http://localhost"]}}"#
        let credentials = try? GoogleContacts.parseClientSecretFile(Data(file.utf8))
        expect(credentials == .init(clientID: "123.apps.googleusercontent.com", clientSecret: "GOCSPX-x"))
        expect((try? GoogleContacts.parseClientSecretFile(Data(#"{"web":{"client_id":"a","client_secret":"b"}}"#.utf8))) == nil)
    }

    static func emailFromIDToken() {
        let payload = Data(#"{"email":"me@example.com"}"#.utf8).base64URLEncoded
        expect(GoogleContacts.email(fromIDToken: "x.\(payload).y") == "me@example.com")
    }

    static func loopbackQueryParsing() {
        let parameters = LoopbackServer.queryParameters(fromRequest: "GET /?code=abc%2F1&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        expect(parameters == ["code": "abc/1", "state": "xyz"])
    }
}

enum MergeTests {
    static func dropsUngroundedModelValuesAndBackfills() {
        var model = Contact()
        model.givenName = "Jane"
        model.familyName = "Doe"
        model.phones = [.init(label: .mobile, value: "+1 999 999 9999")] // hallucinated
        model.emails = [.init(label: .work, value: "jane@acme.com")]
        var heuristic = Contact()
        heuristic.phones = [.init(label: .work, value: "415 555 0100")]
        heuristic.organization = "Acme"

        let merged = ContactExtractor.merge(model: model, heuristic: heuristic,
                                            sourceText: "Jane Doe\nAcme\n415 555 0100\njane@acme.com")
        expect(merged.fullName == "Jane Doe")
        expect(merged.phones.map(\.value) == ["415 555 0100"])
        expect(merged.emails.map(\.value) == ["jane@acme.com"])
        expect(merged.organization == "Acme")
    }

    static func dropsMiddleNameRepeatingSurname() {
        var model = Contact()
        model.givenName = "Nor Zamielia"
        model.middleName = "Zainuddin"
        model.familyName = "Zainuddin"
        let merged = ContactExtractor.merge(model: model, heuristic: Contact(), sourceText: "Nor Zamielia Zainuddin")
        expect(merged.fullName == "Nor Zamielia Zainuddin")
        expect(merged.middleName.isEmpty)
    }
}

// MARK: - Runner

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var currentCheck = ""

func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #fileID, line: UInt = #line) {
    if !condition() {
        failures += 1
        print("  FAIL \(currentCheck) (\(file):\(line))")
    }
}

let checks: [(String, () -> Void)] = [
    ("HeuristicParserTests.businessCard", HeuristicParserTests.businessCard),
    ("HeuristicParserTests.titleAndCompanyOnOneLine", HeuristicParserTests.titleAndCompanyOnOneLine),
    ("HeuristicParserTests.fallsBackToEmailForNameAndCompany", HeuristicParserTests.fallsBackToEmailForNameAndCompany),
    ("HeuristicParserTests.namePartsWithHonorificsAndCredentials", HeuristicParserTests.namePartsWithHonorificsAndCredentials),
    ("VCardWriterTests.writesEscapedCRLFCard", VCardWriterTests.writesEscapedCRLFCard),
    ("VCardWriterTests.foldsLongLinesWithoutSplittingCharacters", VCardWriterTests.foldsLongLinesWithoutSplittingCharacters),
    ("GoogleContactsTests.peopleAPIBody", GoogleContactsTests.peopleAPIBody),
    ("GoogleContactsTests.parsesDesktopClientFile", GoogleContactsTests.parsesDesktopClientFile),
    ("GoogleContactsTests.emailFromIDToken", GoogleContactsTests.emailFromIDToken),
    ("GoogleContactsTests.loopbackQueryParsing", GoogleContactsTests.loopbackQueryParsing),
    ("MergeTests.dropsUngroundedModelValuesAndBackfills", MergeTests.dropsUngroundedModelValuesAndBackfills),
    ("MergeTests.dropsMiddleNameRepeatingSurname", MergeTests.dropsMiddleNameRepeatingSurname),
]

for (name, check) in checks {
    currentCheck = name
    let before = failures
    check()
    print(failures == before ? "  ok   \(name)" : "")
}
print(failures == 0 ? "All \(checks.count) checks passed." : "\(failures) expectation(s) failed.")
exit(failures == 0 ? 0 : 1)
