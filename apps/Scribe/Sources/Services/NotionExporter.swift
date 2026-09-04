import Foundation
import ScribeCore

/// Pushes a finished meeting into a Notion database.
///
/// Columns are filled only when the destination actually has one of the right
/// name *and* type. Guessing at unfamiliar columns is how an export lands
/// silently in the wrong field, so anything unrecognised is left alone and the
/// full content always goes into the page body, where it reads correctly
/// regardless of how the database is set up.
struct NotionExporter {

    struct Destination: Identifiable, Hashable, Sendable, Codable {
        /// A data source id under the current API; a database id under the old
        /// one. Notion accepts either as a page parent.
        let id: String
        let title: String
        let isDataSource: Bool
    }

    struct Result: Sendable {
        let pageId: String
        let url: String
    }

    /// Pinned: Notion changes response shapes between versions, and the data
    /// source model this uses arrived in this one.
    private static let apiVersion = "2025-09-03"

    private let token: String
    private let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    // MARK: - Discovery

    /// Databases the integration has been given access to.
    ///
    /// Notion only shares what the user explicitly connects, so an empty list
    /// almost always means they have not shared the database with the
    /// integration yet -- worth saying plainly in the UI.
    func destinations() async throws -> [Destination] {
        var found: [Destination] = []

        for target in ["data_source", "database"] {
            let body: [String: Any] = [
                "filter": ["property": "object", "value": target],
                "page_size": 100
            ]
            guard let data = try? await call("POST", "/v1/search", body: body) else { continue }

            struct Search: Decodable {
                struct Item: Decodable {
                    let id: String
                    let object: String
                    let title: [RichText]?
                    struct RichText: Decodable { let plain_text: String? }
                }
                let results: [Item]
            }
            guard let search = try? JSONDecoder().decode(Search.self, from: data) else { continue }

            for item in search.results {
                let name = item.title?.compactMap(\.plain_text).joined() ?? ""
                found.append(
                    Destination(
                        id: item.id,
                        title: name.isEmpty ? "Untitled database" : name,
                        isDataSource: item.object == "data_source"
                    )
                )
            }
            // Prefer data sources; only fall back if the workspace has none.
            if !found.isEmpty { break }
        }

        return found
    }

    /// What columns the destination actually has, keyed by name.
    private func schema(of destination: Destination) async throws -> [String: String] {
        let path = destination.isDataSource
            ? "/v1/data_sources/\(destination.id)"
            : "/v1/databases/\(destination.id)"
        let data = try await call("GET", path, body: nil)

        struct Schema: Decodable {
            struct Property: Decodable { let type: String }
            let properties: [String: Property]
        }
        return try JSONDecoder().decode(Schema.self, from: data).properties.mapValues(\.type)
    }

    /// Find a column by any of several likely names, but only accept it if the
    /// type matches -- writing a date into a text column would fail the whole
    /// request, and writing into a same-named column of the wrong meaning is
    /// worse than writing nothing.
    private func column(
        _ columns: [String: String], named candidates: [String], type: String
    ) -> String? {
        for candidate in candidates {
            if let match = columns.first(where: {
                $0.key.caseInsensitiveCompare(candidate) == .orderedSame && $0.value == type
            }) {
                return match.key
            }
        }
        return nil
    }

    // MARK: - Export

    func export(
        to destination: Destination,
        title: String,
        startedAt: Date,
        durationMs: Int?,
        speakers: [String],
        summary: MeetingSummary?,
        notes: String?,
        transcript: String
    ) async throws -> Result {
        let columns = try await schema(of: destination)

        guard let titleColumn = columns.first(where: { $0.value == "title" })?.key else {
            throw ScribeError.transcription("That Notion database has no title column.")
        }

        var properties: [String: Any] = [
            titleColumn: ["title": [["text": ["content": title]]]]
        ]

        if let date = column(columns, named: ["Date", "Meeting date", "When"], type: "date") {
            properties[date] = ["date": ["start": ISO8601DateFormatter().string(from: startedAt)]]
        }
        if let minutes = column(columns, named: ["Duration (min)", "Duration", "Length"], type: "number"),
           let durationMs {
            properties[minutes] = ["number": max(1, durationMs / 60_000)]
        }
        if let who = column(columns, named: ["Attendees", "Speakers", "People"], type: "multi_select"),
           !speakers.isEmpty {
            properties[who] = ["multi_select": speakers.map { ["name": $0] }]
        }
        if let brief = column(columns, named: ["Summary", "Notes", "Overview"], type: "rich_text"),
           let summary {
            properties[brief] = [
                "rich_text": [["text": ["content": String(summary.summary.prefix(1_900))]]]
            ]
        }
        if let count = column(columns, named: ["Action items", "Actions"], type: "number") {
            properties[count] = ["number": summary?.actionItems.count ?? 0]
        }
        if let source = column(columns, named: ["Source", "Device"], type: "select") {
            properties[source] = ["select": ["name": "Scribe"]]
        }

        let parent: [String: Any] = destination.isDataSource
            ? ["data_source_id": destination.id]
            : ["database_id": destination.id]

        let body: [String: Any] = [
            "parent": parent,
            "properties": properties,
            "children": blocks(
                startedAt: startedAt, durationMs: durationMs, speakers: speakers,
                summary: summary, notes: notes, transcript: transcript
            )
        ]

        let data = try await call("POST", "/v1/pages", body: body)
        struct Page: Decodable { let id: String; let url: String? }
        let page = try JSONDecoder().decode(Page.self, from: data)

        try await fillTranscript(page: page.id, transcript: transcript)

        return Result(pageId: page.id, url: page.url ?? "https://notion.so/\(page.id.replacingOccurrences(of: "-", with: ""))")
    }

