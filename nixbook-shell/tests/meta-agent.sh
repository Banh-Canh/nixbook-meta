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
#     the request read first (--resolve), the result checked (--verify);
#   - the trust ladder (--trust): ask (approval, recorded, a promotion
#     suggested), tell (told, journaled with the tool's undo), silent, the
#     --confirm floor; a session forked (--fork-session).
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
# The placeholders (⟦Person N⟧) here; the pseudonyms have tests of their own.
export NIXBOOK_PRIVACY_PSEUDONYMS=0
export XDG_STATE_HOME="$tmp/state"
# Never the user's own desktop-mcp helper (its socket) nor settings.
mkdir -p "$tmp/run" "$tmp/cfg/nixbook-shell"
export XDG_RUNTIME_DIR="$tmp/run" XDG_CONFIG_HOME="$tmp/cfg" XDG_CACHE_HOME="$tmp/cache" NIXBOOK_AI_RETRY_DELAY=0.05

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
trust)
  # trust check CLASS --risky N: the level in trust-levels ("CLASS LEVEL
  # [set]"), else the defaults; trust record CLASS OUTCOME: logged, and a
  # class listed in trust-promote is suggested.
  echo "$*" >>"$log/trust.log"
  if [ "$2" = check ]; then
    line=$(awk -v c="$3" '$1 == c' "$log/trust-levels" 2>/dev/null | head -n1)
    if [ -n "$line" ]; then
      set -- $line
      jq -cn --arg l "$2" --arg w "${3:-}" '{level: $l, why: (if $w == "set" then "set by you" else "learned" end), suggestPromote: false}'
    elif [ "$5" = 1 ]; then echo '{"level": "ask", "why": "risky", "suggestPromote": false}'
    else echo '{"level": "tell", "why": "default", "suggestPromote": false}'; fi
  elif [ "$2" = record ]; then
    if grep -qxF "$3" "$log/trust-promote" 2>/dev/null; then p=true; else p=false; fi
    jq -cn --argjson p "$p" '{level: "ask", suggestPromote: $p}'
  fi ;;
journal)
  [ "$2" = add ] || exit 1
  printf '%s\n' "$3" >>"$log/journal.log"
  jq -cn --arg n "$(wc -l <"$log/journal.log" | tr -d ' ')" '{id: ("j" + $n)}' ;;
*) exit 1 ;;
esac
EOF
# A stub MCP server: echo, look (an image), slow; what it was called with logged.
cat >"$tmp/stub-mcp.py" <<'EOF'
import json, sys, time
log = sys.argv[1]
tools = [{"name": "echo", "description": "Echo the text", "inputSchema": {"$schema": "x", "type": "object", "properties": {"text": {"type": "string"}}}},
         {"name": "look", "description": "An image", "inputSchema": {"type": "object", "properties": {}}},
         {"name": "slow", "description": "Takes its time", "inputSchema": {"type": "object", "properties": {}}},
         {"name": "contacts", "description": "Find a contact", "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}}}}]
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
        if p["name"] == "contacts":
            res = {"content": [{"type": "text", "text": "contacts: " + p["arguments"].get("query", "")}]}
        elif p["name"] == "look":
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
import json, os, sys
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
              "annotations": {"readOnlyHint": False, "destructiveHint": True}},
             {"name": "type_text", "description": "Type into the window in front", "inputSchema": obj(text="string"),
              "annotations": {"readOnlyHint": False}, "_meta": {"nixbook/group": "input"}},
             {"name": "status_json", "description": "A long JSON status", "inputSchema": obj(),
              "annotations": {"readOnlyHint": True}, "_meta": {"nixbook/group": "observe"}}]
    if "TERM" in os.environ.get("STUB_DESKTOP", ""):
        tools.append({"name": "terminal_run", "description": "Run a command", "inputSchema": obj(command="string"),
                      "annotations": {"readOnlyHint": False}, "_meta": {"nixbook/group": "terminal"}})
    if "CORE" in os.environ.get("STUB_DESKTOP", ""):
        core = {"launch_app", "list_windows", "close_window"}
        for t in tools:
            t.setdefault("_meta", {})["nixbook/core"] = t["name"] in core
            t["_meta"].setdefault("nixbook/group", "windows" if t["name"] != "tasks" else "shell")
            if t["name"] == "tasks":
                # A finer bundle than its group: what --core-tools loads together.
                t["_meta"]["nixbook/bundle"] = "pim"
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
            if p["name"] == "launch_app":
                # The step taken back (--trust: the journal's undo); what
                # shows its effect (--verify: the engine's own look).
                res["_meta"] = {"undo": {"tool": "close_window", "args": {"id": 9}},
                                "observe": {"tool": "list_windows", "args": {}}}
            elif p["name"] == "close_window":
                # It checked its own effect: nothing more to verify.
                res["_meta"] = {"verified": True}
            elif p["name"] == "status_json":
                res = {"content": [{"type": "text", "text": json.dumps({"windows": [{"id": i, "title": "x" * 50} for i in range(200)]}, indent=2)}]}
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
expect_eq "stream-json: init, deltas, the message, the answer, the result" "system stream_event assistant answer result" \
  "$(jq -r .type <<<"$out" | uniq | paste -sd' ')"
expect_eq "stream-json: the text as it streams" "Hello there" \
  "$(jq -r 'select(.type == "stream_event" and .event.delta.type == "text_delta") | .event.delta.text' <<<"$out" | tr -d '\n')"
expect_eq "stream-json: the init's session is the result's" "1" \
  "$(jq -r 'select(.type == "system" or .type == "result") | .session_id' <<<"$out" | sort -u | wc -l | tr -d ' ')"
expect_eq "stream-json: streamed from the server" "true" "$(requests hello | tail -n1 | jq -c .stream)"

