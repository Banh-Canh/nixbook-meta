"""nixbook_ai: the one model client every AI script of the shell shares.

The headless agent (meta-agent.py), Quick AI's one-shot answers
(quick-ai.py), the Nix onboarding (nix-onboard.py) and desktop-mcp's own
passes all talk to the provider's Messages API (Meta's Model API: Muse)
through this module, so they retry, fall back and remember what the server
refuses the same way, and reach desktop-mcp (the privacy mask, the sent log,
the context broker, the memory) the same way. Stdlib only; each script puts
its own directory on sys.path first (the package installs this file next to
them):

    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    import nixbook_ai

  Provider.from_env()     the provider (NIXBOOK_AI_* from the environment, or
                          `nixbook-model-provider env` when the process wasn't
                          started through the provider)
  ensure_provider(argv)   no key here: re-run the script through
                          `nixbook-model-provider run`
  call(system, messages…) one Messages API call (retries, the server's
                          refusals remembered, streamed or not, Meta's fast
                          chat endpoint when asked)
  answer(system, prompt…) one answer: its text, or with a schema its JSON
  dm(argv, stdin)         nixbook-desktop-mcp ARGV: through the helper's
                          socket when it is up, else a process
  mask/unmask/mask_json/unmask_json, sent_note    through dm()
  is_risky, reads_only, build_report, strip_report, step_summary
                          what the agent loop asks about and reports
  action_class, class_summary
                          the kind of step a call is (the trust ladder, the
                          journal: `close_window@firefox`, `calendar:add`)
  config(), routing()     the shell's settings (config.json)
"""

import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid

NO_PROVIDER = "no model provider with an API key (Settings > Desktop agents > Model provider)"
NO_MODEL = "no model set for the provider (Settings > Desktop agents > Model provider)"
EFFORTS = ("minimal", "low", "medium", "high", "max")
# The tool a structured answer goes through (answer(schema=…), and the
# agent's --json-schema).
STRUCTURED = "structured_output"
# How often a failing request is tried again (429, 5xx, 529, the network)
# and the first wait; each next wait three times longer (the server's
# retry-after when it gives one, at most 30 s). Tests make them short.
RETRIES = int(os.environ.get("NIXBOOK_AI_RETRIES") or 3)
RETRY_DELAY = float(os.environ.get("NIXBOOK_AI_RETRY_DELAY") or 1.0)
RETRY_CODES = (429, 500, 502, 503, 504, 529)


class AIError(RuntimeError):
    """A model call that failed: the message is the user's to read."""


class NoProvider(AIError):
    pass


# ── Small helpers ──────────────────────────────────────────────────────────

def child_env(extra=None):
    """The environment of what these scripts start: never the provider's
    key (a tool, a command, desktop-mcp has no business with it)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("NIXBOOK_AI_")}
    if extra:
        env.update({str(k): str(v) for k, v in extra.items()})
    return env


def json_in(text):
    """The JSON object in a text answer (fenced or not), or None."""
    s = str(text or "").strip()
    start, end = s.find("{"), s.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        d = json.loads(s[start:end + 1])
    except ValueError:
        return None
    return d if isinstance(d, dict) else None


def text_of(msg):
    """A message's text blocks, joined."""
    return "".join(b.get("text", "") for b in (msg or {}).get("content") or [] if b.get("type") == "text")


def config():
    """The shell's settings (config.json), {} when unreadable."""
    path = os.environ.get("NIXBOOK_SHELL_CONFIG") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "nixbook-shell", "config.json")
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def routing(cfg=None):
    """Which model decides on the user's behalf (ai.routing): decisions
    (the initiative's, Full AI's reactions, the agent's request resolver),
    its effort, and the quick answers' model."""
    r = (((cfg if cfg is not None else config()).get("ai") or {}).get("routing") or {})
    r = r if isinstance(r, dict) else {}
    effort = str(r.get("decisionsEffort") or "low").lower()
    return {"decisions": str(r.get("decisions") or "big"), "decisionsEffort": effort if effort in EFFORTS else "low",
            "quick": str(r.get("quick") or "small")}


# ── The provider ───────────────────────────────────────────────────────────

_ENV = {"result": None, "at": 0.0}
_ENV_LOCK = threading.Lock()


