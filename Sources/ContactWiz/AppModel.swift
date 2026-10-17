import AppKit
import ContactWizCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var image: NSImage?
    @Published var contact = Contact()
    @Published var recognizedLines: [RecognizedLine] = []
    @Published var isProcessing = false
    @Published var extraction: ExtractionResult?
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    @Published var isSigningIn = false
    @Published var isCreatingInGoogle = false
    @Published var googleAccount: String?
    @Published var googleSignedIn = false
    @Published var lastCreatedURL: URL?

    // View state kept here because `@State` is a macro in this SDK and the
    // Command Line Tools don't ship the SwiftUI macro plugin.
    @Published var isDropTargeted = false
    @Published var showRecognizedText = false
    @Published var showMoreNameFields = false
    @Published var draftClientID = GoogleContacts.shared.clientID
    @Published var draftClientSecret = GoogleContacts.shared.clientSecret

    @AppStorage("useAppleIntelligence") var useAppleIntelligence = true

    let google = GoogleContacts.shared
    private var processingTask: Task<Void, Never>?

    init() {
        refreshGoogleState()
        if useAppleIntelligence { ContactExtractor.prewarm() }
    }

    var recognizedText: String { recognizedLines.map(\.text).joined(separator: "\n") }
    var vCard: String { VCardWriter.vCard(for: contact) }

    // MARK: Input

    func open(url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = "“\(url.lastPathComponent)” isn't an image ContactWiz can read."
            return
        }
        load(image: image)
    }

    func load(image: NSImage) {
        self.image = image
        lastCreatedURL = nil
        statusMessage = nil
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorMessage = "The image could not be read."
            return
        }
        processingTask?.cancel()
        isProcessing = true
        let useAI = useAppleIntelligence
        processingTask = Task {
            defer { isProcessing = false }
            do {
                let lines = try await Task.detached(priority: .userInitiated) {
                    try TextRecognizer.recognize(cgImage: cgImage)
                }.value
                guard !Task.isCancelled else { return }
                recognizedLines = lines
                guard !lines.isEmpty else {
                    contact = Contact()
                    extraction = nil
                    errorMessage = "No text was found in this image."
                    return
                }
                let result = await ContactExtractor.extract(from: lines, useFoundationModel: useAI)
                guard !Task.isCancelled else { return }
                extraction = result
                contact = result.contact
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func reextract() {
        guard let image else { return }
        load(image: image)
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a screenshot containing contact details"
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    func pasteImage() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           let url = urls.first {
            open(url: url)
        } else if let image = NSImage(pasteboard: pasteboard) {
            load(image: image)
        } else {
            errorMessage = "The clipboard doesn't contain an image. Take a screenshot with ⌃⇧⌘4 to copy one."
        }
    }

    /// Interactive region capture using the system `screencapture` tool.
    func captureScreenRegion() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("contactwiz-\(UUID().uuidString).png")
        NSApp.hide(nil)
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            let status: Int32 = await withCheckedContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", url.path]
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(returning: -1) }
            }
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            guard status == 0, FileManager.default.fileExists(atPath: url.path) else { return } // user pressed Esc
            open(url: url)
            try? FileManager.default.removeItem(at: url)
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in self.open(url: url) }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                Task { @MainActor in self.load(image: image) }
            }
            return true
        }
        return false
    }

    // MARK: Output

    func addToGoogleContacts(openSettings: () -> Void) {
        guard google.isConfigured else {
            errorMessage = "Set up your Google OAuth client in Settings to add contacts to Google."
            openSettings()
            return
        }
        Task {
            do {
                if !google.isSignedIn { try await signIn() }
                isCreatingInGoogle = true
                defer { isCreatingInGoogle = false }
                let created = try await google.createContact(contact)
                lastCreatedURL = created.webURL
                statusMessage = "Added \(contact.displayName) to Google Contacts."
                NSWorkspace.shared.open(created.webURL)
            } catch is CancellationError {
                // Sign-in cancelled.
            } catch {
                errorMessage = error.localizedDescription
            }
            refreshGoogleState()
        }
    }

    func signIn() async throws {
        isSigningIn = true
        defer {
            isSigningIn = false
            refreshGoogleState()
        }
        try await google.signIn { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    func signInFromSettings() {
        Task {
            do { try await signIn() } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }

    func cancelSignIn() { google.cancelSignIn() }

    func signOut() {
        google.signOut()
        refreshGoogleState()
    }

    func refreshGoogleState() {
        googleSignedIn = google.isSignedIn
        googleAccount = google.accountEmail
    }

    func saveVCard() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.vCard]
        panel.nameFieldStringValue = contact.suggestedFileName + ".vcf"
        panel.message = "Import this file at contacts.google.com → Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try vCard.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyVCard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(vCard, forType: .string)
        statusMessage = "vCard copied to the clipboard."
    }

    /// Hands the vCard to Apple Contacts (which syncs to Google if that account is set up there).
    func openInAppleContacts() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(contact.suggestedFileName + ".vcf")
        do {
            try vCard.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        processingTask?.cancel()
        image = nil
        contact = Contact()
        recognizedLines = []
        extraction = nil
        statusMessage = nil
        lastCreatedURL = nil
    }
}