# --quiet-steps: a turn's first line and its answer stream, not the words
# between its steps (the conversation keeps them).
script quiet "[[
  {\"type\": \"text\", \"text\": \"Closing them all.\"},
  {\"type\": \"tool_use\", \"id\": \"q1\", \"name\": \"Glob\", \"input\": {\"pattern\": \"*.txt\", \"path\": \"$tmp/rw\"}}
], [
  {\"type\": \"text\", \"text\": \"Need to close rest.\"},
  {\"type\": \"tool_use\", \"id\": \"q2\", \"name\": \"Glob\", \"input\": {\"pattern\": \"*.txt\", \"path\": \"$tmp/rw\"}}
], [
  {\"type\": \"text\", \"text\": \"Still closing.\"},
  {\"type\": \"tool_use\", \"id\": \"q3\", \"name\": \"Glob\", \"input\": {\"pattern\": \"*.txt\", \"path\": \"$tmp/rw\"}}
], [{\"type\": \"text\", \"text\": \"All closed.\"}]]"
streamed() { jq -r 'select(.type == "stream_event" and .event.delta.type == "text_delta") | .event.delta.text' | tr -d '\n'; }
out=$(echo "AGENTTEST:quiet go" | agent -p --output-format stream-json --verbose --include-partial-messages --tools Glob --quiet-steps)
expect_eq "quiet steps: the first line and the answer only" "Closing them all.All closed." "$(streamed <<<"$out")"
expect_eq "quiet steps: the answer is the result" "All closed." "$(jq -r 'select(.type == "result") | .result' <<<"$out")"
expect_eq "quiet steps: every step still ran" "3" "$(jq -r 'select(.type == "user") | .message.content[] | select(.type == "tool_result") | .tool_use_id' <<<"$out" | wc -l | tr -d ' ')"
out=$(echo "AGENTTEST:quiet go" | agent -p --output-format stream-json --verbose --include-partial-messages --tools Glob)
expect_eq "without it: every word streams" "Closing them all.Need to close rest.Still closing.All closed." "$(streamed <<<"$out")"

# --finish: the answer given with the last steps ends the turn once they
# succeed (no call only to say "done"); a failed step and it goes on.
script finish "[[
  {\"type\": \"text\", \"text\": \"Looking.\"},
  {\"type\": \"tool_use\", \"id\": \"f1\", \"name\": \"Glob\", \"input\": {\"pattern\": \"*.txt\", \"path\": \"$tmp/rw\"}},
  {\"type\": \"tool_use\", \"id\": \"f2\", \"name\": \"finish\", \"input\": {\"answer\": \"All found.\"}}
], [{\"type\": \"text\", \"text\": \"Should not be asked.\"}]]"
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:finish go" | agent -p --output-format stream-json --verbose --include-partial-messages --tools Glob --add-dir "$tmp/rw" --finish --quiet-steps)
expect_eq "finish: one model call" "1" "$(requests finish | wc -l | tr -d ' ')"
expect_eq "finish: the answer is the result" "All found." "$(jq -r 'select(.type == "result") | .result' <<<"$out")"
expect_eq "finish: shown as it streams, after the first line" "Looking.All found." "$(streamed <<<"$out")"
expect_contains "finish: offered as a tool" "$(requests finish | head -n1 | jq -c '[.tools[].name]')" '"finish"'
script finishfail "[[
  {\"type\": \"tool_use\", \"id\": \"g1\", \"name\": \"Read\", \"input\": {\"file_path\": \"$tmp/home/secret.txt\"}},
  {\"type\": \"tool_use\", \"id\": \"g2\", \"name\": \"finish\", \"input\": {\"answer\": \"Read it.\"}}
], [{\"type\": \"text\", \"text\": \"I couldn't read it.\"}]]"
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:finishfail go" | agent -p --output-format json --tools Read --finish)
expect_eq "finish: a failed step, and it goes on" "I couldn't read it." "$(jq -r .result <<<"$out")"
expect_contains "finish: told why it wasn't shown" "$(requests finishfail | sed -n 2p)" "Not shown: a step above failed"
out=$(echo "AGENTTEST:finish go" | agent -p --output-format json --tools Glob --add-dir "$tmp/rw")
expect_eq "finish: not offered without the flag" "0" "$(requests finish | tail -n1 | jq '[.tools[].name | select(. == "finish")] | length')"

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
orig=$(jq -c '.messages | length' "$file")
out=$(echo "AGENTTEST:resume forked" | agent -p --output-format json --resume "$sid" --fork-session --session-id "fork-$sid")
expect_eq "fork-session: the conversation goes on under its own id" "fork-$sid" "$(jq -r .session_id <<<"$out")"
expect_eq "fork-session: with the earlier turns" "5" "$(requests resume | tail -n1 | jq '.messages | length')"
expect_eq "fork-session: the original left as it was" "$orig" "$(jq -c '.messages | length' "$file")"
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
expect_eq "mcp: its tools, as mcp__server__tool" '["mcp__stub__echo","mcp__stub__look","mcp__stub__slow","mcp__stub__contacts"]' "$(jq -c '[.tools[].name]' <<<"$first")"
expect_eq "mcp: no schema dialect key" "null" "$(jq -c '.tools[0].input_schema["$schema"]' <<<"$first")"
expect_contains "mcp: its instructions in the system prompt" "$(jq -c .system <<<"$first")" "STUBINSTRUCTIONS"
expect_eq "mcp: in the init event" '["connected"]' "$(jq -c 'select(.type == "system") | [.mcp_servers[].status]' <<<"$out")"
expect_eq "privacy: the input unmasked for the server" "Julien says hi" "$(jq -r 'select(.name == "echo") | .arguments.text' "$tmp/mcp-calls.log" | head -n1)"
results=$(requests mcp | tail -n1 | jq -c '.messages[-1].content')
expect_eq "privacy: its result masked for the model" "echo: ⟦Person 1⟧ says hi" \
  "$(jq -r '.[] | select(.tool_use_id == "m1") | .content[0].text' <<<"$results")"
# A name made up for a hidden person: the user names ⟦Person 1⟧, the model
# searches "Guilloux" (nobody said it): refused, never run; the placeholder
# then runs, the tool getting the real name. A name the user gave runs.
script madeup '[[{"type": "tool_use", "id": "g1", "name": "mcp__stub__contacts", "input": {"query": "Guilloux"}}],
  [{"type": "tool_use", "id": "g2", "name": "mcp__stub__contacts", "input": {"query": "⟦Person 1⟧"}}], [{"type": "text", "text": "ok"}]]'
: >"$tmp/mcp-calls.log"
: >"$tmp/requests.log"
echo "AGENTTEST:madeup send a dm to ⟦Person 1⟧ on discord" | agent -p --strict-mcp-config --mcp-config "$mcp_config" --privacy >/dev/null
expect_eq "made-up name: never run, the placeholder then is (the real name)" "Julien" \
  "$(jq -r 'select(.name == "contacts") | .arguments.query' "$tmp/mcp-calls.log" | paste -sd' ')"
expect_contains "made-up name: told to use the placeholder" \
  "$(requests madeup | sed -n 2p | jq -c '.messages[-1].content[0]')" 'that name was never said in this conversation, so it isn'"'"'t who ⟦Person 1⟧ is'
script givenname '[[{"type": "tool_use", "id": "k1", "name": "mcp__stub__contacts", "input": {"query": "Juju42"}}], [{"type": "text", "text": "ok"}]]'
: >"$tmp/mcp-calls.log"
echo "AGENTTEST:givenname send a dm to ⟦Person 1⟧, Juju42 on discord" | agent -p --strict-mcp-config --mcp-config "$mcp_config" --privacy >/dev/null
expect_eq "made-up name: one the user gave runs" "Juju42" "$(jq -r 'select(.name == "contacts") | .arguments.query' "$tmp/mcp-calls.log")"
script nomask '[[{"type": "tool_use", "id": "n1", "name": "mcp__stub__contacts", "input": {"query": "Guilloux"}}], [{"type": "text", "text": "ok"}]]'
: >"$tmp/mcp-calls.log"
echo "AGENTTEST:nomask send a dm to ⟦Person 1⟧" | agent -p --strict-mcp-config --mcp-config "$mcp_config" >/dev/null
expect_eq "made-up name: only with --privacy" "Guilloux" "$(jq -r 'select(.name == "contacts") | .arguments.query' "$tmp/mcp-calls.log")"
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
expect_eq "confirm: no answer (the input ended) is not done, and not a no" '"No answer in time: not done (the user didn'"'"'t say no; ask again if it still matters)."' "$(requests approve | tail -n1 | jq -c '.messages[-1].content[0].content')"
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
# A command run is asked for even when it isn't risky ("risky steps only"),
# unless --trust says the user let that kind through.
script termrun '[[{"type": "tool_use", "id": "r1", "name": "mcp__desktop__terminal_run", "input": {"command": "cargo test"}}],
  [{"type": "text", "text": "ok"}]]'
term_config=$(jq -c '.mcpServers.desktop.env.STUB_DESKTOP = "TERM"' <<<"$desk_config")
out=$(turn "AGENTTEST:termrun" '{"type": "approval", "id": "r1", "allow": false}' |
  agent -p --input-format stream-json --output-format stream-json --mcp-config "$term_config" --confirm destructive)
expect_eq "confirm destructive: a plain command run is still asked (no --trust)" '"r1"' \
  "$(jq -c 'select(.type == "approval_request") | .id' <<<"$out")"

# -- The trust ladder (--trust) ---------------------------------------------------------------------
# trusted ARGS…: a turn with the desktop's tools and --trust, its approvals after it.
trusted() { agent -p --input-format stream-json --output-format stream-json --mcp-config "$desk_config" --trust "$@"; }
reset_trust() {
  : >"$tmp/trust.log"
  : >"$tmp/journal.log"
  : >"$tmp/desk-calls.log"
  : >"$tmp/trust-levels"
  : >"$tmp/trust-promote"
}
script trustask '[[{"type": "tool_use", "id": "a1", "name": "mcp__desktop__tasks", "input": {"action": "add", "id": "milk"}}],
  [{"type": "text", "text": "Added."}]]'
reset_trust
echo "tasks:add ask" >"$tmp/trust-levels"
echo "tasks:add" >"$tmp/trust-promote"
out=$(turn "AGENTTEST:trustask add milk" '{"type": "approval", "id": "a1", "allow": true}' | trusted)
expect_eq "trust: an ask class waits for the user, its class said" '"a1" "tasks:add"' \
  "$(jq -c 'select(.type == "approval_request") | .id, .class' <<<"$out" | paste -sd' ')"
expect_eq "trust: the level asked once, the yes recorded" "check tasks:add --risky 0|record tasks:add allowed" \
  "$(sed 's/^trust //' "$tmp/trust.log" | paste -sd'|')"
expect_eq "trust: allowed, run" '"tasks"' "$(jq -c .name "$tmp/desk-calls.log")"
expect_eq "trust: a third yes in a row: the shell offers to stop asking" '{"type":"trust_suggest","class":"tasks:add","summary":"tasks: add","step":"id=milk, action=add"}' \
  "$(jq -c 'select(.type == "trust_suggest") | del(.session_id)' <<<"$out")"
expect_eq "trust: a step the user allowed isn't journaled" "" "$(cat "$tmp/journal.log")"
reset_trust
echo "tasks:add ask" >"$tmp/trust-levels"
out=$(turn "AGENTTEST:trustask add milk" '{"type": "approval", "id": "a1", "allow": false}' | trusted)
expect_eq "trust: a no recorded, not run, no suggestion" "record tasks:add denied||" \
  "$(sed -n 2p "$tmp/trust.log" | sed 's/^trust //')|$(cat "$tmp/desk-calls.log")|$(jq -c 'select(.type == "trust_suggest")' <<<"$out")"
reset_trust
echo "tasks:add ask" >"$tmp/trust-levels"
out=$(turn "AGENTTEST:trustask add milk" | NIXBOOK_AGENT_APPROVAL_TIMEOUT=1 trusted)
expect_eq "trust: no answer (the input ended): not recorded as the user's no" "check tasks:add --risky 0" "$(sed 's/^trust //' "$tmp/trust.log")"
reset_trust
echo "tasks:add ask" >"$tmp/trust-levels"
echo "AGENTTEST:trustask add milk" | agent -p --mcp-config "$desk_config" --trust >/dev/null
expect_contains "trust: an ask step with -p text input: refused" "$(requests trustask | tail -n1 | jq -c '.messages[-1].content[0]')" "no one to ask"
expect_eq "trust: nothing run, nothing recorded" "|check tasks:add --risky 0" "$(cat "$tmp/desk-calls.log")|$(sed 's/^trust //' "$tmp/trust.log")"

script trusttell '[[{"type": "tool_use", "id": "b1", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}},
  {"type": "tool_use", "id": "b2", "name": "mcp__desktop__list_windows", "input": {}}],
  [{"type": "tool_use", "id": "b3", "name": "mcp__desktop__type_text", "input": {"text": "hello"}}],
  [{"type": "text", "text": "Typed it."}]]'
reset_trust
echo "type_text@firefox silent" >"$tmp/trust-levels"
out=$(turn "AGENTTEST:trusttell open firefox and type" | trusted --journal-source task --task abc123def456)
expect_eq "trust: tell and silent run without asking" "" "$(jq -c 'select(.type == "approval_request")' <<<"$out")"
expect_eq "trust: a tell step said, with its journal entry and undo" '{"type":"told","class":"launch_app@firefox","summary":"launch app (app=firefox)","journal":"j1","undo":true}' \
  "$(jq -c 'select(.type == "told") | del(.session_id)' <<<"$out")"
expect_eq "trust: a silent one not said" "1" "$(jq -c 'select(.type == "told")' <<<"$out" | wc -l | tr -d ' ')"
expect_eq "trust: reading steps never checked; an input step's class is the app in front" \
  "check launch_app@firefox --risky 0|check type_text@firefox --risky 0" "$(sed 's/^trust //' "$tmp/trust.log" | paste -sd'|')"
sid=$(jq -r 'select(.type == "result") | .session_id' <<<"$out")
expect_eq "trust: the journal gets both, the undo from the tool's _meta.undo" \
  "$(jq -cn --arg s "$sid" '[{source: "task", class: "launch_app@firefox", summary: "launch app (app=firefox)", tool: "launch_app", args: {app: "firefox"}, session: $s, task: "abc123def456", undo: {tool: "close_window", args: {id: 9}}}, {source: "task", class: "type_text@firefox", summary: "type text (text=hello)", tool: "type_text", args: {text: "hello"}, session: $s, task: "abc123def456"}]')" \
  "$(jq -sc . "$tmp/journal.log")"

script trustrisky '[[{"type": "tool_use", "id": "d1", "name": "mcp__desktop__tasks", "input": {"action": "delete", "id": "t1"}}],
  [{"type": "text", "text": "Handled."}]]'
reset_trust
echo "tasks:delete silent" >"$tmp/trust-levels"
out=$(turn "AGENTTEST:trustrisky delete it" '{"type": "approval", "id": "d1", "allow": true}' | trusted --confirm destructive)
expect_eq "trust: a risky step still asked (the --confirm floor) when trust says otherwise" '"d1" "check tasks:delete --risky 1"' \
  "$(jq -c 'select(.type == "approval_request") | .id' <<<"$out") \"$(head -n1 "$tmp/trust.log" | sed 's/^trust //')\""
reset_trust
echo "tasks:delete silent set" >"$tmp/trust-levels"
out=$(turn "AGENTTEST:trustrisky delete it" | trusted --confirm destructive)
expect_eq "trust: unless the user set its level themselves" "|1" \
  "$(jq -c 'select(.type == "approval_request")' <<<"$out")|$(wc -l <"$tmp/journal.log" | tr -d ' ')"
reset_trust
out=$(turn "AGENTTEST:trustrisky delete it" '{"type": "approval", "id": "d1", "allow": true}' | trusted)
expect_eq "trust: a risky class is ask by default, even without --confirm" '"d1"' "$(jq -c 'select(.type == "approval_request") | .id' <<<"$out")"
rm -f "$tmp/trust-levels" "$tmp/trust-promote"

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
out=$(echo "AGENTTEST:lazy find my beach pictures" | agent -p --output-format json --mcp-config "$desk_config" --lazy-mcp 12)
opener=$(requests lazy | sed -n 1p | jq -r '.tools[] | select(.name == "open_tools__photos") | .description')
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
expect_contains "lazy: its tools callable by their full name, the opener says" "$opener" "mcp__photos__TOOL"
# Named in the request: offered from the first call, no open_tools__ round trip.
script prefetch '[[{"type": "text", "text": "Found."}]]'
: >"$tmp/requests.log"
echo "AGENTTEST:prefetch find my beach photos [Current date & time: 10:00; Focused app: kitty]" | agent -p --mcp-config "$desk_config" --lazy-mcp 12 >/dev/null
first=$(requests prefetch | sed -n 1p | jq -c '[.tools[].name]')
expect_eq "prefetch: a server the request names, offered at once" "13 0" \
  "$(jq '[.[] | select(startswith("mcp__photos__"))] | length' <<<"$first") $(jq '[.[] | select(. == "open_tools__photos")] | length' <<<"$first")"
: >"$tmp/requests.log"
echo "AGENTTEST:prefetch what time is it [Current date & time: 10:00; Focused app: photos]" | agent -p --mcp-config "$desk_config" --lazy-mcp 12 >/dev/null
expect_eq "prefetch: not from the app in front, nor unasked" "1" \
  "$(requests prefetch | sed -n 1p | jq '[.tools[].name | select(. == "open_tools__photos")] | length')"

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
# Only when it may be ambiguous; then in parallel with the main call, on the
# small model with minimal effort; the tools wait for its verdict.
script resolve '{"steps": [{"content": [{"type": "text", "text": "Closing."}, {"type": "tool_use", "id": "c1", "name": "mcp__desktop__close_window", "input": {"id": 3}}], "hold": 1.5},
    [{"type": "text", "text": "Closed the browser."}]],
  "system": {"You read the user": {"delay": 0.3, "content": [{"type": "tool_use", "id": "q1", "name": "structured_output", "input": {"intent": "Close a window",
    "readings": ["close Firefox", "close Kitty"], "ambiguous": true, "question": "Which one, Firefox or Kitty?"}}]}}}'
: >"$tmp/requests.log"
: >"$tmp/desk-calls.log"
started=$(date +%s.%N)
out=$(printf '%s\n%s\n' '{"type": "user", "message": {"role": "user", "content": "AGENTTEST:resolve close it"}}' \
  '{"type": "user", "message": {"role": "user", "content": "AGENTTEST:resolve close Firefox"}}' |
  agent -p --input-format stream-json --output-format stream-json --resolve --context-for bubble --mcp-config "$desk_config")
expect_eq "resolve: an ambiguous request gets the question back, no tools" "Which one, Firefox or Kitty? true 0" \
  "$(jq -r 'select(.type == "result") | "\(.result) \(.clarify) \(.num_turns)"' <<<"$out" | sed -n 1p)"
expect_eq "resolve: the main call stopped, its tool never run" "" "$(cat "$tmp/desk-calls.log")"
expect_eq "resolve: the question as the answer" '"Which one, Firefox or Kitty?"' "$(jq -c 'select(.type == "answer") | .text' <<<"$out" | sed -n 1p)"
expect_eq "resolve: then the answer, not read again" "Closed the browser. null" \
  "$(jq -r 'select(.type == "result") | "\(.result) \(.clarify)"' <<<"$out" | tail -n1)"
reads=$(jq -c 'select(.path == "/v1/messages" and (.body.system | tostring | contains("You read the user")))' "$tmp/requests.log")
expect_eq "resolve: once, on the small model, minimal effort, a short answer" '"small-model" "minimal" 300' \
  "$(jq -r '.body | "\(.model | tojson) \(.output_config.effort | tojson) \(.max_tokens)"' <<<"$reads" | paste -sd'|')"
main_t=$(jq -r 'select(.path == "/v1/messages" and (.body.system | tostring | contains("You read the user") | not) and (.body | tostring | contains("AGENTTEST:resolve close it"))) | .t' "$tmp/requests.log" | head -n1)
expect_eq "resolve: in parallel with the main call (not before it)" "yes" \
  "$(python3 -c 'import sys; print("yes" if abs(float(sys.argv[1]) - float(sys.argv[2])) < 0.25 else "no")' "$main_t" "$(jq -r .t <<<"$reads")")"
expect_contains "resolve: given the broker's context" "$(jq -c .body.messages <<<"$reads")" "CTXBLOCK for=bubble"
expect_eq "resolve: the question kept in the conversation" '["user","assistant","user"]' \
  "$(requests resolve | grep -v 'You read the user' | tail -n1 | jq -c '[.messages[].role]')"
expect_eq "resolve: a stopped call leaves nothing in the conversation" "Which one, Firefox or Kitty?" \
  "$(requests resolve | grep -v 'You read the user' | tail -n1 | jq -r '.messages[1].content[0].text')"
# Clear requests: no resolver at all (a named app, a number, a plain question).
: >"$tmp/requests.log"
for q in "open firefox" "volume 30" "next workspace" "how are you" "close the kitty window"; do
  echo "AGENTTEST:hello $q" | agent -p --resolve >/dev/null
done
expect_eq "resolve: never for a request naming its target, nor a question" "0" \
  "$(jq -c 'select(.body.system | tostring | contains("You read the user"))' "$tmp/requests.log" | wc -l | tr -d ' ')"
# "the other one": read, not ambiguous: the tool runs once the verdict is in.
script resolved '{"steps": [[{"type": "tool_use", "id": "f1", "name": "mcp__desktop__focus_window", "input": {"id": 4}}], [{"type": "text", "text": "Done."}]],
  "system": {"You read the user": {"delay": 0.4, "content": [{"type": "tool_use", "id": "q1", "name": "structured_output", "input": {"intent": "Focus the Kitty window",
    "readings": ["focus Kitty"], "ambiguous": false, "question": ""}}]}}}'
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:resolved the other one" | agent -p --output-format stream-json --resolve)
expect_eq "resolve: the other one: read once, then done" "1 Done." \
  "$(jq -c 'select(.body.system | tostring | contains("You read the user"))' "$tmp/requests.log" | wc -l | tr -d ' ') $(jq -r 'select(.type == "result") | .result' <<<"$out")"
echo '{"ai": {"routing": {"resolve": "big", "decisionsEffort": "medium", "effortMinimal": false}}}' >"$tmp/cfg/nixbook-shell/config.json"
: >"$tmp/requests.log"
echo "AGENTTEST:resolved close it" | agent -p --output-format json --resolve >/dev/null
expect_eq "resolve: the routing's model, and its effort when effortMinimal is off" '"big-model" "medium"' \
  "$(jq -c 'select(.path == "/v1/messages" and (.body.system | tostring | contains("You read the user"))) | .body | "\(.model | tojson) \(.output_config.effort | tojson)"' -r "$tmp/requests.log")"
rm "$tmp/cfg/nixbook-shell/config.json"

# -- The result checked (--verify) --------------------------------------------------------------------
# One check on the small model: the acting calls and the engine's own look
# (the tool's _meta.observe); one fix round when it isn't done.
script verify '{"steps": [[{"type": "tool_use", "id": "v1", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}}],
  [{"type": "text", "text": "Opened."}],
  [{"type": "tool_use", "id": "v5", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}}],
  [{"type": "text", "text": "Fixed: Firefox is open now."}]],
  "system": {"You check whether": [{"type": "tool_use", "id": "v4", "name": "verification", "input": {"met": false, "note": "no Firefox window"}}]}}'
: >"$tmp/requests.log"
: >"$tmp/desk-calls.log"
out=$(echo "AGENTTEST:verify open firefox" | agent -p --output-format stream-json --mcp-config "$desk_config" --verify)
expect_eq "verify: the verdict" '{"type":"verify","met":false,"note":"no Firefox window","by":"model"}' "$(jq -c 'select(.type == "verify") | del(.session_id)' <<<"$out")"
expect_eq "verify: the engine's own look (observe), then the fix" "launch_app list_windows launch_app" "$(jq -r .name "$tmp/desk-calls.log" | paste -sd' ')"
checks=$(jq -c 'select(.path == "/v1/messages" and (.body.system | tostring | contains("You check whether"))) | .body' "$tmp/requests.log")
expect_eq "verify: one call, small model, forced verdict, short" '1 "small-model" {"type":"tool","name":"verification"} 300 ["verification"]' \
  "$(wc -l <<<"$checks" | tr -d ' ') $(jq -c '.model' <<<"$checks") $(jq -c '.tool_choice' <<<"$checks") $(jq -c '.max_tokens' <<<"$checks") $(jq -c '[.tools[].name]' <<<"$checks")"
expect_contains "verify: the acting calls and what the computer sees now" "$(jq -c .messages <<<"$checks")" "list_windows now says"
expect_eq "verify: the verification tool offered from the first call (the cache)" "true" \
  "$(requests verify | grep -v 'You check whether' | head -n1 | jq '[.tools[].name] | index("verification") != null')"
expect_eq "verify: the answer before the check, the fixed one after" '"Opened." false|"Fixed: Firefox is open now." true' \
  "$(jq -c 'select(.type == "answer") | "\(.text | tojson) \(.revised // false)"' -r <<<"$out" | paste -sd'|')"
expect_eq "verify: the answer event before the verify event" "answer verify" \
  "$(jq -r 'select(.type == "answer" or .type == "verify") | .type' <<<"$out" | head -n2 | paste -sd' ')"
expect_eq "verify: the fixed answer, not verified" "Fixed: Firefox is open now. false" \
  "$(jq -r 'select(.type == "result") | "\(.result) \(.verified)"' <<<"$out")"
script verified '{"steps": [[{"type": "tool_use", "id": "w1", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}}],
  [{"type": "text", "text": "Opened."}]],
  "system": {"You check whether": [{"type": "tool_use", "id": "w2", "name": "verification", "input": {"met": true, "note": "Firefox is in front"}}]}}'
out=$(echo "AGENTTEST:verified open firefox" | agent -p --output-format json --mcp-config "$desk_config" --verify)
expect_eq "verify: met, the answer as it was" "Opened. true" "$(jq -r '"\(.result) \(.verified)"' <<<"$out")"
# Every acting tool checked its own effect (_meta.verified): no check call.
script selfcheck '{"steps": [[{"type": "tool_use", "id": "x1", "name": "mcp__desktop__close_window", "input": {"id": 3}}],
  [{"type": "text", "text": "Closed."}]], "system": {"You check whether": [{"type": "text", "text": "never asked"}]}}'
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:selfcheck close firefox" | agent -p --output-format stream-json --mcp-config "$desk_config" --verify)
expect_eq "verify: the tools checked it themselves, no model call" "0 true tools" \
  "$(jq -c 'select(.body.system | tostring | contains("You check whether"))' "$tmp/requests.log" | wc -l | tr -d ' ') $(jq -r 'select(.type == "result") | .verified' <<<"$out") $(jq -r 'select(.type == "verify") | .by' <<<"$out")"