def provider_env():
    """`nixbook-model-provider env`: the provider's settings and key as JSON
    ({baseUrl, key, model, smallModel, bigModel, label} or {error}), asked
    once and kept (10 minutes; a failure 30 s, so a key saved meanwhile is
    seen) — for the long-lived processes (desktop-mcp's helper, its passes)
    that weren't started through the provider."""
    with _ENV_LOCK:
        now = time.monotonic()
        d = _ENV["result"]
        if d is not None and now - _ENV["at"] < (600 if not d.get("error") else 30):
            return d
        d = {"error": NO_PROVIDER}
        exe = shutil.which("nixbook-model-provider")
        if exe:
            try:
                p = subprocess.run([exe, "env"], capture_output=True, text=True, timeout=20, env=child_env(),
                                   stdin=subprocess.DEVNULL)
                lines = (p.stdout or "").strip().splitlines()
                got = json.loads(lines[-1]) if lines else None
                if isinstance(got, dict):
                    d = got
            except (OSError, subprocess.TimeoutExpired, ValueError):
                pass
        _ENV["result"], _ENV["at"] = d, now
        return d


class Provider:
    """The provider's Messages API: its base URL, key, label and models
    (small, main, big)."""

    def __init__(self, base, key, models, label=""):
        self.base = str(base or "").rstrip("/")
        self.key = str(key or "")
        main = str((models or {}).get("main") or "")
        self.models = {"main": main, "small": str((models or {}).get("small") or "") or main,
                       "big": str((models or {}).get("big") or "") or main}
        self.label = label or ("Meta" if "meta.ai" in self.base else "Custom")

    @classmethod
    def from_env(cls):
        env = os.environ
        if env.get("NIXBOOK_AI_KEY"):
            d = {"baseUrl": env.get("NIXBOOK_AI_BASE_URL", ""), "key": env["NIXBOOK_AI_KEY"],
                 "model": env.get("NIXBOOK_AI_MODEL", ""), "smallModel": env.get("NIXBOOK_AI_SMALL_MODEL", ""),
                 "bigModel": env.get("NIXBOOK_AI_BIG_MODEL", ""), "label": env.get("NIXBOOK_AI_LABEL", "")}
        else:
            d = provider_env()
            if d.get("error"):
                raise NoProvider(str(d["error"]) if d["error"] != NO_PROVIDER else NO_PROVIDER)
        if not d.get("baseUrl") or not d.get("key"):
            raise NoProvider(NO_PROVIDER)
        return cls(d["baseUrl"], d["key"], {"main": d.get("model"), "small": d.get("smallModel"),
                                            "big": d.get("bigModel")}, d.get("label") or "")

    def model(self, alias=""):
        """small | main | big, the usual vendor names (haiku → small,
        sonnet/default → main, opus/fable → big), or a provider model id."""
        n = str(alias or "").strip()
        low = n.lower()
        if low in ("", "main", "default") or "sonnet" in low:
            return self.models["main"]
        if low == "small" or "haiku" in low:
            return self.models["small"]
        if low == "big" or "opus" in low or "fable" in low:
            return self.models["big"]
        return n

    def request(self, path, body, stream=False):
        headers = {"Authorization": f"Bearer {self.key}", "content-type": "application/json"}
        if path.startswith("/v1/messages"):
            # The wire protocol Meta's API speaks, not another vendor's.
            headers["anthropic-version"] = "2023-06-01"
        if stream:
            headers["accept"] = "text/event-stream"
        return urllib.request.Request(self.base + path, data=json.dumps(body).encode(), method="POST",
                                      headers=headers)


def ensure_provider(argv, script=None):
    """No key here (started outside the provider): this script run again
    through `nixbook-model-provider run`, which sets NIXBOOK_AI_* (once:
    it marks the environment). Nothing when the provider isn't installed:
    Provider.from_env() says what is missing."""
    if os.environ.get("NIXBOOK_AI_KEY") or os.environ.get("NIXBOOK_AI_PROVIDED"):
        return
    exe = shutil.which("nixbook-model-provider")
    if not exe:
        return
    import sys
    path = os.path.abspath(script or sys.argv[0])
    os.execvp(exe, [exe, "run", sys.executable, "-I", path, *argv])


# ── The wire ───────────────────────────────────────────────────────────────

# What the server refused, remembered for the rest of the process: the
# thinking/effort settings, a max_tokens too big, the fast chat endpoint.
_STATE = {"tuning": True, "fast": None, "max_tokens": None}


def http_detail(e):
    try:
        detail = e.read().decode("utf-8", "replace")
    except (OSError, AttributeError):
        detail = ""
    try:
        d = json.loads(detail)
        detail = (d.get("error") or {}).get("message") or d.get("message") or detail
    except (ValueError, AttributeError):
        pass
    return str(detail)


