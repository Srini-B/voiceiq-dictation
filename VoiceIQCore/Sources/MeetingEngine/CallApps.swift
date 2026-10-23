#if os(macOS)
import Foundation

/// What `CallDetector` treats as a call.
enum CallApps {
    /// Apps whose microphone use is a call on its own.
    static let known: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams", "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime", "com.apple.mobilephone": "Phone",
        "net.whatsapp.WhatsApp": "WhatsApp", "desktop.WhatsApp": "WhatsApp",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord", "com.hnc.DiscordPTB": "Discord", "com.hnc.DiscordCanary": "Discord",
        "com.cisco.webexmeetingsapp": "Webex", "Cisco-Systems.Spark": "Webex", "com.webex.meetingmanager": "Webex",
        "com.skype.skype": "Skype", "com.apple.MobileSMS": "Messages",
        "ru.keepcoder.Telegram": "Telegram", "org.telegram.desktop": "Telegram",
        "org.whispersystems.signal-desktop": "Signal", "com.viber.osx": "Viber", "jp.naver.line.mac": "LINE",
        "com.tencent.xinWeChat": "WeChat", "com.facebook.archon": "Messenger",
        "com.amazon.Amazon-Chime": "Amazon Chime", "com.logmein.GoToMeeting": "GoTo Meeting", "com.logmein.goto": "GoTo",
        "com.ringcentral.glip": "RingCentral", "com.tencent.meeting": "Tencent Meeting", "com.alibaba.DingTalkMac": "DingTalk",
        "co.teamport.around": "Around", "app.tuple.app": "Tuple", "im.riot.app": "Element",
    ]

    /// Known apps that also record voice notes: their mic use is a call only
    /// while they also play sound.
    static let voiceNoteApps: Set<String> = [
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.MobileSMS", "ru.keepcoder.Telegram",
        "org.telegram.desktop", "org.whispersystems.signal-desktop", "com.viber.osx", "jp.naver.line.mac",
        "com.tencent.xinWeChat", "com.facebook.archon",
    ]

    /// The developer part of a bundle ID: "com.p5sys.jump.connect" and
    /// "com.p5sys.jump.audio.driver" are both "com.p5sys". Nil for Apple's own.
    static func vendor(_ bundleID: String) -> String? {
        let parts = bundleID.lowercased().split(separator: ".").prefix(2)
        let vendor = parts.joined(separator: ".")
        return parts.count == 2 && vendor != "com.apple" ? vendor : nil
    }

    /// System daemons that carry FaceTime audio and iPhone calls relayed to
    /// the Mac (Continuity). The call itself has no app process using the mic.
    static let callDaemons: Set<String> = ["avconferenced", "callservicesd"]
    static let callDaemonSource = CallSource.app(bundleID: "com.apple.FaceTime", name: "FaceTime or phone")

    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// Pages whose microphone use is a call on its own, matched against the
    /// page URL and window titles.
    static let meetingPages = [
        "meet.google.com/", "teams.microsoft.com", "teams.live.com", "zoom.us/j", "zoom.us/wc", "app.zoom.us/wc",
        "whereby.com/", "meet.jit.si/", "app.slack.com/huddle", "discord.com/channels", "webex.com",
        "web.whatsapp.com", "web.telegram.org", "messenger.com", "app.gather.town", "around.co",
        "v.ringcentral.com", "app.goto.com", "meet.goto.com", "app.chime.aws", "meeting.zoho", "riverside.fm",
        "streamyard.com", "talky.io", "vdo.ninja", "Meet - ", "| Microsoft Teams", "Zoom Meeting", "Huddle",
    ]

    /// Apps that capture the mic and play sound without being a call: voice
    /// assistants, recorders, music software, the simulator.
    static let notCalls: Set<String> = [
        "com.openai.chat", "com.anthropic.claudefordesktop", "com.apple.Siri", "com.apple.VoiceMemos",
        "com.apple.QuickTimePlayerX", "com.apple.GarageBand10", "com.apple.logic10", "com.ableton.live",
        "com.obsproject.obs-studio", "com.loom.desktop", "com.rogueamoeba.audiohijack", "com.apple.iphonesimulator",
        "com.apple.dt.Xcode", "com.apple.Music", "com.spotify.client",
    ]
    /// The same, for pages in a browser.
    static let notCallPages = ["chatgpt.com", "claude.ai", "gemini.google.com"]
}
#endif
