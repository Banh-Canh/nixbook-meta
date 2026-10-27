"""nixbook-quick-ai: the instant answers of the shell's Quick AI card (a
selection, the screen, the launcher, a notification). One request, one
answer, no agent: the provider's Messages API called directly with its small
model, so the card answers in a couple of seconds instead of waiting for
Claude Code to start.

Run through `nixbook-model-provider run nixbook-quick-ai ask REQUEST.json`:
with Meta (or another Anthropic-compatible API) the provider's environment
is set (ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, the model names) and the
API is called here; with Anthropic (the user's Claude login, no key) the
answer comes from `claude -p` with the small model instead.

The request (JSON): {mode, question, text, image, context: {app, title,
source}, history: [{role, text}], lang, effort, model: small|main|big,
claude}. The answer, one JSON object per line on stdout:
  {"type": "start", "provider", "model"}
  {"type": "delta", "text"}        (streamed text, when the server streams)
  {"type": "answer", "text"}       (the whole answer, always last)
  {"type": "replies", "replies"}   (mode reply: the suggestions)
  {"type": "error", "error"}
  {"type": "done", "ms"}
Text is masked by nixbook-desktop-mcp's privacy mask (names, emails… →
⟦Person 1⟧) before it leaves, and the answer unmasked; what was sent is
recorded in the desktop-mcp sent log, like every other AI pass.
"""

import json
import re
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import base64

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


def desktop_mcp(*args, data=None, env=None):
    """nixbook-desktop-mcp ARGS (stdin DATA): its stdout, None without it."""
    exe = shutil.which("nixbook-desktop-mcp")
    if not exe:
        return None
    try:
        p = subprocess.run([exe, *args], input=data, capture_output=True, text=True, timeout=30,
                           env={**os.environ, **env} if env else None)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout if p.returncode == 0 else None


def mask(text):
    if not text:
        return text
    out = desktop_mcp("privacy", "mask", data=text)
    return text if out is None else out


def unmask(text):
    if not text or "⟦" not in text:
        return text
    out = desktop_mcp("privacy", "unmask", data=text)
    return text if out is None else out


def build(req):
    """The system prompt and the messages (Anthropic Messages shape, text
    masked), and the prompt as plain text for the record and Claude Code."""
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
    facts = str(req.get("facts") or "").strip()
    if facts and mode in ("do", "ask"):
        parts.append(f"What the desktop knows right now:\n{facts[:2000]}")
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


def model_for(req):
    which = req.get("model") or "small"
    env = os.environ
    main = env.get("ANTHROPIC_MODEL", "")
    return {"small": env.get("ANTHROPIC_DEFAULT_HAIKU_MODEL") or main,
            "big": env.get("ANTHROPIC_DEFAULT_OPUS_MODEL") or main}.get(which, main)


def call_api(req, system, messages, on_delta):
    """The provider's Messages API, streamed. A server that refuses the
    effort settings (not every Anthropic-compatible one has them) is asked
    again without them."""
    base = os.environ["ANTHROPIC_BASE_URL"].rstrip("/")
    key = os.environ["ANTHROPIC_AUTH_TOKEN"]
    model = model_for(req)
    effort = str(req.get("effort") or "low")
    # The OpenAI-style chat endpoint first (Meta's): it takes reasoning_effort
    # "minimal", about 2 s faster than the Messages API's lowest thinking.
    text = chat_answer(req, base, key, model, system, messages, effort)
    if text is not None:
        on_delta(text)
        return model, text
    body = {"model": model, "max_tokens": 4000, "stream": True, "system": system, "messages": messages}
    tuned = {**body, "thinking": {"type": "adaptive"}, "output_config": {"effort": effort}}
    for attempt in (tuned, body):
        r = urllib.request.Request(base + "/v1/messages", data=json.dumps(attempt).encode(), method="POST",
                                   headers={"Authorization": f"Bearer {key}", "anthropic-version": "2023-06-01",
                                            "content-type": "application/json", "accept": "text/event-stream"})
        try:
            with urllib.request.urlopen(r, timeout=90) as resp:
                return model, read_stream(resp, on_delta)
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")
            try:
                d = json.loads(detail)
                detail = (d.get("error") or {}).get("message") or d.get("message") or detail
            except ValueError:
                pass
            if attempt is tuned and e.code == 400 and any(w in detail for w in ("thinking", "effort", "output_config")):
                continue
            raise RuntimeError(f"HTTP {e.code}: {str(detail)[:300]}")
    raise RuntimeError("the server refused the request")


def chat_messages(system, messages):
    """Messages API messages in the OpenAI chat shape (text and base64
    images)."""
    out = [{"role": "system", "content": system}]
    for m in messages:
        c = m["content"]
        if isinstance(c, str):
            out.append({"role": m["role"], "content": c})
            continue
        parts = []
        for b in c:
            if b.get("type") == "text":
                parts.append({"type": "text", "text": b["text"]})
            elif b.get("type") == "image":
                src = b["source"]
                parts.append({"type": "image_url", "image_url": {"url": f"data:{src['media_type']};base64,{src['data']}"}})
        out.append({"role": m["role"], "content": parts})
    return out