def normalize_message(msg):
    content = []
    for b in msg.get("content") or []:
        t = b.get("type")
        if t == "text":
            content.append({"type": "text", "text": str(b.get("text") or "")})
        elif t == "tool_use":
            content.append({"type": "tool_use", "id": b.get("id") or f"toolu_{uuid.uuid4().hex[:20]}",
                            "name": b.get("name", ""), "input": b.get("input") if isinstance(b.get("input"), dict) else {}})
        elif t == "thinking":
            block = {"type": "thinking", "thinking": str(b.get("thinking") or "")}
            if b.get("signature"):
                block["signature"] = b["signature"]
            content.append(block)
        elif t == "redacted_thinking":
            content.append({"type": "redacted_thinking", "data": b.get("data", "")})
    return {"content": content, "stop_reason": msg.get("stop_reason") or "end_turn",
            "usage": msg.get("usage") or {}, "model": msg.get("model") or ""}


def synthesize(msg, relay):
    """A whole reply as the stream events it would have been."""
    relay({"type": "message_start", "message": {"model": msg.get("model"), "role": "assistant", "content": [],
                                                "usage": msg.get("usage") or {}}})
    for i, b in enumerate(normalize_message(msg)["content"]):
        t = b["type"]
        start = {"type": t, "text": ""} if t == "text" else {"type": t, "thinking": ""} if t == "thinking" else \
            {"type": "tool_use", "id": b["id"], "name": b["name"], "input": {}} if t == "tool_use" else b
        relay({"type": "content_block_start", "index": i, "content_block": start})
        if t == "text" and b["text"]:
            relay({"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": b["text"]}})
        elif t == "thinking" and b["thinking"]:
            relay({"type": "content_block_delta", "index": i, "delta": {"type": "thinking_delta", "thinking": b["thinking"]}})
        elif t == "tool_use":
            relay({"type": "content_block_delta", "index": i,
                   "delta": {"type": "input_json_delta", "partial_json": json.dumps(b["input"])}})
        relay({"type": "content_block_stop", "index": i})
    relay({"type": "message_delta", "delta": {"stop_reason": msg.get("stop_reason") or "end_turn"},
           "usage": {"output_tokens": (msg.get("usage") or {}).get("output_tokens", 0)}})
    relay({"type": "message_stop"})


def read_sse(resp, relay):
    """A streamed Messages API reply: the whole message, each event relayed."""
    blocks, partial = {}, {}
    msg = {"stop_reason": "end_turn", "usage": {}, "model": ""}
    data_lines = []

    def handle(ev):
        t = ev.get("type")
        if t == "ping":
            return
        if t == "error":
            raise AIError(f"API error: {(ev.get('error') or {}).get('message') or ev}")
        relay(ev)
        if t == "message_start":
            m = ev.get("message") or {}
            msg["model"] = m.get("model") or ""
            msg["usage"] = dict(m.get("usage") or {})
        elif t == "content_block_start":
            blocks[ev.get("index", len(blocks))] = dict(ev.get("content_block") or {})
        elif t == "content_block_delta":
            i, d = ev.get("index", 0), ev.get("delta") or {}
            b = blocks.setdefault(i, {"type": "text", "text": ""})
            dt = d.get("type")
            if dt == "text_delta":
                b["text"] = b.get("text", "") + d.get("text", "")
            elif dt == "thinking_delta":
                b["thinking"] = b.get("thinking", "") + d.get("thinking", "")
            elif dt == "signature_delta":
                b["signature"] = b.get("signature", "") + d.get("signature", "")
            elif dt == "input_json_delta":
                partial[i] = partial.get(i, "") + d.get("partial_json", "")
        elif t == "content_block_stop":
            i = ev.get("index", 0)
            b = blocks.get(i) or {}
            if b.get("type") == "tool_use":
                raw = partial.get(i, "")
                try:
                    b["input"] = json.loads(raw) if raw.strip() else (b.get("input") or {})
                except ValueError:
                    b["input"] = {}
        elif t == "message_delta":
            d = ev.get("delta") or {}
            if d.get("stop_reason"):
                msg["stop_reason"] = d["stop_reason"]
            msg["usage"].update(ev.get("usage") or {})

    for raw in resp:
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if not line:
            if data_lines:
                try:
                    ev = json.loads("\n".join(data_lines))
                except ValueError:
                    ev = None
                data_lines = []
                if isinstance(ev, dict):
                    handle(ev)
            continue
        if line.startswith("data:"):
            data_lines.append(line[5:].lstrip())
    if data_lines:
        try:
            ev = json.loads("\n".join(data_lines))
        except ValueError:
            ev = None
        if isinstance(ev, dict):
            handle(ev)
    for i, b in blocks.items():
        if b.get("type") == "tool_use" and "input" not in b:
            try:
                b["input"] = json.loads(partial.get(i) or "{}")
            except ValueError:
                b["input"] = {}
    msg["content"] = [blocks[i] for i in sorted(blocks)]
    return normalize_message(msg)


