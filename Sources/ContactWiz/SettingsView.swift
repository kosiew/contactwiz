import ContactWizCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Extraction") {
                Toggle("Use Apple Intelligence (on-device)", isOn: $model.useAppleIntelligence)
                Text(ContactExtractor.isFoundationModelAvailable
                     ? "The on-device model reads the recognized text; built-in rules fill any gaps."
                     : "Apple Intelligence isn't available on this Mac, so built-in rules are used.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Client ID", text: $model.draftClientID)
                SecureField("Client secret", text: $model.draftClientSecret)
                HStack {
                    Button("Save") {
                        model.google.clientID = model.draftClientID
                        model.google.clientSecret = model.draftClientSecret
                        model.refreshGoogleState()
                    }
                    .disabled(model.draftClientID == model.google.clientID && model.draftClientSecret == model.google.clientSecret)
                    Spacer()
                    if model.googleSignedIn {
                        Text(model.googleAccount ?? "Signed in").foregroundStyle(.secondary)
                        Button("Sign Out") { model.signOut() }
                    } else if model.isSigningIn {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancelSignIn() }
                    } else {
                        Button("Sign In with Google") {
                            model.google.clientID = model.draftClientID
                            model.google.clientSecret = model.draftClientSecret
                            model.signInFromSettings()
                        }
                        .disabled(model.draftClientID.isEmpty || model.draftClientSecret.isEmpty)
                    }
                }
            } header: {
                Text("Google Contacts")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("One-time setup in Google Cloud Console:")
                    Text("1. Create a project and enable the **People API**.")
                    Text("2. Configure the OAuth consent screen and add yourself as a test user.")
                    Text("3. Credentials → Create OAuth client ID → **Desktop app**. Paste its ID and secret here.")
                    Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
