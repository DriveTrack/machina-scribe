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

    /// Where a fresh install points before anyone opens Settings.
    ///
    /// Both values are publishable by design -- the anon key authorises
    /// nothing on its own, because every table is behind RLS keyed on
    /// `auth.uid()`. Shipping them means the iPhone, which has no shell to
    /// write defaults from, does not need either value typed in by hand.
    ///
    /// The legacy `anon` JWT rather than the newer `sb_publishable_` key:
    /// supabase-swift is pinned at 2.x here and the JWT is the form it has
    /// been exercised against. Swap once that is actually tested.
    enum DefaultConnection {
        static let url = "https://lclnwhbhoibnipcbgbpi.supabase.co"
        static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxjbG53aGJob2libmlwY2JnYnBpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg1NDQ3MzQsImV4cCI6MjEwNDEyMDczNH0.Q0U13fDT76W5e_AYRyBqwNh_ADsNDNk2r38SFoku4Rk"
    }
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

    /// Bumped whenever the meeting list changes. The macOS sidebar is built
    /// once when the window opens, so without this it never learns that a
    /// recording finished and stays stuck on "No meetings yet".
    private(set) var meetingsToken = UUID()

    /// Which model writes the summaries. Cost differs sixfold; quality is a
    /// judgement only the reader can make, so it is a setting.
    var summaryModel: Summarizer.Model {
        didSet { UserDefaults.standard.set(summaryModel.rawValue, forKey: "summaryModel") }
    }

    /// The Notion database meetings are filed into, once chosen.
    var notionDestination: NotionExporter.Destination? {
        didSet {
            let data = notionDestination.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data, forKey: "notionDestination")
        }
    }

    private(set) var hasNotionKey: Bool

    /// How long finished recordings are kept so voices can be identified by
    /// ear afterwards. Zero keeps none.
    var keepAudioHours: Int {
        didSet {
            UserDefaults.standard.set(keepAudioHours, forKey: "keepAudioHours")
            applyRetention()
        }
    }

    /// Mirrors the keychain. Kept as stored state because the keychain itself
    /// is invisible to observation -- reading it in a computed property means
    /// views never learn that a key was added, and the record button stays
    /// disabled until something unrelated redraws it.
    private(set) var hasGeminiKey: Bool

    init() {
        // Fall back to the shipped project rather than an empty string, so the
        // first launch is already connected. A value the user has typed always
        // wins -- this only fills the gap where there is nothing stored.
        supabaseURL = UserDefaults.standard.string(forKey: "supabaseURL")
            ?? DefaultConnection.url
        supabaseAnonKey = UserDefaults.standard.string(forKey: "supabaseAnonKey")
            ?? DefaultConnection.anonKey
        hasGeminiKey = Keychain.get("gemini")?.isEmpty == false
        keepAudioHours = UserDefaults.standard.object(forKey: "keepAudioHours") as? Int ?? 24
        summaryModel = UserDefaults.standard.string(forKey: "summaryModel")
            .flatMap(Summarizer.Model.init(rawValue:)) ?? .flashLite
        notionDestination = UserDefaults.standard.data(forKey: "notionDestination")
            .flatMap { try? JSONDecoder().decode(NotionExporter.Destination.self, from: $0) }
        hasNotionKey = Keychain.get("notion")?.isEmpty == false
        rebuild()
        applyRetention()
    }

    func meetingsDidChange() { meetingsToken = UUID() }

    var archive: RecordingArchive {
        RecordingArchive(retention: .seconds(keepAudioHours * 3600))
    }

    /// Push the current setting down, and sweep anything already past its
    /// window -- including everything, when retention has just been turned off.
    private func applyRetention() {
        session?.archive = archive
        archive.purgeExpired()
    }

    func setGeminiKey(_ key: String) throws {
        try Keychain.set(key, for: "gemini")
        hasGeminiKey = true
    }

    func clearGeminiKey() {
        Keychain.delete("gemini")
        hasGeminiKey = false
    }

    func setNotionKey(_ key: String) throws {
        try Keychain.set(key, for: "notion")
        hasNotionKey = true
    }

    func clearNotionKey() {
        Keychain.delete("notion")
        hasNotionKey = false
        notionDestination = nil
    }

    /// Built per use rather than held: the key can change under us, and an
    /// exporter carrying a stale token fails in a confusing way.
    var notion: NotionExporter? {
        Keychain.get("notion").map { NotionExporter(token: $0) }
    }

    var summarizer: Summarizer? {
        Keychain.get("gemini").map { Summarizer(apiKey: $0, model: summaryModel) }
    }

    var isConfigured: Bool {
        !supabaseURL.isEmpty && !supabaseAnonKey.isEmpty && URL(string: supabaseURL) != nil
    }

    private func rebuild() {
        guard isConfigured, let url = URL(string: supabaseURL) else {
            store = nil
            session = nil
            return
        }
        let store = ScribeStore(url: url, anonKey: supabaseAnonKey)
        self.store = store
        let session = RecordingSession(store: store)
        session.archive = archive
        session.onTranscriptSaved = { [weak self] in self?.meetingsDidChange() }
        self.session = session
    }

    func refreshSession() async {
        guard let store else { signedIn = false; return }
        signedIn = await store.userId != nil
        if signedIn {
            try? await store.abandonStaleRecordings()
            await refreshPeople()
        }
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