def chat_answer(req, base, key, model, system, messages, effort):
    """The answer through /v1/chat/completions, or None when the server has
    no such endpoint (then the Messages API answers)."""
    global CHAT_OK
    if CHAT_OK is False or effort not in ("low", "minimal"):
        return None
    body = {"model": model, "max_completion_tokens": 4000, "reasoning_effort": "minimal",
            "messages": chat_messages(system, messages)}
    r = urllib.request.Request(base + "/v1/chat/completions", data=json.dumps(body).encode(), method="POST",
                               headers={"Authorization": f"Bearer {key}", "content-type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=90) as resp:
            d = json.loads(resp.read().decode())
        text = ((d.get("choices") or [{}])[0].get("message") or {}).get("content")
        if not isinstance(text, str):
            raise ValueError("no choices")
        CHAT_OK = True
        return text
    except urllib.error.HTTPError as e:
        if e.code not in (400, 404, 405, 422):
            raise RuntimeError(f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:300]}")
    except (ValueError, KeyError, IndexError, AttributeError):
        pass
    CHAT_OK = False
    return None


def read_stream(resp, on_delta):
    if "text/event-stream" not in (resp.headers.get("content-type") or ""):
        d = json.loads(resp.read().decode())
        return "".join(b.get("text", "") for b in d.get("content") or [] if b.get("type") == "text")
    text = []
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        try:
            ev = json.loads(line[5:])
        except ValueError:
            continue
        if ev.get("type") == "content_block_delta" and (ev.get("delta") or {}).get("type") == "text_delta":
            piece = ev["delta"].get("text", "")
            text.append(piece)
            on_delta(piece)
        elif ev.get("type") == "error":
            raise RuntimeError(str((ev.get("error") or {}).get("message") or ev))
    return "".join(text)


def call_claude(req, system, prompt):
    """Anthropic: the small model through Claude Code (the user's login),
    no tools but Read for an image, no MCP servers, no session kept."""
    claude = req.get("claude") or shutil.which("claude")
    if not claude:
        raise RuntimeError("Claude Code isn't installed (Settings > Desktop agents)")
    workdir = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "nixbook-shell", "quick-ai")
    os.makedirs(workdir, mode=0o700, exist_ok=True)
    tools = ""
    image = req.get("image")
    if image:
        prompt = f"Read the image {image} first (it is the user's screen).\n\n{prompt}"
        tools = "Read"
    history = "\n\n".join(f"{t.get('role', 'user')}: {t.get('text', '')}" for t in (req.get("history") or [])[-12:])
    if history and req.get("followUp"):
        prompt = f"{prompt}\n\nThe conversation since:\n{mask(history)}"
    cmd = [claude, "-p", "--output-format", "json", "--no-session-persistence", "--strict-mcp-config",
           "--setting-sources", "project", "--tools", tools, "--system-prompt", system,
           "--model", "sonnet" if req.get("model") == "main" else "haiku"]
    if tools:
        cmd += ["--allowedTools", tools, "--add-dir", os.path.dirname(image)]
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, cwd=workdir, timeout=180)
    try:
        out = json.loads(p.stdout)
    except ValueError:
        raise RuntimeError((p.stderr or p.stdout or "Claude Code failed").strip()[:300])
    if out.get("is_error"):
        raise RuntimeError(str(out.get("result") or "Claude Code failed")[:300])
    return "claude-haiku", str(out.get("result") or "")


# ── Doing things: the desktop tools (nixbook-desktop-mcp), called by the
# model itself. The guardrails are desktop-mcp's own (the pause, the tool
# groups, no terminals or password managers, the audit log); the card asks
# before a step that destroys something (a window closed, an event
# deleted), or before every acting step with confirm "actions".
# Every desktop tool the user has enabled (desktop-mcp's tool groups): the
# agent has the same hands and eyes as Claude in the side panel. None left
# out but the agent desktop's switch (Full AI works on the user's desktop).
AGENT_SKIP = {"desktop"}
AGENT_SYSTEM = (
    "You run the user's desktop for them (nixbook: NixOS, the niri scrolling compositor, its own shell). They "
    "talk to you instead of clicking, so you must be at least as fast as doing it by hand: act at once with the "
    "fewest tool calls (several independent calls in one turn), never ask \"shall I?\" (the user's bubble asks "
    "them before anything destructive), never explain what you are about to do. When you changed anything, end "
    "with a report for the user, exactly: <report>{{\"summary\": \"one line: the outcome\", \"done\": [\"each thing "
    "you did, with its result, one line each (\\\"Dismissed 12 Spotify notifications\\\")\"], \"failed\": [\"what didn't "
    "work, and why\"], \"needs_you\": [\"what only the user can do or decide now\"]}}</report>, nothing after it; "
    "empty lists are fine, never invent results. A question with no change: just answer it in two or three "
    "sentences, no report, with tools only if it is about their desktop or data. What the desktop already knows "
    "comes with the request (time, weather, battery, next events, music): answer from it directly, no tool. Never "
    "open panels, take screenshots or poke around to find information: use the tool made for it, or say you can't "
    "tell. Media and volume: shell_ipc (target mpris: playPause, next, previous; target audio or brightness when "
    "listed by shell_ipc_list). The user's apps' own tools are yours too, named app__tool (youtube-music__play, "
    "spotify__search, phone__send_sms…): use them before clicking in the app. Music: play/pause only resumes what "
    "is loaded, and does nothing when the song has ended or nothing is loaded; to start music (a song, an artist, "
    "\"some music\", or when play/pause didn't take) use the music app's play tool (ask it what is playing first "
    "if unsure). Bigger apps' tools come with open_app_tools. Keep learning: when the user states a lasting preference or a standing order "
    "(\"always…\", \"never…\", \"when X happens, do Y\"), save it at once (a routine for \"when X, do Y\", "
    "remember_about_user for what they like and who matters to them) and say you will. You only have the tools listed to you (the server's instructions below may name "
    "others): you can't see images, so read the screen with read_screen. Answer in the language the user writes "
    "or speaks in ({lang} when it isn't clear)."
)
AGENT_STEPS = 10


