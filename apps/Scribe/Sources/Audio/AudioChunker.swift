import AVFoundation
import Foundation

/// Splits a long recording into overlapping pieces small enough to diarize.
///
/// Gemini will only diarize 30 minutes at a time, so anything longer has to be
/// cut. The cuts overlap so that `Stitcher` has shared audio on both sides of
/// every seam to match speaker labels against.
enum AudioChunker {

    struct Piece {
        let url: URL
        /// Where this piece begins within the original recording.
        let offsetMs: Int
    }

    /// Returns the original file untouched when it is already short enough --
    /// the common case, and one fewer export to go wrong.
    static func split(
        _ source: URL,
        chunkMs: Int = GeminiTranscriber.maxChunkMs,
        overlapMs: Int = GeminiTranscriber.overlapMs
    ) async throws -> [Piece] {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let totalMs = Int(CMTimeGetSeconds(duration) * 1000)

        guard totalMs > chunkMs else {
            return [Piece(url: source, offsetMs: 0)]
        }

        var pieces: [Piece] = []
        var offset = 0
        var index = 0

        while offset < totalMs {
            let end = min(offset + chunkMs, totalMs)
            let url = try await export(asset: asset, fromMs: offset, toMs: end, index: index)
            pieces.append(Piece(url: url, offsetMs: offset))

            if end >= totalMs { break }
            // step back by the overlap so the next piece re-covers this tail
            offset = end - overlapMs
            index += 1
        }

        return pieces
    }

    private static func export(
        asset: AVURLAsset,
        fromMs: Int,
        toMs: Int,
        index: Int
    ) async throws -> URL {
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ScribeError.audio("could not create an export session")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-chunk-\(index)-\(UUID().uuidString).m4a")

        let scale = CMTimeScale(1000)
        session.timeRange = CMTimeRange(
            start: CMTime(value: CMTimeValue(fromMs), timescale: scale),
            end: CMTime(value: CMTimeValue(toMs), timescale: scale)
        )

        try await session.export(to: url, as: .m4a)
        return url
    }
}
