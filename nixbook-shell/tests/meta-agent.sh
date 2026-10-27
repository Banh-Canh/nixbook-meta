#!/usr/bin/env bash
# Tests for the headless agent (scripts/meta-agent.py, nixbook-meta-agent),
# against the fake Messages API (tests/fake-messages.py, its scripted
# conversations: AGENTTEST:NAME) and a stub MCP server:
#   - text, json and stream-json output (partial messages included);
#   - a tool loop with parallel calls, Read/Edit/Write confined to folders;
#   - --json-schema: the answer through a forced structured_output call;
#   - stream-json input (two turns), sessions and --resume;
#   - an MCP server (its tools, instructions, narrowing, a timeout), the
#     privacy mask on its input and output;
#   - --max-turns, the effort settings refused, the model names;
#   - Bash (plain, and in bubblewrap when it can run), WebFetch, WebSearch,
#     images from Read; the provider's key never given to tools;
#   - no key: through nixbook-model-provider; SIGTERM: saved and resumable;
#   - what Quick AI's loop did, now here: approvals (--confirm, over stdin),
#     the report (--report), big MCP servers on demand (--lazy-mcp), the
#     broker's context (--context-for), the episode learned (--learn); and
#     the request read first (--resolve), the result checked (--verify).
# Needs bash, python3 and jq. Run: bash tests/meta-agent.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/meta-agent.py"
tmp="$(mktemp -d)"
server_pid=""
trap '[ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; rm -rf "$tmp"' EXIT

failures=0
pass() { echo "ok   - $1"; }
fail() {
  echo "FAIL - $1" >&2
  [ $# -lt 2 ] || printf '%s\n' "$2" | sed 's/^/       /' >&2
  failures=$((failures + 1))
}
expect_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected: $2"$'\n'"actual:   $3"; fi
}
expect_contains() {
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "expected to contain: $3"$'\n'"actual: $2" ;; esac
}
expect_lacks() {
  case "$2" in *"$3"*) fail "$1" "expected not to contain: $3"$'\n'"actual: $2" ;; *) pass "$1" ;; esac
}

mkdir -p "$tmp/bin" "$tmp/scripts" "$tmp/work" "$tmp/ro" "$tmp/rw/.git" "$tmp/state" "$tmp/home"
printf 'line one\nline two\n' >"$tmp/ro/a.txt"
printf 'foo and more\n' >"$tmp/rw/b.txt"
printf 'TOPSECRET\n' >"$tmp/home/secret.txt"
export XDG_STATE_HOME="$tmp/state"
# Never the user's own desktop-mcp helper (its socket) nor settings.
mkdir -p "$tmp/run" "$tmp/cfg/nixbook-shell"
export XDG_RUNTIME_DIR="$tmp/run" XDG_CONFIG_HOME="$tmp/cfg" NIXBOOK_AI_RETRY_DELAY=0.05

# The privacy mask (nixbook-desktop-mcp privacy mask|unmask).
# The context broker (context build: its arguments in its text) and the
# episodes (episode -) too.
cat >"$tmp/bin/nixbook-desktop-mcp" <<'EOF'
#!/usr/bin/env bash
log="${0%/*}/.."
case "$1" in
privacy)
  echo "$2 $3" >>"$log/privacy.log"
  if [ "$2" = mask ]; then sed 's/Julien/⟦Person 1⟧/g'; else sed 's/⟦Person 1⟧/Julien/g'; fi ;;
context)
  [ "$2" = build ] || exit 1
  shift 2
  s="" q="" na=no a="" t=""
  while [ $# -gt 0 ]; do
    case "$1" in --for) s=$2; shift ;; --query) q=$2; shift ;; --app) a=$2; shift ;; --title) t=$2; shift ;; --no-activity) na=yes ;; esac
    shift
  done
  jq -cn --arg t "CTXBLOCK for=$s query=$q noact=$na app=$a title=$t Julien" '{sections: [{name: "facts", text: $t}], text: $t}' ;;
episode) cat >>"$log/episode.log"; echo >>"$log/episode.log"; echo "learned" ;;
*) exit 1 ;;
esac
EOF
# A stub MCP server: echo, look (an image), slow; what it was called with logged.
cat >"$tmp/stub-mcp.py" <<'EOF'
import json, sys, time
log = sys.argv[1]
tools = [{"name": "echo", "description": "Echo the text", "inputSchema": {"$schema": "x", "type": "object", "properties": {"text": {"type": "string"}}}},
         {"name": "look", "description": "An image", "inputSchema": {"type": "object", "properties": {}}},
         {"name": "slow", "description": "Takes its time", "inputSchema": {"type": "object", "properties": {}}}]
