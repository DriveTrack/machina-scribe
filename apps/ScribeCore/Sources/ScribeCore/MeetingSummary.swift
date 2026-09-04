import Foundation

/// The structured summary of a meeting.
public struct MeetingSummary: Codable, Hashable, Sendable {

    public struct ActionItem: Codable, Hashable, Sendable, Identifiable {
        public var task: String
        /// Who took it on, when the transcript actually says. Never guessed.
        public var owner: String?
        /// Whatever the transcript said about timing, in its own words
        /// ("by Friday", "end of Q3") rather than a fabricated date.
        public var due: String?

        public var id: String { "\(task)-\(owner ?? "")" }

        public init(task: String, owner: String? = nil, due: String? = nil) {
            self.task = task
            self.owner = owner
            self.due = due
        }
    }

    /// A few words naming what the meeting was actually about, used to replace
    /// the date-only title a meeting starts life with.
    public var title: String
    public var summary: String
    public var topics: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]

    public init(
        title: String,
        summary: String,
        topics: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [String] = []
    ) {
        self.title = title
        self.summary = summary
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    public enum CodingKeys: String, CodingKey {
        case title, summary, topics, decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    /// Local models routinely wrap their JSON in a fenced block, a sentence of
    /// preamble, or a `<think>` block before it. Take the outermost braces
    /// rather than insisting on a clean response -- a summary that parses is
    /// worth more than a principled rejection of one that nearly did.
    public static func decoding(_ text: String) -> MeetingSummary? {
        var candidates = [text]
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            candidates.insert(String(text[start...end]), at: 0)
        }
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let summary = try? JSONDecoder().decode(MeetingSummary.self, from: data) {
                return summary
            }
        }
        return nil
    }
}
