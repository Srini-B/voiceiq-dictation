# Releasing VoiceiQ

VoiceiQ ships two apps from one project, built on the same `VoiceIQCore`
package, with one version number. Releases normally run in GitHub Actions:
pushing a new `MARKETING_VERSION` to `main` builds and ships both apps. That
flow, its secrets and the Mac auto-update are in [UPDATES.md](UPDATES.md). This
page covers the scripts it runs, which also work on a release Mac:

| | macOS | iPhone |
| --- | --- | --- |
| Script | `scripts/release.sh` | `scripts/release-ios.sh` |
| Channel | Notarized DMG and ZIP on GitHub Releases, with Sparkle auto-update | TestFlight |

Both scripts follow the same flow and stop at the first failure:

```text
preflight (tools, identity, credentials)
  → scripts/test.sh (VoiceIQCore)
  → xcodegen generate
  → Release build or archive, manual signing
  → verify signature and entitlements
  → publish (notarize + DMG, or upload to TestFlight)
```

`SKIP_TESTS=1` skips the test step when it has just been run.

## Before any release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
   They are set once, under `settings`, for all four targets. The build
   number must be higher than every build already on TestFlight or GitHub.
2. Confirm `./scripts/build.sh` and `./scripts/build-ios.sh` pass.
3. Confirm the production models are available with a real dictation on both
   providers (Gemini and OpenAI).

Parakeet and Nemotron use the pinned FluidAudio Swift package through the
`VoiceIQInference` target. Build with Swift 6.2+ for package traits.
`VoiceIQCore/Package.swift` enables FluidAudio's `NemoTextProcessing` trait,
which links the prebuilt `text-processing-rs` v0.3.1 inverse text
normalization library used for local English transcripts. It holds compiled
NeMo grammars, not neural weights, and is unrelated to the Nemotron ASR model.
The Mac UI links only `VoiceIQCore`; the Mac helper and iOS app link inference. The keyboard and Live Activity
continue to link only `VoiceIQBridge`.
`VoiceIQSpeech` holds the shared model identifiers, session contract, and Mac
pipe messages. The inference target depends on this contract rather than Core,
so the helper does not carry the app's database or cloud-provider code.

`scripts/trim-inference-resources.py` runs before helper/iOS app signing. It
removes FluidAudio 0.17.7's unused LuxTTS resource bundle and fails on unfamiliar
resource files so dependency upgrades require an explicit review. ASR uses
downloaded model directories, not these resources. Do not add TTS functionality
without restoring its resources.

Model weights, including the optional English tools pack, are downloaded only
from Settings, not during build or app launch.
Both release scripts run `scripts/check-app-bundle.py` to reject bundled model
weights, unused TTS resources, and accidental runtime dependencies. It fails if
the Mac UI links FluidAudio or the normalizer, if the helper links app or
database code, or if the inference binary (Mac helper or iOS app) lacks
`_nemo_normalize_sentence`. To check an
existing build, pass the Mac app path or the app inside an iOS device archive:

```bash
python3 scripts/check-app-bundle.py build/release/DerivedData/Build/Products/Release/VoiceiQ.app
python3 scripts/check-app-bundle.py build/ios/VoiceiQ.xcarchive/Products/Applications/VoiceiQ.app
```

Keep the iOS archive's dSYMs for this check because its app executable is stripped.
See
[local transcription](LOCAL_TRANSCRIPTION.md) for download and fallback checks.
When local speech changes, also download and delete English tools, and dictate
with each model both with and without the pack on the installed notarized build.
The macOS target embeds `Contents/Helpers/VoiceiQLocalSpeech.app`. Xcode signs
this background app with the same Developer ID and hardened runtime; the host's
notarization submission includes it. Verify the nested signature with
`codesign --verify --deep --strict VoiceiQ.app` and exercise its 60-second idle
exit from an installed, notarized build. Do not distribute the helper separately.

## macOS

