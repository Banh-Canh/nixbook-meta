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
                          chat endpoint when asked; each tool call to
                          on_block as soon as it is complete; Cancel stops
                          it from another thread), on a kept-alive
                          connection (one pool a process)
  use_caps_cache()        what the server can't do (the fast endpoint, the
                          thinking settings) remembered a day across
                          processes ($XDG_CACHE_HOME/nixbook-shell/
                          provider-caps.json)
  answer(system, prompt…) one answer: its text, or with a schema its JSON
  dm(argv, stdin)         nixbook-desktop-mcp ARGV: through the helper's
                          socket when it is up, else a process
  mask/unmask/mask_json/unmask_json, sent_note    through dm()
  is_risky, reads_only, build_report, strip_report, step_summary
                          what the agent loop asks about and reports
  action_class, class_summary
                          the kind of step a call is (the trust ladder, the
                          journal: `close_window@firefox`, `calendar:add`,
                          `terminal_run:git-status`)
  command_risk, command_segments, terminal_never
                          a command line read as the shell would: its kind,
                          whether it is risky, the kinds always asked
  config(), routing()     the shell's settings (config.json)

Heavy modules (http.client, ssl, urllib) are imported when first used: the
scripts that only reach desktop-mcp don't pay for them.
"""

import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
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


class Busy(AIError):
    """An error event in the stream from a busy or failing server: retried."""


# The stream's error types worth another try (the HTTP codes' equivalents).
BUSY_ERRORS = ("overloaded_error", "api_error", "rate_limit_error")


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
    (the initiative's, Full AI's reactions), its effort, the quick answers'
    model, the agent's checks (resolve: the request read when it may be
    ambiguous; verify: the result checked), and effortMinimal (the checks,
    the reactions and the one-shot answers think as little as the server
    allows)."""
    r = (((cfg if cfg is not None else config()).get("ai") or {}).get("routing") or {})
    r = r if isinstance(r, dict) else {}
    effort = str(r.get("decisionsEffort") or "low").lower()
    return {"decisions": str(r.get("decisions") or "big"), "decisionsEffort": effort if effort in EFFORTS else "low",
            "quick": str(r.get("quick") or "small"), "resolve": str(r.get("resolve") or "small"),
            "verify": str(r.get("verify") or "small"), "effortMinimal": r.get("effortMinimal", True) is not False}


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

    def headers(self, path, stream=False):
        headers = {"Authorization": f"Bearer {self.key}", "content-type": "application/json",
                   # Plain bytes (a stream decoded as it comes), the
                   # connection kept for the next call.
                   "accept-encoding": "identity", "connection": "keep-alive"}
        if path.startswith("/v1/messages"):
            # The wire protocol Meta's API speaks, not another vendor's.
            headers["anthropic-version"] = "2023-06-01"
        if stream:
            headers["accept"] = "text/event-stream"
        return headers

    def caps_key(self, model_id):
        return f"{self.base}|{model_id}"


def ensure_provider(argv, script=None, why=""):
    """No key here (started outside the provider, and `nixbook-model-provider
    env` gave none): this script run again through `nixbook-model-provider
    run`, which sets NIXBOOK_AI_* (once: it marks the environment), said on
    stderr (WHY: what env answered). Nothing when the provider isn't
    installed: Provider.from_env() says what is missing."""
    if os.environ.get("NIXBOOK_AI_KEY") or os.environ.get("NIXBOOK_AI_PROVIDED"):
        return
    exe = shutil.which("nixbook-model-provider")
    if not exe:
        return
    import sys
    path = os.path.abspath(script or sys.argv[0])
    sys.stderr.write(f"{os.path.basename(path)}: no key from `nixbook-model-provider env`"
                     + (f" ({why})" if why else "") + ": through `nixbook-model-provider run`\n")
    sys.stderr.flush()
    os.execvp(exe, [exe, "run", sys.executable, "-I", path, *argv])


# ── The wire ───────────────────────────────────────────────────────────────

# What the server refused, remembered for the rest of the process, per
# provider and model (one model's refusal says nothing of another's): the
# thinking/effort settings (or only effort "minimal"), a max_tokens too big,
# the fast chat endpoint.
_STATE = {}
_STATE_LOCK = threading.Lock()


def _st(p, model_id):
    key = p.caps_key(model_id) if p is not None else f"|{model_id}"
    with _STATE_LOCK:
        return _STATE.setdefault(key, {"tuning": True, "minimal": True, "fast": None, "max_tokens": None})
# The same, across processes (use_caps_cache): {base|model: {fast, tuning,
# t}}, a day; Quick AI's one-shots don't pay a failed probe each time.
CAPS_DAYS = 1
_CAPS = {"on": False, "data": None}
_CAPS_LOCK = threading.Lock()


def use_caps_cache(on=True):
    """Remember what the provider can't do across processes (the scripts
    started once per request: quick-ai, the agent)."""
    _CAPS["on"] = bool(on)


def caps_path():
    return os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "nixbook-shell",
                        "provider-caps.json")


def _caps_all():
    if _CAPS["data"] is None:
        try:
            with open(caps_path(), encoding="utf-8") as f:
                d = json.load(f)
            _CAPS["data"] = d if isinstance(d, dict) else {}
        except (OSError, ValueError):
            _CAPS["data"] = {}
    return _CAPS["data"]