def _send(p, body, stream, on_event, timeout):
    """One request, tried again on a busy or failing server (and the
    network) as long as nothing of the answer was relayed yet."""
    delay = RETRY_DELAY
    for attempt in range(RETRIES + 1):
        started = [False]

        def relay(ev):
            started[0] = True
            if on_event:
                on_event(ev)
        try:
            with urllib.request.urlopen(p.request("/v1/messages", body, stream), timeout=timeout) as resp:
                if stream and "text/event-stream" in (resp.headers.get("content-type") or ""):
                    return read_sse(resp, relay)
                msg = json.loads(resp.read().decode("utf-8", "replace"))
                if not isinstance(msg, dict):
                    raise AIError("API error: not a Messages API reply")
                if msg.get("type") == "error":
                    raise AIError(f"API error: {(msg.get('error') or {}).get('message') or msg}")
                if on_event:
                    synthesize(msg, relay)
                return normalize_message(msg)
        except urllib.error.HTTPError as e:
            if e.code in RETRY_CODES and attempt < RETRIES and not started[0]:
                retry = e.headers.get("retry-after") if e.headers else None
                try:
                    wait = min(30.0, float(retry)) if retry else delay
                except ValueError:
                    wait = delay
                http_detail(e)
                time.sleep(wait)
                delay *= 3
                continue
            raise
        except (urllib.error.URLError, socket.timeout, ConnectionError, TimeoutError) as e:
            if attempt < RETRIES and not started[0]:
                time.sleep(delay)
                delay *= 3
                continue
            raise AIError(f"API error: {getattr(e, 'reason', e)}")
    raise AIError("API error: the server kept failing")


def system_text(system):
    if isinstance(system, list):
        return "\n\n".join(str(b.get("text") or "") for b in system if isinstance(b, dict))
    return str(system or "")


def chat_messages(system, messages):
    """Messages API messages in the OpenAI chat shape (text and base64
    images)."""
    out = [{"role": "system", "content": system_text(system)}]
    for m in messages:
        c = m.get("content")
        if isinstance(c, str):
            out.append({"role": m["role"], "content": c})
            continue
        parts = []
        for b in c or []:
            if b.get("type") == "text":
                parts.append({"type": "text", "text": b.get("text", "")})
            elif b.get("type") == "image":
                src = b.get("source") or {}
                parts.append({"type": "image_url", "image_url": {"url": f"data:{src.get('media_type')};base64,{src.get('data')}"}})
        out.append({"role": m["role"], "content": parts})
    return out


def _fast(p, model, system, messages, max_tokens, timeout):
    """Meta's OpenAI-style chat endpoint with reasoning_effort "minimal" (the
    Messages API can't ask for that little thinking: about 2 s faster). None
    when it isn't there (404/405, or a 400/422 from a server that never took
    it): the Messages API answers then, and every next call goes there."""
    body = {"model": model, "max_completion_tokens": max_tokens, "reasoning_effort": "minimal",
            "messages": chat_messages(system, messages)}
    try:
        with urllib.request.urlopen(p.request("/v1/chat/completions", body), timeout=timeout) as resp:
            d = json.loads(resp.read().decode("utf-8", "replace"))
        text = ((d.get("choices") or [{}])[0].get("message") or {}).get("content")
        if not isinstance(text, str):
            raise ValueError("no choices")
    except urllib.error.HTTPError as e:
        http_detail(e)
        if e.code in (404, 405) or (e.code in (400, 422) and not _STATE["fast"]):
            _STATE["fast"] = False
        return None
    except (ValueError, KeyError, IndexError, AttributeError, TypeError):
        if not _STATE["fast"]:
            _STATE["fast"] = False
        return None
    except (urllib.error.URLError, socket.timeout, ConnectionError, TimeoutError):
        return None
    _STATE["fast"] = True
    return {"content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "usage": d.get("usage") or {},
            "model": d.get("model") or model}


