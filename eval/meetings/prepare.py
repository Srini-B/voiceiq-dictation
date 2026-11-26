#!/usr/bin/env python3
"""Builds the meetings the evaluator runs, as VoiceiQ records them.

Each meeting becomes a folder with the two tracks a Mac call recording has:
mic.caf (the note owner) and system.caf (everyone else), 16 kHz mono, plus
input.json (what the app would know: owner, calendar, call app, the call
window's names) and reference.json (who said what, for scoring).

  AMI:        the four headsets of an AMI meeting (CC BY 4.0), downloaded here.
              The speaker who talks most is the owner; the other three are
              summed as the far side.
  Synthetic:  scripts/*.json read by macOS voices (`say`), one voice per
              person, with names said, decisions and action items.
  Echo:       a copy of each synthetic meeting whose mic also hears the far
              side through the speakers (delayed, quieter), so the pipeline
              takes its echo path.

Needs macOS (say, afconvert), ffmpeg and python3; no API keys.
Usage: python3 prepare.py OUT_DIR [--ami ES2004a ...] [--no-synthetic]
"""
import argparse, array, html, json, os, re, shutil, subprocess, sys, tempfile, urllib.request, wave, zipfile

RATE = 16000
HERE = os.path.dirname(os.path.abspath(__file__))
AMI_AUDIO = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{m}/audio/{m}.Headset-{c}.wav"
AMI_NOTES = "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip"


def run(*cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def fetch(url, path):
    if os.path.exists(path):
        return
    for attempt in range(5):
        try:
            urllib.request.urlretrieve(url, path + ".part")
            os.replace(path + ".part", path)
            return
        except Exception as error:  # the AMI mirror returns 503 under load
            if attempt == 4:
                raise SystemExit(f"download failed: {url}: {error}")


def read_pcm(path):
    """Any audio file as 16 kHz mono int16 samples."""
    out = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"],
                         check=True, capture_output=True).stdout
    samples = array.array("h"); samples.frombytes(out)
    return samples