# ai.routing.verify = the main model: the turn's own prefix (the cache), the
# check as one more message.
script verifymain '[[{"type": "tool_use", "id": "y1", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}}],
  [{"type": "text", "text": "Opened."}],
  [{"type": "tool_use", "id": "y2", "name": "verification", "input": {"met": true, "note": "seen"}}]]'
echo '{"ai": {"routing": {"verify": "main"}}}' >"$tmp/cfg/nixbook-shell/config.json"
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:verifymain open firefox" | agent -p --output-format json --mcp-config "$desk_config" --verify)
last=$(requests verifymain | tail -n1)
expect_eq "verify: on the main model, same tools as the turn, the [verify] message last" '"main-model" true true' \
  "$(jq -c .model <<<"$last") $(jq -c --argjson f "$(requests verifymain | head -n1 | jq -c '[.tools[].name]')" '[.tools[].name] == $f' <<<"$last") $(jq -c '.messages[-1].content[0].text | startswith("[verify]")' <<<"$last")"
expect_eq "verify: its verdict" "Opened. true" "$(jq -r '"\(.result) \(.verified)"' <<<"$out")"
rm "$tmp/cfg/nixbook-shell/config.json"
out=$(echo "AGENTTEST:hello" | agent -p --output-format json --verify)
expect_eq "verify: nothing to check when nothing acted" "null" "$(jq -c .verified <<<"$out")"

