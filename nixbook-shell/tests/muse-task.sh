#!/usr/bin/env bash
# Tests for Muse's background tasks (scripts/muse-task.py, nixbook-muse-task),
# against the fake Messages API (tests/fake-messages.py, its scripted
# conversations: AGENTTEST:NAME), the real headless agent
# (scripts/meta-agent.py) and a stub nixbook-desktop-mcp (its MCP server,
# trust, journal, context and episode commands):
#   - a task started (a plain background process; systemd-run tried first
#     and its failure falling back), its state file after every event, done
#     with a notification, its steps journaled with source `task`;
#   - waiting on a risky step's approval (notified), allowed over the
#     control socket; waiting on its own question, answered;
#   - started from a side panel conversation (--from-session, forked);
#   - stopped; resumed after its runner was killed; an answer to a task
#     whose runner is gone; the desktop-control pause stopping it;
#   - at most ai.autonomy.maxTasks at once; policies.ai; list, show, clear.
# Needs bash, python3 and jq. Run: bash tests/muse-task.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
server_pid=""
cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null
  # The runners and agents still going (a failed test).
  pkill -f "$root/scripts/muse-task.py run" 2>/dev/null || true
  pkill -f "$root/scripts/meta-agent.py" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

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

mkdir -p "$tmp/bin" "$tmp/scripts" "$tmp/state" "$tmp/run" "$tmp/cfg/nixbook-shell" "$tmp/data" "$tmp/home"
export XDG_STATE_HOME="$tmp/state" XDG_RUNTIME_DIR="$tmp/run" XDG_CONFIG_HOME="$tmp/cfg" XDG_DATA_HOME="$tmp/data" XDG_CACHE_HOME="$tmp/cache"
export HOME="$tmp/home" NIXBOOK_AI_RETRY_DELAY=0.05 NIXBOOK_MUSE_TASK_SPAWN=plain
unset NIXBOOK_META_AGENT NIXBOOK_SHELL_CONFIG

# The stub desktop-mcp: with no arguments its MCP server (stub-desktop.py),
# else the commands the agent calls (all logged).
cat >"$tmp/bin/nixbook-desktop-mcp" <<EOF
#!/usr/bin/env bash
log="$tmp"
[ \$# -eq 0 ] && exec python3 -I "$tmp/stub-desktop.py" "$tmp/desk-calls.log"
echo "\$*" >>"\$log/dm.log"
case "\$1" in
context) echo '{"text": "CTXBLOCK"}' ;;
episode) cat >/dev/null; echo learned ;;
trust)
  if [ "\$2" = check ]; then
    if [ "\$5" = 1 ]; then echo '{"level": "ask", "why": "risky"}'; else echo '{"level": "tell", "why": "default"}'; fi
  else echo '{"level": "ask", "suggestPromote": false}'; fi ;;
journal) printf '%s\n' "\$3" >>"\$log/journal.log"; echo '{"id": "j1"}' ;;
privacy) cat ;;
*) exit 1 ;;
esac
EOF
cat >"$tmp/stub-desktop.py" <<'EOF'
import json, sys
log = sys.argv[1]
obj = lambda **p: {"type": "object", "properties": {k: {"type": v} for k, v in p.items()}}
tools = [{"name": "launch_app", "description": "Start an app", "inputSchema": obj(app="string"),
          "annotations": {"readOnlyHint": False}},
         {"name": "list_windows", "description": "The windows", "inputSchema": obj(),
          "annotations": {"readOnlyHint": True}},
         {"name": "tasks", "description": "The to-do lists: list, add, delete", "inputSchema": obj(action="string", id="string"),
          "annotations": {"readOnlyHint": False, "destructiveHint": True}}]
