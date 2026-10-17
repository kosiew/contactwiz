import ContactWizCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HSplitView {
            ImagePane(model: model)
                .frame(minWidth: 300, idealWidth: 380)
            VStack(spacing: 0) {
                ContactForm(contact: $model.contact, showMoreName: $model.showMoreNameFields)
                Divider()
                ActionBar(model: model)
            }
            .frame(minWidth: 460)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseImage() } label: { Label("Open", systemImage: "folder") }
                    .help("Open a screenshot (⌘O)")
                Button { model.pasteImage() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .help("Paste a screenshot from the clipboard (⇧⌘V)")
                Button { model.captureScreenRegion() } label: { Label("Capture", systemImage: "camera.viewfinder") }
                    .help("Capture a region of the screen (⇧⌘R)")
                Button { model.reextract() } label: { Label("Re-extract", systemImage: "arrow.clockwise") }
                    .help("Run extraction again")
                    .disabled(model.image == nil || model.isProcessing)
                Button { model.clear() } label: { Label("Clear", systemImage: "trash") }
                    .disabled(model.image == nil && model.contact.isEmpty)
            }
        }
        .sheet(isPresented: $model.showGoogleSetup) {
            GoogleSetupView(model: model)
        }
        .alert("ContactWiz", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Image

private struct ImagePane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let image = model.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                } else {
                    placeholder
                }
                if model.isProcessing {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Reading contact details…").font(.callout)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(model.isDropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .underPageBackgroundColor))
            .onDrop(of: [.fileURL, .image], isTargeted: $model.isDropTargeted) { model.handleDrop($0) }

            if !model.recognizedLines.isEmpty {
                Divider()
                DisclosureGroup("Recognized text (\(model.recognizedLines.count) lines)", isExpanded: $model.showRecognizedText) {
                    ScrollView {
                        Text(model.recognizedText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .padding(10)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.rectangle.badge.plus")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a screenshot here").font(.title3.weight(.medium))
            Text("Business cards, email signatures, profile pages…")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Open…") { model.chooseImage() }
                Button("Paste") { model.pasteImage() }
                Button("Capture Screen") { model.captureScreenRegion() }
            }
            .padding(.top, 4)
        }
        .padding()
    }
}

// MARK: - Form

private struct ContactForm: View {
    @Binding var contact: Contact
    @Binding var showMoreName: Bool

    var body: some View {
        Form {
            Section("Name") {
                TextField("First", text: $contact.givenName)
                TextField("Last", text: $contact.familyName)
                DisclosureGroup("More name fields", isExpanded: $showMoreName) {
                    TextField("Prefix", text: $contact.namePrefix)
                    TextField("Middle", text: $contact.middleName)
                    TextField("Suffix", text: $contact.nameSuffix)
                }
            }
            Section("Work") {
                TextField("Company", text: $contact.organization)
                TextField("Job title", text: $contact.jobTitle)
            }
            Section("Phone") {
                ForEach($contact.phones) { $phone in
                    HStack {
                        Picker("Label", selection: $phone.label) {
                            ForEach(PhoneLabel.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 96)
                        TextField("Phone", text: $phone.value, prompt: Text("Phone"))
                            .labelsHidden()
                        RemoveButton { contact.phones.removeAll { $0.id == phone.id } }
                    }
                }
                AddButton("Add phone") { contact.phones.append(.init(label: .mobile, value: "")) }
            }
            Section("Email") {
                ForEach($contact.emails) { $email in
                    HStack {
                        Picker("Label", selection: $email.label) {
                            ForEach(EmailLabel.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 96)
                        TextField("Email", text: $email.value, prompt: Text("Email"))
                            .labelsHidden()
                        RemoveButton { contact.emails.removeAll { $0.id == email.id } }
                    }
                }
                AddButton("Add email") { contact.emails.append(.init(label: .work, value: "")) }
            }
            Section("Website") {
                ForEach($contact.websites) { $site in
                    HStack {
                        TextField("Website", text: $site.value, prompt: Text("https://"))
                            .labelsHidden()
                        RemoveButton { contact.websites.removeAll { $0.id == site.id } }
                    }
                }
                AddButton("Add website") { contact.websites.append(Website("")) }
            }
            Section("Address") {
                TextField("Street", text: $contact.address.street, axis: .vertical)
                TextField("City", text: $contact.address.city)
                TextField("State / Region", text: $contact.address.region)
                TextField("Postal code", text: $contact.address.postalCode)
                TextField("Country", text: $contact.address.country)
            }
            Section("Notes") {
                TextField("Notes", text: $contact.note, axis: .vertical)
                    .lineLimit(3...8)
                    .labelsHidden()
            }
        }
        .formStyle(.grouped)
    }
}

private struct RemoveButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.borderless)
            .help("Remove")
    }
}

private struct AddButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    var body: some View {
        Button(action: action) { Label(title, systemImage: "plus.circle") }
            .buttonStyle(.borderless)
    }
}

// MARK: - Actions

private struct ActionBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLine
            HStack {
                Menu("Export") {
                    Button("Save vCard (.vcf)…") { model.saveVCard() }
                    Button("Copy vCard") { model.copyVCard() }
                    Button("Open in Apple Contacts") { model.openInAppleContacts() }
                }
                .fixedSize()
                .disabled(model.contact.isEmpty)

                if let url = model.lastCreatedURL {
                    Link("View in Google Contacts", destination: url)
                }
                Spacer()
                if model.isSigningIn {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Google sign-in in your browser…").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelSignIn() }
                } else if model.isCreatingInGoogle {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.addToGoogleContacts()
                } label: {
                    Label("Add to Google Contacts", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.contact.isEmpty || model.isProcessing || model.isSigningIn || model.isCreatingInGoogle)
            }
        }
        .padding(12)
    }

    @ViewBuilder private var statusLine: some View {
        if let message = model.statusMessage {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else if let extraction = model.extraction {
            let icon = extraction.method == .foundationModel ? "apple.intelligence" : "text.viewfinder"
            let detail = extraction.fallbackReason.map { " — \($0)" } ?? ""
            Label("Extracted with \(extraction.method.rawValue)\(detail). Review the fields, then add.", systemImage: icon)
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(model.googleSignedIn ? "Google: \(model.googleAccount ?? "signed in")" : "Not signed in to Google")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
