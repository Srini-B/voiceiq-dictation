# Call detection without a live mic

**2026-11-28.** In the live-call probe's rerun (thread T-01a22123), the owner's
Chrome held no microphone, and `CallDetector` required every call
app to be capturing it, so the app offered nothing. In a real call, an owner
who joins muted can be in the same state. Rule 3 now accepts a browser that only
plays sound when its front window shows a joined call room
(`CallApps.callRooms`, matched by address or title, such as a Meet code, not
the Meet home page). Chat sites such as WhatsApp Web, Telegram Web,
Messenger, Teams and Discord still need the mic: they play voice messages
and videos. The browser's sound can't be pinned to a tab, so a room in a back
window doesn't count either. Codex raised both points on #138.

Known native apps still need the mic. Slack, Teams and others play
notification sounds, so output alone would raise false offers. Look-alike
tabs (rule 4) still need two-way audio.

The page read now also runs for browsers that only play, such as YouTube. It
takes at most 0.5 s per browser per 5 s poll, off the main actor.

A recording that has started already watches the call's output to find its
end (`CallProcesses.isRunningAudio`), so a muted call keeps recording.
