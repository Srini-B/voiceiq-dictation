# 2026-11-17: The meeting offer names only call apps and meeting pages (Mac)

## Why

The pill offered "Meeting in Granola Helper (MacOSMicAppsWithDevices) —
record it?" whenever Granola recorded a meeting or dictated, and "Meeting in
Jump Desktop …" whenever the Jump Desktop client passed the Mac's microphone
to a remote machine. During a real Google Meet in Chrome with Granola
recording, the offer still named Granola.

## Cause

`CallDetector`'s last rule offered any app that both captured the mic and
played sound, skipping the bundle IDs in `CallApps.notCalls`. Three things
went wrong:

- The rule matched by the exact bundle ID of the process that held the mic.
  Granola captures from a helper app with its own bundle ID, so
  `com.granola.app` in `notCalls` never matched it. The offer then showed that
  process's `localizedName` as is.
- The Jump Desktop client was not on the list. It plays the remote machine's
  sound and captures the real mic, so it looked like a call. The earlier fix
  (2026-10-23) covered only Jump Desktop Connect, the host side, whose audio
  goes through Jump's own drivers.
- The detector kept the first source it offered. When a meeting page turned up
  after another source, the offer kept the old name.

This is the third time the rule caught a non-call (Jump Desktop Connect on
2026-10-23, Superwhisper on 2026-11-02). Recorders, dictation tools, remote
desktop clients and virtual machines all capture and play sound, so an
exclusion list can never be complete.

## What changed

- A native app is a call only when it is in `CallApps.known`. The two-way
  audio rule now covers only browser pages (a call on a site not in
  `meetingPages`), with Chrome Remote Desktop added to `notCallPages`.
  `notCalls`, `CallApps.vendor` and the Jump driver check
  (`routesOwnAudio`, `deviceDrivers`) had no remaining use and were removed.
- A running app whose bundle sits inside another app's bundle is mapped to
  that app (`CallDetector.containingApp`) before the lists are checked, so
  the offer names "Google Chrome", not "Google Chrome Helper".
- A meeting page is named by its host ("meet.google.com"), or for a title
  match by `CallApps.meetingTitles` ("Google Meet"). Before this it showed
  the matched pattern, such as "meet.google.com/".
- A known app, call daemon or meeting page seen on two polls in a row
  replaces an offer for a tab that only looked like a call
  (`CallDetector.poll`, `MeetingEngine.detected`). Another look-alike tab
  never replaces one: the name follows the front tab while the audio is the
  whole browser's, so switching tabs mid-call is not a new call (from
  review). A recording keeps its call.

## More call apps, sites and browsers

The known-apps-only rule stays (the trade-off was accepted), so the list was
widened. Each new bundle ID was read from a real bundle, not guessed:

| App | Bundle ID | Source |
| --- | --- | --- |
| Lark | com.larksuite.larkApp | LarkSuite.app Info.plist, Homebrew cask `lark` DMG |
| Lark (App Store) | com.larksuite.macos.lark | App Store lookup |
| Feishu | com.electron.lark | Lark.app Info.plist, cask `feishu` DMG |
| Pop | com.pop.pop.app | Info.plist, cask `pop-app` |
| Zoho Meeting | com.electron.zohomeeting | Info.plist, meeting.zoho.com/agent DMG |
| Jitsi Meet | org.jitsi.jitsi-meet | Info.plist, cask `jitsi-meet` |
| Gather | com.gather.Gather | Info.plist, cask `gather` |
| 8x8 Work | com.electron.8x8---virtual-office | Info.plist, cask `8x8-work` |
| Dialpad | com.electron.dialpad | Info.plist, cask `dialpad` pkg |
| Vonage Business | com.vonage.vbc | Info.plist, vbc-downloads.vonage.com DMG |
| Wire | com.wearezeta.zclient.mac | Info.plist, cask `wire` pkg; same ID on the App Store |
| Threema / Threema Work | threema-consumer-web / threema-work-web | Info.plist, casks `threema`, `threema-work` |
| KakaoTalk | com.kakao.KakaoTalkMac | App Store lookup |
| Zalo | com.vng.zalo | Info.plist, cask `zalo` |
| Mattermost | Mattermost.Desktop | Info.plist, cask `mattermost`; same ID on the App Store |
| Zoiper | com.securax.zoiper5 | Zoiper5.app Info.plist, zoiper.com pkg |
| Bria | com.CounterPath_Corporation.Bria | Info.plist, cask `bria` |