`scripts/release.sh` produces a Developer ID signed, notarized, and stapled app
and DMG. It stops on any signing, entitlement, notarization, or Gatekeeper
failure.

### Prerequisites

A keychain must contain this identity:

```text
Developer ID Application: Blue Lobster Technology PTE. LTD (G8K3545FJ2)
```

The MacBook has it in the login keychain. Any other Mac (the Mac mini) gets a
copy of the same identity, not a new certificate: the API key cannot create
Developer ID certificates (Apple allows that only to the Account Holder), and
the Developer ID profile names this certificate. To set up another Mac:

1. On the MacBook, in Keychain Access › login › My Certificates, select
   "Developer ID Application: …", File › Export Items…, save as `.p12` with a
   password. macOS asks for the login password; it cannot be done over SSH.
2. Copy the `.p12` to the other Mac and run:

   ```bash
   P12=~/DeveloperID.p12 P12_PASSWORD='…' scripts/setup-mac-signing.sh
   ```

   It imports the identity into `~/Library/Keychains/voiceiq-signing.keychain-db`
   (the release keychain, unlocked by the release scripts with
   `~/.voiceiq-signing/keychain.pass`, so signing works from SSH), installs the
   Developer ID profile with asc, and checks the notarization variables. Delete
   the `.p12` afterwards. Run it without `P12` any time to see what is missing.

It also needs the Developer ID provisioning profile "VoiceiQ macOS Developer ID"
in `~/Library/Developer/Xcode/UserData/Provisioning Profiles`. Release builds
carry the iCloud key-value storage entitlement (dictionary sync,
`App/VoiceIQ-Release.entitlements`), which macOS allows only with a profile;
without it the build fails at signing. Debug builds are ad-hoc and have no
iCloud. The profile is for App ID `io.blue.voiceiq` with the iCloud capability:

```bash
asc --profile voiceiq profiles list --profile-type MAC_APP_DIRECT
asc --profile voiceiq profiles download --id PROFILE_ID --output VoiceiQ-macOS.provisionprofile
```

Name the installed file `<UUID>.provisionprofile` (the UUID inside the profile).

The shell must export these values before the script starts:

```bash
export APPLE_ID=...
export APPLE_APP_SPECIFIC_PASSWORD=...
export APPLE_TEAM_ID=...
```

The values are stored in `~/.zshrc` on the release machine. Source that file in the calling shell. The script checks that all three variables exist and never prints them.

### Build a release

```bash
source ~/.zshrc
./scripts/release.sh
```

The script performs this sequence:

1. Runs the `VoiceIQCore` tests.
2. Regenerates `VoiceIQ.xcodeproj` with XcodeGen.
3. Builds Release with manual Developer ID signing, hardened runtime, and a secure timestamp.
4. Verifies the app signature and rejects `get-task-allow`.
5. Creates a ZIP with `ditto` and submits it to Apple notarization.
6. Staples the app, checks it with Gatekeeper, and re-creates
   `build/release/VoiceiQ-<version>.zip` from the stapled app.
7. Builds `build/release/VoiceiQ-<version>.dmg` with `scripts/make-dmg.sh`.
8. Signs, notarizes, staples, and Gatekeeper-checks the DMG.

Step 4 also checks that Sparkle's `Autoupdate`, `Updater.app` and framework
carry the Developer ID team; the "Sign Sparkle helpers" build phase signs them.

Both `VoiceiQ-<version>.zip` and `VoiceiQ-<version>.dmg` are shareable as they
are: the app inside each carries a stapled notarization ticket, so testers can
open it after the usual first-launch confirmation without an internet check.

The bundle identifier is `io.blue.voiceiq`. Changing it resets the app's UserDefaults domain and requires users to grant microphone, Accessibility, and other TCC permissions again. `FileLayout` and `KeychainStore` migrate the previous VoiceiQ folder and API-key service, but macOS permissions cannot be migrated.

