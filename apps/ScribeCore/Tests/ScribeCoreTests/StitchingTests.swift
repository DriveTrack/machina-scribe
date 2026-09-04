import Testing
@testable import ScribeCore

@Suite("Keeping speakers consistent across chunk boundaries")
struct StitchingTests {

    /// Chunk 2 starts 20 minutes in and re-transcribes the last 40 seconds of
    /// chunk 1. Crucially its diarizer has assigned the labels the other way
    /// round -- Jose is spk_2 here but was spk_1 before. Naming him once must
    /// still hold for the whole meeting.
    private var twoChunks: [Chunk] {
        let first = Chunk(offsetMs: 0, turns: [
            Turn(speaker: "Speaker 1", startMs: 0, endMs: 5_000,
                 text: "Let's start with the roadmap for next quarter."),
            Turn(speaker: "Speaker 2", startMs: 6_000, endMs: 12_000,
                 text: "I think we should push the migration back."),
            // inside the overlap window (starts at 1_180_000)
            Turn(speaker: "Speaker 1", startMs: 1_185_000, endMs: 1_192_000,
                 text: "So the latency work lands before the migration."),
            Turn(speaker: "Speaker 2", startMs: 1_193_000, endMs: 1_199_000,
                 text: "Right, and I will own the scoping document.")
        ])

        let second = Chunk(offsetMs: 1_180_000, turns: [
            // same audio as the tail of chunk 1, labels swapped
            Turn(speaker: "Speaker 2", startMs: 5_000, endMs: 12_000,
                 text: "So the latency work lands before the migration"),
            Turn(speaker: "Speaker 1", startMs: 13_000, endMs: 19_000,
                 text: "Right and I will own the scoping doc"),
            // past the seam: genuinely new content
            Turn(speaker: "Speaker 2", startMs: 45_000, endMs: 50_000,
                 text: "One more thing about the hiring plan."),
            Turn(speaker: "Speaker 1", startMs: 51_000, endMs: 56_000,
                 text: "Go ahead, we have time.")
        ])

        return [first, second]
    }

    @Test("a voice keeps its identity when the second chunk labels it differently")
    func labelsSurviveTheSeam() {
        let result = Stitcher.stitch(twoChunks)

        // "One more thing about the hiring plan" was spk_2 in chunk 2, but that
        // voice is chunk 1's Speaker 1. It must come back as Speaker 1.
        let hiring = result.turns.first { $0.text.contains("hiring plan") }
        #expect(hiring?.speaker == "Speaker 1")

        let goAhead = result.turns.first { $0.text.contains("Go ahead") }
        #expect(goAhead?.speaker == "Speaker 2")

        #expect(result.unmatchedLabels.isEmpty)
    }

    @Test("the overlap is not transcribed twice")
    func noDuplication() {
        let result = Stitcher.stitch(twoChunks)
        let latency = result.turns.filter { $0.text.lowercased().contains("latency work lands") }
        #expect(latency.count == 1)
        // and the earlier chunk's fuller punctuation is the one kept
        #expect(latency.first?.text.hasSuffix(".") == true)
    }

    @Test("timings come back absolute, in order")
    func absoluteTimings() {
        let result = Stitcher.stitch(twoChunks)
        #expect(result.turns.map(\.startMs) == result.turns.map(\.startMs).sorted())
        #expect(result.turns.first?.startMs == 0)
        // 1_180_000 chunk offset + 45_000 local
        #expect(result.turns.contains { $0.startMs == 1_225_000 })
    }

    @Test("someone who only joins in the second half becomes a new speaker")
    func lateArrival() {
        var chunks = twoChunks
        chunks[1].turns.append(
            Turn(speaker: "Speaker 3", startMs: 60_000, endMs: 65_000,
                 text: "Sorry I'm late, what did I miss?")
        )
        let result = Stitcher.stitch(chunks)
        let latecomer = result.turns.first { $0.text.contains("Sorry") }
        #expect(latecomer?.speaker == "Speaker 3")
        #expect(result.unmatchedLabels == ["Speaker 3"])
    }

    @Test("an unmatchable seam splits the speaker rather than merging two people")
    func noFalseMerge() {
        // Overlap text shares nothing, so no vote can be cast. The safe outcome
        // is extra speaker cards to rename -- never words on the wrong person.
        let a = Chunk(offsetMs: 0, turns: [
            Turn(speaker: "Speaker 1", startMs: 1_185_000, endMs: 1_190_000, text: "alpha bravo charlie")
        ])
        let b = Chunk(offsetMs: 1_180_000, turns: [
            Turn(speaker: "Speaker 1", startMs: 5_000, endMs: 10_000, text: "xray yankee zulu"),
            Turn(speaker: "Speaker 1", startMs: 45_000, endMs: 50_000, text: "after the seam")
        ])
        let result = Stitcher.stitch([a, b])
        #expect(result.unmatchedLabels.isEmpty == false)
        #expect(result.turns.first { $0.text == "after the seam" }?.speaker == "Speaker 2")
    }

    @Test("a single chunk passes through untouched")
    func singleChunk() {
        let only = Chunk(offsetMs: 0, turns: [
            Turn(speaker: "Speaker 1", startMs: 0, endMs: 1_000, text: "Just one chunk.")
        ])
        let result = Stitcher.stitch([only])
        #expect(result.turns.count == 1)
        #expect(result.turns[0].speaker == "Speaker 1")
    }

    @Test("similarity tolerates the wording drift between two passes")
    func similarityIsFuzzy() {
        let x = "So the latency work lands before the migration."
        let y = "so the latency work lands before the migration"
        #expect(Stitcher.similarity(x, y) > 0.9)
        #expect(Stitcher.similarity("alpha bravo", "xray yankee") == 0)
    }
}
