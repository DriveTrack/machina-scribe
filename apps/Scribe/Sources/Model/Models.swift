import Foundation

struct Meeting: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String?
    var location: String?
    var startedAt: Date
    var endedAt: Date?
    var durationMs: Int?
    var source: String?
    var status: String
    var error: String?
    var notes: String?
    var summary: String?
    var notionURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, location, source, status, error, notes, summary
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMs = "duration_ms"
        case notionURL = "notion_url"
    }

    var displayTitle: String { title?.isEmpty == false ? title! : "Untitled meeting" }
}

struct Person: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var note: String?
}

/// A row of `transcript_lines`: a turn with its speaker already resolved.
struct TranscriptLine: Codable, Identifiable, Hashable, Sendable {
    var idx: Int
    var startMs: Int
    var endMs: Int
    var text: String
    var speaker: String
    var speakerLabel: String?
    var resolvedBy: String?

    var id: Int { idx }

    enum CodingKeys: String, CodingKey {
        case idx, text, speaker
        case startMs = "start_ms"
        case endMs = "end_ms"
        case speakerLabel = "speaker_label"
        case resolvedBy = "resolved_by"
    }

    var timecode: String {
        let total = max(0, startMs / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

/// A tap made during the meeting: "the person talking right now is X".
struct LiveTag: Identifiable, Hashable, Sendable {
    let id = UUID()
    var name: String
    var atMs: Int
}

/// A live tag that could not be applied cleanly.
struct TagProblem: Codable, Identifiable, Hashable, Sendable {
    /// "unmatched" — the tap matched no turn, so that name was never applied.
    /// "conflict"  — several people were tagged into a single diarized voice.
    var kind: String
    var detail: String?
    var atMs: Int?

    var id: String { "\(kind)-\(detail ?? "")-\(atMs ?? -1)" }

    enum CodingKeys: String, CodingKey {
        case kind, detail
        case atMs = "at_ms"
    }

    var isConflict: Bool { kind == "conflict" }
}