for line in sys.stdin:
    msg = json.loads(line)
    if "id" not in msg:
        continue
    m, p = msg["method"], msg.get("params") or {}
    if m == "initialize":
        res = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "stub"},
               "instructions": "STUBINSTRUCTIONS: use echo"}
    elif m == "tools/list":
        res = {"tools": tools}
    elif m == "tools/call":
        with open(log, "a") as f:
            f.write(json.dumps(p, ensure_ascii=False) + "\n")
        if p["name"] == "slow":
            time.sleep(4)
        if p["name"] == "look":
            res = {"content": [{"type": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png"}]}
        else:
            res = {"content": [{"type": "text", "text": "echo: " + p["arguments"].get("text", "")}]}
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "no"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": res}), flush=True)
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
# The desktop's server (annotated tools, replies naming the focused window)
# and a big app's (13 tools: offered on demand with --lazy-mcp 12).
cat >"$tmp/stub-desktop.py" <<'EOF'
import json, sys
log, kind = sys.argv[1], sys.argv[2]
obj = lambda **p: {"type": "object", "properties": {k: {"type": v} for k, v in p.items()}}
if kind == "desktop":
    tools = [{"name": "launch_app", "description": "Start an app", "inputSchema": obj(app="string"),
              "annotations": {"readOnlyHint": False}},
             {"name": "close_window", "description": "Close a window", "inputSchema": obj(id="integer"),
              "annotations": {"readOnlyHint": False, "destructiveHint": True}},
             {"name": "list_windows", "description": "The windows", "inputSchema": obj(),
              "annotations": {"readOnlyHint": True}},
             {"name": "tasks", "description": "The to-do lists: list, add, delete", "inputSchema": obj(action="string", id="string"),
              "annotations": {"readOnlyHint": False, "destructiveHint": True}}]
else:
    tools = [{"name": f"photo_{i}", "description": f"Photos {i}", "inputSchema": obj(query="string")} for i in range(13)]
for line in sys.stdin:
    msg = json.loads(line)
    if "id" not in msg:
        continue
    m, p = msg["method"], msg.get("params") or {}
    if m == "initialize":
        res = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": kind},
               "instructions": f"{kind.upper()}INSTRUCTIONS"}
    elif m == "tools/list":
        res = {"tools": tools}
    elif m == "tools/call":
        with open(log, "a") as f:
            f.write(json.dumps({"server": kind, **p}, ensure_ascii=False) + "\n")
        a = p.get("arguments") or {}
        if a.get("app") == "BROKEN":
            res = {"content": [{"type": "text", "text": "no such app: BROKEN"}], "isError": True}
        else:
            res = {"content": [{"type": "text", "text": f"done: {p['name']}\nFocused: firefox — 'Firefox' (id 3)"}]}
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "no"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": res}), flush=True)
EOF
desk_config=$(jq -cn --arg py "$(command -v python3)" --arg s "$tmp/stub-desktop.py" --arg l "$tmp/desk-calls.log" \
  '{mcpServers: {desktop: {command: $py, args: ["-I", $s, $l, "desktop"]}, photos: {command: $py, args: ["-I", $s, $l, "photos"]}}}')
mcp_config=$(jq -cn --arg py "$(command -v python3)" --arg s "$tmp/stub-mcp.py" --arg l "$tmp/mcp-calls.log" \
  '{mcpServers: {stub: {command: $py, args: ["-I", $s, $l]}}}')

python3 -I "$root/tests/fake-messages.py" "$tmp/port" "$tmp/requests.log" "$tmp/scripts" &
server_pid=$!
for _ in $(seq 50); do
  [ -s "$tmp/port" ] && break
  sleep 0.1
done
base="http://127.0.0.1:$(cat "$tmp/port")"
export NIXBOOK_AI_BASE_URL="$base" NIXBOOK_AI_KEY=test-key NIXBOOK_AI_MODEL=main-model
export NIXBOOK_AI_SMALL_MODEL=small-model NIXBOOK_AI_BIG_MODEL=big-model

# script NAME JSON: the fake's replies for AGENTTEST:NAME.
script() { printf '%s' "$2" >"$tmp/scripts/$1.json"; }
# agent ARGS… (prompt on stdin), run in $tmp/work.
agent() { (cd "$tmp/work" && python3 -I "$script" "$@"); }
# The requests made for a test, by its AGENTTEST name.
requests() { jq -c --arg t "AGENTTEST:$1" 'select(.path == "/v1/messages" and (.body | tostring | contains($t))) | .body' "$tmp/requests.log"; }

# -- Output formats -------------------------------------------------------------
script hello '[[{"type": "text", "text": "Hello there"}]]'
expect_eq "text: the answer alone" "Hello there" "$(echo "AGENTTEST:hello hi" | agent -p)"
out=$(echo "AGENTTEST:hello hi" | agent -p --output-format json)
expect_eq "json: the result object" "result success false Hello there 1 0" \
  "$(jq -r '"\(.type) \(.subtype) \(.is_error) \(.result) \(.num_turns) \(.total_cost_usd)"' <<<"$out")"
expect_contains "json: a session id" "$(jq -r .session_id <<<"$out")" "-"
expect_eq "json: the main model by default, no tuning unasked" '"main-model" null null' \
  "$(requests hello | tail -n1 | jq -c '[.model, .thinking, .output_config] | map(tojson) | join(" ")' -r)"
out=$(echo "AGENTTEST:hello hi" | agent -p --output-format stream-json --verbose --include-partial-messages)
expect_eq "stream-json: init, deltas, the message, the result" "system stream_event assistant result" \
  "$(jq -r .type <<<"$out" | uniq | paste -sd' ')"
expect_eq "stream-json: the text as it streams" "Hello there" \
  "$(jq -r 'select(.type == "stream_event" and .event.delta.type == "text_delta") | .event.delta.text' <<<"$out" | tr -d '\n')"
expect_eq "stream-json: the init's session is the result's" "1" \
  "$(jq -r 'select(.type == "system" or .type == "result") | .session_id' <<<"$out" | sort -u | wc -l | tr -d ' ')"
expect_eq "stream-json: streamed from the server" "true" "$(requests hello | tail -n1 | jq -c .stream)"

# -- The model names -------------------------------------------------------------
: >"$tmp/requests.log"
for m in haiku small sonnet opus big muse-x; do echo "AGENTTEST:hello $m" | agent -p --model "$m" >/dev/null; done
expect_eq "models: aliases mapped, the provider's own ids kept" "small-model small-model main-model big-model big-model muse-x" \
  "$(requests hello | jq -r .model | paste -sd' ')"

# -- A tool loop: parallel calls, confined files -------------------------------
script files "[[
  {\"type\": \"text\", \"text\": \"Looking.\"},
  {\"type\": \"tool_use\", \"id\": \"t1\", \"name\": \"Read\", \"input\": {\"file_path\": \"$tmp/ro/a.txt\"}},
  {\"type\": \"tool_use\", \"id\": \"t2\", \"name\": \"Read\", \"input\": {\"file_path\": \"$tmp/home/secret.txt\"}},
  {\"type\": \"tool_use\", \"id\": \"t3\", \"name\": \"Edit\", \"input\": {\"file_path\": \"$tmp/rw/b.txt\", \"old_string\": \"foo\", \"new_string\": \"bar\"}},
  {\"type\": \"tool_use\", \"id\": \"t4\", \"name\": \"Edit\", \"input\": {\"file_path\": \"$tmp/ro/a.txt\", \"old_string\": \"one\", \"new_string\": \"1\"}},
  {\"type\": \"tool_use\", \"id\": \"t5\", \"name\": \"Write\", \"input\": {\"file_path\": \"$tmp/rw/.git/config\", \"content\": \"x\"}},
  {\"type\": \"tool_use\", \"id\": \"t6\", \"name\": \"Write\", \"input\": {\"file_path\": \"$tmp/rw/new/c.txt\", \"content\": \"made\"}},
  {\"type\": \"tool_use\", \"id\": \"t7\", \"name\": \"Grep\", \"input\": {\"pattern\": \"two\", \"path\": \"$tmp/ro\", \"output_mode\": \"content\"}},
  {\"type\": \"tool_use\", \"id\": \"t8\", \"name\": \"Glob\", \"input\": {\"pattern\": \"**/*.txt\", \"path\": \"$tmp/rw\"}}
], [{\"type\": \"text\", \"text\": \"Done.\"}]]"
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:files go" | agent -p --output-format stream-json --tools Read,Edit,Write,Glob,Grep \
  --add-dir "$tmp/ro" --write-dir "$tmp/rw")
expect_eq "tools: the loop ends with the answer" "Done. 2" "$(jq -r 'select(.type == "result") | "\(.result) \(.num_turns)"' <<<"$out")"
expect_eq "tools: the built-ins asked for, nothing else" '["Read","Glob","Grep","Edit","Write"]' \
  "$(requests files | head -n1 | jq -c '[.tools[].name]')"
results=$(requests files | tail -n1 | jq -c '.messages[-1].content')
res() { jq -r --arg id "$1" '.[] | select(.tool_use_id == $id) | "\(.is_error // false) \(.content | if type == "string" then . else tojson end)"' <<<"$results"; }
expect_eq "tools: every call answered, in order" "t1 t2 t3 t4 t5 t6 t7 t8" "$(jq -r '[.[].tool_use_id] | join(" ")' <<<"$results")"
expect_contains "Read: with line numbers" "$(res t1)" "false      1	line one"
expect_contains "Read: outside the folders refused" "$(res t2)" "true $tmp/home/secret.txt is outside the folders"
expect_eq "Edit: in a writable folder" "bar and more" "$(cat "$tmp/rw/b.txt")"
expect_contains "Edit: a read-only folder refused" "$(res t4)" "true $tmp/ro/a.txt is outside the folders this agent may change"
expect_eq "Edit: the read-only file untouched" "line one" "$(head -n1 "$tmp/ro/a.txt")"
expect_contains "Write: never into .git" "$(res t5)" "true"
if [ -e "$tmp/rw/.git/config" ]; then fail "Write: .git/config not written"; else pass "Write: .git/config not written"; fi
expect_eq "Write: a new file, its folder made" "made" "$(cat "$tmp/rw/new/c.txt")"
expect_contains "Grep: the matching line" "$(res t7)" "a.txt:2:line two"
expect_contains "Glob: the files" "$(res t8)" "$tmp/rw/b.txt"
expect_eq "stream-json: the tool results as a user event" "8" \
  "$(jq -r 'select(.type == "user") | .message.content | length' <<<"$out")"
out=$(echo "AGENTTEST:files again" | agent -p --output-format json --tools Read,Edit --disallowedTools Edit,Write)
expect_eq "disallowed: removed from the tools" '["Read"]' "$(requests files | tail -n2 | head -n1 | jq -c '[.tools[].name]')"
# acceptEdits: the working directory writable.
printf 'foo\n' >"$tmp/work/w.txt"
script cwdedit '[[{"type": "tool_use", "id": "e1", "name": "Edit", "input": {"file_path": "w.txt", "old_string": "foo", "new_string": "baz"}}], [{"type": "text", "text": "ok"}]]'
echo "AGENTTEST:cwdedit" | agent -p --tools Edit --permission-mode acceptEdits >/dev/null
expect_eq "acceptEdits: the working directory writable" "baz" "$(cat "$tmp/work/w.txt")"
# An attached file: --add-dir FILE lets that file alone be read.
script attached "[[{\"type\": \"tool_use\", \"id\": \"r1\", \"name\": \"Read\", \"input\": {\"file_path\": \"$tmp/home/secret.txt\"}}], [{\"type\": \"text\", \"text\": \"ok\"}]]"
echo "AGENTTEST:attached" | agent -p --tools Read --add-dir "$tmp/home/secret.txt" >/dev/null
expect_eq "add-dir: a file readable alone" "false" "$(requests attached | tail -n1 | jq -c '.messages[-1].content[0].is_error // false')"

# -- Images from Read -----------------------------------------------------------------
printf '\x89PNG\r\n\x1a\n0000' >"$tmp/ro/pic.png"
script image "[[{\"type\": \"tool_use\", \"id\": \"i1\", \"name\": \"Read\", \"input\": {\"file_path\": \"$tmp/ro/pic.png\"}}], [{\"type\": \"text\", \"text\": \"a picture\"}]]"
echo "AGENTTEST:image" | agent -p --tools Read --add-dir "$tmp/ro" >/dev/null
expect_eq "Read: an image as an image block" '"image/png"' \
  "$(requests image | tail -n1 | jq -c '.messages[-1].content[0].content[] | select(.type == "image") | .source.media_type')"

# -- --json-schema ------------------------------------------------------------------
schema='{"type": "object", "properties": {"answer": {"type": "integer"}}, "required": ["answer"]}'
script forced '[[{"type": "text", "text": "I think it is 42."}], [{"type": "tool_use", "id": "s1", "name": "structured_output", "input": {"answer": 42}}]]'
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:forced what is it?" | agent -p --output-format json --json-schema "$schema" --effort low)
expect_eq "schema: the structured answer" '{"answer":42} {"answer": 42}' \
  "$(jq -r '"\(.structured_output | tojson) \(.result)"' <<<"$out")"
expect_eq "schema: the final call forced, without thinking" '{"type":"tool","name":"structured_output"} null' \
  "$(requests forced | tail -n1 | jq -c '.tool_choice, .thinking' | paste -sd' ')"
expect_eq "schema: the first call tuned (effort asked)" '"low"' "$(requests forced | head -n1 | jq -c .output_config.effort)"
expect_eq "schema: the tool offered with the schema" "$(jq -c . <<<"$schema")" \
  "$(requests forced | head -n1 | jq -c '.tools[] | select(.name == "structured_output") | .input_schema')"
script direct '[[{"type": "tool_use", "id": "s1", "name": "structured_output", "input": {"oops": 1}}], [{"type": "tool_use", "id": "s2", "name": "structured_output", "input": {"answer": 7}}]]'
out=$(echo "AGENTTEST:direct" | agent -p --output-format json --json-schema "$schema")
expect_eq "schema: a wrong answer handed back, then the right one" "7 2" "$(jq -r '"\(.structured_output.answer) \(.num_turns)"' <<<"$out")"
expect_contains "schema: what was wrong said" "$(requests direct | tail -n1 | jq -c '.messages[-1].content')" "missing: answer"

# A server that can't force a tool: the JSON as text at last.
# shellcheck disable=SC2016 # Markdown backticks, not an expansion
script noforce '[[{"type": "text", "text": "thinking"}],
  {"tool_choice": {"status": 400, "error": "tool_choice is not supported"},
   "otherwise": [{"type": "text", "text": "```json\n{\"answer\": 5}\n```"}]}]'
out=$(echo "AGENTTEST:noforce" | agent -p --output-format json --json-schema "$schema")
expect_eq "schema: no forced tool on the server, the JSON as text" "5" "$(jq -r .structured_output.answer <<<"$out")"
# -- stream-json input: two turns -------------------------------------------------
script twoturns '[[{"type": "text", "text": "first"}], [{"type": "text", "text": "second"}]]'
: >"$tmp/requests.log"
out=$(printf '%s\n%s\n' \
  '{"type": "user", "message": {"role": "user", "content": "AGENTTEST:twoturns one"}}' \
  '{"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "two"}]}}' |
  agent -p --input-format stream-json --output-format stream-json --verbose)
expect_eq "stream input: a result per turn" "first second" "$(jq -r 'select(.type == "result") | .result' <<<"$out" | paste -sd' ')"
expect_eq "stream input: one init" "1" "$(jq -r 'select(.type == "system") | .subtype' <<<"$out" | wc -l | tr -d ' ')"
expect_eq "stream input: the second turn has the first" "3" "$(requests twoturns | tail -n1 | jq '.messages | length')"

# -- Sessions -------------------------------------------------------------------------
script resume '[[{"type": "text", "text": "one"}], [{"type": "text", "text": "two"}]]'
: >"$tmp/requests.log"
sid=$(echo "AGENTTEST:resume first" | agent -p --output-format json | jq -r .session_id)
file="$tmp/state/nixbook-shell/agent-sessions/$sid.json"
expect_eq "session: saved, private" "600" "$(stat -c %a "$file" 2>/dev/null || echo missing)"
out=$(echo "and again" | agent -p --output-format json --resume "$sid")
expect_eq "resume: the conversation goes on, same session" "two $sid" "$(jq -r '"\(.result) \(.session_id)"' <<<"$out")"
expect_eq "resume: the earlier turn sent" '["user","assistant","user"]' "$(requests resume | tail -n1 | jq -c '[.messages[].role]')"
before=$(find "$tmp/state/nixbook-shell/agent-sessions" -name '*.json' | wc -l)
echo "AGENTTEST:hello" | agent -p --no-session-persistence >/dev/null
expect_eq "no-session-persistence: nothing saved" "$before" "$(find "$tmp/state/nixbook-shell/agent-sessions" -name '*.json' | wc -l)"
out=$(echo "hi" | agent -p --output-format json --resume no-such-session) && rc=0 || rc=$?
expect_eq "resume: an unknown session is an error" "1 true" "$rc $(jq -r .is_error <<<"$out")"
expect_contains "resume: said so" "$(jq -r .result <<<"$out")" "No conversation found"
touch -d '10 days ago' "$file"
echo "AGENTTEST:hello" | agent -p --no-session-persistence >/dev/null
if [ -e "$file" ]; then fail "sessions: pruned after a week"; else pass "sessions: pruned after a week"; fi

# -- An MCP server ------------------------------------------------------------------
script mcp '[[{"type": "tool_use", "id": "m1", "name": "mcp__stub__echo", "input": {"text": "⟦Person 1⟧ says hi"}},
  {"type": "tool_use", "id": "m2", "name": "mcp__stub__look", "input": {}}], [{"type": "text", "text": "ok"}]]'
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:mcp" | agent -p --output-format stream-json --strict-mcp-config --mcp-config "$mcp_config" --privacy)
first=$(requests mcp | head -n1)
expect_eq "mcp: its tools, as mcp__server__tool" '["mcp__stub__echo","mcp__stub__look","mcp__stub__slow"]' "$(jq -c '[.tools[].name]' <<<"$first")"
expect_eq "mcp: no schema dialect key" "null" "$(jq -c '.tools[0].input_schema["$schema"]' <<<"$first")"
expect_contains "mcp: its instructions in the system prompt" "$(jq -c .system <<<"$first")" "STUBINSTRUCTIONS"
expect_eq "mcp: in the init event" '["connected"]' "$(jq -c 'select(.type == "system") | [.mcp_servers[].status]' <<<"$out")"
expect_eq "privacy: the input unmasked for the server" "Julien says hi" "$(jq -r 'select(.name == "echo") | .arguments.text' "$tmp/mcp-calls.log" | head -n1)"
results=$(requests mcp | tail -n1 | jq -c '.messages[-1].content')
expect_eq "privacy: its result masked for the model" "echo: ⟦Person 1⟧ says hi" \
  "$(jq -r '.[] | select(.tool_use_id == "m1") | .content[0].text' <<<"$results")"
printf 'Julien wrote this\n' >"$tmp/ro/note.txt"
script privread "[[{\"type\": \"tool_use\", \"id\": \"p1\", \"name\": \"Read\", \"input\": {\"file_path\": \"$tmp/ro/note.txt\"}}], [{\"type\": \"text\", \"text\": \"ok\"}]]"
echo "AGENTTEST:privread" | agent -p --tools Read --add-dir "$tmp/ro" --privacy >/dev/null
expect_contains "privacy: a built-in's result masked too" "$(requests privread | tail -n1 | jq -c '.messages[-1].content[0].content')" "⟦Person 1⟧ wrote this"
expect_eq "privacy: through desktop-mcp's JSON mask" "mask --json" "$(grep -m1 '^mask' "$tmp/privacy.log")"
expect_eq "mcp: an image result passed on" '"image"' "$(jq -c '.[] | select(.tool_use_id == "m2") | .content[0].type' <<<"$results")"
: >"$tmp/requests.log"
echo "AGENTTEST:mcp" | agent -p --mcp-config "$mcp_config" --allowedTools mcp__stub__echo >/dev/null
expect_eq "mcp: narrowed by --allowedTools" '["mcp__stub__echo"]' "$(requests mcp | head -n1 | jq -c '[.tools[].name]')"
script slow '[[{"type": "tool_use", "id": "w1", "name": "mcp__stub__slow", "input": {}}], [{"type": "text", "text": "gave up"}]]'
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:slow" | NIXBOOK_AGENT_MCP_TIMEOUT=1 agent -p --output-format json --mcp-config "$mcp_config")
expect_contains "mcp: a call that takes too long is an error" "$(requests slow | tail -n1 | jq -c '.messages[-1].content[0]')" "timed out"
expect_eq "mcp: and the agent goes on" "gave up" "$(jq -r .result <<<"$out")"

# -- --max-turns ----------------------------------------------------------------------
script loop '[[{"type": "tool_use", "id": "l1", "name": "Glob", "input": {"pattern": "*"}}]]'
out=$(echo "AGENTTEST:loop" | agent -p --output-format json --tools Glob --max-turns 2) && rc=0 || rc=$?
expect_eq "max-turns: stopped" "1 error_max_turns true 2" "$rc $(jq -r '"\(.subtype) \(.is_error) \(.num_turns)"' <<<"$out")"

# -- A server refusing the effort settings ------------------------------------------
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:hello NOEFFORT" | agent -p --output-format json --effort low)
expect_eq "effort: answered on the second try" "Hello there" "$(jq -r .result <<<"$out")"
expect_eq "effort: asked with, then without them" '{"type":"adaptive"} null' \
  "$(requests hello | jq -c .thinking | paste -sd' ')"

# -- Bash -----------------------------------------------------------------------------
# shellcheck disable=SC2016 # the command's own expansion, in the sandbox
script bash '[[{"type": "tool_use", "id": "b1", "name": "Bash", "input": {"command": "pwd; echo key=${NIXBOOK_AI_KEY:-none}"}}], [{"type": "text", "text": "ran"}]]'
: >"$tmp/requests.log"
echo "AGENTTEST:bash" | agent -p --tools Bash >/dev/null
expect_eq "Bash: in the working directory, never the provider's key" "$tmp/work
key=none" "$(requests bash | tail -n1 | jq -r '.messages[-1].content[0].content')"
if bwrap --ro-bind / / true 2>/dev/null; then
  script sandbox "[[{\"type\": \"tool_use\", \"id\": \"x1\", \"name\": \"Bash\", \"input\": {\"command\": \"cat $tmp/home/secret.txt 2>&1 || echo hidden\"}},
    {\"type\": \"tool_use\", \"id\": \"x2\", \"name\": \"Bash\", \"input\": {\"command\": \"echo written > $tmp/rw/out.txt && cat $tmp/ro/a.txt | head -n1\"}},
    {\"type\": \"tool_use\", \"id\": \"x3\", \"name\": \"Bash\", \"input\": {\"command\": \"echo no > $tmp/ro/x.txt\"}},
    {\"type\": \"tool_use\", \"id\": \"x4\", \"name\": \"Bash\", \"input\": {\"command\": \"cat $tmp/rw/b.txt\"}}],
    [{\"type\": \"text\", \"text\": \"ok\"}]]"
  : >"$tmp/requests.log"
  echo "AGENTTEST:sandbox" | HOME="$tmp/home" agent -p --tools Bash \
    --sandbox "{\"read\": [\"$tmp/ro\"], \"write\": [\"$tmp/rw\"], \"deny\": [\"$tmp/rw/b.txt\"]}" >/dev/null
  results=$(requests sandbox | tail -n1 | jq -c '.messages[-1].content')
  box() { jq -r --arg id "$1" '.[] | select(.tool_use_id == $id) | "\(.is_error // false) \(.content)"' <<<"$results"; }
  expect_contains "sandbox: the home hidden" "$(box x1)" "hidden"
  expect_lacks "sandbox: its secret unread" "$(box x1)" "TOPSECRET"
  expect_eq "sandbox: the readable folder read" "false line one" "$(box x2)"
  expect_eq "sandbox: the writable folder written" "written" "$(cat "$tmp/rw/out.txt" 2>/dev/null)"
  expect_contains "sandbox: a read-only folder not written" "$(box x3)" "true"
  if [ -e "$tmp/ro/x.txt" ]; then fail "sandbox: nothing written there"; else pass "sandbox: nothing written there"; fi
  expect_lacks "sandbox: a denied file hidden" "$(box x4)" "bar and more"
else
  echo "skip - Bash sandbox: bubblewrap can't run here"
fi

# -- The web ----------------------------------------------------------------------------
script web "[[{\"type\": \"tool_use\", \"id\": \"f1\", \"name\": \"WebFetch\", \"input\": {\"url\": \"$base/page\", \"prompt\": \"the answer\"}},
  {\"type\": \"tool_use\", \"id\": \"f2\", \"name\": \"WebSearch\", \"input\": {\"query\": \"nixos\", \"blocked_domains\": [\"blocked.example\"]}}],
  [{\"type\": \"text\", \"text\": \"found\"}]]"
: >"$tmp/requests.log"
echo "AGENTTEST:web" | NIXBOOK_AGENT_WEBFETCH_LOCAL=1 NIXBOOK_AGENT_SEARCH_URL="$base/search" \
  agent -p --tools WebFetch,WebSearch >/dev/null
results=$(requests web | tail -n1 | jq -c '.messages[-1].content')
page=$(jq -r '.[] | select(.tool_use_id == "f1") | .content' <<<"$results")
expect_contains "WebFetch: the page as text" "$page" "The answer is 42."
expect_contains "WebFetch: its title" "$page" "Title: Fake page"
expect_lacks "WebFetch: no script" "$page" "hidden"
found=$(jq -r '.[] | select(.tool_use_id == "f2") | .content' <<<"$results")
expect_contains "WebSearch: the result's real link" "$found" "https://example.org/nixos"
expect_contains "WebSearch: its snippet" "$found" "The purely functional distribution."
expect_lacks "WebSearch: a blocked domain left out" "$found" "blocked.example"
: >"$tmp/requests.log"
echo "AGENTTEST:web" | agent -p --tools WebFetch >/dev/null
expect_contains "WebFetch: this computer's addresses refused" \
  "$(requests web | tail -n1 | jq -c '.messages[-1].content[0]')" "not on the internet"

# -- Approvals (--confirm): a risky step waits for the user ---------------------------------
# turn TEXT [APPROVAL…]: a stream-json user line, then the approval lines.
turn() {
  jq -cn --arg t "$1" '{type: "user", message: {role: "user", content: $t}}'
  shift
  for a in "$@"; do printf '%s\n' "$a"; done
}
script approve '[[{"type": "tool_use", "id": "d1", "name": "mcp__desktop__tasks", "input": {"action": "delete", "id": "t1"}}],
  [{"type": "text", "text": "Handled."}]]'
: >"$tmp/desk-calls.log"
out=$(turn "AGENTTEST:approve delete the task" '{"type": "approval", "id": "d1", "allow": true}' |
  agent -p --input-format stream-json --output-format stream-json --mcp-config "$desk_config" --confirm destructive)
expect_eq "confirm: the risky step asked about" '{"type":"approval_request","id":"d1","tool":"tasks","input":{"action":"delete","id":"t1"},"summary":"id=t1, action=delete"}' \
  "$(jq -c 'select(.type == "approval_request") | del(.session_id)' <<<"$out")"
expect_eq "confirm: allowed, run" '"tasks" {"action":"delete","id":"t1"}' "$(jq -c '.name, .arguments' "$tmp/desk-calls.log" | paste -sd' ')"
: >"$tmp/desk-calls.log"
: >"$tmp/requests.log"
out=$(turn "AGENTTEST:approve delete the task" '{"type": "approval", "id": "d1", "allow": false}' |
  agent -p --input-format stream-json --output-format stream-json --mcp-config "$desk_config" --confirm destructive)
expect_eq "confirm: denied, not run" "" "$(cat "$tmp/desk-calls.log")"
expect_eq "confirm: the model told" '"The user said no."' "$(requests approve | tail -n1 | jq -c '.messages[-1].content[0].content')"
: >"$tmp/requests.log"
out=$(turn "AGENTTEST:approve delete the task" | NIXBOOK_AGENT_APPROVAL_TIMEOUT=1 \
  agent -p --input-format stream-json --output-format stream-json --mcp-config "$desk_config" --confirm destructive)
expect_eq "confirm: no answer (the input ended) is a no" '"The user said no."' "$(requests approve | tail -n1 | jq -c '.messages[-1].content[0].content')"
: >"$tmp/requests.log"
echo "AGENTTEST:approve delete the task" | agent -p --mcp-config "$desk_config" --confirm destructive >/dev/null
expect_contains "confirm: with -p text input, no one to ask: refused" "$(requests approve | tail -n1 | jq -c '.messages[-1].content[0]')" "no one to ask"
expect_eq "confirm: nothing run then" "" "$(cat "$tmp/desk-calls.log")"
script closing '[[{"type": "tool_use", "id": "c1", "name": "mcp__desktop__close_window", "input": {"id": 3}},
  {"type": "tool_use", "id": "c2", "name": "mcp__desktop__list_windows", "input": {}}], [{"type": "text", "text": "ok"}]]'
out=$(turn "AGENTTEST:closing" | agent -p --input-format stream-json --output-format stream-json --mcp-config "$desk_config" --confirm destructive)
expect_eq "confirm destructive: closing a window isn't asked" "" "$(jq -c 'select(.type == "approval_request")' <<<"$out")"
: >"$tmp/desk-calls.log"
out=$(turn "AGENTTEST:closing" '{"type": "approval", "id": "c1", "allow": true}' |
  agent -p --input-format stream-json --output-format stream-json --mcp-config "$desk_config" --confirm actions)
expect_eq "confirm actions: every acting step asked, never one that reads" '"c1"' "$(jq -c 'select(.type == "approval_request") | .id' <<<"$out")"
expect_eq "confirm actions: both run" "close_window list_windows" "$(jq -r .name "$tmp/desk-calls.log" | sort | paste -sd' ')"

# -- The report (--report) ---------------------------------------------------------------------
script reported '[[{"type": "tool_use", "id": "r1", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}}],
  [{"type": "text", "text": "Opened it.<report>{\"summary\": \"Firefox is ready\", \"done\": [\"Opened Firefox\"], \"failed\": [], \"needs_you\": [\"Sign in to your account\"]}</report>"}]]'
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:reported open firefox" | agent -p --output-format json --mcp-config "$desk_config" --report)
expect_eq "report: the model's, in the result" '{"summary":"Firefox is ready","done":["Opened Firefox"],"failed":[],"needsYou":["Sign in to your account"]}' \
  "$(jq -c .report <<<"$out")"
expect_eq "report: the result without the block" "Opened it." "$(jq -r .result <<<"$out")"
expect_contains "report: asked for in the system prompt" "$(requests reported | sed -n 1p | jq -r '.system[0].text')" "<report>"
script failing '[[{"type": "tool_use", "id": "f1", "name": "mcp__desktop__launch_app", "input": {"app": "BROKEN"}}], [{"type": "text", "text": "Hmm."}]]'
out=$(echo "AGENTTEST:failing open it" | agent -p --output-format json --mcp-config "$desk_config" --report)
expect_eq "report: a failed step said, from the real calls" '["launch app (app=BROKEN): no such app: BROKEN"]' "$(jq -c .report.failed <<<"$out")"
script fine '[[{"type": "tool_use", "id": "g1", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}}], [{"type": "text", "text": "Firefox is open."}]]'
out=$(echo "AGENTTEST:fine open firefox" | agent -p --output-format json --mcp-config "$desk_config" --report)
expect_eq "report: none when it went well" "null Firefox is open." "$(jq -r '"\(.report) \(.result)"' <<<"$out")"

# -- Big MCP servers on demand (--lazy-mcp) ------------------------------------------------------
script lazy '[[{"type": "tool_use", "id": "o1", "name": "open_tools__photos", "input": {}}],
  [{"type": "tool_use", "id": "o2", "name": "mcp__photos__photo_12", "input": {"query": "beach"}}], [{"type": "text", "text": "Found."}]]'
: >"$tmp/requests.log"
: >"$tmp/desk-calls.log"
out=$(echo "AGENTTEST:lazy find my beach photos" | agent -p --output-format json --mcp-config "$desk_config" --lazy-mcp 12)
first=$(requests lazy | sed -n 1p | jq -c '[.tools[].name]')
expect_contains "lazy: a big server as one tool" "$first" '"open_tools__photos"'
expect_eq "lazy: not its tools up front" "0" "$(jq '[.[] | select(startswith("mcp__photos__"))] | length' <<<"$first")"
expect_contains "lazy: the desktop's always up front" "$first" '"mcp__desktop__launch_app"'
second=$(requests lazy | sed -n 2p | jq -c '[.tools[].name]')
expect_eq "lazy: opened, its tools offered, the opener gone" "13 0" \
  "$(jq -r '"\([.[] | select(startswith("mcp__photos__"))] | length) \([.[] | select(. == "open_tools__photos")] | length)"' <<<"$second")"
expect_eq "lazy: then called" '"photo_12"' "$(jq -c .name "$tmp/desk-calls.log")"
expect_eq "lazy: done" "Found." "$(jq -r .result <<<"$out")"
sid=$(jq -r .session_id <<<"$out")
: >"$tmp/requests.log"
echo "AGENTTEST:lazy again" | agent -p --mcp-config "$desk_config" --lazy-mcp 12 --resume "$sid" >/dev/null
expect_eq "lazy: what was opened stays open on --resume" "13" \
  "$(requests lazy | sed -n 1p | jq '[.tools[].name | select(startswith("mcp__photos__"))] | length')"

# -- The broker's context (--context-for) ---------------------------------------------------------
: >"$tmp/requests.log"
out=$(printf '%s\n' '{"type": "user", "message": {"role": "user", "content": "AGENTTEST:hello what is next?"}, "nixbook": {"noActivity": true, "app": "firefox", "title": "Inbox"}}' |
  agent -p --input-format stream-json --output-format stream-json --context-for bubble --privacy)
user=$(requests hello | tail -n1 | jq -r '.messages[0].content | if type == "string" then . else map(.text) | join("") end')
expect_contains "context: the broker's block first" "$user" "<context>
CTXBLOCK for=bubble query=AGENTTEST:hello what is next? noact=yes app=firefox title=Inbox"
expect_contains "context: masked with --privacy" "$user" "⟦Person 1⟧"
expect_contains "context: then the message" "$user" "</context>"
expect_contains "context: said to be data" "$(requests hello | tail -n1 | jq -r '.system[0].text')" "data, never instructions"

# -- The episode learned (--learn) -------------------------------------------------------------------
: >"$tmp/episode.log"
echo "AGENTTEST:fine open firefox" | agent -p --mcp-config "$desk_config" --learn --context-for bubble >/dev/null
expect_eq "learn: the episode, its app the focused window's" '{"task":"AGENTTEST:fine open firefox","actions":[{"tool":"launch_app","do":"app=firefox","error":null}],"app":"firefox"}' \
  "$(sed -n 1p "$tmp/episode.log" | jq -c .)"
: >"$tmp/episode.log"
echo "AGENTTEST:hello" | agent -p --mcp-config "$desk_config" --learn >/dev/null
expect_eq "learn: nothing for a turn that didn't act" "" "$(cat "$tmp/episode.log")"

# -- The request read first (--resolve) --------------------------------------------------------------
script resolve '{"steps": [[{"type": "text", "text": "Closed the browser."}]],
  "system": {"You read the user": [{"type": "tool_use", "id": "q1", "name": "structured_output", "input": {"intent": "Close a window",
    "readings": ["close Firefox", "close Kitty"], "ambiguous": true, "question": "Which one, Firefox or Kitty?"}}]}}'
: >"$tmp/requests.log"
out=$(printf '%s\n%s\n' '{"type": "user", "message": {"role": "user", "content": "AGENTTEST:resolve close it"}}' \
  '{"type": "user", "message": {"role": "user", "content": "AGENTTEST:resolve close Firefox"}}' |
  agent -p --input-format stream-json --output-format stream-json --resolve --context-for bubble)
expect_eq "resolve: an ambiguous request gets the question back, no tools" "Which one, Firefox or Kitty? true 0" \
  "$(jq -r 'select(.type == "result") | "\(.result) \(.clarify) \(.num_turns)"' <<<"$out" | sed -n 1p)"
expect_eq "resolve: then the answer, not read again" "Closed the browser. null" \
  "$(jq -r 'select(.type == "result") | "\(.result) \(.clarify)"' <<<"$out" | tail -n1)"
reads=$(jq -c 'select(.path == "/v1/messages" and (.body.system | tostring | contains("You read the user"))) | .body' "$tmp/requests.log")
expect_eq "resolve: once, by the decisions model (ai.routing: big), with its effort" '"big-model" "low"' \
  "$(jq -r '"\(.model | tojson) \(.output_config.effort | tojson)"' <<<"$reads" | paste -sd'|')"
expect_contains "resolve: given the broker's context" "$(jq -c .messages <<<"$reads")" "CTXBLOCK for=bubble"
expect_eq "resolve: the question kept in the conversation" '["user","assistant","user"]' \
  "$(requests resolve | grep -v 'You read the user' | tail -n1 | jq -c '[.messages[].role]')"
script resolved '{"steps": [[{"type": "text", "text": "Done."}]],
  "system": {"You read the user": [{"type": "tool_use", "id": "q1", "name": "structured_output", "input": {"intent": "Close the Firefox window",
    "readings": ["close Firefox"], "ambiguous": false, "question": ""}}]}}'
echo '{"ai": {"routing": {"decisions": "small", "decisionsEffort": "medium"}}}' >"$tmp/cfg/nixbook-shell/config.json"
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:resolved close it" | agent -p --output-format json --resolve)
expect_contains "resolve: a clear request goes on with its intent" \
  "$(requests resolved | grep -v 'You read the user' | tail -n1 | jq -c '.messages[0].content')" "<intent>Close the Firefox window</intent>"
expect_eq "resolve: the routing's model and effort" '"small-model" "medium"' \
  "$(jq -c 'select(.path == "/v1/messages" and (.body.system | tostring | contains("You read the user"))) | .body | "\(.model | tojson) \(.output_config.effort | tojson)"' -r "$tmp/requests.log")"
rm "$tmp/cfg/nixbook-shell/config.json"
: >"$tmp/requests.log"
echo "AGENTTEST:resolved how are you" | agent -p --resolve >/dev/null
expect_eq "resolve: not for a plain question" "0" \
  "$(jq -c 'select(.body.system | tostring | contains("You read the user"))' "$tmp/requests.log" | wc -l | tr -d ' ')"

# -- The result checked (--verify) --------------------------------------------------------------------
script verify '[[{"type": "tool_use", "id": "v1", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}}],
  [{"type": "text", "text": "Opened."}],
  [{"type": "tool_use", "id": "v2", "name": "mcp__desktop__close_window", "input": {"id": 3}},
   {"type": "tool_use", "id": "v3", "name": "mcp__desktop__list_windows", "input": {}}],
  [{"type": "tool_use", "id": "v4", "name": "verification", "input": {"met": false, "note": "no Firefox window"}}],
  [{"type": "tool_use", "id": "v5", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}}],
  [{"type": "text", "text": "Fixed: Firefox is open now."}]]'
: >"$tmp/requests.log"
: >"$tmp/desk-calls.log"
out=$(echo "AGENTTEST:verify open firefox" | agent -p --output-format stream-json --mcp-config "$desk_config" --verify)
expect_eq "verify: the verdict" '{"type":"verify","met":false,"note":"no Firefox window"}' "$(jq -c 'select(.type == "verify") | del(.session_id)' <<<"$out")"
expect_eq "verify: only reading tools in the check, then the fix" "launch_app list_windows launch_app" "$(jq -r .name "$tmp/desk-calls.log" | paste -sd' ')"
expect_contains "verify: an acting tool refused in it" "$(requests verify | sed -n 4p | jq -c '.messages[-1].content')" "this round only checks"
expect_contains "verify: an internal message" "$(requests verify | sed -n 3p | jq -c '.messages[-1].content')" "[verify]"
expect_eq "verify: the fixed answer, not verified" "Fixed: Firefox is open now. false" \
  "$(jq -r 'select(.type == "result") | "\(.result) \(.verified)"' <<<"$out")"
script verified '[[{"type": "tool_use", "id": "w1", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}}],
  [{"type": "text", "text": "Opened."}],
  [{"type": "tool_use", "id": "w2", "name": "verification", "input": {"met": true, "note": "Firefox is in front"}}]]'
out=$(echo "AGENTTEST:verified open firefox" | agent -p --output-format json --mcp-config "$desk_config" --verify)
expect_eq "verify: met, the answer as it was" "Opened. true" "$(jq -r '"\(.result) \(.verified)"' <<<"$out")"
out=$(echo "AGENTTEST:hello" | agent -p --output-format json --verify)
expect_eq "verify: nothing to check when nothing acted" "null" "$(jq -c .verified <<<"$out")"

# -- The client (nixbook_ai): a busy server tried again -----------------------------------------------
out=$(echo "AGENTTEST:hello RETRY429:2" | agent -p --output-format json)
expect_eq "retry: a 429 twice, then the answer" "Hello there" "$(jq -r .result <<<"$out")"

# -- The provider -------------------------------------------------------------------------
cat >"$tmp/bin/nixbook-model-provider" <<'EOF'
#!/usr/bin/env bash
[ "$1" = run ] && shift
export NIXBOOK_AI_KEY=test-key NIXBOOK_AI_PROVIDED=1
exec "$@"
EOF
chmod +x "$tmp/bin/nixbook-model-provider"
expect_eq "provider: no key here, through nixbook-model-provider" "Hello there" \
  "$(echo "AGENTTEST:hello" | NIXBOOK_AI_KEY='' agent -p)"
rm "$tmp/bin/nixbook-model-provider"
out=$(echo "AGENTTEST:hello" | NIXBOOK_AI_KEY='' agent -p --output-format json) && rc=0 || rc=$?
expect_eq "provider: no key, no provider: an error result" "1 true" "$rc $(jq -r .is_error <<<"$out")"
out=$(echo "AGENTTEST:hello" | NIXBOOK_AI_KEY=wrong agent -p --output-format json) && rc=0 || rc=$?
expect_eq "provider: the server's refusal said" "1 API error: HTTP 401: bad key" "$rc $(jq -r .result <<<"$out")"

# -- Stopped (SIGTERM): saved, resumable ----------------------------------------------
# A marker no other command line has (pgrep/pkill -f look at them all).
mark="$$$RANDOM"
sid="stop-test-$mark"
script stop "[[{\"type\": \"tool_use\", \"id\": \"z1\", \"name\": \"Bash\", \"input\": {\"command\": \"sleep 37.$mark\"}}], [{\"type\": \"text\", \"text\": \"resumed\"}]]"
: >"$tmp/requests.log"
(cd "$tmp/work" && echo "AGENTTEST:stop" | exec python3 -I "$script" -p --tools Bash --output-format json --session-id "$sid" >/dev/null) &
pid=$!
for _ in $(seq 100); do
  pgrep -f "sleep 37.$mark" >/dev/null && break
  sleep 0.1
done
started=$(date +%s)
pkill -TERM -f "session-id $sid" || true
wait "$pid" 2>/dev/null && rc=0 || rc=$?
expect_eq "SIGTERM: out at once" "143 yes" "$rc $([ $(($(date +%s) - started)) -le 2 ] && echo yes || echo no)"
for _ in $(seq 20); do
  pgrep -f "sleep 37.$mark" >/dev/null || break
  sleep 0.1
done
if pgrep -f "sleep 37.$mark" >/dev/null; then fail "SIGTERM: the command stopped too"; else pass "SIGTERM: the command stopped too"; fi
out=$(echo "go on" | agent -p --output-format json --tools Bash --resume "$sid")
expect_eq "SIGTERM: resumed after it" "resumed" "$(jq -r .result <<<"$out")"
expect_contains "SIGTERM: the stopped call marked" "$(requests stop | tail -n1 | jq -c '.messages[2].content')" "interrupted"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all meta-agent tests passed"