# -- Speed: kept-alive connections, tools started while the message streams ------------------------
script keep '[[{"type": "tool_use", "id": "k1", "name": "mcp__desktop__list_windows", "input": {}}],
  [{"type": "tool_use", "id": "k2", "name": "mcp__desktop__list_windows", "input": {}}], [{"type": "text", "text": "Seen."}]]'
: >"$tmp/requests.log"
echo "AGENTTEST:keep look twice" | agent -p --mcp-config "$desk_config" >/dev/null
expect_eq "keep-alive: the turn's three calls on one connection" "3 1" \
  "$(requests keep | wc -l | tr -d ' ') $(jq -r 'select(.body | tostring | contains("AGENTTEST:keep")) | .conn' "$tmp/requests.log" | sort -u | wc -l | tr -d ' ')"
# A tool call complete while the message still streams (held 1.5 s): run at once.
script streamed '[{"content": [{"type": "text", "text": "Opening."}, {"type": "tool_use", "id": "s1", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}}], "hold": 1.5},
  [{"type": "text", "text": "Open."}]]'
: >"$tmp/desk-calls.log"
out=$(echo "AGENTTEST:streamed open firefox" | agent -p --output-format stream-json --include-partial-messages --mcp-config "$desk_config")
expect_eq "streamed tools: started before the message ended" "tool_started message_stop" \
  "$(jq -r 'if .type == "tool_started" then "tool_started" elif .type == "stream_event" and .event.type == "message_stop" then "message_stop" else empty end' <<<"$out" | head -n2 | paste -sd' ')"
