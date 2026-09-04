import Foundation

/// Holds recordings for a short window after the meeting, then deletes them.
///
/// The app's default is to keep no audio at all. This exists for one reason:
/// after a call it is much easier to say *who* a voice was if you can play the
/// moment back. That is worth a day of retention, and not much more -- so the
/// window is enforced rather than merely intended. Expired files are swept on
/// every launch, whenever a new one is stored, and whenever the archive is
/// consulted, so a file cannot outlive its window just because nobody looked.
struct RecordingArchive {

    /// How long a recording survives after the meeting. Zero means keep none.
    var retention: Duration

    static let defaultRetention: Duration = .seconds(24 * 60 * 60)

    init(retention: Duration = RecordingArchive.defaultRetention) {
        self.retention = retention
    }

    private var directory: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }

        let dir = base.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func location(_ meeting: UUID) -> URL? {
        directory?.appendingPathComponent("\(meeting.uuidString).m4a")
    }

    /// Recordings that have not been transcribed yet.
    ///
    /// Separate from the retained ones because the retention window must not
    /// apply to them: a recording still waiting on a transcript has to survive
    /// regardless of whether the user keeps audio afterwards.
    private var pendingDirectory: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("PendingRecordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func pendingLocation(_ meeting: UUID) -> URL? {
        pendingDirectory?.appendingPathComponent("\(meeting.uuidString).m4a")
    }

    /// Move a just-finished recording out of the OS temporary directory.
    ///
    /// This happens the moment recording stops, before any transcription is
    /// attempted. The temporary directory can be emptied by the system at any
    /// time, so audio left there while a long transcription retries -- or
    /// while the app is closed overnight after a failure -- is audio that can
    /// silently disappear. There is no getting a meeting back.
    @discardableResult
    func stash(_ source: URL, for meeting: UUID) -> URL {
        guard let destination = pendingLocation(meeting) else { return source }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            // Copy rather than give up: better two copies than none.
            try? FileManager.default.copyItem(at: source, to: destination)
            guard FileManager.default.fileExists(atPath: destination.path) else { return source }
        }

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = destination
        try? mutable.setResourceValues(values)
        return destination
    }

    /// The un-transcribed recording for a meeting, if one is waiting.
    func pendingURL(for meeting: UUID) -> URL? {
        guard let url = pendingLocation(meeting),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Everything still waiting on a transcript, oldest first.
    func pendingMeetings() -> [(meeting: UUID, url: URL, bytes: Int64)] {
        guard let pendingDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: pendingDirectory, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
              )
        else { return [] }
        return files.compactMap { file in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (id, file, Int64(size))
        }
    }

    /// The transcript is stored, so the recording stops being pending and the
    /// retention setting finally decides its fate.
    func settle(_ meeting: UUID) {
        guard let pending = pendingLocation(meeting),
              FileManager.default.fileExists(atPath: pending.path)
        else { return }

        guard retention > .zero, let destination = location(meeting) else {
            try? FileManager.default.removeItem(at: pending)
            return
        }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: pending, to: destination)
    }

    /// Move a finished recording into the archive. Returns false when nothing
    /// was kept, which is the correct outcome with retention switched off.
    @discardableResult
    func keep(_ source: URL, for meeting: UUID) -> Bool {
        purgeExpired()

        guard retention > .zero, let destination = location(meeting) else {
            try? FileManager.default.removeItem(at: source)
            return false
        }

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            // If it cannot be archived it must still not linger in temp.
            try? FileManager.default.removeItem(at: source)
            return false
        }

        // A file with a day to live has no business in a backup or in iCloud.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = destination
        try? mutable.setResourceValues(values)

        return true
    }

    /// The recording for a meeting, if one is still within its window.
    func url(for meeting: UUID) -> URL? {
        purgeExpired()
        guard let url = location(meeting),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// When this recording will be deleted.
    func expiry(for meeting: UUID) -> Date? {
        guard retention > .zero,
              let url = location(meeting),
              let created = stored(at: url)
        else { return nil }
        return created.addingTimeInterval(retention.seconds)
    }

    func discard(_ meeting: UUID) {
        guard let url = location(meeting) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Delete everything past its window. Cheap, and safe to call often.
    func purgeExpired(now: Date = Date()) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey]
              )
        else { return }

        for file in files {
            // Retention off means the archive should be empty, not frozen.
            guard retention > .zero else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            guard let created = stored(at: file) else {
                // No usable date: assume the worst rather than keep it forever.
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if now.timeIntervalSince(created) > retention.seconds {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Discard a pending recording -- only when the user gives up on it.
    func discardPending(_ meeting: UUID) {
        guard let url = pendingLocation(meeting) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Total bytes currently held, for showing in settings.
    func bytesHeld() -> Int64 {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
              )
        else { return 0 }
        return files.reduce(0) { total, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    private func stored(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}

private extension Duration {
    var seconds: TimeInterval { TimeInterval(components.seconds) }
}
