#!/usr/bin/env python3
"""Says which guests' beeps the owner's Chrome played: guestcheck.py WAV PITCH…

Each guest beeps at its own pitch for 2 s. A guest counts as heard when, in at
least MIN_FRAMES 0.1 s frames, its pitch is louder than LEVEL_DB and at least
MARGIN_DB above every other guest's pitch in the same frame. Loud broadband
sound (speech, a clipped neighbour, a UI chime) raises every pitch together,
so it cannot pass a silent guest, as the whole-file peak per band did (Neon
on #142). Prints one line per guest; exits with the number not heard.
"""
import math
import struct
import subprocess
import sys

# Pitches no guest beeps at, so even one guest must stand above something.
REFERENCES = [600, 900, 1600]  # also no guest pitch's 2nd or 3rd harmonic
RATE, FRAME = 8000, 800  # 0.1 s; pitches are multiples of 100 Hz, so each sits on a bin
LEVEL_DB, MARGIN_DB, MIN_FRAMES = -50.0, 15.0, 4


def level(frame, pitch):
    """Goertzel power at `pitch`, in dB relative to a full-scale sine."""
    coeff = 2 * math.cos(2 * math.pi * pitch / RATE)
    s1 = s2 = 0.0
    for x in frame:
        s1, s2 = x + coeff * s1 - s2, s1
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return 10 * math.log10(max(power, 1e-12) / (FRAME / 2) ** 2)


def main():
    wav, pitches = sys.argv[1], [int(p) for p in sys.argv[2:]]
    raw = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", wav, "-ac", "1", "-ar", str(RATE),
                          "-f", "s16le", "-"], check=True, capture_output=True).stdout
    samples = [s / 32768 for s in struct.unpack(f"<{len(raw) // 2}h", raw[: len(raw) // 2 * 2])]
    frames = [samples[i:i + FRAME] for i in range(0, len(samples) - FRAME + 1, FRAME)]
    levels = [[level(f, p) for p in pitches + REFERENCES] for f in frames]
    missing = 0
    for g, pitch in enumerate(pitches):
        clear = [row[g] - max((v for k, v in enumerate(row) if k != g), default=-120)
                 for row in levels if row[g] > LEVEL_DB]
        good = sum(m >= MARGIN_DB for m in clear)
        peak = max((row[g] for row in levels), default=-120)
        heard = good >= MIN_FRAMES
        missing += not heard
        print(f"Guest {g + 1} ({pitch} Hz): {peak:.0f} dBFS at the owner, {good} clear frames, "
              f"{'heard' if heard else 'NOT HEARD'}")
    sys.exit(missing)


main()
