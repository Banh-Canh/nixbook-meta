#!/usr/bin/env bash
# Tests for Quick AI's engine (scripts/quick-ai.py), against a fake
# Anthropic-compatible Messages API (tests/fake-messages.py) and a stub
# nixbook-desktop-mcp (tools, call, privacy mask, sent note):
#   - a streamed answer (deltas, then the whole answer);
#   - suggested replies (JSON → the replies, no raw JSON shown);
#   - a server refusing the effort settings: asked again without them;
#   - the privacy mask: what leaves is masked, the answer unmasked;
#   - doing things: the model's tool calls run through desktop-mcp as
#     steps; a destructive one waits for an OK on stdin, refused → not run;
#   - a missing request, a server error.
# Needs bash, python3 and jq. Run: bash tests/quick-ai.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/quick-ai.py"
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
expect_contains_() {
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "expected to contain: $3"$'\n'"actual: $2" ;; esac
}
expect_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected: $2"$'\n'"actual:   $3"; fi
}

# The stub desktop-mcp: two tools (one destructive), calls logged.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/nixbook-desktop-mcp" <<EOF
#!/usr/bin/env bash
case "\$1" in
tools) cat <<'JSON'
[{"name": "launch_app", "description": "Start an app", "inputSchema": {"type": "object", "properties": {"app": {"type": "string"}, "wait_ms": {"type": "integer"}}},
  "annotations": {"readOnlyHint": false, "destructiveHint": false}, "_meta": {"nixbook/group": "windows"}},
 {"name": "close_window", "description": "Close a window", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}},
  "annotations": {"readOnlyHint": false, "destructiveHint": true}, "_meta": {"nixbook/group": "windows"}},
 {"name": "tasks", "description": "The to-do lists: list, add, done", "inputSchema": {"type": "object", "properties": {"action": {"type": "string"}}},
  "annotations": {"readOnlyHint": false, "destructiveHint": true}, "_meta": {"nixbook/group": "shell"}},
 {"name": "ignored_tool", "description": "Not offered", "inputSchema": {"type": "object"}, "annotations": {}}]
JSON
;;
call) echo "\$2 \$3" >>"$tmp/calls.log"; echo "done: \$2" ;;
privacy)
  if [ "\$2" = mask ]; then sed 's/Julien/⟦Person 1⟧/g'; else sed 's/⟦Person 1⟧/Julien/g'; fi ;;
sent) echo "\$3|\$5" >>"$tmp/sent.log" ;;
instructions) echo "Tools to see and drive the desktop. Notes: QUERY=\$NIXBOOK_DESKTOP_MCP_QUERY" ;;
esac
EOF
chmod +x "$tmp/bin/nixbook-desktop-mcp"
export PATH="$tmp/bin:$PATH"

port_file="$tmp/port"
python3 -I "$root/tests/fake-messages.py" "$port_file" "$tmp/requests.log" &
server_pid=$!
for _ in $(seq 50); do
  [ -s "$port_file" ] && break
  sleep 0.1
done
ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$port_file")"
export ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN=test-key
export ANTHROPIC_MODEL=main-model ANTHROPIC_DEFAULT_HAIKU_MODEL=small-model

ask() { # ask NAME JSON [STDIN] → the events in $tmp/NAME.out
  printf '%s' "$2" >"$tmp/$1.json"
  printf '%s' "${3:-}" | python3 -I "$script" ask "$tmp/$1.json" >"$tmp/$1.out" 2>"$tmp/$1.err" || true
}
event() { jq -c "select(.type == \"$2\")$3" "$tmp/$1.out"; }

# A streamed answer.
ask explain '{"mode": "explain", "text": "error: foo", "lang": "en"}'
expect_eq "stream: deltas" '"Hello "
"world"' "$(event explain delta .text)"
expect_eq "stream: the whole answer" '"Hello world"' "$(event explain answer .text)"
expect_eq "stream: the small model" '"small-model"' "$(event explain start .model)"
expect_eq "stream: the effort settings sent" '"low"' "$(jq -c 'select(.body.stream == true) | .body.output_config.effort' "$tmp/requests.log" | head -n1)"
expect_eq "stream: recorded as sent" "Quick AI: explain|api:small-model" "$(head -n1 "$tmp/sent.log")"

