import Foundation
import FluidAudio
import ScribeCore

/// Works out who spoke when, on this device.
///
/// One pass over the whole recording, which is the point. Gemini could only
/// diarize 30 minutes at a time, so a long meeting was cut into overlapping
/// pieces and the labels matched across every seam -- and anyone silent across
/// a boundary came back as a new person. A 111-minute meeting with three people
/// in it produced eight speakers. Clustering the entire recording at once has
/// no seams, so that failure has nowhere to happen.
///
/// FluidAudio's offline pipeline: pyannote community-1 segmentation, WeSpeaker
/// embeddings, VBx clustering with PLDA. CoreML on the Neural Engine, about
/// 30 MB fetched once. Measured at ~90x realtime with the models warm.
///
/// Linked directly rather than run as a sidecar. Humla shells out to a Swift
/// helper only because their app is Rust; we are already Swift, so the process
/// boundary would buy nothing and cost a JSON protocol to keep in step.
actor FluidDiarizer {

    /// Held between meetings: loading and compiling the models takes ~14
    /// seconds cold and ~0.2 warm, and there is no reason to pay it twice.
    private var models: OfflineDiarizerModels?

    enum Progress: Sendable, Equatable {
        case downloadingModels
        case analysing(Double)
    }

    /// Prepare the models without diarizing anything, so the download happens
    /// before someone is waiting on a finished recording.
    func warmUp() async throws {
        _ = try await loadedModels()
    }

    private func loadedModels() async throws -> OfflineDiarizerModels {
        if let models { return models }
        let loaded = try await OfflineDiarizerModels.load()
        models = loaded
        return loaded
    }

    /// Segment `fileURL` into per-speaker stretches.
    ///
    /// Unpinned by default, because pinning to a guess is worse than not
    /// pinning at all. Measured on a real 111-minute meeting with four
    /// speakers, where the roster named only three of them:
    ///
    ///     unpinned                  3 speakers   (under by 1)
    ///     exactly roster (3)        3 speakers   (under by 1)
    ///     min roster, no max        3 speakers   (under by 1)
    ///     min roster, max roster+4  3 speakers   (under by 1)
    ///     exactly truth (4)         4 speakers   correct
    ///
    /// Two things follow. `min` and `max` do not move the answer at all --
    /// only `exactly` does. And `exactly <roster>` is only right when the
    /// roster is right: name four attendees and have one stay silent, and it
    /// forces the clusterer to split somebody in two, which is the
    /// over-counting bug we came here to escape.
    ///
    /// So the count is never guessed. `retryWithExactly` exists for the
    /// caller to re-run once it has *evidence* of an under-count -- see
    /// `RecordingSession`, which uses the live tags, because a tap is an
    /// observation that somebody spoke rather than a guess that they might.
    func segments(
        in fileURL: URL,
        retryWithExactly exactCount: Int? = nil,
        report: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> [SpeakerSegment] {
        if models == nil { report?(.downloadingModels) }
        let models = try await loadedModels()

        var config = OfflineDiarizerConfig()
        // Only ever set from evidence, and never to a count so small it could
        // not be a conversation.
        if let exactCount, exactCount > 1 {
            config = config.withSpeakers(exactly: exactCount)
        }

        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)

        // The URL overload streams the file memory-mapped rather than reading
        // it all in. A two-hour recording is large and this machine is often
        // already short of memory.
        let result = try await manager.process(fileURL) { done, total in
            guard total > 0 else { return }
            report?(.analysing(Double(done) / Double(total)))
        }

        return result.segments.map {
            SpeakerSegment(
                speakerId: $0.speakerId,
                startMs: Int($0.startTimeSeconds * 1000),
                endMs: Int($0.endTimeSeconds * 1000)
            )
        }
    }
}
