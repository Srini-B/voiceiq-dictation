#!/usr/bin/env python3
"""Check a built app for accidental local-model/runtime payloads and report bytes.

Usage: python3 scripts/check-app-bundle.py /path/to/VoiceiQ.app
Run on the signed Mac app or an iOS device archive, not DerivedData as a whole.
"""

import json
from pathlib import Path
import plistlib
import subprocess
import sys


def main():
    app = Path(sys.argv[1]).resolve()
    mac = (app / "Contents/Info.plist").exists()
    info = app / ("Contents/Info.plist" if mac else "Info.plist")
    with info.open("rb") as handle:
        metadata = plistlib.load(handle)
    files = [path for path in app.rglob("*") if path.is_file() and not path.is_symlink()]
    forbidden = []
    for path in app.rglob("*"):
        if path.suffix in {".mlmodel", ".mlmodelc", ".mlpackage", ".onnx", ".safetensors", ".gguf", ".cact"}:
            forbidden.append(str(path.relative_to(app)))
        if path.name == "FluidAudio_FluidAudio.bundle" or path.name.startswith("ggml-"):
            forbidden.append(str(path.relative_to(app)))
    if forbidden:
        raise SystemExit(f"Unexpected bundled models or TTS resources: {forbidden}")

    executable = app / ("Contents/MacOS" if mac else "") / metadata["CFBundleExecutable"]
    # Device archives strip local symbols from the app but retain them in dSYMs.
    symbol_file = executable if mac else (
        app.parents[2] / "dSYMs" / f"{app.name}.dSYM"
        / "Contents/Resources/DWARF" / metadata["CFBundleExecutable"]
    )
    symbols = subprocess.run(["nm", str(symbol_file)], check=True, capture_output=True, text=True).stdout
    if mac:
        helper = app / "Contents/Helpers/VoiceiQLocalSpeech.app/Contents/MacOS/VoiceiQLocalSpeech"
        if "10FluidAudio" in symbols or "_nemo_normalize" in symbols:
            raise SystemExit("Mac UI still links the inference runtime")
        symbols = subprocess.run(["nm", str(helper)], check=True, capture_output=True, text=True).stdout
        if any(name in symbols for name in ["11VoiceIQCore", "GRDB"]):
            raise SystemExit("Speech helper still links app/database code")
        if "10FluidAudio" not in symbols:
            raise SystemExit("Speech helper lacks the expected inference runtime")
    elif "10FluidAudio" not in symbols:
        raise SystemExit("iOS app lacks the expected inference runtime")
    if "_nemo_normalize_sentence" not in symbols:
        raise SystemExit("Inference lacks the required English normalization runtime")

    print(json.dumps({
        "app": str(app),
        "platform": "macOS" if mac else "iOS/iPadOS",
        "version": metadata["CFBundleShortVersionString"],
        "build": metadata["CFBundleVersion"],
        "fileBytes": sum(path.stat().st_size for path in files),
        "executableBytes": executable.stat().st_size,
        "bundledModels": forbidden,
    }, indent=2))


if __name__ == "__main__":
    main()
