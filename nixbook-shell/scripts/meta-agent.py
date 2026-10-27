"""nixbook-meta-agent: the shell's headless agent on Meta's Model API (Muse).

Every agent the shell starts (the side panel's Muse, the equalizer agent,
the desktop memory's passes and routine runs, nixbook-improve) runs through
this script: one prompt (or a stream of them), the model, its tools (a few
built-ins and the MCP servers it is given) in a loop until it answers. Its
command line is the usual print-mode agent one (-p, --output-format
stream-json, --mcp-config, --resume…) and its events the usual stream-json
shapes (system/init, stream_event, assistant, user, result), so the callers
and their parsers changed little when the shell moved to it.

The model is reached through a Messages API endpoint (POST
$NIXBOOK_AI_BASE_URL/v1/messages, `Authorization: Bearer $NIXBOOK_AI_KEY`;
the `anthropic-version` header is just the wire protocol Meta's API speaks).
Without a key in the environment the script re-runs itself through
`nixbook-model-provider run`, which sets NIXBOOK_AI_* from the shell's
settings and the keyring.

    nixbook-meta-agent [-p] [options]      the prompt on stdin (plain text)

  --model M                  small | main | big, or a provider model id
                             (haiku → small, sonnet/default → main,
                             opus/fable → big)
  --effort low|medium|high   adaptive thinking + output_config.effort
  --system-prompt S / --append-system-prompt S
  --output-format text|json|stream-json
  --input-format text|stream-json      stream-json: one turn per stdin line
  --include-partial-messages           stream-json: the deltas too
  --json-schema S            the answer as JSON for S (a final
                             `structured_output` tool call)
  --mcp-config JSON|FILE     stdio (or streamable HTTP) MCP servers
  --tools LIST               built-ins: Read Glob Grep Edit Write Bash
                             WebFetch WebSearch ("" = none, the default)
  --allowedTools / --disallowedTools LIST
  --add-dir DIR / --write-dir DIR      what the file tools may read / write
  --permission-mode acceptEdits        the working directory writable
  --sandbox JSON             Bash in bubblewrap: {read, write, deny}
  --max-turns N              (30)
  --resume ID / --session-id ID / --no-session-persistence
  --privacy                  tools other than the desktop server's: their
                             inputs unmasked, their results masked
                             (nixbook-desktop-mcp privacy)

Stdlib only.
"""

import base64
import concurrent.futures
import fnmatch
import hashlib
import html
import html.parser
import ipaddress
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

BUILTINS = ("Read", "Glob", "Grep", "Edit", "Write", "Bash", "WebFetch", "WebSearch")
# Flags that take a value, and those that take one or more (variadic: every
# following argument not starting with "-").
VALUE_FLAGS = {"--model", "--effort", "--system-prompt", "--append-system-prompt", "--output-format",
               "--input-format", "--json-schema", "--tools", "--sandbox", "--max-turns", "--max-budget-usd",
               "--resume", "-r", "--session-id", "--setting-sources", "--settings", "--permission-mode", "--name",
               "--fallback-model", "--system-prompt-file", "--append-system-prompt-file", "--agents",
               "--permission-prompt-tool", "--debug-file"}
MULTI_FLAGS = {"--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools", "--add-dir",
               "--write-dir", "--mcp-config", "--plugin-dir", "--betas"}
BOOL_FLAGS = {"-p", "--print", "--verbose", "--include-partial-messages", "--strict-mcp-config",
              "--no-session-persistence", "--privacy", "--restricted", "--safe-mode", "--continue", "-c",
              "--dangerously-skip-permissions", "--fork-session", "--replay-user-messages", "--debug", "-d"}

MAX_TOKENS = int(os.environ.get("NIXBOOK_AI_MAX_TOKENS") or 16000)
TOOL_OUTPUT_MAX = 60000
READ_LINES = 2000
LINE_MAX = 2000
IMAGE_MAX = 5 * 1024 * 1024
FETCH_MAX = 100_000
BASH_TIMEOUT = 120
BASH_TIMEOUT_MAX = 600
BASH_OUTPUT_MAX = 30000
MCP_INIT_TIMEOUT = float(os.environ.get("NIXBOOK_AGENT_MCP_INIT_TIMEOUT") or 30)
MCP_CALL_TIMEOUT = float(os.environ.get("NIXBOOK_AGENT_MCP_TIMEOUT") or 300)
SESSION_DAYS = 7
IMAGE_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
               ".webp": "image/webp"}
SKIP_DIRS = {".git", "node_modules", ".direnv", "__pycache__", ".devenv", "result"}
# The tool name the forced final answer goes through (--json-schema).
STRUCTURED = "structured_output"

DEFAULT_SYSTEM = (
    "You are Muse, the AI agent built into the user's desktop (nixbook: NixOS, the niri compositor and its own "
    "shell), running without a window for one task. Do what is asked with the tools you are given: act rather "
    "than describe, put several independent tool calls in one turn, and stop as soon as the task is done. Then "
    "answer plainly and briefly with what you did or found; never invent results, and say what you could not do."
)


class AgentError(Exception):
    pass


# The commands Bash is running: stopped with the agent.
CHILDREN = set()


def kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        try:
            proc.kill()
        except OSError:
            pass


# ── Small helpers ──────────────────────────────────────────────────────────

def warn(msg):
    sys.stderr.write(f"nixbook-meta-agent: {msg}\n")
    sys.stderr.flush()


def split_list(values):
    """Comma or space separated names, a pattern's parentheses kept whole
    (`Edit(//a b/**)`)."""
    out = []
    for v in values:
        cur, depth = "", 0
        for ch in str(v):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth = max(0, depth - 1)
            if depth == 0 and (ch == "," or ch.isspace()):
                if cur.strip():
                    out.append(cur.strip())
                cur = ""
                continue
            cur += ch
        if cur.strip():
            out.append(cur.strip())
    return out


