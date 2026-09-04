import Testing
@testable import ScribeCore

@Suite("Attaching speakers to words")
struct DiarizationTests {

    private func word(_ text: String, _ start: Int, _ end: Int) -> Word {
        Word(text: text, speaker: nil, startMs: start, endMs: end)
    }

    @Test("each word takes the speaker whose segment covers it")
    func coversWords() {
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1000),
            SpeakerSegment(speakerId: "S2", startMs: 1000, endMs: 2000),
        ]
        let out = Diarization.assign(
            words: [word("hello", 0, 400), word("there", 500, 900), word("hi", 1100, 1500)],
            to: segments
        )
        #expect(out.map(\.speaker) == ["S1", "S1", "S2"])
    }

    @Test("a word straddling a boundary goes to whoever spoke most of it")
    func straddling() {
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1000),
            SpeakerSegment(speakerId: "S2", startMs: 1000, endMs: 2000),
        ]
        // 900-1300: midpoint 1100 sits in S2, though it starts inside S1.
        let out = Diarization.assign(words: [word("crossing", 900, 1300)], to: segments)
        #expect(out[0].speaker == "S2")
    }

    @Test("a word in a gap takes the nearest segment rather than none")
    func gapFallback() {
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1000),
            SpeakerSegment(speakerId: "S2", startMs: 5000, endMs: 6000),
        ]
        // 1200 is in the gap, closer to S1's end than to S2's start.
        let out = Diarization.assign(words: [word("orphan", 1100, 1300)], to: segments)
        #expect(out[0].speaker == "S1")
    }

    @Test("no segments at all leaves every word untouched")
    func noSegments() {
        let words = [word("a", 0, 100), word("b", 200, 300)]
        #expect(Diarization.assign(words: words, to: []) == words)
    }

    @Test("overlapping segments still resolve to the one that covers the word")
    func overlapping() {
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 3000),
            SpeakerSegment(speakerId: "S2", startMs: 1000, endMs: 1200),
        ]
        let out = Diarization.assign(words: [word("mid", 1050, 1150)], to: segments)
        #expect(out[0].speaker == "S2")
    }

    @Test("timings and order survive assignment untouched")
    func preservesEverything() {
        let words = (0..<50).map { word("w\($0)", $0 * 100, $0 * 100 + 80) }
        let segments = [SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 10_000)]
        let out = Diarization.assign(words: words, to: segments)
        #expect(out.map(\.text) == words.map(\.text))
        #expect(out.map(\.startMs) == words.map(\.startMs))
        #expect(out.map(\.endMs) == words.map(\.endMs))
    }

    @Test("a lone word inside someone else's sentence is absorbed")
    func absorbsFlicker() {
        var words = [word("I", 0, 100), word("think", 150, 250), word("so", 300, 400)]
        words[0].speaker = "S1"; words[1].speaker = "S2"; words[2].speaker = "S1"
        let out = Diarization.absorbSingleWordFlickers(words)
        #expect(out.map(\.speaker) == ["S1", "S1", "S1"])
    }

    @Test("a real interjection with pauses around it is left alone")
    func keepsGenuineInterjection() {
        var words = [word("so", 0, 100), word("yeah", 900, 1100), word("anyway", 2000, 2300)]
        words[0].speaker = "S1"; words[1].speaker = "S2"; words[2].speaker = "S1"
        let out = Diarization.absorbSingleWordFlickers(words)
        #expect(out.map(\.speaker) == ["S1", "S2", "S1"])
    }

    @Test("assigned words collapse into one turn per voice")
    func feedsTurns() {
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1000),
            SpeakerSegment(speakerId: "S2", startMs: 1000, endMs: 2000),
        ]
        let words = Diarization.assign(
            words: [word("hello", 0, 400), word("there", 500, 900),
                    word("hi", 1100, 1500), word("back", 1600, 1900)],
            to: segments
        )
        let turns = Transcript.turns(from: words)
        #expect(turns.count == 2)
        #expect(turns[0].text == "hello there")
        #expect(turns[1].text == "hi back")
        #expect(turns[0].speaker == "Speaker 1")
        #expect(turns[1].speaker == "Speaker 2")
    }
}
