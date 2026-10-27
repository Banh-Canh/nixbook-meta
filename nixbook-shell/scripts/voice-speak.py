"""nixbook-voice-speak: the desktop agent's answers read out loud
(services/Voice.qml, ai.voice.speak), in a cute voice. Meta's Model API has
no speech synthesis, so it is Meta's MMS-TTS (Massively Multilingual Speech,
facebook/mms-tts, English and French; the ONNX conversion run by
sherpa-onnx), on this computer, made cute (ai.voice.style "cute"): the
voice and its timbre raised a little together (a smaller, younger
character), then the pitch raised again keeping the timbre (clear, not a
chipmunk), a touch of treble, and a bouncier pace.

  nixbook-voice-speak [--lang auto|en|fr] [--style cute|natural] [--file WAV] TEXT…

Sentence after sentence: the first is heard while the next ones are made.
The text is made speakable first (no Markdown, code, links or emoji;
numbers spelled out: MMS reads letters only). SIGTERM / SIGINT stop it at
once (the key, Escape). --file writes one WAV instead of playing (tests).
NIXBOOK_MMS_VOICES: a folder with en/ and fr/ (model.onnx, tokens.txt).
"""

import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading

VOICES = os.environ.get("NIXBOOK_MMS_VOICES", "")
MAX_CHARS = 900
# The cute chain, per voice (MMS's English voice speaks around 134 Hz, the
# French one around 107 Hz): (raise with the timbre, raise keeping it).
CUTE = {"en": (1.35, 1.5), "fr": (1.4, 1.55)}
PACE = 1.08

FR = re.compile(r"\b(le|la|les|des|est|une|pas|vous|tu|je|il|elle|avec|pour|dans|sur|c'est|ce|cette|sont|ont|aux|du|au|et|j'ai|oui|non)\b", re.I)
EN = re.compile(r"\b(the|is|are|and|you|your|to|of|in|it|on|with|for|this|that|have|has|was|i|yes|no)\b", re.I)

ONES_EN = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen " \
          "seventeen eighteen nineteen".split()
TENS_EN = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
ONES_FR = "zéro un deux trois quatre cinq six sept huit neuf dix onze douze treize quatorze quinze seize dix-sept " \
          "dix-huit dix-neuf".split()
TENS_FR = {2: "vingt", 3: "trente", 4: "quarante", 5: "cinquante", 6: "soixante"}


