"""nixbook-quick-ai: the instant answers of the shell's Quick AI (a
selection, the screen, the launcher, a notification, Full AI's reactions,
Kiroshi's scan). One request, one answer, no agent start: the provider's
Messages API (Meta's: Muse) called directly through nixbook_ai (the client
every AI script of the shell shares), so it answers in a couple of seconds.

Run through `nixbook-model-provider run nixbook-quick-ai ask REQUEST.json`,
which sets the provider's environment (NIXBOOK_AI_BASE_URL, NIXBOOK_AI_KEY,
NIXBOOK_AI_MODEL, NIXBOOK_AI_SMALL_MODEL, NIXBOOK_AI_BIG_MODEL); run without
it, the script goes through the provider itself.

The request (JSON): {mode, question, text, image, context: {app, title,
source}, history: [{role, text}], lang, effort, model: small|main|big}. The
answer, one JSON object per line on stdout:
  {"type": "start", "provider", "model"}
  {"type": "delta", "text"}        (streamed text, when the server streams)
  {"type": "answer", "text"}       (the whole answer, always last)
  {"type": "replies", "replies"}   (mode reply: the suggestions)
  {"type": "error", "error"}
  {"type": "done", "ms"}
What the desktop knows for the request (the time, weather, next events, the
user's corrections and preferences, the memory, what they just did) comes
from desktop-mcp's context broker (`context build --for text|react|scan`),
the one every AI surface reads. Text is masked by desktop-mcp's privacy mask
(names, emails… → ⟦Person 1⟧) before it leaves, and the answer unmasked;
what was sent is recorded in the desktop-mcp sent log, like every other AI
pass.

The `do` mode (the desktop agent) is nixbook-meta-agent's now, the shell's
only agent loop: the request is handed to it (exec), its stream-json events
on stdout instead of these.
"""

import base64
import concurrent.futures
import json
import os
import sys
import time

# The shared client (nixbook_ai.py), next to this script in the source tree
# and in the package.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import nixbook_ai  # noqa: E402

mask, unmask = nixbook_ai.mask, nixbook_ai.unmask

MODES = {
    "explain": "Explain the text below clearly and briefly: what it means, and anything worth knowing "
               "(a term, a command, an error and how to fix it). Two short paragraphs at most.",
    "summarize": "Summarize the text below in at most four short bullet points. Keep names, numbers and dates.",
    "translate": "Translate the text below into {target}. If it is already in {target}, translate it into "
                 "English. Output only the translation, nothing before or after it.",
    "rewrite": "Rewrite the text below so it reads clearly and naturally, same language, same meaning, "
               "same tone. Output only the rewritten text, nothing before or after it.",
    "fix": "Fix the spelling, grammar and punctuation of the text below and change nothing else. "
           "Output only the corrected text, nothing before or after it.",
    "ask": "Answer the user's question. The text below, if any, is what they are looking at.",
    "reply": "Below is a message the user received. Suggest three short replies they could send, in the "
             "message's language, each a different intent (e.g. yes / not now / a question back). Output "
             'only JSON: {{"replies": ["…", "…", "…"]}}.',
    "screen": "The image is part of the user's screen they selected. {question}",
    "do": "The user tells you what to do on their desktop, or asks something. Do it with the tools.",
    "extract": "Write out all the text below exactly as it is, keeping its lines and order. Output only that "
               "text, nothing before or after it.",
}
# The modes whose answer replaces the selection: the text alone.
TEXT_ONLY = {"translate", "rewrite", "fix", "extract"}

SYSTEM = (
    "You are the instant assistant built into the user's desktop (nixbook, a NixOS desktop). The user "
    "called you on something in front of them with a single key, so be quick and direct: no greeting, no "
    "preamble, no closing offer. Plain text or light Markdown (short lists, `code`). Answer in the language "
    "the user writes or speaks in ({lang} when it isn't clear), unless the task says otherwise."
)
PRIVACY = (
    "Text in ⟦…⟧ (⟦Person 2⟧, ⟦Email 1⟧) is a private detail the user's computer hid from you: keep the "
    "placeholder exactly as it is in your answer."
)
LANGS = {"en": "English", "fr": "French", "de": "German", "vi": "Vietnamese", "es": "Spanish",
         "it": "Italian", "ja": "Japanese", "zh": "Chinese", "pt": "Portuguese"}
TEXT_MAX = 24000
IMAGE_MAX = 8 * 1024 * 1024


