#!/usr/bin/env bash
# Tests for the shared model client (scripts/nixbook_ai.py), against the fake
# Messages API (tests/fake-messages.py), a stub nixbook-desktop-mcp, a fake
# desktop-mcp helper socket and a stub nixbook-model-provider:
#   - call(): a busy server (429) tried again, the effort settings dropped
#     on a 400 (and remembered), max_tokens halved, Meta's fast chat
#     endpoint first and its absence remembered, a streamed reply's events;
#   - answer(): text, and with a schema the JSON (a forced tool, a missing
#     key told once, no forced tool on the server: the JSON as text);
#   - Provider: from the environment, or `nixbook-model-provider env`;
#   - dm(): through the helper's socket, a process when it isn't one of its
#     commands or isn't there, (127, "") without either; mask/unmask;
#   - is_risky, reads_only, build_report, action_class;
#   - nix-onboard's turn through it.
# Needs bash, python3 and jq. Run: bash tests/nixbook-ai.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
server_pid=""
trap '[ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/scripts" "$tmp/run" "$tmp/cfg"
export XDG_RUNTIME_DIR="$tmp/run" XDG_CONFIG_HOME="$tmp/cfg" XDG_STATE_HOME="$tmp/state"
export NIXBOOK_AI_RETRY_DELAY=0.05

# The stub desktop-mcp: the privacy mask, and its arguments echoed.
cat >"$tmp/bin/nixbook-desktop-mcp" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$tmp/dm.log"
case "\$1" in
privacy) if [ "\$2" = mask ]; then sed 's/Julien/⟦Person 1⟧/g'; else sed 's/⟦Person 1⟧/Julien/g'; fi ;;
sent) ;;
*) printf 'proc:%s|' "\$*"; cat ;;
esac
EOF
# The provider's settings and key as JSON (`env`), for a process started
# without them.
cat >"$tmp/bin/nixbook-model-provider" <<EOF
#!/usr/bin/env bash
[ "\$1" = env ] || exit 2
echo "env" >>"$tmp/provider.log"
jq -cn --arg b "\$FAKE_BASE" '{baseUrl: \$b, key: "test-key", model: "env-main", smallModel: "env-small", bigModel: "env-big", label: "Meta"}'
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

: >"$tmp/requests.log"
python3 -I "$root/tests/fake-messages.py" "$tmp/port" "$tmp/requests.log" "$tmp/scripts" &
server_pid=$!
for _ in $(seq 50); do
  [ -s "$tmp/port" ] && break
  sleep 0.1
done
FAKE_BASE="http://127.0.0.1:$(cat "$tmp/port")"
export FAKE_BASE
export NIXBOOK_AI_BASE_URL="$FAKE_BASE" NIXBOOK_AI_KEY=test-key NIXBOOK_AI_MODEL=main-model
export NIXBOOK_AI_SMALL_MODEL=small-model NIXBOOK_AI_BIG_MODEL=big-model

printf '%s' '[[{"type": "tool_use", "id": "s1", "name": "structured_output", "input": {"answer": 42}}]]' >"$tmp/scripts/forced.json"
printf '%s' '[[{"type": "tool_use", "id": "s1", "name": "structured_output", "input": {"oops": 1}}],
  [{"type": "tool_use", "id": "s2", "name": "structured_output", "input": {"answer": 7}}]]' >"$tmp/scripts/missing.json"
printf '%s' '[{"tool_choice": {"status": 400, "error": "tool_choice is not supported"},
  "otherwise": [{"type": "text", "text": "Here: {\"answer\": 5}"}]}]' >"$tmp/scripts/noforce.json"

cat >"$tmp/test.py" <<'PY'
import json, os, socket, sys, threading, time
sys.path.insert(0, sys.argv[1])
import nixbook_ai as ai

tmp = sys.argv[2]
failures = 0


def check(name, expected, actual):
    global failures
    if expected == actual:
        print(f"ok   - {name}")
    else:
        failures += 1
        print(f"FAIL - {name}\n       expected: {expected!r}\n       actual:   {actual!r}", file=sys.stderr)


