import AVFoundation
import Foundation
import Observation
import Speech

/// A rough live transcript, shown while recording.
///
/// Two jobs. It shows that the microphone is working, and -- more usefully --
/// it gives you something to *point at*: each chunk carries the moment in the
/// recording where it was spoken, so tapping one says "that was Priya" without
/// having to catch her mid-sentence.
///
/// This is **not** the transcript that gets saved. It has no speaker labels and
/// is less accurate; Gemini's diarized pass is the real one.
///
/// It runs **on-device only**. If a device cannot do on-device recognition for
/// the locale, the preview is switched off rather than quietly streaming the
/// meeting to Apple's servers -- the whole app promises audio goes nowhere but
/// Gemini, and a live preview is not worth breaking that.
@MainActor
@Observable
final class LiveTranscriber {

    enum Availability: Equatable {
        case ready
        case denied
        /// On-device recognition is not offered here, so we decline to run.
        case unavailableOnDevice
    }

    /// A tappable run of speech, positioned on the recording's timeline.
    struct Chunk: Identifiable, Equatable, Sendable {
        let id: Int
        var startMs: Int
        var endMs: Int
        var text: String
    }

    private(set) var availability: Availability = .ready
    /// Settled chunks plus whatever the current segment has so far.
    private(set) var chunks: [Chunk] = []
    /// Words too fresh to have a reliable position yet; shown, not tappable.
    private(set) var pending: String = ""

    var isEmpty: Bool { chunks.isEmpty && pending.isEmpty }

    /// Where the recording is right now, in milliseconds. Set by the recorder;
    /// recognition timestamps are relative to their own segment, so they need
    /// this to be placed on the recording's timeline.
    var audioOffsetMs: (() -> Int)?

    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rollover: Task<Void, Never>?
    private var running = false

    /// Chunks from recognition segments that have already been retired.
    private var settled: [Chunk] = []
    /// Where the current recognition segment began, on the recording timeline.
    private var segmentBaseMs = 0
    private var nextChunkId = 0

    /// Recognition tasks do not run indefinitely, so each one is retired on a
    /// timer and its chunks folded into `settled` before a fresh one starts.
    private static let segmentLength: Duration = .seconds(50)

    let sink = AudioSink()

    // MARK: - Lifecycle

    func prepare() async -> Availability {
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            availability = .unavailableOnDevice
            return availability
        }
        availability = await Self.requestAuthorization() ? .ready : .denied
        return availability
    }

    /// Deliberately `nonisolated`.
    ///
    /// `requestAuthorization` answers on its own queue. If the continuation is
    /// resumed from a closure that inherited main-actor isolation, Swift's
    /// executor check traps and the app dies the moment the user taps Allow.
    private nonisolated static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func start() {
        guard availability == .ready, !running else { return }
        running = true
        settled = []
        chunks = []
        pending = ""
        nextChunkId = 0
        beginSegment()
    }

    func stop() {
        running = false
        rollover?.cancel()
        rollover = nil
        sink.attach(nil)
        request?.endAudio()
        request = nil
        task = nil
        pending = ""
    }

    // MARK: - Segments

    private func beginSegment() {
        guard let recognizer, running else { return }

        segmentBaseMs = audioOffsetMs?() ?? 0

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // The point of the whole class: never leave the device.
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        self.request = request
        sink.attach(request)

        // @Sendable for the same reason as the audio tap: this fires on the
        // recognizer's own queue, so it must not inherit main-actor isolation.
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            // SFTranscription is not Sendable, so flatten it here, on the
            // recognizer's queue, and hand the main actor plain values.
            let pieces = result?.bestTranscription.segments.map {
                (text: $0.substring, at: $0.timestamp, len: $0.duration)
            }
            let isFinal = result?.isFinal ?? false
            let failed = error != nil

            Task { @MainActor in
                guard let self else { return }
                if let pieces { self.absorb(pieces) }
                // A dropped segment loses a few seconds of preview, not the
                // recording -- the audio file is unaffected.
                if isFinal || failed { self.retireSegment() }
            }
        }

        rollover = Task { [weak self] in
            try? await Task.sleep(for: Self.segmentLength)
            guard let self, self.running, !Task.isCancelled else { return }
            self.request?.endAudio()
        }
    }

    private func retireSegment() {
        settled = chunks
        pending = ""
        sink.attach(nil)
        task = nil
        request = nil
        if running { beginSegment() }
    }

    // MARK: - Chunking

    /// Rebuild the current segment's chunks from the latest partial result.
    ///
    /// Partials restate the whole segment each time, so the current segment's
    /// chunks are rebuilt wholesale while earlier ones stay put. Tags are not
    /// stored here -- they live on the recording session, keyed by time -- so
    /// rebuilding never loses one.
    private func absorb(_ pieces: [(text: String, at: TimeInterval, len: TimeInterval)]) {
        guard !pieces.isEmpty else { return }

        var built: [Chunk] = []
        var words: [String] = []
        var startMs: Int?
        var endMs = 0
        var id = nextChunkId

        // Some configurations report a zero timestamp on partial results. When
        // that happens the segment's own base is the best position available,
        // which is still inside the right few seconds.
        func position(_ t: TimeInterval) -> Int {
            segmentBaseMs + (t > 0 ? Int(t * 1000) : 0)
        }

        for piece in pieces {
            if startMs == nil { startMs = position(piece.at) }
            words.append(piece.text)
            endMs = position(piece.at) + Int(piece.len * 1000)

            // Short enough to tap accurately, long enough to read.
            let endsSentence = piece.text.last.map { ".!?".contains($0) } ?? false
            if endsSentence || words.count >= 12 {
                built.append(Chunk(id: id, startMs: startMs ?? segmentBaseMs,
                                   endMs: endMs, text: words.joined(separator: " ")))
                id += 1
                words = []
                startMs = nil
            }
        }

        // Whatever has not reached a boundary yet is still moving; show it as
        // plain text so the screen keeps up, but do not offer it for tagging.
        pending = words.joined(separator: " ")
        chunks = settled + built
        nextChunkId = max(nextChunkId, id)
    }
}

/// Bridges the real-time audio thread to whichever recognition segment is
/// currently open.
///
/// `SFSpeechAudioBufferRecognitionRequest.append` is safe to call from the
/// audio thread; swapping which request is open is not, so that part is
/// guarded. The lock is held only for a pointer read.
final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func attach(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }
}
