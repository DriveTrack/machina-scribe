import Foundation

/// Anything that can turn a recording into timed words.
///
/// Words rather than turns, deliberately. Turns are a projection -- grouping
/// words by voice and pause, which `Transcript.turns(from:)` already does --
/// but the word timings themselves are not recoverable once you have collapsed
/// them, and they are exactly what aligning a separate speaker-diarization
/// pass needs. An engine that knows who spoke fills in `Word.speaker`; one that
/// does not leaves it nil for a later pass to supply.
public protocol AudioTranscriber: Sendable {

    /// The longest single request this engine will accept, or nil when it will
    /// take a recording of any length.
    ///
    /// This is the whole reason chunking exists. Gemini caps diarization at 30
    /// minutes, so a two-hour meeting has to be cut into overlapping pieces and
    /// the speaker labels matched back together across every seam -- and each
    /// seam is a chance to re-identify the same person as somebody new. An
    /// engine that returns nil here needs none of that machinery: no chunks, no
    /// overlap, no stitching, and no way for the meeting to sprout phantom
    /// speakers at a boundary.
    var maxChunkMs: Int? { get }

    /// Whether this engine reports who is speaking.
    ///
    /// False means `Word.speaker` comes back nil throughout and something else
    /// has to say who spoke -- a diarization pass, or failing that a single
    /// unnamed speaker.
    var identifiesSpeakers: Bool { get }

    /// A name for this engine, for status text and error messages.
    var label: String { get }

    func words(
        in fileURL: URL,
        report: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> [Word]
}

/// What a transcriber is doing, so the UI can say so rather than showing one
/// stale line for minutes at a time.
public enum TranscriptionProgress: Sendable, Equatable {
    case preparing
    case uploading
    case transcribing
    /// Fraction complete, 0...1, where the engine can report it.
    case progress(Double)
    case waiting(seconds: TimeInterval, attempt: Int, of: Int)
}