def child_env(extra=None):
    """The environment of what the agent starts: never the provider's key."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("NIXBOOK_AI_")}
    if extra:
        env.update({str(k): str(v) for k, v in extra.items()})
    return env


def cap(text, limit=TOOL_OUTPUT_MAX):
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n… [{len(text) - limit} more characters cut]"


def expand(path, cwd):
    path = os.path.expanduser(str(path))
    if path.startswith("//"):
        path = path[1:]
    if not os.path.isabs(path):
        path = os.path.join(cwd, path)
    return os.path.realpath(path)


def inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def glob_regex(pattern):
    """A gitignore-style glob (`**` any depth) as a regex on absolute paths."""
    out, i = "", 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
            continue
        if pattern.startswith("**", i):
            out += ".*"
            i += 2
            continue
        out += "[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c)
        i += 1
    return re.compile(out + r"(?:/.*)?$")


# ── Options ────────────────────────────────────────────────────────────────

class Options:
    def __init__(self, argv):
        self.model = ""
        self.effort = ""
        self.system_prompt = None
        self.append_system = []
        self.output_format = "text"
        self.input_format = "text"
        self.partial = False
        self.json_schema = None
        self.mcp_configs = []
        self.tools = None
        self.allowed = []
        self.disallowed = []
        self.add_dirs = []
        self.write_dirs = []
        self.sandbox = None
        self.max_turns = 30
        self.resume = ""
        self.session_id = ""
        self.persist = True
        self.privacy = False
        self.permission_mode = ""
        self.prompt_args = []
        self.parse(argv)

    def parse(self, argv):
        args = list(argv)
        i = 0
        while i < len(args):
            a = args[i]
            i += 1
            if a == "--":
                self.prompt_args += args[i:]
                break
            name, value = (a.split("=", 1) + [None])[:2] if a.startswith("--") and "=" in a else (a, None)
            if name in BOOL_FLAGS:
                self.flag(name, True)
            elif name in VALUE_FLAGS:
                if value is None:
                    if i >= len(args):
                        raise AgentError(f"{name} needs a value")
                    value = args[i]
                    i += 1
                self.flag(name, value)
            elif name in MULTI_FLAGS:
                # One value or more (variadic options): the next argument
                # always, then those not starting with "-".
                if value is None:
                    if i >= len(args):
                        raise AgentError(f"{name} needs a value")
                    values = [args[i]]
                    i += 1
                    while i < len(args) and not args[i].startswith("-"):
                        values.append(args[i])
                        i += 1
                else:
                    values = [value]
                for v in values:
                    self.flag(name, v)
            elif a.startswith("-") and a != "-":
                warn(f"unknown option {a} (ignored)")
            else:
                self.prompt_args.append(a)

    def flag(self, name, v):
        if name == "--model":
            self.model = v
        elif name == "--effort":
            self.effort = str(v).strip().lower()
        elif name == "--system-prompt":
            self.system_prompt = v
        elif name == "--system-prompt-file":
            with open(v, encoding="utf-8") as f:
                self.system_prompt = f.read()
        elif name == "--append-system-prompt":
            self.append_system.append(v)
        elif name == "--append-system-prompt-file":
            with open(v, encoding="utf-8") as f:
                self.append_system.append(f.read())
        elif name == "--output-format":
            if v not in ("text", "json", "stream-json"):
                raise AgentError(f"--output-format: text, json or stream-json, not {v}")
            self.output_format = v
        elif name == "--input-format":
            if v not in ("text", "stream-json"):
                raise AgentError(f"--input-format: text or stream-json, not {v}")
            self.input_format = v
        elif name == "--include-partial-messages":
            self.partial = True
        elif name == "--json-schema":
            try:
                self.json_schema = json.loads(v) if str(v).lstrip().startswith("{") else json.load(open(v, encoding="utf-8"))
            except (OSError, ValueError) as e:
                raise AgentError(f"--json-schema: not a JSON schema ({e})")
        elif name == "--mcp-config":
            self.mcp_configs.append(v)
        elif name == "--tools":
            self.tools = split_list([v])
        elif name in ("--allowedTools", "--allowed-tools"):
            self.allowed += split_list([v])
        elif name in ("--disallowedTools", "--disallowed-tools"):
            self.disallowed += split_list([v])
        elif name == "--add-dir":
            self.add_dirs.append(v)
        elif name == "--write-dir":
            self.write_dirs.append(v)
        elif name == "--sandbox":
            try:
                self.sandbox = json.loads(v) if str(v).lstrip().startswith("{") else json.load(open(v, encoding="utf-8"))
                if not isinstance(self.sandbox, dict):
                    raise ValueError("an object is expected")
            except (OSError, ValueError) as e:
                raise AgentError(f"--sandbox: {e}")
        elif name == "--max-turns":
            try:
                self.max_turns = max(1, int(v))
            except ValueError:
                raise AgentError(f"--max-turns: a number, not {v}")
        elif name in ("--resume", "-r"):
            self.resume = v
        elif name == "--session-id":
            self.session_id = v
        elif name == "--no-session-persistence":
            self.persist = False
        elif name == "--privacy":
            self.privacy = True
        elif name == "--permission-mode":
            self.permission_mode = v
        # Everything else is accepted for compatibility and ignored.


# ── The provider ───────────────────────────────────────────────────────────

class Provider:
    def __init__(self, opts):
        env = os.environ
        self.base = env.get("NIXBOOK_AI_BASE_URL", "").rstrip("/")
        self.key = env.get("NIXBOOK_AI_KEY", "")
        main = env.get("NIXBOOK_AI_MODEL", "")
        self.models = {"main": main, "small": env.get("NIXBOOK_AI_SMALL_MODEL") or main,
                       "big": env.get("NIXBOOK_AI_BIG_MODEL") or main}
        self.model = self.resolve(opts.model)
        self.effort = opts.effort if opts.effort in ("low", "medium", "high", "max", "minimal") else ""
        # Off for the rest of the run once the server refused them.
        self.tuning = bool(self.effort)
        self.max_tokens = MAX_TOKENS
        if not self.base or not self.key:
            raise AgentError("no model provider with an API key (Settings > Desktop agents > Model provider)")
        if not self.model:
            raise AgentError("no model set for the provider (Settings > Desktop agents > Model provider)")

    def resolve(self, name):
        n = str(name or "").strip()
        low = n.lower()
        if low in ("", "main", "default") or "sonnet" in low:
            return self.models["main"]
        if low == "small" or "haiku" in low:
            return self.models["small"]
        if low == "big" or "opus" in low or "fable" in low:
            return self.models["big"]
        return n

    def request(self, body, stream):
        data = json.dumps(body).encode()
        headers = {"Authorization": f"Bearer {self.key}", "anthropic-version": "2023-06-01",
                   "content-type": "application/json"}
        if stream:
            headers["accept"] = "text/event-stream"
        return urllib.request.Request(self.base + "/v1/messages", data=data, method="POST", headers=headers)

    def call(self, system, messages, tools, tool_choice=None, on_event=None):
        """One model call. Returns the message ({content, stop_reason,
        usage, model}). Streamed when on_event wants the deltas. A server
        refusing the thinking/effort settings is asked again without them,
        one refusing max_tokens with less."""
        stream = on_event is not None
        forced = bool(tool_choice) and tool_choice.get("type") in ("tool", "any")
        while True:
            body = {"model": self.model, "max_tokens": self.max_tokens, "system": system,
                    "messages": api_messages(messages)}
            if tools:
                body["tools"] = tools
            if tool_choice:
                body["tool_choice"] = tool_choice
            # Forcing a tool and thinking don't go together.
            if self.tuning and not forced:
                body["thinking"] = {"type": "adaptive"}
                body["output_config"] = {"effort": self.effort}
            if stream:
                body["stream"] = True
            try:
                return self.send(body, stream, on_event)
            except urllib.error.HTTPError as e:
                detail = http_detail(e)
                if e.code == 400 and self.tuning and not forced and any(
                        w in detail for w in ("thinking", "effort", "output_config")):
                    self.tuning = False
                    continue
                if e.code == 400 and "max_tokens" in detail and self.max_tokens > 4096:
                    self.max_tokens = max(4096, self.max_tokens // 2)
                    continue
                if e.code == 400 and stream and "stream" in detail:
                    stream = False
                    body.pop("stream", None)
                    continue
                raise AgentError(f"API error: HTTP {e.code}: {detail[:400]}")

    def send(self, body, stream, on_event):
        delay = 1.0
        for attempt in range(4):
            started = [False]

            def relay(ev):
                started[0] = True
                if on_event:
                    on_event(ev)
            try:
                with urllib.request.urlopen(self.request(body, stream), timeout=300) as resp:
                    if stream and "text/event-stream" in (resp.headers.get("content-type") or ""):
                        return read_sse(resp, relay)
                    msg = json.loads(resp.read().decode("utf-8", "replace"))
                    if msg.get("type") == "error":
                        raise AgentError(f"API error: {(msg.get('error') or {}).get('message') or msg}")
                    if stream:
                        synthesize(msg, relay)
                    return normalize_message(msg)
            except urllib.error.HTTPError as e:
                if e.code in (429, 500, 502, 503, 504, 529) and attempt < 3 and not started[0]:
                    retry = e.headers.get("retry-after") if e.headers else None
                    try:
                        wait = min(30.0, float(retry)) if retry else delay
                    except ValueError:
                        wait = delay
                    e.read()
                    time.sleep(wait)
                    delay *= 3
                    continue
                raise
            except (urllib.error.URLError, socket.timeout, ConnectionError, TimeoutError) as e:
                if attempt < 3 and not started[0]:
                    time.sleep(delay)
                    delay *= 3
                    continue
                raise AgentError(f"API error: {getattr(e, 'reason', e)}")
        raise AgentError("API error: the server kept failing")


def http_detail(e):
    try:
        detail = e.read().decode("utf-8", "replace")
    except OSError:
        detail = ""
    try:
        d = json.loads(detail)
        detail = (d.get("error") or {}).get("message") or d.get("message") or detail
    except (ValueError, AttributeError):
        pass
    return str(detail)


def api_messages(messages):
    """The history as it is sent: no thinking blocks (kept in the
    transcript; Meta's API continues a tool call without them, as Quick AI
    has always done) and no empty text block (refused)."""
    out = []
    for m in messages:
        c = m.get("content")
        if isinstance(c, list):
            kept = [b for b in c if b.get("type") not in ("thinking", "redacted_thinking")
                    and not (b.get("type") == "text" and not str(b.get("text") or "").strip())]
            out.append({**m, "content": kept or [{"type": "text", "text": "…"}]})
        else:
            out.append({**m, "content": c if str(c or "").strip() else "…"})
    return out


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
    """A JSON reply as the stream events it would have been."""
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
            raise AgentError(f"API error: {(ev.get('error') or {}).get('message') or ev}")
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
                    handle(json.loads("\n".join(data_lines)))
                except ValueError:
                    pass
                data_lines = []
            continue
        if line.startswith("data:"):
            data_lines.append(line[5:].lstrip())
    if data_lines:
        try:
            handle(json.loads("\n".join(data_lines)))
        except ValueError:
            pass
    for i, b in blocks.items():
        if b.get("type") == "tool_use" and "input" not in b:
            try:
                b["input"] = json.loads(partial.get(i) or "{}")
            except ValueError:
                b["input"] = {}
    msg["content"] = [blocks[i] for i in sorted(blocks)]
    return normalize_message(msg)


def reexec_through_provider(argv):
    """No key here: the provider's launcher sets it, then runs this again."""
    if os.environ.get("NIXBOOK_AI_KEY") or os.environ.get("NIXBOOK_AI_PROVIDED"):
        return
    provider = shutil.which("nixbook-model-provider")
    if not provider:
        return
    os.execv(provider, [provider, "run", sys.executable, "-I", os.path.abspath(__file__), *argv])