def known_caps(p, model_id):
    """What the cache knows of this provider and model ({} when nothing,
    or older than a day)."""
    if not _CAPS["on"]:
        return {}
    with _CAPS_LOCK:
        d = _caps_all().get(p.caps_key(model_id))
    if not isinstance(d, dict) or time.time() - float(d.get("t") or 0) > CAPS_DAYS * 86400:
        return {}
    return d


def _remember(p, model_id, **caps):
    """Something learned of the server: for this process, and in the cache."""
    _st(p, model_id).update(caps)
    if not _CAPS["on"] or p is None:
        return
    with _CAPS_LOCK:
        data = _caps_all()
        key = p.caps_key(model_id)
        entry = dict(data.get(key) or {})
        if all(entry.get(k) == v for k, v in caps.items()) and time.time() - float(entry.get("t") or 0) < 3600:
            return
        entry.update(caps)
        entry["t"] = int(time.time())
        data[key] = entry
        path = caps_path()
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = f"{path}.{os.getpid()}.tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f)
            os.replace(tmp, path)
        except OSError:
            pass


def _fast_known(p, model_id):
    v = _st(p, model_id)["fast"]
    if v is not None:
        return v
    v = known_caps(p, model_id).get("fast")
    return v if isinstance(v, bool) else None


def _tuning_ok(p, model_id, effort=None):
    st, known = _st(p, model_id), known_caps(p, model_id)
    if not st["tuning"] or known.get("tuning") is False:
        return False
    # Effort "minimal" refused alone: no thinking fields for it (the
    # nearest thing), the other efforts still sent.
    return effort != "minimal" or (st["minimal"] and known.get("minimal") is not False)


def http_detail(e):
    try:
        detail = e.read().decode("utf-8", "replace")
    except (OSError, AttributeError, ValueError):
        detail = ""
    try:
        d = json.loads(detail)
        detail = (d.get("error") or {}).get("message") or d.get("message") or detail
    except (ValueError, AttributeError):
        pass
    return str(detail)


class Cancelled(AIError):
    """A call stopped by its Cancel (another thread's decision)."""


class Cancel:
    """Stops a call in flight from another thread: its connection shut, the
    call raising Cancelled (never sent again)."""

    def __init__(self):
        self._event = threading.Event()
        self._lock = threading.Lock()
        self._conn = None

    def attach(self, conn):
        with self._lock:
            self._conn = conn
        if self._event.is_set():
            self._shut()

    def set(self):
        self._event.set()
        self._shut()

    def is_set(self):
        return self._event.is_set()

    def _shut(self):
        with self._lock:
            conn = self._conn
        sock = getattr(conn, "sock", None)
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


# Kept-alive connections, per (scheme, host, port): taken by a call, given
# back once its answer is read whole; one TLS context for the process. A
# connection idle longer than IDLE_MAX is dropped (servers close them).
IDLE_MAX = 50.0
_POOL = {}
_POOL_LOCK = threading.Lock()
_SSL = {"ctx": None}
POOL_MAX = 4


def _ssl_context():
    if _SSL["ctx"] is None:
        import ssl
        _SSL["ctx"] = ssl.create_default_context()
    return _SSL["ctx"]


def _take(key, timeout):
    """(a connection for KEY, whether it was kept from before)."""
    import http.client
    now = time.monotonic()
    with _POOL_LOCK:
        idle = _POOL.get(key) or []
        while idle:
            conn, since = idle.pop()
            if now - since <= IDLE_MAX and conn.sock is not None:
                conn.timeout = timeout
                try:
                    conn.sock.settimeout(timeout)
                except OSError:
                    conn.close()
                    continue
                return conn, True
            conn.close()
    scheme, host, port = key
    if scheme == "https":
        return http.client.HTTPSConnection(host, port, timeout=timeout, context=_ssl_context()), False
    return http.client.HTTPConnection(host, port, timeout=timeout), False


def _give(key, conn, resp):
    """CONN back to the pool, its answer read whole (else closed)."""
    if conn is None:
        return
    if resp is None or resp.will_close or not resp.isclosed() or conn.sock is None:
        conn.close()
        return
    with _POOL_LOCK:
        idle = _POOL.setdefault(key, [])
        if len(idle) >= POOL_MAX:
            conn.close()
            return
        idle.append((conn, time.monotonic()))


def close_pool():
    with _POOL_LOCK:
        for idle in _POOL.values():
            for conn, _ in idle:
                conn.close()
        _POOL.clear()


def _proxied(scheme):
    """A proxy set for SCHEME: then urllib (it knows proxies), one
    connection a call."""
    return bool(os.environ.get(f"{scheme}_proxy") or os.environ.get(f"{scheme.upper()}_PROXY"))


class Response:
    """A request's answer (status 200): read it, then done() (its
    connection given back for the next call, or closed)."""

    def __init__(self, resp, conn, key):
        self.resp, self.conn, self.key = resp, conn, key
        self.headers = resp.headers

    def __iter__(self):
        return iter(self.resp)

    def read(self):
        return self.resp.read()

    def done(self, ok=True):
        if self.conn is None:
            self.resp.close()
            return
        if ok:
            _give(self.key, self.conn, self.resp)
        else:
            self.conn.close()


