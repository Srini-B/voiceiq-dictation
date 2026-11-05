# Return URL table synced with Dictus and VivaDicta (2026-11-05)

**Why.** The iPhone app returns the user to the app they were dictating into
through `KnownAppSchemes` when the private launch fails. The table was adapted
from Dictus in September and had fallen behind: Dictus re-tested Claude on
2026-10-01 and found `claude://` opens a new chat, and VivaDicta, which
Dictus's table is ported from, added weekly batches through 2026-10-31. Our
notices did not credit VivaDicta.

**What changed.**
- `KnownAppSchemes.swift`: 102 → 197 return URLs, 31 → 134 hosts with no way
  back. Taken from Dictus develop `ed605740` (its tiers and notes) and
  VivaDicta `92e2416c` (additions after Dictus's sync point `fac75995`).
- Claude and Orca moved to the hosts with no way back: their only URL lands on
  a new chat or the home screen, so the swipe-back screen, which leaves the app
  where it was, is better.
- Google Maps now uses `comgooglemaps://` (Google's documented scheme). TikTok,
  Google Drive and Walmart use the universal links upstream confirmed in their
  AASA files. The six Typeless-only entries neither upstream lists stay.
- `THIRD_PARTY_NOTICES.md`: VivaDicta MIT notice.

**Verified.** The file compiles; a scratch check confirmed every value parses
as a URL, no bundle ID is in both lists, Messages still uses `ichat://`, and
Claude and Orca return nil and are not reported as gaps. None of the new
entries was tested on a device. A URL iOS cannot open falls back to the
swipe-back screen (an `https` one too, since it opens only as a universal
link); a URL that opens the app on the wrong screen does not, because the
return counts as done once iOS opens it.

**Rollback.** Revert the commit.