expect_eq "streamed tools: its id and name said" '"s1" "mcp__desktop__launch_app"' "$(jq -c 'select(.type == "tool_started") | .id, .name' <<<"$out" | paste -sd' ')"
expect_eq "streamed tools: and it ran, once" '"launch_app"' "$(jq -c .name "$tmp/desk-calls.log")"
expect_eq "streamed tools: the answer" "Open." "$(jq -r 'select(.type == "result") | .result' <<<"$out")"
# A step that needs the user's OK isn't started early: asked at the message's end, as before.
script streamask '[{"content": [{"type": "tool_use", "id": "d1", "name": "mcp__desktop__tasks", "input": {"action": "delete", "id": "t1"}}], "hold": 0.5},
  [{"type": "text", "text": "Handled."}]]'
: >"$tmp/desk-calls.log"
out=$(turn "AGENTTEST:streamask delete it" '{"type": "approval", "id": "d1", "allow": false}' |
  agent -p --input-format stream-json --output-format stream-json --include-partial-messages --mcp-config "$desk_config" --confirm destructive)
expect_eq "streamed tools: a risky one waits for the message's end and the user" "message_stop approval_request" \
  "$(jq -r 'if .type == "approval_request" then "approval_request" elif .type == "stream_event" and .event.type == "message_stop" then "message_stop" else empty end' <<<"$out" | head -n2 | paste -sd' ')"
