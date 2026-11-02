#!/bin/sh
# Prepares the work dir for convert_fluid_speech_pro.py: Python env, mobius wrappers, and the pinned model files.
set -eu
cd "$(dirname "$0")"
REV=53f490b9292c5943847f635b7abfc3f123018964
MOBIUS_REV=588b8e7077d454e9613bdb2672b89824c2f7095d

[ -d .venv ] || uv venv -p 3.11 .venv
VIRTUAL_ENV=.venv uv pip install -r requirements.txt

if [ ! -d mobius ]; then
    git clone https://github.com/FluidInference/mobius.git
fi
git -C mobius checkout -q "$MOBIUS_REV"

mkdir -p hf
curl -sfL -o hf/fluid_speech.py "https://huggingface.co/FluidVoice-Labs/fluid-speech-pro/resolve/$REV/fluid_speech.py"
[ "$(git hash-object hf/fluid_speech.py)" = e65ba9d64f912b73f793fd472b6128d17dd637f3 ]
[ -f hf/fluid-speech-pro.nemo ] || curl -sfL --retry 5 -o hf/fluid-speech-pro.nemo \
    "https://huggingface.co/FluidVoice-Labs/fluid-speech-pro/resolve/$REV/fluid-speech-pro.nemo"
echo "ready"