# ── The privacy mask (nixbook-desktop-mcp privacy) ─────────────────────────

class Privacy:
    """With --privacy, every tool but the desktop server's: what the model
    sends it unmasked (the real names reach the tool), what it answers
    masked (`nixbook-desktop-mcp privacy unmask|mask --json`: the same JSON
    back; images blacked out when the user asks for it)."""

    def __init__(self, on):
        self.on = on
        self.exe = shutil.which("nixbook-desktop-mcp") if on else None
        if on and not self.exe:
            warn("--privacy: nixbook-desktop-mcp not found, nothing masked")

    def run(self, verb, data, as_json):
        """DATA through `privacy VERB [--json]`; None when it fails."""
        if not self.on or not self.exe:
            return None
        try:
            p = subprocess.run([self.exe, "privacy", verb, *(["--json"] if as_json else [])], input=data,
                               capture_output=True, text=True, timeout=30, env=child_env())
        except (OSError, subprocess.TimeoutExpired):
            return None
        return p.stdout if p.returncode == 0 else None

    def applies(self, tool_name):
        return self.on and not tool_name.startswith("mcp__desktop__")

    def unmask_input(self, tool_name, args):
        if not self.applies(tool_name):
            return args
        raw = json.dumps(args, ensure_ascii=False)
        if "⟦" not in raw:
            return args
        out = self.run("unmask", raw, True)
        try:
            back = json.loads(out) if out is not None else None
        except ValueError:
            back = None
        if not isinstance(back, dict):
            text = self.run("unmask", raw, False)
            try:
                back = json.loads(text) if text is not None else None
            except ValueError:
                back = None
        return back if isinstance(back, dict) else args

    def mask_result(self, tool_name, content):
        if not self.applies(tool_name):
            return content
        out = self.run("mask", json.dumps(content, ensure_ascii=False), True)
        try:
            back = json.loads(out) if out is not None else None
        except ValueError:
            back = None
        if isinstance(back, type(content)):
            return back
        # The plain-text mask: the text blocks one by one.
        def plain(text):
            masked = self.run("mask", text, False) if text else text
            return text if masked is None else masked
        if isinstance(content, str):
            return plain(content)
        return [{**b, "text": plain(b.get("text", ""))} if b.get("type") == "text" else b for b in content]


# ── MCP clients ────────────────────────────────────────────────────────────

class StdioMcp:
    def __init__(self, name, spec):
        self.name = name
        cmd = [str(spec.get("command") or "")] + [str(a) for a in spec.get("args") or []]
        if not cmd[0]:
            raise AgentError("no command")
        debug = os.environ.get("NIXBOOK_AGENT_DEBUG")
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=None if debug else subprocess.DEVNULL,
                                     env=child_env(spec.get("env") or {}), cwd=spec.get("cwd") or None,
                                     start_new_session=True)
        self.lock = threading.Lock()
        self.cond = threading.Condition()
        self.replies = {}
        self.next_id = 0
        self.dead = False
        threading.Thread(target=self.reader, daemon=True).start()

    def reader(self):
        try:
            for line in self.proc.stdout:
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(msg, dict):
                    continue
                if "method" in msg and "id" in msg:
                    # A request from the server (ping, roots…).
                    reply = {"jsonrpc": "2.0", "id": msg["id"]}
                    if msg["method"] == "ping":
                        reply["result"] = {}
                    elif msg["method"] == "roots/list":
                        reply["result"] = {"roots": []}
                    else:
                        reply["error"] = {"code": -32601, "message": "not supported"}
                    self.write(reply)
                    continue
                if "id" in msg:
                    with self.cond:
                        self.replies[msg["id"]] = msg
                        self.cond.notify_all()
        except (OSError, ValueError):
            pass
        with self.cond:
            self.dead = True
            self.cond.notify_all()

    def write(self, obj):
        data = (json.dumps(obj) + "\n").encode()
        with self.lock:
            self.proc.stdin.write(data)
            self.proc.stdin.flush()

    def rpc(self, method, params, timeout):
        with self.cond:
            self.next_id += 1
            rid = self.next_id
        try:
            self.write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        except (OSError, ValueError):
            raise AgentError(f"MCP server {self.name} is gone")
        deadline = time.monotonic() + timeout
        with self.cond:
            while rid not in self.replies:
                left = deadline - time.monotonic()
                if self.dead:
                    raise AgentError(f"MCP server {self.name} exited")
                if left <= 0:
                    try:
                        self.write({"jsonrpc": "2.0", "method": "notifications/cancelled",
                                    "params": {"requestId": rid, "reason": "timeout"}})
                    except (OSError, ValueError):
                        pass
                    raise AgentError(f"MCP server {self.name}: {method} timed out after {int(timeout)} s")
                self.cond.wait(min(left, 1.0))
            msg = self.replies.pop(rid)
        if "error" in msg:
            err = msg["error"] or {}
            raise AgentError(f"MCP server {self.name}: {err.get('message') or err}")
        return msg.get("result") or {}

    def notify(self, method, params=None):
        try:
            self.write({"jsonrpc": "2.0", "method": method, **({"params": params} if params is not None else {})})
        except (OSError, ValueError):
            pass

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except OSError:
                self.proc.terminate()


class HttpMcp:
    """A streamable HTTP MCP server (JSON or SSE answers)."""

    def __init__(self, name, spec):
        self.name = name
        self.url = str(spec.get("url") or "")
        if not self.url.startswith(("https://", "http://")):
            raise AgentError("no url")
        self.headers = {str(k): str(v) for k, v in (spec.get("headers") or {}).items()}
        self.session = None
        self.next_id = 0
        self.lock = threading.Lock()

    def post(self, obj, timeout):
        headers = {"content-type": "application/json", "accept": "application/json, text/event-stream",
                   **self.headers}
        if self.session:
            headers["mcp-session-id"] = self.session
        r = urllib.request.Request(self.url, data=json.dumps(obj).encode(), method="POST", headers=headers)
        try:
            with urllib.request.urlopen(r, timeout=timeout) as resp:
                sid = resp.headers.get("mcp-session-id")
                if sid:
                    self.session = sid
                if "id" not in obj:
                    return None
                if "text/event-stream" in (resp.headers.get("content-type") or ""):
                    data = []
                    for raw in resp:
                        line = raw.decode("utf-8", "replace").rstrip("\r\n")
                        if line.startswith("data:"):
                            data.append(line[5:].lstrip())
                        elif not line and data:
                            try:
                                msg = json.loads("\n".join(data))
                            except ValueError:
                                msg = None
                            data = []
                            if isinstance(msg, dict) and msg.get("id") == obj["id"]:
                                return msg
                    raise AgentError(f"MCP server {self.name}: no answer")
                body = resp.read().decode("utf-8", "replace")
                return json.loads(body) if body.strip() else {}
        except urllib.error.HTTPError as e:
            raise AgentError(f"MCP server {self.name}: HTTP {e.code}")
        except (urllib.error.URLError, socket.timeout, TimeoutError, ValueError) as e:
            raise AgentError(f"MCP server {self.name}: {e}")

    def rpc(self, method, params, timeout):
        with self.lock:
            self.next_id += 1
            rid = self.next_id
        msg = self.post({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}, timeout) or {}
        if "error" in msg:
            raise AgentError(f"MCP server {self.name}: {(msg['error'] or {}).get('message') or msg['error']}")
        return msg.get("result") or {}

    def notify(self, method, params=None):
        try:
            self.post({"jsonrpc": "2.0", "method": method, **({"params": params} if params is not None else {})}, 10)
        except AgentError:
            pass

    def close(self):
        pass