expect_eq "streamed tools: denied, never run" "" "$(cat "$tmp/desk-calls.log")"
# The output limit reached halfway through a tool call: its input is
# incomplete, so it never runs (it used to run with {}). Alone: the reply is
# taken back (retract) and asked again once with twice the room.
script cutalone '[{"content": [{"type": "text", "text": "Saving."}, {"type": "tool_use", "id": "c1", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}, "cut": true}], "stop_reason": "max_tokens"}]'
: >"$tmp/desk-calls.log"
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:cutalone save it" | agent -p --output-format stream-json --include-partial-messages --mcp-config "$desk_config")
expect_eq "cut tool call: never run" "" "$(cat "$tmp/desk-calls.log")"
expect_eq "cut tool call: never shown as a step" "" "$(jq -r 'select(.type == "tool_started" or .type == "assistant") | .message.content[]? | select(.type == "tool_use") | .id' <<<"$out")"
expect_eq "cut alone: the reply taken back once" "1" "$(jq -c 'select(.type == "retract")' <<<"$out" | wc -l | tr -d ' ')"
expect_eq "cut alone: asked again with twice the room" "16000 32000" "$(requests cutalone | jq -r .max_tokens | paste -sd' ')"
# Beside whole calls: those run, the model is told to send the cut one again.
script cutpair '[{"content": [{"type": "tool_use", "id": "p1", "name": "mcp__desktop__list_windows", "input": {}}, {"type": "tool_use", "id": "p2", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}, "cut": true}], "stop_reason": "max_tokens"},
  [{"type": "text", "text": "Done."}]]'