# The OpenAI-style chat endpoint, when the server has it: tried first.
ask chat '{"mode": "explain", "text": "CHATOK this", "lang": "en"}'
expect_eq "chat: answered through /v1/chat/completions" '"Fast answer"' "$(event chat answer .text)"
expect_eq "chat: minimal reasoning" '"minimal"' "$(jq -c 'select(.body.reasoning_effort) | .body.reasoning_effort' "$tmp/requests.log" | tail -n1)"

# Replies.
ask reply '{"mode": "reply", "text": "tu viens ce soir ?", "lang": "fr"}'
expect_eq "reply: the suggestions" '["Oui !","Pas ce soir","À quelle heure ?"]' "$(event reply replies .replies)"
expect_eq "reply: no raw JSON as the answer" '""' "$(event reply answer .text)"
expect_eq "reply: no deltas" "" "$(event reply delta .text)"

# A server without the effort settings.
ask noeffort '{"mode": "summarize", "text": "NOEFFORT long text", "lang": "en"}'
expect_eq "no effort: answered on the second try" '"Hello world"' "$(event noeffort answer .text)"
expect_eq "no effort: asked again without them" "null" "$(jq -c 'select(.body.reasoning_effort == null and (.body.messages | tostring | contains("NOEFFORT"))) | .body.output_config' "$tmp/requests.log" | tail -n1)"

# The privacy mask.
ask private '{"mode": "explain", "text": "PRIVATE Julien wrote this", "lang": "en"}'
if grep -q 'Julien wrote' "$tmp/requests.log"; then fail "privacy: the name left unmasked"; else pass "privacy: the name masked on the way"; fi
expect_eq "privacy: the answer unmasked" '"Ask Julien"' "$(event private answer .text)"

# Doing things: a step, then the answer.
ask act '{"mode": "do", "question": "open firefox", "lang": "en"}'
expect_eq "do: the step ran" '"run"
"ok"' "$(event act step .status)"
expect_eq "do: through desktop-mcp" 'launch_app {"app": "firefox"}' "$(head -n1 "$tmp/calls.log")"
expect_eq "do: the answer, the report under it" '"Firefox is open.\n- ✓ launch app (app=firefox)"' "$(event act answer .text)"
expect_eq "do: only the offered tools, without desktop-mcp's extras" '["launch_app","close_window","tasks"]
[]' "$(jq -c 'select(.body.tools) | [.body.tools[].name], [.body.tools[0].input_schema.properties | keys[] | select(. == "wait_ms")]' "$tmp/requests.log" | head -n2)"

# The report after acting: built from the steps when the model gives none,
# the model's own otherwise; none for a plain answer.
expect_eq "report: from the steps" '["launch app (app=firefox)"]' "$(event act report .done)"
expect_eq "report: the steps counted" '1 1 0' "$(event act report ' | "\(.steps) \(.ok) \(.ko)"' | tr -d '"')"
expect_contains_ "report: in the answer too" "$(event act answer .text)" "✓ launch app"
ask reported '{"mode": "do", "question": "REPORTME open firefox", "lang": "en"}'
expect_eq "report: the model's summary" '"Firefox is ready"' "$(event reported report .summary)"
expect_eq "report: what needs the user" '["Sign in to your account"]' "$(event reported report .needsYou)"
expect_eq "report: no report tag left in the answer" "" "$(event reported answer .text | grep -o '<report>')"
expect_eq "report: none for a plain answer" "" "$(event explain report .summary)"

# What the desktop knows goes along (answered without a tool).
ask facts '{"mode": "do", "question": "FACTS what is the weather?", "lang": "en", "facts": "Weather in Paris: rain, 11°C"}'
expect_contains_ "facts: sent with the question" "$(grep FACTS "$tmp/requests.log" | tail -n1)" "Weather in Paris: rain"
# Out of steps: an answer all the same, without tools.
ask loop '{"mode": "do", "question": "LOOP forever", "lang": "en"}'
expect_contains_ "out of steps: an answer all the same" "$(event loop answer .text)" "Concluded without more tools."
expect_eq "out of steps: asked without tools" '{"type":"none"}' "$(jq -c 'select(.body.tool_choice) | .body.tool_choice' "$tmp/requests.log" | tail -n1)"

