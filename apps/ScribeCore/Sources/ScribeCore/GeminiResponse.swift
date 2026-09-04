import Foundation

/// Decoder for the `interactions` transcription response.
///
/// The transcript arrives twice: once as flat text, and once as per-word
/// annotations carrying the speaker and timings. We want the annotations --
/// the flat text has no speaker in it at all.
public struct GeminiTranscription: Decodable, Sendable {

    public struct Annotation: Decodable, Sendable {
        public let type: String
        public let text: String?
        public let speaker: String?
        public let startOffset: String?
        public let endOffset: String?
    }

    struct Content: Decodable {
        let annotations: [Annotation]?
    }

    struct Step: Decodable {
        let content: [Content]?
    }

    let steps: [Step]?
    public let outputText: String?

    /// Every `word_info` annotation, flattened across steps, in order.
    public var words: [Word] {
        (steps ?? [])
            .flatMap { $0.content ?? [] }
            .flatMap { $0.annotations ?? [] }
            .filter { $0.type == "word_info" }
            .compactMap { annotation in
                guard
                    let text = annotation.text,
                    let start = annotation.startOffset.flatMap(Transcript.millis(fromOffset:)),
                    let end = annotation.endOffset.flatMap(Transcript.millis(fromOffset:))
                else { return nil }
                return Word(text: text, speaker: annotation.speaker, startMs: start, endMs: end)
            }
    }

    public static func decode(_ data: Data) throws -> GeminiTranscription {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GeminiTranscription.self, from: data)
    }

    /// Turns, ready to store. Empty when the response carried no annotations,
    /// which means diarization was not actually applied.
    public func turns(maxGapMs: Int = 1_500) -> [Turn] {
        Transcript.turns(from: words, maxGapMs: maxGapMs)
    }
}
