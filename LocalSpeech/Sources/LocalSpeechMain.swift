import VoiceIQSpeech

/// The VoiceiQ Meetings Chrome extension's native messaging host. The helper
/// keeps its name and bundle id because installed browser manifests point at
/// this executable. Started any other way, it exits.
@main
enum LocalSpeechMain {
    static func main() {
        if BrowserHostServer.isBrowserLaunch(CommandLine.arguments) { BrowserHostServer.run() }
    }
}
