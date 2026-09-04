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

    let recorder = AudioRecorder()
    private let store: ScribeStore
    /// Kept when transcription fails so the meeting can be retried rather than lost.
    private var pendingAudio: (url: URL, durationMs: Int)?

    init(store: ScribeStore) {
        self.store = store
    }

    var isRecording: Bool { recorder.isRecording }

    // MARK: - Recording

    func start(title: String?, location: String?) async {
        guard await recorder.requestPermission() else {
            phase = .failed("Microphone access was denied. Grant it in system settings.")
            return
        }
        do {
            let id = try await store.startMeeting(title: title, location: location)
            meetingId = id
            tags = []
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
        guard recorder.isRecording, let meeting = meetingId else { return }
        let at = recorder.currentOffsetMs
        tags.append(LiveTag(name: name, atMs: at))

        // Written through immediately: a tap that only lives in memory is lost
        // if the app is killed mid-meeting.
        Task { try? await store.addLiveTag(meeting: meeting, name: name, atMs: at) }
    }

    // MARK: - Finishing

    func stop() async {
        guard let stopped = recorder.stop(), let meeting = meetingId else {
            phase = .idle
            return
        }
        pendingAudio = stopped
        await transcribe(meeting: meeting, audio: stopped)
    }

    func retry() async {
        guard let meeting = meetingId, let audio = pendingAudio else { return }
        await transcribe(meeting: meeting, audio: audio)
    }

    private func transcribe(meeting: UUID, audio: (url: URL, durationMs: Int)) async {
        guard let key = Keychain.get("gemini") else {
            phase = .failed(ScribeError.missingAPIKey.localizedDescription)
            return
        }

        do {
            phase = .transcribing(step: "Saving meeting")
            try await store.markTranscribing(meeting, durationMs: audio.durationMs)

            phase = .transcribing(step: "Preparing audio")
            let pieces = try await AudioChunker.split(audio.url)

            let transcriber = GeminiTranscriber(apiKey: key)
            var chunks: [Chunk] = []
            for (n, piece) in pieces.enumerated() {
                phase = .transcribing(
                    step: pieces.count == 1
                        ? "Transcribing"
                        : "Transcribing part \(n + 1) of \(pieces.count)"
                )
                let turns = try await transcriber.transcribe(fileURL: piece.url)
                chunks.append(Chunk(offsetMs: piece.offsetMs, turns: turns))
            }

            phase = .transcribing(step: "Matching speakers")
            let stitched = Stitcher.stitch(chunks, overlapMs: GeminiTranscriber.overlapMs)

            let named = try await store.saveTranscript(meeting: meeting, turns: stitched.turns)
            try await store.markReady(meeting)

            discardAudio(audio.url, pieces: pieces)
            pendingAudio = nil
            phase = .finished(
                meeting: meeting,
                namedByTags: named,
                unmatched: stitched.unmatchedLabels
            )
        } catch {
            // The audio stays on disk so this can be retried; it is only ever
            // in the temporary directory, and is removed once it succeeds.
            try? await store.markFailed(meeting, error.localizedDescription)
            phase = .failed(error.localizedDescription)
        }
    }

    /// The recording has done its job. We keep transcripts, not audio.
    private func discardAudio(_ original: URL, pieces: [AudioChunker.Piece]) {
        let fm = FileManager.default
        for piece in pieces where piece.url != original {
            try? fm.removeItem(at: piece.url)
        }
        try? fm.removeItem(at: original)
    }

    func reset() {
        phase = .idle
        tags = []
        meetingId = nil
        pendingAudio = nil
    }
}