# The user's apps' tools (the side panel's MCP servers, through
# `nixbook-desktop-mcp app-tools` / `app-call`): those of a small server
# (APP_SMALL tools or fewer: music, the phone) are given up front, a bigger
# one's (photos: ~90) when the request names it or the model asks for them
# (open_app_tools), so every request doesn't carry them all.
APP_SMALL = 12
APP_SEP = "__"
# Few servers annotate their tools: these names only read.
APP_READS = re.compile(r"(get|list|search|find|show|read|now_playing|my_|status|devices|ping|info)", re.I)


def app_tool_name(server, tool):
    return re.sub(r"[^A-Za-z0-9_-]", "_", f"{server}{APP_SEP}{tool}")[:64]


def app_specs(servers, only=None):
    specs, meta = [], {}
    for server, info in servers.items():
        if only is not None and server not in only:
            continue
        for t in info.get("tools") or []:
            name = app_tool_name(server, str(t.get("name") or ""))
            schema = {k: v for k, v in (t.get("inputSchema") or {"type": "object", "properties": {}}).items()
                      if k != "$schema"}
            schema.setdefault("type", "object")
            specs.append({"name": name, "description": f"[{server}] " + str(t.get("description") or "")[:2000],
                          "input_schema": schema})
            ann = t.get("annotations") or {}
            reads = bool(ann.get("readOnlyHint")) or bool(APP_READS.match(str(t.get("name") or "")))
            meta[name] = {"group": "app", "server": server, "tool": t.get("name"), "shown": f"{server}: {t.get('name')}",
                          "read_only": reads, "destructive": bool(ann.get("destructiveHint"))}
    return specs, meta


def app_servers():
    out = desktop_mcp("app-tools")
    try:
        servers = json.loads(out or "{}")
        return servers if isinstance(servers, dict) else {}
    except ValueError:
        return {}


def open_app_tools_spec(big):
    lines = [f"{n}: {', '.join(str(t.get('name')) for t in (i.get('tools') or [])[:12])}…" for n, i in big.items()]
    return {"name": "open_app_tools",
            "description": "Get the tools of one of the user's bigger apps, to use them in your next steps: "
                           + "; ".join(lines),
            "input_schema": {"type": "object", "properties": {"server": {"type": "string", "enum": sorted(big)}},
                             "required": ["server"]}}


def agent_tools():
    """The tools' specs in the Messages API shape, and their groups/hints."""
    out = desktop_mcp("tools")
    if out is None:
        raise RuntimeError("the desktop tools (nixbook-desktop-mcp) aren't available")
    specs, meta = [], {}
    for t in json.loads(out):
        if t.get("name") in AGENT_SKIP:
            continue
        schema = dict(t.get("inputSchema") or {"type": "object", "properties": {}})
        # desktop-mcp's after-action extras: not for this loop.
        props = {k: v for k, v in (schema.get("properties") or {}).items() if k not in ("screenshot_after", "wait_ms")}
        schema["properties"] = props
        # Whole: the long ones (calendar, widget, contacts…) say how to use them.
        specs.append({"name": t["name"], "description": str(t.get("description") or "")[:4000], "input_schema": schema})
        ann = t.get("annotations") or {}
        meta[t["name"]] = {"group": (t.get("_meta") or {}).get("nixbook/group", ""),
                           "read_only": bool(ann.get("readOnlyHint")), "destructive": bool(ann.get("destructiveHint"))}
    return specs, meta


# The tools that both read and write (calendar, tasks, contacts, widget,
# equalizer, layouts…) say which with their `action`: these only read.
READ_ACTIONS = {"list", "lists", "upcoming", "get", "search", "find", "show", "status", "layout", "day", "events",
                "read", "next", "agenda", "info", "count", "check", "history"}


def reads_only(name, args, meta):
    if meta.get(name, {}).get("read_only"):
        return True
    action = str((args or {}).get("action") or "").lower()
    return action in READ_ACTIONS


def needs_ok(req, name, args, meta):
    m = meta.get(name, {})
    confirm = str(req.get("confirm") or "destructive")
    if reads_only(name, args, meta) or confirm == "never":
        return False
    if confirm == "actions":
        return True
    if m.get("destructive"):
        return True
    # Removing data through the generic tools.
    return name in ("calendar", "tasks", "contacts") and str(args.get("action", "")).lower() in ("delete", "remove")