: >"$tmp/desk-calls.log"
: >"$tmp/requests.log"
out=$(echo "AGENTTEST:cutpair look then open" | agent -p --output-format stream-json --include-partial-messages --mcp-config "$desk_config")
expect_eq "cut beside whole calls: the whole one ran, the cut one not" '"list_windows"' "$(jq -c .name "$tmp/desk-calls.log")"
expect_contains "cut beside whole calls: told to send it again" "$(requests cutpair | tail -n1 | jq -c '.messages[-1].content')" "cut off by the output limit"
expect_eq "cut beside whole calls: the turn goes on" "Done." "$(jq -r 'select(.type == "result") | .result' <<<"$out")"

# -- The prompt cache and the history sent -------------------------------------------------------------
: >"$tmp/requests.log"
out=$(printf '%s\n%s\n' '{"type": "user", "message": {"role": "user", "content": "AGENTTEST:twoturns one"}}' \
  '{"type": "user", "message": {"role": "user", "content": "two"}}' |
  agent -p --input-format stream-json --output-format stream-json --context-for bubble --mcp-config "$desk_config")
second=$(requests twoturns | tail -n1)
expect_eq "cache: breakpoints on the tools' end, the system's, the previous turn, the last message (4 at most)" \
  "4 true true true true" \
  "$(jq -c '[.. | objects | select(has("cache_control"))] | length' <<<"$second") $(jq -c '.tools[-1] | has("cache_control")' <<<"$second") $(jq -c '.system[-1] | has("cache_control")' <<<"$second") $(jq -c '.messages[1].content[-1] | has("cache_control")' <<<"$second") $(jq -c '.messages[-1].content[-1] | has("cache_control")' <<<"$second")"
expect_eq "cache: the recent turns' context blocks kept (cut in steps, so the cache holds)" "true true" \
  "$(jq -c '.messages[0] | tostring | contains("<context>")' <<<"$second") $(jq -c '.messages[-1] | tostring | contains("<context>")' <<<"$second")"
