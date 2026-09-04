import AVFoundation
import Foundation
import Observation

/// Captures the meeting to a single file on disk.
///
/// The file is a working buffer, not a keepsake: it exists only until the
/// transcript comes back, then it is deleted. Nothing here ever uploads it
/// anywhere except Gemini.
@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: Duration = .zero
    /// 0...1, for the level meter. Purely cosmetic, but it is the only proof
    /// the user has that the microphone is actually hearing them.
    private(set) var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?

    /// Where the current recording is being written.
    private(set) var fileURL: URL?

    /// Mono 16 kHz AAC. Speech recognition gains nothing from stereo or a
    /// higher rate, and this keeps a two-hour meeting to a few megabytes.
    private static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
    ]

    func requestPermission() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    func start() throws {
        guard !isRecording else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // .record with .mixWithOthers so a meeting can be captured while
        // something else holds audio; .allowBluetooth for a lav or headset.
        try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
        try session.setActive(true)
        #endif

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-\(UUID().uuidString).m4a")

        let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw ScribeError.audio("the recorder refused to start")
        }

        self.recorder = recorder
        self.fileURL = url
        self.startedAt = Date()
        self.isRecording = true
        startTicking()
    }

    /// Stops and returns the file plus how long it ran.
    @discardableResult
    func stop() -> (url: URL, durationMs: Int)? {
        guard let recorder, let url = fileURL else { return nil }
        let ms = Int(recorder.currentTime * 1000)
        recorder.stop()
        ticker?.cancel()
        ticker = nil
        self.recorder = nil
        isRecording = false
        level = 0

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif

        return (url, ms)
    }

    /// Milliseconds since recording began -- the timestamp a live tag carries.
    var currentOffsetMs: Int {
        Int((recorder?.currentTime ?? 0) * 1000)
    }

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.elapsed = .seconds(recorder.currentTime)
                // dBFS is roughly -60 (silence) to 0 (clipping); map to 0...1
                let db = Double(recorder.averagePower(forChannel: 0))
                self.level = max(0, min(1, (db + 60) / 60))
            }
        }
    }
}
