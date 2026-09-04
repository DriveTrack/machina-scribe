import Foundation

/// One recognized word, as Gemini reports it.
public struct Word: Equatable, Sendable {
    public var text: String
    /// Diarization label, chunk-local ("spk_1"). Nil when diarization is off.
    public var speaker: String?
    public var startMs: Int
    public var endMs: Int

    public init(text: String, speaker: String?, startMs: Int, endMs: Int) {
        self.text = text
        self.speaker = speaker
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// A run of speech by one voice: what actually gets stored as a segment.
public struct Turn: Codable, Equatable, Sendable {
    public var speaker: String
    public var startMs: Int
    public var endMs: Int
    public var text: String

    public init(speaker: String, startMs: Int, endMs: Int, text: String) {
        self.speaker = speaker
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

public enum Transcript {

    /// Protobuf durations arrive as `"12.500s"`. Anything else is a wire change
    /// we would rather notice than silently read as zero.
    public static func millis(fromOffset offset: String) -> Int? {
        guard offset.hasSuffix("s"),
              let seconds = Double(offset.dropLast())
        else { return nil }
        return Int((seconds * 1000).rounded())
    }

    /// Diarization labels its voices opaquely, and the exact spelling is not
    /// something to rely on: the documented example is `spk_1`, while the live
    /// API returns `spk:0`. Rather than parse either shape, number speakers by
    /// the order they first talk -- which is both robust to the format and
    /// friendlier than the API's internal indices, zero-based or otherwise.
    public struct SpeakerNaming {
        private var assigned: [String: String] = [:]

        public init() {}

        public mutating func label(for raw: String?) -> String {
            let key = raw ?? "<unknown>"
            if let existing = assigned[key] { return existing }
            let fresh = "Speaker \(assigned.count + 1)"
            assigned[key] = fresh
            return fresh
        }
    }

    /// Collapse words into turns. A turn ends when the voice changes or when a
    /// pause runs longer than `maxGapMs` -- without the pause rule a single
    /// speaker holding the floor becomes one unreadable wall of text with a
    /// useless timestamp on the front.
    public static func turns(from words: [Word], maxGapMs: Int = 1_500) -> [Turn] {
        var result: [Turn] = []
        var buffer: [Word] = []
        var naming = SpeakerNaming()

        func flush() {
            guard let first = buffer.first, let last = buffer.last else { return }
            let text = buffer.map(\.text).joined(separator: " ")
            result.append(
                Turn(
                    speaker: naming.label(for: first.speaker),
                    startMs: first.startMs,
                    endMs: last.endMs,
                    text: normalizeSpacing(text)
                )
            )
            buffer = []
        }

        for word in words {
            if let previous = buffer.last {
                let voiceChanged = previous.speaker != word.speaker
                let longPause = word.startMs - previous.endMs > maxGapMs
                if voiceChanged || longPause { flush() }
            }
            buffer.append(word)
        }
        flush()
        return result
    }

    /// Joining words with spaces puts one before every comma; undo that.
    static func normalizeSpacing(_ text: String) -> String {
        var out = text
        for mark in [",", ".", "?", "!", ";", ":", "'s", "n't", "'re", "'ll", "'ve", "'m", "'d"] {
            out = out.replacingOccurrences(of: " \(mark)", with: mark)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