for line in sys.stdin:
    msg = json.loads(line)
    if "id" not in msg:
        continue
    m, p = msg["method"], msg.get("params") or {}
    if m == "initialize":
        res = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "desktop"}}
    elif m == "tools/list":
        res = {"tools": tools}
    elif m == "tools/call":
        with open(log, "a") as f:
            f.write(json.dumps(p, ensure_ascii=False) + "\n")
        res = {"content": [{"type": "text", "text": f"done: {p['name']}\nFocused: firefox — 'Firefox' (id 3)"}]}
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "no"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": res}), flush=True)
EOF
# The notifications, logged as their arguments (one JSON array a line).
cat >"$tmp/bin/notify-send" <<EOF
#!/usr/bin/env bash
jq -cn '\$ARGS.positional' --args -- "\$@" >>"$tmp/notify.log"
EOF
# notify-send isn't waited for (the Open action keeps it until a click):
# its line, once written.
wait_notify() {
  for _ in $(seq 50); do
    grep -qF -- "$1" "$tmp/notify.log" 2>/dev/null && return 0
    sleep 0.1
  done
}
# The provider: the agent is started without the key (never in a tool's
# environment) and gets it through nixbook-model-provider run.
cat >"$tmp/bin/nixbook-model-provider" <<EOF
#!/usr/bin/env bash
[ "\$1" = run ] && shift
export NIXBOOK_AI_KEY=test-key NIXBOOK_AI_PROVIDED=1 NIXBOOK_AI_BASE_URL="\$(cat "$tmp/base")"
export NIXBOOK_AI_MODEL=main-model NIXBOOK_AI_SMALL_MODEL=small-model NIXBOOK_AI_BIG_MODEL=big-model
exec "\$@"
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

python3 -I "$root/tests/fake-messages.py" "$tmp/port" "$tmp/requests.log" "$tmp/scripts" &
server_pid=$!
for _ in $(seq 50); do
  [ -s "$tmp/port" ] && break
  sleep 0.1
done
echo "http://127.0.0.1:$(cat "$tmp/port")" >"$tmp/base"
unset NIXBOOK_AI_KEY NIXBOOK_AI_BASE_URL NIXBOOK_AI_PROVIDED

script() { printf '%s' "$2" >"$tmp/scripts/$1.json"; }
mt() { python3 -I "$root/scripts/muse-task.py" "$@"; }
field() { mt show "$1" | jq -r "$2"; }
# until ID STATUS: waits (15 s at most) for the task's status.
until_status() {
  for _ in $(seq 150); do
    [ "$(field "$1" .status)" = "$2" ] && return 0
    sleep 0.1
  done
  return 1
}
until_dead() {
  for _ in $(seq 150); do
    [ "$(field "$1" .alive)" = false ] && return 0
    sleep 0.1
  done
  return 1
}
requests() { jq -c --arg t "AGENTTEST:$1" 'select(.path == "/v1/messages" and (.body | tostring | contains($t))) | .body' "$tmp/requests.log"; }
: >"$tmp/requests.log"

# -- A task to its end -----------------------------------------------------------------
script taskdone '{"steps": [[{"type": "tool_use", "id": "l1", "name": "mcp__desktop__launch_app", "input": {"app": "firefox"}}],
  [{"type": "text", "text": "Found it: the cheapest is 12 €."}]],
  "system": {"You check whether": [{"type": "tool_use", "id": "v1", "name": "verification", "input": {"met": true, "note": "seen"}}]}}'
# systemd-run first; it fails here, so the plain process.
cat >"$tmp/bin/systemd-run" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$tmp/systemd-run.log"
exit 1
EOF
chmod +x "$tmp/bin/systemd-run"
out=$(NIXBOOK_MUSE_TASK_SPAWN='' mt start "AGENTTEST:taskdone find the cheapest flight")
id=$(jq -r .id <<<"$out")
expect_contains "start: an id" "$id" ""
if until_status "$id" "done"; then pass "start: the task runs to its end"; else fail "start: the task runs to its end" "$(mt show "$id")"; fi
expect_contains "start: systemd-run tried first, as a transient unit" "$(cat "$tmp/systemd-run.log")" \
  "--user --quiet --collect --unit nixbook-muse-task-$id-1"
rm "$tmp/bin/systemd-run"
expect_eq "state: private" "600" "$(stat -c %a "$tmp/state/nixbook-shell/tasks/$id.json")"
expect_eq "state: the answer" "Found it: the cheapest is 12 €." "$(field "$id" .answer)"
expect_eq "state: its steps" '[{"tool":"launch_app","summary":"app=firefox","status":"ok"}]' "$(field "$id" '[.steps[] | del(.id)] | tojson')"
expect_eq "state: what it did without asking said" '"launch_app@firefox"' "$(field "$id" '.told[0].class | tojson')"
expect_eq "state: the check" "true" "$(field "$id" .verify.met)"
expect_eq "journal: its steps with source task and the task's id" "task $id launch_app@firefox" \
  "$(jq -r '"\(.source) \(.task) \(.class)"' "$tmp/journal.log")"
wait_notify 'Muse is done'
expect_eq "done: a notification with the summary, Open opening the Tasks list" \
  "[\"-a\",\"Muse\",\"-h\",\"string:x-nixbook-task:$id\",\"-A\",\"default=Open\",\"--\",\"Muse is done: AGENTTEST:taskdone find the cheapest flight\",\"Found it: the cheapest is 12 €.\"]" \
  "$(tail -n1 "$tmp/notify.log")"