lighten=$(
  PYTHONDONTWRITEBYTECODE=1 python3 - "$script" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("ma", sys.argv[1]); ma = importlib.util.module_from_spec(spec); spec.loader.exec_module(ma)
img = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AAAA"}}
msgs = []
for t in range(9):
    msgs.append({"role": "user", "content": [{"type": "text", "text": f"<context>c{t}</context>\nask {t}"}]})
    msgs.append({"role": "assistant", "content": [{"type": "tool_use", "id": f"u{t}", "name": "shot", "input": {}}]})
    msgs.append({"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"u{t}", "content": [img]}]})
out = ma.api_messages(msgs)
ctx = [i // 3 for i, m in enumerate(out) if "<context>" in json.dumps(m)]
imgs = [i // 3 for i, m in enumerate(out) if '"image"' in json.dumps(m)]
cut = ma.api_messages(msgs, keep_turns=3)
print(json.dumps([ctx, imgs, len(cut), "ask 6" in json.dumps(cut[0])], separators=(",", ":")))
PY
)
asks=$(PYTHONDONTWRITEBYTECODE=1 python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('ma', sys.argv[1]); ma = importlib.util.module_from_spec(spec); spec.loader.exec_module(ma)
print(ma.asks_user('Found a group.\\nIs that where you want the hello?'), ma.asks_user('Sent it.'), ma.asks_user('Which one? **Work** or home?'))" "$script")
expect_eq "verify: none when the answer asks the user (it waits for them)" "True False True" "$asks"
expect_eq "lighten: contexts from turn 8, images from turn 4, the last 3 turns when too long" \
  '[[8],[4,5,6,7,8],9,true]' "$lighten"
sid=$(jq -r 'select(.type == "result") | .session_id' <<<"$out" | head -n1)
expect_eq "cache: the transcript keeps every context block" "2" \
  "$(jq '[.messages[] | select(.role == "user") | select(tostring | contains("<context>"))] | length' "$tmp/state/nixbook-shell/agent-sessions/$sid.json")"
expect_eq "cache: the system prompt the same each turn (no clock in it)" "1" \
  "$(requests twoturns | jq -c .system | sort -u | wc -l | tr -d ' ')"

# -- Tool results: compact JSON, cut; the desktop's core tools; the answer's limit --------------------------
script results '[[{"type": "tool_use", "id": "j1", "name": "mcp__desktop__status_json", "input": {}}], [{"type": "text", "text": "ok"}]]'
: >"$tmp/requests.log"
echo "AGENTTEST:results" | agent -p --mcp-config "$desk_config" --tool-result-max 500 --max-tokens 1200 >/dev/null
res=$(requests results | tail -n1 | jq -r '.messages[-1].content[0].content[0].text')
expect_contains "results: JSON sent compact" "$res" '{"windows":[{"id":0,"title":"'
expect_contains "results: cut at --tool-result-max" "$res" "more characters cut]"
expect_eq "results: no longer than that" "yes" "$([ ${#res} -lt 560 ] && echo yes || echo no)"
expect_eq "max-tokens: the answer's limit" "1200 1200" "$(requests results | jq -r .max_tokens | paste -sd' ')"
echo "AGENTTEST:results" | agent -p --mcp-config "$desk_config" >/dev/null
expect_eq "results: 6000 characters by default for an MCP tool" "yes" \
  "$(requests results | tail -n1 | jq -r '.messages[-1].content[0].content[0].text | length' | awk '{print ($1 > 5900 && $1 < 6100) ? "yes" : "no"}')"
core_config=$(jq -c '.mcpServers.desktop.env = {"STUB_DESKTOP": "CORE"} | del(.mcpServers.photos)' <<<"$desk_config")
script core '[[{"type": "tool_use", "id": "o1", "name": "open_tools__desktop_input", "input": {}}],
  [{"type": "tool_use", "id": "o2", "name": "mcp__desktop__type_text", "input": {"text": "hi"}}],
  [{"type": "tool_use", "id": "o3", "name": "mcp__desktop__tasks", "input": {"action": "list"}}], [{"type": "text", "text": "Typed."}]]'
: >"$tmp/requests.log"
: >"$tmp/desk-calls.log"
echo "AGENTTEST:core type hi" | agent -p --mcp-config "$core_config" --core-tools >/dev/null
first=$(requests core | sed -n 1p)
expect_eq "core tools: only the core ones up front, the others by bundle, else group" \
  '["mcp__desktop__launch_app","mcp__desktop__close_window","mcp__desktop__list_windows","open_tools__desktop_pim","open_tools__desktop_input","open_tools__desktop_observe"]' \
  "$(jq -c '[.tools[].name]' <<<"$first")"
expect_contains "core tools: an opener names its tools" "$(jq -r '.tools[] | select(.name == "open_tools__desktop_input") | .description' <<<"$first")" "Load the input tools: type_text"
expect_eq "core tools: opened, its group offered from the next call on" "true false" \
  "$(requests core | sed -n 2p | jq -c '([.tools[].name] | index("mcp__desktop__type_text") != null), ([.tools[].name] | index("open_tools__desktop_input") != null)' | paste -sd' ')"
expect_eq "core tools: a tool of a closed group called by its name: loaded and run" "type_text tasks" \
  "$(jq -r .name "$tmp/desk-calls.log" | paste -sd' ')"
echo "AGENTTEST:core again" | agent -p --mcp-config "$desk_config" --core-tools >/dev/null
expect_eq "core tools: a server marking none core: all of them up front" "0" \
  "$(requests core | tail -n1 | jq '[.tools[].name | select(startswith("open_tools__desktop"))] | length')"

# -- The provider through `nixbook-model-provider env` (no second start) -----------------------------
cat >"$tmp/bin/nixbook-model-provider" <<EOF
#!/usr/bin/env bash
if [ "\$1" = env ]; then
  jq -cn --arg b "$base" '{baseUrl: \$b, key: "test-key", model: "main-model", smallModel: "small-model", bigModel: "big-model", label: "Meta"}'
  exit 0
fi
echo run >>"$tmp/provider-run.log"
exit 1
EOF
chmod +x "$tmp/bin/nixbook-model-provider"
# shellcheck disable=SC2016 # the backticks are the text, not a command
expect_eq 'provider: through `env`, never run again through it' "Hello there|" \
  "$(echo "AGENTTEST:hello" | NIXBOOK_AI_KEY='' NIXBOOK_AI_BASE_URL='' agent -p)|$(cat "$tmp/provider-run.log" 2>/dev/null)"
rm "$tmp/bin/nixbook-model-provider"

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
