import Foundation

/// Pushes a finished meeting into a Notion database.
///
/// Only the title property is written. Databases differ wildly in what columns
/// they have, and guessing at them is how an export silently lands in the wrong
/// field -- so everything else goes into the page body, where it always reads
/// correctly. A date property is filled only when the database has exactly one,
/// which is unambiguous.
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

    /// The name of the destination's title column, plus a date column when
    /// there is exactly one to be sure about.
    private func schema(of destination: Destination) async throws -> (title: String, date: String?) {
        let path = destination.isDataSource
            ? "/v1/data_sources/\(destination.id)"
            : "/v1/databases/\(destination.id)"
        let data = try await call("GET", path, body: nil)

        struct Schema: Decodable {
            struct Property: Decodable { let type: String }
            let properties: [String: Property]
        }
        let schema = try JSONDecoder().decode(Schema.self, from: data)

        guard let title = schema.properties.first(where: { $0.value.type == "title" })?.key else {
            throw ScribeError.transcription("That Notion database has no title column.")
        }
        let dates = schema.properties.filter { $0.value.type == "date" }.map(\.key)
        return (title, dates.count == 1 ? dates.first : nil)
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

        var properties: [String: Any] = [
            columns.title: ["title": [["text": ["content": title]]]]
        ]
        if let dateColumn = columns.date {
            properties[dateColumn] = [
                "date": ["start": ISO8601DateFormatter().string(from: startedAt)]
            ]
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
        return Result(pageId: page.id, url: page.url ?? "https://notion.so/\(page.id.replacingOccurrences(of: "-", with: ""))")
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

        out.append(heading("Transcript"))
        // Notion caps a rich text item at 2000 characters and a request at 100
        // blocks, so the transcript is split and, if need be, truncated with a
        // note rather than silently cut off.
        let paragraphs = chunk(transcript, limit: 1_900)
        let room = max(0, 95 - out.count)
        for piece in paragraphs.prefix(room) {
            out.append(paragraph(piece))
        }
        if paragraphs.count > room {
            out.append(paragraph(
                "The rest of the transcript was too long for one Notion page; "
                + "it is complete in Scribe.",
                italic: true
            ))
        }
        return out
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
