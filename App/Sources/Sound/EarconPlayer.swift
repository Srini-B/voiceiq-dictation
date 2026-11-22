import AVFoundation
import VoiceIQCore

/// Preloaded earcon playback (<10ms trigger latency). Sounds fire on the same
/// state-machine tick as the matching animation — the Pixel frame-sync principle.
/// No sounds on hover/menus, ever: design the silence.
@MainActor
final class EarconPlayer {
    enum Earcon: String, CaseIterable {
        case start, stop, lock, success, cancel, error, celebration
    }

    private var players: [Earcon: AVAudioPlayer] = [:]
    /// Live-follows the Settings toggle (UserDefaults reads are cheap).
    var enabled: Bool { SettingsStore().soundsEnabled }

    init() {
        // Loading 7 players blocks the caller (~120ms measured) — never on the
        // main thread at launch, and never in front of the first key press.
        loadInBackground()
    }

    private func loadInBackground() {
        Task.detached(priority: .utility) { [weak self] in
            let loaded = EarconPlayer.loadPlayers()
            guard let self else { return }
            await self.adopt(loaded) // @MainActor — hops back on its own
        }
    }

    private func adopt(_ loaded: [Earcon: AVAudioPlayer]) {
        players = loaded
        warmOutputRoute()
    }

    nonisolated private static func loadPlayers() -> [Earcon: AVAudioPlayer] {
        var players: [Earcon: AVAudioPlayer] = [:]
        for earcon in Earcon.allCases {
            guard let url = Bundle.main.url(forResource: earcon.rawValue, withExtension: "wav", subdirectory: "Sounds") else {
                Log.ui.warning("EarconPlayer: missing \(earcon.rawValue, privacy: .public).wav")
                continue
            }
            if let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                player.volume = volume
                players[earcon] = player
            }
        }
        return players
    }

    /// The FIRST play() of a player instance blocks its caller while the
    /// AudioQueue is built and the output route spins up — measured 45–475ms on
    /// a USB/Bluetooth output. That otherwise lands on the start earcon, ahead of
    /// the mic, so the first dictation after launch loses that much leading
    /// speech. Pay it once, silently, off the main actor. Never stop() a player:
    /// an explicit stop re-costs the next play ~440ms.
    private func warmOutputRoute() {
        guard let player = players[.start] else { return }
        nonisolated(unsafe) let warm = player
        let volume = warm.volume
        warm.volume = 0
        Task.detached(priority: .utility) {
            warm.play()
            try? await Task.sleep(nanoseconds: UInt64((warm.duration + 0.05) * 1_000_000_000))
            await MainActor.run { warm.volume = volume }
        }
    }

    func play(_ earcon: Earcon) {
        guard enabled, let player = players[earcon] else { return }
        player.currentTime = 0
        player.play()
    }

    /// Plays the start sound after `grace`, unless `retractStart` comes
    /// first. The wait runs off the main thread, which `engine.start()` can
    /// block for hundreds of ms on a Bluetooth mic right after the press.
    func playStart(after grace: TimeInterval) {
        guard enabled, let player = players[.start] else { return }
        nonisolated(unsafe) let start = player
        let token = startGate.arm()
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + grace) { [startGate] in
            // Under the gate's lock, so a cancel either comes before this and
            // stops it, or after it and sees the sound playing.
            startGate.fire(token) {
                start.volume = Self.volume
                start.currentTime = 0
                start.play()
            }
        }
    }

    /// Drops a start sound still waiting out its grace, and fades one that
    /// already sounds: 20 ms instead of a click, then a pause, never stop()
    /// (see warmOutputRoute).
    func retractStart() {
        guard let token = startGate.disarm(), let player = players[.start], player.isPlaying else { return }
        nonisolated(unsafe) let start = player
        start.setVolume(0, fadeDuration: 0.02)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.03) { [startGate] in
            // A newer start owns the player now: leave it alone.
            startGate.ifStill(token) {
                start.pause()
                start.currentTime = 0
                start.volume = Self.volume
            }
        }
    }

    /// Drops a start sound still waiting, without touching one that plays.
    func cancelPendingStart() {
        _ = startGate.disarm()
    }

    private let startGate = StartGate()
    nonisolated private static let volume: Float = 0.9
}

/// Which delayed start sound may still play, and which start owns the player.
/// Used from a background queue and the main actor.
private final class StartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private var armed: Int?

    func arm() -> Int {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        armed = counter
        return counter
    }

    /// Runs `body` once, under the lock, if `token` is still armed.
    func fire(_ token: Int, _ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard armed == token else { return }
        armed = nil
        body()
    }

    /// Disarms, and returns the latest start's token.
    func disarm() -> Int? {
        lock.lock(); defer { lock.unlock() }
        armed = nil
        return counter == 0 ? nil : counter
    }

    /// Runs `body` under the lock if no start came after `token`.
    func ifStill(_ token: Int, _ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard counter == token else { return }
        body()
    }
}
