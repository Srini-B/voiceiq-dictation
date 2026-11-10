# Agent rules

- Whenever the macOS application needs to be tested, test a signed and notarized build: produce it with the release flow (`scripts/release.sh`), install it, and test the installed app. Never test on a Debug build.
- Never turn off Wi-Fi or any other network interface on a test machine (the Mac mini runner, the MacBook, or any remote Mac), not even briefly to test offline behaviour. These machines are remote; one lost its only network link for hours until someone rebooted it by hand. Test offline paths by blocking only the app's requests, or skip the test and say so.
