# Call detection without a live mic

**2026-11-28.** In the live-call probe's rerun (thread T-01a22123), the owner's
Chrome held no microphone, and `CallDetector` required every call
app to be capturing it, so the app offered nothing. In a real call, an owner
who joins muted can be in the same state. Rule 3 now accepts a browser that only
plays sound when its front page is a joined call room
(`CallApps.isCallRoom`, such as a Meet code, not the Meet home page). It
matches by address, and by title only when no address can be read, because
any video can be titled "Zoom Meeting". Chat sites such as WhatsApp Web, Telegram Web,
Messenger, Teams and Discord still need the mic: they play voice messages
and videos. The browser's sound can't be pinned to a tab, so a room in a back
window doesn't count either. Codex raised both points on #138.

Known native apps still need the mic. Slack, Teams and others play
notification sounds, so output alone would raise false offers. Look-alike
tabs (rule 4) still need two-way audio.

The page read now also runs for browsers that only play, such as YouTube.
For those it reads only the front page (`BrowserPages.read(frontOnly:)`),
and it runs off the main actor. Each AX call is capped at 0.5 s.

A recording that has started already watches the call's output to find its
end (`CallProcesses.isRunningAudio`), so a muted call keeps recording. The
offer itself also stays for a muted owner who switches tabs, as long as the
browser plays and any window shows the meeting page. Before this, three
missed polls (15 s) dropped it.

Known limit: a browser's sound can't be traced to a tab. So a joined room in
front, plus a video in another tab of the same browser, still raises an
offer. × keeps it quiet for 30 minutes.
