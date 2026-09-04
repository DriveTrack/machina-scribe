import Foundation
import ScribeCore

/// Turns a speaker-attributed transcript into something worth reading later.
///
/// Summarising is a cheap, well-trodden task, so it runs on the low-cost Flash
/// tier by default: a one-hour meeting costs well under a cent. The model is a
/// setting because "good enough" is a judgement only the reader can make.
struct Summarizer: MeetingSummarizing {

    var label: String { model.label }
    /// The transcript is uploaded to Google.
    let isLocal = false


    enum Model: String, CaseIterable, Identifiable, Sendable {
        /// ~$0.006 for a one-hour meeting.
        case flashLite = "gemini-3.1-flash-lite"
        /// ~6x the cost, better at teasing apart who committed to what.
        case flash = "gemini-3.5-flash"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .flashLite: "Cheaper — Flash Lite"
            case .flash:     "Sharper — Flash"
            }
        }
    }

    private let apiKey: String
    private let model: Model
    private let session: URLSession

    init(apiKey: String, model: Model = .flashLite, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// The schema is enforced by the API rather than parsed hopefully out of
    /// prose, so a malformed summary fails loudly instead of arriving empty.
    private var responseSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Three to six words naming what this meeting was about. No date, no the word 'meeting', no trailing punctuation."
                ],
                "summary": [
                    "type": "string",
                    "description": "Two or three sentences on what this meeting was for and where it landed."
                ],
                "topics": [
                    "type": "array", "items": ["type": "string"],
                    "description": "The subjects actually discussed, a few words each."
                ],
                "decisions": [
                    "type": "array", "items": ["type": "string"],
                    "description": "Things settled. Include who settled them when the transcript says."
                ],
                "action_items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "task": ["type": "string"],
                            "owner": ["type": "string", "description": "Speaker who took it on, or empty if unclear."],
                            "due": ["type": "string", "description": "Timing in the transcript's own words, or empty."]
                        ],
                        "required": ["task"]
                    ]
                ],
                "open_questions": [
                    "type": "array", "items": ["type": "string"],
                    "description": "Raised but unresolved."
                ]
            ],
            "required": ["title", "summary", "topics", "decisions", "action_items", "open_questions"]
        ]
    }

    private static let instructions = """
    You are summarising the transcript of an in-person meeting for the person \
    who recorded it. They will read this later to remember what happened and \
    what they owe people.

    Rules:
    - Use only what the transcript says. Never invent a decision, an owner or a \
    deadline. If nobody was named as owning something, leave the owner empty.
    - Attribute using the speaker names in the transcript.
    - An action item is something a person committed to doing. Vague intentions \
    ("we should probably look at that") are not action items; put them under \
    open questions instead.
    - Prefer the speaker's own words for a deadline over a calendar date.
    - Be concise. This is a record, not an essay. If a section has nothing in \
    it, return an empty list rather than padding it.
    - The transcript comes from automatic speech recognition, so expect \
    mis-heard words. Read through obvious errors rather than quoting them.
    - The title should name the subject, not describe the artefact. "Q4 \
    migration timing" is useful; "Meeting about the project" is not.
    """

    func summarize(title: String?, transcript: String, notes: String?) async throws -> MeetingSummary {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScribeError.transcription("There is no transcript to summarise.")
        }

        var prompt = "Meeting: \(title?.isEmpty == false ? title! : "Untitled")\n\n"
        if let notes, !notes.isEmpty {
            prompt += "Notes the recorder typed during the meeting:\n\(notes)\n\n"
        }
        prompt += "Transcript:\n\(transcript)"

        let payload: [String: Any] = [
            "system_instruction": ["parts": [["text": Self.instructions]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json",
                "responseSchema": responseSchema
            ]
        ]

        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent")!
        )
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (body, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ScribeError.http(http.statusCode, String(decoding: body, as: UTF8.self))
        }

        struct Envelope: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: body)
        guard let text = envelope.candidates?.first?.content?.parts?.first?.text,
              let data = text.data(using: .utf8)
        else {
            throw ScribeError.transcription("The model returned no summary.")
        }

        return try JSONDecoder().decode(MeetingSummary.self, from: data)
    }
}