class Mcp:
    """The configured servers, started in parallel; their tools by the name
    the model sees (mcp__server__tool)."""

    def __init__(self, configs, allowed, disallowed):
        self.servers = {}
        self.status = []
        self.instructions = {}
        self.tools = {}
        specs = {}
        for c in configs:
            try:
                d = json.loads(c) if str(c).lstrip().startswith("{") else json.load(open(os.path.expanduser(c),
                                                                                         encoding="utf-8"))
            except (OSError, ValueError) as e:
                warn(f"--mcp-config {str(c)[:60]}: {e}")
                continue
            specs.update((d or {}).get("mcpServers") or {})
        allow = [a for a in allowed if a.startswith("mcp__")]
        deny = [a for a in disallowed if a.startswith("mcp__")]

        def start(name, spec):
            client = None
            try:
                kind = str(spec.get("type") or ("http" if spec.get("url") else "stdio"))
                if kind == "stdio":
                    client = StdioMcp(name, spec)
                elif kind in ("http", "streamable-http"):
                    client = HttpMcp(name, spec)
                else:
                    raise AgentError(f"transport {kind} isn't supported")
                init = client.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                 "clientInfo": {"name": "nixbook-meta-agent", "version": "1.0"}},
                                  MCP_INIT_TIMEOUT)
                client.notify("notifications/initialized")
                tools, cursor = [], None
                for _ in range(20):
                    page = client.rpc("tools/list", {"cursor": cursor} if cursor else {}, MCP_INIT_TIMEOUT)
                    tools += page.get("tools") or []
                    cursor = page.get("nextCursor")
                    if not cursor:
                        break
                return name, client, init, tools, None
            except Exception as e:  # noqa: BLE001 — a server that fails is left out
                if client is not None:
                    try:
                        client.close()
                    except Exception:  # noqa: BLE001
                        pass
                return name, None, None, [], str(e)

        if not specs:
            return
        with concurrent.futures.ThreadPoolExecutor(min(8, len(specs))) as pool:
            jobs = [pool.submit(start, n, s if isinstance(s, dict) else {}) for n, s in specs.items()]
            for job in jobs:
                name, client, init, tools, err = job.result()
                if err:
                    warn(f"MCP server {name}: {err}")
                    self.status.append({"name": name, "status": "failed", "error": err})
                    continue
                self.servers[name] = client
                self.status.append({"name": name, "status": "connected"})
                if (init or {}).get("instructions"):
                    self.instructions[name] = str(init["instructions"])
                for t in tools:
                    tname = str(t.get("name") or "")
                    full = f"mcp__{name}__{tname}"
                    if allow and not any(pattern_allows(p, name, tname) for p in allow):
                        continue
                    if any(pattern_allows(p, name, tname) for p in deny):
                        continue
                    exposed = safe_tool_name(full)
                    schema = t.get("inputSchema") if isinstance(t.get("inputSchema"), dict) else {}
                    schema = {k: v for k, v in schema.items() if k != "$schema"}
                    schema.setdefault("type", "object")
                    self.tools[exposed] = {"server": name, "tool": tname, "full": full,
                                           "spec": {"name": exposed, "description": str(t.get("description") or "")[:8000],
                                                    "input_schema": schema}}

    def call(self, exposed, args):
        info = self.tools[exposed]
        result = self.servers[info["server"]].rpc("tools/call", {"name": info["tool"], "arguments": args},
                                                  MCP_CALL_TIMEOUT)
        blocks = []
        for c in result.get("content") or []:
            t = c.get("type")
            if t == "text":
                blocks.append({"type": "text", "text": cap(str(c.get("text") or ""))})
            elif t == "image" and c.get("data"):
                blocks.append({"type": "image", "source": {"type": "base64", "media_type": c.get("mimeType") or "image/png",
                                                           "data": c["data"]}})
            elif t == "resource":
                r = c.get("resource") or {}
                blocks.append({"type": "text", "text": cap(str(r.get("text") or f"[resource {r.get('uri', '')}]"))})
            elif t == "resource_link":
                blocks.append({"type": "text", "text": f"[resource {c.get('uri', '')}]"})
            else:
                blocks.append({"type": "text", "text": f"[{t}]"})
        if not blocks and result.get("structuredContent") is not None:
            blocks.append({"type": "text", "text": cap(json.dumps(result["structuredContent"], ensure_ascii=False))})
        if not blocks:
            blocks.append({"type": "text", "text": "(no output)"})
        return blocks, bool(result.get("isError"))

    def close(self, wait=2.0):
        """Their stdin closed (an MCP server's cue to exit), a moment to do
        so, then stopped."""
        stdio = [c for c in self.servers.values() if isinstance(c, StdioMcp)]
        for c in stdio:
            try:
                c.proc.stdin.close()
            except (OSError, ValueError):
                pass
        deadline = time.monotonic() + wait
        for c in stdio:
            try:
                c.proc.wait(timeout=max(0.0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(c.proc.pid, signal.SIGTERM)
                except OSError:
                    pass
        self.servers = {}


def pattern_allows(pattern, server, tool):
    p = pattern.split("(", 1)[0]
    if p in (f"mcp__{server}", f"mcp__{server}__*", f"mcp__{server}__{tool}"):
        return True
    return "*" in p and fnmatch.fnmatchcase(f"mcp__{server}__{tool}", p)


def safe_tool_name(name):
    clean = re.sub(r"[^A-Za-z0-9_-]", "_", name)
    if len(clean) <= 64:
        return clean
    return clean[:55] + "_" + hashlib.sha1(name.encode()).hexdigest()[:8]


# ── Built-in tools ─────────────────────────────────────────────────────────

class HtmlText(html.parser.HTMLParser):
    SKIP = {"script", "style", "noscript", "svg", "head", "template"}
    BLOCK = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "header",
             "footer", "pre", "blockquote", "table", "ul", "ol", "dt", "dd"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out, self.skip, self.title, self.in_title = [], 0, "", False

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
        if tag == "title":
            self.in_title = True
        if tag in self.BLOCK:
            self.out.append("\n")
        if tag == "a" and not self.skip:
            self.href = dict(attrs).get("href")

    def handle_endtag(self, tag):
        if tag in self.SKIP:
            self.skip = max(0, self.skip - 1)
        if tag == "title":
            self.in_title = False
        if tag in self.BLOCK:
            self.out.append("\n")

    def handle_data(self, data):
        if self.in_title:
            self.title += data
        if not self.skip:
            self.out.append(data)

    def text(self):
        s = "".join(self.out)
        s = re.sub(r"[ \t\r\f\v]+", " ", s)
        s = re.sub(r"\n\s*\n+", "\n\n", s)
        return s.strip()


def html_to_text(raw):
    p = HtmlText()
    try:
        p.feed(raw)
        p.close()
    except Exception:  # noqa: BLE001 — broken markup: what was read
        pass
    return p.title.strip(), p.text()


def public_host(host):
    """The host's addresses are all on the internet (no local network)."""
    if os.environ.get("NIXBOOK_AGENT_WEBFETCH_LOCAL") == "1":
        return True
    try:
        infos = socket.getaddrinfo(host, None)
    except OSError:
        return False
    for info in infos:
        try:
            ip = ipaddress.ip_address(info[4][0].split("%")[0])
        except ValueError:
            return False
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast or ip.is_unspecified:
            return False
    return True


class CheckedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        u = urllib.parse.urlsplit(newurl)
        if u.scheme not in ("http", "https") or not public_host(u.hostname or ""):
            raise urllib.error.URLError(f"redirect to {newurl} refused")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url, timeout=30, limit=2_000_000):
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise AgentError("only http(s) URLs")
    if not public_host(u.hostname):
        raise AgentError(f"{u.hostname} is not on the internet (local addresses are refused)")
    opener = urllib.request.build_opener(CheckedRedirect)
    r = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) nixbook-meta-agent",
                                             "Accept": "text/html,application/xhtml+xml,text/plain,*/*;q=0.8"})
    with opener.open(r, timeout=timeout) as resp:
        raw = resp.read(limit)
        ctype = resp.headers.get("content-type") or ""
        charset = resp.headers.get_content_charset() or "utf-8"
        final = resp.geturl()
    return raw.decode(charset, "replace"), ctype, final


