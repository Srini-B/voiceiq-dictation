# Cancel button on the macOS hands-free pill (2026-11-16)

**Why.** In the locked (hands-free) pill, Stop ends the dictation and inserts
the text, and the only way to throw a dictation away was ⌘Esc. A tester asked
for a Cancel button.

**What changed.**
- The locked pill shows a tonal ✕ Cancel button just left of Stop and is
  308pt wide (was 268). Cancel posts `.pillCancelTapped`, and
  `DictationController` sends `coordinator.handle(.cancel)`, the same intent
  ⌘Esc sends. Discarding works the same either way: short cancels leave no
  trace, and cancels of 10s or longer are kept in History with Retry
  (`DictationCoordinator.cancelKeepThreshold`). Neither inserts anything.
- Placement: on the right, beside Stop, not at the left edge. The left edge
  is the drag handle, and a missed drag must not discard a recording.
- Accessibility labels: "Cancel dictation without inserting text" and
  "Stop dictation and insert text". Help text: "Cancel without inserting
  (⌘Esc)" and "Stop and insert". macOS does not draw tooltips on the
  non-activating pill panel, so the help text reaches only VoiceOver and
  other accessibility clients.

**Verification.** On the Mac mini, `scripts/release.sh` exited 0: 183
VoiceIQCore tests passed, and the app and DMG were notarized and stapled.
The installed build was then tested. Clicking Cancel in a short session and
pressing ⌘Esc each returned the pill to rest. TextEdit and the clipboard
were unchanged, the recordings folder was unchanged, and no History row was
added. A 236s session cancelled with the button was kept in History as
Cancelled with nothing inserted. Stop still ended sessions normally. Not
pushed.