def call(system, messages, *, model="small", effort=None, tools=None, tool_choice=None, max_tokens=16000,
         stream=False, on_event=None, fast=False, timeout=180, provider=None):
    """One Messages API call: the reply {content, stop_reason, usage, model}.

    effort (minimal|low|medium|high|max): adaptive thinking and
    output_config.effort, dropped for good when the server refuses them (a
    400 naming them), and when a tool is forced (they don't go together).
    A 400 naming max_tokens: asked again with half (not below 4096). stream
    or on_event: the reply streamed, each event to on_event. fast with no
    tools: Meta's chat endpoint first (see _fast). Retried on 429/5xx/529 and
    the network, with backoff and the server's retry-after."""
    p = provider or Provider.from_env()
    model_id = p.model(model)
    if not model_id:
        raise AIError(NO_MODEL)
    if fast and not tools and _STATE["fast"] is not False:
        msg = _fast(p, model_id, system, messages, max_tokens, timeout)
        if msg is not None:
            if on_event:
                synthesize(msg, on_event)
            return msg
    effort = effort if effort in EFFORTS else None
    forced = bool(tool_choice) and tool_choice.get("type") in ("tool", "any")
    stream = bool(stream or on_event)
    limit = min(max_tokens, _STATE["max_tokens"] or max_tokens)
    while True:
        body = {"model": model_id, "max_tokens": limit, "system": system, "messages": messages}
        if tools:
            body["tools"] = tools
        if tool_choice:
            body["tool_choice"] = tool_choice
        tuned = bool(effort) and _STATE["tuning"] and not forced
        if tuned:
            body["thinking"] = {"type": "adaptive"}
            body["output_config"] = {"effort": effort}
        if stream:
            body["stream"] = True
        try:
            return _send(p, body, stream, on_event, timeout)
        except urllib.error.HTTPError as e:
            detail = http_detail(e)
            if e.code == 400 and tuned and any(w in detail for w in ("thinking", "effort", "output_config")):
                _STATE["tuning"] = False
                continue
            if e.code == 400 and "max_tokens" in detail and limit > 4096:
                limit = max(4096, limit // 2)
                _STATE["max_tokens"] = limit
                continue
            if e.code == 400 and stream and "stream" in detail:
                stream = False
                continue
            raise AIError(f"API error: HTTP {e.code}: {detail[:400]}")


def _structured(msg, schema, wrapped):
    """(value, None), or (None, why): the structured answer of a reply, by
    the tool or as JSON in its text."""
    call_ = next((b for b in msg.get("content") or [] if b.get("type") == "tool_use" and b.get("name") == STRUCTURED),
                 None)
    value = call_.get("input") if call_ is not None else json_in(text_of(msg))
    if not isinstance(value, dict):
        return None, "no answer"
    if wrapped:
        if "value" not in value:
            return None, "the answer goes in `value`"
        return value["value"], None
    missing = [k for k in schema.get("required") or [] if k not in value]
    if missing:
        return None, "missing: " + ", ".join(missing)
    return value, None


def answer(system, prompt_or_messages, *, model="small", effort=None, schema=None, timeout=180, fast=False,
           max_tokens=8000, provider=None):
    """One answer, no tools: its text; with `schema` the JSON object it asks
    for, through a `structured_output` tool — offered (with the thinking
    the effort asks for) when there is an effort, else forced; a server that
    can't force one tool is asked for any, then for the JSON as text. A
    reply missing a required key is told so once. AIError when it fails."""
    if isinstance(prompt_or_messages, str):
        messages = [{"role": "user", "content": prompt_or_messages}]
    else:
        messages = list(prompt_or_messages)
    if schema is None:
        return text_of(call(system, messages, model=model, effort=effort, max_tokens=max_tokens, fast=fast,
                            timeout=timeout, provider=provider))
    wrapped = schema.get("type", "object") != "object"
    input_schema = {"type": "object", "properties": {"value": schema}, "required": ["value"]} if wrapped else \
        {k: v for k, v in schema.items() if k != "$schema"}
    tool = {"name": STRUCTURED, "description": "Give your answer, as the JSON asked for. Call it once.",
            "input_schema": input_schema}
    base = system_text(system)
    choices = ([{"type": "auto"}] if effort in EFFORTS else []) + [{"type": "tool", "name": STRUCTURED},
                                                                    {"type": "any"}, None]
    told = False
    i = 0
    convo = list(messages)
    while i < len(choices):
        choice = choices[i]
        sys_text = base + ("\n\nAnswer by calling the `structured_output` tool, once, with the JSON it asks for."
                           if choice is not None else "\n\nAnswer with the JSON object alone, nothing else: "
                           + json.dumps(input_schema, ensure_ascii=False))
        try:
            msg = call(sys_text, convo if choice is not None else messages, model=model, effort=effort if choice and choice["type"] == "auto" else None,
                       tools=[tool] if choice is not None else None, tool_choice=choice, max_tokens=max_tokens,
                       timeout=timeout, provider=provider)
        except AIError as e:
            if "HTTP 400" in str(e) and i + 1 < len(choices):
                i += 1
                continue
            raise
        value, why = _structured(msg, schema, wrapped)
        if why is None:
            return value
        if why.startswith("missing") and not told and choice is not None:
            # Once: what is wrong, the same way asked again.
            told = True
            content = msg["content"] or [{"type": "text", "text": "…"}]
            content = [b for b in content if b.get("type") in ("text", "tool_use")] or [{"type": "text", "text": "…"}]
            calls = [b for b in content if b.get("type") == "tool_use"]
            convo = convo + [{"role": "assistant", "content": content},
                             {"role": "user", "content": [{"type": "tool_result", "tool_use_id": b["id"],
                                                           "is_error": True, "content": why} for b in calls]
                              or why + ". Answer again, complete."}]
            continue
        i += 1
    raise AIError("the model gave no structured answer")


# ── desktop-mcp ────────────────────────────────────────────────────────────

def helper_socket():
    rt = os.environ.get("XDG_RUNTIME_DIR")
    return os.path.join(rt, "nixbook-desktop-mcp", "helper.sock") if rt else ""


def _dm_socket(argv, stdin, timeout):
    """ARGV through the shell's desktop-mcp helper (its socket: no Python
    start, ~150 ms of CPU saved a call): (code, stdout), or None to run it
    as a process (no helper, or not one of its commands: code 127)."""
    path = helper_socket()
    if not path or not os.path.exists(path):
        return None
    rid = uuid.uuid4().hex
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(2)
        try:
            s.connect(path)
            s.sendall((json.dumps({"id": rid, "argv": argv, "stdin": stdin or ""}, ensure_ascii=False) + "\n").encode())
        except OSError:
            return None
        # Sent: from here a silence is the answer (never run twice).
        s.settimeout(timeout)
        buf = b""
        try:
            while True:
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        reply = json.loads(line.decode("utf-8", "replace"))
                    except ValueError:
                        continue
                    if isinstance(reply, dict) and reply.get("id") == rid:
                        code = reply.get("code")
                        code = code if isinstance(code, int) else 1
                        out = str(reply.get("stdout") or "")
                        return None if code == 127 and not out else (code, out)
                chunk = s.recv(65536)
                if not chunk:
                    return 1, ""
                buf += chunk
        except (socket.timeout, TimeoutError):
            return 124, ""
        except OSError:
            return 1, ""
    finally:
        s.close()


def dm(argv, stdin=None, timeout=30, env=None):
    """nixbook-desktop-mcp ARGV (stdin: a string): (exit code, stdout).
    Through the helper's socket when it answers, else a process (always a
    process with `env`: what it adds can't go through the socket); (127, "")
    without either."""
    argv = [str(a) for a in argv]
    if env is None:
        got = _dm_socket(argv, stdin, timeout)
        if got is not None:
            return got
    exe = shutil.which("nixbook-desktop-mcp")
    if not exe:
        return 127, ""
    try:
        p = subprocess.run([exe, *argv], input=stdin if stdin is not None else "", capture_output=True, text=True,
                           timeout=timeout, env=child_env(env))
    except subprocess.TimeoutExpired:
        return 124, ""
    except OSError:
        return 127, ""
    return p.returncode, p.stdout or ""


def mask(text):
    """The privacy mask (names, emails… → ⟦Person 1⟧): the text as it may
    leave the computer; the text itself when desktop-mcp can't."""
    if not text:
        return text
    code, out = dm(["privacy", "mask"], stdin=text)
    return out if code == 0 else text


def unmask(text):
    if not text or "⟦" not in text:
        return text
    code, out = dm(["privacy", "unmask"], stdin=text)
    return out if code == 0 else text


def _json_through(verb, value):
    code, out = dm(["privacy", verb, "--json"], stdin=json.dumps(value, ensure_ascii=False))
    if code != 0:
        return None
    try:
        back = json.loads(out)
    except ValueError:
        return None
    return back if isinstance(back, type(value)) else None


def mask_json(value):
    """A JSON value masked (strings inside it; images blacked out when the
    user asks for it), the value itself when it can't be."""
    back = _json_through("mask", value)
    return value if back is None else back


def unmask_json(value):
    if "⟦" not in json.dumps(value, ensure_ascii=False):
        return value
    back = _json_through("unmask", value)
    return value if back is None else back


def sent_note(purpose, model, text, web=False):
    """What was sent, in desktop-mcp's sent log (Settings shows it): the
    purpose, the model it went to (provider-prefixed) and the text."""
    dm(["sent", "note", str(purpose)[:60] + (" (web)" if web else ""), str(text), str(model)])


# ── Steps: what is asked about, what is reported ───────────────────────────

# The tools that both read and write (calendar, tasks, contacts, widget,
# equalizer, layouts…) say which with their `action`: these only read.
READ_ACTIONS = {"list", "lists", "upcoming", "get", "search", "find", "show", "status", "layout", "day", "events",
                "read", "next", "agenda", "info", "count", "check", "history"}
# The really risky steps, the only ones asked about by default (confirm
# "destructive"): data deleted, words sent to other people in the user's
# name, credentials, money. Closing a window, adding an event, clicking
# around or playing music just happen.
RISKY_TOOL = re.compile(r"(^|_)(delete|remove|empty_trash|purge|wipe|clear|merge|resolve_duplicates|credentials|"
                        r"send|sms|reply|connect_with|partner|uninstall|format|buy|pay|purchase|order)", re.I)
RISKY_ACTION = re.compile(r"^(delete|remove|clear|purge|empty|reply|send)", re.I)
# A click on such a button (ui_act/click on an element named so).
RISKY_TARGET = re.compile(r"\b(delete|remove|send|reply|pay|buy|purchase|order|checkout|unsubscribe|empty trash|"
                          r"erase|format|uninstall|supprimer|envoyer|payer|acheter|l(ö|oe)schen|senden|x(ó|o)a|g(ử|u)i)\b", re.I)
HARMLESS_TOOL = re.compile(r"(queue|playlist|playback|volume|seek|repeat|shuffle)", re.I)


def _bare(name, meta):
    """A tool's own name: meta's, else without an mcp__server__ prefix."""
    tool = (meta or {}).get(name, {}).get("tool") if isinstance(meta, dict) else None
    if tool:
        return str(tool)
    m = re.match(r"^mcp__[^_]+(?:_[^_]+)*?__(.+)$", str(name))
    return m.group(1) if m else str(name)


def reads_only(name, args, meta=None):
    """True for a call that only reads: a tool annotated read-only (meta:
    {name: {read_only}}), or a multi-purpose tool asked a reading action."""
    if isinstance(meta, dict) and meta.get(name, {}).get("read_only"):
        return True
    action = str((args or {}).get("action") or "").lower()
    return action in READ_ACTIONS


def is_risky(name, args, meta=None):
    tool = _bare(name, meta)
    if HARMLESS_TOOL.search(tool):
        return False
    if RISKY_TOOL.search(tool):
        return True
    action = str((args or {}).get("action") or "")
    if RISKY_ACTION.match(action):
        return True
    if tool == "browser_act":
        # A click (or a form sent) on a "Send", "Pay", "Order"… button.
        return str((args or {}).get("action") or "") in ("click", "submit", "press") and bool(
            RISKY_TARGET.search(str((args or {}).get("name") or "")))
    if tool in ("ui_act", "click", "notification_action"):
        said = " ".join(str(v) for v in (args or {}).values() if isinstance(v, str))
        return bool(RISKY_TARGET.search(said))
    return False


# The trust ladder's classes (action_class): what the user lets Muse do
# without asking is decided per kind of step, not per tool. The window tools
# that name the app they act on (its `app`), and the input tools, which act
# on the window in front (the app the caller saw there): the app is part of
# the class, so "typing in Firefox" and "typing in the terminal" are trusted
# apart.
APP_TOOLS = {"launch_app", "close_window", "focus_window", "window_action", "move_window_to_workspace", "set_aside",
             "ui_act"}
INPUT_TOOLS = {"type_text", "press_keys", "click", "drag", "scroll", "run_steps", "run_recipe", "move_pointer"}
TRUST_LEVELS = ("ask", "tell", "silent")


def _class_part(value, limit):
    """A piece of a class name: lower case, letters, digits, . _ - only."""
    return re.sub(r"[^a-z0-9._-]+", "-", str(value or "").strip().lower()).strip("-")[:limit]


def action_class(name, args, app=None, meta=None):
    """The kind of step a tool call is, for the trust ladder and the
    journal: the tool's own name (`mcp__desktop__media_control` →
    `media_control`), `:<action>` for the multi-purpose tools (their
    `action` argument), `@<app desktop id>` for the window and input tools
    acting on an app (APP the caller knows, e.g. the window in front for the
    input tools; else the call's own `app`). `media_control:pause`,
    `close_window@firefox`, `calendar:add`."""
    tool = _bare(name, meta)
    cls = tool
    args = args if isinstance(args, dict) else {}
    action = _class_part(args.get("action"), 40)
    if action:
        cls += ":" + action
    if tool in APP_TOOLS or tool in INPUT_TOOLS:
        who = app or (args.get("app") if isinstance(args.get("app"), str) else "")
        who = _class_part(re.sub(r"\.desktop$", "", str(who or "").strip(), flags=re.I), 80)
        if who:
            cls += "@" + who
    return cls


def class_summary(cls):
    """A class in words, for "Stop asking before …?": `close_window@firefox`
    → "close window in firefox", `calendar:add` → "calendar: add"."""
    tool, _, app = str(cls or "").partition("@")
    tool, _, action = tool.partition(":")
    out = tool.replace("_", " ")
    if action:
        out += ": " + action.replace("_", " ")
    if app:
        out += " in " + app
    return out


def step_summary(args):
    keys = ("app", "name", "id", "index", "workspace", "text", "title", "body", "message", "query", "target",
            "function", "theme", "variant", "action", "keys", "path")
    bits = [f"{k}={str(args[k])[:40]}" for k in keys if k in (args or {})]
    return ", ".join(bits)[:120]


def step_line(s):
    line = str(s["tool"]).replace("_", " ") + (f" ({s['summary']})" if s.get("summary") else "")
    if s["status"] == "denied":
        return line + ": you said no"
    if s["status"] == "error" and s.get("result"):
        return line + ": " + str(s["result"]).strip().splitlines()[0][:160]
    return line


REPORT_RE = re.compile(r"<report>\s*(\{.*?\})\s*</report>", re.S)


def strip_report(text):
    """(the text without its <report>{…}</report> block, the block's JSON
    or {})."""
    m = REPORT_RE.search(text or "")
    if not m:
        return (text or "").strip(), {}
    try:
        model = json.loads(m.group(1))
    except ValueError:
        model = {}
    return (text[:m.start()] + text[m.end():]).strip(), model if isinstance(model, dict) else {}


def build_report(answer_text, steps):
    """The answer and, when the agent changed something, its report: the
    model's own (<report>{…}</report>) where it gave one, the steps that
    failed added when it left them out. steps: [{tool, summary, status
    (ok|error|denied), result, read_only}] in order. (text, None) for a
    plain answer, or one that went well and needs nothing from the user."""
    text, model = strip_report(answer_text)
    steps = list(steps or [])
    acted = [s for s in steps if not s.get("read_only")]
    if not acted and not model:
        return text, None

    def lst(k):
        return [str(x).strip() for x in (model.get(k) or []) if str(x).strip()][:12]
    done, failed, needs = lst("done"), lst("failed"), lst("needs_you")
    # The steps that failed and weren't done after all (no later success of
    # the same tool): said even when the model leaves them out. One that
    # failed and then worked isn't the user's business.
    bad = [s for i, s in enumerate(steps) if s["status"] in ("error", "denied")
           and not any(t["tool"] == s["tool"] and t["status"] == "ok" for t in steps[i + 1:])]
    if bad and not failed:
        failed = [step_line(s) for s in bad][:8]
    # It went well and nothing needs them: just the answer, as in a chat.
    if not failed and not needs:
        if not text:
            text = str(model.get("summary") or "").strip() or ("\n".join(done) if done else "Done.")
        return text, None
    if not done:
        done = [step_line(s) for s in acted if s["status"] == "ok"][:12]
    summary = str(model.get("summary") or "").strip() or (text.splitlines()[0] if text else "") or \
        ("Done." if not bad else "Done, with problems.")
    report = {"summary": summary, "done": done, "failed": failed, "needsYou": needs, "steps": len(steps),
              "ok": sum(1 for s in steps if s["status"] == "ok"), "ko": len(bad)}
    parts = [summary]
    parts += [f"- ✓ {d}" for d in done] + [f"- ✗ {f}" for f in failed] + [f"- → {n}" for n in needs]
    return "\n".join(parts), report