TOOL_SPECS = {
    "Read": {"description": "Read a file: text with line numbers (cat -n style; offset/limit for long files), or an "
                            "image (png, jpg, gif, webp) to look at. Absolute paths or relative to the working directory.",
             "input_schema": {"type": "object", "properties": {
                 "file_path": {"type": "string", "description": "the file"},
                 "offset": {"type": "integer", "description": "first line (1-based)"},
                 "limit": {"type": "integer", "description": "how many lines (2000 by default)"}},
                 "required": ["file_path"]}},
    "Glob": {"description": "Find files by name pattern (e.g. **/*.nix), newest first.",
             "input_schema": {"type": "object", "properties": {
                 "pattern": {"type": "string"}, "path": {"type": "string", "description": "the directory to search"}},
                 "required": ["pattern"]}},
    "Grep": {"description": "Search file contents with a regular expression (Python syntax).",
             "input_schema": {"type": "object", "properties": {
                 "pattern": {"type": "string"}, "path": {"type": "string", "description": "a file or directory"},
                 "glob": {"type": "string", "description": "only files matching this glob (e.g. *.py)"},
                 "output_mode": {"type": "string", "enum": ["files_with_matches", "content", "count"]},
                 "-i": {"type": "boolean"}, "-n": {"type": "boolean"}, "-A": {"type": "integer"},
                 "-B": {"type": "integer"}, "-C": {"type": "integer"},
                 "multiline": {"type": "boolean"}, "head_limit": {"type": "integer"}},
                 "required": ["pattern"]}},
    "Edit": {"description": "Replace text in a file: old_string must appear exactly once (or set replace_all).",
             "input_schema": {"type": "object", "properties": {
                 "file_path": {"type": "string"}, "old_string": {"type": "string"}, "new_string": {"type": "string"},
                 "replace_all": {"type": "boolean"}}, "required": ["file_path", "old_string", "new_string"]}},
    "Write": {"description": "Write a whole file (created, or replaced).",
              "input_schema": {"type": "object", "properties": {
                  "file_path": {"type": "string"}, "content": {"type": "string"}}, "required": ["file_path", "content"]}},
    "Bash": {"description": "Run a bash command in the working directory (timeout in milliseconds, 120000 by "
                            "default, at most 600000). Output is cut when long.",
             "input_schema": {"type": "object", "properties": {
                 "command": {"type": "string"}, "timeout": {"type": "integer"}, "description": {"type": "string"}},
                 "required": ["command"]}},
    "WebFetch": {"description": "Fetch a web page (http/https) and read it as text.",
                 "input_schema": {"type": "object", "properties": {
                     "url": {"type": "string"}, "prompt": {"type": "string", "description": "what to look for in it"}},
                     "required": ["url"]}},
    "WebSearch": {"description": "Search the web: the top results' titles, links and snippets.",
                  "input_schema": {"type": "object", "properties": {
                      "query": {"type": "string"}, "allowed_domains": {"type": "array", "items": {"type": "string"}},
                      "blocked_domains": {"type": "array", "items": {"type": "string"}}},
                      "required": ["query"]}},
}


