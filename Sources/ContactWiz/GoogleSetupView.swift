import AppKit
import SwiftUI

/// Guided one-time setup of the user's own Google OAuth client.
struct GoogleSetupView: View {
    @ObservedObject var model: AppModel

    private var isConfigured: Bool {
        !model.draftClientID.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.draftClientSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SetupStep(number: 1, title: "Create a Google Cloud project",
                              detail: "Any name works, e.g. “ContactWiz”. Skip if you already have one.",
                              link: ("Create project", "https://console.cloud.google.com/projectcreate"))
                    SetupStep(number: 2, title: "Enable the People API",
                              detail: "Make sure your new project is selected at the top, then click Enable.",
                              link: ("Open People API", "https://console.cloud.google.com/apis/library/people.googleapis.com"))
                    SetupStep(number: 3, title: "Set up the consent screen",
                              detail: "Click Get started: app name “ContactWiz”, your email, audience External. Then under Audience → Test users, add your Google account.",
                              link: ("Open Google Auth Platform", "https://console.cloud.google.com/auth/overview"),
                              secondaryLink: ("Test users", "https://console.cloud.google.com/auth/audience"))
                    SetupStep(number: 4, title: "Create a Desktop app client",
                              detail: "Application type: Desktop app. After Create, click Download JSON.",
                              link: ("Create OAuth client", "https://console.cloud.google.com/auth/clients/create"))
                    SetupStep(number: 5, title: "Import the downloaded file", detail: nil, link: nil) {
                        importArea
                    }
                }
                .padding(.trailing, 4)
            }
            footer
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Returning from the browser: pick up a freshly downloaded file.
            model.scanDownloadsForClientFile()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect Google Contacts").font(.title2.weight(.semibold))
                Text("ContactWiz talks to Google with your own OAuth client, so your contacts never pass through anyone else's servers. This takes about 3 minutes, once.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var importArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isConfigured {
                Label("Client ready: \(model.draftClientID.prefix(24))…", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if let file = model.foundClientFile {
                HStack {
                    Label(file.lastPathComponent, systemImage: "doc.badge.arrow.up")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Use This File") { model.importClientFile(file) }
                        .buttonStyle(.borderedProminent)
                }
                Text("Found in your Downloads folder.").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Choose JSON File…") { model.chooseClientFile() }
                Text("or drop it here").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.tertiary))
            .onDrop(of: [.fileURL], isTargeted: nil) { model.handleClientFileDrop($0) }

            if let error = model.setupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Enter client ID and secret manually", isExpanded: $model.showManualCredentials) {
                VStack(spacing: 8) {
                    TextField("Client ID", text: $model.draftClientID)
                    SecureField("Client secret", text: $model.draftClientSecret)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }

    private var footer: some View {
        HStack {
            Text("Stored in your Keychain. Change later in Settings (⌘,).")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) { model.cancelGoogleSetup() }
                .keyboardShortcut(.cancelAction)
            Button(model.googleSignedIn ? "Done" : "Sign In with Google") { model.completeGoogleSetup() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isConfigured)
        }
    }
}

private struct SetupStep<Extra: View>: View {
    let number: Int
    let title: String
    let detail: String?
    let link: (String, String)?
    var secondaryLink: (String, String)?
    @ViewBuilder var extra: Extra

    init(number: Int, title: String, detail: String?, link: (String, String)?,
         secondaryLink: (String, String)? = nil, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.number = number
        self.title = title
        self.detail = detail
        self.link = link
        self.secondaryLink = secondaryLink
        self.extra = extra()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if link != nil || secondaryLink != nil {
                    HStack(spacing: 14) {
                        if let (label, url) = link { Link("\(label) ↗", destination: URL(string: url)!) }
                        if let (label, url) = secondaryLink { Link("\(label) ↗", destination: URL(string: url)!) }
                    }
                    .font(.callout)
                }
                extra
            }
            Spacer(minLength: 0)
        }
    }
}