If the log shows "Finder scripting unavailable — DMG still works, layout will
be default", Finder did not answer the layout script in time (seen once on the
Mac mini, AppleEvent -1712). The DMG works but opens without the designed
window. Rebuild it from the stapled app, then sign, notarize and staple it as
`release.sh` does:

```bash
APP=build/release/DerivedData/Build/Products/Release/VoiceiQ.app
APP_NAME=VoiceiQ scripts/make-dmg.sh "$APP" build/release/VoiceiQ-<version>.dmg
```

### Verification

Inspect an existing release without submitting another notarization job:

```bash
codesign -dvv "build/release/DerivedData/Build/Products/Release/VoiceiQ.app"
codesign -d --entitlements :- "build/release/DerivedData/Build/Products/Release/VoiceiQ.app"
spctl -a -t exec -vv "build/release/DerivedData/Build/Products/Release/VoiceiQ.app"
xcrun stapler validate "build/release/VoiceiQ-<version>.dmg"
spctl -a -t open --context context:primary-signature -vv "build/release/VoiceiQ-<version>.dmg"
```

Do not distribute an artifact if any command fails. There is no unsigned or unnotarized fallback.

### Every macOS release

1. Complete the product reliability checklist in `docs/design/product-reliability.md`.
2. Smoke-test onboarding, API-key storage, permissions, dictation, history, and the DMG install flow on a clean macOS account.
3. Push the version change; the release workflow publishes the GitHub
   release with the ZIP, DMG and Sparkle appcast. By hand:
   `scripts/publish-github-release.sh` (dry run first with `DRY_RUN=1`). See
   [UPDATES.md](UPDATES.md).

Notarization uses the App Store Connect API key when `ASC_KEY_ID`,
`ASC_ISSUER_ID` and `ASC_PRIVATE_KEY_PATH` are set (CI), otherwise the
`APPLE_ID` variables.

## iPhone (TestFlight)

`scripts/release-ios.sh` archives the `VoiceIQiOS` scheme, signs the app and
both extensions for the App Store, uploads the build, and waits until App Store
Connect has processed it. The internal group "VoiceiQ Internal" has automatic
distribution, so a processed build reaches its testers without another step.

```bash
./scripts/release-ios.sh                 # upload with asc (default)
UPLOAD=xcode ./scripts/release-ios.sh    # upload with Xcode's signed-in account
UPLOAD=none ./scripts/release-ios.sh     # everything except the upload
TEST_NOTES_FILE=notes.txt ./scripts/release-ios.sh   # set TestFlight What to Test
```

asc signs in with the `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_PRIVATE_KEY_*`
variables when they are set (CI), otherwise with the stored profile `voiceiq`.

The script performs this sequence:

1. Checks xcodegen, the Apple Distribution identity, the three App Store
   profiles and, for `UPLOAD=asc`, that the asc profile can see the app.
2. Runs the `VoiceIQCore` tests.
3. Uses `CURRENT_PROJECT_VERSION` as the build number, the same as the Mac
   app's, and stops if TestFlight already has that build.
4. Runs `scripts/archive-ios.sh`, which regenerates the project, archives
   Release to `build/ios/VoiceiQ.xcarchive` and exports
   `build/ios/export/VoiceiQ.ipa`.
5. Verifies every bundle's signature, checks for the shared App Group, and
   rejects `get-task-allow`.
6. Uploads with `asc publish testflight --upload-only --wait` and lists the
   TestFlight groups, then sets What to Test from `TEST_NOTES_FILE`. With
   `UPLOAD=xcode` it runs `xcodebuild -exportArchive` with the `upload`
   destination instead.

### One-time setup on a release Mac

**Signing.** The team's Apple Distribution identity must be in a keychain,
and the three App Store profiles named in `project.yml`
(`PROVISIONING_PROFILE_SPECIFIER`) must be installed in
`~/Library/Developer/Xcode/UserData/Provisioning Profiles`.

