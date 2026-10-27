# shellcheck shell=bash
# nixbook-voice-transcribe WAV [LANGUAGE] [MODEL]: what was said in a 16 kHz
# mono WAV, on one line, transcribed on this computer by whisper.cpp
# (Vulkan when there is a GPU, else the CPU): nothing leaves it. The voice
# input of Quick AI (services/Voice.qml). LANGUAGE: a two-letter code or
# auto (default); MODEL: small (default: right in French, Vietnamese,
# German as well as English) or base (twice as fast, English mostly).
# Nothing heard (silence, noise, music): an empty line.
#
# NIXBOOK_WHISPER_MODELS: the directory of ggml-<model>.bin files (set by
# the package).
set -euo pipefail

wav=${1:?usage: nixbook-voice-transcribe WAV [LANGUAGE] [MODEL]}
lang=${2:-auto}
model=${3:-small}
[[ $lang =~ ^([a-z]{2,3}|auto)$ ]] || lang=auto
[[ $model =~ ^[a-z0-9.-]+$ ]] || model=small
m="$NIXBOOK_WHISPER_MODELS/ggml-$model.bin"
[ -e "$m" ] || m="$NIXBOOK_WHISPER_MODELS/ggml-small.bin"

# Silero VAD: only speech is transcribed (noise alone gives nothing, where
# whisper would make words up); without its model, the whole file.
vad=()
[ -e "$NIXBOOK_WHISPER_MODELS/ggml-silero-vad.bin" ] && vad=(--vad -vm "$NIXBOOK_WHISPER_MODELS/ggml-silero-vad.bin")

# -nt: no timestamps, -np: only the text. Whisper's markers for what isn't
# speech ([BLANK_AUDIO], (music), *sighs*) dropped; lines joined.
whisper-cli -m "$m" -f "$wav" -l "$lang" -nt -np "${vad[@]}" 2>/dev/null |
  sed -E 's/\[[^]]*\]//g; s/\([^)]*\)//g; s/\*[^*]*\*//g' |
  tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
echo
