import Foundation
import ScribeCore
import Supabase

/// Everything that touches the database. Transcripts only -- audio never
/// reaches this layer.
@MainActor
final class ScribeStore {
    let client: SupabaseClient

    init(url: URL, anonKey: String) {
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }

    var userId: UUID? {
        get async { try? await client.auth.session.user.id }
    }

    // MARK: - Auth

    func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
    }

    func signUp(email: String, password: String) async throws {
        try await client.auth.signUp(email: email, password: password)
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    // MARK: - Recording lifecycle

    private struct NewMeeting: Encodable {
        let user_id: UUID
        let title: String?
        let location: String?
        let source: String
        let status: String
        let started_at: Date
    }

    func startMeeting(title: String?, location: String?) async throws -> UUID {
        guard let user = await userId else { throw ScribeError.transcription("Not signed in.") }
        #if os(iOS)
        let source = "ios"
        #else
        let source = "macos"
        #endif

        let row: Meeting = try await client
            .from("meetings")
            .insert(NewMeeting(
                user_id: user, title: title, location: location,
                source: source, status: "recording", started_at: Date()
            ))
            .select()
            .single()
            .execute()
            .value
        return row.id
    }

    private struct MeetingProgress: Encodable {
        var status: String
        var duration_ms: Int?
        var ended_at: Date?
        var error: String?
    }

    private func updateMeeting(_ id: UUID, _ patch: MeetingProgress) async throws {
        try await client.from("meetings").update(patch).eq("id", value: id).execute()
    }

    func markTranscribing(_ id: UUID, durationMs: Int) async throws {
        try await updateMeeting(id, MeetingProgress(
            status: "transcribing", duration_ms: durationMs, ended_at: Date(), error: nil
        ))
    }

    func markReady(_ id: UUID) async throws {
        try await updateMeeting(id, MeetingProgress(status: "ready"))
    }

    func markFailed(_ id: UUID, _ message: String) async throws {
        try await updateMeeting(id, MeetingProgress(status: "failed", error: message))
    }

    /// A meeting left in `recording` means the app died mid-capture: the audio
    /// is gone, so it will never finish. Without this they pile up in the list
    /// forever, each looking like it is still going.
    ///
    /// The cutoff is deliberately generous, so a genuinely long meeting running
    /// on another device is never mistaken for a corpse.
    func abandonStaleRecordings(olderThan hours: Int = 6) async throws {
        struct Patch: Encodable {
            let status = "failed"
            let error = "Recording was interrupted before it could be transcribed."
        }
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        try await client
            .from("meetings")
            .update(Patch())
            .eq("status", value: "recording")
            .lt("started_at", value: cutoff)
            .execute()
    }

    // MARK: - Live tags

    private struct NewLiveTag: Encodable {
        let user_id: UUID
        let meeting_id: UUID
        let name: String
        let at_ms: Int
    }

    /// Written as they happen, so a crash mid-meeting does not lose them.
    func addLiveTag(meeting: UUID, name: String, atMs: Int) async throws {
        guard let user = await userId else { return }
        try await client.from("live_tags")
            .insert(NewLiveTag(user_id: user, meeting_id: meeting, name: name, at_ms: atMs))
            .execute()
    }

    // MARK: - Transcript

    private struct NewSpeaker: Encodable {
        let user_id: UUID
        let meeting_id: UUID
        let label: String
    }

    private struct NewSegment: Encodable {
        let user_id: UUID
        let meeting_id: UUID
        let speaker_id: UUID
        let idx: Int
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    private struct SpeakerRow: Decodable { let id: UUID; let label: String }

    /// Store a finished transcript, then let the taps made during the meeting
    /// name the voices they landed on.
    ///
    /// - Returns: how many speakers a live tag managed to name.
    @discardableResult
    func saveTranscript(meeting: UUID, turns: [Turn]) async throws -> Int {
        guard let user = await userId else { throw ScribeError.transcription("Not signed in.") }

        let labels = Array(Set(turns.map(\.speaker))).sorted()
        let inserted: [SpeakerRow] = try await client
            .from("speakers")
            .insert(labels.map { NewSpeaker(user_id: user, meeting_id: meeting, label: $0) })
            .select("id,label")
            .execute()
            .value

        let idForLabel = Dictionary(uniqueKeysWithValues: inserted.map { ($0.label, $0.id) })

        let segments = turns.enumerated().compactMap { idx, turn -> NewSegment? in
            guard let speakerId = idForLabel[turn.speaker] else { return nil }
            return NewSegment(
                user_id: user, meeting_id: meeting, speaker_id: speakerId,
                idx: idx, start_ms: turn.startMs, end_ms: turn.endMs, text: turn.text
            )
        }
        try await client.from("segments").insert(segments).execute()

        return try await resolveLiveTags(meeting: meeting)
    }

    private struct ResolveArgs: Encodable {
        let p_meeting_id: UUID
        let p_window_ms: Int
    }

    @discardableResult
    func resolveLiveTags(meeting: UUID, windowMs: Int = 5_000) async throws -> Int {
        try await client
            .rpc("resolve_live_tags", params: ResolveArgs(p_meeting_id: meeting, p_window_ms: windowMs))
            .execute()
            .value
    }

    private struct NameArgs: Encodable {
        let p_meeting_id: UUID
        let p_label: String
        let p_name: String
    }

    func nameSpeaker(meeting: UUID, label: String, name: String) async throws {
        try await client
            .rpc("name_speaker", params: NameArgs(p_meeting_id: meeting, p_label: label, p_name: name))
            .execute()
    }

    // MARK: - Reading

    func meetings(limit: Int = 100) async throws -> [Meeting] {
        try await client.from("meetings")
            .select()
            .order("started_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    func transcript(meeting: UUID) async throws -> [TranscriptLine] {
        try await client.from("transcript_lines")
            .select("idx,start_ms,end_ms,text,speaker,speaker_label,resolved_by")
            .eq("meeting_id", value: meeting)
            .order("idx")
            .execute()
            .value
    }

    /// What went wrong with the live tags for a meeting: taps that matched no
    /// turn, and voices that several different people were tagged into.
    func tagProblems(meeting: UUID) async throws -> [TagProblem] {
        struct Args: Encodable { let p_meeting_id: UUID }
        return try await client
            .rpc("tag_problems", params: Args(p_meeting_id: meeting))
            .execute()
            .value
    }

    func people() async throws -> [Person] {
        try await client.from("people").select("id,name,note").order("name").execute().value
    }

    private struct NewPerson: Encodable {
        let user_id: UUID
        let name: String
    }

    func addPerson(named name: String) async throws -> Person {
        guard let user = await userId else { throw ScribeError.transcription("Not signed in.") }
        return try await client.from("people")
            .upsert(NewPerson(user_id: user, name: name), onConflict: "user_id,name")
            .select("id,name,note")
            .single()
            .execute()
            .value
    }

    func setNotes(meeting: UUID, notes: String) async throws {
        struct Patch: Encodable { let notes: String }
        try await client.from("meetings").update(Patch(notes: notes)).eq("id", value: meeting).execute()
    }

    func delete(meeting: UUID) async throws {
        try await client.from("meetings").delete().eq("id", value: meeting).execute()
    }
}
