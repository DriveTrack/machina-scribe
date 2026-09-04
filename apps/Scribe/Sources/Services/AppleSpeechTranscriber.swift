import Foundation
import AVFoundation
import ScribeCore
import Speech

/// Transcribes on this device with Apple's `SpeechAnalyzer`.
///
/// Free, offline, and unmetered, which is the point: it removes the 30-minute
/// diarization cap, the per-minute token budget and the ~$1.30 a two-hour
/// meeting used to cost. Measured on an M1 Pro at roughly 17x realtime with
/// punctuation, capitalisation and per-word timings intact.
///
/// It runs inside a system daemon rather than in this process, which matters
/// more than it sounds: the model's memory never lands in the app's footprint.
/// Bundling Whisper instead would put 600 MB-1.1 GB resident here for the whole
/// meeting, and on a machine already under pressure that is what makes audio
/// stutter.
///
/// It does not say who is speaking. Every `Word` comes back with a nil speaker
/// for a diarization pass to fill in.
struct AppleSpeechTranscriber: AudioTranscriber {

    let maxChunkMs: Int? = nil
    let identifiesSpeakers = false
    let label = "On this device"

    /// Which language to transcribe. Defaults to the device's own.
    var locale: Locale = .current

    enum Failure: LocalizedError {
        case unsupportedLocale(String)
        case assetsUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let id):
                return "On-device transcription does not support \(id) yet. "
                     + "Choose another language, or switch the engine in Settings."
            case .assetsUnavailable(let id):
                return "The on-device model for \(id) could not be installed. "
                     + "Check the network and disk space, then try again."
            }
        }
    }

    /// Whether this device can transcribe `locale` on its own, downloading the
    /// model first if it is supported but not yet installed.
    ///
    /// Worth calling before a recording rather than after: discovering the
    /// language is unsupported once someone has already talked for an hour is
    /// the worst possible moment.
    @discardableResult
    static func prepare(locale: Locale) async throws -> Locale {
        // Apple's own equivalence rather than comparing identifiers: the
        // framework reports `en_US` where a caller is likely to hold `en-US`,
        // and it is the framework's opinion of a match that decides whether the
        // model actually loads.
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupportedLocale(locale.identifier)
        }
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.contains(where: { $0.identifier == resolved.identifier }) else {
            return resolved
        }

        let transcriber = SpeechTranscriber(locale: resolved, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [])
        // nil means there is nothing left to fetch.
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else { return resolved }
        do {
            try await request.downloadAndInstall()
        } catch {
            throw Failure.assetsUnavailable(locale.identifier)
        }
        return resolved
    }

    func words(
        in fileURL: URL,
        report: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> [Word] {
        report?(.preparing)
        let resolved = try await Self.prepare(locale: locale)

        let file = try AVAudioFile(forReading: fileURL)
        let totalMs = Int(Double(file.length) / file.fileFormat.sampleRate * 1000)

        // `.audioTimeRange` is the whole reason this is usable: without it the
        // result is a wall of text with no way to line it up against a speaker
        // segment, and a diarized transcript stops being possible.
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // `finishAfterFile` so the stream ends at the end of the recording
        // instead of waiting for audio that is never coming.
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: file,
            modules: [transcriber],
            finishAfterFile: true
        )

        report?(.transcribing)
        var words: [Word] = []
        for try await result in transcriber.results {
            for run in result.text.runs {
                guard let range = run.audioTimeRange else { continue }
                let text = String(result.text[run.range].characters)
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                words.append(
                    Word(
                        text: text,
                        // Nobody here knows who spoke; the diarization pass does.
                        speaker: nil,
                        startMs: Int(CMTimeGetSeconds(range.start) * 1000),
                        endMs: Int(CMTimeGetSeconds(range.end) * 1000)
                    )
                )
            }
            if totalMs > 0, let last = words.last {
                report?(.progress(min(1, Double(last.endMs) / Double(totalMs))))
            }
        }
        // Held so the analyzer is not torn down mid-stream.
        withExtendedLifetime(analyzer) {}
        return words
    }
}