def post(p, path, body, stream=False, timeout=180, cancel=None):
    """BODY to the provider's PATH: a Response (status 200), or
    urllib.error.HTTPError (another status), OSError / http.client errors
    (the network). Kept-alive: a connection kept from before that turns out
    closed by the server (before any answer) is tried once again on a new
    one."""
    import io
    import urllib.error
    import urllib.parse
    url = p.base + path
    data = json.dumps(body).encode()
    headers = p.headers(path, stream)
    u = urllib.parse.urlsplit(url)
    if _proxied(u.scheme):
        import urllib.request
        r = urllib.request.Request(url, data=data, method="POST", headers=headers)
        return Response(urllib.request.urlopen(r, timeout=timeout), None, None)
    import http.client
    key = (u.scheme, u.hostname or "", u.port or (443 if u.scheme == "https" else 80))
    target = (u.path or "/") + (f"?{u.query}" if u.query else "")
    for attempt in (0, 1):
        conn, reused = _take(key, timeout)
        if cancel is not None:
            cancel.attach(conn)
        try:
            conn.request("POST", target, body=data, headers=headers)
            resp = conn.getresponse()
        except (http.client.HTTPException, OSError) as e:
            conn.close()
            if cancel is not None and cancel.is_set():
                raise Cancelled("stopped")
            stale = isinstance(e, (http.client.RemoteDisconnected, http.client.BadStatusLine,
                                   ConnectionResetError, BrokenPipeError, ConnectionAbortedError))
            if reused and stale and attempt == 0:
                continue
            raise
        break
    if resp.status != 200:
        try:
            raw = resp.read()
        except (http.client.HTTPException, OSError):
            raw = b""
        _give(key, conn, resp)
        raise urllib.error.HTTPError(url, resp.status, resp.reason, resp.headers, io.BytesIO(raw))
    return Response(resp, conn, key)


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
            "usage": msg.get("usage") or {}, "model": msg.get("model") or "",
            # The tool calls the output limit cut off (their input incomplete).
            **({"cut": list(msg["cut"])} if msg.get("cut") else {})}


def synthesize(msg, relay, on_block=None):
    """A whole reply as the stream events it would have been (each tool
    call to on_block too)."""
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
        if t == "tool_use" and on_block:
            _block_done(on_block, b)
    relay({"type": "message_delta", "delta": {"stop_reason": msg.get("stop_reason") or "end_turn"},
           "usage": {"output_tokens": (msg.get("usage") or {}).get("output_tokens", 0)}})
    relay({"type": "message_stop"})


def _block_done(on_block, b):
    try:
        on_block({"type": "tool_use", "id": b.get("id") or "", "name": b.get("name", ""),
                  "input": b.get("input") if isinstance(b.get("input"), dict) else {}})
    except Exception:  # noqa: BLE001 — the caller's business, never the stream's
        pass


def read_sse(resp, relay, on_block=None):
    """A streamed Messages API reply: the whole message, each event relayed,
    each tool call to on_block as soon as its block ends (its input whole)."""
    blocks, partial, cut, stopped = {}, {}, set(), set()
    msg = {"stop_reason": "end_turn", "usage": {}, "model": ""}
    data_lines = []

    def handle(ev):
        t = ev.get("type")
        if t == "ping":
            return
        if t == "error":
            err = ev.get("error") or {}
            why = f"API error: {err.get('message') or ev}"
            # A busy server said so in the stream: tried again (by _send, as
            # long as nothing was relayed).
            raise (Busy if err.get("type") in BUSY_ERRORS else AIError)(why)
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
            stopped.add(i)
            b = blocks.get(i) or {}
            if b.get("type") == "tool_use":
                raw = partial.get(i, "")
                try:
                    b["input"] = json.loads(raw) if raw.strip() else (b.get("input") or {})
                except ValueError:
                    # Cut off by the output limit: never run on an empty input.
                    b["input"] = {}
                    if not b.get("id"):
                        b["id"] = f"toolu_{uuid.uuid4().hex[:20]}"
                    cut.add(b["id"])
                    return
                if on_block:
                    if not b.get("id"):
                        b["id"] = f"toolu_{uuid.uuid4().hex[:20]}"
                    _block_done(on_block, b)
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
    # A tool call whose block never ended (the stream closed early, a proxy
    # cutting the body): its input may be partial, so never run (cut). Its
    # content_block_start carried "input": {}, which isn't its input.
    for i, b in blocks.items():
        if b.get("type") == "tool_use" and i not in stopped:
            b["input"] = {}
            if not b.get("id"):
                b["id"] = f"toolu_{uuid.uuid4().hex[:20]}"
            cut.add(b["id"])
    msg["content"] = [blocks[i] for i in sorted(blocks)]
    msg["cut"] = sorted(cut)
    return normalize_message(msg)


