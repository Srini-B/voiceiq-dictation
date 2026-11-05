import Foundation

// Adapted from Dictus (github.com/getdictus/dictus-ios, MIT License,
// Copyright (c) 2026 PIVI Solutions), whose table is ported from VivaDicta
// (github.com/n0an/VivaDicta, MIT License, Copyright (c) 2026 Anton Novoselov).
// See THIRD_PARTY_NOTICES.md. The notes on each entry are their findings and are
// kept because they explain the non-obvious choices (Messages uses ichat://,
// Safari and Claude have no entry).
//
// Last synced: Dictus develop `ed605740` (2026-11-03) and VivaDicta `92e2416c`
// (2026-10-31), on 2026-11-05. To sync, diff `knownURLs`, `knownNoSchemeHosts` and
// `StateLosingHostApps` in VivaDicta/VivaDictaApp.swift since that commit.

/// The way back into the app the keyboard was typing in, keyed by its bundle ID.
///
/// A scheme only belongs here if opening it RESUMES the app where the user left
/// it. One that performs an action (compose, new tab, search) is worse than the
/// swipe-back screen, because it discards what the user was doing.
public enum KnownAppSchemes {
    public static let schemesByBundleId: [String: String] = [
        // Verified against the app's own Info.plist, official documentation, or the
        // shipping binary.
        // Verified on device: lands back in the note the user was editing.
        "com.apple.mobilenotes": "mobilenotes://",
        // `ichat://`, and this one is measured rather than inherited. Messages declares
        // several schemes and most of them *act* instead of resuming: `sms://`,
        // `messages://`, `imessage://` and `im://` all land the user on the **"New
        // message"** compose sheet, not in the conversation they were typing in.
        // `ichat://` is the only one that brings Messages back exactly where it was.
        // Verified twice on iOS 26.5, and the upstream catalogue has `sms://` here with
        // the compose bug intact. Do not "fix" this to the obvious scheme.
        "com.apple.MobileSMS": "ichat://",
        // Verified on device, twice. It was the top suspect on name shape — `message://`
        // reads like "open a specific message", which is `sms://`'s mistake — and the
        // suspicion was wrong. Kept as a note because the next reader will have the same
        // doubt.
        "com.apple.mobilemail": "message://",
        "com.apple.Pages": "pages://",
        "com.apple.Numbers": "numbers://",
        "com.apple.Keynote": "keynote://",
        // NOT `x-apple-reminder://`, which is unregistered.
        "com.apple.reminders": "x-apple-reminderkit://",
        // NOT `whatsapp://` — that one belongs to the SMB build below. Verified on device
        // to come back to the conversation the user was in, which makes it the reference
        // for what a good entry looks like: it names the app, not an action.
        "net.whatsapp.WhatsApp": "whatsapp-consumer://",
        "net.whatsapp.WhatsAppSMB": "whatsapp://",
        "com.telegram.telegram-ios": "tg://",
        "ph.telegra.Telegraph": "tg://",
        // NOT `tg://`, which is shared with official Telegram — iOS would pick between them.
        "app.swiftgram.ios": "sg://",
        // This bundle identifier is Slack. Verified on device: `://open` carries a verb,
        // which is the shape that turned out wrong for Messages, and here it resumes
        // correctly. Second time the name-shape heuristic raised a false alarm.
        "com.tinyspeck.chatlyio": "slack://open",
        // This bundle identifier is Simplenote.
        "com.codality.NotationalFlow": "simplenote://",
        "com.microsoft.Office.Word": "ms-word://",
        "com.microsoft.Office.Outlook": "ms-outlook://",
        "com.microsoft.skype.teams": "msteams://",
        "com.culturedcode.ThingsiPhone": "things://",
        "com.google.Gmail": "googlegmail://",
        "com.google.chrome.ios": "googlechrome://",
        "com.google.Translate": "googletranslate://",
        "com.google.OPA": "google://",
        "com.google.GoogleMobile": "googlemobileapp://",
        "com.google.gemini": "gemini-app://",
        "com.facebook.Facebook": "fb://",
        "com.facebook.Messenger": "fb-messenger://",
        "com.atebits.Tweetie2": "twitter://",
        "com.toyopagroup.picaboo": "snapchat://",
        "com.burbn.instagram": "instagram://",
        "com.burbn.barcelona": "barcelona://",
        "com.viber": "viber://",
        "com.spotify.client": "spotify://",
        "com.spotify.client.L32G8C83V9": "spotify://",
        "com.getdropbox.Dropbox": "dbapi-1://",
        "com.linkedin.LinkedIn": "linkedin://",
        // Verified on device.
        "com.openai.chat": "com.openai.chat://",
        "ai.perplexity.app": "perplexity-app://",
        // Verified on device, T3 Code 1.2.0, 2026-09-22. The first entry added on purpose
        // rather than inherited, and it was in `knownNoSchemeHosts` until then. The scheme
        // always opened the app; up to 1.1.0 it also reset navigation to Home, measured on
        // device with `t3code://` and `t3code:///` alike. Upstream fixed that on our report
        // (pingdotgg/t3code#11950, #12002), so a result measured before 1.2.0 says nothing
        // about this entry. NOT the `.dev`, `.preview` or `.swiftui` bundles: nobody
        // outside T3's team runs them, and none was tested.
        "com.t3tools.t3code": "t3code://",
        "ai.x.GrokApp": "grok://",
        "md.obsidian": "obsidian://",
        "im.monica.app.monica": "monica://",
        "com.mem-labs.mem": "mem://",
        "com.cardify.tinder": "tinder://",
        "com.readdle.smartemail": "readdle-spark://",
        "com.hammerandchisel.discord": "discord://",
        "org.whispersystems.signal": "sgnl://",
        "co.fluder.mobile.FSNotes-iOS": "fsnotes://",
        "ch.threema.iapp": "threema://",
        "com.briansunter.logseq-dev": "logseq://",
        // Verified on device.
        "com.github.stormbreaker.prod": "github://",
        "com.appliedphasor.secure-shellfish": "shellfish://",
        "com.crystalnix.ServerAuditor": "termius://",
        "com.reddit.Reddit": "reddit://",
        "pro.writer": "ia-writer://",
        "ru.yandex.mobile.translate": "yandextranslate://",
        "com.openminis.app": "minis://",
        "com.tencent.xin": "weixin://",
        "com.letterboxd.LetterboxdApp": "letterboxd://",
        "eusoft.eudic.ip": "eudic://",
        "com.ex3ndr.happy": "happy://",
        "psyche.kelivo": "kelivo://",
        "com.agiletortoise.Drafts5": "drafts://",
        "com.ubercab.UberClient": "uber://",
        // Synced from upstream on 2026-10-01 (VivaDicta 3.11.0 and 3.11.1). Read from the
        // app's own Info.plist, source or published docs, never tested here.
        "com.logseq.logseq": "logseq://",
        // NOT `matrix://`, which other Matrix clients share.
        "io.element.elementx": "io.element.elementx://",
        "ai.openclawfoundation.app": "openclaw://",
        "com.apple.shortcuts": "shortcuts://",
        "com.apple.Maps": "maps://",
        "com.apple.mobilecal": "calshow://",
        "com.google.Maps": "comgooglemaps://",
        // The inline Notes editor drawn inside other apps. The note lives in Notes, so
        // that is where the user came from.
        "com.apple.mobilenotes.EditorExtension": "mobilenotes://",
        "sh.paseo": "paseo://",
        // NOT `sip:`, which is shared.
        "com.silentcircle.SilentPhone": "silentphone://",
        "ai.pocketpal": "pocketpal://",
        "app.cogwheel.conduit": "conduit://",
        // NOT `http`/`https`, which both browsers also claim.
        "com.brave.ios.browser": "brave://",
        "org.mozilla.ios.Firefox": "firefox://",
        "com.mattermost.rn": "mattermost://",
        "io.raindrop.ios": "raindrop://",
        "com.ntoporcov.openclient": "openclient://",
        // NOT `tg://`, which is shared with official Telegram.
        "app.nicegram": "nicegram://",
        // Was in `knownNoSchemeHosts` until upstream read a scheme out of its source on
        // 2026-09-28.
        "h3p.Neon-Vision-Editor": "neonvisioneditor://",
        "xyz.block.buzz.mobile": "buzz://",
        // Synced from VivaDicta `92e2416c` (2026-10-31) on 2026-11-05. Read from the
        // app's source or vendor docs upstream, never tested here.
        "com.standardnotes.standardnotes": "com.standardnotes.standardnotes://", // packages/mobile/ios/StandardNotes/Info.plist: the scheme is $(PRODUCT_BUNDLE_IDENTIFIER)
        "app.getbb.mobile": "bb://", // bb; apps/mobile/app.json in get-bb/bb (Expo "scheme"); not on the App Store, TestFlight build
        "com.cherryai.cherrystudio-app": "cherrystudio://", // Cherry Studio; app.config.ts in CherryHQ/cherry-studio-app (Expo "scheme")
        "com.pentlandFirth.Unwatched": "unwatched://", // Unwatched; Unwatched/Info.plist in fer0n/Unwatched
        "dev.bybee.heeler": "heeler://", // Heeler for herdr; Sources/Heeler/Info.plist in ZingerLittleBee/Heeler
        "xyz.nextalone.nagram": "nagram://", // Nagram; Telegram/Telegram-iOS/Info.plist in NextAlone/Nagram-iOS; NOT tg://, shared with Telegram
        "im.vector.app": "element://", // Element Classic; Config/AppIdentifiers.xcconfig APPLICATION_SCHEME in element-hq/element-ios; NOT matrix://, shared with other Matrix clients
        "dev.herdr.HerdrChat": "herdrchat://", // HerdrChat; app.json in cobanov/herdrchat (Expo "scheme")
        "wiki.qaq.flow": "flowdown://", // FlowDown; FlowDown/Resources/InfoPlist/Info-iOS.plist + Configuration/Base.xcconfig in Lakr233/FlowDown
        "com.apple.mobileslideshow": "photos-redirect://", // Photos; 2026-10-03, community lists, not read from the binary
        "com.microsoft.onenote": "onenote://", // OneNote; 2026-10-10, vendor docs (Graph "open OneNote client") show only onenote:https://<page> forms
        "com.tapbots.Ivory": "ivory://", // Ivory; 2026-10-10, tapbots.com support docs show only ivory://acct/... forms
        "com.bytecrossing.Egern": "egern://", // Egern; 2026-10-17, vendor docs (egernapp.com/docs/url-scheme)
        "com.lukilabs.lukiapp": "craftdocs://", // Craft; 2026-10-24, vendor docs (support.craft.do "Using URL Scheme") show only craftdocs://<action> forms
        "com.fogcreek.trello": "trello://", // Trello; 2026-10-24, Atlassian support "Automate with URL Scheme" shows only trello://x-callback-url/... forms; AASA has no root path
        "com.kagi.kagiiOS": "orion://", // Orion Browser; 2026-10-24, help.kagi.com technical docs show only orion://open-url and orion://search forms
        "org.zulip.Zulip": "zulip://", // Zulip; 2026-10-24, ios/Runner/Info.plist in zulip/zulip-flutter, but the app handles only zulip://login, so a bare open just foregrounds it

        // Corroborated across independent sources but not read from a shipping app, so a
        // miss is possible. It degrades to the overlay.
        "notion.id": "notion://",
        "com.meituan.imeituan": "imeituan://",
        "com.newin.nplayer.basic": "nplayer-http://",
        "com.evernote.iPhone.Evernote": "evernote://",
        "jp.naver.line": "line://",
        "com.google.ios.youtube": "youtube://",
        "com.ebay.iphone": "ebay://",
        "com.google.Docs": "googledocs://",
        "com.taobao.taobao4iphone": "taobao://",
        "company.thebrowser.ArcMobile2": "arcmobile2://",
        "com.linear.ios": "linear://",
        "com.iwilab.KakaoTalk": "kakaotalk://",
        "com.apple.AppStore": "itms-apps://",
        // rednote / Xiaohongshu.
        "com.xingin.discover": "xhsdiscover://",
        "doordash.DoorDashConsumer": "doordash://",
        "pinterest": "pinterest://",

        // Single-source or inferred from a sibling platform. Weaker still, and kept only
        // because a miss costs nothing beyond the prompt the user would otherwise get.
        "com.alibaba.sourcing": "enalibaba://",
        "com.automattic.beeper": "beeper://",
        "com.xiaojukeji.didi": "diditaxi://",
        // VK Messenger. NOT the `vk.me` universal link — the main VK client claims that
        // domain with the same wildcard, so iOS picks between them.
        "com.vk.vkme": "vkme://",
        "com.overdesigned.Cheatsheet": "cheatsheet://",
        "net.ichi2.anki": "anki://",
        "net.shinyfrog.bear-iOS": "bear://",
        "app.getmoshi.ios": "moshi://",
        "com.google.Keep": "comgooglekeep://",
        // WeCom.
        "com.tencent.ww": "wxwork://",
        "com.dianping.dpscope": "dianping://",
        // Yandex Browser, not the Yandex app. An open-URL scheme: action-shaped by name.
        "ru.yandex.mobile.search": "yandexbrowser-open-url://",
        // Upstream notes the simulator carries only a stub of Translate.app.
        "com.apple.Translate": "translate://",

        // No custom scheme; a universal link confirmed in the app's AASA file. See the
        // trade-off in this property's doc comment, and the audit note above: a root URL
        // is a navigation by construction, so none of these can resume the app where the
        // user left it. Untested, and suspect on the resume criterion.
        "com.google.ios.ytcreator": "https://studio.youtube.com/",
        "com.amazon.Amazon": "https://www.amazon.com/",
        "com.amazon.AmazonDE": "https://www.amazon.de/",
        "com.amazon.AmazonUK": "https://www.amazon.co.uk/",
        "ru.ivi": "https://www.ivi.ru/",
        "ru.oneme.app": "https://max.ru/",
        "ru.ozon.OzonStore": "https://www.ozon.ru/",
        "com.ClassDojo": "https://www.classdojo.com/ul/home",
        "com.kouzoh.ios.mercari": "https://jp.mercari.com/",
        "com.ubercab.UberEats": "https://www.ubereats.com/",
        // Synced from upstream on 2026-10-01, same caveat.
        "com.zhiliaoapp.musically": "https://www.tiktok.com/",
        "com.google.NotebookLM": "https://notebooklm.google/app",
        "com.360buy.jdmobile": "https://m.jd.com/",
        "com.waze.iphone": "https://www.waze.com/ul",
        "ru.avito.app": "https://www.avito.ru/",
        "vn.com.vng.zingalo": "https://zalo.me/",
        // NOT `vk://`: several VK apps share one team.
        "com.vk.vkclient": "https://vk.com/feed",
        "com.dazz.hoop": "https://hoop.photo/",
        "com.airbnb.app": "https://www.airbnb.com/",
        "com.kk2.rootshell": "https://rootshell.com/",
        "com.moonshot.kimichat": "https://kimi.com/app/",
        "co.hinge.mobile.ios": "https://hinge.co/app/",
        // `raycast://` is the macOS scheme.
        "com.raycast.ios.release": "https://raycast.com/ios-app-link/",
        "com.duolingo.DuolingoMobile": "https://duolingo.com/home",
        // Meta AI.
        "com.facebook.stellaapp": "https://www.meta.ai/",
        "com.yandex.alice-app": "https://alice.yandex.ru/",
        // Google Chat.
        "com.google.Dynamite": "https://chat.google.com/",
        // Google Flow Music.
        "com.google.producer": "https://www.flowmusic.app/",
        "com.beeasy.shopee.my": "https://shopee.com.my/",
        "com.abbyhealth.app": "https://app.abbyhealth.app/",
        // Alza.
        "cz.juicymo.contracts.ios.Alza-01": "https://www.alza.cz/",
        "com.google.Drive": "https://drive.google.com/drive/my-drive",
        // Weaker: the AASA lists the bundle only for a specific page.
        "com.quizlet.quizlet": "https://quizlet.com/latest/",
        // Qwen international.
        "com.tongyi.intl": "https://qwen.com/app/",
        "com.audible.iphone": "https://www.audible.com/iosinstall/",
        // Kuaishou.
        "com.jiangjia.gif": "https://m.ssl.kuaishou.com/app/",
        "com.bloomberg.Bloomberg": "https://www.bloomberg.com/latest",
        // eXpress messenger.
        "ru.unlimitedtech.express": "https://xlnk.ms/open/",
        // Synced from VivaDicta `92e2416c` (2026-10-31) on 2026-11-05, same caveat. Some are
        // a deep path rather than the root, where the AASA lists only that path.
        "com.microsoft.officemobile": "https://m365.cloud.microsoft/", // Microsoft 365 Copilot; AASA paths / and /*
        "com.skout.SKOUT": "https://www.skout.com/",
        "com.thecarousell.Carousell": "https://www.carousell.sg/", // carousell.com sits behind a Cloudflare challenge
        "com.apple.supportapp": "https://getsupport.apple.com/", // Apple Support; AASA catch-all /*
        "com.alibaba.iAliexpress": "https://www.aliexpress.com/", // AliExpress; AASA served at the root, not /.well-known
        "com.luma.mobile": "https://luma.com/", // Luma; AASA /* with exclusions that spare the root
        "kz.slando": "https://www.olx.kz/", // OLX.kz; AASA paths ["*"]
        "RU.WILDBERRIES.MOBILEAPP": "https://www.wildberries.ru/", // Wildberries; AASA lists / for the bundle
        "com.comuto.comuto": "https://www.blablacar.fr/", // BlaBlaCar; AASA lists / for the bundle (www.blablacar.com serves none)
        "com.walmart.electronics": "https://www.walmart.com/", // Walmart; AASA component /
        "fr.leboncoin.Leboncoin": "https://www.leboncoin.fr/", // leboncoin; AASA path /
        "com.ebaykleinanzeigen.ebc": "https://www.kleinanzeigen.de/", // Kleinanzeigen; AASA path / for the bundle
        "com.ss.iphone.ugc.Aweme": "https://www.douyin.com/", // Douyin; AASA path / for the bundle
        "ru.yandex.ytaxi": "https://go.yandex/", // Yandex Go; AASA path / for the bundle
        "com.facebook.hatch": "https://muse.ai/open_hatch", // Muse from Meta; 2026-10-03, AASA lists /open_hatch, no root path
        "com.taimi.ios": "https://taimi.com/applink", // Taimi; 2026-10-10, AASA lists /applink only, no root path
        "com.toggl.daneel": "https://track.toggl.com/timer/", // Toggl Track; 2026-10-10, AASA path /timer/* (the Track web home); toggl.com has no AASA
        "co.switch.Switch": "https://dialpad.com/app/", // Dialpad (ex-Switch); 2026-10-10, AASA path /app/*
        "com.picsart.studio": "https://picsart.com/open", // Picsart; 2026-10-10, AASA path /open (exact, no trailing slash)
        "com.teslamotors.TeslaApp": "https://www.tesla.com/1/app/home", // Tesla; 2026-10-10, AASA path /1/app/home ("Open Tesla App"), read via Apple's CDN mirror
        "de.barmergek.serviceapp": "https://link-registry.bconnect.barmer.de/barmer/foreground", // Meine BARMER; 2026-10-10, AASA path /barmer/foreground
        "com.kindroid.app": "https://kindroid-ai.firebaseapp.com/", // Kindroid; 2026-10-17, AASA /* on the Firebase auth domain; kindroid.ai serves no AASA
        "com.linguee.DeepLMobileTranslator": "https://www.deepl.com/ul/", // DeepL; 2026-10-17, AASA path /ul/* only, no root path
        "io.elevenlabs.readerapp": "https://elevenlabs.io/readerapp", // ElevenReader; 2026-10-17, AASA lists the exact path /readerapp

        // From the return table shipped in Typeless 2.7.0 (its LSApplicationQueriesSchemes
        // list), not verified on device here. A miss degrades to the swipe-back screen.
        "com.larksuite.lark": "lark://",
        "com.microsoft.copilot": "copilotn://",
        "com.atlassian.jira.app": "jira://",
        "com.monday.monday": "monday://",
        "com.netflix.Netflix": "nflx://",
        "com.substack.Substack": "substack://"
    ]

