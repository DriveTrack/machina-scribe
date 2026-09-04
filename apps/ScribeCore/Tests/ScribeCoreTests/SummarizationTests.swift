import Testing
@testable import ScribeCore

@Suite("Fitting a long meeting through a small window")
struct TranscriptWindowsTests {

    @Test("a short transcript stays whole")
    func shortTranscript() {
        let text = "Jose: hello\nChris: hi"
        #expect(TranscriptWindows.split(text, maxCharacters: 1000) == [text])
    }

    @Test("windows never exceed the limit")
    func respectsLimit() {
        let lines = (0..<200).map { "Speaker \($0 % 3): " + String(repeating: "word ", count: 10) }
        let windows = TranscriptWindows.split(lines.joined(separator: "\n"), maxCharacters: 500)
        #expect(windows.count > 1)
        for w in windows { #expect(w.count <= 500 || !w.contains("\n")) }
    }

    @Test("a turn is never cut in half")
    func keepsTurnsIntact() {
        let lines = (0..<40).map { "Speaker: turn number \($0) said something here" }
        let windows = TranscriptWindows.split(lines.joined(separator: "\n"), maxCharacters: 200)
        // Every original line appears intact in exactly one window.
        for line in lines {
            #expect(windows.filter { $0.contains(line) }.count == 1)
        }
    }

    @Test("a single turn longer than the window is emitted alone rather than dropped")
    func oversizedTurn() {
        let huge = "Speaker: " + String(repeating: "x", count: 900)
        let windows = TranscriptWindows.split("short line\n\(huge)\nanother", maxCharacters: 100)
        #expect(windows.contains(huge))
        #expect(windows.joined().contains("another"))
    }

    @Test("nothing is lost across the split")
    func losesNothing() {
        let lines = (0..<50).map { "Speaker \($0 % 4): line \($0)" }
        let windows = TranscriptWindows.split(lines.joined(separator: "\n"), maxCharacters: 300)
        for line in lines { #expect(windows.contains { $0.contains(line) }) }
    }
}

@Suite("Merging what each window found")
struct ExtractedFactsTests {

    @Test("the same decision seen twice is recorded once")
    func dedupes() {
        let merged = ExtractedFacts.merged([
            ExtractedFacts(decisions: ["Ship on Friday"], topics: ["timing"]),
            ExtractedFacts(decisions: ["ship on friday"], topics: ["Timing"]),
        ])
        #expect(merged.decisions == ["Ship on Friday"])
        #expect(merged.topics == ["timing"])
    }

    @Test("a commitment keeps the owner whichever window found it")
    func keepsOwner() {
        let merged = ExtractedFacts.merged([
            ExtractedFacts(actionItems: [.init(task: "Fix alignment", owner: nil, due: nil)]),
            ExtractedFacts(actionItems: [.init(task: "fix alignment", owner: "Wilma", due: "Friday")]),
        ])
        #expect(merged.actionItems.count == 1)
        #expect(merged.actionItems[0].owner == "Wilma")
        #expect(merged.actionItems[0].due == "Friday")
    }

    @Test("distinct commitments are all kept")
    func keepsDistinct() {
        let merged = ExtractedFacts.merged([
            ExtractedFacts(actionItems: [.init(task: "A", owner: "Jose")]),
            ExtractedFacts(actionItems: [.init(task: "B", owner: "Chris")]),
        ])
        #expect(merged.actionItems.count == 2)
    }

    @Test("blank entries are dropped rather than rendered as empty bullets")
    func dropsBlanks() {
        let merged = ExtractedFacts.merged([ExtractedFacts(decisions: ["", "  ", "Real one"])])
        #expect(merged.decisions == ["Real one"])
    }

    @Test("the digest is far smaller than the transcript it came from")
    func digestIsSmall() {
        let facts = ExtractedFacts(
            decisions: ["Ship Friday"],
            actionItems: [.init(task: "Fix alignment", owner: "Wilma", due: "Friday")],
            openQuestions: ["Do we bump the target?"],
            topics: ["timing"]
        )
        let digest = facts.digest
        #expect(digest.contains("Ship Friday"))
        #expect(digest.contains("Fix alignment — Wilma (Friday)"))
        #expect(digest.contains("Do we bump the target?"))
    }

    @Test("nothing extracted still says so rather than rendering blank")
    func emptyDigest() {
        #expect(ExtractedFacts.merged([]).digest == "Nothing specific was extracted.")
    }
}

@Suite("Reading a local model's reply")
struct SummaryDecodingTests {

    private let valid = """
    {"title":"Q4 timing","summary":"We settled the date.","topics":["timing"],
     "decisions":["Ship Friday"],"action_items":[{"task":"Fix it","owner":"Wilma","due":"Friday"}],
     "open_questions":[]}
    """

    @Test("clean JSON decodes")
    func clean() {
        let s = MeetingSummary.decoding(valid)
        #expect(s?.title == "Q4 timing")
        #expect(s?.actionItems.first?.owner == "Wilma")
    }

    @Test("JSON inside a code fence decodes")
    func fenced() {
        #expect(MeetingSummary.decoding("```json\n\(valid)\n```")?.title == "Q4 timing")
    }

    @Test("JSON after a reasoning block decodes")
    func afterThinking() {
        let reply = "<think>The user wants a summary. Let me check the decisions.</think>\n\(valid)"
        #expect(MeetingSummary.decoding(reply)?.title == "Q4 timing")
    }

    @Test("JSON after a sentence of preamble decodes")
    func withPreamble() {
        #expect(MeetingSummary.decoding("Here is the summary:\n\(valid)")?.title == "Q4 timing")
    }

    @Test("a reply with no JSON at all returns nil rather than a blank summary")
    func noJSON() {
        #expect(MeetingSummary.decoding("I could not summarise that.") == nil)
    }

    @Test("JSON missing a required field returns nil")
    func incomplete() {
        #expect(MeetingSummary.decoding(#"{"title":"Only a title"}"#) == nil)
    }
}
