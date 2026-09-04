import Foundation

/// Splitting a long transcript into pieces a small context window can hold.
///
/// Shared because both local summarisers need it and they need it to behave the
/// same way: Apple's on-device model has a hard 4096-token window, and a local
/// 4B model has a large one but still finite. Splitting on turn boundaries
/// rather than character counts keeps a speaker's sentence intact, which is the
/// difference between "Wilma will handle the alignment" surviving as one fact
/// and being cut in half across two windows.
public enum TranscriptWindows {

    /// Roughly four characters per token for English. Deliberately an
    /// underestimate of capacity: overshooting the window throws.
    public static func split(_ transcript: String, maxCharacters: Int) -> [String] {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
        var windows: [String] = []
        var current = ""

        for line in lines {
            // A single turn longer than the window is rare but real -- someone
            // holding the floor uninterrupted. Emit it alone and let the model
            // truncate rather than dropping it.
            if line.count >= maxCharacters {
                if !current.isEmpty { windows.append(current); current = "" }
                windows.append(String(line))
                continue
            }
            if current.count + line.count + 1 > maxCharacters {
                windows.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n" }
            current += line
        }
        if !current.isEmpty { windows.append(current) }
        return windows
    }
}

/// What one pass over a window found. Deliberately small and factual: these are
/// things stated in the passage, not judgements about the meeting as a whole.
public struct ExtractedFacts: Sendable {
    public var decisions: [String] = []
    public var actionItems: [MeetingSummary.ActionItem] = []
    public var openQuestions: [String] = []
    public var topics: [String] = []

    public init(
        decisions: [String] = [], actionItems: [MeetingSummary.ActionItem] = [],
        openQuestions: [String] = [], topics: [String] = []
    ) {
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.topics = topics
    }

    /// How long a deadline is allowed to be before we stop believing it is one.
    ///
    /// Asked for "timing in the speaker's own words", a small model will
    /// happily paste back a whole paragraph of transcript. A real deadline is
    /// "by Friday" or "end of Q3"; anything sentence-length is the model
    /// having lost the plot, and it is better to show no deadline than a
    /// hundred words of somebody thinking aloud.
    static let maximumDueLength = 60

    /// Longest a single commitment can be before it is dropped as a
    /// mis-extraction rather than a task.
    static let maximumTaskLength = 200

    /// Things a model writes when it means "empty".
    ///
    /// Asked to leave a field blank when the transcript does not say, small
    /// models very often write the *words* instead -- so an action item comes
    /// back "due Not specified", which reads in the UI as though a deadline
    /// exists. These are all empty.
    static let placeholders: Set<String> = [
        "", "n/a", "na", "none", "null", "nil", "tbd", "tba", "unknown",
        "not specified", "unspecified", "not stated", "not mentioned",
        "not given", "no due date", "no deadline", "no owner", "empty",
        "not applicable", "unclear", "not determined", "immediately",
    ]

    /// Nil for anything that is blank, or a model's way of writing blank.
    static func meaningful(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !placeholders.contains(trimmed.lowercased())
        else { return nil }
        return trimmed
    }

    public static func merged(_ all: [ExtractedFacts]) -> ExtractedFacts {
        // Rank by how many windows mentioned a thing. A point raised in three
        // passages matters more than one raised in passing, and this is the
        // only signal available -- no window ever sees the meeting, so nothing
        // here can judge importance directly.
        func ranked(_ lists: [[String]]) -> [String] {
            var counts: [String: (text: String, n: Int, first: Int)] = [:]
            var order = 0
            for list in lists {
                for raw in list {
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let key = text.lowercased()
                    if let existing = counts[key] {
                        counts[key] = (existing.text, existing.n + 1, existing.first)
                    } else {
                        counts[key] = (text, 1, order)
                        order += 1
                    }
                }
            }
            return counts.values
                .sorted { $0.n != $1.n ? $0.n > $1.n : $0.first < $1.first }
                .map(\.text)
        }

        var out = ExtractedFacts()
        out.decisions = ranked(all.map(\.decisions))
        out.openQuestions = ranked(all.map(\.openQuestions))
        out.topics = ranked(all.map(\.topics))

        // Two windows can each catch the same commitment, worded slightly
        // differently. Match on task text, keeping whichever copy named an
        // owner -- a window that saw the follow-up often knows who took it.
        var byTask: [String: (item: MeetingSummary.ActionItem, n: Int, first: Int)] = [:]
        var order = 0
        for item in all.flatMap(\.actionItems) {
            let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty, task.count <= maximumTaskLength else { continue }
            // A "deadline" the length of a paragraph is the model pasting
            // transcript back rather than reading a date off it.
            let due = meaningful(item.due)
            let cleanDue = (due?.count ?? .max) <= maximumDueLength ? due : nil
            let cleanOwner = meaningful(item.owner)

            let key = task.lowercased()
            if let existing = byTask[key] {
                byTask[key] = (
                    MeetingSummary.ActionItem(
                        task: existing.item.task,
                        owner: existing.item.owner ?? cleanOwner,
                        due: existing.item.due ?? cleanDue
                    ),
                    existing.n + 1, existing.first
                )
            } else {
                byTask[key] = (
                    MeetingSummary.ActionItem(task: task, owner: cleanOwner, due: cleanDue),
                    1, order
                )
                order += 1
            }
        }
        out.actionItems = byTask.values
            .sorted { $0.n != $1.n ? $0.n > $1.n : $0.first < $1.first }
            .map(\.item)
        return out
    }

    /// Everything the meeting produced, rendered small enough to reduce over.
    ///
    /// The cap is the whole point. A 111-minute meeting really did yield 80
    /// topics, 38 commitments and 131 "open questions" -- most of the last
    /// being small talk a per-passage reader cannot tell from a real question.
    /// Rendered whole that came to ~3,500 tokens, which overflowed the 4,096
    /// the on-device model has for prompt, schema and answer together. The
    /// model then never saw the facts at all and wrote its overview from the
    /// example in the instructions instead: a meeting about vehicle inventory
    /// was summarised as "Q4 migration timing".
    ///
    /// So take the best-attested few of each. Ranking already put them first.
    public func digest(
        maxTopics: Int = 12,
        maxDecisions: Int = 12,
        maxActionItems: Int = 12,
        maxOpenQuestions: Int = 8
    ) -> String {
        var out = ""
        func section(_ name: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            out += "\(name):\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        section("Topics", Array(topics.prefix(maxTopics)))
        section("Decisions", Array(decisions.prefix(maxDecisions)))
        section("Action items", actionItems.prefix(maxActionItems).map {
            var line = $0.task
            if let owner = $0.owner, !owner.isEmpty { line += " — \(owner)" }
            if let due = $0.due, !due.isEmpty { line += " (\(due))" }
            return line
        })
        section("Open questions", Array(openQuestions.prefix(maxOpenQuestions)))
        return out.isEmpty ? "Nothing specific was extracted." : out
    }
}