class Builtins:
    def __init__(self, opts, cwd):
        self.cwd = cwd
        self.opts = opts
        # --tools loads the built-ins; without it, those --allowedTools names.
        names = list(opts.tools) if opts.tools is not None else [a for a in opts.allowed if a in BUILTINS]
        if opts.tools is not None and any(n.lower() == "default" for n in opts.tools):
            names = list(BUILTINS)
        # Edit(//dir/**) / Write(…) in --allowedTools: a writable directory.
        write = [os.path.realpath(os.path.expanduser(d)) for d in opts.write_dirs]
        for a in opts.allowed:
            m = re.match(r"^(Edit|Write)\((.+)\)$", a)
            if m:
                d = re.sub(r"/\*\*.*$", "", m.group(2))
                write.append(expand(d, cwd))
                if opts.tools is None:
                    names.append(m.group(1))
        bare_deny = {d for d in opts.disallowed if "(" not in d}
        self.names = [n for n in BUILTINS if n in names and n not in bare_deny]
        # Path rules from --disallowedTools: Edit(/x/**/.git/**) and the like.
        self.deny = []
        for d in opts.disallowed:
            m = re.match(r"^(\w+)\((.+)\)$", d)
            if m and m.group(1) in BUILTINS:
                pat = m.group(2)
                if pat.startswith("//"):
                    pat = pat[1:]
                elif not pat.startswith("/"):
                    pat = os.path.join(cwd, pat)
                self.deny.append((m.group(1), glob_regex(pat)))
        if opts.permission_mode in ("acceptEdits", "bypassPermissions"):
            write.append(cwd)
        self.write_dirs = sorted(set(write))
        self.read_dirs = sorted({cwd, *[os.path.realpath(os.path.expanduser(d)) for d in opts.add_dirs],
                                 *self.write_dirs})
        self.file_lock = threading.Lock()

    def specs(self):
        return [{"name": n, **TOOL_SPECS[n]} for n in self.names]

    def denied(self, tool, path):
        group = {"Read", "Glob", "Grep"} if tool in ("Read", "Glob", "Grep") else {"Edit", "Write"}
        return any(t in group | {tool} and rx.match(path) for t, rx in self.deny)

    def readable(self, tool, path):
        p = expand(path, self.cwd)
        if not any(inside(p, d) for d in self.read_dirs):
            raise AgentError(f"{p} is outside the folders this agent may read ({', '.join(self.read_dirs)})")
        if self.denied(tool, p):
            raise AgentError(f"{p}: reading it is not allowed")
        return p

    def writable(self, tool, path):
        p = expand(path, self.cwd)
        # Never what runs on its own later: a repository's internals, direnv.
        if ".git" in p.split("/") or os.path.basename(p) == ".envrc":
            raise AgentError(f"{p}: changing .git or .envrc is not allowed")
        if not any(inside(p, d) for d in self.write_dirs):
            where = ", ".join(self.write_dirs) or "none"
            raise AgentError(f"{p} is outside the folders this agent may change ({where})")
        if self.denied(tool, p):
            raise AgentError(f"{p}: changing it is not allowed")
        return p

    def run(self, name, args):
        """(content, is_error): content a string or blocks."""
        try:
            return getattr(self, "t_" + name.lower())(args or {}), False
        except AgentError as e:
            return str(e), True
        except (OSError, ValueError, re.error, UnicodeError) as e:
            return f"{e.__class__.__name__}: {e}", True

    def t_read(self, a):
        path = self.readable("Read", a.get("file_path") or a.get("path") or "")
        if os.path.isdir(path):
            raise AgentError(f"{path} is a directory: use Glob to list it")
        ext = os.path.splitext(path)[1].lower()
        if ext in IMAGE_TYPES:
            size = os.path.getsize(path)
            if size > IMAGE_MAX:
                raise AgentError(f"the image is too big ({size // 1024} kB, at most {IMAGE_MAX // 1024} kB)")
            with open(path, "rb") as f:
                data = base64.b64encode(f.read()).decode()
            return [{"type": "text", "text": f"Image {path}:"},
                    {"type": "image", "source": {"type": "base64", "media_type": IMAGE_TYPES[ext], "data": data}}]
        with open(path, "rb") as f:
            head = f.read(8192)
        if b"\0" in head:
            raise AgentError(f"{path} is a binary file")
        offset = max(1, int(a.get("offset") or 1))
        limit = max(1, int(a.get("limit") or READ_LINES))
        out, total = [], 0
        with open(path, encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f, 1):
                total = n
                if n < offset or n >= offset + limit:
                    continue
                line = line.rstrip("\n")
                if len(line) > LINE_MAX:
                    line = line[:LINE_MAX] + "…"
                out.append(f"{n:>6}\t{line}")
        if not out:
            return "(empty file)" if total == 0 else f"(the file has {total} lines; nothing from line {offset})"
        text = "\n".join(out)
        if total >= offset + limit:
            text += f"\n… ({total} lines in all: read on with offset {offset + limit})"
        return cap(text)

    def walk(self, root, pattern=None):
        rx = glob_regex(pattern) if pattern else None
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for f in sorted(filenames):
                p = os.path.join(dirpath, f)
                rel = os.path.relpath(p, root)
                if rx is None or rx.match(rel) or ("/" not in pattern and fnmatch.fnmatch(f, pattern)):
                    yield p

    def t_glob(self, a):
        root = self.readable("Glob", a.get("path") or self.cwd)
        pattern = str(a.get("pattern") or "*")
        if pattern.startswith("/"):
            raise AgentError("the pattern is relative to path")
        found = [p for p in self.walk(root, pattern) if not self.denied("Glob", p)]
        found.sort(key=lambda p: os.path.getmtime(p) if os.path.exists(p) else 0, reverse=True)
        if not found:
            return "No files found"
        more = f"\n… ({len(found) - 200} more)" if len(found) > 200 else ""
        return "\n".join(found[:200]) + more

    def t_grep(self, a):
        target = self.readable("Grep", a.get("path") or self.cwd)
        flags = re.IGNORECASE if a.get("-i") else 0
        if a.get("multiline"):
            flags |= re.MULTILINE | re.DOTALL
        rx = re.compile(str(a.get("pattern") or ""), flags)
        mode = a.get("output_mode") or "files_with_matches"
        ctx = int(a.get("-C") or 0)
        before, after = int(a.get("-B") or ctx), int(a.get("-A") or ctx)
        numbers = a.get("-n", True)
        limit = int(a.get("head_limit") or 0) or (250 if mode != "content" else 1000)
        files = [target] if os.path.isfile(target) else list(self.walk(target, a.get("glob")))
        out, counts = [], []
        for p in files:
            if self.denied("Grep", p):
                continue
            try:
                if os.path.getsize(p) > 4_000_000:
                    continue
                with open(p, "rb") as f:
                    raw = f.read()
            except OSError:
                continue
            if b"\0" in raw[:8192]:
                continue
            text = raw.decode("utf-8", "replace")
            if a.get("multiline"):
                hits = list(rx.finditer(text))
                if not hits:
                    continue
                if mode == "content":
                    for h in hits:
                        line = text.count("\n", 0, h.start()) + 1
                        out.append(f"{p}:{line}:{h.group(0)[:2000]}")
                counts.append((p, len(hits)))
                continue
            lines = text.split("\n")
            hit_lines = [i for i, line in enumerate(lines) if rx.search(line)]
            if not hit_lines:
                continue
            counts.append((p, len(hit_lines)))
            if mode == "content":
                shown = set()
                for i in hit_lines:
                    for j in range(max(0, i - before), min(len(lines), i + after + 1)):
                        if j in shown:
                            continue
                        shown.add(j)
                        sep = ":" if j == i else "-"
                        out.append(f"{p}{sep}{j + 1}{sep}{lines[j][:LINE_MAX]}" if numbers else f"{p}{sep}{lines[j][:LINE_MAX]}")
            if len(out) > limit * 2:
                break
        if mode == "count":
            res = [f"{p}:{n}" for p, n in counts]
        elif mode == "content":
            res = out
        else:
            res = [p for p, _ in counts]
        if not res:
            return "No matches found"
        more = f"\n… ({len(res) - limit} more)" if len(res) > limit else ""
        return cap("\n".join(res[:limit]) + more)

    def t_edit(self, a):
        path = self.writable("Edit", a.get("file_path") or "")
        old, new = str(a.get("old_string", "")), str(a.get("new_string", ""))
        if old == new:
            raise AgentError("old_string and new_string are the same")
        with self.file_lock:
            if old == "" and not os.path.exists(path):
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as f:
                    f.write(new)
                return f"Created {path}"
            with open(path, encoding="utf-8") as f:
                text = f.read()
            n = text.count(old) if old else 0
            if n == 0:
                raise AgentError(f"old_string was not found in {path}")
            if n > 1 and not a.get("replace_all"):
                raise AgentError(f"old_string appears {n} times in {path}: give more context, or replace_all")
            text = text.replace(old, new) if a.get("replace_all") else text.replace(old, new, 1)
            tmp = path + f".agent-{os.getpid()}.tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            try:
                os.chmod(tmp, os.stat(path).st_mode & 0o7777)
            except OSError:
                pass
            os.replace(tmp, path)
        count = n if a.get("replace_all") else 1
        return f"Edited {path} ({count} replacement{'s' if count > 1 else ''})"

    def t_write(self, a):
        path = self.writable("Write", a.get("file_path") or "")
        if os.path.isdir(path):
            raise AgentError(f"{path} is a directory")
        content = str(a.get("content", ""))
        with self.file_lock:
            existed = os.path.exists(path)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
        return f"{'Updated' if existed else 'Created'} {path} ({len(content)} characters)"

    def t_bash(self, a):
        command = str(a.get("command") or "")
        if not command.strip():
            raise AgentError("no command")
        try:
            timeout = min(BASH_TIMEOUT_MAX, max(1, int(a.get("timeout") or BASH_TIMEOUT * 1000) / 1000))
        except (TypeError, ValueError):
            timeout = BASH_TIMEOUT
        bash = shutil.which("bash") or "/bin/sh"
        env = child_env()
        if self.opts.sandbox is not None:
            cmd = self.bwrap(bash, command, env)
        else:
            cmd = [bash, "-c", command]
        proc = subprocess.Popen(cmd, cwd=self.cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True)
        CHILDREN.add(proc)
        try:
            out, err = proc.communicate(timeout=timeout)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            kill_group(proc)
            out, err = proc.communicate()
            code, err = None, (err or b"") + f"\n(timed out after {int(timeout)} s)".encode()
        finally:
            CHILDREN.discard(proc)
        text = out.decode("utf-8", "replace")
        if err:
            text += ("\n" if text and not text.endswith("\n") else "") + err.decode("utf-8", "replace")
        text = text.strip() or "(no output)"
        if len(text) > BASH_OUTPUT_MAX:
            text = text[:BASH_OUTPUT_MAX // 2] + f"\n… [{len(text) - BASH_OUTPUT_MAX} characters cut] …\n" + \
                text[-BASH_OUTPUT_MAX // 2:]
        if code:
            text += f"\n(exit code {code})"
        if code is None or code:
            raise AgentError(text)
        return text

    def bwrap(self, bash, command, env):
        """The command in bubblewrap: the system read-only, the home hidden
        but the folders given, its own processes, the network open."""
        bw = shutil.which("bwrap")
        if not bw:
            raise AgentError("the Bash sandbox (bubblewrap) isn't available: not run")
        sb = self.opts.sandbox
        home = os.path.expanduser("~")
        args = [bw, "--die-with-parent", "--new-session", "--unshare-pid", "--unshare-ipc", "--unshare-uts",
                "--unshare-cgroup-try", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"]
        for d in ("/nix", "/etc", "/run/current-system", "/usr", "/bin", "/lib", "/lib64", "/sbin", "/opt",
                  "/run/systemd/resolve", "/run/NetworkManager", "/sys/devices/system/cpu"):
            if os.path.islink(d):
                args += ["--symlink", os.readlink(d), d]
            elif os.path.exists(d):
                args += ["--ro-bind", d, d]
        args += ["--dir", home]
        reads = [os.path.realpath(os.path.expanduser(p)) for p in sb.get("read") or [] if isinstance(p, str)]
        writes = [os.path.realpath(os.path.expanduser(p)) for p in sb.get("write") or [] if isinstance(p, str)]
        mounts = sorted({(p, False) for p in reads + [self.cwd] if p not in writes} | {(p, True) for p in writes},
                        key=lambda m: m[0].count("/"))
        for path, rw in mounts:
            if os.path.exists(path):
                args += ["--bind" if rw else "--ro-bind", path, path]
        for p in sb.get("deny") or []:
            p = os.path.realpath(os.path.expanduser(str(p)))
            if not os.path.exists(p) or not any(inside(p, m) for m, _ in mounts):
                continue
            args += ["--tmpfs", p] if os.path.isdir(p) else ["--ro-bind", "/dev/null", p]
        for k in ("DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "DISPLAY", "NIRI_SOCKET", "SSH_AUTH_SOCK",
                  "XDG_RUNTIME_DIR", "SWAYSOCK", "GNOME_KEYRING_CONTROL", "XAUTHORITY"):
            env.pop(k, None)
        env["HOME"] = home
        return args + ["--chdir", self.cwd, "--", bash, "-c", command]

    def t_webfetch(self, a):
        url = str(a.get("url") or "").strip()
        if url.startswith("http://") and not os.environ.get("NIXBOOK_AGENT_WEBFETCH_LOCAL"):
            url = "https://" + url[len("http://"):]
        try:
            raw, ctype, final = fetch(url)
        except urllib.error.HTTPError as e:
            raise AgentError(f"HTTP {e.code} for {url}")
        except (urllib.error.URLError, socket.timeout, TimeoutError) as e:
            raise AgentError(f"couldn't fetch {url}: {getattr(e, 'reason', e)}")
        if "html" in ctype or raw.lstrip()[:15].lower().startswith(("<!doctype", "<html")):
            title, text = html_to_text(raw)
        else:
            title, text = "", raw
        head = f"URL: {final}\n" + (f"Title: {title}\n" if title else "")
        if a.get("prompt"):
            head += f"(Looking for: {a['prompt']})\n"
        return head + "\n" + cap(text, FETCH_MAX)

    def t_websearch(self, a):
        query = str(a.get("query") or "").strip()
        if not query:
            raise AgentError("no query")
        base = os.environ.get("NIXBOOK_AGENT_SEARCH_URL") or "https://html.duckduckgo.com/html/"
        try:
            raw, _, _ = fetch(base + "?" + urllib.parse.urlencode({"q": query}))
        except (urllib.error.URLError, socket.timeout, TimeoutError) as e:
            raise AgentError(f"the search failed: {getattr(e, 'reason', e)}")
        results = []
        links = list(re.finditer(r'<a[^>]+class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', raw, re.S))
        snippets = re.findall(r'class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</(?:a|td|div)>', raw, re.S)
        allowed = [d.lower() for d in a.get("allowed_domains") or []]
        blocked = [d.lower() for d in a.get("blocked_domains") or []]
        for i, m in enumerate(links):
            href = html.unescape(m.group(1))
            if "uddg=" in href:
                href = urllib.parse.unquote(urllib.parse.parse_qs(urllib.parse.urlsplit(href).query).get("uddg", [href])[0])
            elif href.startswith("//"):
                href = "https:" + href
            host = (urllib.parse.urlsplit(href).hostname or "").lower()
            if "duckduckgo.com" in host and "/y.js" in href:
                continue  # an ad
            if allowed and not any(host == d or host.endswith("." + d) for d in allowed):
                continue
            if any(host == d or host.endswith("." + d) for d in blocked):
                continue
            title = html_to_text(m.group(2))[1]
            snippet = html_to_text(snippets[i])[1] if i < len(snippets) else ""
            results.append(f"{len(results) + 1}. {title}\n   {href}\n   {snippet}")
            if len(results) >= 8:
                break
        if not results:
            return f"No results for \"{query}\""
        return f"Results for \"{query}\":\n\n" + "\n\n".join(results)


# ── Sessions ───────────────────────────────────────────────────────────────

def sessions_dir():
    d = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "nixbook-shell",
                     "agent-sessions")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def session_path(sid):
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", sid or "") or sid.startswith("."):
        raise AgentError(f"not a session id: {sid}")
    return os.path.join(sessions_dir(), sid + ".json")


def prune_sessions():
    try:
        d = sessions_dir()
        old = time.time() - SESSION_DAYS * 86400
        for f in os.listdir(d):
            p = os.path.join(d, f)
            try:
                if f.endswith((".json", ".tmp")) and os.path.getmtime(p) < old:
                    os.unlink(p)
            except OSError:
                pass
    except OSError:
        pass


def load_session(sid):
    try:
        with open(session_path(sid), encoding="utf-8") as f:
            d = json.load(f)
    except FileNotFoundError:
        raise AgentError(f"No conversation found with session ID: {sid}")
    except (OSError, ValueError) as e:
        raise AgentError(f"session {sid} can't be read: {e}")
    return repair(d.get("messages") or [])


def save_session(sid, messages, model, cwd):
    path = session_path(sid)
    tmp = f"{path}.{os.getpid()}.{time.monotonic_ns()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"id": sid, "updated": int(time.time()), "model": model, "cwd": cwd,
                   "messages": repair(messages)}, f, ensure_ascii=False)
    os.replace(tmp, path)