On the Mac mini the key lives in `~/Library/Keychains/voiceiq-signing.keychain-db`,
which the script unlocks with `~/.voiceiq-signing/keychain.pass`. With an asc
key the profiles can be recreated from the terminal:

```bash
asc --profile voiceiq profiles list --profile-type IOS_APP_STORE
asc --profile voiceiq profiles download --id PROFILE_ID --output profile.mobileprovision
```

A profile lists the capabilities its App ID had when it was made. After a
capability is added (iCloud on `io.blue.voiceiq.ios` on 2026-09-28), delete the
profile and create it again with the same name, then install the new file and
remove the old one:

```bash
asc --profile voiceiq profiles delete --id OLD_PROFILE_ID --confirm
asc --profile voiceiq profiles create --name "VoiceiQ iOS App Store" --profile-type IOS_APP_STORE \
  --bundle BUNDLE_ID_RESOURCE_ID --certificate APPLE_DISTRIBUTION_CERT_ID
```

**asc (App Store Connect CLI, https://asccli.sh).** Uploads, build numbers
and TestFlight go through asc with the App Store Connect team API key
"VoiceiQ release" (App Manager role). On the Mac mini it is set up already:

| Item | Location |
| --- | --- |
| asc | `brew install asc` (`/opt/homebrew/bin/asc`), telemetry disabled |
| Private key | `~/.asc/keys/AuthKey_<KEY_ID>.p8` (0600) |
| asc profile `voiceiq` | `~/.asc/config.json` (0600). The login keychain cannot be written from SSH or agent sessions, so asc keeps it in its config file. |

Check it with `asc --profile voiceiq apps view --id APP_ID`, where `APP_ID` is
the value in `scripts/release-ios.sh`. To set up
another Mac, download a Team Key (App Store Connect → Users and Access →
Integrations → App Store Connect API → Team Keys, App Manager role; the `.p8`
downloads only once) and run:

```bash
KEY_FILE=~/Downloads/AuthKey_XXXXXXXXXX.p8 ISSUER_ID=<issuer ID above the Team Keys table> ./scripts/setup-asc.sh
```

`setup-asc.sh` can also create the key itself through an Apple web session
(`APPLE_ID=… ./scripts/setup-asc.sh`, prompts for the password and a
two-factor code). If a key leaks, revoke it on the same page.

Exporting an App Store IPA reserves its build number in App Store Connect
("awaiting upload"). `release-ios.sh` deletes that reservation before it
uploads and after a dry run, so it does not block the number.

**Xcode fallback.** Without an asc key, `UPLOAD=xcode` uploads through the
Apple Account signed in to Xcode (Settings → Accounts). Run it from the
logged-in desktop session, not a plain SSH shell, because signing needs the
unlocked login keychain.

### What asc can and cannot do with the API key

With the key: builds and uploads, build numbers, TestFlight groups and
testers, bundle IDs and their capabilities, certificates, and provisioning
profiles (`asc --profile voiceiq profiles list --profile-type IOS_APP_STORE`).

The public API does not create App Groups, assign them to bundle IDs, or
create app records. For those, asc needs an Apple web session
(`asc web auth login`: password and two-factor code), which expires, so they
stay out of the release script:

```bash
asc web app-groups create --name "<name>" --identifier <app group> --confirm
asc web apps create --name "<app name>" --bundle-id <app bundle id> --sku <sku>
```

The first release was set up in the Developer portal by hand; what the team
needs is listed in [IOS.md](IOS.md#apple-developer-setup).

### Every iPhone release

1. Install the TestFlight build on a physical iPhone. Add the keyboard, allow
   Full Access, dictate in two apps (the second without a bounce), end the
   session from the Dynamic Island, and record a short meeting.
2. External testers need Beta App Review: create an external group and run
   `asc publish testflight --app APP_ID --build-id BUILD_ID --group "<group>" --submit --confirm`.
