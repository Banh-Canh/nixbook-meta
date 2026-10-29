"""nixbook-meeting: Muse's meeting companion (services/Meeting.qml).

While the user is on a call, what is said is transcribed live by Meta's
Muse Voice Transcribe (nixbook-voice-stream --segments, one stream per side:
what the user hears — the default output's monitor — and, optionally, their
own microphone, labelled "You"), shown as captions; the lines in another
language than the user's are translated (the small model, a batch every few
seconds); every ai.meeting.notesEveryS seconds the small model folds what
was said since into running notes (topics, decisions, action items with an
owner, open questions); when the call ends, the big model (ai.routing.meeting,
Muse Wonder by default) writes its record: a summary, the decisions, the
action items and a follow-up message the user may send (never sent here).

The transcript stays on this computer: $XDG_STATE_HOME/nixbook-shell/
meetings/<id>.json (0600, its folder 0700), kept ai.meeting.keepDays days.
Text sent to a model goes through desktop-mcp's privacy mask (names,
emails… hidden) and what comes back is unmasked: everything shown carries
the real names. Nothing runs unless the shell's AI is on and online
(policies.ai 1) and ai.meeting.enable.

  nixbook-meeting run [--title T] [--event ID] [--app APP] [--mic]
                      [--translate LANG] [--lang L] [--notes-every S]
                      [--keep-days N] [--monitor-file WAV] [--mic-file WAV]
      Listens until "stop" on stdin (or 4 hours), then writes the record.
      Run through `nixbook-model-provider run` (the streams need the key).
      stdin: "stop" (the record written), "cancel" (none), "mic on|off",
      "translate LANG|off". One JSON object per line on stdout:
        {"type": "started", "id", "path"}
        {"type": "ready", "who"}            a side's stream is up
        {"type": "partial", "who", "text"}  the words being said
        {"type": "final", "who", "text", "i", "t"}   a caption line
        {"type": "translation", "i", "text"}
        {"type": "notes", "notes"}          the running notes, whole
        {"type": "status", "text"}
        {"type": "summary", "summary"}      {title, summary, decisions,
                                            actions, questions, followup}
        {"type": "error", "error", "who"?}
        {"type": "ended", "id", "path", "lines"}
  nixbook-meeting list [--json] [N]       the meetings kept, newest first
  nixbook-meeting show [ID|last] [--json] [--transcript]
  nixbook-meeting summarize ID            its record written again
  nixbook-meeting prune [--keep-days N]   the older ones deleted

The --*-file options stream WAV files instead of the audio (tests).
"""

import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import nixbook_ai  # noqa: E402

HERE = os.path.dirname(os.path.realpath(__file__))
LANGS = {"en": "English", "fr": "French", "de": "German", "vi": "Vietnamese", "es": "Spanish",
         "it": "Italian", "pt": "Portuguese", "nl": "Dutch", "ja": "Japanese", "zh": "Chinese"}
# How often the lines in another language are translated, and the most a
# batch takes (a caption is a sentence or two).
TRANSLATE_EVERY = float(os.environ.get("NIXBOOK_MEETING_TRANSLATE_EVERY") or 4.0)
TRANSLATE_BATCH = 12
# A call is long, a model's prompt isn't: the transcript the record is
# written from, at most (the middle cut, the running notes cover it).
SUMMARY_CHARS = 90000
NOTES_CHUNK_CHARS = 14000
MAX_SECONDS = 4 * 3600
LINE_MAX = 2000

out_lock = threading.Lock()


