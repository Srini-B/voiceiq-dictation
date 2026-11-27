#!/usr/bin/env python3
"""Runs upstream Hex's own offline meeting pass on prepared meetings.

Hex (github.com/anomalyco/hex, MIT) transcribes a recorded meeting from its two
WAV tracks with `hex meeting transcribe <id>`, a command of debug builds. This
script gives each meeting prepare.py wrote to that command unchanged: the mic
as Hex's microphone track, the far side as its system track. It then writes
the transcript in the format score.py reads. Hex names two speakers, the
microphone ("You", written here as the owner) and the system track ("Them").

Needs macOS, ffmpeg, and a debug build of Hex with its selected model and
speech detector installed:

  git clone https://github.com/anomalyco/hex && cd hex && cargo build
  HEX_APPLICATION_SUPPORT_DIR=~/hexdata ./target/debug/hex model install parakeet_unified_en

Usage: python3 hex_upstream.py HEX_BINARY HEX_SUPPORT_DIR DATA_DIR OUT_DIR [meeting-id ...]
"""
import json, os, shutil, struct, subprocess, sys, time


def wav(source, target):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", source, "-ac", "1", "-ar", "16000",
                    "-c:a", "pcm_f32le", target], check=True)
    # ffmpeg writes float WAV as WAVE_FORMAT_EXTENSIBLE, which the wave module refuses; the data chunk's size gives the frames.
    with open(target, "rb") as file:
        file.seek(12)
        while True:
            name, size = struct.unpack("<4sI", file.read(8))
            if name == b"data":
                return size // 4
            file.seek(size + size % 2, os.SEEK_CUR)


def main():
    binary, support, data, out = sys.argv[1:5]
    only = set(sys.argv[5:])
    os.makedirs(out, exist_ok=True)
    env = dict(os.environ, HEX_APPLICATION_SUPPORT_DIR=support)
    failed = []
    for name in sorted(os.listdir(data)):
        source = os.path.join(data, name)
        if name.startswith(".") or (only and name not in only) or not os.path.exists(os.path.join(source, "input.json")):
            continue
        # An earlier result goes first, so a failed rerun leaves nothing for compare.py to score.
        result = os.path.join(out, f"{name}.json")
        if os.path.exists(result):
            os.remove(result)
        try:
            run_one(binary, env, support, source, name, result)
        except Exception as error:  # one meeting's failure must not stop the others
            print(f"{name}: FAILED {error}", flush=True)
            failed.append(name)
    if failed:
        sys.exit(f"failed: {', '.join(failed)}")


def run_one(binary, env, support, source, name, result):
    owner = json.load(open(os.path.join(source, "input.json")))["owner"]
    meeting_id = f"{int(time.time() * 1000)}-{os.getpid()}"
    folder = os.path.join(support, "meetings", meeting_id)
    os.makedirs(folder)
    try:
        transcribe(binary, env, source, name, result, owner, meeting_id, folder)
    finally:
        shutil.rmtree(folder, ignore_errors=True)


def transcribe(binary, env, source, name, result, owner, meeting_id, folder):
    frames = {track: wav(os.path.join(source, caf), os.path.join(folder, f"{track}.wav"))
              for track, caf in (("microphone", "mic.caf"), ("system", "system.caf"))}
    track = lambda t: {"file": f"{t}.wav", "sample_rate": 16000, "first_pts_us": 0, "last_pts_us": None,
                       "first_arrival_us": 0, "samples": frames[t], "dropped_packets": 0}
    duration_ms = max(frames.values()) * 1000 // 16000
    json.dump({"schema_version": 1, "id": meeting_id, "title": name, "status": "complete",
               "created_at_ms": int(time.time() * 1000), "ended_at_ms": None, "duration_ms": duration_ms,
               "system": track("system"), "microphone": track("microphone"), "error": None},
              open(os.path.join(folder, "manifest.json"), "w"))
    started = time.time()
    run = subprocess.run([binary, "meeting", "transcribe", meeting_id], env=env, capture_output=True, text=True)
    seconds = time.time() - started
    if run.returncode:
        raise RuntimeError(run.stderr.strip()[-400:])
    manifest = json.load(open(os.path.join(folder, "manifest.json")))
    entries = [json.loads(line) for line in open(os.path.join(folder, "transcript.ndjson")) if line.strip()]
    segments = [{"start": e["start_ms"] / 1000, "end": e["end_ms"] / 1000,
                 "speaker_name": owner if e["source"] == "microphone" else "Them",
                 "speaker_id": "you" if e["source"] == "microphone" else "them", "text": e["text"]}
                for e in entries]
    json.dump({"id": name, "segments": segments,
               "participants": sorted({s["speaker_name"] for s in segments}), "notes": "",
               "seconds": {"transcribe": round(seconds, 1)}, "duration_seconds": duration_ms / 1000,
               "echo_suppressed_utterances": manifest.get("echo_suppressed_utterances", 0)},
              open(result, "w"), indent=1, ensure_ascii=False)
    print(f"{name}: {len(segments)} entries in {seconds:.1f}s, "
          f"{manifest.get('echo_suppressed_utterances', 0)} echo utterances dropped", flush=True)


if __name__ == "__main__":
    main()