def emit(kind, **fields):
    sys.stdout.write(json.dumps({"type": kind, **fields}, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def broker(surface, query="", app="", title="", no_activity=False):
    """What the desktop knows for this request, from desktop-mcp's context
    broker (`context build --for SURFACE`): its text, "" when it can't say
    (then the request's own pieces are used)."""
    argv = ["context", "build", "--for", surface, "--query", str(query or "")[:500]]
    if app:
        argv += ["--app", str(app)[:200]]
    if title:
        argv += ["--title", str(title)[:200]]
    if no_activity:
        argv.append("--no-activity")
    code, out = nixbook_ai.dm(argv, timeout=10)
    if code != 0:
        return ""
    try:
        d = json.loads(out)
    except ValueError:
        return ""
    return str(d.get("text") or "").strip() if isinstance(d, dict) else ""


def build(req):
    """The system prompt and the messages (Messages API shape, text
    masked), and the prompt as plain text for the record."""
    mode = req.get("mode") if req.get("mode") in MODES else "ask"
    lang = LANGS.get(str(req.get("lang") or "en")[:2].lower(), "English")
    target = req.get("target") or lang
    if mode == "translate" and target == "English" and lang == "English":
        target = "French"
    question = str(req.get("question") or "").strip()
    text = str(req.get("text") or "")[:TEXT_MAX]
    ctx = req.get("context") or {}
    task = MODES[mode].format(target=target, question=question or
                              "Say what this is and what matters in it, briefly; if it shows an error or a "
                              "problem, how to fix it.")
    if req.get("image") and not text:
        # A region of the screen (the screenshot app's Ask AI): its text is
        # in the image.
        task = task.replace("the text below", "the text in the image").replace("The text below", "The text in the image")
    parts = [f"Task: {task}"]
    where = " — ".join(str(ctx[k]) for k in ("app", "title") if ctx.get(k))
    if where:
        parts.append(f"Where it comes from: {where}")
    if mode not in ("screen",) and question and mode != "ask":
        parts.append(f"The user adds: {question}")
    if mode == "ask" and question:
        parts.append(f"Question: {question}")
    if text:
        parts.append(f"Text:\n<<<\n{text}\n>>>")
    # What the desktop knows (the broker: facts, corrections, preferences,
    # memory): not for a text copied out of an image; the text's own
    # rewrites without what the user just did.
    known = "" if mode == "extract" else broker(
        "text", question or text[:300], ctx.get("app") or "", ctx.get("title") or "", no_activity=mode in TEXT_ONLY)
    if not known and mode == "ask":
        known = str(req.get("facts") or "").strip()[:2000]
    if known:
        parts.append("What the desktop knows (the time, the user's preferences, their memory; use it only where it "
                     f"helps):\n{known}")
    prompt = mask("\n\n".join(parts))
    system = SYSTEM.format(lang=lang) + "\n\n" + PRIVACY
    content = [{"type": "text", "text": prompt}]
    image = req.get("image")
    if image:
        with open(image, "rb") as f:
            raw = f.read(IMAGE_MAX + 1)
        if len(raw) > IMAGE_MAX:
            raise ValueError("the image is too big")
        media = "image/jpeg" if raw[:3] == b"\xff\xd8\xff" else "image/png"
        content.insert(0, {"type": "image", "source": {"type": "base64", "media_type": media,
                                                        "data": base64.b64encode(raw).decode()}})
    # A follow-up: the first turn, the answers and questions since
    # (history, starting with the first answer), the new question last.
    messages = [{"role": "user", "content": content}]
    follow = str(req.get("followUp") or "").strip()
    if follow:
        for turn in (req.get("history") or [])[-12:]:
            role = "assistant" if turn.get("role") == "assistant" else "user"
            if turn.get("text") and messages[-1]["role"] != role:
                messages.append({"role": role, "content": mask(str(turn["text"]))})
        if messages[-1]["role"] == "user":
            messages.append({"role": "assistant", "content": "(no answer)"})
        messages.append({"role": "user", "content": mask(follow)})
        prompt = prompt + "\n\nFollow-up: " + mask(follow)
    return mode, system, messages, prompt


def model_alias(req, default="small"):
    return str(req.get("model") or default)


def answer_text(req, p, system, messages, on_delta):
    """The text modes' answer: Meta's fast chat endpoint first when the
    effort is low (reasoning_effort "minimal": about 2 s faster), else the
    Messages API streamed, its effort settings dropped if refused."""
    effort = str(req.get("effort") or "low")
    stream = []

    def relay(ev):
        if ev.get("type") == "content_block_delta" and (ev.get("delta") or {}).get("type") == "text_delta":
            piece = ev["delta"].get("text", "")
            stream.append(piece)
            on_delta(piece)
    msg = nixbook_ai.call(system, messages, model=model_alias(req), effort=effort, max_tokens=4000, stream=True,
                          on_event=relay, fast=effort in ("low", "minimal"), timeout=90, provider=p)
    return nixbook_ai.text_of(msg) or "".join(stream)


# ── Doing things: nixbook-meta-agent, the shell's only agent loop. The
# request is handed over to it as Quick AI's own loop used to run it: the
# desktop tools (the desktop MCP server: its pause, tool groups, guardrails
# and audit log), the broker's context for the bubble, the risky steps
# refused (no one to answer an approval on this command line, unless
# confirm "never"), a report, the apps' big servers on demand, the episode
# learned. Its stream-json events come out instead of this script's.
def do_mode(req):
    import shutil
    exe = shutil.which("nixbook-meta-agent")
    if not exe:
        emit("error", error="the desktop agent (nixbook-meta-agent) isn't installed")
        return 1
    question = str(req.get("followUp") or req.get("question") or "").strip()
    text = str(req.get("text") or "")[:TEXT_MAX]
    prompt = question + (f"\n\nText:\n<<<\n{text}\n>>>" if text else "") or "(empty message)"
    cfg = nixbook_ai.config()
    agent = (cfg.get("ai") or {}).get("agent") or {}
    confirm = str(req.get("confirm") or "destructive")
    servers = {"mcpServers": {"desktop": {"command": "nixbook-desktop-mcp",
                                          "env": {"NIXBOOK_DESKTOP_MCP_CLIENT": "Quick AI"}}}}
    args = [exe, "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--strict-mcp-config", "--mcp-config", json.dumps(servers), "--allowedTools", "mcp__desktop",
            "--context-for", "bubble", "--confirm", confirm if confirm in ("destructive", "actions", "never")
            else "destructive", "--report", "--lazy-mcp", "12", "--learn",
            "--model", model_alias(req, nixbook_ai.routing(cfg)["quick"]), "--no-session-persistence"]
    if agent.get("resolve", True) is not False:
        args.append("--resolve")
    if agent.get("verify", True) is not False:
        args.append("--verify")
    if str(req.get("effort") or "") in nixbook_ai.EFFORTS:
        args += ["--effort", str(req["effort"])]
    if str(req.get("panel") or "").strip():
        args += ["--append-system-prompt", str(req["panel"])]
    sys.stdout.flush()
    os.execv(exe, args + ["--", prompt])


def replies_of(text):
    s = text.strip()
    if s.startswith("```"):
        s = s.strip("`").split("\n", 1)[-1]
    start, end = s.find("{"), s.rfind("}")
    try:
        d = json.loads(s[start:end + 1])
        return [str(r).strip() for r in d.get("replies") or [] if str(r).strip()][:4]
    except (ValueError, AttributeError):
        return [line.lstrip("-•*0123456789. ").strip() for line in s.splitlines() if line.strip()][:3]


def clean(mode, text):
    """A replacement text alone: no fence nor quotes around it."""
    s = text.strip()
    if mode in TEXT_ONLY:
        if s.startswith("```") and s.endswith("```"):
            s = s[3:-3].split("\n", 1)[-1] if "\n" in s[3:-3] else s[3:-3]
        if len(s) > 1 and s[0] == s[-1] and s[0] in "\"'«“":
            s = s[1:-1]
    return s.strip()


# ── Full AI mode's reactions (services/FullAi.qml): something happened on
# the computer (a notification, a download, the battery, a screen…); the
# model decides: ignore it, tell the user, ask them what to do, or do it.
# It acts on its own only on what the user told it (this session, a rule,
# a note) or did twice before for the same kind of thing; else it asks.
# What the user answered is kept (learned.json) and given back next time.
REACT_SYSTEM = (
    "You run the user's desktop in Full AI mode: they talk to you, you are the one watching the computer. "
    "Something just happened. Decide, and answer with JSON only: {{\"action\": \"ignore\"|\"tell\"|\"ask\"|\"do\", "
    "\"say\": \"what you say out loud, one or two short spoken sentences\", \"instruction\": \"for do: the complete "
    "instruction for the desktop agent (it has the desktop tools)\", \"basis\": \"told\"|\"learned\"|\"guess\", "
    "\"learn\": \"a lasting preference this shows, or empty\"}}. "
    "ignore: noise, ads, your own actions, what the user already sees and doesn't need. tell: worth knowing, nothing "
    "to decide. ask: it needs a decision (a message to answer, a file to open, a meeting about to start): say what "
    "happened in a few words and ask what to do, offering the likely answer (\"Julien asks if you come tonight. "
    "Shall I say yes?\"). do: only when the user told you to (this session or a saved note/rule: basis \"told\") or "
    "always chose the same before (basis \"learned\"); never send a message or delete anything on a guess. "
    "Speak naturally, like a helpful assistant, in the language the user talks to you in (the conversation "
    "below; else the message's language when it is theirs, else {lang}), never read out codes or long "
    "texts; private details stay as the placeholders they are."
)


def learned_path():
    return os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
                        "nixbook-shell", "full-ai-learned.json")


def read_learned():
    try:
        with open(learned_path(), encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def write_learned(d):
    path = learned_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def event_sig(ev):
    """What makes two events "the same kind": the event, the app, and for a
    notification its title (a chat's sender)."""
    kind = str(ev.get("event") or "")
    app = str(ev.get("app") or "").lower()
    title = str(ev.get("title") or "").lower()[:60] if kind == "notification" else ""
    return "|".join(x for x in (kind, app, title) if x)


def learned_for(ev, d):
    """The past reactions to this kind of event, and the preferences."""
    sig = event_sig(ev)
    app_sig = "|".join(sig.split("|")[:2])
    past = [r for r in d.get("reactions") or [] if r.get("sig") == sig or r.get("sig", "").startswith(app_sig)][-12:]
    return past, (d.get("prefs") or [])[-30:]


def learn_command(raw):
    """`learn JSON`: {sig?, event?, decision, outcome, said?} a reaction and
    the user's answer (kept here: the past reactions Full AI reads back);
    {pref: text, app?, sig?} a preference, in the one memory every AI
    surface reads (desktop-mcp's `prefs add`; here only when it can't);
    {forget: true} the reactions gone."""
    try:
        item = json.loads(raw)
    except ValueError:
        print("learn: JSON expected", file=sys.stderr)
        return 2
    if not isinstance(item, dict):
        print("learn: a JSON object expected", file=sys.stderr)
        return 2
    d = read_learned()
    if item.get("forget") is True:
        write_learned({})
        return 0
    changed = False
    if item.get("pref"):
        pref = {"text": str(item["pref"])[:300], "source": "fullai"}
        if item.get("app"):
            pref["app"] = str(item["app"])[:80]
        if item.get("sig"):
            pref["signature"] = str(item["sig"])[:120]
        code, _ = nixbook_ai.dm(["prefs", "add", json.dumps(pref, ensure_ascii=False)])
        if code != 0:
            prefs = [p for p in d.get("prefs") or [] if p.get("text") != item["pref"]]
            prefs.append({"text": str(item["pref"])[:300], "t": int(time.time())})
            d["prefs"] = prefs[-60:]
            changed = True
    if item.get("decision"):
        sig = item.get("sig") or event_sig(item.get("event") or {})
        rec = {"sig": sig, "t": int(time.time()), "decision": item["decision"], "outcome": item.get("outcome", ""),
               "said": str(item.get("said") or "")[:200]}
        d["reactions"] = ((d.get("reactions") or []) + [rec])[-400:]
        changed = True
    if changed:
        write_learned(d)
    return 0


REACT_SCHEMA = {"type": "object", "properties": {
    "action": {"type": "string", "enum": ["ignore", "tell", "ask", "do"]}, "say": {"type": "string"},
    "instruction": {"type": "string"}, "basis": {"type": "string", "enum": ["told", "learned", "guess"]},
    "learn": {"type": "string"}}, "required": ["action", "say", "basis"]}


def react(req, started, p):
    """A decision on the user's behalf: the routing's decisions model
    (ai.routing.decisions, the big one by default, with its effort), the
    broker's context for the event (its facts, the user's corrections and
    preferences, the memory notes, whole lines), the conversation and the
    past reactions to the same kind of thing."""
    ev = req.get("event") or {}
    lang = LANGS.get(str(req.get("lang") or "en")[:2].lower(), "English")
    d = read_learned()
    past, prefs = learned_for(ev, d)
    r = nixbook_ai.routing()
    model = str(req.get("model") or r["decisions"])
    effort = str(req.get("effort") or r["decisionsEffort"])
    parts = ["What happened: " + json.dumps({k: v for k, v in ev.items() if v not in ("", None)}, ensure_ascii=False)]
    known = broker("react", f"{ev.get('app', '')} {ev.get('title', '')} {ev.get('text', '')}".strip(),
                   ev.get("app") or "", ev.get("title") or "")
    if known:
        parts.append("What the desktop knows (the time, the user's corrections and preferences, the memory, what "
                     f"they just did):\n{known}")
    else:
        # No broker: the request's own facts and the preferences kept here.
        if req.get("facts"):
            parts.append("What the desktop knows right now:\n" + str(req["facts"])[:1500])
        if prefs:
            parts.append("What the user prefers (learned):\n" + "\n".join("- " + x.get("text", "") for x in prefs))
    if req.get("recent"):
        parts.append("The conversation with the user so far (what they told you):\n" + str(req["recent"])[-2500:])
    if past:
        parts.append("Your past reactions to the same kind of thing and what the user answered:\n" + "\n".join(
            f"- {time.strftime('%d %b', time.localtime(x.get('t', 0)))}: you {x.get('decision')}, "
            f"the user {x.get('outcome') or 'said nothing'}{': ' + x['said'] if x.get('said') else ''}" for x in past))
    prompt = mask("\n\n".join(parts))
    system = REACT_SYSTEM.format(lang=lang) + "\n\n" + PRIVACY
    emit("start", provider=p.label, model=p.model(model))
    nixbook_ai.sent_note("Full AI: a reaction", f"{p.label.lower()}:{p.model(model)}", prompt)
    try:
        decision = nixbook_ai.answer(system, prompt, model=model, effort=effort, schema=REACT_SCHEMA, timeout=60,
                                     max_tokens=3000, provider=p)
    except Exception as e:  # noqa: BLE001
        emit("error", error=str(e))
        emit("done", ms=int((time.monotonic() - started) * 1000))
        return 1
    decision = nixbook_ai.unmask_json(decision) if isinstance(decision, dict) else {}
    action = decision.get("action") if decision.get("action") in ("ignore", "tell", "ask", "do") else "ignore"
    basis = decision.get("basis") if decision.get("basis") in ("told", "learned", "guess") else "guess"
    # Acting alone: only on what it was told, or what the user chose at
    # least twice before for this kind of thing; else it asks.
    if action == "do":
        agreed = sum(1 for x in past if x.get("outcome") in ("agreed", "did it") and x.get("decision") in ("ask", "do"))
        if basis == "guess" or (basis == "learned" and agreed < 2) or not str(decision.get("instruction") or "").strip():
            action = "ask"
    emit("react", action=action, say=str(decision.get("say") or "").strip()[:400],
         instruction=str(decision.get("instruction") or "").strip()[:2000], basis=basis,
         learn=str(decision.get("learn") or "").strip()[:300], sig=event_sig(ev))
    emit("done", ms=int((time.monotonic() - started) * 1000))
    return 0


def ask(path):
    started = time.monotonic()
    try:
        with open(path, encoding="utf-8") as f:
            req = json.load(f)
    except (OSError, ValueError) as e:
        emit("error", error=f"no request: {e}")
        return 2
    if req.get("mode") == "do":
        return do_mode(req)
    try:
        p = nixbook_ai.Provider.from_env()
    except nixbook_ai.AIError as e:
        emit("error", error=str(e))
        emit("done", ms=int((time.monotonic() - started) * 1000))
        return 1
    if req.get("mode") == "scan":
        return scan(req, started, p)
    if req.get("mode") == "react":
        return react(req, started, p)
    try:
        mode, system, messages, prompt = build(req)
        model = p.model(model_alias(req))
        emit("start", provider=p.label, model=model)
        purpose = f"Quick AI: {mode}" + (" (screen)" if req.get("image") else "")
        nixbook_ai.sent_note(purpose, f"{p.label.lower()}:{model}", prompt)
        # Replies come as JSON: only the suggestions are shown.
        stream = (lambda piece: None) if mode == "reply" else (lambda piece: emit("delta", text=unmask(piece)))
        text = answer_text(req, p, system, messages, stream)
    except Exception as e:  # noqa: BLE001 — every failure is the card's to show
        emit("error", error=str(e) or e.__class__.__name__)
        emit("done", ms=int((time.monotonic() - started) * 1000))
        return 1
    text = unmask(text)
    if mode == "reply":
        replies = replies_of(text)
        emit("replies", replies=replies)
        emit("answer", text="" if replies else text.strip())
    else:
        emit("answer", text=clean(mode, text))
    emit("done", ms=int((time.monotonic() - started) * 1000))
    return 0


# ── Kiroshi scan (services/Kiroshi.qml): a situational brief of the focused
# screen. A screenshot, the focused window's accessibility text and what the
# user is doing (their recent windows and commands, the open windows, the
# latest notifications, the next events, the time) go to the model, which
# says what they are in the middle of, the one thing that matters now, and
# labels the 3–8 things on screen with a substantial detail and, when the AI
# can take it off their hands, a plan, a draft and a self-contained
# instruction for the desktop agent (Quick AI's "do"). Everything is masked
# by the privacy mask on the way out. Answer: {"type": "scan", width,
# height, doing, focus, items: [{label, kind, box: [x, y, w, h] in the
# image's pixels, urgency, detail, handle: {title, plan, draft, instruction}
# | null}], routine: [item indexes]}.
SCAN_KINDS = {"window", "notification", "error", "message", "button", "field", "text", "media", "link", "event",
              "other"}
SCAN_URGENCY = ("now", "soon", "later", "noise")
SCAN_INTRO = (
    "You are the user's Kiroshi optics: a glance at their screen should leave them knowing what matters and "
    "having handed off the busywork, so they think less. The image is a {w}x{h} screenshot of their focused "
    "screen (nixbook: NixOS, the niri compositor). What they are doing is below."
)
# Pass 1, fast: what is on screen and what matters (the overlay shows it at once).
SCAN_FAST = (
    "Label the 3 to 8 things on the screen that matter (an error, a message waiting for an answer, a meeting "
    "coming, a form, the work in the main window, a notification…), most important first. For each: label (2-5 "
    "words), kind ({kinds}), box [x, y, width, height] in pixels of the image, tight around it, urgency (now: "
    "needs them now, soon, later, noise: can be dismissed or ignored), gist (one line, at most 14 words, the "
    "key fact). Then routine = the indexes (from 0) of the items an assistant with desktop tools could handle "
    "entirely without the user's judgment (noise to dismiss, an acknowledgement, a task to file). Write in "
    "{lang}. Output only JSON: "
    '{{"items": [{{"label": "…", "kind": "…", "box": [0, 0, 0, 0], "urgency": "now", "gist": "…"}}], '
    '"routine": []}}'
)
# Pass 0, alongside pass 1: the brief's two lines, in a few seconds.
SCAN_BRIEF = (
    "From the screen and what the user is doing, say in {lang}: doing = one line on what they "
    "are in the middle of; focus = the one thing that matters most right now (a meeting about to start, a "
    "message waiting, a failure), or \"\" if nothing is pressing. Output only JSON: "
    '{{"doing": "…", "focus": "…"}}'
)
# Pass 2, one per item, in parallel: the substance and what the agent can do.
SCAN_ITEM = (
    "On this screen you labelled:\n{listing}\n\nNow only item {n} (\"{label}\").{routine} Give:\n"
    "- detail: 2-3 sentences of real substance from what is visible and the context: the key facts, numbers, "
    "dates, who asks what, what an error means and its likely cause. Never just restate the label.\n"
    "- handle: what the user's desktop agent can take off their hands, or null when only the user can decide. "
    "The agent has tools for windows and apps, typing and keys, the clipboard, notifications, calendar, tasks, "
    "contacts, reminders and the shell, and can read the screen and the apps' accessibility trees. Prefer "
    "multi-step work that saves real effort (reply with the right context, gather information from several "
    "places, file a task with the details, set a reminder before the meeting, look up an error and propose the "
    "fix) over a single click the user could do as fast. handle = {{\"title\": a short verb phrase, \"plan\": 2 "
    "to 5 concrete steps, \"draft\": the exact text it would send or type if it writes something (a reply, a "
    "message, a commit message, a search) else \"\", \"instruction\": the complete self-contained instruction "
    "for the agent, naming the app, the window, the person, and including the draft}}.\n"
    "Write in {lang}; a draft in the language of the conversation it answers. Output only JSON: "
    '{{"detail": "…", "handle": {{"title": "…", "plan": ["…"], "draft": "", "instruction": "…"}}}}'
)


def image_size(path):
    """(width, height) from a PNG or JPEG header, (0, 0) if unknown."""
    try:
        with open(path, "rb") as f:
            head = f.read(64 * 1024)
    except OSError:
        return 0, 0
    if head[:8] == b"\x89PNG\r\n\x1a\n":
        return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")
    if head[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(head):
            if head[i] != 0xFF:
                i += 1
                continue
            marker = head[i + 1]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                return int.from_bytes(head[i + 7:i + 9], "big"), int.from_bytes(head[i + 5:i + 7], "big")
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            i += 2 + int.from_bytes(head[i + 2:i + 4], "big")
    return 0, 0


def quick_call(args, timeout):
    """nixbook-desktop-mcp ARGS, its stdout if it answers in time, else ""."""
    code, out = nixbook_ai.dm(args, timeout=timeout, env={"NIXBOOK_DESKTOP_MCP_CLIENT": "Kiroshi scan"})
    return out.strip() if code == 0 else ""


def scan_context(req):
    """What the user is doing, as text for the prompt (masked later with it):
    the broker's (the time, next events, what they just did, the memory)
    and what is on screen (the windows, the latest notifications, the
    focused window's accessibility tree), the tree and the broker asked in
    parallel."""
    ctx = req.get("context") or {}
    recent = req.get("recent") or []
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        ui = pool.submit(quick_call, ["call", "ui_read", "{}"], 3)
        known = pool.submit(broker, "scan", ctx.get("title") or ctx.get("app") or "", ctx.get("app") or "",
                            ctx.get("title") or "")
        ui_text, known_text = ui.result()[:2500], known.result()
    recent_text = ""
    if not known_text and recent:
        # No broker: the recent activity filtered by desktop-mcp's `context`.
        recent_text = quick_call(["context", json.dumps({"now": int(time.time()), "events": recent[-40:]})], 3)[:1500]
    parts = []
    if not known_text:
        parts.append(f"Now: {ctx.get('now') or time.strftime('%a %d %b %Y %H:%M')}")
    where = " — ".join(str(ctx[k]) for k in ("app", "title") if ctx.get(k))
    if where:
        parts.append(f"Focused window: {where}")
    wins = [f"- {w.get('app', '')} — {str(w.get('title', ''))[:90]}" for w in (req.get("windows") or [])[:10]]
    if wins:
        parts.append("Open windows (last used first):\n" + "\n".join(wins))
    if known_text:
        parts.append(f"What the desktop knows (the time, next events, what they just did, their memory):\n{known_text}")
    if recent_text:
        parts.append(f"What they did the last minutes:\n{recent_text}")
    notes = []
    for n in (req.get("notifications") or [])[:8]:
        body = " ".join(str(n.get("body") or "").split())[:220]
        notes.append(f"- [{n.get('time', '')}] {n.get('app', '')} · {n.get('summary', '')}: {body}")
    if notes:
        parts.append("Latest notifications (newest first):\n" + "\n".join(notes))
    if not known_text:
        events = [f"- {e.get('when', '')}: {e.get('summary', '')}" + (f" @ {e['location']}" if e.get("location") else "")
                  + (" (video call)" if e.get("meeting") else "") for e in (req.get("events") or [])[:4]]
        if events:
            parts.append("Next calendar events:\n" + "\n".join(events))
    if ui_text:
        parts.append(f"The focused window's accessibility tree (what a screen reader sees):\n<<<\n{ui_text}\n>>>")
    return "\n\n".join(parts)


def scan_json(text):
    s = text.strip()
    if s.startswith("```"):
        s = s.strip("`").split("\n", 1)[-1]
    start, end = s.find("{"), s.rfind("}")
    try:
        d = json.loads(s[start:end + 1])
    except ValueError:
        return None
    return d if isinstance(d, dict) else None


def scan_brief(text, w, h):
    """Pass 1's JSON, checked: {doing, focus, items, routine}; None if unusable."""
    d = scan_json(text)
    if d is None:
        return None
    items = []
    for it in d.get("items") or []:
        if not isinstance(it, dict):
            continue
        box = it.get("box")
        if not (isinstance(box, list) and len(box) == 4 and all(isinstance(v, (int, float)) for v in box)):
            continue
        x, y, bw, bh = (float(v) for v in box)
        # A box given as [x1, y1, x2, y2] (some models do).
        if bw > x and bh > y and (x + bw > w * 1.02 or y + bh > h * 1.02):
            bw, bh = bw - x, bh - y
        x, y = max(0.0, min(x, w - 1)), max(0.0, min(y, h - 1))
        bw, bh = max(8.0, min(bw, w - x)), max(8.0, min(bh, h - y))
        kind = str(it.get("kind") or "other").lower()
        urgency = str(it.get("urgency") or "later").lower()
        items.append({"label": str(it.get("label") or "?")[:60], "kind": kind if kind in SCAN_KINDS else "other",
                      "box": [round(x), round(y), round(bw), round(bh)],
                      "urgency": urgency if urgency in SCAN_URGENCY else "later",
                      "gist": str(it.get("gist") or "")[:160]})
    items = items[:8]
    routine = sorted({i for i in (d.get("routine") or []) if isinstance(i, int) and 0 <= i < len(items)})
    return {"items": items, "routine": routine}


def scan_handle(d):
    """Pass 2's JSON: {detail, handle | None}."""
    if d is None:
        return {"detail": "", "handle": None}
    handle = d.get("handle")
    if isinstance(handle, dict) and str(handle.get("instruction") or "").strip():
        handle = {"title": str(handle.get("title") or "Handle it")[:60],
                  "plan": [str(p).strip()[:160] for p in (handle.get("plan") or []) if str(p).strip()][:5],
                  "draft": str(handle.get("draft") or "")[:2000],
                  "instruction": str(handle["instruction"]).strip()[:2000]}
    else:
        handle = None
    return {"detail": str(d.get("detail") or "")[:700], "handle": handle}


def complete(req, p, system, image_block, parts, max_tokens):
    """One answer from the provider, as fast as it goes: its OpenAI-style
    chat endpoint first when it has one (Meta's takes reasoning_effort
    "minimal", which the Messages API can't ask for: half the thinking),
    else the Messages API. Returns (text, usage)."""
    content = ([image_block] if image_block else []) + [{"type": "text", "text": t} for t in parts]
    msg = nixbook_ai.call(system, [{"role": "user", "content": content}], model=model_alias(req),
                          effort=str(req.get("effort") or "low"), max_tokens=max_tokens,
                          fast=str(req.get("scanEffort") or "minimal") == "minimal", timeout=120, provider=p)
    return nixbook_ai.text_of(msg), msg.get("usage") or {}


def scan(req, started, p):
    """Three kinds of passes, the first two at once: the brief's two lines
    (emitted as "brief" in ~3 s), what is on the screen
    (the image: "scan", with boxes, urgency and a gist), then every item's
    detail and handle in parallel ("item", each as it comes). The image and
    the context come first in every request: the passes share that prefix
    (the provider's prompt cache)."""
    ms = lambda: int((time.monotonic() - started) * 1000)  # noqa: E731
    image = req.get("image") or ""
    w, h = image_size(image)
    if not w:
        emit("error", error="no screenshot to scan")
        emit("done", ms=ms())
        return 1
    lang = LANGS.get(str(req.get("lang") or "en")[:2].lower(), "English")
    shared = mask(SCAN_INTRO.format(w=w, h=h) + "\n\n" + scan_context(req))
    system = SYSTEM.format(lang=lang) + "\n\n" + PRIVACY
    model = p.model(model_alias(req))
    fast = SCAN_FAST.format(kinds="|".join(sorted(SCAN_KINDS)), lang=lang)
    emit("start", provider=p.label, model=model, contextMs=ms())
    nixbook_ai.sent_note("Kiroshi scan (screen)", f"{p.label.lower()}:{model}", shared + "\n\n" + fast)
    with open(image, "rb") as f:
        raw = f.read(IMAGE_MAX + 1)
    if len(raw) > IMAGE_MAX:
        emit("error", error="the screenshot is too big")
        emit("done", ms=ms())
        return 1
    media = "image/jpeg" if raw[:3] == b"\xff\xd8\xff" else "image/png"
    data = base64.b64encode(raw).decode()
    image_block = {"type": "image", "source": {"type": "base64", "media_type": media, "data": data}}

    def ask_model(task, with_image=True, max_tokens=6000):
        text, usage = complete(req, p, system, image_block if with_image else None, [shared, task], max_tokens)
        emit("usage", usage=usage, ms=ms())
        return text

    def brief_pass():
        try:
            d = scan_json(unmask(ask_model(SCAN_BRIEF.format(lang=lang), max_tokens=3000))) or {}
            emit("brief", doing=str(d.get("doing") or "")[:240], focus=str(d.get("focus") or "")[:300], ms=ms())
        except Exception as e:  # noqa: BLE001 — the labels still come
            emit("brief", doing="", focus="", ms=ms(), error=str(e))

    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        brief_job = pool.submit(brief_pass)
        try:
            found = scan_brief(unmask(ask_model(fast)), w, h)
        except Exception as e:  # noqa: BLE001 — the overlay shows it
            brief_job.result()
            emit("error", error=str(e) or e.__class__.__name__)
            emit("done", ms=ms())
            return 1
        if not found or not found["items"]:
            brief_job.result()
            emit("error", error="the model's answer had no labels")
            emit("scan", width=w, height=h, items=[], routine=[], ms=ms())
            emit("done", ms=ms())
            return 1
        emit("scan", width=w, height=h, ms=ms(), **found)
        listing = mask("\n".join(f"{i}. {it['label']} ({it['kind']}, {it['urgency']}, box {it['box']}): {it['gist']}"
                                 for i, it in enumerate(found["items"])))

        def detail(i):
            it = found["items"][i]
            hint = (" You judged it routine: the agent handles it entirely (dismiss the notification, acknowledge, "
                    "file the task…), so give a handle, never null.") if i in found["routine"] else ""
            task = SCAN_ITEM.format(listing=listing, n=i, label=mask(it["label"]), lang=lang, routine=hint)
            try:
                return i, scan_handle(scan_json(unmask(ask_model(task)))), ""
            except Exception as e:  # noqa: BLE001
                return i, {"detail": "", "handle": None}, str(e) or e.__class__.__name__

        jobs = [pool.submit(detail, i) for i in range(len(found["items"]))]
        for fut in concurrent.futures.as_completed(jobs):
            i, got, err = fut.result()
            emit("item", index=i, ms=ms(), error=err, **got)
        brief_job.result()
    emit("done", ms=ms())
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "ask":
        nixbook_ai.ensure_provider(argv[1:], __file__)
        return ask(argv[2])
    if len(argv) == 3 and argv[1] == "learn":
        return learn_command(argv[2])
    if len(argv) == 2 and argv[1] == "learned":
        print(json.dumps(read_learned(), ensure_ascii=False))
        return 0
    if len(argv) == 2 and argv[1] == "modes":
        print(json.dumps(sorted(MODES)))
        return 0
    print("usage: nixbook-quick-ai ask REQUEST.json | learn JSON | learned | modes", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