def _send(p, body, stream, on_event, timeout, on_block=None, cancel=None):
    """One request, tried again on a busy or failing server (and the
    network) as long as nothing of the answer was relayed yet."""
    import http.client
    import urllib.error
    delay = RETRY_DELAY
    for attempt in range(RETRIES + 1):
        started = [False]

        def relay(ev):
            started[0] = True
            if on_event:
                on_event(ev)
        if cancel is not None and cancel.is_set():
            raise Cancelled("stopped")
        resp = None
        try:
            resp = post(p, "/v1/messages", body, stream, timeout, cancel)
            ok = False
            try:
                if stream and "text/event-stream" in (resp.headers.get("content-type") or ""):
                    msg = read_sse(resp, relay, on_block)
                    if cancel is not None and cancel.is_set():
                        raise Cancelled("stopped")
                    ok = True
                    return msg
                msg = json.loads(resp.read().decode("utf-8", "replace"))
                ok = True
            finally:
                resp.done(ok)
            if not isinstance(msg, dict):
                raise AIError("API error: not a Messages API reply")
            if msg.get("type") == "error":
                raise AIError(f"API error: {(msg.get('error') or {}).get('message') or msg}")
            if on_event or on_block:
                synthesize(msg, relay if on_event else (lambda ev: None), on_block)
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
        except Cancelled:
            raise
        except Busy as e:
            if attempt < RETRIES and not started[0]:
                time.sleep(delay)
                delay *= 3
                continue
            raise AIError(str(e))
        except (http.client.HTTPException, OSError, ValueError) as e:
            if cancel is not None and cancel.is_set():
                raise Cancelled("stopped")
            if isinstance(e, ValueError) and not isinstance(e, UnicodeError):
                # Not JSON: not a server to try again.
                raise AIError("API error: not a Messages API reply")
            # A timeout: once more at most (a server that hangs would else
            # hold the caller for RETRIES × the timeout, each generation paid).
            if attempt < (min(1, RETRIES) if isinstance(e, TimeoutError) else RETRIES) and not started[0]:
                time.sleep(delay)
                delay *= 3
                continue
            raise AIError(f"API error: {getattr(e, 'reason', None) or e or e.__class__.__name__}")
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
    import http.client
    import urllib.error
    body = {"model": model, "max_completion_tokens": max_tokens, "reasoning_effort": "minimal",
            "messages": chat_messages(system, messages)}
    try:
        resp = post(p, "/v1/chat/completions", body, timeout=timeout)
        ok = False
        try:
            d = json.loads(resp.read().decode("utf-8", "replace"))
            ok = True
        finally:
            resp.done(ok)
        text = ((d.get("choices") or [{}])[0].get("message") or {}).get("content")
        if not isinstance(text, str):
            raise ValueError("no choices")
    except urllib.error.HTTPError as e:
        http_detail(e)
        if e.code in (404, 405) or (e.code in (400, 422) and not _fast_known(p, model)):
            _remember(p, model, fast=False)
        return None
    except (ValueError, KeyError, IndexError, AttributeError, TypeError):
        if not _fast_known(p, model):
            _remember(p, model, fast=False)
        return None
    except (http.client.HTTPException, OSError):
        return None
    _remember(p, model, fast=True)
    return {"content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "usage": d.get("usage") or {},
            "model": d.get("model") or model}


