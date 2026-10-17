import AppKit
import SwiftUI

@main
struct ContactWizApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("ContactWiz", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Screenshot…") { model.chooseImage() }
                    .keyboardShortcut("o")
                Button("Paste Screenshot") { model.pasteImage() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Capture Screen Region") { model.captureScreenRegion() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save vCard…") { model.saveVCard() }
                    .keyboardShortcut("s")
                    .disabled(model.contact.isEmpty)
                Button("Copy vCard") { model.copyVCard() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.contact.isEmpty)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (e.g. `swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { AppModel.shared.open(url: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
