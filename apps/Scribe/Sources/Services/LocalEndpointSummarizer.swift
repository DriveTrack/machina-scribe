import Foundation
import ScribeCore

/// Summarises through any OpenAI-compatible server running on this machine --
/// Ollama, LM Studio, llama.cpp, vLLM.
///
/// The quality tier for anything the on-device model is too small for. A 4B
/// model at 4-bit holds a whole 111-minute meeting in one pass, so there is no
/// map-reduce and nothing lost between windows.
///
/// Out of process on purpose. Loading those weights inside this app would keep
/// two-odd gigabytes resident for as long as the app is open, on a machine that
/// is often already swapping; a separate server can be started for one summary
/// and told to unload afterwards, and if it dies it takes nothing with it.
///
/// Nothing leaves the machine: the endpoint is localhost by default, and the
/// app refuses to treat a remote one as local so the "nothing was uploaded"
/// claim in the UI stays true.
struct LocalEndpointSummarizer: MeetingSummarizing {

    var label: String { "\(model) via \(endpoint.host() ?? "local server")" }

    /// Only when it really is this machine. Someone pointing the setting at a
    /// server across the internet is entitled to do that, but the UI must not
    /// then tell them their meeting stayed put.
    var isLocal: Bool {
        guard let host = endpoint.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }

    /// Ollama's default. LM Studio uses 1234.
    static let defaultEndpoint = URL(string: "http://127.0.0.1:11434/v1/chat/completions")!
    static let defaultModel = "qwen3:4b"

    var endpoint: URL = defaultEndpoint
    var model: String = defaultModel
    var session: URLSession = .shared

    /// Long, because a 4B model working through 28,000 tokens of transcript on
    /// a laptop is slow and finishing late beats failing.
    var timeout: TimeInterval = 900

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
            "model": model,
            "temperature": 0.2,
            "stream": false,
            "messages": [
                ["role": "system", "content": Self.instructions],
                ["role": "user", "content": prompt],
            ],
            // Ollama and LM Studio both honour this; a server that does not
            // will still usually return JSON because the system prompt asks
            // for it, which is why the parser below tolerates surrounding
            // prose rather than demanding a bare object.
            "response_format": ["type": "json_object"],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await session.data(for: request)
        } catch {
            throw ScribeError.transcription(
                "Could not reach \(endpoint.absoluteString). Is the server running? (\(error.localizedDescription))"
            )
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ScribeError.http(http.statusCode, String(decoding: body, as: UTF8.self))
        }

        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]?
        }
        guard let text = try JSONDecoder().decode(Envelope.self, from: body)
            .choices?.first?.message?.content
        else { throw ScribeError.transcription("The local model returned no summary.") }

        guard let summary = MeetingSummary.decoding(text) else {
            throw ScribeError.transcription(
                "The local model's reply was not the expected JSON. Try a larger model, "
                + "or one tuned for structured output."
            )
        }
        return summary
    }

    private static let instructions = """
    You summarise meeting transcripts. Reply with a single JSON object and \
    nothing else -- no prose before or after, no code fence.

    Shape:
    {
      "title": "three to six words naming the subject, no date, not the word meeting",
      "summary": "two or three sentences on what it was for and where it landed",
      "topics": ["subjects discussed"],
      "decisions": ["things settled, with who settled them where the transcript says"],
      "action_items": [{"task": "...", "owner": "speaker or empty", "due": "their own words or empty"}],
      "open_questions": ["raised but unresolved"]
    }

    Rules:
    - Use only what the transcript says. Never invent a decision, an owner or a \
    deadline. If nobody was named, leave owner empty.
    - An action item is something a person committed to doing. Vague intentions \
    are open questions, not action items.
    - Prefer the speaker's own words for a deadline over a calendar date.
    - The transcript comes from speech recognition; read through obvious \
    mis-hearings rather than quoting them.
    - Empty lists where a section has nothing. Do not pad.
    """
}