def as_blocks(content):
    if isinstance(content, str):
        return [{"type": "text", "text": content}] if content else []
    return list(content or [])


def repair(messages):
    """A history the API accepts: roles alternating (consecutive ones
    merged), every tool call answered (an interrupted run's calls marked)."""
    out = []
    for m in messages:
        if not isinstance(m, dict) or m.get("role") not in ("user", "assistant"):
            continue
        if out and out[-1]["role"] == m["role"]:
            out[-1] = {"role": m["role"], "content": as_blocks(out[-1]["content"]) + as_blocks(m.get("content"))}
        else:
            out.append({"role": m["role"], "content": m.get("content")})
    fixed = []
    for i, m in enumerate(out):
        fixed.append(m)
        if m["role"] != "assistant":
            continue
        calls = [b["id"] for b in as_blocks(m["content"]) if b.get("type") == "tool_use"]
        if not calls:
            continue
        nxt = out[i + 1] if i + 1 < len(out) else None
        answered = {b.get("tool_use_id") for b in as_blocks(nxt["content"])} if nxt else set()
        missing = [{"type": "tool_result", "tool_use_id": c, "is_error": True, "content": "interrupted"}
                   for c in calls if c not in answered]
        if not missing:
            continue
        if nxt is not None:
            out[i + 1] = {"role": "user", "content": missing + as_blocks(nxt["content"])}
        else:
            fixed.append({"role": "user", "content": missing})
    return fixed


# ── The agent ──────────────────────────────────────────────────────────────

