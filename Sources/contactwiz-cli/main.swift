import ContactWizCore
import Foundation

let usage = """
    usage: contactwiz-cli <image> [-o out.vcf] [--no-ai] [--lines] [--google]

      -o FILE   write the vCard to FILE instead of stdout
      --no-ai   skip Apple Intelligence; use built-in rules only
      --lines   print the OCR lines to stderr
      --google  create the contact in Google Contacts (sign in via the app first)
    """

var arguments = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

let noAI = flag("--no-ai")
let printLines = flag("--lines")
let google = flag("--google")
let output = option("-o")

guard arguments.count == 1 else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

do {
    let lines = try TextRecognizer.recognize(imageAt: URL(fileURLWithPath: arguments[0]))
    if printLines { lines.forEach { stderr("ocr: \($0.text)") } }

    let result = await ContactExtractor.extract(from: lines, useFoundationModel: !noAI)
    stderr("extracted with: \(result.method.rawValue)" + (result.fallbackReason.map { " (\($0))" } ?? ""))

    let vCard = VCardWriter.vCard(for: result.contact)
    if let output {
        try vCard.write(toFile: output, atomically: true, encoding: .utf8)
        stderr("wrote \(output)")
    } else {
        print(vCard, terminator: "")
    }

    if google {
        let created = try await GoogleContacts.shared.createContact(result.contact)
        stderr("created \(created.resourceName): \(created.webURL.absoluteString)")
    }
} catch {
    stderr("error: \(error.localizedDescription)")
    exit(1)
}