def requests():
    with open(os.path.join(tmp, "requests.log"), encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def mark():
    return len(requests())


def since(n, word):
    return [r for r in requests()[n:] if word in json.dumps(r["body"])]


def fresh():
    """A new process's memory of what the server refused."""
    ai._STATE.update({"tuning": True, "fast": None, "max_tokens": None})


say = lambda t: [{"role": "user", "content": t}]  # noqa: E731

# call(): a busy server.
n = mark()
msg = ai.call("sys", say("RETRY429:2 hi"))
check("call: a 429 twice, then the answer", "Hello world", ai.text_of(msg))
check("call: three tries", 3, len(since(n, "RETRY429:2")))
ai.RETRIES = 1
try:
    ai.call("sys", say("RETRY429:5 hi"))
    check("call: given up after the retries", "an error", "an answer")
except ai.AIError as e:
    check("call: given up after the retries, said", True, "HTTP 429" in str(e))
ai.RETRIES = 3

# The effort settings: dropped on a 400 naming them, for the whole process.
fresh()
n = mark()
check("effort: answered without them", "Hello world", ai.text_of(ai.call("sys", say("NOEFFORT x"), effort="low")))
check("effort: asked with, then without", [{"effort": "low"}, None], [r["body"].get("output_config") for r in since(n, "NOEFFORT")])
n = mark()
ai.call("sys", say("again x"), effort="low")
check("effort: not asked again in this process", [None], [r["body"].get("output_config") for r in since(n, "again x")])
fresh()
n = mark()
ai.call("sys", say("forced x"), effort="low", tools=[{"name": "t", "input_schema": {"type": "object"}}],
        tool_choice={"type": "tool", "name": "t"})
check("effort: never with a forced tool", [None], [r["body"].get("thinking") for r in since(n, "forced x")])

# max_tokens halved on a 400 naming it.
n = mark()
ai.call("sys", say("BIGTOKENS x"))
check("max_tokens: halved until accepted", [16000, 8000], [r["body"]["max_tokens"] for r in since(n, "BIGTOKENS")])

# Meta's fast chat endpoint.
fresh()
n = mark()
check("fast: the chat endpoint's answer", "Fast answer", ai.text_of(ai.call("sys", say("CHATOK y"), fast=True)))
check("fast: reasoning_effort minimal", ["minimal"], [r["body"].get("reasoning_effort") for r in since(n, "CHATOK")])
check("fast: the system prompt first", "sys", since(n, "CHATOK")[0]["body"]["messages"][0]["content"])
fresh()
n = mark()
check("fast: no such endpoint, the Messages API", "Hello world", ai.text_of(ai.call("sys", say("nochat z"), fast=True)))
check("fast: tried once", ["/v1/chat/completions", "/v1/messages"], [r["path"] for r in since(n, "nochat z")])
n = mark()
ai.call("sys", say("nochat2 z"), fast=True)
check("fast: its absence remembered", ["/v1/messages"], [r["path"] for r in since(n, "nochat2 z")])
fresh()
n = mark()
ai.call("sys", say("tools z"), fast=True, tools=[{"name": "t", "input_schema": {"type": "object"}}])
check("fast: never with tools", ["/v1/messages"], [r["path"] for r in since(n, "tools z")])

# A streamed reply's events.
events = []
msg = ai.call("sys", say("stream it"), on_event=events.append)
check("stream: the deltas", "Hello world", "".join(e["delta"]["text"] for e in events if e.get("type") == "content_block_delta"))
check("stream: the whole message", "Hello world", ai.text_of(msg))

# answer(): text, and the JSON for a schema.
schema = {"type": "object", "properties": {"answer": {"type": "integer"}}, "required": ["answer"]}
check("answer: the text", "Hello world", ai.answer("sys", "plain"))
check("answer: the small model by default", "small-model", requests()[-1]["body"]["model"])
check("answer: a schema, through the forced tool", {"answer": 42}, ai.answer("sys", "AGENTTEST:forced", schema=schema))
check("answer: the tool forced", {"type": "tool", "name": "structured_output"}, requests()[-1]["body"]["tool_choice"])
n = mark()
check("answer: a missing key told once", {"answer": 7}, ai.answer("sys", "AGENTTEST:missing", schema=schema))
check("answer: what was missing said", True, "missing: answer" in json.dumps(since(n, "AGENTTEST:missing")[-1]["body"]["messages"]))
check("answer: no forced tool on the server, the JSON as text", {"answer": 5}, ai.answer("sys", "AGENTTEST:noforce", schema=schema))
fresh()
n = mark()
ai.answer("sys", "AGENTTEST:forced", schema=schema, effort="low")
check("answer: with an effort, the tool offered and thinking on", [({"type": "auto"}, {"effort": "low"})],
      [(r["body"].get("tool_choice"), r["body"].get("output_config")) for r in since(n, "AGENTTEST:forced")])
try:
    ai.answer("sys", "FAIL500", schema=schema)
    check("answer: a failing server", "an error", "an answer")
except ai.AIError as e:
    check("answer: a failing server raises", True, "HTTP 500" in str(e))

# The provider: the environment, else `nixbook-model-provider env`.
p = ai.Provider.from_env()
check("provider: from the environment", ("test-key", "small-model", "big-model", "Custom"),
      (p.key, p.model("haiku"), p.model("opus"), p.label))
check("provider: model names", ["main-model", "main-model", "small-model", "muse-x"],
      [p.model(a) for a in ("", "sonnet", "small", "muse-x")])
saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("NIXBOOK_AI_")}
p = ai.Provider.from_env()
check("provider: through `nixbook-model-provider env`", ("test-key", "env-small", "Meta"), (p.key, p.model("small"), p.label))
ai.Provider.from_env()
with open(os.path.join(tmp, "provider.log")) as f:
    check("provider: asked once", 1, len(f.read().split()))
