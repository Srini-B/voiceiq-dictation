#if os(macOS)
import Foundation

/// What `CallDetector` treats as a call.
enum CallApps {
    /// Apps whose microphone use is a call on its own. No other app counts:
    /// recorders, dictation, and remote desktop clients capture and play too.
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
        "com.larksuite.larkApp": "Lark", "com.larksuite.macos.lark": "Lark", "com.electron.lark": "Feishu",
        "com.pop.pop.app": "Pop", "com.electron.zohomeeting": "Zoho Meeting", "org.jitsi.jitsi-meet": "Jitsi Meet",
        "com.gather.Gather": "Gather", "com.electron.8x8---virtual-office": "8x8 Work", "com.electron.dialpad": "Dialpad",
        "com.vonage.vbc": "Vonage Business", "com.wearezeta.zclient.mac": "Wire",
        "threema-consumer-web": "Threema", "threema-work-web": "Threema Work", "com.kakao.KakaoTalkMac": "KakaoTalk",
        "com.vng.zalo": "Zalo", "Mattermost.Desktop": "Mattermost", "com.securax.zoiper5": "Zoiper",
        "com.CounterPath_Corporation.Bria": "Bria",
    ]

    /// Known apps that also record voice notes: their mic use is a call only
    /// while they also play sound.
    static let voiceNoteApps: Set<String> = [
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.MobileSMS", "ru.keepcoder.Telegram",
        "org.telegram.desktop", "org.whispersystems.signal-desktop", "com.viber.osx", "jp.naver.line.mac",
        "com.tencent.xinWeChat", "com.facebook.archon",
        "com.larksuite.larkApp", "com.larksuite.macos.lark", "com.electron.lark", "com.wearezeta.zclient.mac",
        "threema-consumer-web", "threema-work-web", "com.kakao.KakaoTalkMac", "com.vng.zalo", "Mattermost.Desktop",
    ]

    /// System daemons that carry FaceTime audio and iPhone calls relayed to
    /// the Mac (Continuity). The call itself has no app process using the mic.
    static let callDaemons: Set<String> = ["avconferenced", "callservicesd"]
    static let callDaemonSource = CallSource.app(bundleID: "com.apple.FaceTime", name: "FaceTime or phone")
    /// Apps whose call audio the daemons above play, not the app itself.
    static let daemonCallApps: Set<String> = ["com.apple.FaceTime", "com.apple.mobilephone"]

    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "company.thebrowser.dia", "ai.perplexity.comet", "com.kagi.kagimacOS", "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
    ]

    /// Pages whose microphone use is a call on its own, matched against the
    /// page URL and window titles.
    static let meetingPages = [
        "meet.google.com/", "teams.microsoft.com", "teams.live.com", "zoom.us/j", "zoom.us/wc", "app.zoom.us/wc",
        "whereby.com/", "meet.jit.si/", "app.slack.com/huddle", "discord.com/channels", "webex.com",
        "web.whatsapp.com", "web.telegram.org", "messenger.com", "app.gather.town", "around.co",
        "v.ringcentral.com", "app.goto.com", "meet.goto.com", "app.chime.aws", "meeting.zoho", "riverside.fm",
        "streamyard.com", "talky.io", "vdo.ninja", "teams.cloud.microsoft", "pop.com/j/", "vc.larksuite.com",
        "vc.feishu.cn", "meetings.dialpad.com", "app.dialpad.com", "8x8.vc/", "meetings.vonage.com", "app.vonage.com",
        "Meet - ", "| Microsoft Teams", "Zoom Meeting", "Huddle",
    ]
    /// What the offer calls a meeting found only by its window title.
    static let meetingTitles = [
        "Meet - ": "Google Meet", "| Microsoft Teams": "Microsoft Teams", "Zoom Meeting": "Zoom", "Huddle": "Slack huddle",
    ]

    /// What the offer calls a meeting page: the host of the address that
    /// matched, else the name of a matched title, else the pattern itself.
    static func meetingName(match: String, in strings: [String]) -> String {
        let address = strings.first { $0.localizedCaseInsensitiveContains(match) }.flatMap { URL(string: $0)?.host() }
        return address?.replacingOccurrences(of: "www.", with: "") ?? meetingTitles[match]
            ?? match.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Pages that capture the mic and play sound without being a call: voice
    /// assistants and remote desktops.
    static let notCallPages = ["chatgpt.com", "claude.ai", "gemini.google.com", "remotedesktop.google.com"]
}
#endif
