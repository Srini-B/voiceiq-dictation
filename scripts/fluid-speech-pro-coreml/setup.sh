#!/bin/sh
# Prepares the work dir for convert_fluid_speech_pro.py: Python env, mobius wrappers, and the pinned model files.
set -eu
cd "$(dirname "$0")"
REV=36481f6c9d353a301df1524dd0124eaf9212713e
NEMO_SHA256=f3e377b792ae5a52a3c071adb7eba5504306f2f4bdcf933ae9da2cbcab6f0449
MOBIUS_REV=588b8e7077d454e9613bdb2672b89824c2f7095d

[ -d .venv ] || uv venv -p 3.11 .venv
VIRTUAL_ENV=.venv uv pip install -r requirements.txt

if [ ! -d mobius ]; then
    git clone https://github.com/FluidInference/mobius.git
fi
git -C mobius checkout -q "$MOBIUS_REV"

mkdir -p hf
curl -fsSL -o hf/fluid_speech.py "https://huggingface.co/FluidVoice-Labs/fluid-speech-pro/resolve/$REV/fluid_speech.py"
if [ "$(git hash-object hf/fluid_speech.py)" != 2de08614b7eecd22792cd23a2a7e882c4ffe3b41 ]; then
    echo "hf/fluid_speech.py does not match the pinned digest" >&2
    exit 1
fi
if [ ! -f hf/fluid-speech-pro.nemo ] || [ "$(shasum -a 256 hf/fluid-speech-pro.nemo | cut -d' ' -f1)" != "$NEMO_SHA256" ]; then
    curl -fsSL --retry 5 -o hf/fluid-speech-pro.nemo.part \
        "https://huggingface.co/FluidVoice-Labs/fluid-speech-pro/resolve/$REV/fluid-speech-pro.nemo"
    mv hf/fluid-speech-pro.nemo.part hf/fluid-speech-pro.nemo
fi
echo "ready"