def emit(kind, **fields):
    with out_lock:
        sys.stdout.write(json.dumps({"type": kind, **fields}, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def meetings_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "nixbook-shell", "meetings")


def settings(cfg=None):
    cfg = cfg if cfg is not None else nixbook_ai.config()
    m = ((cfg.get("ai") or {}).get("meeting") or {})
    m = m if isinstance(m, dict) else {}
    r = ((cfg.get("ai") or {}).get("routing") or {})
    r = r if isinstance(r, dict) else {}

    def num(key, default, lo, hi):
        try:
            return max(lo, min(hi, float(m.get(key, default))))
        except (TypeError, ValueError):
            return default
    return {"enable": m.get("enable", True) is not False, "keepDays": int(num("keepDays", 30, 1, 3650)),
            "notesEveryS": num("notesEveryS", 75, 1, 900),
            # The record: Muse Wonder (big) unless ai.routing.meeting says.
            "model": str(r.get("meeting") or "big"), "fast": r.get("effortMinimal", True) is not False,
            "policy": cfg.get("policies", {}).get("ai", 1) if isinstance(cfg.get("policies"), dict) else 1}


def write_private(path, data):
    """PATH replaced atomically, readable by the user alone."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    try:
        os.chmod(os.path.dirname(path), 0o700)
    except OSError:
        pass
    tmp = f"{path}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def all_meetings():
    folder = meetings_dir()
    try:
        names = [n for n in os.listdir(folder) if n.endswith(".json")]
    except OSError:
        return []
    out = []
    for n in names:
        d = load(os.path.join(folder, n))
        if d and d.get("id"):
            out.append(d)
    out.sort(key=lambda d: d.get("started") or 0, reverse=True)
    return out


def prune(keep_days):
    """The meetings started more than KEEP_DAYS days ago, deleted: the
    number removed."""
    cutoff = time.time() - max(1, keep_days) * 86400
    removed = 0
    for d in all_meetings():
        if (d.get("started") or 0) < cutoff:
            try:
                os.unlink(os.path.join(meetings_dir(), f"{d['id']}.json"))
                removed += 1
            except OSError:
                pass
    return removed


# -- which language a caption is in ------------------------------------------
# A few function words a language: a line clearly in the user's own language
# isn't sent to be translated (most of a call usually is).
STOPWORDS = {
    "en": "the and is are you that this with for have we it of to what not be can will do so was there".split(),
    "fr": "le la les et est que qui vous nous je pas un une des du pour avec ce sur dans c'est on mais très".split(),
    "de": "der die das und ist nicht ich wir sie mit ein eine zu auf für es du den dem auch wie oder".split(),
    "es": "el los las y es que no un una con para por lo pero está como muy también".split(),
    "it": "il gli è che non un una di per con sono ma come anche questo".split(),
    "pt": "o os as é que não um uma com para por mas como você também".split(),
    "nl": "het en is niet een van ik we je met voor op dat zijn ook".split(),
}
STOPWORDS = {lang: set(words) for lang, words in STOPWORDS.items()}
VI_LETTERS = re.compile("[ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]", re.I)
OTHER_SCRIPT = re.compile("[Ѐ-ӿ؀-ۿऀ-ॿ぀-ヿ一-鿿가-힯]")


def detect(text):
    """The language of TEXT (en, fr, de…), "other" for another script,
    "" when it can't tell."""
    t = str(text or "").lower()
    if VI_LETTERS.search(t):
        return "vi"
    if OTHER_SCRIPT.search(t):
        return "other"
    words = re.findall(r"[a-zà-ÿ']+", t)
    scores = sorted(((sum(1 for w in words if w in sw), lang) for lang, sw in STOPWORDS.items()), reverse=True)
    best, second = scores[0], scores[1]
    if best[0] >= 2 and best[0] > second[0]:
        return best[1]
    return ""


def needs_translation(text, target):
    lang = detect(text)
    if lang == target:
        return False
    # Too short to tell ("OK", "Yeah", "Ja."): left as it is.
    return bool(lang) or len(str(text).split()) >= 4


# -- the model passes ---------------------------------------------------------

PRIVACY = ("People's names may be stand-ins the user's computer chose: write a person's name exactly as you were "
           "given it, never another name for them. Text in ⟦…⟧ (⟦Person 2⟧, ⟦Email 1⟧) is a private detail the "
           "user's computer hid from you: keep the placeholder exactly as it is.")
WHO = ("The captions come from a live transcription (expect mistakes). \"You\" is the user; \"Them\" is everyone "
       "else on the call (one audio stream, so they have no names unless someone says them).")

TRANSLATE_SYSTEM = ("You translate the live captions of a call into {target}. Each numbered line is one caption. "
                    "For each, give its translation into {target}, natural and short; a line already in {target} "
                    "gets null. " + PRIVACY)
TRANSLATE_SCHEMA = {"type": "object", "required": ["lines"], "properties": {"lines": {"type": "array", "items": {
    "type": "object", "required": ["n", "text"],
    "properties": {"n": {"type": "integer"}, "text": {"type": ["string", "null"]}}}}}}

ITEMS = {"type": "array", "items": {"type": "string"}, "maxItems": 12}
ACTIONS = {"type": "array", "maxItems": 15, "items": {"type": "object", "required": ["what"], "properties": {
    "what": {"type": "string"}, "owner": {"type": "string"}, "due": {"type": "string"}}}}
NOTES_SCHEMA = {"type": "object", "required": ["topics", "decisions", "actions"], "properties": {
    "topics": ITEMS, "decisions": ITEMS, "actions": ACTIONS, "questions": ITEMS}}
NOTES_SYSTEM = ("You keep the running notes of a call the user is in, while it happens. You get the notes so far "
                "and what was said since. " + WHO + " Give the whole updated notes: topics (short phrases, in the "
                "order discussed), decisions (what was agreed, a line each), actions (what someone will do: what, "
                "owner — \"You\", a name heard, or \"\" — and due when said), questions (left open). Keep the "
                "earlier items unless the call changed them, merge duplicates, at most 12 a list, short lines, in "
                "the call's language. " + PRIVACY)
SUMMARY_SCHEMA = {"type": "object", "required": ["title", "summary", "decisions", "actions", "followup"],
                  "properties": {
                      "title": {"type": "string"}, "summary": {"type": "string"}, "decisions": ITEMS,
                      "actions": ACTIONS, "questions": ITEMS,
                      "followup": {"type": "object", "required": ["body"], "properties": {
                          "subject": {"type": "string"}, "body": {"type": "string"}}}}}
SUMMARY_SYSTEM = ("The call is over. Write its record for the user, from its transcript and the running notes "
                  "taken during it. " + WHO + " Give: title (8 words at most), summary (2 to 4 sentences), "
                  "decisions, actions (what, owner, due when said), questions left open, and followup: a short, "
                  "friendly message the user could send the others afterwards (subject and body: thanks, the "
                  "decisions, the action items with their owners), not signed. In the call's language. Only what "
                  "was said: nothing made up. " + PRIVACY)


def clock(t):
    t = int(t or 0)
    return f"{t // 3600}:{t % 3600 // 60:02d}:{t % 60:02d}" if t >= 3600 else f"{t // 60:02d}:{t % 60:02d}"


def transcript_text(lines, start=0, end=None):
    return "\n".join(f"{clock(ln.get('t'))} {'You' if ln.get('who') == 'you' else 'Them'}: {ln.get('text', '')}"
                     for ln in lines[start:end])


def ask(purpose, system, prompt, schema, model, fast, effort=None):
    """One structured answer: the prompt masked, the answer unmasked, what
    was sent noted in desktop-mcp's sent log."""
    masked = nixbook_ai.mask(prompt)
    p = nixbook_ai.Provider.from_env()
    nixbook_ai.sent_note(purpose, f"{p.label}:{p.model(model)}", masked)
    value = nixbook_ai.answer(system, masked, model=model, schema=schema, fast=fast, effort=effort,
                              max_tokens=6000, provider=p)
    return nixbook_ai.unmask_json(value) if isinstance(value, (dict, list)) else value


def clean_notes(d):
    """The notes as the shell shows them: lists of short strings, actions
    {what, owner, due}."""
    d = d if isinstance(d, dict) else {}

    def strings(v):
        return [str(x).strip()[:300] for x in (v if isinstance(v, list) else []) if str(x).strip()][:15]
    actions = []
    for a in d.get("actions") if isinstance(d.get("actions"), list) else []:
        if isinstance(a, dict) and str(a.get("what") or "").strip():
            actions.append({"what": str(a["what"]).strip()[:300], "owner": str(a.get("owner") or "").strip()[:80],
                            "due": str(a.get("due") or "").strip()[:60]})
    return {"topics": strings(d.get("topics")), "decisions": strings(d.get("decisions")), "actions": actions[:15],
            "questions": strings(d.get("questions"))}


def write_record(meeting, cfg, notes_now=None):
    """The record of a call (the big model): {title, summary, decisions,
    actions, questions, followup {subject, body}}, or {error}."""
    lines = meeting.get("lines") or []
    if not lines:
        return {"empty": True, "title": meeting.get("title") or "", "summary": "", "decisions": [], "actions": [],
                "questions": [], "followup": {"subject": "", "body": ""}}
    text = transcript_text(lines)
    if len(text) > SUMMARY_CHARS:
        head = text[:SUMMARY_CHARS // 6]
        tail = text[-(SUMMARY_CHARS - len(head)):]
        text = head + "\n[… the middle of the call: see the running notes …]\n" + tail
    notes = notes_now if notes_now is not None else meeting.get("notes") or {}
    prompt = (f"Call: {meeting.get('title') or 'untitled'} ({clock(lines[-1].get('t'))} long)\n\n"
              f"Running notes:\n{json.dumps(notes, ensure_ascii=False)}\n\nTranscript:\n{text}")
    try:
        got = ask("meeting record", SUMMARY_SYSTEM, prompt, SUMMARY_SCHEMA, cfg["model"], False, effort="low")
    except nixbook_ai.AIError as e:
        return {"error": str(e)}
    got = got if isinstance(got, dict) else {}
    out = clean_notes(got)
    out.pop("topics", None)
    follow = got.get("followup") if isinstance(got.get("followup"), dict) else {}
    out.update(title=str(got.get("title") or meeting.get("title") or "").strip()[:120],
               summary=str(got.get("summary") or "").strip()[:2000],
               followup={"subject": str(follow.get("subject") or "").strip()[:200],
                         "body": str(follow.get("body") or "").strip()[:4000]})
    return out


# -- one side of the call -----------------------------------------------------

def stream_cmd():
    forced = os.environ.get("NIXBOOK_VOICE_STREAM")
    if forced:
        return forced.split()
    exe = shutil.which("nixbook-voice-stream")
    if exe:
        return [exe]
    return [sys.executable, "-I", os.path.join(HERE, "voice-stream.py")]


class Side(threading.Thread):
    """One nixbook-voice-stream (the call, or the user's microphone), opened
    again when it ends on its own (the server's limit, the network), given
    up after five quick ends in a row."""

    def __init__(self, who, source, lang, file, on_event):
        super().__init__(daemon=True)
        self.who, self.source, self.lang, self.file, self.on_event = who, source, lang, file, on_event
        self.proc = None
        self.stopping = threading.Event()
        self.lock = threading.Lock()

    def argv(self):
        cmd = stream_cmd() + ["--segments", "--no-level", "--source", self.source]
        if self.lang:
            cmd += ["--lang", self.lang]
        if self.file:
            cmd += ["--file", self.file]
        setpriv = shutil.which("setpriv")
        return ([setpriv, "--pdeathsig", "TERM"] if setpriv else []) + cmd

    def run(self):
        quick = 0
        while not self.stopping.is_set():
            started = time.monotonic()
            try:
                proc = subprocess.Popen(self.argv(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1)
            except OSError as e:
                self.on_event(self.who, {"type": "error", "error": f"voice stream: {e}"})
                return
            with self.lock:
                self.proc = proc
            for line in proc.stdout:
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if isinstance(ev, dict):
                    self.on_event(self.who, ev)
            proc.wait()
            if self.stopping.is_set() or self.file:
                break
            quick = quick + 1 if time.monotonic() - started < 5 else 0
            if quick >= 5:
                self.on_event(self.who, {"type": "error", "error": "the voice stream keeps failing", "fatal": True})
                break
            self.stopping.wait(min(16, 2 ** quick))
        self.on_event(self.who, {"type": "closed"})

    def stop(self, wait=4.0):
        """The last words awaited (a moment), then gone."""
        self.stopping.set()
        with self.lock:
            proc = self.proc
        if proc and proc.poll() is None:
            try:
                proc.stdin.write("stop\n")
                proc.stdin.flush()
            except (OSError, ValueError):
                pass
            try:
                proc.wait(wait)
            except subprocess.TimeoutExpired:
                proc.terminate()
        self.join(wait + 1)


# -- the meeting --------------------------------------------------------------

class Meeting:
    def __init__(self, opts, cfg):
        self.cfg = cfg
        self.opts = opts
        mid = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
        self.path = os.path.join(meetings_dir(), f"{mid}.json")
        self.data = {"version": 1, "id": mid, "title": opts["title"], "event": opts["event"], "app": opts["app"],
                     "started": time.time(), "ended": None, "lang": opts["translate"] or opts["lang"], "lines": [],
                     "notes": {}, "summary": None}
        self.t0 = time.monotonic()
        self.lock = threading.Lock()
        self.dirty = threading.Event()
        self.done = threading.Event()
        self.translate = opts["translate"]
        self.folded = 0          # lines already in the notes
        self.translated = 0      # lines looked at for translation
        self.sides = {}
        self.errors = set()

    def save(self):
        with self.lock:
            snapshot = json.loads(json.dumps(self.data, ensure_ascii=False))
        write_private(self.path, snapshot)

    def saver(self):
        while not self.done.is_set():
            if self.dirty.wait(3):
                self.dirty.clear()
                try:
                    self.save()
                except OSError as e:
                    emit("error", error=f"couldn't save the transcript: {e}")
                self.done.wait(2)

    def on_event(self, who, ev):
        kind = ev.get("type")
        if kind == "ready":
            emit("ready", who=who)
        elif kind == "partial":
            emit("partial", who=who, text=str(ev.get("text") or "")[:LINE_MAX])
        elif kind == "final":
            said = str(ev.get("text") or "").strip()[:LINE_MAX]
            if not said:
                return
            with self.lock:
                t = round(time.monotonic() - self.t0, 1)
                self.data["lines"].append({"t": t, "who": who, "text": said})
                i = len(self.data["lines"]) - 1
            self.dirty.set()
            emit("final", who=who, text=said, i=i, t=t)
        elif kind == "error":
            self.error(str(ev.get("error") or "error"), who)

    def error(self, msg, who=""):
        """An error said once (a pass failing every few seconds isn't news)."""
        if (who, msg) in self.errors:
            return
        self.errors.add((who, msg))
        emit("error", error=msg, **({"who": who} if who else {}))

    def start_side(self, who):
        if who in self.sides and self.sides[who].is_alive():
            return
        side = Side(who, "monitor" if who == "them" else "mic", self.opts["lang"],
                    self.opts["monitorFile" if who == "them" else "micFile"], self.on_event)
        self.sides[who] = side
        side.start()

    def stop_side(self, who):
        side = self.sides.pop(who, None)
        if side:
            side.stop()

    def translator(self):
        """The lines in another language than the user's, translated in
        batches (the small model, minimal effort)."""
        backoff = 0.0
        while not self.done.wait(TRANSLATE_EVERY + backoff):
            target = self.translate
            if not target:
                continue
            with self.lock:
                lines = self.data["lines"]
                todo = [(i, lines[i]["text"]) for i in range(self.translated, len(lines))
                        if needs_translation(lines[i]["text"], target)][:TRANSLATE_BATCH]
                upto = todo[-1][0] + 1 if len(todo) == TRANSLATE_BATCH else len(lines)
            if not todo:
                self.translated = upto
                continue
            prompt = "\n".join(f"{n + 1}. {text}" for n, (_, text) in enumerate(todo))
            name = LANGS.get(target, target)
            try:
                got = ask("meeting translation", TRANSLATE_SYSTEM.format(target=name), prompt, TRANSLATE_SCHEMA,
                          "small", self.cfg["fast"])
            except nixbook_ai.AIError as e:
                self.error(f"translation: {e}")
                backoff = min(60.0, backoff * 2 + 10)
                continue
            backoff = 0.0
            self.translated = upto
            for item in (got or {}).get("lines") or []:
                if not isinstance(item, dict) or not isinstance(item.get("n"), int):
                    continue
                n, text = item["n"] - 1, item.get("text")
                if 0 <= n < len(todo) and isinstance(text, str) and text.strip():
                    i = todo[n][0]
                    with self.lock:
                        self.data["lines"][i]["tr"] = text.strip()[:LINE_MAX]
                    self.dirty.set()
                    emit("translation", i=i, text=text.strip()[:LINE_MAX])

    def fold_notes(self):
        """What was said since the last fold, into the running notes (the
        small model)."""
        with self.lock:
            lines = self.data["lines"]
            start, end = self.folded, len(lines)
            notes = self.data["notes"]
            # A long stretch (a slow server, a long gap) in pieces.
            chunk = transcript_text(lines, start, end)
            while len(chunk) > NOTES_CHUNK_CHARS and end - start > 1:
                end = start + max(1, (end - start) // 2)
                chunk = transcript_text(lines, start, end)
        if end <= start:
            return False
        prompt = (f"Call: {self.data.get('title') or 'untitled'}\n\nNotes so far:\n"
                  f"{json.dumps(notes or {}, ensure_ascii=False)}\n\nSaid since:\n{chunk}")
        got = ask("meeting notes", NOTES_SYSTEM, prompt, NOTES_SCHEMA, "small", self.cfg["fast"])
        notes = clean_notes(got)
        with self.lock:
            self.data["notes"] = notes
            self.folded = end
        self.dirty.set()
        emit("notes", notes=notes)
        return True

    def notetaker(self):
        every = self.opts["notesEvery"]
        while not self.done.wait(every):
            try:
                while self.fold_notes() and self.folded < len(self.data["lines"]) and not self.done.is_set():
                    pass
            except nixbook_ai.AIError as e:
                self.error(f"notes: {e}")

    def command(self, cmd):
        if cmd == "mic on":
            self.start_side("you")
        elif cmd == "mic off":
            self.stop_side("you")
        elif cmd.startswith("translate "):
            lang = cmd.split(" ", 1)[1].strip()[:2].lower()
            self.translate = lang if lang in LANGS else ""
            with self.lock:
                self.data["lang"] = self.translate or self.data["lang"]

    def run(self):
        os.makedirs(meetings_dir(), mode=0o700, exist_ok=True)
        self.save()
        emit("started", id=self.data["id"], path=self.path)
        self.start_side("them")
        if self.opts["mic"]:
            self.start_side("you")
        for fn in (self.saver, self.translator, self.notetaker):
            threading.Thread(target=fn, daemon=True).start()
        commands = queue.Queue()

        def stdin():
            for line in sys.stdin:
                commands.put(line.strip())
            commands.put("stop")
        threading.Thread(target=stdin, daemon=True).start()
        how = "stop"
        while True:
            try:
                cmd = commands.get(timeout=1)
            except queue.Empty:
                if time.monotonic() - self.t0 > MAX_SECONDS:
                    break
                # Every side gone for good (the files over, in tests): over.
                if self.sides and not any(s.is_alive() for s in self.sides.values()):
                    break
                continue
            if cmd in ("stop", "cancel"):
                how = cmd
                break
            self.command(cmd)
        for who in list(self.sides):
            self.stop_side(who)
        self.done.set()
        with self.lock:
            self.data["ended"] = time.time()
        self.save()
        if how == "stop":
            emit("status", text="Writing the summary")
            summary = write_record(self.data, self.cfg)
            with self.lock:
                if not summary.get("error"):
                    self.data["summary"] = summary
                    if summary.get("title") and not self.data.get("title"):
                        self.data["title"] = summary["title"]
            self.save()
            if summary.get("error"):
                emit("error", error=f"the summary: {summary['error']}")
            else:
                emit("summary", summary=summary)
        emit("ended", id=self.data["id"], path=self.path, lines=len(self.data["lines"]))
        return 0


def refuse(cfg):
    """Why it must not listen, or ""."""
    if cfg["policy"] != 1:
        return "AI is off or local only (Settings > Desktop agents > AI features)"
    if not cfg["enable"]:
        return "the meeting companion is off (Settings > Desktop agents > Meeting companion)"
    return ""


def cmd_run(args):
    opts = {"title": "", "event": "", "app": "", "mic": False, "translate": "", "lang": "", "notesEvery": None,
            "keepDays": None, "monitorFile": None, "micFile": None}
    while args:
        a = args.pop(0)
        if a == "--mic":
            opts["mic"] = True
        elif a in ("--title", "--event", "--app", "--translate", "--lang", "--notes-every", "--keep-days",
                   "--monitor-file", "--mic-file") and args:
            v = args.pop(0)
            key = {"--notes-every": "notesEvery", "--keep-days": "keepDays", "--monitor-file": "monitorFile",
                   "--mic-file": "micFile"}.get(a, a[2:])
            opts[key] = v
    cfg = settings()
    why = refuse(cfg)
    if why:
        emit("error", error=why)
        return 2
    nixbook_ai.ensure_provider(sys.argv[1:])
    opts["title"] = opts["title"].strip()[:200]
    opts["translate"] = opts["translate"][:2].lower() if opts["translate"][:2].lower() in LANGS else ""
    try:
        opts["notesEvery"] = max(1.0, min(900.0, float(opts["notesEvery"]))) if opts["notesEvery"] else cfg["notesEveryS"]
        keep = int(opts["keepDays"]) if opts["keepDays"] else cfg["keepDays"]
    except ValueError:
        emit("error", error="--notes-every and --keep-days take numbers")
        return 2
    prune(keep)
    return Meeting(opts, cfg).run()


def find(ref):
    meetings = all_meetings()
    if not meetings:
        return None
    if ref in ("", "last", "latest"):
        return meetings[0]
    return next((m for m in meetings if m["id"] == ref), None)


def as_text(m, transcript=False):
    out = [f"{m.get('title') or 'Untitled call'} — {time.strftime('%Y-%m-%d %H:%M', time.localtime(m.get('started') or 0))}"
           + ("" if m.get("ended") else " (still going)")]
    s = m.get("summary") or {}
    n = m.get("notes") or {}
    if s.get("summary"):
        out.append(s["summary"])
    for label, items in (("Decisions", s.get("decisions") or n.get("decisions")),
                         ("Open questions", s.get("questions") or n.get("questions")),
                         ("Topics", None if s else n.get("topics"))):
        if items:
            out.append(label + ":\n" + "\n".join(f"- {x}" for x in items))
    actions = s.get("actions") or n.get("actions")
    if actions:
        out.append("Action items:\n" + "\n".join(
            f"- {a['what']}" + (f" ({a['owner']})" if a.get("owner") else "") + (f", {a['due']}" if a.get("due") else "")
            for a in actions))
    if transcript:
        out.append("Transcript:\n" + transcript_text(m.get("lines") or []))
    return "\n\n".join(out)


def main(argv):
    args = list(argv[1:])
    cmd = args.pop(0) if args else ""
    if cmd == "run":
        return cmd_run(args)
    if cmd == "list":
        meetings = all_meetings()[:int(next((a for a in args if a.isdigit()), "20"))]
        rows = [{"id": m["id"], "title": m.get("title") or "", "started": m.get("started"), "ended": m.get("ended"),
                 "lines": len(m.get("lines") or []), "summary": bool(m.get("summary"))} for m in meetings]
        print(json.dumps(rows, ensure_ascii=False) if "--json" in args else "\n".join(
            f"{r['id']}  {r['title'] or 'Untitled call'}  ({r['lines']} lines)" for r in rows))
        return 0
    if cmd == "show":
        ref = next((a for a in args if not a.startswith("--")), "last")
        m = find(ref)
        if not m:
            print(f"no meeting {ref!r}", file=sys.stderr)
            return 1
        if "--json" in args:
            if "--transcript" not in args:
                m = {k: v for k, v in m.items() if k != "lines"}
            print(json.dumps(m, ensure_ascii=False))
        else:
            print(as_text(m, "--transcript" in args))
        return 0
    if cmd == "summarize":
        cfg = settings()
        why = refuse(cfg)
        if why:
            emit("error", error=why)
            return 2
        nixbook_ai.ensure_provider(sys.argv[1:])
        m = find(args[0] if args else "last")
        if not m:
            emit("error", error="no such meeting")
            return 1
        summary = write_record(m, cfg)
        if summary.get("error"):
            emit("error", error=summary["error"])
            return 1
        m["summary"] = summary
        write_private(os.path.join(meetings_dir(), f"{m['id']}.json"), m)
        emit("summary", summary=summary)
        return 0
    if cmd == "prune":
        keep = settings()["keepDays"]
        if "--keep-days" in args and args.index("--keep-days") + 1 < len(args):
            keep = int(args[args.index("--keep-days") + 1])
        print(prune(keep))
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