until_dead "$id" || true
expect_eq "done: the runner gone, its socket too" "false no" \
  "$(field "$id" .alive) $([ -e "$tmp/run/nixbook-shell/tasks/$id.sock" ] && echo yes || echo no)"
first=$(requests taskdone | sed -n 1p)
expect_contains "agent: the task as the first message, the context first" "$(jq -c '.messages[0].content' <<<"$first")" "CTXBLOCK"
expect_contains "agent: told it works in the background" "$(jq -r '.system[0].text' <<<"$first")" "in the background"
expect_eq "agent: the side panel's servers, no commands" '["mcp__desktop__launch_app","mcp__desktop__list_windows","mcp__desktop__tasks","verification"]' \
  "$(jq -c '[.tools[].name]' <<<"$first")"
expect_contains "agent: with the trust ladder and its floor" "$(grep -c 'trust check' "$tmp/dm.log")" "1"

# -- Waiting on an approval, allowed over the socket ----------------------------------------------
script taskapprove '{"steps": [[{"type": "tool_use", "id": "d1", "name": "mcp__desktop__tasks", "input": {"action": "delete", "id": "t1"}}],
  [{"type": "text", "text": "Deleted the old task."}]],
  "system": {"You check whether": [{"type": "tool_use", "id": "v1", "name": "verification", "input": {"met": true, "note": "gone"}}]}}'
: >"$tmp/desk-calls.log"
id=$(mt start "AGENTTEST:taskapprove clean my list" | jq -r .id)
until_status "$id" waiting || fail "approval: waiting" "$(mt show "$id")"
expect_eq "approval: what waits in the state" '{"id":"d1","tool":"tasks","summary":"id=t1, action=delete","class":"tasks:delete"}' \
  "$(field "$id" '.approval | tojson')"
wait_notify 'Muse needs you: tasks (id=t1, action=delete)'
expect_contains "approval: the user notified" "$(tail -n1 "$tmp/notify.log")" "Muse needs you: tasks (id=t1, action=delete)"
expect_eq "approval: the socket only this user's" "600" "$(stat -c %a "$tmp/run/nixbook-shell/tasks/$id.sock")"
expect_eq "approval: nothing run yet" "" "$(cat "$tmp/desk-calls.log")"
expect_eq "approval: the wrong step refused" '{"error":"no such step waits for an answer"}' "$(mt approve "$id" nope yes || true)"
expect_eq "approval: allowed" '{"ok":true}' "$(mt approve "$id" d1 yes)"
until_status "$id" "done" || fail "approval: then done" "$(mt show "$id")"
expect_eq "approval: the step ran" '"tasks" {"action":"delete","id":"t1"}' "$(jq -c '.name, .arguments' "$tmp/desk-calls.log" | paste -sd' ')"
expect_eq "approval: gone from the state" "null" "$(field "$id" .approval)"

# -- Its own question, answered ---------------------------------------------------------------
script taskask '[[{"type": "text", "text": "Which day suits you, Monday or Tuesday?"}], [{"type": "text", "text": "Booked for Monday."}]]'
id=$(mt start "AGENTTEST:taskask book the badminton court" | jq -r .id)
until_status "$id" waiting || fail "question: waiting" "$(mt show "$id")"
expect_eq "question: in the state" "Which day suits you, Monday or Tuesday?" "$(field "$id" .question)"
wait_notify 'Muse needs you: Which day suits you'
expect_contains "question: the user notified" "$(tail -n1 "$tmp/notify.log")" "Muse needs you: Which day suits you"
expect_eq "question: list shows it waiting, with its question" "waiting Which day suits you, Monday or Tuesday?" \
  "$(mt list | jq -r --arg id "$id" '.[] | select(.id == $id) | "\(.status) \(.question)"')"
expect_eq "question: answered" '{"ok":true}' "$(mt answer "$id" "Monday please")"
until_status "$id" "done" || fail "question: then done" "$(mt show "$id")"
expect_eq "question: the answer" "Booked for Monday." "$(field "$id" .answer)"
expect_contains "question: the user's answer reached Muse" "$(requests taskask | tail -n1 | jq -c '.messages[-1].content')" "Monday please"
expect_eq "question: no question left" "null" "$(field "$id" .question)"

