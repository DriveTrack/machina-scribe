import Foundation
import ScribeCore

/// The local-first store: every meeting lives in one SQLite file on this
/// device, and nothing is uploaded.
///
/// This is the default, and the reason the app can honestly say a meeting never
/// leaves the machine. Transcription and speaker separation already run here;
/// storing the result on somebody's server would have made that claim untrue
/// for the only artefact anyone actually reads.
///
/// The schema mirrors the Postgres one so an optional sync can map row for row
/// -- minus `user_id`, which scoped rows to an account. There is exactly one
/// user of a file in your own home directory, and the column would be a
/// constant repeated a hundred thousand times.
@MainActor
final class LocalStore {

    private let db: SQLite
    let fileURL: URL

    /// `~/Library/Application Support/Scribe/scribe.sqlite` -- inside the app's
    /// container when sandboxed, which is where a user's own data belongs and
    /// what gets carried by a Mac migration.
    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Scribe", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("scribe.sqlite")
    }

    init(url: URL) throws {
        fileURL = url
        db = try SQLite(path: url.path)
        try migrate()
    }

    convenience init() throws {
        try self.init(url: try Self.defaultURL())
    }

    // MARK: - Schema

    private func migrate() throws {
        try db.execute("""
        create table if not exists people (
          id         text primary key collate nocase,
          name       text not null,
          note       text,
          created_at text not null
        );
        -- Names are matched case-insensitively, the way people type them:
        -- tagging "jose" and "Jose" in one meeting is one person, not two.
        create unique index if not exists people_name on people (lower(name));

        create table if not exists meetings (
          id            text primary key collate nocase,
          title         text,
          location      text,
          started_at    text not null,
          ended_at      text,
          duration_ms   integer,
          source        text,
          status        text not null,
          error         text,
          notes         text,
          summary       text,
          summary_json  text,
          summarized_at text,
          notion_page_id text,
          notion_url    text,
          exported_at   text,
          created_at    text not null,
          updated_at    text not null
        );
        create index if not exists meetings_started on meetings (started_at desc);

        create table if not exists speakers (
          id             text primary key collate nocase,
          meeting_id     text not null collate nocase references meetings(id) on delete cascade,
          label          text not null,
          person_id      text collate nocase references people(id) on delete set null,
          resolved_by    text,
          match_delta_ms integer,
          created_at     text not null
        );
        create unique index if not exists speakers_label on speakers (meeting_id, label);

        create table if not exists segments (
          id         text primary key collate nocase,
          meeting_id text not null collate nocase references meetings(id) on delete cascade,
          speaker_id text collate nocase references speakers(id) on delete set null,
          idx        integer not null,
          start_ms   integer not null,
          end_ms     integer not null,
          text       text not null
        );
        create unique index if not exists segments_idx on segments (meeting_id, idx);

        create table if not exists live_tags (
          id         text primary key collate nocase,
          meeting_id text not null collate nocase references meetings(id) on delete cascade,
          name       text not null,
          at_ms      integer not null,
          resolved_speaker_id text collate nocase references speakers(id) on delete set null,
          created_at text not null
        );

        create table if not exists meeting_attendees (
          id         text primary key collate nocase,
          meeting_id text not null collate nocase references meetings(id) on delete cascade,
          name       text not null,
          created_at text not null
        );
        """)

        // Full-text search over turns, kept in step by triggers rather than
        // rebuilt: a two-hour meeting is ~1500 rows and reindexing all of them
        // on every edit would be felt.
        try db.execute("""
        create virtual table if not exists segments_fts using fts5(
          text, content='segments', content_rowid='rowid',
          -- Porter stemming, so searching "transcript" finds "transcripts"
          -- and "transcription". Without it FTS matches whole tokens only:
          -- "transcript" returned nothing on a meeting that says the word
          -- twice, which reads as broken search rather than a strict one.
          tokenize='porter unicode61'
        );
        create trigger if not exists segments_ai after insert on segments begin
          insert into segments_fts(rowid, text) values (new.rowid, new.text);
        end;
        create trigger if not exists segments_ad after delete on segments begin
          insert into segments_fts(segments_fts, rowid, text) values ('delete', old.rowid, old.text);
        end;
        create trigger if not exists segments_au after update on segments begin
          insert into segments_fts(segments_fts, rowid, text) values ('delete', old.rowid, old.text);
          insert into segments_fts(rowid, text) values (new.rowid, new.text);
        end;
        """)
    }

    private func now() -> SQLite.Value { .init(Date()) }
    private func newId() -> String { UUID().uuidString }

    // MARK: - Keeping the file copyable

    /// Fold the write-ahead log back into the main file.
    ///
    /// Write-ahead logging means a recent transcript can live entirely in
    /// `scribe.sqlite-wal` and not in `scribe.sqlite` at all. Anyone who backs
    /// this up the obvious way -- copy the .sqlite, drag it to a drive -- would
    /// silently take a snapshot missing their newest meetings. That is exactly
    /// what happened the first time a copy of this database was taken during
    /// development, and the copy came back with zero rows.
    ///
    /// Cheap, and worth doing whenever the app is about to stop being used.
    func checkpoint() {
        try? db.execute("pragma wal_checkpoint(truncate)")
    }

    /// A consistent single-file snapshot, WAL included.
    ///
    /// `vacuum into` rather than a file copy: it takes a read lock, writes one
    /// complete database, and cannot catch a half-finished transaction. The
    /// result is a plain SQLite file that opens anywhere.
    func backup(to destination: URL) throws {
        // vacuum refuses to overwrite, which is the behaviour we want -- but
        // the caller has usually just picked a filename in a save panel and
        // been asked about replacing it already.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        try db.execute("vacuum into '\(escaped)'")
    }

    // MARK: - Recording lifecycle

    func startMeeting(title: String?, location: String?) async throws -> UUID {
        #if os(iOS)
        let source = "ios"
        #else
        let source = "macos"
        #endif
        let id = UUID()
        try db.run("""
            insert into meetings (id, title, location, started_at, source, status, created_at, updated_at)
            values (?, ?, ?, ?, ?, 'recording', ?, ?)
            """,
            [.init(id), .init(title), .init(location), now(), .text(source), now(), now()])
        return id
    }

    func markTranscribing(_ id: UUID, durationMs: Int) async throws {
        try db.run("""
            update meetings set status = 'transcribing', duration_ms = ?, ended_at = ?,
                                error = null, updated_at = ? where id = ?
            """, [.init(durationMs), now(), now(), .init(id)])
    }

    func markReady(_ id: UUID) async throws {
        try db.run("update meetings set status = 'ready', updated_at = ? where id = ?",
                   [now(), .init(id)])
    }

    func markFailed(_ id: UUID, _ message: String) async throws {
        try db.run("update meetings set status = 'failed', error = ?, updated_at = ? where id = ?",
                   [.init(message), now(), .init(id)])
    }

    /// A meeting still marked `recording` means the app died mid-capture, so it
    /// will never finish on its own. Without this they pile up in the list, each
    /// looking like it is still going. The cutoff is generous so a genuinely
    /// long meeting is never mistaken for a corpse.
    func abandonStaleRecordings(olderThan hours: Int = 6) async throws {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        try db.run("""
            update meetings set status = 'failed',
              error = 'Recording was interrupted before it could be transcribed.',
              updated_at = ?
            where status = 'recording' and started_at < ?
            """, [now(), .init(cutoff)])
    }

    // MARK: - Live tags

    func addLiveTag(meeting: UUID, name: String, atMs: Int) async throws {
        try db.run("""
            insert into live_tags (id, meeting_id, name, at_ms, created_at) values (?, ?, ?, ?, ?)
            """,
            [.text(newId()), .init(meeting), .init(name), .init(atMs), now()])
    }

    // MARK: - Transcript

    /// Store a finished transcript, then let the taps made during the meeting
    /// name the voices they landed on.
    ///
    /// One transaction: speakers and a thousand-odd segments land together or
    /// not at all. Half a transcript on disk would look complete and read as
    /// though the meeting stopped early -- the exact failure the PostgREST
    /// paging bug produced once already.
    ///
    /// - Returns: how many speakers a live tag managed to name.
    @discardableResult
    func saveTranscript(meeting: UUID, turns: [Turn]) async throws -> Int {
        try db.transaction {
            // Replacing rather than appending, so re-transcribing a meeting
            // does not leave the old turns interleaved with the new ones.
            try db.run("delete from segments where meeting_id = ?", [.init(meeting)])
            try db.run("delete from speakers where meeting_id = ?", [.init(meeting)])

            var idForLabel: [String: String] = [:]
            for label in Set(turns.map(\.speaker)).sorted() {
                let id = newId()
                idForLabel[label] = id
                try db.run("""
                    insert into speakers (id, meeting_id, label, created_at) values (?, ?, ?, ?)
                    """, [.text(id), .init(meeting), .init(label), now()])
            }

            for (idx, turn) in turns.enumerated() {
                try db.run("""
                    insert into segments (id, meeting_id, speaker_id, idx, start_ms, end_ms, text)
                    values (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(newId()), .init(meeting), .init(idForLabel[turn.speaker]),
                     .init(idx), .init(turn.startMs), .init(turn.endMs), .init(turn.text)])
            }
        }
        return try await resolveLiveTags(meeting: meeting)
    }

    /// Turn the taps made during the meeting into named speakers.
    ///
    /// A tap lands inside the turn of whoever was talking, so the segment
    /// containing it identifies the voice -- and naming that voice names every
    /// turn it ever speaks. One tap, whole meeting.
    ///
    /// Manual names always win; this never overwrites a human correction.
    @discardableResult
    func resolveLiveTags(meeting: UUID, windowMs: Int = 5_000) async throws -> Int {
        struct Hit { let tagId: String; let name: String; let speakerId: String; let delta: Int }

        let tags = try db.run(
            "select id, name, at_ms from live_tags where meeting_id = ?", [.init(meeting)])
        let segments = try db.run("""
            select speaker_id, idx, start_ms, end_ms from segments
            where meeting_id = ? and speaker_id is not null order by idx
            """, [.init(meeting)])

        var best: [String: Hit] = [:]   // speakerId -> the tap that fits it best
        for tag in tags {
            guard let tagId = tag.string("id"),
                  let name = tag.string("name"),
                  let at = tag.int("at_ms") else { continue }

            var chosen: Hit?
            for segment in segments {
                guard let speakerId = segment.string("speaker_id"),
                      let start = segment.int("start_ms"),
                      let end = segment.int("end_ms"),
                      end >= at - windowMs, start <= at + windowMs else { continue }

                let delta: Int
                if at >= start && at <= end {
                    delta = 0
                } else if at > end {
                    // The tap landed after a turn ended: you reached for the
                    // button as they were finishing. Very likely still them.
                    delta = at - end
                } else {
                    // Before a turn began. Possible, but reaction lag makes
                    // "whoever just stopped" the better bet than "whoever is
                    // about to start", so weight it against.
                    delta = (start - at) * 3
                }
                if chosen == nil || delta < chosen!.delta {
                    chosen = Hit(tagId: tagId, name: name, speakerId: speakerId, delta: delta)
                }
            }
            guard let hit = chosen else { continue }
            // One meeting can carry several taps for the same voice; trust the
            // one that landed most squarely inside a turn.
            if best[hit.speakerId] == nil || hit.delta < best[hit.speakerId]!.delta {
                best[hit.speakerId] = hit
            }
        }

        var updated = 0
        try db.transaction {
            for (speakerId, hit) in best {
                let personId = try upsertPerson(named: hit.name)
                let rows = try db.run("""
                    update speakers set person_id = ?, resolved_by = 'live_tag', match_delta_ms = ?
                    where id = ? and coalesce(resolved_by, '') <> 'manual'
                    returning id
                    """, [.text(personId), .init(hit.delta), .text(speakerId)])
                updated += rows.count
                try db.run("update live_tags set resolved_speaker_id = ? where id = ?",
                           [.text(speakerId), .text(hit.tagId)])
            }
        }
        return updated
    }

    /// Attach a human name to one diarized voice.
    ///
    /// Segments point at the speaker row rather than carrying a name, so this
    /// renames every turn in the meeting -- past and future -- in one write.
    func nameSpeaker(meeting: UUID, label: String, name: String) async throws {
        try db.transaction {
            let personId = try upsertPerson(named: name)
            let rows = try db.run("""
                update speakers set person_id = ?, resolved_by = 'manual', match_delta_ms = null
                where meeting_id = ? and label = ? returning id
                """, [.text(personId), .init(meeting), .init(label)])
            guard !rows.isEmpty else {
                throw ScribeError.transcription("No speaker \(label) in this meeting.")
            }
        }
    }

    @discardableResult
    private func upsertPerson(named name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = try db.run(
            "select id from people where lower(name) = lower(?)", [.init(trimmed)]
        ).first?.string("id") {
            return existing
        }
        let id = newId()
        try db.run("insert into people (id, name, created_at) values (?, ?, ?)",
                   [.text(id), .init(trimmed), now()])
        return id
    }

    // MARK: - Reading

    func meetings(limit: Int = 100) async throws -> [Meeting] {
        try db.run("select * from meetings order by started_at desc limit ?", [.init(limit)])
            .map(Self.meeting(from:))
    }

    func meeting(_ id: UUID) async throws -> Meeting? {
        try db.run("select * from meetings where id = ?", [.init(id)]).first.map(Self.meeting(from:))
    }

    private static func meeting(from row: SQLite.Row) -> Meeting {
        Meeting(
            id: row.uuid("id") ?? UUID(),
            title: row.string("title"),
            location: row.string("location"),
            startedAt: row.date("started_at") ?? Date(),
            endedAt: row.date("ended_at"),
            durationMs: row.int("duration_ms"),
            source: row.string("source"),
            status: row.string("status") ?? "ready",
            error: row.string("error"),
            notes: row.string("notes"),
            summary: row.string("summary"),
            notionURL: row.string("notion_url")
        )
    }

    /// The whole transcript. No paging: this reads a local file, so the 1000-row
    /// ceiling that silently truncated a meeting over the network does not
    /// exist here.
    func transcript(meeting: UUID) async throws -> [TranscriptLine] {
        try db.run("""
            select s.idx, s.start_ms, s.end_ms, s.text,
                   sp.label as speaker_label, sp.resolved_by,
                   coalesce(p.name, sp.label) as speaker
            from segments s
            left join speakers sp on sp.id = s.speaker_id
            left join people   p  on p.id  = sp.person_id
            where s.meeting_id = ? order by s.idx
            """, [.init(meeting)])
            .map {
                TranscriptLine(
                    idx: $0.int("idx") ?? 0,
                    startMs: $0.int("start_ms") ?? 0,
                    endMs: $0.int("end_ms") ?? 0,
                    text: $0.string("text") ?? "",
                    speaker: $0.string("speaker") ?? "Speaker",
                    speakerLabel: $0.string("speaker_label"),
                    resolvedBy: $0.string("resolved_by")
                )
            }
    }

    /// Taps that matched no turn, and voices several different people were
    /// tagged into.
    func tagProblems(meeting: UUID) async throws -> [TagProblem] {
        var problems = try db.run("""
            select name, at_ms from live_tags
            where meeting_id = ? and resolved_speaker_id is null order by at_ms
            """, [.init(meeting)])
            .map { TagProblem(kind: "unmatched", detail: $0.string("name"), atMs: $0.int("at_ms")) }

        // Two different names tapped onto one voice: either a mis-tap, or the
        // diarizer merged two people. Worth surfacing either way.
        problems += try db.run("""
            select sp.label, group_concat(distinct t.name) as names
            from speakers sp join live_tags t on t.resolved_speaker_id = sp.id
            where sp.meeting_id = ?
            group by sp.id having count(distinct lower(t.name)) > 1
            """, [.init(meeting)])
            .map { TagProblem(kind: "conflict", detail: $0.string("names"), atMs: nil) }

        return problems
    }

    func search(_ query: String, limit: Int = 50) async throws -> [(meeting: UUID, idx: Int, text: String)] {
        // FTS5 MATCH takes a query language, not a string: a stray quote,
        // hyphen or `NOT` from someone typing a normal phrase is a syntax
        // error, and the search would fail rather than find nothing. Quote
        // each word as a literal and AND them together.
        let terms = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\"\($0)\"" }
        guard !terms.isEmpty else { return [] }
        let match = terms.joined(separator: " AND ")

        return try db.run("""
            select s.meeting_id, s.idx, s.text from segments_fts f
            join segments s on s.rowid = f.rowid
            where segments_fts match ? order by rank limit ?
            """, [.init(match), .init(limit)])
            .compactMap {
                guard let m = $0.uuid("meeting_id"), let i = $0.int("idx"), let t = $0.string("text")
                else { return nil }
                return (m, i, t)
            }
    }

    func people() async throws -> [Person] {
        try db.run("select id, name, note from people order by name").compactMap {
            guard let id = $0.uuid("id"), let name = $0.string("name") else { return nil }
            return Person(id: id, name: name, note: $0.string("note"))
        }
    }

    func addPerson(named name: String) async throws -> Person {
        let id = try upsertPerson(named: name)
        guard let row = try db.run("select id, name, note from people where id = ?", [.text(id)]).first,
              let uuid = row.uuid("id"), let stored = row.string("name")
        else { throw ScribeError.transcription("Could not save that name.") }
        return Person(id: uuid, name: stored, note: row.string("note"))
    }

    // MARK: - Attendees

    func setAttendees(meeting: UUID, names: [String]) async throws {
        try db.transaction {
            try db.run("delete from meeting_attendees where meeting_id = ?", [.init(meeting)])
            for name in names {
                try db.run("""
                    insert into meeting_attendees (id, meeting_id, name, created_at)
                    values (?, ?, ?, ?)
                    """, [.text(newId()), .init(meeting), .init(name), now()])
            }
        }
    }

    func attendees(meeting: UUID) async throws -> [String] {
        try db.run(
            "select name from meeting_attendees where meeting_id = ? order by created_at",
            [.init(meeting)]
        ).compactMap { $0.string("name") }
    }

    // MARK: - Summary and export

    func saveSummary(meeting: UUID, _ summary: MeetingSummary) async throws {
        let json = try JSONEncoder().encode(summary)
        try db.run("""
            update meetings set summary = ?, summary_json = ?, summarized_at = ?, updated_at = ?
            where id = ?
            """,
            [.init(summary.summary), .init(String(data: json, encoding: .utf8)),
             now(), now(), .init(meeting)])
    }

    func summary(meeting: UUID) async throws -> MeetingSummary? {
        guard let json = try db.run("select summary_json from meetings where id = ?", [.init(meeting)])
            .first?.string("summary_json"), let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    func recordNotionExport(meeting: UUID, pageId: String, url: String) async throws {
        try db.run("""
            update meetings set notion_page_id = ?, notion_url = ?, exported_at = ?, updated_at = ?
            where id = ?
            """, [.init(pageId), .init(url), now(), now(), .init(meeting)])
    }

    func setTitle(meeting: UUID, title: String) async throws {
        try db.run("update meetings set title = ?, updated_at = ? where id = ?",
                   [.init(title), now(), .init(meeting)])
    }

    func setNotes(meeting: UUID, notes: String) async throws {
        try db.run("update meetings set notes = ?, updated_at = ? where id = ?",
                   [.init(notes), now(), .init(meeting)])
    }

    func delete(meeting: UUID) async throws {
        try db.run("delete from meetings where id = ?", [.init(meeting)])
    }
}
