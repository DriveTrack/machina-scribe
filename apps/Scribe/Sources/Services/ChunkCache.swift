import Foundation
import ScribeCore

/// Remembers which parts of a long recording have already been transcribed.
///
/// A two-hour meeting is six separate API calls. Without this, failing on part
/// four means the retry pays for parts one through three all over again --
/// which, when the failure was a rate limit, is exactly the thing that caused
/// it. Cached parts make a retry cost only what is left.
struct ChunkCache {
    let meeting: UUID

    private var directory: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base
            .appendingPathComponent("PartialTranscripts", isDirectory: true)
            .appendingPathComponent(meeting.uuidString, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func file(_ index: Int) -> URL? {
        directory?.appendingPathComponent("part-\(index).json")
    }

    /// Keyed by offset as well as index so that a change in how the audio is
    /// split can never quietly pair a cached transcript with different audio.
    private struct Stored: Codable {
        var offsetMs: Int
        var turns: [Turn]
    }

    func turns(at index: Int, offsetMs: Int) -> [Turn]? {
        guard let file = file(index),
              let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.offsetMs == offsetMs
        else { return nil }
        return stored.turns
    }

    func save(_ turns: [Turn], at index: Int, offsetMs: Int) {
        guard let file = file(index),
              let data = try? JSONEncoder().encode(Stored(offsetMs: offsetMs, turns: turns))
        else { return }
        try? data.write(to: file, options: .atomic)
    }

    func clear() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    var completedParts: Int {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return 0 }
        return files.filter { $0.hasPrefix("part-") }.count
    }
}
