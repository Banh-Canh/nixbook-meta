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
    "preamble, no closing offer. Plain text or light Markdown (short lists, `code`). Answer in {lang} "
    "unless the task says otherwise."
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


def desktop_mcp(*args, data=None):
    """nixbook-desktop-mcp ARGS (stdin DATA): its stdout, None without it."""
    exe = shutil.which("nixbook-desktop-mcp")
    if not exe:
        return None
    try:
        p = subprocess.run([exe, *args], input=data, capture_output=True, text=True, timeout=30)
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
AGENT_TOOLS = [
    "list_windows", "list_workspaces", "system_info", "list_apps", "launch_app", "focus_window", "close_window",
    "focus_workspace", "move_window_to_workspace", "window_action", "save_layout", "list_layouts", "restore_layout",
    "read_screen", "clipboard_get", "clipboard_set", "notifications", "type_text", "press_keys", "run_steps",
    "shell_ipc", "shell_ipc_list", "list_themes", "set_theme", "set_wallpaper", "widget", "equalizer", "calendar",
    "tasks", "contacts", "notify", "ui_read", "ui_act", "remind", "recall", "screen_capture",
]
AGENT_SYSTEM = (
    "You run the user's desktop for them (nixbook: NixOS, the niri scrolling compositor, its own shell). They "
    "talk to you instead of clicking, so you must be at least as fast as doing it by hand: act at once with the "
    "fewest tool calls (several independent calls in one turn), never ask \"shall I?\" (the user's card asks "
    "them before anything destructive), never explain what you are about to do. When done, one short sentence "
    "of what changed (\"Firefox is open on workspace 3.\"). A question: answer it in two or three sentences, "
    "with tools only if it is about their desktop or data. Media and volume: shell_ipc (target mpris: "
    "playPause, next, previous; target audio or brightness when listed by shell_ipc_list). Answer in {lang}."
)
AGENT_STEPS = 10


def agent_tools():
    """The tools' specs in the Messages API shape, and their groups/hints."""
    out = desktop_mcp("tools")
    if out is None:
        raise RuntimeError("the desktop tools (nixbook-desktop-mcp) aren't available")
    specs, meta = [], {}
    for t in json.loads(out):
        if t.get("name") not in AGENT_TOOLS:
            continue
        schema = dict(t.get("inputSchema") or {"type": "object", "properties": {}})
        # desktop-mcp's after-action extras: not for this loop.
        props = {k: v for k, v in (schema.get("properties") or {}).items() if k not in ("screenshot_after", "wait_ms")}
        schema["properties"] = props
        specs.append({"name": t["name"], "description": str(t.get("description") or "")[:600], "input_schema": schema})
        ann = t.get("annotations") or {}
        meta[t["name"]] = {"group": (t.get("_meta") or {}).get("nixbook/group", ""),
                           "read_only": bool(ann.get("readOnlyHint")), "destructive": bool(ann.get("destructiveHint"))}
    return specs, meta


def needs_ok(req, name, args, meta):
    m = meta.get(name, {})
    confirm = str(req.get("confirm") or "destructive")
    if m.get("read_only") or confirm == "never":
        return False
    if confirm == "actions":
        return True
    if m.get("destructive"):
        return True
    # Removing data through the generic tools.
    return name in ("calendar", "tasks", "contacts") and str(args.get("action", "")).lower() in ("delete", "remove")


def run_tool(name, args):
    exe = shutil.which("nixbook-desktop-mcp")
    env = {**os.environ, "NIXBOOK_DESKTOP_MCP_CLIENT": "Quick AI"}
    for k in ("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"):
        env.pop(k, None)
    try:
        p = subprocess.run([exe, "call", name, json.dumps(args)], capture_output=True, text=True, timeout=120, env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"error: {e}", True
    out = (p.stdout or "").strip() or (p.stderr or "").strip() or ("done" if p.returncode == 0 else "failed")
    return out[:6000], p.returncode != 0


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


def agent(req, system, messages):
    """The model with the desktop tools, up to AGENT_STEPS rounds. Each
    call is a "step" event; one needing the user's OK an "approve" event,
    answered by a line on stdin (yes / no)."""
    specs, meta = agent_tools()
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
        messages.append({"role": "assistant", "content": content})
        results = []
        for c in calls:
            name, args = c.get("name", ""), c.get("input") or {}
            shown = unmask(step_summary(name, args))
            if needs_ok(req, name, args, meta):
                emit("approve", id=c["id"], tool=name, summary=shown, args=json.loads(unmask(json.dumps(args, ensure_ascii=False))))
                answer = sys.stdin.readline().strip().lower()
                if answer not in ("y", "yes", "ok"):
                    emit("step", id=c["id"], tool=name, summary=shown, status="denied")
                    results.append({"type": "tool_result", "tool_use_id": c["id"], "is_error": True,
                                    "content": "the user said no: don't do it, don't retry it another way"})
                    continue
            emit("step", id=c["id"], tool=name, summary=shown, status="run")
            out, failed = run_tool(name, args)
            emit("step", id=c["id"], tool=name, summary=shown, status="error" if failed else "ok",
                 result=unmask(out[:300]))
            if failed and "desktop control is paused" in out:
                emit("paused")
            results.append({"type": "tool_result", "tool_use_id": c["id"], "content": out, "is_error": failed})
        messages.append({"role": "user", "content": results})
    else:
        said = ["(stopped after %d steps)" % AGENT_STEPS]
    return model, "\n".join(said)


def agent_claude(req, system, prompt):
    """Anthropic: Claude Code (Haiku) with nixbook-desktop-mcp as its MCP
    server, only the steps that need no OK allowed; its tool calls are
    streamed as steps."""
    claude = req.get("claude") or shutil.which("claude")
    if not claude:
        raise RuntimeError("Claude Code isn't installed (Settings > Desktop agents)")
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
    if len(argv) == 2 and argv[1] == "modes":
        print(json.dumps(sorted(MODES)))
        return 0
    print("usage: nixbook-quick-ai ask REQUEST.json | modes", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
