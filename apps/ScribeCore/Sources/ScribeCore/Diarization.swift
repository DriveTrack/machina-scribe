import Foundation

/// A stretch of audio attributed to one voice by a diarization pass.
///
/// Times are absolute within the recording. The id is whatever the diarizer
/// called the voice -- an opaque cluster label like `S1`, not a name.
public struct SpeakerSegment: Equatable, Sendable {
    public var speakerId: String
    public var startMs: Int
    public var endMs: Int

    public init(speakerId: String, startMs: Int, endMs: Int) {
        self.speakerId = speakerId
        self.startMs = startMs
        self.endMs = endMs
    }

    var midpoint: Int { startMs + (endMs - startMs) / 2 }
    func contains(_ ms: Int) -> Bool { ms >= startMs && ms <= endMs }
}

public enum Diarization {

    /// Attach a speaker to every word by asking which segment its midpoint
    /// falls in.
    ///
    /// The midpoint rather than the start: a word straddling a boundary is more
    /// truthfully owned by whoever was speaking for most of it, and using the
    /// start systematically hands the first word of each turn to the previous
    /// speaker.
    ///
    /// Words that fall in a gap -- diarizers leave them, and one turn in
    /// sixteen landed in one during testing -- take the nearest segment rather
    /// than nothing. A word between two turns belongs to one of them; dropping
    /// its speaker would silently split a turn in half at that point, which
    /// reads as a phantom speaker change.
    ///
    /// Words keep their order and their timings. Only `speaker` is written.
    public static func assign(words: [Word], to segments: [SpeakerSegment]) -> [Word] {
        guard !segments.isEmpty else { return words }
        let sorted = segments.sorted { $0.startMs < $1.startMs }

        return words.map { word in
            var word = word
            word.speaker = speaker(at: word.startMs + (word.endMs - word.startMs) / 2, in: sorted)
            return word
        }
    }

    /// The segment covering `ms`, or failing that the one whose edge is
    /// closest to it.
    static func speaker(at ms: Int, in sorted: [SpeakerSegment]) -> String? {
        // Binary search for the last segment starting at or before `ms`, then
        // look at it and its neighbour: segments can overlap, so the covering
        // one is not always the last that started.
        var low = 0, high = sorted.count - 1, candidate = 0
        while low <= high {
            let mid = (low + high) / 2
            if sorted[mid].startMs <= ms {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let window = max(0, candidate - 1)...min(sorted.count - 1, candidate + 1)

        // Several segments can cover the same instant. Prefer the shortest:
        // a brief segment nested inside a long one is the diarizer saying
        // "for this moment it was somebody else", and the long one is the
        // background it is carving out of. Taking whichever came first in the
        // array instead would always return the container and throw the
        // interjection away.
        let covering = window.filter { sorted[$0].contains(ms) }
        if let best = covering.min(by: {
            (sorted[$0].endMs - sorted[$0].startMs) < (sorted[$1].endMs - sorted[$1].startMs)
        }) {
            return sorted[best].speakerId
        }

        // In a gap. Take whichever edge in the window is nearest.
        return window
            .map { (sorted[$0], distance(from: ms, to: sorted[$0])) }
            .min { $0.1 < $1.1 }?
            .0.speakerId
    }

    private static func distance(from ms: Int, to segment: SpeakerSegment) -> Int {
        if segment.contains(ms) { return 0 }
        return ms < segment.startMs ? segment.startMs - ms : ms - segment.endMs
    }

    /// Absorb one-word interjections into the turn around them.
    ///
    /// A diarizer will occasionally place a single word with a neighbour's
    /// voice mid-sentence. Left alone, `Transcript.turns` splits a turn into
    /// three at that word, so a meeting reads as though people are constantly
    /// interrupting each other one word at a time. A real backchannel ("yeah",
    /// "right") is usually its own short segment surrounded by silence, which
    /// this leaves intact -- what it removes is a lone word buried inside
    /// somebody else's continuous speech.
    public static func absorbSingleWordFlickers(_ words: [Word]) -> [Word] {
        guard words.count > 2 else { return words }
        var out = words
        for i in 1..<(out.count - 1) {
            let before = out[i - 1].speaker
            let after = out[i + 1].speaker
            guard before == after, out[i].speaker != before else { continue }
            // Only when the word sits tight against both neighbours; a real
            // interjection has a pause around it.
            let gapBefore = out[i].startMs - out[i - 1].endMs
            let gapAfter = out[i + 1].startMs - out[i].endMs
            if gapBefore < 400 && gapAfter < 400 { out[i].speaker = before }
        }
        return out
    }
}
