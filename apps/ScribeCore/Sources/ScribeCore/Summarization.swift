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

    public static func merged(_ all: [ExtractedFacts]) -> ExtractedFacts {
        var out = ExtractedFacts()
        for facts in all {
            out.decisions += facts.decisions
            out.actionItems += facts.actionItems
            out.openQuestions += facts.openQuestions
            out.topics += facts.topics
        }
        out.decisions = out.decisions.deduplicatedCaseInsensitively()
        out.openQuestions = out.openQuestions.deduplicatedCaseInsensitively()
        out.topics = out.topics.deduplicatedCaseInsensitively()
        // Two windows can each catch the same commitment, worded slightly
        // differently. Match on task text alone, keeping whichever copy named
        // an owner -- a window that saw the follow-up often knows who took it.
        var byTask: [String: MeetingSummary.ActionItem] = [:]
        for item in out.actionItems {
            let key = item.task.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = byTask[key] {
                byTask[key] = MeetingSummary.ActionItem(
                    task: existing.task,
                    owner: existing.owner ?? item.owner,
                    due: existing.due ?? item.due
                )
            } else {
                byTask[key] = item
            }
        }
        out.actionItems = Array(byTask.values).sorted { $0.task < $1.task }
        return out
    }

    /// Rendered for the reduce step: compact, and far smaller than the
    /// transcript it came from -- a 111-minute meeting collapses to something
    /// that fits one 4k call with room for the answer.
    public var digest: String {
        var out = ""
        func section(_ name: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            out += "\(name):\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        section("Topics", topics)
        section("Decisions", decisions)
        section("Action items", actionItems.map {
            var line = $0.task
            if let owner = $0.owner, !owner.isEmpty { line += " — \(owner)" }
            if let due = $0.due, !due.isEmpty { line += " (\(due))" }
            return line
        })
        section("Open questions", openQuestions)
        return out.isEmpty ? "Nothing specific was extracted." : out
    }
}

private extension [String] {
    /// Same point made twice in two windows is one point.
    func deduplicatedCaseInsensitively() -> [String] {
        var seen = Set<String>()
        return filter { line in
            let key = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}
