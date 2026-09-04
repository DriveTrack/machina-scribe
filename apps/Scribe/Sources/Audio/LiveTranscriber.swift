import AVFoundation
import Foundation
import Observation
import Speech

/// A rough live transcript, shown while recording so you can see it is working.
///
/// This is **not** the transcript that gets saved. It has no speaker labels and
/// is less accurate; Gemini's diarized pass is the real one. It exists so the
/// screen shows words rather than a silent timer.
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

    private(set) var availability: Availability = .ready
    /// Everything recognised so far, plus whatever the current segment thinks.
    var text: String {
        [settled, partial].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var settled = ""
    private var partial = ""

    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rollover: Task<Void, Never>?
    private var running = false

    /// Recognition tasks do not run indefinitely, so each one is retired on a
    /// timer and its text folded into `settled` before a fresh one starts.
    private static let segmentLength: Duration = .seconds(50)

    func prepare() async -> Availability {
        guard let recognizer, recognizer.isAvailable else {
            availability = .unavailableOnDevice
            return availability
        }
        guard recognizer.supportsOnDeviceRecognition else {
            availability = .unavailableOnDevice
            return availability
        }

        let granted = await Self.requestAuthorization()
        availability = granted ? .ready : .denied
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
        settled = ""
        partial = ""
        beginSegment()
    }

    func stop() {
        running = false
        rollover?.cancel()
        rollover = nil
        endSegment()
        settled = text
        partial = ""
    }

    /// Where the audio tap delivers buffers. Held separately from this actor
    /// so the audio thread never has to hop onto the main one.
    let sink = AudioSink()

    // MARK: - Segments

    private func beginSegment() {
        guard let recognizer, running else { return }

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
            // The result object is not Sendable, so read what we need here, on
            // the recognizer's queue, and hand the main actor plain values.
            let words = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil

            Task { @MainActor in
                guard let self else { return }
                if let words { self.partial = words }
                // A dropped segment loses a few seconds of preview, not the
                // recording -- the audio file is unaffected.
                if isFinal || failed { self.settleSegment() }
            }
        }

        rollover = Task { [weak self] in
            try? await Task.sleep(for: Self.segmentLength)
            guard let self, self.running, !Task.isCancelled else { return }
            self.endSegment()
        }
    }

    /// Fold the finished segment's words into the running text and start again.
    private func settleSegment() {
        if !partial.isEmpty {
            settled = settled.isEmpty ? partial : settled + " " + partial
            partial = ""
        }
        sink.attach(nil)
        task = nil
        request = nil
        if running { beginSegment() }
    }

    /// Ask the current segment to wrap up; the callback finishes the handover.
    private func endSegment() {
        rollover?.cancel()
        rollover = nil
        sink.attach(nil)
        request?.endAudio()
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
