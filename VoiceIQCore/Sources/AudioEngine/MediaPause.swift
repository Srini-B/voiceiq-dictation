#if os(macOS)
import AppKit
import Foundation

/// Pauses Music and Spotify while the user dictates and plays again only the
/// ones it paused. Muting silences the speaker but the song runs on; pausing
/// keeps the user's place.
///
/// Apple Events go through `/usr/bin/osascript` off the main actor, so the
/// first one asks the user to let VoiceiQ control that app, and a player that
/// isn't running is never asked (or launched). Adapted from Hex, MIT licence,
/// Copyright (c) 2026 Christopher Langton
/// (github.com/anomalyco/hex, src/audio/recording_environment.rs).
@MainActor
public final class MediaPause {
    enum Player: String, CaseIterable {
        case music = "Music"
        case spotify = "Spotify"

        var bundleID: String {
            switch self {
            case .music: return "com.apple.Music"
            case .spotify: return "com.spotify.client"
            }
        }
    }

    /// Players this paused, to play again on resume.
    private var paused: [Player] = []
    private var holding = false

    public init() {}

    public func pause() {
        guard !holding else { return }
        holding = true
        let running = Self.runningPlayers()
        guard !running.isEmpty else { return }
        let script = Self.pauseScript(for: running)
        Task.detached(priority: .userInitiated) {
            let output = Self.run(script) ?? ""
            let players = output.split(separator: ",")
                .compactMap { Player(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            await self.adopt(players)
        }
    }

    public func resume() {
        holding = false
        let players = paused
        paused = []
        Self.play(players)
    }

    private func adopt(_ players: [Player]) {
        guard !players.isEmpty else { return }
        Log.audio.info("paused \(players.map(\.rawValue).joined(separator: ", "), privacy: .public) while dictating")
        // A script from an earlier dictation may answer during this one: what
        // it paused stays paused until this one ends.
        guard holding else {
            Self.play(players)
            return
        }
        paused += players
    }

    private static func play(_ players: [Player]) {
        let running = Set(runningPlayers())
        let script = players.filter(running.contains)
            .map { "try\n  tell application \"\($0.rawValue)\" to play\nend try" }
            .joined(separator: "\n")
        guard !script.isEmpty else { return }
        Task.detached(priority: .userInitiated) { _ = run(script) }
    }

    nonisolated static func pauseScript(for players: [Player]) -> String {
        var script = "set pausedPlayers to {}\n"
        for player in players {
            script += """
            try
              tell application "\(player.rawValue)"
                if player state is playing then
                  pause
                  set end of pausedPlayers to "\(player.rawValue)"
                end if
              end tell
            end try

            """
        }
        return script + "return pausedPlayers\n"
    }

    private static func runningPlayers() -> [Player] {
        let bundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Player.allCases.filter { bundleIDs.contains($0.bundleID) }
    }

    /// The script's output, or nil when it failed (for example the user
    /// declined to let VoiceiQ control the player).
    nonisolated private static func run(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            Log.audio.error("MediaPause: osascript did not start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Log.audio.notice("MediaPause: script failed: \(message, privacy: .public)")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