def run_tool(name, args, info=None):
    """A desktop tool, or an app's (info: its server): (its text, failed, the
    tool_result content: text and images, so the model sees a screenshot)."""
    exe = shutil.which("nixbook-desktop-mcp")
    env = {**os.environ, "NIXBOOK_DESKTOP_MCP_CLIENT": "Quick AI"}
    for k in ("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"):
        env.pop(k, None)
    cmd = [exe, "app-call", info["server"], str(info["tool"]), json.dumps(args)] if (info or {}).get("server") else \
        [exe, "call", name, json.dumps(args), "--json"]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=120, env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"error: {e}", True, f"error: {e}"
    failed = p.returncode != 0
    try:
        items = json.loads(p.stdout)
        if not isinstance(items, list):
            raise ValueError
    except ValueError:
        out = (p.stdout or "").strip() or (p.stderr or "").strip() or ("done" if not failed else "failed")
        return out[:6000], failed, out[:6000]
    texts, blocks = [], []
    for c in items:
        if c.get("type") == "text":
            texts.append(str(c.get("text", "")))
        elif c.get("type") == "image" and c.get("data"):
            blocks.append({"type": "image", "source": {"type": "base64", "media_type": c.get("mimeType") or "image/png",
                                                        "data": c["data"]}})
    out = "\n".join(texts).strip()[:6000] or ("done" if not failed else "failed")
    return out, failed, ([{"type": "text", "text": out}] + blocks[:2]) if blocks else out


def step_summary(name, args):
    keys = ("app", "name", "id", "index", "workspace", "text", "title", "body", "message", "query", "target",
            "function", "theme", "variant", "action", "keys", "path")
    bits = [f"{k}={str(args[k])[:40]}" for k in keys if k in args]
    return ", ".join(bits)[:120]


def post(req, body):
    """One non-streamed Messages API call (the effort settings dropped if
    the server refuses them)."""
    base = os.environ["ANTHROPIC_BASE_URL"].rstrip("/")
    key = os.environ["ANTHROPIC_AUTH_TOKEN"]
    tuned = {**body, "thinking": {"type": "adaptive"}, "output_config": {"effort": str(req.get("effort") or "low")}}
    for attempt in (tuned, body):
        r = urllib.request.Request(base + "/v1/messages", data=json.dumps(attempt).encode(), method="POST",
                                   headers={"Authorization": f"Bearer {key}", "anthropic-version": "2023-06-01",
                                            "content-type": "application/json"})
        try:
            with urllib.request.urlopen(r, timeout=120) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")
            try:
                d = json.loads(detail)
                detail = (d.get("error") or {}).get("message") or d.get("message") or detail
            except ValueError:
                pass
            if attempt is tuned and e.code == 400 and any(w in detail for w in ("thinking", "effort", "output_config")):
                continue
            raise RuntimeError(f"HTTP {e.code}: {str(detail)[:300]}")
    raise RuntimeError("the server refused the request")


# This run's steps ({tool, summary, status, result, read_only}), by id:
# what the report says was done comes from them, not only from the model.
RUN_STEPS = {}


def note_step(step_id, tool, summary, status, result="", read_only=False):
    RUN_STEPS[step_id] = {"tool": tool, "summary": summary, "status": status, "result": result, "read_only": read_only}


def step_line(s):
    line = s["tool"].replace("_", " ") + (f" ({s['summary']})" if s.get("summary") else "")
    if s["status"] == "denied":
        return line + ": you said no"
    if s["status"] == "error" and s.get("result"):
        return line + ": " + str(s["result"]).strip().splitlines()[0][:160]
    return line


def build_report(text):
    """The answer and, when the agent changed something, its report: the
    model's own (<report>{…}</report>) where it gave one, the steps that
    failed added when it left them out. None for a plain answer."""
    import re as _re
    m = _re.search(r"<report>\s*(\{.*?\})\s*</report>", text, _re.S)
    model = {}
    if m:
        try:
            model = json.loads(m.group(1))
        except ValueError:
            model = {}
        text = (text[:m.start()] + text[m.end():]).strip()
    steps = list(RUN_STEPS.values())
    acted = [s for s in steps if not s["read_only"]]
    if not acted and not model:
        return text, None
    lst = lambda k: [str(x).strip() for x in (model.get(k) or []) if str(x).strip()][:12]  # noqa: E731
    done, failed, needs = lst("done"), lst("failed"), lst("needs_you")
    bad = [s for s in steps if s["status"] in ("error", "denied")]
    if bad and not failed:
        failed = [step_line(s) for s in bad][:8]
    if not done:
        done = [step_line(s) for s in acted if s["status"] == "ok"][:12]
    summary = str(model.get("summary") or "").strip() or (text.splitlines()[0] if text else "") or \
        ("Done." if not bad else "Done, with problems.")
    report = {"summary": summary, "done": done, "failed": failed, "needsYou": needs, "steps": len(steps),
              "ok": sum(1 for s in steps if s["status"] == "ok"), "ko": len(bad)}
    parts = [summary]
    parts += [f"- ✓ {d}" for d in done] + [f"- ✗ {f}" for f in failed] + [f"- → {n}" for n in needs]
    return "\n".join(parts), report


def tool_instructions(req):
    """desktop-mcp's own instructions, as an MCP client gets them at
    initialize: how to use its tools, and the desktop memory (aliases,
    notes, recipes) for this task."""
    query = str(req.get("followUp") or req.get("question") or "")[:500]
    out = desktop_mcp("instructions", env={"NIXBOOK_DESKTOP_MCP_QUERY": query, "NIXBOOK_DESKTOP_MCP_CLIENT": "Quick AI"})
    return (out or "").strip()[:8000]


ASK_CLAUDE = {
    "name": "ask_claude",
    "description": "Hand the task over to Claude, the user's full assistant, when it needs what you don't have: "
                   "searching the web, reading or writing the user's files, their mail or calendar accounts "
                   "(connectors), other MCP servers, long work. The conversation goes on there (it sees what was "
                   "said). Give the complete task with everything you already know; don't use it for what your "
                   "own tools do.",
    "input_schema": {"type": "object", "properties": {"task": {"type": "string"}}, "required": ["task"]},
}


