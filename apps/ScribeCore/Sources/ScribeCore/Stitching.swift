import Foundation

/// One transcription request's worth of audio.
///
/// Diarization caps a request at 30 minutes, so a long meeting is transcribed
/// in pieces. Each piece is diarized independently: the voice the API calls
/// `spk_1` in the second chunk is not necessarily `spk_1` in the first. These
/// chunks deliberately overlap so the seam can be repaired.
public struct Chunk: Equatable, Sendable {
    /// Where this chunk begins within the whole recording.
    public var offsetMs: Int
    /// Turns with chunk-local timings and chunk-local speaker labels.
    public var turns: [Turn]

    public init(offsetMs: Int, turns: [Turn]) {
        self.offsetMs = offsetMs
        self.turns = turns
    }
}

public struct StitchResult: Equatable, Sendable {
    public var turns: [Turn]
    /// Labels that could not be tied to a voice already seen. They become new
    /// speakers, which is the safe failure: the user renames one extra card
    /// rather than reading words attributed to the wrong person.
    public var unmatchedLabels: [String]
}

public enum Stitcher {

    /// Merge independently diarized chunks into one transcript with consistent
    /// speaker names and absolute timings.
    ///
    /// Within the overlap the two chunks transcribe the *same* audio, so their
    /// turns should read alike. Matching that text tells us which local label
    /// corresponds to which speaker we have already named.
    public static func stitch(
        _ chunks: [Chunk],
        overlapMs: Int = 40_000,
        similarityThreshold: Double = 0.34
    ) -> StitchResult {
        guard var accumulated = chunks.first.map({ absolute($0) }) else {
            return StitchResult(turns: [], unmatchedLabels: [])
        }

        var knownLabels = Set(accumulated.map(\.speaker))
        var unmatched: [String] = []

        for chunk in chunks.dropFirst() {
            let incoming = absolute(chunk)
            let seamEnd = chunk.offsetMs + overlapMs

            // The same seconds of audio, transcribed twice.
            let old = accumulated.filter { $0.endMs > chunk.offsetMs && $0.startMs < seamEnd }
            let new = incoming.filter { $0.startMs < seamEnd }

            var mapping = vote(new: new, old: old, threshold: similarityThreshold)

            // Any local label with no counterpart in the overlap is a voice we
            // have not met -- someone who only starts talking later, or a match
            // we simply missed. Give it a fresh name rather than guessing.
            for label in Set(incoming.map(\.speaker)) where mapping[label] == nil {
                let fresh = nextLabel(avoiding: knownLabels)
                mapping[label] = fresh
                knownLabels.insert(fresh)
                unmatched.append(label)
            }

            // Keep the earlier chunk's rendering of the overlap: it was
            // transcribed with the full run-up rather than from a cold start.
            let tail = incoming
                .filter { $0.startMs >= seamEnd }
                .map { turn -> Turn in
                    var t = turn
                    t.speaker = mapping[turn.speaker] ?? turn.speaker
                    return t
                }

            accumulated.append(contentsOf: tail)
            knownLabels.formUnion(accumulated.map(\.speaker))
        }

        accumulated.sort { $0.startMs < $1.startMs }
        return StitchResult(turns: accumulated, unmatchedLabels: unmatched)
    }

    // MARK: - Internals

    private static func absolute(_ chunk: Chunk) -> [Turn] {
        chunk.turns.map { turn in
            Turn(
                speaker: turn.speaker,
                startMs: turn.startMs + chunk.offsetMs,
                endMs: turn.endMs + chunk.offsetMs,
                text: turn.text
            )
        }
    }

    /// Each overlapping turn casts one vote for "my label is really their label".
    /// Majority wins, so a single garbled turn cannot flip a speaker.
    private static func vote(new: [Turn], old: [Turn], threshold: Double) -> [String: String] {
        var tally: [String: [String: Int]] = [:]

        for candidate in new {
            var best: (label: String, score: Double)?
            for existing in old {
                // A turn can only correspond to one that covers similar time.
                guard overlaps(candidate, existing, slackMs: 4_000) else { continue }
                let score = similarity(candidate.text, existing.text)
                if score >= threshold, score > (best?.score ?? 0) {
                    best = (existing.speaker, score)
                }
            }
            if let best {
                tally[candidate.speaker, default: [:]][best.label, default: 0] += 1
            }
        }

        return tally.compactMapValues { votes in
            votes.max { $0.value < $1.value }?.key
        }
    }

    private static func overlaps(_ a: Turn, _ b: Turn, slackMs: Int) -> Bool {
        a.startMs - slackMs < b.endMs && b.startMs - slackMs < a.endMs
    }

    /// Jaccard over lowercased word sets. The two transcriptions of the same
    /// audio rarely match character for character -- punctuation and filler
    /// words differ -- but they share nearly all their vocabulary.
    static func similarity(_ a: String, _ b: String) -> Double {
        let left = tokens(a)
        let right = tokens(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let shared = left.intersection(right).count
        let total = left.union(right).count
        return Double(shared) / Double(total)
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 1 }
        )
    }

    private static func nextLabel(avoiding taken: Set<String>) -> String {
        var n = 1
        while taken.contains("Speaker \(n)") { n += 1 }
        return "Speaker \(n)"
    }
}