class Agent:
    def __init__(self, opts, out):
        self.opts = opts
        self.out = out
        self.cwd = os.path.realpath(os.getcwd())
        self.provider = Provider(opts)
        self.builtins = Builtins(opts, self.cwd)
        self.privacy = Privacy(opts.privacy)
        self.schema = opts.json_schema if isinstance(opts.json_schema, dict) else None
        self.wrapped = bool(self.schema) and self.schema.get("type", "object") != "object"
        self.usage = {}
        prune_sessions()
        if opts.resume:
            self.session_id = opts.resume
            self.messages = load_session(opts.resume)
        else:
            self.session_id = opts.session_id or str(uuid.uuid4())
            self.messages = []
            if opts.session_id and opts.persist and os.path.exists(session_path(opts.session_id)):
                raise AgentError(f"Session ID {opts.session_id} is already in use")
        self.mcp = Mcp(opts.mcp_configs, opts.allowed, opts.disallowed)
        self.tools = self.builtins.specs() + [t["spec"] for t in self.mcp.tools.values()]
        if self.schema:
            schema = {"type": "object", "properties": {"value": self.schema}, "required": ["value"]} \
                if self.wrapped else {k: v for k, v in self.schema.items() if k != "$schema"}
            self.tools.append({"name": STRUCTURED, "description": "Give your final answer, as the JSON the caller "
                               "asked for. Call it once, last, when the task is done.", "input_schema": schema})
        self.system = self.build_system()

    def build_system(self):
        o = self.opts
        parts = [o.system_prompt if o.system_prompt is not None else DEFAULT_SYSTEM]
        if self.builtins.names:
            env = [f"Working directory: {self.cwd}", f"Today: {time.strftime('%A %d %B %Y, %H:%M')}"]
            if set(self.builtins.names) & {"Read", "Glob", "Grep"}:
                env.append("Folders you can read: " + ", ".join(self.builtins.read_dirs))
            if set(self.builtins.names) & {"Edit", "Write"}:
                env.append("Folders you can change: " + (", ".join(self.builtins.write_dirs) or "none"))
            parts.append("Environment:\n" + "\n".join(env))
        if self.mcp.instructions:
            parts.append("Instructions from the MCP servers whose tools you have:\n\n" + "\n\n".join(
                f"## {n}\n{t}" for n, t in self.mcp.instructions.items()))
        parts += [s for s in o.append_system if s]
        if self.schema:
            parts.append(f"When the task is done, give your final answer by calling the `{STRUCTURED}` tool, once, "
                         "with the JSON it asks for; nothing after it.")
        return [{"type": "text", "text": "\n\n".join(p for p in parts if p), "cache_control": {"type": "ephemeral"}}]

    def emit(self, obj):
        if self.opts.output_format != "stream-json":
            return
        if "session_id" not in obj:
            obj["session_id"] = self.session_id
        self.out.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self.out.flush()

    def init_event(self):
        self.emit({"type": "system", "subtype": "init", "cwd": self.cwd, "session_id": self.session_id,
                   "model": self.provider.model, "tools": [t["name"] for t in self.tools if t["name"] != STRUCTURED],
                   "mcp_servers": self.mcp.status, "permissionMode": self.opts.permission_mode or "default",
                   "apiKeySource": "nixbook-model-provider"})

    def save(self):
        if self.opts.persist:
            try:
                save_session(self.session_id, self.messages, self.provider.model, self.cwd)
            except (OSError, AgentError) as e:
                warn(f"the session wasn't saved: {e}")

    def call(self, tool_choice=None, tools=None):
        partial = self.opts.partial and self.opts.output_format == "stream-json"
        on_event = (lambda ev: self.emit({"type": "stream_event", "event": ev, "parent_tool_use_id": None})) \
            if partial else None
        msg = self.provider.call(self.system, repair(self.messages), self.tools if tools is None else tools,
                                 tool_choice, on_event)
        u = msg.get("usage") or {}
        for k in ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"):
            if isinstance(u.get(k), int):
                self.usage[k] = self.usage.get(k, 0) + u[k]
        content = msg["content"] or [{"type": "text", "text": ""}]
        self.emit({"type": "assistant", "message": {"id": f"msg_{uuid.uuid4().hex[:24]}", "type": "message",
                                                    "role": "assistant", "model": msg.get("model") or self.provider.model,
                                                    "content": content, "stop_reason": msg["stop_reason"],
                                                    "usage": u}, "parent_tool_use_id": None})
        self.messages.append({"role": "assistant", "content": content})
        return msg

    def run_tool(self, call):
        name, args = call.get("name", ""), call.get("input") or {}
        args = self.privacy.unmask_input(name, args)
        try:
            if name in self.builtins.names:
                content, err = self.builtins.run(name, args)
            elif name in self.mcp.tools:
                content, err = self.mcp.call(name, args)
            else:
                content, err = f"no such tool: {name}", True
        except AgentError as e:
            content, err = str(e), True
        except Exception as e:  # noqa: BLE001 — a tool's failure is the model's to read
            content, err = f"{e.__class__.__name__}: {e}", True
        content = self.privacy.mask_result(name, content)
        return {"type": "tool_result", "tool_use_id": call["id"], "content": content, **({"is_error": True} if err else {})}

    def run_tools(self, calls):
        if len(calls) == 1:
            return [self.run_tool(calls[0])]
        with concurrent.futures.ThreadPoolExecutor(min(8, len(calls))) as pool:
            return list(pool.map(self.run_tool, calls))

    def structured(self, value):
        """The structured answer's value, or an error to hand back."""
        if not isinstance(value, dict):
            return None, "the answer must be a JSON object"
        if self.wrapped:
            if "value" not in value:
                return None, "the answer goes in `value`"
            return value["value"], None
        missing = [k for k in self.schema.get("required") or [] if k not in value]
        if missing:
            return None, "missing: " + ", ".join(missing)
        return value, None

    def force_structured(self, why):
        """The forced final call: the answer as the schema's JSON. A server
        that can't force one tool is asked for any tool, then for the JSON
        as text."""
        self.messages.append({"role": "user", "content": why + f" Call `{STRUCTURED}` now with your final answer."})
        choice = {"type": "tool", "name": STRUCTURED}
        for _ in range(3):
            try:
                msg = self.call(choice)
            except AgentError as e:
                if "HTTP 400" not in str(e) or choice is None:
                    raise
                choice = {"type": "any"} if choice.get("type") == "tool" else None
                if choice is None:
                    self.messages.append({"role": "user", "content": "Answer with the JSON alone, nothing else."})
                continue
            call = next((b for b in msg["content"] if b.get("type") == "tool_use" and b.get("name") == STRUCTURED), None)
            others = [b for b in msg["content"] if b.get("type") == "tool_use" and b is not call]
            if call is None:
                found = json_in("".join(b.get("text", "") for b in msg["content"] if b.get("type") == "text"))
                value, err = self.structured(found) if found is not None else (None, "no answer")
                if not err:
                    if others:
                        self.messages.append({"role": "user", "content": [
                            {"type": "tool_result", "tool_use_id": b["id"], "is_error": True, "content": "not run"}
                            for b in others]})
                    return value
                self.messages.append({"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": b["id"], "is_error": True, "content": "not now"} for b in others]
                    + [{"type": "text", "text": f"Call `{STRUCTURED}`." if choice else "The JSON alone, please."}]})
                continue
            value, err = self.structured(call.get("input"))
            results = [{"type": "tool_result", "tool_use_id": call["id"], "content": err or "ok",
                        **({"is_error": True} if err else {})}] + [
                {"type": "tool_result", "tool_use_id": b["id"], "is_error": True, "content": "not run"} for b in others]
            self.messages.append({"role": "user", "content": results})
            if not err:
                return value
        raise AgentError("the model gave no structured answer")

    def turn(self, content):
        """One user turn to its result event."""
        started = time.monotonic()
        self.usage = {}
        if not as_blocks(content):
            content = "(empty message)"
        self.messages.append({"role": "user", "content": content})
        self.save()
        result, subtype, error, structured, turns = "", "success", False, None, 0
        try:
            while True:
                if turns >= self.opts.max_turns:
                    if self.schema:
                        structured = self.force_structured("You are out of turns: no more tools.")
                        result = json.dumps(structured, ensure_ascii=False)
                    else:
                        subtype, error = "error_max_turns", True
                        result = result or f"Reached the maximum number of turns ({self.opts.max_turns})"
                    break
                turns += 1
                msg = self.call()
                texts = [b.get("text", "") for b in msg["content"] if b.get("type") == "text"]
                if "".join(texts).strip():
                    result = "".join(texts).strip()
                calls = [b for b in msg["content"] if b.get("type") == "tool_use"]
                if msg["stop_reason"] == "pause_turn" and not calls:
                    continue
                final = next((c for c in calls if c.get("name") == STRUCTURED), None) if self.schema else None
                if final is not None:
                    value, err = self.structured(final.get("input"))
                    others = [c for c in calls if c is not final]
                    results = self.run_tools(others) if others and err else [
                        {"type": "tool_result", "tool_use_id": c["id"], "is_error": True, "content": "not run: the "
                         "answer was given"} for c in others]
                    results.append({"type": "tool_result", "tool_use_id": final["id"], "content": err or "ok",
                                    **({"is_error": True} if err else {})})
                    self.messages.append({"role": "user", "content": results})
                    self.emit({"type": "user", "message": {"role": "user", "content": results},
                               "parent_tool_use_id": None})
                    if not err:
                        structured = value
                        result = json.dumps(value, ensure_ascii=False)
                        break
                    self.save()
                    continue
                if not calls:
                    if self.schema:
                        structured = self.force_structured("Done?")
                        result = json.dumps(structured, ensure_ascii=False)
                    if msg["stop_reason"] == "max_tokens" and not result:
                        subtype, error, result = "error_during_execution", True, "the answer was cut (max_tokens)"
                    break
                self.save()
                results = self.run_tools(calls)
                self.messages.append({"role": "user", "content": results})
                self.emit({"type": "user", "message": {"role": "user", "content": results}, "parent_tool_use_id": None})
                self.save()
        except AgentError as e:
            subtype, error, result = "error_during_execution", True, str(e)
        except Exception as e:  # noqa: BLE001 — the caller gets a result line whatever happens
            subtype, error, result = "error_during_execution", True, f"{e.__class__.__name__}: {e}"
        self.save()
        ev = {"type": "result", "subtype": subtype, "is_error": error, "duration_ms": int((time.monotonic() - started) * 1000),
              "duration_api_ms": 0, "num_turns": turns, "result": result, "session_id": self.session_id,
              "total_cost_usd": 0, "usage": {"input_tokens": self.usage.get("input_tokens", 0),
                                             "output_tokens": self.usage.get("output_tokens", 0),
                                             "cache_read_input_tokens": self.usage.get("cache_read_input_tokens", 0),
                                             "cache_creation_input_tokens": self.usage.get("cache_creation_input_tokens", 0)},
              "permission_denials": []}
        if structured is not None:
            ev["structured_output"] = structured
        return ev

    def deliver(self, ev):
        fmt = self.opts.output_format
        if fmt == "stream-json":
            self.emit(ev)
        elif fmt == "json":
            self.out.write(json.dumps(ev, ensure_ascii=False) + "\n")
            self.out.flush()
        elif ev["is_error"]:
            sys.stderr.write(str(ev["result"]) + "\n")
        else:
            self.out.write(str(ev["result"]) + "\n")
            self.out.flush()


def json_in(text):
    """The JSON object in a text answer (fenced or not), or None."""
    s = text.strip()
    start, end = s.find("{"), s.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        d = json.loads(s[start:end + 1])
    except ValueError:
        return None
    return d if isinstance(d, dict) else None


def user_content(line):
    """A stream-json input line's message content, or None to skip it."""
    try:
        d = json.loads(line)
    except ValueError:
        return None
    if not isinstance(d, dict) or d.get("type") != "user":
        return None
    m = d.get("message") or {}
    c = m.get("content") if isinstance(m, dict) else None
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return [b for b in c if isinstance(b, dict)]
    return None


def error_result(opts, msg, sid=""):
    ev = {"type": "result", "subtype": "error_during_execution", "is_error": True, "result": msg,
          "session_id": sid, "total_cost_usd": 0, "num_turns": 0, "duration_ms": 0,
          "usage": {"input_tokens": 0, "output_tokens": 0}}
    if opts is not None and opts.output_format in ("json", "stream-json"):
        sys.stdout.write(json.dumps(ev, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    sys.stderr.write(f"nixbook-meta-agent: {msg}\n")
    return 1


def main(argv):
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    try:
        opts = Options(argv)
    except (AgentError, OSError) as e:
        return error_result(None, str(e))
    reexec_through_provider(argv)
    state = {}

    def stop(*_):
        # Stopped (the side panel's stop button): the transcript as it is
        # (an unanswered tool call marked interrupted, so --resume goes on),
        # the running commands and the MCP servers stopped, out at once.
        agent = state.get("agent")
        if agent is not None:
            agent.save()
        for proc in list(CHILDREN):
            kill_group(proc)
        if agent is not None:
            agent.mcp.close(wait=0.5)
        try:
            sys.stdout.flush()
        except (OSError, ValueError):
            pass
        os._exit(143)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)
    try:
        agent = Agent(opts, sys.stdout)
    except (AgentError, OSError) as e:
        return error_result(opts, str(e), opts.resume or opts.session_id)
    state["agent"] = agent
    status = 0
    try:
        if opts.input_format == "stream-json":
            agent.init_event()
            for line in sys.stdin:
                content = user_content(line)
                if content is None:
                    continue
                ev = agent.turn(content)
                agent.deliver(ev)
                status = 1 if ev["is_error"] else 0
            return status
        prompt = " ".join(opts.prompt_args) if opts.prompt_args else sys.stdin.read()
        if not prompt.strip():
            return error_result(opts, "no prompt (give it on stdin)", agent.session_id)
        agent.init_event()
        ev = agent.turn(prompt)
        agent.deliver(ev)
        return 1 if ev["is_error"] else 0
    finally:
        agent.mcp.close()


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(1)
