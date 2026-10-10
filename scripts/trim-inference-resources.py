#!/usr/bin/env python3
"""Remove FluidAudio 0.17.7's TTS-only resources before app signing.

Parakeet and Nemotron load their assets from the user's model directory.
Neither uses Bundle.module. Fail on unfamiliar resources so an SDK upgrade
cannot silently remove a new ASR dependency.
"""

import os
from pathlib import Path
import shutil


def main():
    bundle = (
        Path(os.environ["TARGET_BUILD_DIR"])
        / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
        / "FluidAudio_FluidAudio.bundle"
    )
    if not bundle.exists():
        return
    allowed = {"Info.plist", "luxtts_en_us_lexicon.tsv.zz", "luxtts_en_us_g2p_aux.json"}
    unexpected = [
        str(path.relative_to(bundle))
        for path in bundle.rglob("*")
        if path.is_file()
        and "_CodeSignature" not in path.relative_to(bundle).parts
        and path.name not in allowed
    ]
    if unexpected:
        raise SystemExit(f"Review new FluidAudio resources before trimming: {unexpected}")
    shutil.rmtree(bundle)
    print("Removed unused FluidAudio TTS resource bundle")


if __name__ == "__main__":
    main()