def call(system, messages, *, model="small", effort=None, tools=None, tool_choice=None, max_tokens=16000,
         stream=False, on_event=None, fast=False, timeout=180, provider=None, on_block=None, cancel=None):
    """One Messages API call: the reply {content, stop_reason, usage, model}.

    effort (minimal|low|medium|high|max): adaptive thinking and
    output_config.effort, dropped for good when the server refuses them (a
    400 naming them), and when a tool is forced (they don't go together).
    A 400 naming max_tokens: asked again with half (not below 4096). stream
    or on_event: the reply streamed, each event to on_event. on_block: each
    tool call ({type, id, name, input}) as soon as it is complete, while the
    rest still streams. cancel (a Cancel): stopped from another thread
    (Cancelled). fast with no tools: Meta's chat endpoint first (see _fast).
    Retried on 429/5xx/529 and the network, with backoff and the server's
    retry-after."""
    import urllib.error
    p = provider or Provider.from_env()
    model_id = p.model(model)
    if not model_id:
        raise AIError(NO_MODEL)
    if fast and not tools and _fast_known(p, model_id) is not False:
        msg = _fast(p, model_id, system, messages, max_tokens, timeout)
        if msg is not None:
            if on_event:
                synthesize(msg, on_event)
            return msg
    effort = effort if effort in EFFORTS else None
    forced = bool(tool_choice) and tool_choice.get("type") in ("tool", "any")
    stream = bool(stream or on_event or on_block)
    st = _st(p, model_id)
    limit = min(max_tokens, st["max_tokens"] or max_tokens)
    while True:
        body = {"model": model_id, "max_tokens": limit, "system": system, "messages": messages}
        if tools:
            body["tools"] = tools
        if tool_choice:
            body["tool_choice"] = tool_choice
        tuned = bool(effort) and _tuning_ok(p, model_id, effort) and not forced
        if tuned:
            body["thinking"] = {"type": "adaptive"}
            body["output_config"] = {"effort": effort}
        if stream:
            body["stream"] = True
        try:
            return _send(p, body, stream, on_event, timeout, on_block, cancel)
        except urllib.error.HTTPError as e:
            detail = http_detail(e)
            if e.code == 400 and tuned and any(w in detail for w in ("thinking", "effort", "output_config")):
                if effort == "minimal":
                    _remember(p, model_id, minimal=False)
                else:
                    _remember(p, model_id, tuning=False)
                continue
            if e.code == 400 and "max_tokens" in detail and limit > 4096:
                limit = max(4096, limit // 2)
                st["max_tokens"] = limit
                continue
            if e.code in (401, 403):
                # A key changed or revoked: asked again next time, not in 10 min.
                with _ENV_LOCK:
                    _ENV["result"] = None
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
    reply missing a required key is told so once. fast: Meta's chat
    endpoint first (the JSON as text, reasoning_effort minimal). AIError
    when it fails."""
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
    if fast:
        # Meta's chat endpoint first (reasoning_effort "minimal"): the JSON
        # as text, the Messages API when it isn't there or the JSON isn't.
        p = provider or Provider.from_env()
        provider = p
        model_id = p.model(model)
        if model_id and _fast_known(p, model_id) is not False:
            msg = _fast(p, model_id, base + "\n\nAnswer with the JSON object alone, nothing else: "
                        + json.dumps(input_schema, ensure_ascii=False), messages, max_tokens, timeout)
            if msg is not None:
                value, why = _structured(msg, schema, wrapped)
                if why is None:
                    return value
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
RISKY_ACTION = re.compile(r"^(delete|remove|clear|purge|empty|reply|send|react)", re.I)
# A click on such a button (ui_act/click on an element named so).
RISKY_TARGET = re.compile(r"\b(delete|remove|send|reply|pay|buy|purchase|order|checkout|unsubscribe|empty trash|"
                          r"erase|format|uninstall|supprimer|envoyer|payer|acheter|l(ö|oe)schen|senden|x(ó|o)a|g(ử|u)i)\b", re.I)
HARMLESS_TOOL = re.compile(r"(queue|playlist|playback|volume|seek|repeat|shuffle)", re.I)
# Chat apps through their page (desktop-mcp's page_act): Enter, or a form
# submitted, in the message box sends the message.
CHAT_TARGETS = re.compile(r"^(discord|slack)(:|$)", re.I)


def page_act_risky(args):
    """A page click/submit/key on a "Send", "Pay"… element, or Enter in a chat app."""
    args = args if isinstance(args, dict) else {}
    action = str(args.get("action") or "")
    if action not in ("click", "submit", "press"):
        return False
    if RISKY_TARGET.search(str(args.get("name") or "")):
        return True
    key = str(args.get("value") or "Enter")
    return bool(CHAT_TARGETS.match(str(args.get("target") or ""))) and (
        action == "submit" or (action == "press" and re.search(r"(^|\+)\s*(enter|return)$", key, re.I) is not None
                               and not re.search(r"shift", key, re.I)))


def _bare(name, meta):
    """A tool's own name: meta's, else without an mcp__server__ prefix."""
    tool = (meta or {}).get(name, {}).get("tool") if isinstance(meta, dict) else None
    if tool:
        return str(tool)
    m = re.match(r"^mcp__[^_]+(?:_[^_]+)*?__(.+)$", str(name))
    return m.group(1) if m else str(name)


# Tools that only read whatever their arguments (the terminal's and the
# editor's: what is on screen, the file in front).
READ_ONLY_TOOLS = {"terminal_list", "terminal_read", "editor_read"}


def reads_only(name, args, meta=None):
    """True for a call that only reads: a tool annotated read-only (meta:
    {name: {read_only}}), or a multi-purpose tool asked a reading action."""
    if isinstance(meta, dict) and meta.get(name, {}).get("read_only"):
        return True
    if _bare(name, meta) in READ_ONLY_TOOLS:
        return True
    action = str((args or {}).get("action") or "").lower()
    return action in READ_ACTIONS


# The shell's generic IPC (desktop-mcp's shell_ipc): its `function` is the
# action (target and function, not `action`, so it used to pass as never
# risky and promotable as a whole: notifications.reply, history clear…).
IPC_RISKY_FUNCTION = re.compile(r"^(delete|remove|clear|purge|empty|reply|send|react|invoke|forget|wipe)", re.I)


def is_risky(name, args, meta=None):
    tool = _bare(name, meta)
    if tool == "shell_ipc":
        args = args if isinstance(args, dict) else {}
        fn = str(args.get("function") or "")
        return bool(IPC_RISKY_FUNCTION.match(fn)) or bool(RISKY_TARGET.search(
            " ".join(str(v) for v in (args.get("args") or []) if isinstance(v, str)) if isinstance(args.get("args"), list) else ""))
    if tool == "terminal_run":
        # A command: risky by what it does (command_risk), and when it can't be read.
        return command_risk((args or {}).get("command") if isinstance(args, dict) else None)[0]
    if HARMLESS_TOOL.search(tool):
        return False
    if RISKY_TOOL.search(tool):
        return True
    action = str((args or {}).get("action") or "")
    if RISKY_ACTION.match(action):
        return True
    if tool in ("browser_act", "page_act"):
        # A click (or a form sent) on a "Send", "Pay", "Order"… button; Enter in a chat.
        return page_act_risky(args)
    if tool in ("ui_act", "click", "notification_action"):
        said = " ".join(str(v) for v in (args or {}).values() if isinstance(v, str))
        return bool(RISKY_TARGET.search(said))
    return False


# ── Commands (terminal_run): their kind and their risk ─────────────────────
# A command line is read as the shell would split it (shlex, its operators
# kept): segments joined by && || ; | &, each with its words (assignments
# and wrappers like env, nohup, timeout, xargs, `bash -c "…"` unwrapped:
# what really runs) and its redirections; $(…), `…`, <(…) and find's -exec
# read as commands of their own. A line that can't be read is risky.

# Tools whose first word after them is part of the kind (`git status`,
# `cargo test`): the options they take an argument for are skipped first.
SUBCOMMAND_TOOLS = {
    "git": {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"},
    "cargo": {"-C", "--config", "-Z", "--manifest-path", "--color"},
    "npm": {"--prefix", "-w", "--workspace"}, "pnpm": {"-C", "--dir", "--filter", "-F"},
    "yarn": {"--cwd"}, "go": {"-C"}, "nix": {"--option", "-I", "--extra-experimental-features", "--log-format"},
    "make": {"-C", "-f", "--file", "--directory", "-j", "-l", "-o", "-W"},
    "docker": {"-H", "--host", "--context", "-c", "--config", "-l", "--log-level"},
    "podman": {"--connection", "-c", "--url", "--root", "--runroot", "--log-level"},
    "kubectl": {"-n", "--namespace", "--context", "--kubeconfig", "--cluster", "--user", "-s", "--server"},
    "colmena": {"-f", "--config", "--show-trace"},
    "systemctl": {"-H", "--host", "-M", "--machine", "-t", "--type", "-p", "--property", "-n", "--lines", "-o",
                  "--output"},
}
# What only wraps the real command: env, nohup, timeout… (the options that
# take an argument, then for timeout its duration).
COMMAND_WRAPPERS = {
    "env": {"-u", "--unset", "-C", "--chdir"}, "nohup": set(), "time": {"-f", "--format", "-o", "--output"},
    "command": set(), "builtin": set(), "exec": {"-a"}, "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "--class", "-n", "--classdata", "-p"}, "stdbuf": {"-i", "-o", "-e"},
    "timeout": {"-s", "--signal", "-k", "--kill-after"}, "setsid": set(), "unbuffer": set(), "chronic": set(),
    "caffeinate": set(), "xargs": {"-I", "-i", "-n", "--max-args", "-P", "--max-procs", "-d", "--delimiter", "-a",
                                   "--arg-file", "-L", "-s", "-E", "-e"},
    "watch": {"-n", "--interval", "-d"}, "systemd-inhibit": {"--what", "--who", "--why", "--mode"},
}
# Heads skipped when naming a command's kind: `cd x && cargo test` is a
# cargo test.
COMMAND_PREAMBLE = {"cd", "pushd", "popd", "export", "set", "unset", "true", ":", "shopt", "ulimit", "umask"}
SHELL_NAMES = {"sh", "bash", "zsh", "dash", "fish", "ksh", "mksh", "ash", "busybox"}
# What runs whatever it is given (a pipe into one, `bash <(curl …)`).
INTERPRETERS = SHELL_NAMES | {"python", "python3", "perl", "ruby", "node", "deno", "bun", "php", "lua", "source", "."}
PRIVILEGE_TOOLS = {"sudo", "su", "doas", "pkexec", "run0", "sudoedit", "machinectl"}
# Kinds always asked whatever the arguments (`rm` alone too): what they
# can do is rarely undone. A risky command of another kind gets `-risky`
# (`terminal_run:echo-risky` for `echo x > /dev/sda`), never promoted either.
TERMINAL_NEVER = {
    "rm", "dd", "shred", "wipefs", "fdisk", "sfdisk", "parted", "sgdisk", "mkswap", "blkdiscard", "chmod", "chown",
    "chgrp", "kill", "pkill", "killall", "xkill", "shutdown", "reboot", "poweroff", "halt", "git-push", "git-reset",
    "git-clean", "git-rebase", "git-filter-branch", "git-filter-repo", "systemctl-stop", "systemctl-restart",
    "systemctl-disable", "systemctl-mask", "systemctl-kill", "systemctl-poweroff", "systemctl-reboot",
    "systemctl-halt", "systemctl-isolate", "nix-collect-garbage", "nixos-rebuild", "nixos-install", "colmena-apply",
    "colmena-apply-local", "npm-publish", "pnpm-publish", "yarn-publish", "cargo-publish", "kubectl-delete",
    "kubectl-apply", "kubectl-replace", "kubectl-drain", "kubectl-patch", "docker-rm", "docker-rmi", "podman-rm",
    "podman-rmi", "eval", "unparsed", "empty", *SHELL_NAMES, *PRIVILEGE_TOOLS,
}
COMMAND_SEPARATORS = {"&&", "||", ";", "|", "&", "|&", ";;", ";&", "(", ")", "((", "))", "{", "}"}
DEV_SAFE = re.compile(r"^/dev/(null|zero|stdout|stderr|stdin|tty|fd/\d+|shm/.*)$")
GLOB = re.compile(r"[*?\[{]")


def _word(w):
    return os.path.basename(str(w)).lower()


def _inner_commands(command):
    """The commands inside $(…), <(…), >(…) and `…`, or None when the
    parentheses don't close."""
    out = re.findall(r"`([^`]*)`", command)
    i, n = 0, len(command)
    while i < n - 1:
        if command[i] in "$<>" and command[i + 1] == "(":
            arith = command[i] == "$" and command[i + 2:i + 3] == "("
            depth, j = 0, i + 1
            while j < n:
                if command[j] == "(":
                    depth += 1
                elif command[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if depth:
                return None
            if not arith:
                out.append(command[i + 2:j])
            i = j
        i += 1
    return out


def _tokens(command):
    import shlex
    lex = shlex.shlex(command.replace("\r", " ").replace("\n", " ; "), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    return list(lex)


def _skip_options(words, takes_arg):
    """The words after the leading options (and their arguments)."""
    i = 0
    while i < len(words):
        w = words[i]
        if w == "--":
            return words[i + 1:]
        if not w.startswith("-") or w == "-":
            break
        i += 2 if w in takes_arg else 1
    return words[i:]


def _unwrap(words, depth):
    """(the words that really run, the command strings they run besides:
    `bash -c STR`'s STR, find's -exec, the wrappers they came through)."""
    extra, via = [], set()
    for _ in range(8):
        while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
            words = words[1:]
        if not words:
            return words, extra, via
        h = _word(words[0])
        if h in COMMAND_WRAPPERS:
            via.add(h)
            rest = _skip_options(words[1:], COMMAND_WRAPPERS[h])
            if h == "env":
                while rest and "=" in rest[0] and not rest[0].startswith("-"):
                    rest = rest[1:]
            if h == "timeout" and rest:
                rest = rest[1:]
            if h == "watch" and len(rest) == 1:  # watch "a command"
                extra.append(rest[0])
                return [], extra, via
            words = rest
            continue
        if h in SHELL_NAMES:
            for k, w in enumerate(words[1:], 1):
                if w.startswith("-") and not w.startswith("--") and "c" in w[1:]:
                    if k + 1 < len(words):
                        extra.append(words[k + 1])
                        return [], extra, via
                    break
        if h == "find":
            for k, w in enumerate(words):
                if w in ("-exec", "-execdir", "-ok", "-okdir") and k + 1 < len(words):
                    tail = words[k + 1:]
                    end = next((m for m, x in enumerate(tail) if x in (";", "+", "\\;")), len(tail))
                    extra.append(" ".join(_quote(x) for x in tail[:end]) or "true")
        return words, extra, via
    return words, extra, via


def _quote(w):
    import shlex
    return shlex.quote(w)


def command_segments(command, depth=0):
    """[{words, redirects, piped (fed by a pipe), via (wrappers)}] of a
    command line, or None when it can't be read."""
    if not isinstance(command, str) or depth > 4:
        return None
    inner = _inner_commands(command)
    if inner is None:
        return None
    try:
        tokens = _tokens(command)
    except ValueError:
        return None
    segments, cur, redirects, piped = [], [], [], False
    pending_redirect = False

    def close(sep):
        nonlocal cur, redirects, piped
        if cur or redirects:
            words, extra, via = _unwrap(cur, depth)
            segments.append({"words": words, "redirects": redirects, "piped": piped, "via": via})
            for e in extra:
                sub = command_segments(e, depth + 1)
                if sub is None:
                    raise ValueError("unreadable")
                segments.extend(sub)
            piped = sep in ("|", "|&")
        elif sep not in ("(", ")", "{", "}", "((", "))"):
            piped = False
        cur, redirects = [], []

    try:
        for t in tokens:
            if pending_redirect:
                redirects.append(t)
                pending_redirect = False
                continue
            if t and set(t) <= set("<>&|;()") and ("<" in t or ">" in t):
                # A redirection: its target next (not for >&2-style ones,
                # whose digit is the next word: harmless either way).
                pending_redirect = True
                continue
            if t in COMMAND_SEPARATORS or (t and set(t) <= set("&|;()")):
                close(t)
                continue
            cur.append(t)
        close(";")
        for e in inner:
            sub = command_segments(e, depth + 1)
            if sub is None:
                return None
            segments.extend(sub)
    except ValueError:
        return None
    return segments


def command_head(words):
    """A command's kind: its first word, and its subcommand for git, cargo,
    npm… (`git-status`, `cargo-test`); "" without words."""
    if not words:
        return ""
    h = _word(words[0])
    if h in SUBCOMMAND_TOOLS:
        rest = [w for w in _skip_options(words[1:], SUBCOMMAND_TOOLS[h]) if not w.startswith("+")]
        if h == "make":
            rest = [w for w in rest if "=" not in w and not w.startswith("-")]
        sub = _class_part(rest[0], 30) if rest else ""
        return h + ("-" + sub if sub else "")
    return _class_part(h, 40)


def _flags(args):
    short, long_ = set(), set()
    for a in args:
        if a.startswith("--"):
            long_.add(a.split("=", 1)[0])
        elif a.startswith("-") and len(a) > 1:
            short.update(a[1:])
    return short, long_


def _nonopts(args):
    return [a for a in args if not a.startswith("-")]


def segment_risk(seg, whole):
    """Why this segment is risky, or ""."""
    words, redirects = seg["words"], seg["redirects"]
    for r in redirects:
        if r.startswith("/dev/") and not DEV_SAFE.match(r):
            return f"writes to {r}"
    if not words:
        return ""
    b, args = _word(words[0]), words[1:]
    short, long_ = _flags(args)
    plain = _nonopts(args)
    head = command_head(words)
    sub = head.split("-", 1)[1] if "-" in head and b in SUBCOMMAND_TOOLS else ""
    if b in PRIVILEGE_TOOLS:
        return "runs as another user"
    if b == "rm" and (short & set("rRf") or long_ & {"--recursive", "--force", "--no-preserve-root"}
                      or any(GLOB.search(a) for a in plain) or "xargs" in seg.get("via", ())):
        return "deletes recursively, by force or by a pattern"
    if b == "find" and "-delete" in args:
        return "deletes what it finds"
    if b in ("dd", "shred", "wipefs", "fdisk", "sfdisk", "cfdisk", "parted", "sgdisk", "mkswap", "blkdiscard") \
            or b.startswith("mkfs"):
        return "writes to a disk"
    if b in ("chmod", "chown", "chgrp") and ("R" in short or "--recursive" in long_):
        return "changes permissions recursively"
    if b in ("kill", "pkill", "killall", "xkill"):
        return "stops processes"
    if b in ("shutdown", "reboot", "poweroff", "halt"):
        return "turns the computer off or restarts it"
    if b == "tee" and any(a.startswith("/dev/") and not DEV_SAFE.match(a) for a in plain):
        return "writes to a device"
    if b == "eval":
        return "runs a string as a command"
    if b in INTERPRETERS and seg.get("piped"):
        return "runs what is piped into it"
    if b in INTERPRETERS and re.search(r"\b(curl|wget)\b", whole):
        return "runs something downloaded"
    if b == "git":
        rest = _skip_options(args, SUBCOMMAND_TOOLS["git"])
        r_short, r_long = _flags(rest[1:])
        r_plain = _nonopts(rest[1:])
        if sub == "push":
            return "pushes to a remote"
        if sub == "reset" and r_long & {"--hard", "--merge", "--keep"}:
            return "drops changes (reset --hard)"
        if sub == "clean" and ("f" in r_short or "--force" in r_long):
            return "deletes untracked files"
        if sub == "checkout" and ("--" in rest or "." in r_plain or "f" in r_short or "--force" in r_long):
            return "drops changes (checkout --)"
        if sub == "restore" and ("--worktree" in r_long or "W" in r_short
                                 or not ("--staged" in r_long or "S" in r_short)):
            return "drops changes (restore)"
        if sub in ("rebase", "filter-branch", "filter-repo"):
            return "rewrites history"
        if sub == "branch" and ("D" in r_short or ("d" in r_short and "f" in r_short) or "--delete" in r_long
                                and "--force" in r_long):
            return "deletes a branch"
        if sub == "stash" and r_plain[:1] in (["drop"], ["clear"]):
            return "drops stashed changes"
        if sub in ("reflog", "update-ref") and ("expire" in r_plain or "delete" in r_plain or "d" in r_short):
            return "drops history"
        return ""
    if b == "systemctl" and sub in ("stop", "restart", "disable", "mask", "kill", "poweroff", "reboot", "halt",
                                    "isolate", "suspend", "hibernate", "try-restart", "reload-or-restart"):
        return "stops, restarts or disables a service"
    if b == "loginctl" and plain[:1] and re.match(r"^(terminate|kill|poweroff|reboot)", plain[0]):
        return "ends a session"
    if b == "nix-collect-garbage" or (b == "nix-store" and long_ & {"--gc", "--delete"}) \
            or (b == "nix" and plain[:2] in (["store", "gc"], ["store", "delete"])) \
            or (b == "nix-env" and ("e" in short or long_ & {"--uninstall", "--delete-generations"})) \
            or (b == "nix" and plain[:1] == ["profile"] and plain[1:2] in (["remove"], ["wipe-history"])):
        return "deletes from the Nix store or profile"
    if b == "colmena" and plain[:1] in (["apply"], ["apply-local"]):
        return "deploys the system"
    if b in ("nixos-rebuild", "darwin-rebuild") and set(plain) & {"switch", "boot", "test"}:
        return "switches the system"
    if b == "nixos-install" or (b == "home-manager" and "switch" in plain):
        return "switches the configuration"
    if b in ("docker", "podman") and set(plain) & {"rm", "rmi", "prune", "kill", "down"}:
        return "removes containers, images or volumes"
    if b == "kubectl" and sub in ("delete", "apply", "replace", "drain", "patch", "cordon", "taint", "scale") \
            or b == "kubectl" and sub == "rollout" and set(plain) & {"restart", "undo"}:
        return "changes a cluster"
    if b == "helm" and plain[:1] and plain[0] in ("uninstall", "delete", "rollback", "upgrade", "install"):
        return "changes a cluster"
    if b in ("npm", "pnpm", "yarn") and sub in ("publish", "unpublish", "deprecate"):
        return "publishes a package"
    if b == "cargo" and sub in ("publish", "yank"):
        return "publishes a crate"
    if b == "twine" and "upload" in plain or b == "gh" and plain[:2] in (["repo", "delete"], ["release", "delete"]):
        return "publishes or deletes online"
    if b == "crontab" and "r" in short:
        return "deletes the crontab"
    return ""


def command_risk(command):
    """(risky, why, the kind's head): the head of the risky part when one is."""
    segments = command_segments(command)
    if segments is None:
        return True, "can't be read", "unparsed"
    segments = [s for s in segments if s["words"] or s["redirects"]]
    if not segments:
        return True, "empty", "empty"
    for s in segments:
        why = segment_risk(s, command)
        if why:
            head = command_head(s["words"]) or "redirect"
            if head not in TERMINAL_NEVER and not head.startswith("mkfs"):
                head += "-risky"
            return True, why, head
    main = next((s for s in segments if s["words"] and _word(s["words"][0]) not in COMMAND_PREAMBLE), None)
    main = main or next((s for s in segments if s["words"]), None)
    return False, "", command_head(main["words"]) if main else "empty"


def terminal_never(action):
    """Whether a terminal_run kind (`git-push`, `echo-risky`) is always asked."""
    action = str(action or "")
    return action in TERMINAL_NEVER or action.startswith("mkfs") or action.endswith("-risky") or not action


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
    if tool == "terminal_run":
        # A command's kind: `terminal_run:git-status`; a risky one by its
        # risky part, never promoted (terminal_never).
        return cls + ":" + (_class_part(command_risk(args.get("command"))[2], 60) or "empty")
    if tool == "shell_ipc":
        # `shell_ipc:reply@notifications`: the function as the action (so
        # the never-promoted ones stay asked), the target as where.
        fn, target = _class_part(args.get("function"), 40), _class_part(args.get("target"), 40)
        return cls + (":" + fn if fn else "") + ("@" + target if target else "")
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
    if s["status"] == "timeout":
        return line + ": waited for your OK, not done"
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
    # Steps that waited for an OK nobody gave: still the user's to decide.
    waited = [step_line(s) for s in steps if s["status"] == "timeout"]
    if waited and not needs:
        needs = waited[:8]
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