def machine_context():
    """The shell's own reference about this machine (system-context.md, made
    by the Home Manager module): the parts that help acting on it (the
    machine, the shell, how things are done), not the package lists."""
    path = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                        "nixbook-shell", "system-context.md")
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return ""
    keep, out = False, []
    for line in text.splitlines():
        if line.startswith("## "):
            keep = any(w in line for w in ("This machine", "Desktop shell", "How things are done", "Keyboard shortcuts (niri"))
        if keep:
            out.append(line)
    return ("About this machine:\n" + "\n".join(out))[:14000] if out else ""


def agent(req, system, messages):
    """The model with the desktop tools, up to AGENT_STEPS rounds. Each
    call is a "step" event; one needing the user's OK an "approve" event,
    answered by a line on stdin (yes / no)."""
    specs, meta = agent_tools()
    # What the side panel's Claude starts with (Ai.stableSystemPrompt: the
    # configured prompt, this machine's whole reference and the shell's live
    # settings, when ai.includeSystemContext): the same knowledge. It comes
    # first and is cached (it changes rarely): the next calls read it from
    # the provider's cache instead of paying ~0.5 s each for its tokens.
    panel = str(req.get("panel") or "").strip() if "panel" in req else machine_context()
    stable = f"{system}\n\n{mask(panel)}" if panel else system
    system = ""
    told = tool_instructions(req)
    if told:
        system = ("The desktop tools' own instructions (from their server: with the desktop memory and what "
                  f"agents remember about the user, for this task):\n{mask(told)}")
    # The apps' tools: the small servers', and a big one's when it is named.
    apps = app_servers()
    asked = str(req.get("followUp") or req.get("question") or "").lower()
    up_front = {n for n, i in apps.items() if len(i.get("tools") or []) <= APP_SMALL
                or n.lower().replace("-", " ") in asked.replace("-", " ")}
    more, more_meta = app_specs(apps, up_front)
    specs, meta = specs + more, {**meta, **more_meta}
    big = {n: i for n, i in apps.items() if n not in up_front}
    if big:
        specs = specs + [open_app_tools_spec(big)]
    hints = [f"{n}: {i['instructions'][:400]}" for n, i in apps.items() if n in up_front and i.get("instructions")]
    if hints:
        system = f"{system}\n\nThe apps' own instructions:\n" + "\n".join(hints)
    if req.get("activity"):
        system = f"{system}\n\nWhat the user did just before (most recent last):\n{mask(str(req['activity'])[-3000:])}"
    system = [{"type": "text", "text": stable, "cache_control": {"type": "ephemeral"}}] + (
        [{"type": "text", "text": system.strip()}] if system.strip() else [])
    # Claude Code, the whole assistant (web, files, the user's mail and
    # calendar connectors, other MCP servers): the task handed over, the
    # conversation going on there.
    if req.get("claude") and req.get("delegate", True):
        specs = specs + [ASK_CLAUDE]
    model = model_for(req)
    said = []
    for _ in range(AGENT_STEPS):
        d = post(req, {"model": model, "max_tokens": 6000, "system": system, "messages": messages, "tools": specs})
        content = [b for b in d.get("content") or [] if b.get("type") in ("text", "tool_use")]
        texts = [b["text"] for b in content if b["type"] == "text" and b.get("text", "").strip()]
        calls = [b for b in content if b["type"] == "tool_use"]
        if texts and calls:
            emit("note", text=unmask(" ".join(texts)))
        if not calls:
            said = texts
            break
        handoff = next((c for c in calls if c.get("name") == "ask_claude"), None)
        if handoff:
            task = str((handoff.get("input") or {}).get("task") or "").strip()
            emit("delegate", task=unmask(task))
            said = [" ".join(texts) or "Asking Claude…"]
            break
        messages.append({"role": "assistant", "content": content})
        results = []
        for c in calls:
            name, args = c.get("name", ""), c.get("input") or {}
            shown = unmask(step_summary(name, args))
            label = meta.get(name, {}).get("shown") or name
            if needs_ok(req, name, args, meta):
                emit("approve", id=c["id"], tool=label, summary=shown, args=json.loads(unmask(json.dumps(args, ensure_ascii=False))))
                answer = sys.stdin.readline().strip().lower()
                if answer not in ("y", "yes", "ok"):
                    note_step(c["id"], label, shown, "denied", read_only=reads_only(name, args, meta))
                    emit("step", id=c["id"], tool=label, summary=shown, status="denied")
                    results.append({"type": "tool_result", "tool_use_id": c["id"], "is_error": True,
                                    "content": "the user said no: don't do it, don't retry it another way"})
                    continue
            if name == "open_app_tools":
                server = str(args.get("server") or "")
                if server in big:
                    extra, extra_meta = app_specs({server: big.pop(server)})
                    specs = [t for t in specs if t["name"] != "open_app_tools"] + extra + (
                        [open_app_tools_spec(big)] if big else [])
                    meta.update(extra_meta)
                    out = f"{server}'s tools are yours now: " + ", ".join(t["name"] for t in extra)
                else:
                    out = f"no such app: {server}"
                note_step(c["id"], name, server, "ok", out[:300], True)
                results.append({"type": "tool_result", "tool_use_id": c["id"], "content": out})
                continue
            emit("step", id=c["id"], tool=label, summary=shown, status="run")
            out, failed, result = run_tool(name, args, meta.get(name))
            emit("step", id=c["id"], tool=label, summary=shown, status="error" if failed else "ok",
                 result=unmask(out[:300]))
            note_step(c["id"], label, shown, "error" if failed else "ok", unmask(out[:300]),
                      reads_only(name, args, meta))
            if failed and "desktop control is paused" in out:
                emit("paused")
            results.append({"type": "tool_result", "tool_use_id": c["id"], "content": result, "is_error": failed})
        messages.append({"role": "user", "content": results})
    else:
        # Out of steps: an answer all the same, from what it has, no more tools.
        messages.append({"role": "user", "content": "Stop using tools now. Answer the user from what you found, "
                         "and say plainly what you couldn't do."})
        said = []
        try:
            d = post(req, {"model": model, "max_tokens": 3000, "system": system, "messages": messages,
                           "tools": specs, "tool_choice": {"type": "none"}})
            said = [b["text"] for b in d.get("content") or [] if b.get("type") == "text" and b.get("text", "").strip()]
        except RuntimeError:
            pass
        if not said:
            said = [f"I stopped after {AGENT_STEPS} steps without finishing."]
    learn_episode(req)
    return model, "\n".join(said)


