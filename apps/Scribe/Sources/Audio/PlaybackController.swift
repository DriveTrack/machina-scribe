import AVFoundation
import Foundation
import Observation

/// Plays back an archived recording, so a voice can be put to a name after the
/// meeting rather than during it.
@MainActor
@Observable
final class PlaybackController: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    private(set) var positionMs = 0
    private(set) var durationMs = 0

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    func load(_ url: URL) {
        stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        durationMs = Int((player?.duration ?? 0) * 1000)
        positionMs = 0
    }

    /// Play from a point in the meeting -- what tapping a turn does.
    func play(fromMs ms: Int) {
        guard let player else { return }
        player.currentTime = max(0, min(player.duration, Double(ms) / 1000))
        player.play()
        isPlaying = true
        startTicking()
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            player.play()
            isPlaying = true
            startTicking()
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        isPlaying = false
        positionMs = 0
        durationMs = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let player = self.player else { return }
                self.positionMs = Int(player.currentTime * 1000)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.ticker?.cancel()
        }
    }
}
