import Foundation
import Observation
import SwiftUI

/// Connection details and the signed-in session.
///
/// The Supabase URL and anon key are publishable, so they live in defaults.
/// The Gemini key is not, so it lives in the keychain.
@MainActor
@Observable
final class AppState {
    var supabaseURL: String {
        didSet { UserDefaults.standard.set(supabaseURL, forKey: "supabaseURL"); rebuild() }
    }
    var supabaseAnonKey: String {
        didSet { UserDefaults.standard.set(supabaseAnonKey, forKey: "supabaseAnonKey"); rebuild() }
    }

    private(set) var store: ScribeStore?
    private(set) var session: RecordingSession?
    var signedIn = false
    var people: [Person] = []

    init() {
        supabaseURL = UserDefaults.standard.string(forKey: "supabaseURL") ?? ""
        supabaseAnonKey = UserDefaults.standard.string(forKey: "supabaseAnonKey") ?? ""
        rebuild()
    }

    var isConfigured: Bool {
        !supabaseURL.isEmpty && !supabaseAnonKey.isEmpty && URL(string: supabaseURL) != nil
    }

    var hasGeminiKey: Bool { Keychain.get("gemini")?.isEmpty == false }

    private func rebuild() {
        guard isConfigured, let url = URL(string: supabaseURL) else {
            store = nil
            session = nil
            return
        }
        let store = ScribeStore(url: url, anonKey: supabaseAnonKey)
        self.store = store
        self.session = RecordingSession(store: store)
    }

    func refreshSession() async {
        guard let store else { signedIn = false; return }
        signedIn = await store.userId != nil
        if signedIn { await refreshPeople() }
    }

    func refreshPeople() async {
        people = (try? await store?.people()) ?? []
    }

    /// Someone new joined the meeting; make them taggable right away.
    @discardableResult
    func addPerson(_ name: String) async -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let store else { return nil }
        let person = try? await store.addPerson(named: trimmed)
        await refreshPeople()
        return person
    }
}