expect_contains_ "do: the tools' own instructions, for this task" "$(jq -c 'select(.body.tools) | .body.system' "$tmp/requests.log" | head -n1)" "QUERY=open firefox"
# A tool that also writes, asked only to read (its action): no OK needed,
# even when every action is asked about; and no report for it.
: >"$tmp/calls.log"
ask reads '{"mode": "do", "question": "TASKS what is on my list?", "lang": "en", "confirm": "actions"}'
expect_eq "read actions: not asked" "" "$(event reads approve .tool)"
expect_eq "read actions: run" 'tasks {"action": "list"}' "$(cat "$tmp/calls.log")"
expect_eq "read actions: no report" "" "$(event reads report .summary)"

# A destructive step: asked, refused, not run.
: >"$tmp/calls.log"
ask deny '{"mode": "do", "question": "CLOSE the window", "lang": "en"}' $'no\n'
expect_eq "deny: asked first" '"close_window"' "$(event deny approve .tool)"
expect_eq "deny: not run" '"denied"' "$(event deny step .status)"
expect_eq "deny: nothing called" "" "$(cat "$tmp/calls.log")"
expect_eq "deny: reported as failed" '["close window (id=7): you said no"]' "$(event deny report .failed)"
: >"$tmp/calls.log"
ask allow '{"mode": "do", "question": "CLOSE the window", "lang": "en"}' $'yes\n'
expect_eq "allow: run once allowed" 'close_window {"id": 7}' "$(cat "$tmp/calls.log")"
: >"$tmp/calls.log"
ask never '{"mode": "do", "question": "CLOSE the window", "lang": "en", "confirm": "never"}'
expect_eq "confirm never: not asked" "" "$(event never approve .tool)"

# Full AI mode's reactions: ask by default, act alone only when told or
# after the user agreed twice; their answers kept and given back.
export XDG_STATE_HOME="$tmp/state"
ask react1 '{"mode": "react", "event": {"event": "notification", "app": "Chat", "title": "Ana", "text": "dinner?"}}'
expect_eq "react: asks by default" '"ask"' "$(event react1 react .action)"
ask react2 '{"mode": "react", "event": {"event": "notification", "app": "Chat", "title": "Bo", "text": "TOLDIT ping"}}'
expect_eq "react: does what it was told" '"do"' "$(event react2 react .action)"
ask react3 '{"mode": "react", "event": {"event": "notification", "app": "Mail", "title": "x", "text": "GUESSDO spam"}}'
expect_eq "react: never acts on a guess" '"ask"' "$(event react3 react .action)"
ev='{"mode": "react", "event": {"event": "notification", "app": "Chat", "title": "Ana", "text": "LEARNED dinner?"}}'
ask react4 "$ev"
expect_eq "react: learned, but not agreed twice yet: asks" '"ask"' "$(event react4 react .action)"
for i in 1 2; do python3 -I "$script" learn '{"event": {"event": "notification", "app": "Chat", "title": "Ana"}, "decision": "ask", "outcome": "agreed", "said": "yes"}'; done
ask react5 "$ev"
expect_eq "react: agreed twice: acts alone" '"do"' "$(event react5 react .action)"
expect_contains_ "react: the past answers go along" "$(grep LEARNED "$tmp/requests.log" | tail -n1)" "the user agreed: yes"
expect_eq "react: what it learned is said" '"answer yes to Ana"' "$(event react5 react .learn)"
python3 -I "$script" learn '{"pref": "Ana is my sister"}'
expect_eq "learn: a preference kept" '"Ana is my sister"' "$(python3 -I "$script" learned | jq -c '.prefs[-1].text')"
python3 -I "$script" learn '{"forget": true}'
expect_eq "learn: forgotten" '{}' "$(python3 -I "$script" learned)"
unset XDG_STATE_HOME

# Failures.
python3 -I "$script" ask "$tmp/none.json" >"$tmp/none.out" 2>/dev/null || true
expect_eq "no request: an error" '"error"' "$(jq -c '.type' "$tmp/none.out" | head -n1)"
ask broken '{"mode": "explain", "text": "FAIL500", "lang": "en"}'
case "$(event broken error .error)" in
*"HTTP 500"*) pass "server error: shown" ;;
*) fail "server error: shown" "$(cat "$tmp/broken.out")" ;;
esac

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all quick-ai tests passed"
