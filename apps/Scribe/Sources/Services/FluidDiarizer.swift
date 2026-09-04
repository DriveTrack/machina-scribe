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
    /// `expectedSpeakers` pins the cluster count, and passing it matters more
    /// than it looks. Left to decide for itself, VBx *under*-counts: a
    /// three-voice recording came back as two, merging the two people who
    /// sounded most alike -- one of whom had spoken only briefly. That is the
    /// mirror image of the chunked-Gemini bug, which over-counted. Pinning it
    /// fixed all but one turn of the same recording.
    ///
    /// We know the number because the tagging pad already collects it: the
    /// attendees named before the meeting starts. Humla has no roster and has
    /// to expose a manual "number of speakers" control instead. Pass nil when
    /// the roster is empty and let it decide.
    func segments(
        in fileURL: URL,
        expectedSpeakers: Int? = nil,
        report: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> [SpeakerSegment] {
        if models == nil { report?(.downloadingModels) }
        let models = try await loadedModels()

        var config = OfflineDiarizerConfig()
        // Only pin a count we could actually believe. One "speaker" is not a
        // conversation, and a roster far larger than the people who really
        // spoke would force the clusterer to invent divisions.
        if let expected = expectedSpeakers, expected > 1 {
            config = config.withSpeakers(exactly: expected)
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
