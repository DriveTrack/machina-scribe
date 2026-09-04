import Foundation
import ScribeCore
import FoundationModels

/// Summarises with the model built into the OS. Free, offline, and it costs
/// this app no memory at all -- the model lives in a system process and is
/// shared with everything else that uses it, which matters on a machine that
/// records meetings while Docker and an editor are already resident.
///
/// The catch is a hard **4096-token context window**, shared by the prompt, the
/// response and the session's accumulated history. A 111-minute meeting is
/// about 28,000 tokens, roughly seven times the whole window.
///
/// So this maps and reduces -- but it extracts *structure* on the way in rather
/// than prose. Summarising each tenth of a meeting into a paragraph and gluing
/// the paragraphs together is what loses the thread, because no step ever sees
/// the meeting. Decisions and commitments are local facts: "Wilma will handle
/// the alignment" is fully present in the passage where it was said, and a
/// small model is good at spotting it there. Those facts then collapse to
/// around 1,500 tokens, which fits a single call with room to write the
/// narrative once, over all of them.
struct AppleSummarizer: MeetingSummarizing {

    let label = "On this device"
    let isLocal = true

    /// Well under the 4096-token window in characters, leaving room for the
    /// instructions, the schema and the answer.
    private let windowCharacters = 6_000

    /// The reduce prompt's ceiling, in characters. ~4 chars per token puts
    /// this near 1,500 tokens, leaving the rest of the window for the
    /// instructions, the schema and the overview itself.
    static let maximumReduceCharacters = 6_000

