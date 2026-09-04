import Testing
@testable import ScribeCore

@Suite("Parsing Gemini's transcription response")
struct ParsingTests {

    @Test("word offsets are protobuf durations, not milliseconds")
    func offsets() {
        #expect(Transcript.millis(fromOffset: "0.100s") == 100)
        #expect(Transcript.millis(fromOffset: "12.5s") == 12_500)
        #expect(Transcript.millis(fromOffset: "0s") == 0)
        // a wire change should surface, not read as time zero
        #expect(Transcript.millis(fromOffset: "100") == nil)
        #expect(Transcript.millis(fromOffset: "") == nil)
    }

    @Test("spk_N is rewritten into something a person can read")
    func labels() {
        #expect(Transcript.displayLabel(for: "spk_1") == "Speaker 1")
        #expect(Transcript.displayLabel(for: "spk_12") == "Speaker 12")
        #expect(Transcript.displayLabel(for: "narrator") == "narrator")
    }

    @Test("word annotations become speaker-attributed turns")
    func decoding() throws {
        let json = """
        {
          "id": "interactions/abc",
          "status": "completed",
          "output_text": "Hello world how are you",
          "steps": [{
            "id": "step_001",
            "type": "model_output",
            "content": [{
              "type": "text",
              "text": "Hello world how are you",
              "annotations": [
                {"type":"word_info","text":"Hello","speaker":"spk_1","start_offset":"0.100s","end_offset":"0.450s"},
                {"type":"word_info","text":"world","speaker":"spk_1","start_offset":"0.500s","end_offset":"0.850s"},
                {"type":"word_info","text":"how","speaker":"spk_2","start_offset":"1.000s","end_offset":"1.200s"},
                {"type":"word_info","text":"are","speaker":"spk_2","start_offset":"1.250s","end_offset":"1.400s"},
                {"type":"word_info","text":"you","speaker":"spk_2","start_offset":"1.450s","end_offset":"1.700s"}
              ]
            }]
          }]
        }
        """.data(using: .utf8)!

        let parsed = try GeminiTranscription.decode(json)
        #expect(parsed.words.count == 5)

        let turns = parsed.turns()
        #expect(turns.count == 2)
        #expect(turns[0] == Turn(speaker: "Speaker 1", startMs: 100, endMs: 850, text: "Hello world"))
        #expect(turns[1] == Turn(speaker: "Speaker 2", startMs: 1_000, endMs: 1_700, text: "how are you"))
    }

    @Test("a response with no annotations yields no turns rather than one bogus one")
    func noDiarization() throws {
        let json = #"{"id":"x","status":"completed","output_text":"just text","steps":[]}"#
            .data(using: .utf8)!
        #expect(try GeminiTranscription.decode(json).turns().isEmpty)
    }

    @Test("one speaker holding the floor is split on long pauses")
    func pauseSplitting() {
        let words = [
            Word(text: "First", speaker: "spk_1", startMs: 0, endMs: 500),
            Word(text: "thought", speaker: "spk_1", startMs: 500, endMs: 1_000),
            // four seconds of silence, then the same voice resumes
            Word(text: "Second", speaker: "spk_1", startMs: 5_000, endMs: 5_500),
            Word(text: "thought", speaker: "spk_1", startMs: 5_500, endMs: 6_000)
        ]
        let turns = Transcript.turns(from: words)
        #expect(turns.count == 2)
        #expect(turns[0].text == "First thought")
        #expect(turns[1].startMs == 5_000)
    }

    @Test("punctuation does not get a space in front of it")
    func spacing() {
        let words = ["Well", ",", "yes", "."].enumerated().map { i, w in
            Word(text: w, speaker: "spk_1", startMs: i * 100, endMs: i * 100 + 50)
        }
        #expect(Transcript.turns(from: words)[0].text == "Well, yes.")
    }
}