def words_en(n):
    if n < 20:
        return ONES_EN[n]
    if n < 100:
        return TENS_EN[n // 10] + ("-" + ONES_EN[n % 10] if n % 10 else "")
    if n < 1000:
        return ONES_EN[n // 100] + " hundred" + (" " + words_en(n % 100) if n % 100 else "")
    if n < 1_000_000:
        return words_en(n // 1000) + " thousand" + (" " + words_en(n % 1000) if n % 1000 else "")
    return str(n)


def words_fr(n):
    if n < 20:
        return ONES_FR[n]
    if n < 70:
        t, u = divmod(n, 10)
        return TENS_FR[t] + ("" if u == 0 else " et un" if u == 1 else "-" + ONES_FR[u])
    if n < 80:
        return "soixante" + (" et " if n == 71 else "-") + ONES_FR[n - 60]
    if n < 100:
        return "quatre-vingt" + ("s" if n == 80 else "-" + ONES_FR[n - 80])
    if n < 1000:
        h, r = divmod(n, 100)
        return ("cent" if h == 1 else ONES_FR[h] + " cent" + ("s" if r == 0 else "")) + (" " + words_fr(r) if r else "")
    if n < 1_000_000:
        k, r = divmod(n, 1000)
        return ("mille" if k == 1 else words_fr(k) + " mille") + (" " + words_fr(r) if r else "")
    return str(n)


def language(text):
    fr = len(FR.findall(text)) + 2 * len(re.findall(r"[éèêàçùœâîôû]", text, re.I))
    return "fr" if fr > len(EN.findall(text)) else "en"


def speakable(text, lang):
    s = str(text)
    s = re.sub(r"```.*?```", " ", s, flags=re.S)
    s = re.sub(r"<think>.*?(</think>|$)", " ", s, flags=re.S)
    s = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", s)
    s = re.sub(r"https?://\S+", "", s)
    s = re.sub(r"[`*_#>|~]", "", s)
    s = re.sub(r"^\s*[-•]\s+", "", s, flags=re.M)
    s = re.sub(r"[\U0001F000-\U0001FFFF☀-➿️✓✗→⚠⟦⟧]", "", s)
    words = words_fr if lang == "fr" else words_en
    unit = {"%": (" pour cent", " percent"), "°C": (" degrés", " degrees"), "°": (" degrés", " degrees")}
    for sym, (fr, en) in unit.items():
        s = re.sub(rf"(\d)\s*{re.escape(sym)}", lambda m: m.group(1) + (fr if lang == "fr" else en), s)
    def clock(h, m):
        h, m = int(h), int(m or 0)
        if lang == "fr":
            return f"{'une' if h == 1 else words(h)} heure{'s' if h > 1 else ''}" + (f" {words(m)}" if m else "")
        return words(h) + ("" if m == 0 else f" oh {words(m)}" if m < 10 else f" {words(m)}")
    s = re.sub(r"\b(\d{1,2}):(\d{2})\b", lambda m: clock(m.group(1), m.group(2)), s)
    if lang == "fr":
        s = re.sub(r"\b(\d{1,2})\s?h(?:\s?(\d{2}))?\b", lambda m: clock(m.group(1), m.group(2)), s)
    s = re.sub(r"(\d+)[.,](\d+)", lambda m: f"{words(int(m.group(1)))} {'virgule' if lang == 'fr' else 'point'} "
               + " ".join(words(int(d)) for d in m.group(2)), s)
    s = re.sub(r"\d+", lambda m: words(int(m.group(0))), s)
    s = re.sub(r"[ \t]+", " ", s)
    s = re.sub(r"\n{2,}", "\n", s).strip()
    if len(s) > MAX_CHARS:
        cut = s.rfind(".", 0, MAX_CHARS)
        s = s[:cut + 1 if cut > MAX_CHARS // 2 else MAX_CHARS]
    return s


def sentences(text):
    parts = [p.strip() for p in re.split(r"(?<=[.!?…])\s+|\n+", text) if p.strip()]
    # Very short pieces go with the next (a "Done!" alone sounds clipped).
    out = []
    for p in parts:
        if out and len(out[-1]) < 12:
            out[-1] += " " + p
        else:
            out.append(p)
    return out


class Speaker:
    def __init__(self, lang, style, tmp):
        self.lang, self.style, self.tmp = lang, style, tmp
        self.model = os.path.join(VOICES, lang)
        self.procs = []
        self.stopped = False
        self.n = 0

    def run(self, cmd, **kw):
        if self.stopped:
            raise RuntimeError("stopped")
        p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kw)
        self.procs.append(p)
        rc = p.wait()
        self.procs.remove(p)
        if rc != 0 and not self.stopped:
            raise RuntimeError(f"{os.path.basename(cmd[0])} failed ({rc})")

    def make(self, text):
        """One sentence → a WAV, made cute."""
        self.n += 1
        raw = os.path.join(self.tmp, f"raw{self.n}.wav")
        self.run(["sherpa-onnx-offline-tts", f"--vits-model={self.model}/model.onnx",
                  f"--vits-tokens={self.model}/tokens.txt", "--num-threads=2", f"--output-filename={raw}", text])
        if self.style != "cute":
            return raw
        both, keep = CUTE.get(self.lang, CUTE["en"])
        mid = os.path.join(self.tmp, f"mid{self.n}.wav")
        out = os.path.join(self.tmp, f"cute{self.n}.wav")
        self.run(["ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-af",
                  f"asetrate=16000*{both},aresample=24000,treble=g=3:f=3500", mid])
        self.run(["rubberband-r3", "-q", "-F", "-f", str(keep), "-T", f"{PACE / both:.4f}", mid, out])
        return out

    def stop(self, *_):
        self.stopped = True
        for p in list(self.procs):
            try:
                p.kill()
            except OSError:
                pass


def main(argv):
    lang, style, out_file, words = "auto", "cute", None, []
    args = list(argv[1:])
    while args:
        a = args.pop(0)
        if a == "--lang" and args:
            lang = args.pop(0)[:2].lower()
        elif a == "--style" and args:
            style = args.pop(0)
        elif a == "--file" and args:
            out_file = args.pop(0)
        else:
            words.append(a)
    raw_text = " ".join(words) if words else sys.stdin.read()
    if lang not in ("en", "fr"):
        lang = language(raw_text)
    text = speakable(raw_text, lang)
    if not text:
        return 0
    if not os.path.exists(os.path.join(VOICES, lang, "model.onnx")):
        print("no voice installed (NIXBOOK_MMS_VOICES)", file=sys.stderr)
        return 2
    for tool in ("sherpa-onnx-offline-tts", "ffmpeg", "rubberband-r3", "pw-play"):
        if not shutil.which(tool):
            print(f"{tool} isn't installed", file=sys.stderr)
            return 2
    with tempfile.TemporaryDirectory(prefix="nixbook-voice-") as tmp:
        sp = Speaker(lang, style, tmp)
        signal.signal(signal.SIGTERM, lambda *_: (sp.stop(), sys.exit(0)))
        signal.signal(signal.SIGINT, lambda *_: (sp.stop(), sys.exit(0)))
        if out_file:
            parts = [sp.make(s) for s in sentences(text)]
            if len(parts) == 1:
                shutil.copy(parts[0], out_file)
            else:
                lst = os.path.join(tmp, "list.txt")
                with open(lst, "w") as f:
                    f.writelines(f"file '{p}'\n" for p in parts)
                sp.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst, out_file])
            return 0
        # Made in the background, played in order: the next sentence is
        # ready when the last one ends.
        ready = queue.Queue()

        def maker():
            try:
                for s in sentences(text):
                    ready.put(sp.make(s))
            except RuntimeError:
                pass
            ready.put(None)

        threading.Thread(target=maker, daemon=True).start()
        while True:
            wav = ready.get()
            if wav is None or sp.stopped:
                break
            try:
                sp.run(["pw-play", "--media-role=Assistant", wav])
            except RuntimeError:
                break
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
