import SwiftUI

struct SettingsView: View {
    var isOnboarding = false

    @Environment(AppState.self) private var app
    @State private var geminiKey = ""
    @State private var email = ""
    @State private var password = ""
    @State private var message: String?
    @State private var busy = false

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
                    Button("Save key") { saveKey() }
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
                Text("Kept in the keychain, sent only to Google when a recording is transcribed. Audio is deleted as soon as the transcript comes back.")
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
                    }
                    .disabled(busy || !app.isConfigured)
                }
            }

            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isOnboarding ? "Set up" : "Settings")
        .task { if app.hasGeminiKey { geminiKey = "" } }
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