check("provider: its key used", "Hello world", ai.answer("sys", "via env"))
os.environ.update(saved)

# dm(): no helper socket, a process.
code, out = ai.dm(["habits", "status"], stdin="in")
check("dm: a process without the helper", (0, "proc:habits status|in"), (code, out))
check("mask: through desktop-mcp", "ask ⟦Person 1⟧", ai.mask("ask Julien"))
check("unmask: back", "ask Julien", ai.unmask("ask ⟦Person 1⟧"))
check("mask_json: a JSON value", {"to": "⟦Person 1⟧"}, ai.mask_json({"to": "Julien"}))
check("unmask: nothing to do without a placeholder", "plain", ai.unmask("plain"))

# The helper's socket: one JSON line a request, its answer a line.
sock_dir = os.path.join(os.environ["XDG_RUNTIME_DIR"], "nixbook-desktop-mcp")
os.makedirs(sock_dir, mode=0o700)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(os.path.join(sock_dir, "helper.sock"))
srv.listen(4)
seen = []


def serve():
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            return
        with conn:
            buf = b""
            while b"\n" not in buf:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
            req = json.loads(buf.split(b"\n")[0])
            seen.append(req)
            if req["argv"][0] == "unknown":
                reply = {"id": req["id"], "code": 127, "stdout": ""}
            elif req["argv"][0] == "slow":
                # Sent, never answered (in time).
                time.sleep(1.5)
                continue
            else:
                reply = {"id": req["id"], "code": 0, "stdout": "sock:" + " ".join(req["argv"]) + "|" + req["stdin"]}
            # Someone else's answer first: skipped.
            conn.sendall((json.dumps({"id": "other", "code": 9, "stdout": "no"}) + "\n" + json.dumps(reply) + "\n").encode())


threading.Thread(target=serve, daemon=True).start()
open(os.path.join(tmp, "dm.log"), "w").close()
check("dm: through the helper's socket", (0, "sock:context build --for chat|x"),
      ai.dm(["context", "build", "--for", "chat"], stdin="x"))
check("dm: no process started for it", "", open(os.path.join(tmp, "dm.log")).read())
check("dm: not one of its commands (127): a process", (0, "proc:unknown cmd|"), ai.dm(["unknown", "cmd"]))
check("dm: an env: always a process", (0, "proc:instructions|"), ai.dm(["instructions"], env={"NIXBOOK_DESKTOP_MCP_QUERY": "q"}))
check("dm: a silent helper times out, never run twice", (124, ""), ai.dm(["slow"], timeout=0.5))
srv.close()
os.unlink(os.path.join(sock_dir, "helper.sock"))
os.environ["PATH"] = "/nonexistent"
check("dm: neither", (127, ""), ai.dm(["status"]))
check("mask: unchanged without desktop-mcp", "ask Julien", ai.mask("ask Julien"))