    /// Append the whole transcript into the toggle, 100 blocks at a time.
    ///
    /// Notion accepts at most 100 children per request and 2000 characters per
    /// rich text item, so a two-hour meeting cannot go in with the page. It
    /// goes in afterwards, in batches, and nothing is dropped.
    private func fillTranscript(page: String, transcript: String) async throws {
        let paragraphs = chunk(transcript, limit: 1_900)
        guard !paragraphs.isEmpty else { return }

        let children = try await call("GET", "/v1/blocks/\(page)/children", body: nil)
        struct Children: Decodable {
            struct Block: Decodable { let id: String; let type: String }
            let results: [Block]
        }
        guard let toggle = try JSONDecoder().decode(Children.self, from: children)
            .results.first(where: { $0.type == "toggle" })?.id
        else { return }

        for batch in stride(from: 0, to: paragraphs.count, by: 100) {
            let slice = paragraphs[batch..<min(batch + 100, paragraphs.count)]
            _ = try await call("PATCH", "/v1/blocks/\(toggle)/children", body: [
                "children": slice.map { paragraph($0) }
            ])
        }
    }

    // MARK: - Page content

    private func blocks(
        startedAt: Date,
        durationMs: Int?,
        speakers: [String],
        summary: MeetingSummary?,
        notes: String?,
        transcript: String
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []

        var meta = startedAt.formatted(date: .abbreviated, time: .shortened)
        if let durationMs { meta += " · \(max(1, durationMs / 60_000)) min" }
        if !speakers.isEmpty { meta += " · \(speakers.joined(separator: ", "))" }
        out.append(paragraph(meta, italic: true))

        if let summary {
            out.append(heading("Summary"))
            out.append(paragraph(summary.summary))

            // The full transcript sits directly under the summary, but folded
            // away. Ninety thousand characters placed openly between the
            // summary and the action items would bury everything worth
            // reading; a toggle keeps it one click from the summary without
            // pushing the rest off the page.
            out.append(transcriptToggle)

            if !summary.actionItems.isEmpty {
                out.append(heading("Action items"))
                for item in summary.actionItems {
                    var line = item.task
                    if let owner = item.owner, !owner.isEmpty { line += " — \(owner)" }
                    if let due = item.due, !due.isEmpty { line += " (\(due))" }
                    // A to-do, not a bullet: these are things someone owes.
                    out.append([
                        "object": "block", "type": "to_do",
                        "to_do": ["rich_text": [["text": ["content": line]]], "checked": false]
                    ])
                }
            }

            if !summary.decisions.isEmpty {
                out.append(heading("Decisions"))
                summary.decisions.forEach { out.append(bullet($0)) }
            }
            if !summary.openQuestions.isEmpty {
                out.append(heading("Open questions"))
                summary.openQuestions.forEach { out.append(bullet($0)) }
            }
        }

        if let notes, !notes.isEmpty {
            out.append(heading("My notes"))
            out.append(paragraph(notes))
        }

        // When there is no summary there is no toggle either, so the
        // transcript still needs a home.
        if summary == nil {
            out.append(transcriptToggle)
        }
        return out
    }

    /// An empty, collapsed container. The transcript is appended into it after
    /// the page exists, because a page can only be created with 100 blocks and
    /// a long meeting runs to several hundred.
    private var transcriptToggle: [String: Any] {
        [
            "object": "block", "type": "toggle",
            "toggle": [
                "rich_text": [["text": ["content": "Full transcript"]]],
                "children": []
            ]
        ]
    }

    private func heading(_ text: String) -> [String: Any] {
        ["object": "block", "type": "heading_2",
         "heading_2": ["rich_text": [["text": ["content": text]]]]]
    }

    private func paragraph(_ text: String, italic: Bool = false) -> [String: Any] {
        ["object": "block", "type": "paragraph",
         "paragraph": ["rich_text": [[
            "text": ["content": String(text.prefix(1_900))],
            "annotations": ["italic": italic]
         ]]]]
    }

    private func bullet(_ text: String) -> [String: Any] {
        ["object": "block", "type": "bulleted_list_item",
         "bulleted_list_item": ["rich_text": [["text": ["content": String(text.prefix(1_900))]]]]]
    }

    /// Split on line breaks first so speaker turns stay whole; only cut mid-run
    /// when a single turn is itself over the limit.
    private func chunk(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > limit {
                if !current.isEmpty { out.append(current); current = "" }
                if line.count > limit {
                    var rest = Substring(line)
                    while !rest.isEmpty {
                        out.append(String(rest.prefix(limit)))
                        rest = rest.dropFirst(limit)
                    }
                    continue
                }
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Transport

    private func call(_ method: String, _ path: String, body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.notion.com\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Notion's messages are actually useful; pass them straight through.
            struct Failure: Decodable { let message: String? }
            let detail = (try? JSONDecoder().decode(Failure.self, from: data))?.message
            throw ScribeError.http(http.statusCode, detail ?? String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
