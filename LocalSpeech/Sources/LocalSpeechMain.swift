import VoiceIQInference

@main
enum LocalSpeechMain {
    static func main() async {
        // The same helper is the Chrome extension's native messaging host, so
        // the bundle carries no second signed executable.
        if BrowserHostServer.isBrowserLaunch(CommandLine.arguments) { BrowserHostServer.run() }
        await ParakeetHelperServer.run()
    }
}
