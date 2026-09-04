import Foundation
import Observation
import ScribeCore

/// Drives one meeting from the first tap of Record to a stored transcript.
@MainActor
@Observable
final class RecordingSession {

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing(step: String)
        case finished(meeting: UUID, namedByTags: Int, unmatched: [String])
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var tags: [LiveTag] = []
    private(set) var meetingId: UUID?
    /// Named before the meeting starts. The tagging pad shows these rather than
    /// everyone ever recorded, so the right button is easy to hit mid-sentence.
    var attendees: [String] = []

    let recorder = AudioRecorder()
    /// Recordings survive for a short window after the meeting so voices can
    /// be identified by ear; the archive enforces the deletion.
    var archive = RecordingArchive()
    /// Fired once a transcript is stored, so lists can refresh themselves.
    var onTranscriptSaved: (() -> Void)?
    private let store: LocalStore
    /// Which engine to use. Read once when the session is built so a setting
    /// changed mid-meeting cannot swap engines underneath a running recording.
    private let engine: AppState.TranscriptionEngine
    /// Held across meetings: the CoreML models cost ~14s to compile the first
    /// time and ~0.2s afterwards.
    private let diarizer = FluidDiarizer()
    /// Kept when transcription fails so the meeting can be retried rather than lost.
    private var pendingAudio: (url: URL, durationMs: Int)?

    init(store: LocalStore, engine: AppState.TranscriptionEngine = .onDevice) {
        self.store = store
        self.engine = engine
    }

    var isRecording: Bool { recorder.isRecording }

    // MARK: - Recording

    /// Someone turned up who was not on the list.
    func addAttendee(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !attendees.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        attendees.append(trimmed)
        if let meeting = meetingId {
            Task { try? await store.setAttendees(meeting: meeting, names: attendees) }
        }
    }

