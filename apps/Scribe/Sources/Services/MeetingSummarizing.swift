import Foundation
import ScribeCore

/// Anything that can turn a transcript into a `MeetingSummary`.
protocol MeetingSummarizing: Sendable {
    /// Shown in status text, so the user knows where their transcript went.
    var label: String { get }
    /// False when the transcript leaves the device.
    var isLocal: Bool { get }

    func summarize(title: String?, transcript: String, notes: String?) async throws -> MeetingSummary
}

