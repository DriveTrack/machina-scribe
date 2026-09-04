import Foundation
import ScribeCore

/// Sends audio to Gemini and gets back diarized turns.
///
/// Uses the unary `gemini-3.5-transcribe` model rather than the live one: the
/// live endpoint streams text but does no diarization at all, so it cannot say
/// who spoke. Diarization caps a request at 30 minutes, which is why anything
/// longer is chunked before it gets here.
struct GeminiTranscriber {
    static let model = "gemini-3.5-transcribe"
    /// The hard cap is 30 minutes with diarization on; stay clear of the edge.
    static let maxChunkMs = 20 * 60 * 1_000
    /// Re-transcribed on both sides of a seam so speaker labels can be matched.
    static let overlapMs = 40 * 1_000

    private let apiKey: String
    private let session: URLSession
    private let base = URL(string: "https://generativelanguage.googleapis.com")!

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Upload one audio file and return its diarized turns, timed from the
    /// start of that file.
    ///
    /// Retries on rate limiting, because a long meeting is split into several
    /// requests and hitting a per-minute limit partway through is ordinary,
    /// not exceptional. `onWait` reports the pause so the UI can say what is
    /// happening rather than appearing to hang.
    func transcribe(
        fileURL: URL,
        mimeType: String = "audio/mp4",
        maxAttempts: Int = 5,
        onWait: (@Sendable (TimeInterval, Int) -> Void)? = nil
    ) async throws -> [Turn] {
        var attempt = 1
        while true {
            do {
                let uri = try await upload(fileURL: fileURL, mimeType: mimeType)
                return try await requestTranscription(fileURI: uri, mimeType: mimeType)
            } catch let error as ScribeError {
                guard case .rateLimited(let retryAfter, _) = error, attempt < maxAttempts else {
                    throw error
                }
                // Prefer the delay the API asked for; otherwise back off
                // exponentially from 20s, capped so a stuck daily quota fails
                // in minutes rather than hanging for an hour.
                let wait = min(retryAfter ?? (20 * pow(2, Double(attempt - 1))), 180)
                onWait?(wait, attempt)
                try await Task.sleep(for: .seconds(wait))
                attempt += 1
            }
        }
    }

    // MARK: - Files API

    /// Resumable upload: start to get a session URL, then send the bytes.
    private func upload(fileURL: URL, mimeType: String) async throws -> String {
        let data = try Data(contentsOf: fileURL)

        var start = URLRequest(url: base.appending(path: "upload/v1beta/files"))
        start.httpMethod = "POST"
        start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(
            withJSONObject: ["file": ["display_name": fileURL.lastPathComponent]]
        )

        let (startBody, startResponse) = try await session.data(for: start)
        try check(startResponse, startBody)

        guard let http = startResponse as? HTTPURLResponse,
              let uploadURLString = http.value(forHTTPHeaderField: "X-Goog-Upload-URL")
                ?? http.value(forHTTPHeaderField: "x-goog-upload-url"),
              let uploadURL = URL(string: uploadURLString)
        else {
            throw ScribeError.transcription("Upload did not return a session URL.")
        }

        var put = URLRequest(url: uploadURL)
        put.httpMethod = "POST"
        put.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        put.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        put.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")

        let (body, response) = try await session.upload(for: put, from: data)
        try check(response, body)

        struct FileEnvelope: Decodable {
            struct File: Decodable { let uri: String; let state: String? }
            let file: File
        }
        let uploaded = try JSONDecoder().decode(FileEnvelope.self, from: body)
        try await waitUntilActive(uri: uploaded.file.uri, initialState: uploaded.file.state)
        return uploaded.file.uri
    }

    /// A freshly uploaded file is PROCESSING for a moment; transcribing it in
    /// that window fails, so wait for ACTIVE.
    private func waitUntilActive(uri: String, initialState: String?) async throws {
        var state = initialState ?? "PROCESSING"
        guard let url = URL(string: uri) else { return }

        for _ in 0..<60 where state == "PROCESSING" {
            try await Task.sleep(for: .seconds(1))
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (body, response) = try await session.data(for: request)
            try check(response, body)

            struct FileState: Decodable { let state: String? }
            state = (try? JSONDecoder().decode(FileState.self, from: body).state) ?? "ACTIVE"
        }

        if state == "FAILED" {
            throw ScribeError.transcription("Gemini could not process the audio.")
        }
    }

    // MARK: - Transcription

    private func requestTranscription(fileURI: String, mimeType: String) async throws -> [Turn] {
        var request = URLRequest(url: base.appending(path: "v1beta/interactions"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        let payload: [String: Any] = [
            "model": Self.model,
            "input": [["type": "audio", "uri": fileURI, "mime_type": mimeType]],
            "generation_config": [
                "transcription_config": [
                    "mode": [
                        "type": "verbatim",
                        "diarization_mode": "speaker",
                        // word offsets are what let a live tag land on a turn
                        "timestamp_granularities": ["word"]
                    ]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (body, response) = try await session.data(for: request)
        try check(response, body)

        let parsed = try GeminiTranscription.decode(body)
        let turns = parsed.turns()
        guard !turns.isEmpty else {
            throw ScribeError.transcription(
                "No speech was recognised in this recording."
            )
        }
        return turns
    }

    private func check(_ response: URLResponse, _ body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 || http.statusCode == 503 {
                throw ScribeError.rateLimited(
                    retryAfter: Self.retryDelay(from: body, headers: http),
                    detail: Self.reason(from: body)
                )
            }
            throw ScribeError.http(http.statusCode, String(decoding: body, as: UTF8.self))
        }
    }

    /// How long the API says to wait.
    ///
    /// Google returns a RetryInfo detail with a duration like "27s"; a
    /// Retry-After header is the HTTP-standard fallback. Guessing a backoff
    /// when the service has told you the answer just burns more quota.
    static func retryDelay(from body: Data, headers: HTTPURLResponse?) -> TimeInterval? {
        struct Envelope: Decodable {
            struct Failure: Decodable {
                struct Detail: Decodable {
                    let type: String?
                    let retryDelay: String?
                    enum CodingKeys: String, CodingKey {
                        case type = "@type"
                        case retryDelay
                    }
                }
                let details: [Detail]?
            }
            let error: Failure?
        }
        if let parsed = try? JSONDecoder().decode(Envelope.self, from: body),
           let raw = parsed.error?.details?.compactMap(\.retryDelay).first,
           raw.hasSuffix("s"),
           let seconds = Double(raw.dropLast()) {
            return seconds
        }
        if let header = headers?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(header) {
            return seconds
        }
        return nil
    }

    static func reason(from body: Data) -> String {
        struct Envelope: Decodable {
            struct Failure: Decodable { let message: String? }
            let error: Failure?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: body))?.error?.message
            ?? String(decoding: body.prefix(200), as: UTF8.self)
    }
}
