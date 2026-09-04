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

    private(set) var store: LocalStore?
    private(set) var session: RecordingSession?
    var signedIn = false
    var people: [Person] = []

    /// Bumped whenever the meeting list changes. The macOS sidebar is built
    /// once when the window opens, so without this it never learns that a
    /// recording finished and stays stuck on "No meetings yet".
    private(set) var meetingsToken = UUID()

    /// Which engine turns audio into words.
    ///
    /// On-device by default: it is free, it never uploads the meeting, it runs
    /// on the Neural Engine rather than competing for memory, and on the one
    /// long meeting we have both transcripts for it reached the same end
    /// timestamp as Gemini. Gemini stays available for languages the device
    /// cannot handle.
    var transcriptionEngine: TranscriptionEngine {
        didSet {
            UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: "transcriptionEngine")
            // The session captures the engine when it is built, so it has to be
            // rebuilt for a change here to take effect.
            rebuild()
        }
    }

    enum TranscriptionEngine: String, CaseIterable, Identifiable, Sendable {
        case onDevice
        case gemini

        public var id: String { rawValue }

        var label: String {
            switch self {
            case .onDevice: "On this device"
            case .gemini: "Gemini"
            }
        }

        var detail: String {
            switch self {
            case .onDevice:
                "Free and private. Nothing is uploaded, and speakers are worked out here too."
            case .gemini:
                "Uploads the recording. Costs about $1.30 for a two-hour meeting."
            }
        }
    }

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
        transcriptionEngine = UserDefaults.standard.string(forKey: "transcriptionEngine")
            .flatMap(TranscriptionEngine.init(rawValue:)) ?? .onDevice
        summaryEngine = UserDefaults.standard.string(forKey: "summaryEngine")
            .flatMap(SummaryEngine.init(rawValue:)) ?? .onDevice
        localSummaryEndpoint = UserDefaults.standard.string(forKey: "localSummaryEndpoint")
            ?? LocalEndpointSummarizer.defaultEndpoint.absoluteString
        localSummaryModel = UserDefaults.standard.string(forKey: "localSummaryModel")
            ?? LocalEndpointSummarizer.defaultModel
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

    /// Which model writes summaries. On-device first, because it is free and
    /// the transcript never leaves -- but its availability is a system setting
    /// we do not control, so this has to degrade rather than fail.
    var summaryEngine: SummaryEngine {
        didSet { UserDefaults.standard.set(summaryEngine.rawValue, forKey: "summaryEngine") }
    }

    enum SummaryEngine: String, CaseIterable, Identifiable, Sendable {
        case onDevice
        case localServer
        case gemini

        var id: String { rawValue }

        var label: String {
            switch self {
            case .onDevice: "On this device"
            case .localServer: "Local server (Ollama, LM Studio)"
            case .gemini: "Gemini"
            }
        }

        var detail: String {
            switch self {
            case .onDevice:
                "Free, offline, and costs the app no memory. Needs Apple Intelligence switched on."
            case .localServer:
                "Free and offline, and sees the whole meeting at once. Needs a server running here."
            case .gemini:
                "Uploads the transcript to Google. About $0.006 a meeting."
            }
        }
    }

    /// Where the summariser at hand actually is, and why it might not work.
    /// Nil when it is ready.
    var summaryBlocker: String? {
        switch summaryEngine {
        case .onDevice: AppleSummarizer.availability
        case .localServer: nil   // only discoverable by trying
        case .gemini: hasGeminiKey ? nil : "Add a Gemini API key in Settings."
        }
    }

    var summarizer: (any MeetingSummarizing)? {
        switch summaryEngine {
        case .onDevice:
            return AppleSummarizer.availability == nil ? AppleSummarizer() : nil
        case .localServer:
            return LocalEndpointSummarizer(
                endpoint: URL(string: localSummaryEndpoint) ?? LocalEndpointSummarizer.defaultEndpoint,
                model: localSummaryModel
            )
        case .gemini:
            return Keychain.get("gemini").map { Summarizer(apiKey: $0, model: summaryModel) }
        }
    }

    var localSummaryEndpoint: String {
        didSet { UserDefaults.standard.set(localSummaryEndpoint, forKey: "localSummaryEndpoint") }
    }

    var localSummaryModel: String {
        didSet { UserDefaults.standard.set(localSummaryModel, forKey: "localSummaryModel") }
    }

    /// Nothing has to be configured any more -- the store is a local file.
    /// Kept so the onboarding gate has something to ask.
    var isConfigured: Bool { store != nil }

    /// Set when the database could not be opened, which is the only way the
    /// app can now fail to start.
    private(set) var storeError: String?

    /// Where the meetings actually are, said plainly. A local-first app owes
    /// the user a straight answer to "so where is my data".
    var storageDescription: String {
        (try? LocalStore.defaultURL().path(percentEncoded: false))
            ?? "this device"
    }

    func revealStore() {
        #if os(macOS)
        guard let url = try? LocalStore.defaultURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    /// Whether a recording could actually be transcribed if one started now.
    ///
    /// On-device needs nothing bought or pasted, which is most of the point:
    /// the old first-run cliff was being told to go and get an API key before
    /// the app would record at all.
    var canTranscribe: Bool {
        switch transcriptionEngine {
        case .onDevice: true
        case .gemini: hasGeminiKey
        }
    }

    /// Why recording is unavailable, or nil when it is fine.
    var transcriptionBlocker: String? {
        canTranscribe ? nil : "Add a Gemini API key in Settings, or switch to on-device transcription."
    }

    private func rebuild() {
        // No URL, no key, no account. The meetings live in a file in this
        // user's own Application Support directory, so there is nothing to
        // configure before the app works and nothing to be signed out of.
        guard let store = try? LocalStore() else {
            self.store = nil
            session = nil
            storeError = "Could not open the meetings database."
            return
        }
        storeError = nil
        self.store = store
        let session = RecordingSession(store: store, engine: transcriptionEngine)
        session.archive = archive
        session.onTranscriptSaved = { [weak self] in self?.meetingsDidChange() }
        self.session = session
    }

    func refreshSession() async {
        guard let store else { signedIn = false; return }
        // Local storage has no session to be in or out of; the file either
        // opened or it did not.
        signedIn = true
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
