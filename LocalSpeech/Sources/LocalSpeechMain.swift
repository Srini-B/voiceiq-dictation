import VoiceIQCore

@main
enum LocalSpeechMain {
    static func main() async {
        await ParakeetHelperServer.run()
    }
}