def learn_episode(req):
    """What this task did, to the desktop memory's learning pass, as the side
    panel's desktop MCP session does when a task ends: the notes that helped
    counted, a new way of doing something that took work saved as a note or
    a recipe. In the background: the answer waits for nothing."""
    steps = [s for s in RUN_STEPS.values() if s["status"] in ("ok", "error")]
    if not any(not s["read_only"] for s in steps):
        return
    exe = shutil.which("nixbook-desktop-mcp")
    if not exe:
        return
    episode = {"task": unmask(str(req.get("followUp") or req.get("question") or ""))[:500],
               "actions": [{"tool": s["tool"], "do": s.get("summary") or "",
                            "error": str(s["result"])[:160] if s["status"] == "error" else None} for s in steps]}
    try:
        p = subprocess.Popen([exe, "episode", "-"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True, start_new_session=True,
                             env={**os.environ, "NIXBOOK_DESKTOP_MCP_CLIENT": "Quick AI"})
        p.stdin.write(json.dumps(episode, ensure_ascii=False))
        p.stdin.close()
    except OSError:
        pass


def agent_claude(req, system, prompt):
    """Anthropic: Claude Code (Haiku) with nixbook-desktop-mcp as its MCP
    server, only the steps that need no OK allowed; its tool calls are
    streamed as steps."""
    claude = req.get("claude") or shutil.which("claude")
    if not claude:
        raise RuntimeError("Claude Code isn't installed (Settings > Desktop agents)")
    if req.get("panel"):
        system = f"{system}\n\n{mask(str(req['panel']))}"
    specs, meta = agent_tools()
    allowed = ",".join(f"mcp__desktop__{t['name']}" for t in specs if not needs_ok(req, t["name"], {}, meta))
    workdir = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "nixbook-shell", "quick-ai")
    os.makedirs(workdir, mode=0o700, exist_ok=True)
    mcp = json.dumps({"mcpServers": {"desktop": {"command": shutil.which("nixbook-desktop-mcp"), "args": [],
                                                 "env": {"NIXBOOK_DESKTOP_MCP_CLIENT": "Quick AI"}}}})
    cmd = [claude, "-p", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
           "--strict-mcp-config", "--mcp-config", mcp, "--setting-sources", "project", "--tools", "",
           "--allowedTools", allowed, "--system-prompt", system, "--model", "haiku"]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=workdir)
    p.stdin.write(prompt)
    p.stdin.close()
    result, names = "", {}
    for line in p.stdout:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        for b in ((ev.get("message") or {}).get("content") or []) if isinstance(ev.get("message"), dict) else []:
            if b.get("type") == "tool_use":
                name = str(b.get("name", "")).removeprefix("mcp__desktop__")
                names[b.get("id")] = (name, step_summary(name, b.get("input") or {}))
                emit("step", id=b.get("id"), tool=name, summary=names[b.get("id")][1], status="run")
            elif b.get("type") == "tool_result" and b.get("tool_use_id") in names:
                name, shown = names[b["tool_use_id"]]
                emit("step", id=b["tool_use_id"], tool=name, summary=shown, status="error" if b.get("is_error") else "ok")
                content = b.get("content")
                result = content if isinstance(content, str) else " ".join(
                    str(x.get("text", "")) for x in content or [] if isinstance(x, dict))
                note_step(b["tool_use_id"], name, shown, "error" if b.get("is_error") else "ok", result[:300],
                          meta.get(name, {}).get("read_only", False))
        if ev.get("type") == "result":
            if ev.get("is_error"):
                raise RuntimeError(str(ev.get("result") or "Claude Code failed")[:300])
            result = str(ev.get("result") or "")
    p.wait(timeout=30)
    return "claude-haiku", result


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
    the user's answer; {pref: text} a preference; {forget: true} all gone."""
    try:
        item = json.loads(raw)
    except ValueError:
        print("learn: JSON expected", file=sys.stderr)
        return 2
    d = read_learned()
    if item.get("forget") is True:
        write_learned({})
        return 0
    if item.get("pref"):
        prefs = [p for p in d.get("prefs") or [] if p.get("text") != item["pref"]]
        prefs.append({"text": str(item["pref"])[:300], "t": int(time.time())})
        d["prefs"] = prefs[-60:]
    if item.get("decision"):
        sig = item.get("sig") or event_sig(item.get("event") or {})
        rec = {"sig": sig, "t": int(time.time()), "decision": item["decision"], "outcome": item.get("outcome", ""),
               "said": str(item.get("said") or "")[:200]}
        d["reactions"] = ((d.get("reactions") or []) + [rec])[-400:]
    write_learned(d)
    return 0


