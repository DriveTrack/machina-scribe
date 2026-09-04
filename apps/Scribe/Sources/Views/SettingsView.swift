import SwiftUI

struct SettingsView: View {
    var isOnboarding = false

    @Environment(AppState.self) private var app
    @State private var geminiKey = ""
    @State private var email = ""
    @State private var password = ""
    @State private var message: String?
    @State private var busy = false
    @State private var heldBytes: Int64 = 0
    @State private var notionKey = ""
    @State private var notionDatabases: [NotionExporter.Destination] = []
    @State private var loadingNotion = false

    var body: some View {
        @Bindable var app = app

        Form {
            Section {
                TextField("Project URL", text: $app.supabaseURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                SecureField("Anon / publishable key", text: $app.supabaseAnonKey)
            } header: {
                Text("Supabase")
            } footer: {
                Text("Both are safe to store on device. Find them under Project Settings → API.")
            }

            Section {
                SecureField("API key", text: $geminiKey)
                HStack {
                    // Bordered so it reads as a button; in a Form a plain one
                    // renders as another flat row and looks like a text field.
                    Button("Save key") { saveKey() }
                        .buttonStyle(.borderedProminent)
                        .disabled(geminiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if app.hasGeminiKey {
                        Spacer()
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                        Button("Remove", role: .destructive) {
                            app.clearGeminiKey()
                            geminiKey = ""
                        }
                        .font(.footnote)
                    }
                }
            } header: {
                Text("Gemini")
            } footer: {
                Text("Kept in the keychain, sent only to Google when a recording is transcribed.")
            }

            Section {
                Picker("Summaries written by", selection: Binding(
                    get: { app.summaryModel },
                    set: { app.summaryModel = $0 }
                )) {
                    ForEach(Summarizer.Model.allCases) { model in
                        Text(model.label).tag(model)
                    }
                }
            } header: {
                Text("Summaries")
            } footer: {
                Text(app.summaryModel == .flashLite
                     ? "About half a cent for an hour-long meeting. Fine for most notes."
                     : "About six times the cost — still pennies — and better at working out who committed to what.")
            }

            Section {
                SecureField("Internal integration secret", text: $notionKey)
                HStack {
                    Button("Save key") { saveNotionKey() }
                        .buttonStyle(.borderedProminent)
                        .disabled(notionKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if app.hasNotionKey {
                        Spacer()
                        Button("Remove", role: .destructive) { app.clearNotionKey() }
                            .font(.footnote)
                    }
                }

                if app.hasNotionKey {
                    if notionDatabases.isEmpty {
                        Button(loadingNotion ? "Loading…" : "Find my databases") {
                            Task { await loadNotionDatabases() }
                        }
                        .disabled(loadingNotion)
                    } else {
                        Picker("File meetings into", selection: Binding(
                            get: { app.notionDestination?.id ?? "" },
                            set: { id in
                                app.notionDestination = notionDatabases.first { $0.id == id }
                            }
                        )) {
                            Text("Choose…").tag("")
                            ForEach(notionDatabases) { database in
                                Text(database.title).tag(database.id)
                            }
                        }
                    }
                }
            } header: {
                Text("Notion")
            } footer: {
                Text(notionHint)
            }

            Section {
                Picker("Keep recordings for", selection: Binding(
                    get: { app.keepAudioHours },
                    set: { app.keepAudioHours = $0 }
                )) {
                    Text("Don't keep audio").tag(0)
                    Text("6 hours").tag(6)
                    Text("24 hours").tag(24)
                    Text("3 days").tag(72)
                }
                if app.keepAudioHours > 0, heldBytes > 0 {
                    HStack {
                        Text("Currently holding")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: heldBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    Button("Delete all kept audio now", role: .destructive) {
                        var archive = app.archive
                        archive.retention = .zero
                        archive.purgeExpired()
                        heldBytes = 0
                    }
                }
            } header: {
                Text("Recordings")
            } footer: {
                Text(app.keepAudioHours == 0
                     ? "Audio is deleted the moment its transcript is stored. Transcripts are kept; recordings are not."
                     : "Audio stays on this device only, so you can play a meeting back and work out who a voice was. It is deleted automatically once the window passes, and never uploaded anywhere except Google for transcription.")
            }

            Section("Account") {
                if app.signedIn {
                    Button("Sign out", role: .destructive) {
                        Task {
                            try? await app.store?.signOut()
                            await app.refreshSession()
                        }
                    }
                } else {
                    TextField("Email", text: $email)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        #endif
                    SecureField("Password", text: $password)
                    HStack {
                        Button("Sign in") { authenticate(signingUp: false) }
                            .buttonStyle(.borderedProminent)
                        Button("Create account") { authenticate(signingUp: true) }
                            .buttonStyle(.bordered)
                    }
                    .disabled(busy || !app.isConfigured)

                    Text("No account yet? Pick any email and password and choose Create account — this is your own database.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isOnboarding ? "Set up" : "Settings")
        .task {
            if app.hasGeminiKey { geminiKey = "" }
            heldBytes = app.archive.bytesHeld()
            if app.hasNotionKey, notionDatabases.isEmpty { await loadNotionDatabases() }
        }
    }

    /// Notion only exposes what has been explicitly shared with an
    /// integration, which is the single most common reason a database is
    /// missing from the list -- so say it here rather than showing an empty
    /// picker with no explanation.
    private var notionHint: String {
        if !app.hasNotionKey {
            return "Create an internal integration at notion.so/my-integrations, copy its secret, then share the target database with it from the database's ⋯ menu → Connections."
        }
        if notionDatabases.isEmpty {
            return "Nothing found yet. In Notion, open the database → ⋯ → Connections → add your integration, then look again."
        }
        return "Meetings are filed as new pages: summary, action items as checkboxes, then the transcript."
    }

    private func saveNotionKey() {
        do {
            try app.setNotionKey(notionKey.trimmingCharacters(in: .whitespaces))
            notionKey = ""
            message = "Notion key saved."
            Task { await loadNotionDatabases() }
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadNotionDatabases() async {
        guard let notion = app.notion else { return }
        loadingNotion = true
        defer { loadingNotion = false }
        do {
            notionDatabases = try await notion.destinations()
            if notionDatabases.isEmpty { message = "No databases are shared with that integration yet." }
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveKey() {
        do {
            try app.setGeminiKey(geminiKey.trimmingCharacters(in: .whitespaces))
            geminiKey = ""
            message = "Gemini key saved."
        } catch {
            message = error.localizedDescription
        }
    }

    private func authenticate(signingUp: Bool) {
        busy = true
        message = nil
        Task {
            do {
                if signingUp {
                    try await app.store?.signUp(email: email, password: password)
                } else {
                    try await app.store?.signIn(email: email, password: password)
                }
                await app.refreshSession()
                password = ""
                if !app.signedIn {
                    message = "Check your email to confirm the account, then sign in."
                }
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }
}