# An answer to a task that is over: it goes on in its session.
until_dead "$id" || true
expect_eq "answer: no runner, resumed" '{"ok":true,"resumed":true}' "$(mt answer "$id" "AGENTTEST:taskask and Tuesday too?")"
until_status "$id" "done" || true
for _ in $(seq 50); do
  [ "$(requests taskask | wc -l)" -ge 3 ] && break
  sleep 0.1
done
expect_eq "answer: the whole conversation sent again" '["user","assistant","user","assistant","user"]' \
  "$(requests taskask | tail -n1 | jq -c '[.messages[].role]')"

# -- From a side panel conversation (--from-session) ---------------------------------------------
script taskfork '[[{"type": "text", "text": "We talked about flights."}], [{"type": "text", "text": "Compared them all."}]]'
echo "AGENTTEST:taskfork flights to Lyon" | (cd "$tmp/data" && nixbook-model-provider run python3 -I "$root/scripts/meta-agent.py" -p --session-id panel-chat >/dev/null)
panel="$tmp/state/nixbook-shell/agent-sessions/panel-chat.json"
before=$(jq -c '.messages | length' "$panel")
id=$(mt start "compare them in the background" --from-session panel-chat | jq -r .id)
until_status "$id" "done" || fail "from-session: done" "$(mt show "$id")"
expect_eq "from-session: the conversation so far, then the task" '["user","assistant","user"]' \
  "$(requests taskfork | tail -n1 | jq -c '[.messages[].role]')"
expect_eq "from-session: the panel's conversation left as it was" "$before" "$(jq -c '.messages | length' "$panel")"
expect_eq "from-session: the task's own session" "yes" \
  "$([ -s "$tmp/state/nixbook-shell/agent-sessions/$(field "$id" .sessionId).json" ] && echo yes || echo no)"
until_dead "$id" || true

# -- Stopped ------------------------------------------------------------------------------
: >"$tmp/desk-calls.log"
id=$(mt start "AGENTTEST:taskapprove clean my list" | jq -r .id)
until_status "$id" waiting || fail "stop: waiting first"
expect_eq "stop: asked" '{"ok":true}' "$(mt stop "$id")"
expect_eq "stop: stopped" "stopped" "$(field "$id" .status)"
until_dead "$id" || fail "stop: the runner ends"
expect_eq "stop: nothing run" "" "$(cat "$tmp/desk-calls.log")"
expect_eq "stop: no agent left" "" "$(pgrep -f -- "--task $id" || true)"

# -- Resumed after its runner was killed --------------------------------------------------------
script taskresume '[[{"type": "tool_use", "id": "d1", "name": "mcp__desktop__tasks", "input": {"action": "delete", "id": "t1"}}],
  [{"type": "text", "text": "Done after all."}]]'
id=$(mt start "AGENTTEST:taskresume tidy up" | jq -r .id)
until_status "$id" waiting || fail "resume: waiting first"
sid=$(field "$id" .sessionId)
kill -9 "$(field "$id" .pid)"
until_dead "$id" || fail "resume: the runner dead"
for _ in $(seq 50); do
  [ -s "$tmp/state/nixbook-shell/agent-sessions/$sid.json" ] && break
  sleep 0.1
done
expect_eq "resume: the state still says where it was" "waiting" "$(field "$id" .status)"
expect_eq "resume: the agent saved its session (stopped with its runner)" "yes" \
  "$([ -s "$tmp/state/nixbook-shell/agent-sessions/$sid.json" ] && echo yes || echo no)"
expect_eq "resume: asked" "{\"ok\":true,\"id\":\"$id\"}" "$(mt resume "$id")"
until_status "$id" "done" || fail "resume: then done" "$(mt show "$id")"
last=$(requests taskresume | tail -n1)
expect_contains "resume: its session went on (--resume)" "$(jq -c '.messages[1].content' <<<"$last")" "tool_use"
expect_contains "resume: told to go on" "$(jq -c '.messages[-1].content' <<<"$last")" "interrupted"
expect_eq "resume: the same session" "$sid" "$(field "$id" .sessionId)"
expect_eq "resume: an unknown task" '{"error":"no such task: zzzzzzzz"}' "$(mt resume zzzzzzzz || true)"

# -- The desktop-control pause stops a task ---------------------------------------------------------
touch "$tmp/state/nixbook-shell/desktop-control-allowed"
id=$(mt start "AGENTTEST:taskapprove clean my list" | jq -r .id)
until_status "$id" waiting || fail "pause: waiting first"
rm "$tmp/state/nixbook-shell/desktop-control-allowed"
until_status "$id" stopped || fail "pause: stopped with the agents" "$(mt show "$id")"
expect_eq "pause: why" "desktop control was paused" "$(field "$id" .error)"
until_dead "$id" || true