    func start(title: String?, location: String?) async {
        guard await recorder.requestPermission() else {
            phase = .failed("Microphone access was denied. Grant it in system settings.")
            return
        }
        // Asked for before recording starts so the permission sheet does not
        // appear over a meeting already in progress. A refusal only costs the
        // live preview; the recording itself is unaffected.
        _ = await recorder.live.prepare()

        do {
            let id = try await store.startMeeting(title: title, location: location)
            meetingId = id
            tags = []
            try? await store.setAttendees(meeting: id, names: attendees)
            try recorder.start()
            phase = .recording
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// "The person speaking right now is X."
    ///
    /// This does not cut the transcript anywhere. It records a moment in time;
    /// after transcription the moment lands inside one diarized turn, which
    /// identifies that voice for the entire meeting.
    func tag(_ name: String) {
        tag(name, atMs: recorder.currentOffsetMs)
    }

    /// Tag a moment that has already passed -- what tapping a line of the live
    /// preview does. Pointing at text you can see beats catching someone
    /// mid-sentence, and it removes the reaction lag that a live tap carries.
    func tag(_ name: String, atMs: Int) {
        guard recorder.isRecording, let meeting = meetingId else { return }
        tags.append(LiveTag(name: name, atMs: atMs))

        // Written through immediately: a tap that only lives in memory is lost
        // if the app is killed mid-meeting.
        Task { try? await store.addLiveTag(meeting: meeting, name: name, atMs: atMs) }
    }

    /// Who, if anyone, has been attributed to the moment this text covers.
    func taggedName(from startMs: Int, to endMs: Int) -> String? {
        tags.last { $0.atMs >= startMs && $0.atMs <= endMs }?.name
    }

    // MARK: - Finishing

    func stop() async {
        guard let stopped = recorder.stop(), let meeting = meetingId else {
            phase = .idle
            return
        }
        // Out of the OS temporary directory before anything else is attempted.
        // Transcribing two hours of audio takes a while and can fail; the
        // system is free to empty its temp directory in the meantime, and a
        // meeting cannot be recorded again.
        let safe = archive.stash(stopped.url, for: meeting)
        pendingAudio = (safe, stopped.durationMs)
        await transcribe(meeting: meeting, audio: (safe, stopped.durationMs))
    }

    func retry() async {
        guard let meeting = meetingId, let audio = pendingAudio else { return }
        await transcribe(meeting: meeting, audio: audio)
    }

    /// Pick a recording back up after the app was closed.
    ///
    /// A failure that happened last night should still be recoverable this
    /// morning; without this the only path back was keeping the app open.
    func resume(meeting: UUID, durationMs: Int) async {
        guard let url = archive.pendingURL(for: meeting) else { return }
        meetingId = meeting
        pendingAudio = (url, durationMs)
        await transcribe(meeting: meeting, audio: (url, durationMs))
    }

    /// Give up on a recording and delete it.
    func abandon(meeting: UUID) {
        ChunkCache(meeting: meeting).clear()
        archive.discardPending(meeting)
        pendingAudio = nil
    }

    private func transcribe(meeting: UUID, audio: (url: URL, durationMs: Int)) async {
        do {
            phase = .transcribing(step: "Saving meeting")
            try await store.markTranscribing(meeting, durationMs: audio.durationMs)

            let turns: [Turn]
            let unmatched: [String]
            switch engine {
            case .onDevice:
                turns = try await transcribeOnDevice(meeting: meeting, audio: audio)
                unmatched = []
            case .gemini:
                (turns, unmatched) = try await transcribeWithGemini(meeting: meeting, audio: audio)
            }

            let named = try await store.saveTranscript(meeting: meeting, turns: turns)
            try await store.markReady(meeting)

            ChunkCache(meeting: meeting).clear()
            archive.settle(meeting)
            pendingAudio = nil
            onTranscriptSaved?()
            phase = .finished(meeting: meeting, namedByTags: named, unmatched: unmatched)
        } catch {
            // The recording is safe in the pending directory and, on the Gemini
            // path, the parts already transcribed are cached -- so retrying
            // resumes rather than starting over.
            try? await store.markFailed(meeting, error.localizedDescription)
            phase = .failed(error.localizedDescription)
        }
    }

    /// Transcribe and diarize here, with nothing uploaded and nothing charged.
    ///
    /// Two passes over the same recording, and keeping them separate is the
    /// whole design. Transcription gives words with timings but no idea who
    /// spoke; diarization gives speaker stretches but no words. Joining them on
    /// time is exact, and -- unlike the chunked path below -- neither pass has a
    /// length limit, so there are no seams for a speaker to be lost across.
    private func transcribeOnDevice(
        meeting: UUID,
        audio: (url: URL, durationMs: Int)
    ) async throws -> [Turn] {
        let transcriber = AppleSpeechTranscriber()

        phase = .transcribing(step: "Transcribing on this device")
        let heard = try await transcriber.words(in: audio.url) { [weak self] progress in
            Task { @MainActor in
                guard case .progress(let fraction) = progress else { return }
                self?.phase = .transcribing(
                    step: "Transcribing on this device — \(Int(fraction * 100))%"
                )
            }
        }
        guard !heard.isEmpty else {
            throw ScribeError.transcription("No speech was recognised in this recording.")
        }

        phase = .transcribing(step: "Working out who spoke")
        let report: @Sendable (FluidDiarizer.Progress) -> Void = { [weak self] progress in
            Task { @MainActor in
                switch progress {
                case .downloadingModels:
                    self?.phase = .transcribing(step: "Getting the speaker model (about 30 MB)")
                case .analysing(let fraction):
                    self?.phase = .transcribing(
                        step: "Working out who spoke — \(Int(fraction * 100))%"
                    )
                }
            }
        }

        var segments = try await diarizer.segments(in: audio.url, report: report)

        // Second pass, only on evidence of an under-count.
        //
        // Every tap during the meeting is an observation that a particular
        // person was speaking. If more distinct people were tapped than the
        // clusterer found voices, it merged two of them -- and unlike the
        // attendee roster, which is a guest list and can name people who never
        // say a word, a tap cannot over-state: somebody had to be talking for
        // it to be made.
        //
        // Pinning to a count we merely hoped for is what re-introduces the
        // over-counting this whole design exists to avoid, so this runs only
        // when the two numbers actually disagree.
        let observed = Set(tags.map { $0.name.lowercased() }).count
        let found = Set(segments.map(\.speakerId)).count
        if observed > found, observed > 1 {
            phase = .transcribing(
                step: "Heard \(observed) people but separated \(found) — looking again"
            )
            let retried = try await diarizer.segments(
                in: audio.url, retryWithExactly: observed, report: report
            )
            // Keep it only if it actually did better. A retry that comes back
            // with the same count, or fewer, has told us the audio does not
            // support the split, and the first answer was the honest one.
            if Set(retried.map(\.speakerId)).count > found { segments = retried }
        }

        let attributed = Diarization.absorbSingleWordFlickers(
            Diarization.assign(words: heard, to: segments)
        )
        return Transcript.turns(from: attributed)
    }

    /// The chunked path. Only Gemini needs it, and only because Gemini caps
    /// diarization at 30 minutes.
    private func transcribeWithGemini(
        meeting: UUID,
        audio: (url: URL, durationMs: Int)
    ) async throws -> (turns: [Turn], unmatched: [String]) {
        guard let key = Keychain.get("gemini") else {
            throw ScribeError.missingAPIKey
        }

        phase = .transcribing(step: "Preparing audio")
        let pieces = try await AudioChunker.split(audio.url)

        let transcriber = GeminiTranscriber(apiKey: key)
        let cache = ChunkCache(meeting: meeting)
        var chunks: [Chunk] = []
        /// Whether a request has actually gone out yet, so pacing does not
        /// delay a run that is only replaying cached parts.
        var sentAnything = false

        for (n, piece) in pieces.enumerated() {
            let label = pieces.count == 1 ? "" : " part \(n + 1) of \(pieces.count)"

            // A part already transcribed on an earlier attempt costs nothing to
            // reuse, and re-sending it is what exhausts the quota that caused
            // the failure in the first place.
            if let done = cache.turns(at: n, offsetMs: piece.offsetMs) {
                phase = .transcribing(step: "Reusing\(label)")
                chunks.append(Chunk(offsetMs: piece.offsetMs, turns: done))
                continue
            }

            // Space parts out rather than firing them back to back; the
            // per-minute token budget is what a run of long chunks exhausts.
            if sentAnything {
                phase = .transcribing(step: "Pacing before\(label)")
                try await Task.sleep(for: GeminiTranscriber.pacingBetweenParts)
            }

            phase = .transcribing(step: "Uploading\(label)")
            let turns = try await transcriber.transcribe(fileURL: piece.url) { [weak self] progress in
                Task { @MainActor in
                    switch progress {
                    case .uploading:
                        self?.phase = .transcribing(step: "Uploading\(label)")
                    case .transcribing:
                        self?.phase = .transcribing(step: "Transcribing\(label)")
                    case .waiting(let seconds, let attempt, let total):
                        self?.phase = .transcribing(
                            step: "Rate limited — waiting \(Int(seconds))s, retry \(attempt) of \(total)\(label)"
                        )
                    }
                }
            }
            cache.save(turns, at: n, offsetMs: piece.offsetMs)
            chunks.append(Chunk(offsetMs: piece.offsetMs, turns: turns))
            sentAnything = true
        }

        phase = .transcribing(step: "Matching speakers")
        let stitched = Stitcher.stitch(chunks, overlapMs: GeminiTranscriber.overlapMs)

        // The chunks were only ever a way past the 30-minute cap.
        let fm = FileManager.default
        for piece in pieces where piece.url != audio.url {
            try? fm.removeItem(at: piece.url)
        }
        return (stitched.turns, stitched.unmatchedLabels)
    }

    func reset() {
        phase = .idle
        tags = []
        meetingId = nil
        pendingAudio = nil
    }
}
