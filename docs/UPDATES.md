# Releases and macOS auto-update

A release ships the Mac and iPhone apps together, with one version number.
Pushing a change to `MARKETING_VERSION` in `project.yml` to `main` starts it;
GitHub Actions builds both apps, writes the release notes with OpenAI, uploads
the iPhone app to TestFlight, and publishes the Mac app on GitHub Releases,
where installed copies update themselves with [Sparkle 2](https://sparkle-project.org).

## Releasing

1. In `project.yml`, raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
   (the build number). They are set once, under `settings`, for every target.
2. Commit and push to `main`.

That is all. `.github/workflows/release.yml` then runs:

```text
plan ─▶ notes ─┬▶ ios    archive, upload to TestFlight, set What to Test
               └▶ macos  test, build, notarize, DMG and ZIP ─┐
                                                             ▼
                  publish  GitHub release v<version> (tag, notes, ZIP, DMG, appcast.xml)
```

- **plan** (`scripts/ci-plan-release.sh`) releases only when the push changed
  `MARKETING_VERSION` and the tag `v<version>` does not exist, and fails if the
  build number is not above the previous version's.
- **notes** (`scripts/generate-release-notes.py`) finds the previous version's
  commit, sends the commit messages and code diff since then to `gpt-6-luna`,
  and writes three files: `github.md` (the release body), `mac.md` (Sparkle's
  update alert) and `ios.txt` (TestFlight's What to Test).
- **ios** runs `scripts/release-ios.sh`. The build number must be new on
  TestFlight; the "VoiceiQ Internal" group gets the build automatically.
- **macos** runs `scripts/release.sh`, notarizing with the App Store Connect key.
- **publish** runs `scripts/publish-github-release.sh` once both apps built, so
  the two never ship different versions. It creates the tag; nobody tags by hand.
  The update alert's notes cover every version the user is missing (below).

A failed job can be re-run from the Actions page. The TestFlight upload and the
GitHub release each refuse to repeat a build that already went out.

To rehearse, run the workflow by hand (Actions › Release › Run workflow). It
defaults to a dry run that builds, notarizes and checks everything and uploads
nothing. A dry run also works on a branch and on a version that is already
tagged: `gh workflow run release.yml --ref <branch> -f dry_run=true`.

### How the previous version is found

The notes cover the commits since the previous release. That is the tag
`v<previous version>` when it exists (every release from this workflow has
one), otherwise the commit that set `MARKETING_VERSION` to the previous
version. Check it with:

```bash
python3 scripts/generate-release-notes.py --base   # previous version, commit, build
OPENAI_API_KEY=… python3 scripts/generate-release-notes.py /tmp/notes
```

### Notes for users several versions behind

Sparkle's update alert shows only the newest appcast item's notes. So
`scripts/sparkle-release-notes.py` makes that item's notes cover the last 10
versions, newest first, as HTML:

```html
<style>.sparkle-installed-version, .sparkle-installed-version ~ * { display: none; }</style>
<section data-sparkle-version="49"><h3>VoiceiQ 0.6.4</h3><ul>…</ul></section>
<section data-sparkle-version="48"><h3>VoiceiQ 0.6.3</h3><ul>…</ul></section>
…
<p><a href="https://github.com/Srini-B/voiceiq-dictation/releases">Earlier releases</a></p>
```

Sparkle adds the class `sparkle-installed-version` to the section whose build
number matches the installed app, and the CSS hides that section and everything
after it. A user on 0.6.2 sees 0.6.4 and 0.6.3; a user further back than the
list sees all of it and the link. This needs no app code, so it reaches copies
that are already installed.

The earlier sections come from the appcast that is live when publishing: the
sections in its items, or the Markdown notes of items from before this change.
The appcast keeps three items, but each new item carries the history forward.
Preview the HTML for a version with:

```bash
curl -sSL https://github.com/Srini-B/voiceiq-dictation/releases/latest/download/appcast.xml -o /tmp/appcast.xml
python3 scripts/sparkle-release-notes.py /tmp/appcast.xml <build> <version> build/release-notes/mac.md \
  https://github.com/Srini-B/voiceiq-dictation/releases
```

### Secrets

Repository secrets (Settings › Secrets and variables › Actions), set from the
Mac mini's release setup on 2026-09-29:

| Secret | Source |
| --- | --- |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_B64` | App Store Connect key "VoiceiQ release" (`~/.asc` on the Mac mini). Signs asc calls, downloads profiles, notarizes. |
| `SIGNING_P12_B64`, `SIGNING_P12_PASSWORD` | Apple Distribution and Developer ID Application identities, exported from the Mac mini's release keychain. The export and its password are in `~/.voiceiq-signing/ci/` there. |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle update signing key (below). |
| `OPENAI_API_KEY` | Release notes. |

Provisioning profiles are not secrets: `scripts/ci-import-signing.sh`
downloads them by name with asc on every run. To replace a secret:

```bash
ssh using-mac-mini 'base64 -i ~/.voiceiq-signing/ci/signing.p12 | tr -d "\n"' \
  | gh secret set SIGNING_P12_B64 -R Srini-B/voiceiq-dictation
```

When the Developer ID certificate (February 2027) or the Apple Distribution
certificate (September 2027) is renewed, import the new identity into the Mac
mini's release keychain and export it again:

```bash
security export -k ~/Library/Keychains/voiceiq-signing.keychain-db -t identities -f pkcs12 \
  -P "$(cat ~/.voiceiq-signing/ci/p12.pass)" -o ~/.voiceiq-signing/ci/signing.p12
```

### Releasing by hand

The same scripts run on a release Mac (docs/RELEASING.md), in this order:
`scripts/release-ios.sh`, `scripts/release.sh`, then
`RELEASE_NOTES=… SPARKLE_NOTES=… scripts/publish-github-release.sh` (dry run
first with `DRY_RUN=1`). Without `RELEASE_NOTES` it reads
`release-notes/<version>.md`.

## Auto-update in the Mac app

| Setting | Default | Where |
| --- | --- | --- |
| Check for updates automatically (every 6 hours) | On | Settings › About |
| Download and install updates automatically | On | Settings › About, and the checkbox in Sparkle's update alert |

With both on:

1. Sparkle finds the update, downloads it, and checks its EdDSA signature and
   Developer ID.
2. VoiceiQ installs it and relaunches as soon as nothing is in use. It checks
   again every 30 seconds while something is. Until then the status menu says
   "Restart to Install VoiceiQ x.y.z", which installs it at once. Quitting
   VoiceiQ also installs it.
3. After the relaunch the pill says "Updated to VoiceiQ x.y.z".

"In use" means a dictation, Ask Anything or Translate session, a meeting that
is detected, recording or being written up, a History retry or queued
dictation being sent, or an answer on screen.
`UpdatePillController` (`App/Sources/Updates/UpdatePillController.swift`) owns
steps 2 and 3; `AppUpdater` owns Sparkle.

This path never shows release notes, so Settings › About has a Release Notes
button that opens the GitHub Releases page.

With automatic downloads off, Sparkle shows its alert with the release notes,
and the menu item reads "Install VoiceiQ x.y.z…" until the user installs,
skips or dismisses it.

Installing keeps microphone, Accessibility and other permissions, because macOS
ties them to the bundle ID and the Developer ID team, which do not change.

### How the app finds updates

```text
VoiceiQ ──every 6 h──▶ github.com/Srini-B/voiceiq-dictation/releases/latest/download/appcast.xml
                             │  GitHub redirects to the newest release's asset
                             ▼
               newest item: build number, version, notes, ZIP URL, EdDSA signature
                             │  newer CFBundleVersion than the running app?
                             ▼
       download ZIP ─▶ verify signature and Developer ID ─▶ wait until idle ─▶ replace app ─▶ relaunch
```

Configuration is in `project.yml`, VoiceIQ target:

| Key | Value |
| --- | --- |
| `VOICEIQ_UPDATE_FEED_URL` (build setting) → `SUFeedURL` | the appcast URL above |
| `SUPublicEDKey` | Public half of the update signing key |
| `SUEnableAutomaticChecks` | `true`: no permission prompt on the second launch |
| `SUAutomaticallyUpdate` | `true`: default for automatic download |
| `SUScheduledCheckInterval` | `21600` seconds (6 hours) |

The "Sign Sparkle helpers" build phase (`scripts/sign-sparkle.sh`) removes
Sparkle's XPC services, which only sandboxed apps use, and signs `Autoupdate`,
`Updater.app` and the framework with the app's identity and hardened runtime.
Without it notarization rejects the build. `scripts/release.sh` checks that all
three carry the Developer ID team.

### Rules for the Releases page

- Every release marked **Latest** must include `appcast.xml`. The feed URL
  follows the Latest release, so a Latest release without it stops all
  updates. Publish anything else as a pre-release or with `--latest=false`.
- Do not delete a release or its ZIP while the appcast still lists it (the
  newest three).
- To pull a bad update, release a fixed version with a higher build number.

## The update signing key

Sparkle rejects any update whose EdDSA signature does not match
`SUPublicEDKey`. The private key is in three places: the MacBook's login
keychain (account `voiceiq`, a password item for `https://sparkle-project.org`),
`~/.voiceiq-signing/sparkle_ed25519.key` on the Mac mini (mode 0600), and the
`SPARKLE_ED_PRIVATE_KEY` secret. Keep one more copy in the team's password
manager.

The Sparkle tools are in `build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin`
after a release build:

```bash
$BIN/generate_keys --account voiceiq -p                    # print the public key
$BIN/generate_keys --account voiceiq -x ~/voiceiq-sparkle.key   # export the private key
$BIN/generate_keys --account voiceiq -f ~/voiceiq-sparkle.key   # import it on another Mac
```

If the key is lost, the next release can still reach users: Sparkle accepts an
update that changes the EdDSA key as long as it is signed with the same
Developer ID. Generate a new key, put its public half in `SUPublicEDKey`, update
the secret, and release as usual. Never change the Developer ID certificate and
the EdDSA key in the same release.

## First Sparkle release

Builds up to 0.5.3 (28) have no updater. People on those builds install the
first Sparkle-enabled release from its DMG once; from then on it updates itself.

## Testing an update locally

Build two copies under a throwaway bundle ID with a local feed, so they do not
replace or collide with the installed app:

```bash
common=(PRODUCT_BUNDLE_IDENTIFIER=io.blue.voiceiq.updatetest
        VOICEIQ_UPDATE_FEED_URL=http://127.0.0.1:8765/appcast.xml)
./scripts/build.sh "${common[@]}" MARKETING_VERSION=0.0.1 CURRENT_PROJECT_VERSION=1 -derivedDataPath /tmp/vq-old
./scripts/build.sh "${common[@]}" MARKETING_VERSION=0.0.2 CURRENT_PROJECT_VERSION=2 -derivedDataPath /tmp/vq-new
BIN=/tmp/vq-old/SourcePackages/artifacts/sparkle/Sparkle/bin
mkdir -p /tmp/vq-feed
ditto -c -k --sequesterRsrc --keepParent /tmp/vq-new/Build/Products/Debug/VoiceiQ.app /tmp/vq-feed/VoiceiQ-0.0.2.zip
$BIN/generate_appcast --account voiceiq --download-url-prefix http://127.0.0.1:8765/ /tmp/vq-feed
(cd /tmp/vq-feed && python3 -m http.server 8765 --bind 127.0.0.1) &
/tmp/vq-old/Build/Products/Debug/VoiceiQ.app/Contents/MacOS/VoiceiQ
```

Both copies must be signed by the same identity; `build.sh` uses your Apple
Development certificate when one is in the keychain. The old copy checks on
launch, downloads 0.0.2, and relaunches as 0.0.2. Clear `SULastCheckTime` in the
`io.blue.voiceiq.updatetest` defaults to check again at the next launch.

The test copy shares `~/Library/Application Support/VoiceiQ` with the real app
(the folder name does not follow the bundle ID), so it sees your History and
applies its own retention setting to it. Afterwards, remove the test copies
from Launch Services so `voiceiq://` links keep opening the real app:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u /tmp/vq-old/Build/Products/Debug/VoiceiQ.app
defaults delete io.blue.voiceiq.updatetest
```
