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
                    Button("Import JSON…") { model.chooseClientFile() }
                    Button("Save") { model.saveDraftCredentials() }
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
                HStack {
                    if let error = model.setupError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Text("Needs a Desktop app OAuth client from Google Cloud Console.")
                    }
                    Spacer()
                    Button("Setup Guide…") { model.presentGoogleSetup() }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
