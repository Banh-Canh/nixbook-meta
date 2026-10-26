"""nixbook-voice-speak: the desktop agent's answers read out loud
(services/Voice.qml, ai.voice.speak). Meta's Model API has no speech
synthesis, so it is Piper, on this computer: a small neural voice per
language (English, French, German, Vietnamese; NIXBOOK_PIPER_VOICES, a
folder of <lang>.onnx + <lang>.onnx.json), streamed to the speakers with
pacat while it is synthesised (the first words in about a second).

  nixbook-voice-speak [--lang auto|en|fr|de|vi] [--file WAV] TEXT…

The text is made speakable first (no Markdown, code, links, emoji, ticks).
SIGTERM / SIGINT stop it at once (the key, Escape). --file writes a WAV
instead of playing (tests).
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys

VOICES = os.environ.get("NIXBOOK_PIPER_VOICES", "")
LANGS = ("en", "fr", "de", "vi")
MAX_CHARS = 900

FR = re.compile(r"\b(le|la|les|des|est|une|pas|vous|tu|je|il|elle|avec|pour|dans|sur|c'est|ce|cette|sont|ont|aux|du|au|et)\b", re.I)
DE = re.compile(r"\b(der|die|das|und|ist|nicht|ich|du|mit|für|auf|ein|eine|sind|wir|sie|es|auch|dem|den)\b", re.I)
EN = re.compile(r"\b(the|is|are|and|you|your|to|of|in|it|on|with|for|this|that|have|has|was)\b", re.I)
VI = re.compile(r"[ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]", re.I)


def language(text):
    """en, fr, de or vi from the words used (a voice per answer)."""
    if len(VI.findall(text)) >= 3:
        return "vi"
    scores = {"fr": len(FR.findall(text)) + 2 * len(re.findall(r"[éèêàçùœ]", text)),
              "de": len(DE.findall(text)) + 2 * len(re.findall(r"[äöüß]", text)),
              "en": len(EN.findall(text))}
    best = max(scores, key=scores.get)
    return best if scores[best] > 0 else "en"


def speakable(text):
    s = str(text)
    s = re.sub(r"```.*?```", " ", s, flags=re.S)
    s = re.sub(r"<think>.*?(</think>|$)", " ", s, flags=re.S)
    s = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", s)
    s = re.sub(r"https?://\S+", "", s)
    s = re.sub(r"[`*_#>|~]", "", s)
    s = re.sub(r"^\s*[-•]\s+", "", s, flags=re.M)
    s = re.sub(r"[✓✗→⚠⟦⟧]", "", s)
    # Emoji and other pictographs: not words.
    s = re.sub(r"[\U0001F000-\U0001FFFF☀-➿️]", "", s)
    s = re.sub(r"[ \t]+", " ", s)
    s = re.sub(r"\n{2,}", "\n", s).strip()
    if len(s) > MAX_CHARS:
        cut = s.rfind(".", 0, MAX_CHARS)
        s = s[:cut + 1 if cut > MAX_CHARS // 2 else MAX_CHARS]
    return s


def main(argv):
    lang, out_file, words = "auto", None, []
    args = list(argv[1:])
    while args:
        a = args.pop(0)
        if a == "--lang" and args:
            lang = args.pop(0)[:2].lower()
        elif a == "--file" and args:
            out_file = args.pop(0)
        else:
            words.append(a)
    text = speakable(" ".join(words) if words else sys.stdin.read())
    if not text:
        return 0
    if lang not in LANGS:
        lang = language(text)
    model = os.path.join(VOICES, f"{lang}.onnx")
    if not os.path.exists(model):
        model = os.path.join(VOICES, "en.onnx")
    if not os.path.exists(model):
        print("no voice installed (NIXBOOK_PIPER_VOICES)", file=sys.stderr)
        return 2
    piper = shutil.which("piper")
    if not piper:
        print("piper isn't installed", file=sys.stderr)
        return 2
    if out_file:
        p = subprocess.run([piper, "-m", model, "-f", out_file], input=text, text=True, capture_output=True)
        return p.returncode
    try:
        with open(model + ".json", encoding="utf-8") as f:
            rate = int(json.load(f)["audio"]["sample_rate"])
    except (OSError, ValueError, KeyError):
        rate = 22050
    synth = subprocess.Popen([piper, "-m", model, "--output-raw"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=False)
    play = subprocess.Popen(["pacat", "--raw", f"--rate={rate}", "--channels=1", "--format=s16le",
                             "--client-name=nixbook-voice", "--stream-name=Desktop agent"],
                            stdin=synth.stdout, stderr=subprocess.DEVNULL)
    synth.stdout.close()

    def stop(*_):
        for p in (synth, play):
            try:
                p.kill()
            except OSError:
                pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        synth.stdin.write(text.encode())
        synth.stdin.close()
    except BrokenPipeError:
        pass
    synth.wait()
    return play.wait()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