    /// Hosts known to have no way back. They skip straight to the swipe-back
    /// screen and are not worth listing as gaps.
    public static let knownNoSchemeHosts: Set<String> = [
        // Ours. The keyboard can be its own host (a text field in VoiceiQ) and
        // returning the user to the app they are already in would be a no-op.
        "io.blue.voiceiq.ios",

        // Safari, deliberately. It is not that no scheme opens it — several do — but that
        // every one of them *acts*: `x-web-search://` opens an empty search and
        // `x-safari-https://` a blank tab, and both discard the page the user was reading.
        // Measured on iOS 26.5. Landing someone on a blank tab is worse than the
        // swipe-back overlay, which leaves their page where it was, so Safari is listed
        // as having no way back rather than a bad one.
        "com.apple.mobilesafari",

        // Claude, for the same reason as Safari: `claude://` opens it on a new chat, not
        // the conversation the user was typing in. Measured on device 2026-10-01, and
        // Wispr Flow does not auto-return to Claude either. A 2026-09-11 check had passed
        // it, so retest on a Claude update rather than trusting either result forever.
        "com.anthropic.claude",

        // Orca, the same way: `orca://` is its only URL, and Expo Router routes it to the
        // home screen, out of the agent chat (VivaDicta `5944540a`, from stablyai/orca).
        "com.stably.orca.mobile",

        // Apple view services and system apps that register no URL types.
        "com.apple.SafariViewService",
        "com.apple.springboard",
        // Confirmed on device: it is reached as a real host and correctly falls to
        // `no-scheme-known` rather than being reported as a gap.
        "com.apple.Spotlight",
        "com.apple.journal",
        "com.apple.mobilesms.compose",
        "com.apple.ShortcutsUI",
        "com.apple.AppleMediaServicesUI.ComposeReviewExtension",

        // Checked by hand upstream: no custom scheme, and no universal link that opens
        // the app at its root.
        "com.deepseek.chat",
        "com.hevyapp.hevy",
        "org.edupage",
        "com.rivetrune.cognilog",
        "com.davetech.todo",
        "cc.calacatta.happiest",

        // Third-party apps upstream found to publish no way back.
        "com.dmitrii.medvedev.gptalk",
        "com.saner.ai",
        "dk.FirstForm.SnappyNotesiOS",
        "com.ai.venice",
        "com.replay.Echo",
        "com.avast.ios.security",
        "com.elaborapp.NoteBox",
        "com.lixkit.diary",
        "com.weichart.Zettel",
        "ru.ozon.sellerApp",
        "kz.origon.empapp",
        "com.cloud-compiler",
        "com.corp.messenger.syncer",
        "com.yottaram.eMoods",

        // Synced from upstream on 2026-10-01 (VivaDicta 3.11.0 and 3.11.1).
        // System apps and view services that register no URL types.
        "com.apple.campo",
        "com.apple.siri",
        "com.apple.Preferences",
        "com.apple.WritingToolsUIService",
        "com.apple.GenerativePlaygroundApp",
        // `tel:` needs a number; nothing opens Phone bare.
        "com.apple.mobilephone",
        // Share extensions: the surface the user typed into is gone on return, and the
        // parent app is not where they were.
        "net.whatsapp.WhatsApp.ShareExtension",
        "ph.telegra.Telegraph.Share",
        "io.raindrop.ios.share",
        // Telegram forks and a Happy fork: they share the upstream app's scheme, so
        // mapping them would let iOS pick which claimant opens.
        "org.denshe.telegramdev",
        "com.olcorporation.olai",
        "com.omachala.happy",
        // A sibling bundle of T3 Code, untested (see the T3 Code entry).
        "com.t3tools.t3code.swiftui",
        // Third-party apps with no custom scheme and no usable universal link.
        "tech.baye.OpenCat",
        "Mailroom.Canary-iOS",
        "4GU63N96WE.com.p5sys.jumpdesktop",
        "org.kodiakgaming.Whisper-Secrets",
        "ch.migrosbank.iphonebanking",
        "com.tencent.workbuddy.app",
        "com.whisper.social",
        "com.yottagames.gameofmafia",
        "cz.mobilcomm.askwatch",
        "ru.kwork.messenger",
        "com.anuvadini.keyboard",
        "com.booking.pulse",
        "com.doordash.dasher",
        "com.larksuite.feishu.ka.fssw",
        "com.microsoft.to-do",
        "com.supersethealth.superset",
        "ru.yandex.uber",
        "ai.qwenlm.chat.ios",
        "com.scaleforce.mobile.myexcitel",
        "co.anysphere.sand",
        "com.x.xchat",
        "com.gingerlabs.Notability",
        "agata.Snippets",
        "ru.bankffin.ffbank",
        "ru.wildberries.wbworkspace",
        "kras-abs.ru.MC-VK-Komfort",
        "cz.chmu.pocasi",
        "online.anero.app",
        "com.ios.aquaMagic062516.cn",
        "mystxtalk",

        // Synced from VivaDicta `92e2416c` (2026-10-31) on 2026-11-05. Checked upstream:
        // no custom scheme, and no universal link that opens the app at its root.
        "com.satisfyer.connect", // Satisfyer Connect - satisfyer.com serves no AASA
        "ru.yandex.telemost", // Yandex Telemost - AASA covers /j/* and /join/* meeting links only
        "com.bitrixsoft.cpmobile", // Bitrix24 - AASA covers per-portal deep paths only
        "com.grindrguy.grindrx", // Grindr - AASA covers /blog and /content-hub only
        "com.guion.flicknote", // FlickNote - flicknote.app serves no AASA
        "com.museai.asst.mobile", // not on the App Store, nothing to verify
        "life.dailypresence.presence", // Presence - no seller site, no AASA
        "com.taskrabbit.site", // Taskrabbit - AASA has no root path; /dashboard would pull the user out of the chat or form they were typing in
        "app.ish.iSH", // iSH Shell - app/Info.plist in ish-app/ish registers no URL types; no AASA
        "ai.perplexity.comet.ios", // Comet browser - perplexity.ai AASA lists the id under webcredentials only
        "com.tinginteractive.usms", // TextNow - textnow.com AASA has webcredentials only, no applinks
        "a4a.radarlive", // Adam4Adam - no AASA on any seller domain
        "com.consim.bharatMatrimony", // Bharat Matrimony - AASA covers /bm.php* and /c/e.php* only
        "com.kunchenguid.sshhip", // SSHHIP - sshhip.com serves no AASA
        "com.security.BatteryCam", // Anker eufy - no AASA on eufy.com / eufylife.com
        "com.amazon.echo", // Amazon Alexa - AASA has no root path; /spa/* is the web-app shell and would navigate away
        "com.zoho.zmail", // Zoho Mail - AASA matches /zm/* with a #mail* fragment only; an inbox link would pull the user out of the draft
        "com.apple.MailCompositionService", // Mail compose sheet hosted in another app
        "com.apple.DocumentManagerUICore.SaveToFiles", // "Save to Files" sheet
        "com.t3tools.t3code.swiftui.dev.AUW3D5DD4J", // third-party dev build of the T3 Code fork; no verifiable mapping
        "com.superhuman.Superhuman", // Superhuman Mail - AASA catch-all, but the root is the inbox and would pull the user out of the draft
        "com.harklabs.hark", // Hark Pro - AASA path /chat likely opens a new chat (same reason Claude stays unmapped)
        "ai.opencode.mobilecode", // not on the App Store, nothing to verify
        "app.locallyai.Locally", // Locally AI - lmstudio.ai AASA lists only a login callback path
        "com.adhoclabs.burner", // Burner - AASA covers /buy and /promo only
        "com.apple.mobiletimer", // Clock - clock-* schemes are undocumented and switch tabs, which could close the label editor
        "com.apple.ReminderKitUI.ReminderCreationViewService", // Reminders "create reminder" sheet hosted in another app
        "com.example.piliplus.MU4RQPHZK2", // PiliPlus sideloaded build - its only scheme bilibili:// is shared
        "com.moxco.bumble", // Bumble - AASA has no root path
        "com.redpax.speakli", // KeySpeech - no AASA, no known scheme
        "com.tencent.mqq", // QQ - qm.qq.com catch-all is also claimed by TIM, so iOS picks between them
        "do.fizzy.app.ios", // Fizzy - AASA catch-all, but the root is the board and would pull the user out of the card
        "app.spine.Spine", // Spine audiobook player - spine.merifiles.com serves no AASA
        "com.5n6.LiberaGPT", // LiberaGPT - liberagpt.com serves no AASA
        "com.alipay.iphoneclient", // Alipay - render.alipay.com AASA covers redirector paths only (p/s/i/, p/s/ulink/)
        "com.apple.VoiceMemos", // Voice Memos - no documented scheme
        "com.byoklab.gitdo", // not on the App Store, nothing to verify
        "com.duckduckgo.mobile.ios", // DuckDuckGo - every own scheme is an action (ddgNewSearch, ddgFireButton...), http/https are shared, and the AASA catch-all root is a new search
        "com.google.AIEdgeGallery", // Google AI Edge Gallery - no known scheme; google-ai-edge/gallery carries no iOS source with this id
        "com.noteful-technologies.noteful", // Noteful - no seller site, no AASA, no known scheme
        "com.slack.slackmdm", // Slack for EMM - slack.com /app/open is also claimed by the main Slack app, so iOS picks between them
        "com.teacapps.QRbot", // QRbot - qrbot.net AASA covers the x-callback-url scan/create actions only
        "com.whoop.iphone", // WHOOP - AASA has no root path; /home would pull the user out of the coach chat or journal
        "apify.privateai.macos.prod", // Enclave - enclaveai.app serves no AASA, closed source
        "app.atomicchat.com", // Atomic Chat - AtomicBot-ai/Atomic-Chat holds only the desktop build (chat.atomic.app); atomic.chat AASA does not list this id
        "com.blubox.prod", // blu box - no seller site, no known scheme
        "com.bookfusion.bookfusion", // BookFusion - AASA covers /highlights/*/open only
        "com.deewarmarket.ios", // Deewar - deewarmarket.com serves no AASA
        "com.gluegroups.glue", // Glue - AASA catch-all, but the root is the inbox and would pull the user out of the thread
        "com.kingdee.MyMoneyPro", // 随手记Pro (Feidee) - feidee.com serves no AASA, no known scheme
        "com.lucas.goals", // not on the App Store, nothing to verify
        "com.mocomediallc.fastfriend", // DrugVokrug - drugvokrug.ru AASA root is shared with com.myfriends.live and com.myfriends.dv, so iOS picks between them
        "com.mwaldman.loci-ai", // Loci - lociai.app AASA covers /link pairing paths only
        "com.spliiit.spliiit", // Spliiit - spliiit.com serves no AASA
        "com.starshipBattle.commander", // not on the App Store, nothing to verify
        "de.caseprep.app", // CasePrep - no seller site, no known scheme
        "dk.simonbs.RunestoneEditor", // Runestone - app source is closed (only the editor framework is open), runestone.app serves no AASA
        "org.whispersystems.signal.shareextension", // Signal share extension
        "com.apple.mobilenotes.SharingExtension", // Notes "Add to Notes" share sheet
        "com.linear.ios.ShareExtension" // Linear share extension
    ]

    /// The return URL for `bundleId`, preferring a user override.
    public static func returnURL(forHostId bundleId: String, overrides: [String: String] = [:]) -> URL? {
        (overrides[bundleId] ?? schemesByBundleId[bundleId]).flatMap(URL.init(string:))
    }

    /// True for a host with no entry that is not known to lack one: a gap in the table.
    public static func isWorthReporting(_ bundleId: String) -> Bool {
        schemesByBundleId[bundleId] == nil && !knownNoSchemeHosts.contains(bundleId)
    }
}