def react(req, started, api, provider):
    ev = req.get("event") or {}
    lang = LANGS.get(str(req.get("lang") or "en")[:2].lower(), "English")
    d = read_learned()
    past, prefs = learned_for(ev, d)
    parts = ["What happened: " + json.dumps({k: v for k, v in ev.items() if v not in ("", None)}, ensure_ascii=False)]
    if req.get("facts"):
        parts.append("What the desktop knows right now:\n" + str(req["facts"])[:1500])
    if req.get("recent"):
        parts.append("The conversation with the user so far (what they told you):\n" + str(req["recent"])[-2500:])
    if past:
        parts.append("Your past reactions to the same kind of thing and what the user answered:\n" + "\n".join(
            f"- {time.strftime('%d %b', time.localtime(r.get('t', 0)))}: you {r.get('decision')}, "
            f"the user {r.get('outcome') or 'said nothing'}{': ' + r['said'] if r.get('said') else ''}" for r in past))
    if prefs:
        parts.append("What the user prefers (learned):\n" + "\n".join("- " + p.get("text", "") for p in prefs))
    told = tool_instructions({"question": f"{ev.get('app', '')} {ev.get('title', '')} {ev.get('text', '')}"})
    if told:
        parts.append("Notes from the desktop memory:\n" + told[-3000:])
    prompt = mask("\n\n".join(parts))
    system = REACT_SYSTEM.format(lang=lang) + "\n\n" + PRIVACY
    emit("start", provider=provider, model=model_for(req) if api else "haiku")
    desktop_mcp("sent", "note", "Full AI: a reaction", prompt, (f"{provider.lower()}:" if api else "") +
                (model_for(req) if api else "haiku"))
    try:
        if api:
            base, key = os.environ["ANTHROPIC_BASE_URL"].rstrip("/"), os.environ["ANTHROPIC_AUTH_TOKEN"]
            messages = [{"role": "user", "content": prompt}]
            text = chat_answer(req, base, key, model_for(req), system, messages, "low")
            if text is None:
                d2 = post(req, {"model": model_for(req), "max_tokens": 2000, "system": system, "messages": messages})
                text = "".join(b.get("text", "") for b in d2.get("content") or [] if b.get("type") == "text")
        else:
            _, text = call_claude(req, system, prompt)
    except Exception as e:  # noqa: BLE001
        emit("error", error=str(e))
        emit("done", ms=int((time.monotonic() - started) * 1000))
        return 1
    m = re.search(r"\{.*\}", unmask(text), re.S)
    try:
        decision = json.loads(m.group(0)) if m else {}
    except ValueError:
        decision = {}
    action = decision.get("action") if decision.get("action") in ("ignore", "tell", "ask", "do") else "ignore"
    basis = decision.get("basis") if decision.get("basis") in ("told", "learned", "guess") else "guess"
    # Acting alone: only on what it was told, or what the user chose at
    # least twice before for this kind of thing; else it asks.
    if action == "do":
        agreed = sum(1 for r in past if r.get("outcome") in ("agreed", "did it") and r.get("decision") in ("ask", "do"))
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
    api = bool(os.environ.get("ANTHROPIC_BASE_URL") and os.environ.get("ANTHROPIC_AUTH_TOKEN"))
    provider = os.environ.get("NIXBOOK_PROVIDER_LABEL") or ("Meta" if "meta.ai" in os.environ.get("ANTHROPIC_BASE_URL", "") else
                                                            "API" if api else "Claude")
    if req.get("mode") == "scan":
        return scan(req, started, api, provider)
    if req.get("mode") == "react":
        return react(req, started, api, provider)
    try:
        mode, system, messages, prompt = build(req)
        emit("start", provider=provider, model=model_for(req) if api else "haiku")
        purpose = f"Quick AI: {mode}" + (" (screen)" if req.get("image") else "")
        desktop_mcp("sent", "note", purpose, prompt, (f"{provider.lower()}:" if api else "") + (model_for(req) if api else "haiku"))
        if mode == "do":
            lang = LANGS.get(str(req.get("lang") or "en")[:2].lower(), "English")
            dsystem = AGENT_SYSTEM.format(lang=lang) + "\n\n" + PRIVACY
            if api:
                _, text = agent(req, dsystem, messages)
            else:
                _, text = agent_claude(req, dsystem, prompt)
            text, report = build_report(unmask(text))
            if report:
                emit("report", **report)
        elif api:
            # Replies come as JSON: only the suggestions are shown.
            stream = (lambda piece: None) if mode == "reply" else (lambda piece: emit("delta", text=unmask(piece)))
            _, text = call_api(req, system, messages, stream)
        else:
            _, text = call_claude(req, system, prompt)
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
    exe = shutil.which("nixbook-desktop-mcp")
    if not exe:
        return ""
    env = {**os.environ, "NIXBOOK_DESKTOP_MCP_CLIENT": "Kiroshi scan"}
    for k in ("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"):
        env.pop(k, None)
    try:
        p = subprocess.run([exe, *args], capture_output=True, text=True, timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return (p.stdout or "").strip() if p.returncode == 0 else ""


def scan_context(req):
    """What the user is doing, as text for the prompt (masked later with it).
    The accessibility tree and the recent-activity filter run in parallel."""
    import concurrent.futures
    ctx = req.get("context") or {}
    recent = req.get("recent") or []
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        ui = pool.submit(quick_call, ["call", "ui_read", "{}"], 3)
        filtered = pool.submit(quick_call, ["context", json.dumps({"now": int(time.time()), "events": recent[-40:]})], 3) \
            if recent else None
        ui_text, recent_text = ui.result()[:2500], (filtered.result()[:1500] if filtered else "")
    parts = [f"Now: {ctx.get('now') or time.strftime('%a %d %b %Y %H:%M')}"]
    where = " — ".join(str(ctx[k]) for k in ("app", "title") if ctx.get(k))
    if where:
        parts.append(f"Focused window: {where}")
    wins = [f"- {w.get('app', '')} — {str(w.get('title', ''))[:90]}" for w in (req.get("windows") or [])[:10]]
    if wins:
        parts.append("Open windows (last used first):\n" + "\n".join(wins))
    if recent_text:
        parts.append(f"What they did the last minutes:\n{recent_text}")
    notes = []
    for n in (req.get("notifications") or [])[:8]:
        body = " ".join(str(n.get("body") or "").split())[:220]
        notes.append(f"- [{n.get('time', '')}] {n.get('app', '')} · {n.get('summary', '')}: {body}")
    if notes:
        parts.append("Latest notifications (newest first):\n" + "\n".join(notes))
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


def complete(req, system, image_block, image_url, parts, max_tokens):
    """One answer from the provider, as fast as it goes: its OpenAI-style
    chat endpoint first when it has one (Meta's takes reasoning_effort
    "minimal", which the Messages API can't ask for: half the thinking),
    else the Messages API. Returns (text, usage)."""
    global CHAT_OK
    base = os.environ["ANTHROPIC_BASE_URL"].rstrip("/")
    key = os.environ["ANTHROPIC_AUTH_TOKEN"]
    model = model_for(req)
    if CHAT_OK is not False and str(req.get("scanEffort") or "minimal") == "minimal":
        content = ([{"type": "image_url", "image_url": {"url": image_url}}] if image_url else []) + \
            [{"type": "text", "text": t} for t in parts]
        body = {"model": model, "max_completion_tokens": max_tokens, "reasoning_effort": "minimal",
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": content}]}
        r = urllib.request.Request(base + "/v1/chat/completions", data=json.dumps(body).encode(), method="POST",
                                   headers={"Authorization": f"Bearer {key}", "content-type": "application/json"})
        try:
            with urllib.request.urlopen(r, timeout=120) as resp:
                d = json.loads(resp.read().decode())
            CHAT_OK = True
            return str(((d.get("choices") or [{}])[0].get("message") or {}).get("content") or ""), d.get("usage") or {}
        except urllib.error.HTTPError as e:
            if CHAT_OK or e.code not in (400, 404, 405, 422):
                raise RuntimeError(f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:300]}")
            CHAT_OK = False
        except (ValueError, KeyError, IndexError):
            CHAT_OK = False
    content = ([image_block] if image_block else []) + [{"type": "text", "text": t} for t in parts]
    d = post(req, {"model": model, "max_tokens": max_tokens, "system": system,
                   "messages": [{"role": "user", "content": content}]})
    return "".join(b.get("text", "") for b in d.get("content") or [] if b.get("type") == "text"), d.get("usage") or {}


CHAT_OK = None


def scan(req, started, api, provider):
    """Three kinds of passes, the first two at once: the brief's two lines
    (emitted as "brief" in ~3 s), what is on the screen
    (the image: "scan", with boxes, urgency and a gist), then every item's
    detail and handle in parallel ("item", each as it comes). The image and
    the context come first in every request: the passes share that prefix
    (the provider's prompt cache)."""
    import concurrent.futures
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
    model = model_for(req) if api else "haiku"
    fast = SCAN_FAST.format(kinds="|".join(sorted(SCAN_KINDS)), lang=lang)
    emit("start", provider=provider, model=model, contextMs=ms())
    desktop_mcp("sent", "note", "Kiroshi scan (screen)", shared + "\n\n" + fast,
                (f"{provider.lower()}:" if api else "") + model)
    image_block = image_url = None
    if api:
        with open(image, "rb") as f:
            raw = f.read(IMAGE_MAX + 1)
        if len(raw) > IMAGE_MAX:
            emit("error", error="the screenshot is too big")
            emit("done", ms=ms())
            return 1
        media = "image/jpeg" if raw[:3] == b"\xff\xd8\xff" else "image/png"
        data = base64.b64encode(raw).decode()
        image_block = {"type": "image", "source": {"type": "base64", "media_type": media, "data": data}}
        image_url = f"data:{media};base64,{data}"

    def ask_model(task, with_image=True, max_tokens=6000):
        if not api:
            return call_claude(req if with_image else {**req, "image": ""}, system, shared + "\n\n" + task)[1]
        text, usage = complete(req, system, image_block if with_image else None, image_url if with_image else None,
                               [shared, task], max_tokens)
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