# What the agent asks about, and reports.
check("risky: deleting, by its MCP name", True, ai.is_risky("mcp__desktop__tasks", {"action": "delete"}))
check("risky: sending an SMS", True, ai.is_risky("mcp__phone__send_sms", {}))
check("risky: the queue isn't", False, ai.is_risky("mcp__youtube-music__clear_queue", {}))
check("risky: closing a window isn't", False, ai.is_risky("close_window", {"id": 3}))
check("reads only: an annotated tool", True, ai.reads_only("x", {}, {"x": {"read_only": True}}))
check("reads only: a reading action", True, ai.reads_only("tasks", {"action": "list"}))
check("reads only: an acting one", False, ai.reads_only("tasks", {"action": "add"}))
# The trust ladder's classes.
check("class: a tool alone", "media_control", ai.action_class("mcp__desktop__media_control", {"volume": 3}))
check("class: a multi-purpose tool's action", "media_control:pause", ai.action_class("media_control", {"action": "Pause"}))
check("class: calendar add", "calendar:add", ai.action_class("mcp__desktop__calendar", {"action": "add", "title": "x"}))
check("class: a window tool, its app", "close_window@firefox", ai.action_class("close_window", {"app": "firefox.desktop"}))
check("class: an input tool, the app the caller saw", "type_text@org.kde.dolphin",
      ai.action_class("type_text", {"text": "hi"}, "org.kde.dolphin"))
check("class: the caller's app wins over the call's", "launch_app@zen", ai.action_class("launch_app", {"app": "Firefox"}, "zen"))
check("class: no app for the other tools", "tasks:add", ai.action_class("tasks", {"action": "add", "app": "x"}, "firefox"))
check("class: a window tool without one", "close_window", ai.action_class("close_window", {"id": 3}))
check("class: odd characters folded", "set_theme:dark-mode", ai.action_class("set_theme", {"action": "Dark mode!"}))
check("class: another server's tool, bare", "send_sms", ai.action_class("mcp__phone__send_sms", {"to": "x"}))
check("class: in words", "close window in firefox", ai.class_summary("close_window@firefox"))
check("class: an action in words", "media control: pause", ai.class_summary("media_control:pause"))
steps = [{"tool": "launch_app", "summary": "app=x", "status": "error", "result": "no such app", "read_only": False}]
text, report = ai.build_report("Hmm.", steps)
check("report: a failed step", ["launch app (app=x): no such app"], report["failed"])
text, report = ai.build_report("Done.", [dict(steps[0], status="ok")])
check("report: none when it went well", ("Done.", None), (text, report))
check("strip_report: the block out", ("Opened.", {"summary": "s"}), ai.strip_report('Opened.<report>{"summary": "s"}</report>'))
cfg_dir = os.path.join(os.environ["XDG_CONFIG_HOME"], "nixbook-shell")
os.makedirs(cfg_dir)
check("routing: the defaults", {"decisions": "big", "decisionsEffort": "low", "quick": "small"}, ai.routing())
with open(os.path.join(cfg_dir, "config.json"), "w") as f:
    json.dump({"ai": {"routing": {"decisions": "main", "decisionsEffort": "silly"}}}, f)
check("routing: the settings, a wrong effort ignored", {"decisions": "main", "decisionsEffort": "low", "quick": "small"},
      ai.routing())
sys.exit(1 if failures else 0)
PY
status=0
python3 -I "$tmp/test.py" "$root/scripts" "$tmp" || status=1

# nix-onboard: a question turn, through the client.
printf '%s' '{"messages": [{"role": "user", "text": "Hi, I am Julien"}], "lang": "en"}' >"$tmp/onboard.json"
out=$(python3 -I "$root/scripts/nix-onboard.py" turn "$tmp/onboard.json")
if [ "$(jq -r 'select(.type == "say") | .text' <<<"$out")" = "Hello world" ]; then
  echo "ok   - nix-onboard: a question, through nixbook_ai"
else
  echo "FAIL - nix-onboard: a question, through nixbook_ai: $out" >&2
  status=1
fi
if grep -F 'Hi, I am' "$tmp/requests.log" | tail -n1 | grep -q '⟦Person 1⟧'; then
  echo "ok   - nix-onboard: masked on the way"
else
  echo "FAIL - nix-onboard: masked on the way" >&2
  status=1
fi

echo
if [ "$status" -ne 0 ]; then
  echo "nixbook-ai tests failed" >&2
  exit 1
fi
echo "all nixbook-ai tests passed"