def write_caf(samples, path):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        with wave.open(tmp.name, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(samples.tobytes())
        run("afconvert", "-f", "caff", "-d", f"LEI16@{RATE}", tmp.name, path)
    os.unlink(tmp.name)


def mix(tracks, gains=None):
    length = max(len(t) for t in tracks)
    out = array.array("h", bytes(2 * length))
    gains = gains or [1.0] * len(tracks)
    for track, gain in zip(tracks, gains):
        for i, value in enumerate(track):
            if value:
                out[i] = max(-32768, min(32767, int(out[i] + gain * value)))
    return out


def delayed(samples, seconds, gain):
    shift = int(seconds * RATE)
    out = array.array("h", bytes(2 * shift)); out.extend(samples)
    return array.array("h", (int(v * gain) for v in out))


def write_json(path, value):
    with open(path, "w") as f:
        json.dump(value, f, indent=1, ensure_ascii=False)


# AMI ---------------------------------------------------------------------

def ami(meeting, out, cache):
    os.makedirs(cache, exist_ok=True)
    notes = os.path.join(cache, "ami_public_manual_1.6.2.zip")
    fetch(AMI_NOTES, notes)
    with zipfile.ZipFile(notes) as z:
        agents = {}
        for line in z.read("corpusResources/meetings.xml").decode().splitlines():
            m = re.search(rf'nite:id="{meeting}_\d+" channel="(\d)" nxt_agent="([A-D])"', line)
            if m:
                agents[m.group(2)] = int(m.group(1))
        words = {}
        for agent in agents:
            xml = z.read(f"words/{meeting}.{agent}.words.xml").decode()
            # Some words carry no times; they cannot be placed, so they are left out.
            words[agent] = [(float(s.group(1)), float(e.group(1)), html.unescape(text))
                            for attrs, text in re.findall(r"<w ([^>]*)>([^<]*)</w>", xml)
                            if 'punc="true"' not in attrs
                            for s, e in [(re.search(r'starttime="([\d.]+)"', attrs), re.search(r'endtime="([\d.]+)"', attrs))]
                            if s and e]
        summary = ""
        name = f"abstractive/{meeting}.abssumm.xml"
        if name in z.namelist():
            xml = z.read(name).decode("latin-1")
            parts = [(kind.capitalize(), [re.sub(r"\s+", " ", html.unescape(t)).strip() for t in re.findall(r"<sentence[^>]*>([^<]*)</sentence>", body)])
                     for kind, body in re.findall(r"<(abstract|actions|decisions|problems)\b[^>]*>(.*?)</\1>", xml, re.S)]
            summary = "\n\n".join(f"{kind}:\n" + "\n".join(f"- {t}" for t in lines) for kind, lines in parts if lines)
    tracks = {}
    for agent, channel in agents.items():
        path = os.path.join(cache, f"{meeting}.Headset-{channel}.wav")
        fetch(AMI_AUDIO.format(m=meeting, c=channel), path)
        tracks[agent] = read_pcm(path)
    owner = max(words, key=lambda a: len(words[a]))
    folder = os.path.join(out, f"ami-{meeting}")
    os.makedirs(folder, exist_ok=True)
    write_caf(tracks[owner], os.path.join(folder, "mic.caf"))
    write_caf(mix([tracks[a] for a in sorted(tracks) if a != owner]), os.path.join(folder, "system.caf"))
    names = {a: f"Speaker {a}" for a in agents}
    write_json(os.path.join(folder, "input.json"), {
        "id": f"ami-{meeting}", "title": None, "app": "us.zoom.xos", "owner": names[owner],
        "calendar": [], "screen": None, "mic_is": names[owner]})
    write_json(os.path.join(folder, "reference.json"), {
        "id": f"ami-{meeting}", "source": "AMI Meeting Corpus (CC BY 4.0)", "owner": names[owner],
        # AMI speakers are anonymous: the scorer matches them by overlap, not by name.
        "participants": None,
        "segments": ami_segments(words, names),
        "summary": summary})


def ami_segments(words, names):
    flat = sorted((s, e, a, t) for a, ws in words.items() for s, e, t in ws)
    segments = []
    for s, e, agent, text in flat:
        last = segments[-1] if segments else None
        if last and last["speaker"] == names[agent] and s - last["end"] < 1.0:
            last["end"] = max(last["end"], e); last["text"] += " " + text
        else:
            segments.append({"start": s, "end": e, "speaker": names[agent], "text": text})
    return segments


# Synthetic -----------------------------------------------------------------

def synthetic(script_path, out, echo):
    script = json.load(open(script_path))
    voices = {p["name"]: p["voice"] for p in script["participants"]}
    owner = script["owner"]
    length = 0
    clips, segments = [], []
    t = 0.5
    with tempfile.TemporaryDirectory() as tmp:
        for index, (speaker, text) in enumerate(script["turns"]):
            path = os.path.join(tmp, f"{index}.wav")
            run("say", "-v", voices[speaker], "-o", path, "--file-format=WAVE", f"--data-format=LEI16@{RATE}", text)
            samples = read_pcm(path)
            clips.append((speaker, t, samples))
            segments.append({"start": round(t, 2), "end": round(t + len(samples) / RATE, 2), "speaker": speaker, "text": text})
            t += len(samples) / RATE + 0.6
        length = int((t + 1) * RATE)
    mic = array.array("h", bytes(2 * length)); system = array.array("h", bytes(2 * length))
    for speaker, start, samples in clips:
        target = mic if speaker == owner else system
        at = int(start * RATE)
        target[at:at + len(samples)] = samples
    suffix = "-echo" if echo else ""
    folder = os.path.join(out, script["id"] + suffix)
    os.makedirs(folder, exist_ok=True)
    if echo:
        # Laptop speakers into the laptop mic: the far side 60 ms late at a third of its level.
        mic = mix([mic, delayed(system, 0.06, 0.33)])
    write_caf(mic, os.path.join(folder, "mic.caf"))
    write_caf(system, os.path.join(folder, "system.caf"))
    names = [p["name"] for p in script["participants"]]
    write_json(os.path.join(folder, "input.json"), {
        "id": script["id"] + suffix, "title": script["title"], "app": script["app"], "owner": owner,
        "calendar": script["calendar"], "screen": script["screen"], "people": names, "mic_is": owner})
    write_json(os.path.join(folder, "reference.json"), {
        "id": script["id"] + suffix, "source": "synthetic (macOS voices)", "owner": owner, "participants": names,
        "segments": segments, "decisions": script["decisions"], "actions": script["actions"],
        "summary": "Script (every line said in the meeting):\n" + "\n".join(f"{who}: {line}" for who, line in script["turns"])
                   + "\n\nDecisions:\n" + "\n".join(f"- {d}" for d in script["decisions"]) + "\n\nAction items:\n"
                   + "\n".join(f"- {a['owner']}: {a['text']}" + (f" (by {a['due']})" if a.get("due") else "") for a in script["actions"])})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--ami", nargs="*", default=["ES2004a"])
    parser.add_argument("--no-synthetic", action="store_true")
    args = parser.parse_args()
    for tool in ("ffmpeg", "afconvert"):
        if not shutil.which(tool):
            raise SystemExit(f"{tool} not found")
    os.makedirs(args.out, exist_ok=True)
    cache = os.path.join(args.out, ".cache")
    for meeting in args.ami:
        if os.path.exists(os.path.join(args.out, f"ami-{meeting}", "reference.json")):
            continue
        print("AMI", meeting, flush=True)
        ami(meeting, args.out, cache)
    if not args.no_synthetic:
        for name in sorted(os.listdir(os.path.join(HERE, "scripts"))):
            for echo in (False, True):
                print("synthetic", name, "echo" if echo else "", flush=True)
                synthetic(os.path.join(HERE, "scripts", name), args.out, echo)


if __name__ == "__main__":
    main()