# -- At most ai.autonomy.maxTasks -------------------------------------------------------------------
echo '{"ai": {"autonomy": {"maxTasks": 1}}}' >"$tmp/cfg/nixbook-shell/config.json"
id=$(mt start "AGENTTEST:taskapprove clean my list" | jq -r .id)
until_status "$id" waiting || fail "max: the first waits"
out=$(mt start "AGENTTEST:taskdone another" || true)
expect_contains "max: a second refused" "$(jq -r .error <<<"$out")" "at most 1"
mt stop "$id" >/dev/null
until_dead "$id" || true
expect_contains "max: room again once it stopped" "$(mt start "AGENTTEST:taskdone another" | jq -r .id)" ""
echo '{"policies": {"ai": 2}}' >"$tmp/cfg/nixbook-shell/config.json"
expect_contains "policies.ai local only: no task" "$(mt start "AGENTTEST:taskdone x" | jq -r .error || true)" "policies.ai"
echo '{"ai": {"autonomy": {"tasks": false}}}' >"$tmp/cfg/nixbook-shell/config.json"
expect_contains "ai.autonomy.tasks off: no task" "$(mt start "AGENTTEST:taskdone x" | jq -r .error || true)" "turned off"
rm "$tmp/cfg/nixbook-shell/config.json"
for t in $(mt list | jq -r '.[] | select(.alive) | .id'); do until_dead "$t" || true; done

# -- Started where the provider's settings are already there (an isolated
# environment whose nixbook-model-provider can't answer): the agent gets them.
mv "$tmp/bin/nixbook-model-provider" "$tmp/provider.ok"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/bin/nixbook-model-provider"
chmod +x "$tmp/bin/nixbook-model-provider"
id=$(NIXBOOK_AI_KEY=test-key NIXBOOK_AI_PROVIDED=1 NIXBOOK_AI_BASE_URL="$(cat "$tmp/base")" NIXBOOK_AI_MODEL=main-model \
NIXBOOK_AI_SMALL_MODEL=small-model mt start "AGENTTEST:taskdone with the provider's settings" | jq -r .id)
if until_status "$id" "done"; then pass "plain spawn: the agent has the runner's provider settings"; else
  fail "plain spawn: the agent has the runner's provider settings" "$(
    mt show "$id"
    cat "$tmp/run/nixbook-shell/tasks/$id.log" 2>/dev/null
  )"
fi
until_dead "$id" || true
# An agent that fails: what it said on stderr in the task's log and error.
cat >"$tmp/bin/broken-agent" <<'EOF'
#!/usr/bin/env bash
echo "nixbook-meta-agent: no model provider with an API key" >&2
exit 1
EOF
chmod +x "$tmp/bin/broken-agent"
id=$(NIXBOOK_META_AGENT="$tmp/bin/broken-agent" mt start "AGENTTEST:taskdone doomed" | jq -r .id)
until_status "$id" failed || fail "a failing agent: failed" "$(mt show "$id")"
expect_eq "a failing agent: its stderr in the task's error" "the agent stopped (exit 1): nixbook-meta-agent: no model provider with an API key" \
  "$(field "$id" .error)"
expect_contains "a failing agent: and in the task's log" "$(cat "$tmp/run/nixbook-shell/tasks/$id.log")" "no model provider with an API key"
until_dead "$id" || true
mv "$tmp/provider.ok" "$tmp/bin/nixbook-model-provider"

# -- list, show, clear -------------------------------------------------------------------
expect_eq "list: every task, newest first" "$(find "$tmp/state/nixbook-shell/tasks" -name '*.json' | wc -l | tr -d ' ')" \
  "$(mt list | jq length)"
expect_contains "show: an unknown task" "$(mt show abcdefabcdef || true)" "no such task"
expect_contains "show: not an id" "$(mt show ../x || true)" "not a task id"
old=$(mt list | jq -r '[.[] | select(.status == "done")][0].id')
f="$tmp/state/nixbook-shell/tasks/$old.json"
jq '.updated = (now - 8 * 86400 | floor)' "$f" >"$f.new" && mv "$f.new" "$f"
before=$(mt list | jq length)
expect_eq "clear: a finished task older than a week removed" '{"removed":1}' "$(mt clear)"
expect_eq "clear: the others kept" "$((before - 1))" "$(mt list | jq length)"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all muse-task tests passed"