Browsers, from their Info.plist in each cask: Dia `company.thebrowser.dia`,
Comet `ai.perplexity.comet`, Orion `com.kagi.kagimacOS`, Safari Technology
Preview `com.apple.SafariTechnologyPreview`, Edge
`com.microsoft.edgemac.Beta` / `.Dev` / `.Canary`.

Lark, Feishu, Wire, Threema, KakaoTalk, Zalo and Mattermost also send voice
messages, so they are in `voiceNoteApps`. Whereby has no Mac app (its help
pages say it is browser-only), so only its site is listed.

New meeting pages, from vendor help pages: teams.cloud.microsoft,
pop.com/j/, vc.larksuite.com, vc.feishu.cn, meetings.dialpad.com,
app.dialpad.com, 8x8.vc/, meetings.vonage.com, app.vonage.com.

## Decisions

- **No allow or ignore list in Settings.** An ignore list has nothing left to
  do: only listed call apps and browsers can raise the offer. An allow list
  would serve only a call app missing from `CallApps.known`. Option-M already
  records any call, and a missing app is a one-line addition to `known`.
- **Lost:** a native call app that is not in `known` no longer gets an offer.
  Taken because every false offer so far came from that rule, and each needed
  a fix after a user saw it.
- **Chrome extension signal not used for detection.** The extension runs only
  on the meeting sites `meetingPages` already lists, and it reports only while
  someone talks. It would add no site and would miss silent stretches.

## Verification

On a test Mac, at the previous main (base) and with the change (fix). `scripts/test.sh`
exited 0 (183 tests). `scripts/release.sh` exited 0, and the build was
notarized and installed. A scratch harness printed `CallDetector.onChange`
for each build while scratch apps captured the mic and played a tone:

| Scenario | Base | Fix |
| --- | --- | --- |
| A: Granola.app with a nested "Granola Helper (MacOSMicAppsWithDevices).app" | offers the helper's raw name | nothing |
| B: app with the Jump Desktop viewer's ID `com.p5sys.jump.mac.viewer` | offers "Jump Desktop" | nothing |
| C: helper from A, then Chrome on meet.google.com/abc-defg-hij | stays on the Granola helper | the Meet page, about 6 s after it starts |
| D: Chrome page with two-way audio, then titled "Meet - …" | first page only | first page, then the meeting about 10 s later |
| E: app with Zoom's ID | Zoom | Zoom |

On the installed builds, scenario A showed "Meeting in Granola Helper
(MacOSMicAppsWithDevices) — record it?" on 0.7.7 and no offer on the fix.
Scenario C showed "Meeting in meet.google.com/ — record it?", and the matched
pattern's trailing slash led to the host naming change above. After that
change, the tests passed again (exit 0) and the harness showed C as
"meet.google.com" and D's title match as "Google Meet". The rebuilt
notarized app showed "Meeting in meet.google.com — record it?".

After the list was widened, the tests passed again (exit 0, 187 tests,
including the four in `CallAppsTests`). The harness named an app with Pop's
ID "Pop". It offered nothing for an app with Zalo's ID that only captured the
mic, and "Zalo" once that app also played sound. It named Chrome on the real
pop.com/j/300-475-962 "pop.com", and still offered nothing for the Granola
helper. The notarized build showed "Meeting in Pop — record it?".

Found, not changed: when two instances of one browser run at once, they share
a bundle ID, so either instance can name a look-alike page.

Not tested: real Granola, real Zoom, the real Jump Desktop client proxying a
mic, and a signed-in Meet call.
