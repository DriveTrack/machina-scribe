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
    ///
    /// Bigger chunks are better than smaller ones: every seam is a chance for
    /// the same person to be re-identified as somebody new, so the fewer seams
    /// a meeting has, the better it comes out.
    static let maxChunkMs = 27 * 60 * 1_000

    /// Re-transcribed on both sides of a seam so speaker labels can be matched.
    ///
    /// Two minutes rather than forty seconds. A speaker can only be carried
    /// across a seam if they happen to talk inside the overlap, and in a real
    /// conversation only one person is usually speaking in any given forty
    /// seconds -- so everyone else was being re-identified as a new person at
    /// every boundary. A three-person meeting came back with eight speakers.
    /// The cost is re-transcribing two minutes per seam, which is cheap next
    /// to hand-merging five phantom speakers.
    static let overlapMs = 120 * 1_000

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
    /// What the transcriber is doing, so the UI can say so instead of showing
    /// one stale line for minutes at a time.
    enum Progress: Sendable {
        case uploading
        case transcribing
        case waiting(seconds: TimeInterval, attempt: Int, of: Int)
    }

    func transcribe(
        fileURL: URL,
        mimeType: String = "audio/mp4",
        maxAttempts: Int = 8,
        report: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> [Turn] {
        Transcript.turns(from: try await transcribeWords(
            fileURL: fileURL, mimeType: mimeType, maxAttempts: maxAttempts, report: report))
    }

    func transcribeWords(
        fileURL: URL,
        mimeType: String = "audio/mp4",
        maxAttempts: Int = 8,
        report: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> [Word] {
        var attempt = 1
        while true {
            do {
                report?(.uploading)
                let uri = try await upload(fileURL: fileURL, mimeType: mimeType)
                report?(.transcribing)
                return try await requestTranscription(fileURI: uri, mimeType: mimeType)
            } catch let error as ScribeError {
                guard case .rateLimited(let retryAfter, _) = error, attempt < maxAttempts else {
                    throw error
                }
                // Prefer the delay the API asked for. Otherwise back off from
                // 30s: a twenty-minute chunk is tens of thousands of audio
                // tokens, so what usually runs out is the per-minute token
                // budget, and that needs most of a minute to refill -- retrying
                // sooner just spends another request to be told the same thing.
                let wait = min(retryAfter ?? (30 * pow(1.8, Double(attempt - 1))), 300)
                report?(.waiting(seconds: wait, attempt: attempt, of: maxAttempts))
                try await Task.sleep(for: .seconds(wait))
                attempt += 1
            }
        }
    }

    /// Breathing room between parts of the same recording.
    ///
    /// Firing consecutive twenty-minute chunks back to back is what trips the
    /// per-minute token limit in the first place. Pausing between them is
    /// cheaper in wall-clock time than eating a 429 and its backoff on
    /// every single part.
    static let pacingBetweenParts: Duration = .seconds(45)

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

    private func requestTranscription(fileURI: String, mimeType: String) async throws -> [Word] {
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
        let words = parsed.words
        guard !words.isEmpty else {
            throw ScribeError.transcription(
                "No speech was recognised in this recording."
            )
        }
        return words
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


// MARK: - AudioTranscriber

extension GeminiTranscriber: AudioTranscriber {

    /// Gemini caps diarization at 30 minutes, so anything longer has to be cut
    /// into overlapping pieces and stitched back together.
    var maxChunkMs: Int? { Self.maxChunkMs }

    /// It diarizes, so `Word.speaker` arrives populated and no separate pass is
    /// needed -- at the cost of that cap, and of a speaker only surviving a
    /// seam if they happen to talk inside the overlap.
    var identifiesSpeakers: Bool { true }

    var label: String { "Gemini" }

    func words(
        in fileURL: URL,
        report: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> [Word] {
        try await transcribeWords(fileURL: fileURL) { progress in
            report?(progress.asTranscriptionProgress)
        }
    }
}

private extension GeminiTranscriber.Progress {
    var asTranscriptionProgress: TranscriptionProgress {
        switch self {
        case .uploading: .uploading
        case .transcribing: .transcribing
        case .waiting(let seconds, let attempt, let total):
            .waiting(seconds: seconds, attempt: attempt, of: total)
        }
    }
}