    enum Failure: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): why
            }
        }
    }

    /// Whether the on-device model can be used right now.
    ///
    /// Worth checking before offering it: availability is not ours to control.
    /// Apple Intelligence is a system setting the user has to switch on, and
    /// the model is also unavailable on ineligible devices and while it is
    /// still downloading.
    static var availability: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to summarise on this device."
        case .unavailable(.deviceNotEligible):
            return "This device cannot run Apple's on-device model."
        case .unavailable(.modelNotReady):
            return "Apple's on-device model is still downloading. Try again shortly."
        case .unavailable(let other):
            return "Apple's on-device model is unavailable (\(other))."
        }
    }

    // MARK: - Extraction schema

    @Generable(description: "Facts stated in one passage of a meeting transcript.")
    struct WindowFacts {
        @Guide(description: "Things settled in this passage. Empty if nothing was settled.")
        var decisions: [String]

        @Guide(description: "Things a named person committed to doing.")
        var commitments: [Commitment]

        @Guide(description: "Questions raised here and left unanswered.")
        var openQuestions: [String]

        @Guide(description: "Subjects discussed, two or three words each.")
        var topics: [String]
    }

    @Generable
    struct Commitment {
        @Guide(description: "What was committed to, in one short sentence.")
        var task: String
        @Guide(description: "The speaker who took it on. Empty if the transcript does not say.")
        var owner: String
        @Guide(description: "Timing in the speaker's own words, like 'by Friday'. Empty if not said.")
        var due: String
    }

    @Generable(description: "The overall shape of a meeting.")
    struct Overview {
        @Guide(description: "Three to six words naming the subject. No date, not the word 'meeting'.")
        var title: String
        @Guide(description: "Two or three sentences on what the meeting was for and where it landed.")
        var summary: String
    }

    // MARK: - Summarising

    func summarize(title: String?, transcript: String, notes: String?) async throws -> MeetingSummary {
        if let why = Self.availability { throw Failure.unavailable(why) }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScribeError.transcription("There is no transcript to summarise.")
        }

        let windows = TranscriptWindows.split(transcript, maxCharacters: windowCharacters)
        var perWindow: [ExtractedFacts] = []

        for window in windows {
            // A fresh session per window, deliberately. A session accumulates
            // its own transcript inside the same 4096 tokens, so reusing one
            // would run out partway through a long meeting -- and every window
            // is independent anyway.
            let session = LanguageModelSession(instructions: Self.extractionInstructions)
            do {
                let facts = try await session.respond(
                    to: "Passage:\n\(window)",
                    generating: WindowFacts.self,
                    options: GenerationOptions(temperature: 0.1)
                ).content
                perWindow.append(
                    ExtractedFacts(
                        decisions: facts.decisions,
                        actionItems: facts.commitments.map {
                            MeetingSummary.ActionItem(
                                task: $0.task,
                                owner: $0.owner.isEmpty ? nil : $0.owner,
                                due: $0.due.isEmpty ? nil : $0.due
                            )
                        },
                        openQuestions: facts.openQuestions,
                        topics: facts.topics
                    )
                )
            } catch let error as LanguageModelSession.GenerationError {
                // One refused or oversized window should not lose the other
                // nine. Meeting talk about people, money or a difficult
                // customer is exactly what trips a guardrail, and losing the
                // whole summary over one passage would be worse than a summary
                // with a gap in it.
                if case .exceededContextWindowSize = error { continue }
                if case .guardrailViolation = error { continue }
                if case .refusal = error { continue }
                throw error
            }
        }

        let facts = ExtractedFacts.merged(perWindow)

        // The reduce. Everything the meeting produced, now small enough to read
        // in one go, plus whatever the user typed at the time.
        var reducePrompt = "Meeting title so far: \(title?.isEmpty == false ? title! : "untitled")\n\n"
        if let notes, !notes.isEmpty {
            reducePrompt += "Notes the recorder typed during the meeting:\n\(notes)\n\n"
        }
        reducePrompt += "What was extracted from the transcript:\n\(facts.digest())"

        // Belt and braces on the thing that actually broke: if the prompt is
        // still too big for the window, the model would silently answer from
        // its instructions instead of these facts. Trim harder rather than let
        // that happen.
        if reducePrompt.count > Self.maximumReduceCharacters {
            reducePrompt = "Meeting title so far: \(title?.isEmpty == false ? title! : "untitled")\n\n"
                + "What was extracted from the transcript:\n"
                + facts.digest(maxTopics: 6, maxDecisions: 6, maxActionItems: 6, maxOpenQuestions: 3)
        }

        let session = LanguageModelSession(instructions: Self.overviewInstructions)
        let overview = try await session.respond(
            to: reducePrompt,
            generating: Overview.self,
            options: GenerationOptions(temperature: 0.2)
        ).content

        return MeetingSummary(
            title: overview.title,
            summary: overview.summary,
            topics: facts.topics,
            decisions: facts.decisions,
            actionItems: facts.actionItems,
            openQuestions: facts.openQuestions
        )
    }

    private static let extractionInstructions = """
    You are reading one passage from the middle of a meeting transcript and \
    writing down only what it actually says.

    - Use only this passage. Do not guess at what came before or after.
    - A commitment is someone saying they will do something. "We should \
    probably look at that" is not a commitment; put it under open questions.
    - Name an owner only when the passage names one. Leave it empty otherwise.
    - Give a deadline in the speaker's own words rather than a calendar date, \
    and keep it to a few words. If the passage does not give one in a few \
    words, leave it empty rather than quoting a sentence.
    - An open question is a real question about the work that nobody answered. \
    Passing small talk is not an open question.
    - The transcript comes from speech recognition, so expect mis-heard words. \
    Read through obvious errors rather than quoting them.
    - Empty lists are correct and expected. Most passages settle nothing.
    - This is a work meeting, and people chat. Personal conversation -- pets, \
    prices, weekend plans, what someone had for lunch -- is not a decision, a \
    commitment or an open question, however question-shaped it sounds. Leave \
    it out.
    - Where a field does not apply, return an empty string. Never write "not \
    specified", "N/A" or "unknown" -- an empty string is how you say that.
    """

    private static let overviewInstructions = """
    You are writing the top of a meeting record for the person who recorded it, \
    from facts already extracted from that meeting's transcript.

    - Use only the facts below. Every word of your answer must be traceable to \
    them. Never invent a subject, a decision, an owner or a deadline.
    - The title must name what THESE facts are about, in three to six words. \
    Do not name a topic that does not appear in them.
    - The summary is two or three sentences naming the substance: what this \
    meeting was working on, and what state it was left in.
    - Do NOT list the decisions or the tasks. The reader is shown those as \
    their own lists directly beneath your summary, so repeating them wastes \
    the only sentences you have. A summary that reads as a comma-separated run \
    of items has failed.
    - Equally, do not fill the space with nothing. "The meeting went well", \
    "there were no major issues", "various topics were discussed" say nothing \
    a reader could not have guessed, and are worse than a short summary. Every \
    sentence must carry a specific from the facts.
    - Two concrete sentences beat three vague ones.
    """

    // No worked example anywhere in these instructions, deliberately. The
    // first version illustrated a good title with "Q4 migration timing" -- and
    // when the reduce prompt overflowed the context window, the model could no
    // longer see the facts and returned that example as the answer. A meeting
    // about vehicle inventory came back titled "Q4 migration timing", with a
    // summary invented to match. An example a model can copy is an example it
    // will copy on the day it has nothing else.
}
