import AVFoundation
import Foundation
import Observation

/// Captures the meeting to a single file on disk, and hands the same buffers to
/// the live preview.
///
/// The file is a working buffer, not a keepsake: it exists only until the
/// transcript comes back, then it is deleted. Nothing here uploads it anywhere
/// except Gemini.
@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: Duration = .zero
    /// 0...1, for the level meter. Cosmetic, but it is the only proof the user
    /// has that the microphone is actually hearing them.
    private(set) var level: Double = 0

    /// Where the current recording is being written.
    private(set) var fileURL: URL?

    let live = LiveTranscriber()

    private let engine = AVAudioEngine()
    private var writer: Writer?
    private var ticker: Task<Void, Never>?

    /// Mono 16 kHz AAC. Speech recognition gains nothing from stereo or a
    /// higher rate, and this keeps a two-hour meeting to a few megabytes.
    private static let fileSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000
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
        // No Bluetooth option on purpose. Routing input over Bluetooth forces
        // the HFP profile, which drops the microphone to 8-16 kHz and audibly
        // hurts transcription -- worse than the built-in mic for a room.
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw ScribeError.audio("no microphone is available")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-\(UUID().uuidString).m4a")
        let file = try AVAudioFile(forWriting: url, settings: Self.fileSettings)

        guard let converter = AVAudioConverter(from: inputFormat, to: file.processingFormat) else {
            throw ScribeError.audio("cannot convert microphone audio for writing")
        }
        let writer = Writer(file: file, converter: converter)
        self.writer = writer
        self.fileURL = url

        // The tap runs on the realtime audio thread. It must be @Sendable:
        // without it the closure inherits this class's main-actor isolation and
        // Swift's executor check kills the app on the first buffer.
        // Everything it touches is lock-guarded or safe to call from there.
        let sink = live.sink
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { @Sendable buffer, _ in
            writer.write(buffer)
            sink.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.writer = nil
            throw ScribeError.audio(error.localizedDescription)
        }

        isRecording = true
        // Recognition reports times relative to its own segment; this is how
        // those become positions in the recording.
        live.audioOffsetMs = { [weak writer] in writer?.elapsedMs ?? 0 }
        live.start()
        startTicking()
    }

    /// Stops and returns the file plus how long it ran.
    @discardableResult
    func stop() -> (url: URL, durationMs: Int)? {
        guard isRecording, let writer, let url = fileURL else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        live.stop()
        ticker?.cancel()
        ticker = nil

        let ms = writer.elapsedMs
        writer.close()
        self.writer = nil
        isRecording = false
        level = 0

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif

        return (url, ms)
    }

    /// Milliseconds of audio captured so far -- the timestamp a live tag
    /// carries. Taken from the audio timeline rather than the wall clock, so a
    /// tag lands where the recording actually is.
    var currentOffsetMs: Int { writer?.elapsedMs ?? 0 }

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let writer = self.writer else { return }
                self.elapsed = .milliseconds(writer.elapsedMs)
                self.level = writer.level
            }
        }
    }
}

// MARK: - Audio-thread side

/// Owns the output file and the format conversion.
///
/// Every method is called from the audio thread, so state is behind a lock and
/// nothing here touches the main actor.
private final class Writer: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private var frames: AVAudioFramePosition = 0
    private var currentLevel: Double = 0
    private var closed = false

    init(file: AVAudioFile, converter: AVAudioConverter) {
        self.file = file
        self.converter = converter
        self.format = file.processingFormat
    }

    var elapsedMs: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(Double(frames) / format.sampleRate * 1000)
    }

    var level: Double {
        lock.lock()
        defer { lock.unlock() }
        return currentLevel
    }

    func write(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }

        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

        // Streaming conversion: hand over exactly one input buffer, then say
        // there is no more for now. Sample-rate conversion needs this form.
        let source = ConversionSource(input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            source.next(status)
        }

        guard error == nil, output.frameLength > 0 else { return }
        try? file.write(from: output)
        frames += AVAudioFramePosition(output.frameLength)
        currentLevel = Self.rms(of: output)
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    /// Feeds one buffer to the converter and then reports exhaustion.
    ///
    /// The converter invokes its input block synchronously, on this same
    /// thread, before `convert` returns -- but the block is typed `@Sendable`,
    /// so the hand-off lives in a reference type rather than a captured var.
    private final class ConversionSource: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let pending = buffer else {
                status.pointee = .noDataNow
                return nil
            }
            buffer = nil
            status.pointee = .haveData
            return pending
        }
    }

    /// Root mean square, mapped onto the same rough 0...1 the meter expects.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            let sample = channel[i]
            sum += sample * sample
        }
        let mean = sqrt(sum / Float(buffer.frameLength))
        // -60 dBFS reads as silence, 0 dBFS as full scale.
        let db = 20 * log10(max(mean, 0.000_001))
        return max(0, min(1, (Double(db) + 60) / 60))
    }
}
