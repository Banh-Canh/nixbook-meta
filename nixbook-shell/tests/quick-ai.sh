#!/usr/bin/env bash
# Tests for Quick AI's engine (scripts/quick-ai.py), against a fake
# Messages API (tests/fake-messages.py) and a stub
# nixbook-desktop-mcp (privacy mask, sent note, the context broker, prefs):
#   - a streamed answer (deltas, then the whole answer), the broker's
#     context in the prompt;
#   - suggested replies (JSON → the replies, no raw JSON shown);
#   - a server refusing the effort settings: asked again without them;
#   - the privacy mask: what leaves is masked, the answer unmasked;
#   - doing things: handed to nixbook-meta-agent (a stub: its command line);
#   - Full AI's reactions: the decisions model, the broker, prefs in the
#     one memory (`prefs add`);
#   - Kiroshi's scan: the broker asked for the scan surface; its offers
#     checked (allow-listed tools, their arguments, one-click work dropped),
#     the facts, the ranking, the offers taken before in the prompt;
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

# The stub desktop-mcp: the privacy mask, the sent log, the context broker
# (its arguments in its text), prefs; calls logged.
mkdir -p "$tmp/bin" "$tmp/run" "$tmp/cfg/nixbook-shell"
# Never the user's own desktop-mcp helper (its socket) nor settings.
export XDG_RUNTIME_DIR="$tmp/run" XDG_CONFIG_HOME="$tmp/cfg" XDG_CACHE_HOME="$tmp/cache" NIXBOOK_AI_RETRY_DELAY=0.05
cat >"$tmp/bin/nixbook-desktop-mcp" <<EOF
#!/usr/bin/env bash
case "\$1" in
call) echo "\$2 \$3" >>"$tmp/calls.log"; echo "done: \$2" ;;
privacy)
  if [ "\$2" = mask ]; then sed 's/Julien/⟦Person 1⟧/g'; else sed 's/⟦Person 1⟧/Julien/g'; fi ;;
sent) echo "\$3|\$5" >>"$tmp/sent.log" ;;
context)
  [ "\$2" = build ] || exit 1
  shift 2
  s="" q="" na=no a=""
  while [ \$# -gt 0 ]; do
    case "\$1" in --for) s=\$2; shift ;; --query) q=\$2; shift ;; --app) a=\$2; shift ;; --no-activity) na=yes ;; esac
    shift
  done
  echo "\$s|\$q|\$a|\$na" >>"$tmp/broker.log"
  [ -e "$tmp/broker-off" ] && exit 1
  jq -cn --arg t "BROKER for=\$s noact=\$na query=\$q Julien" '{sections: [{name: "facts", text: \$t}], text: \$t}' ;;
prefs) echo "\$2 \$3" >>"$tmp/prefs.log"; [ -e "$tmp/prefs-off" ] && exit 1; echo '{"ok": true}' ;;
tools) [ -e "$tmp/tools.json" ] && cat "$tmp/tools.json" ;;
feedback) echo "\$*" >>"$tmp/feedback.log"; [ -e "$tmp/feedback.json" ] && cat "$tmp/feedback.json" ;;
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
NIXBOOK_AI_BASE_URL="http://127.0.0.1:$(cat "$port_file")"
export NIXBOOK_AI_BASE_URL NIXBOOK_AI_KEY=test-key
export NIXBOOK_AI_MODEL=main-model NIXBOOK_AI_SMALL_MODEL=small-model

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
expect_eq "stream: the effort settings sent, minimal (ai.routing.effortMinimal)" '"minimal"' "$(jq -c 'select(.body.stream == true) | .body.output_config.effort' "$tmp/requests.log" | head -n1)"
caps="$tmp/cache/nixbook-shell/provider-caps.json"
expect_eq "caps: the missing fast endpoint remembered (base URL + model)" "false" \
  "$(jq -c --arg k "$NIXBOOK_AI_BASE_URL|small-model" '.[$k].fast' "$caps")"
ask explain2 '{"mode": "explain", "text": "error: bar", "lang": "en"}'
expect_eq "caps: the next one-shot doesn't probe it again" '"/v1/messages"' \
  "$(jq -c 'select(.body | tostring | contains("error: bar")) | .path' "$tmp/requests.log" | sort -u | paste -sd' ')"
echo '{"ai": {"routing": {"effortMinimal": false}}}' >"$tmp/cfg/nixbook-shell/config.json"
ask explain3 '{"mode": "explain", "text": "error: baz", "lang": "en"}'
expect_eq "effortMinimal off: the request's own effort" '"low"' \
  "$(jq -c 'select(.body.stream == true and (.body | tostring | contains("error: baz"))) | .body.output_config.effort' "$tmp/requests.log" | head -n1)"
rm "$tmp/cfg/nixbook-shell/config.json"
expect_eq "stream: recorded as sent" "Quick AI: explain|custom:small-model" "$(head -n1 "$tmp/sent.log")"

# The OpenAI-style chat endpoint, when the server has it: tried first (a
# server the cache doesn't know).
rm -f "$caps"
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

# The broker's context goes along (masked like the rest), not for an image's
# text copied out; the text's rewrites without what the user just did.
expect_contains_ "broker: asked for the text surface" "$(head -n1 "$tmp/broker.log")" "text|error: foo||no"
expect_contains_ "broker: its text in the prompt" "$(grep -F 'error: foo' "$tmp/requests.log" | head -n1)" "BROKER for=text"
expect_contains_ "broker: masked on the way" "$(grep -F 'BROKER for=text' "$tmp/requests.log" | head -n1)" "⟦Person 1⟧"
: >"$tmp/broker.log"
ask fixit '{"mode": "fix", "text": "teh text", "lang": "en"}'
expect_eq "broker: a rewrite without the activity" "text|teh text||yes" "$(cat "$tmp/broker.log")"
: >"$tmp/broker.log"
# A PNG's header (64x32): what image_size reads.
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x40\x00\x00\x00\x20\x08\x02\x00\x00\x00' >"$tmp/region.png"
ask extract "{\"mode\": \"extract\", \"image\": \"$tmp/region.png\", \"lang\": \"en\"}"
expect_eq "broker: not for a text copied out of an image" "" "$(cat "$tmp/broker.log")"
touch "$tmp/broker-off"
ask nobroker '{"mode": "ask", "question": "NOBROKER what time is it?", "facts": "Time: 10:42", "lang": "en"}'
expect_contains_ "broker: without it, the request's own facts" "$(grep NOBROKER "$tmp/requests.log" | tail -n1)" "Time: 10:42"
rm "$tmp/broker-off"

# Doing things: nixbook-meta-agent's now (the shell's only agent loop), the
# request handed over as Quick AI's own loop ran it.
cat >"$tmp/bin/nixbook-meta-agent" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$tmp/ma-args"
echo '{"type": "result", "result": "from the agent"}'
EOF
chmod +x "$tmp/bin/nixbook-meta-agent"
ask act '{"mode": "do", "question": "open firefox", "lang": "en", "confirm": "actions", "panel": "PANELBRAIN"}'
expect_eq "do: the agent's own events" '"from the agent"' "$(jq -c 'select(.type == "result") | .result' "$tmp/act.out")"
args=$(paste -sd' ' "$tmp/ma-args")
expect_contains_ "do: the bubble's context, the user's confirm setting" "$args" "--context-for bubble --confirm actions --report --lazy-mcp 12 --learn"
expect_contains_ "do: the desktop's tools" "$args" '--mcp-config {"mcpServers": {"desktop": {"command": "nixbook-desktop-mcp"'
expect_contains_ "do: the request read first and checked after (ai.agent defaults)" "$args" "--resolve --verify"
expect_contains_ "do: the quick model (ai.routing.quick)" "$args" "--model small"
expect_contains_ "do: the side panel's knowledge" "$args" "--append-system-prompt PANELBRAIN"
expect_contains_ "do: the bubble's budget, the core tools up front" "$args" "--max-tokens 1200 --tool-result-max 6000 --core-tools"
expect_eq "do: the request last, after --" "-- open firefox" "$(tail -n2 "$tmp/ma-args" | paste -sd' ')"
mkdir -p "$tmp/cfg/nixbook-shell"
echo '{"ai": {"agent": {"verify": false}, "routing": {"quick": "main"}}}' >"$tmp/cfg/nixbook-shell/config.json"
ask act2 '{"mode": "do", "question": "open firefox", "lang": "en"}'
args=$(paste -sd' ' "$tmp/ma-args")
expect_contains_ "do: risky steps only by default, the settings followed" "$args" "--confirm destructive"
expect_eq "do: no verification when it is off" "" "$(grep -x -- --verify "$tmp/ma-args" || true)"
expect_contains_ "do: the routing's quick model" "$args" "--model main"
rm -f "$tmp/cfg/nixbook-shell/config.json" "$tmp/bin/nixbook-meta-agent"

# The provider's key never reaches the tools (nixbook_ai's child_env).
expect_eq "child env: no NIXBOOK_AI_ variable for the tools" "" \
  "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import nixbook_ai; print(" ".join(k for k in nixbook_ai.child_env() if k.startswith("NIXBOOK_AI_")))' "$root/scripts")"
# No key: through the provider (a stub that sets it).
cat >"$tmp/bin/nixbook-model-provider" <<EOF
#!/usr/bin/env bash
[ "\$1" = run ] && shift
export NIXBOOK_AI_KEY=test-key NIXBOOK_AI_PROVIDED=1 NIXBOOK_AI_LABEL=Meta
exec "\$@"
EOF
chmod +x "$tmp/bin/nixbook-model-provider"
printf '%s' '{"mode": "explain", "text": "error: foo", "lang": "en"}' >"$tmp/viaprov.json"
NIXBOOK_AI_KEY='' python3 -I "$script" ask "$tmp/viaprov.json" >"$tmp/viaprov.out" 2>"$tmp/viaprov.err" || true
expect_eq "no key: run through nixbook-model-provider" '"Hello world" "Meta"' \
  "$(event viaprov answer .text) $(event viaprov start .provider)"
rm "$tmp/bin/nixbook-model-provider"

# What is risky (nixbook_ai, the agent's --confirm): Quick AI's rules.
risky() { python3 -I -c 'import json,sys; sys.path.insert(0, sys.argv[1]); import nixbook_ai; print(nixbook_ai.is_risky(sys.argv[2], json.loads(sys.argv[3]), {}))' "$root/scripts" "$1" "$2"; }
expect_eq "risky: a browser click on Send" True "$(risky browser_act '{"ref": 1, "name": "Send", "action": "click"}')"
expect_eq "risky: a browser form placing an order" True "$(risky browser_act '{"ref": 4, "name": "Place order", "action": "submit"}')"
expect_eq "risky: a browser click elsewhere isn't" False "$(risky browser_act '{"ref": 2, "name": "Liked Music", "action": "click"}')"
expect_eq "risky: typing in a page isn't" False "$(risky browser_act '{"ref": 3, "name": "Message", "action": "type", "value": "send it"}')"
expect_eq "risky: deleting a task, by its MCP name" True "$(risky mcp__desktop__tasks '{"action": "delete"}')"
expect_eq "risky: closing a window isn't" False "$(risky mcp__desktop__close_window '{"id": 7}')"

# Kiroshi's scan: the broker asked for the scan surface (the answer here has
# no labels: the fake knows nothing of scans).
: >"$tmp/broker.log"
ask scan "{\"mode\": \"scan\", \"image\": \"$tmp/region.png\", \"context\": {\"app\": \"firefox\", \"title\": \"Inbox\"}, \"lang\": \"en\"}"
expect_eq "scan: the broker, for the scan surface" "scan|Inbox|firefox|no" "$(grep '^scan' "$tmp/broker.log")"
expect_contains_ "scan: its context in the prompt" "$(grep -F 'Label the 3' "$tmp/requests.log" | tail -n1)" "BROKER for=scan"

# The scan's offers (the fake's KIROSHITEST answers): only what saves real
# effort, checked against the allow-list and the tools' schemas (desktop-mcp
# has calendar, tasks and the notification tools on; the notes widget's
# group off), the offers this user took before in the prompt, the items
# ranked by value × urgency.
cat >"$tmp/tools.json" <<'JSON'
[{"name": "calendar", "inputSchema": {"type": "object", "additionalProperties": false, "required": ["action"],
  "properties": {"action": {"type": "string", "enum": ["next", "create", "delete"]}, "summary": {"type": "string"},
  "start": {"type": "string"}, "end": {"type": "string"}, "location": {"type": ["string", "null"]}}}},
 {"name": "tasks", "inputSchema": {"type": "object", "additionalProperties": false, "required": ["action"],
  "properties": {"action": {"type": "string"}, "title": {"type": "string"}, "due": {"type": ["string", "null"]},
  "task": {"type": "string"}, "notes": {"type": "string"}}}},
 {"name": "notification_action", "inputSchema": {"type": "object", "additionalProperties": false, "required": ["id"],
  "properties": {"id": {"type": "integer"}, "action": {"type": "string"}, "reply": {"type": "string"}}}},
 {"name": "dismiss_notifications", "inputSchema": {"type": "object", "additionalProperties": false,
  "properties": {"ids": {"type": "array", "items": {"type": "integer"}}, "app": {"type": "string"}}}},
 {"name": "launch_app", "inputSchema": {"type": "object", "required": ["app"], "properties": {"app": {"type": "string"}}}}]
JSON
cat >"$tmp/feedback.json" <<'JSON'
[{"verdict": "up", "surface": "kiroshi", "request": "Invoice: due Friday", "answer": "File a task due Friday"},
 {"verdict": "up", "surface": "chat", "request": "open firefox", "answer": "CHATANSWER"},
 {"verdict": "down", "surface": "kiroshi", "request": "x", "answer": "NOTTAKEN"}]
JSON
: >"$tmp/requests.log"
: >"$tmp/feedback.log"
ask kiroshi "{\"mode\": \"scan\", \"image\": \"$tmp/region.png\", \"lang\": \"en\",
  \"context\": {\"app\": \"signal\", \"title\": \"KIROSHITEST Ana\"},
  \"notifications\": [{\"id\": 42, \"time\": \"10:01\", \"app\": \"Signal\", \"summary\": \"Ana\", \"body\": \"dinner friday 19:30?\", \"canReply\": true, \"actions\": [\"Reply\"]},
    {\"id\": 7, \"app\": \"Updates\", \"summary\": \"Firefox updated\"}, {\"id\": 8, \"app\": \"Updates\", \"summary\": \"Kitty updated\"}]}"
item() { jq -c "select(.type == \"item\" and .index == $1)$2" "$tmp/kiroshi.out"; }
expect_eq "kiroshi: the labels" 4 "$(event kiroshi scan '.items | length')"
expect_eq "kiroshi: one-click offers dropped (keep the music rolling, a tool not allowed)" "[]" "$(item 0 .options)"
expect_eq "kiroshi: the best option first, unknown notification / missing date / extra argument dropped" \
  '["Reply yes to Ana","Add the dinner to the calendar"]' "$(item 1 '.options | map(.title)')"
expect_eq "kiroshi: a reply needs the user's OK, its text is the draft" '[true,"Oui, 19h30 c'"'"'est parfait !","reply"]' \
  "$(item 1 '.options[0] | [.confirm, .draft, .draftKey]')"
expect_eq "kiroshi: a quick option is one checked tool call" '"calendar" {"action":"create","summary":"Dinner with Ana","start":"2026-10-30T19:30"} false "~1 min · 6 clicks"' \
  "$(item 1 '.options[1] | "\(.tool | tojson) \(.args | tojson) \(.confirm) \(.saves | tojson)"' | jq -r .)"
expect_eq "kiroshi: the facts, why and next" '["Ana asks if dinner Friday at 19:30 works","Sent 5 min ago on Signal"] "She is waiting for an answer." "Answer her on Signal."' \
  "$(item 1 '| "\(.facts | tojson) \(.why | tojson) \(.next | tojson)"' | jq -r .)"
expect_eq "kiroshi: the detail text joined from them (older shells)" '"• Ana asks if dinner Friday at 19:30 works\n• Sent 5 min ago on Signal\nShe is waiting for an answer.\nAnswer her on Signal."' "$(item 1 .detail)"
expect_eq "kiroshi: no agent option, no handle" "null" "$(item 1 .handle)"
expect_eq "kiroshi: bad due date, a fixed action changed, a switched-off tool: dropped" '["Fix the hash and rebuild"]' "$(item 2 '.options | map(.title)')"
expect_eq "kiroshi: the handle = the best agent option (older shells)" '"Fix the hash and rebuild" 3 ""' \
  "$(item 2 '| "\(.handle.title | tojson) \(.handle.plan | length) \(.handle.draft | tojson)"' | jq -r .)"
expect_eq "kiroshi: one toast dismissed is no offer, two at once is" '["Clear both update notices"]' "$(item 3 '.options | map(.title)')"
expect_eq "kiroshi: ranked by value × urgency, the noise without offers last" "[1,2,3,0]" "$(event kiroshi ranked .order)"
expect_eq "kiroshi: routine = judged routine and worth it without an OK" "[1,3]" "$(event kiroshi ranked .routine)"
prompt=$(grep -F 'Now only item 1' "$tmp/requests.log" | head -n1)
expect_contains_ "kiroshi: the offers this user takes in the prompt" "$prompt" 'Offers this user takes (prefer those kinds when they fit):\n- File a task due Friday (for: Invoice: due Friday)'
case "$prompt" in *CHATANSWER* | *NOTTAKEN*) fail "kiroshi: only the kiroshi offers taken" ;; *) pass "kiroshi: only the kiroshi offers taken" ;; esac
expect_contains_ "kiroshi: the quick tools offered are the enabled ones" "$prompt" "  - dismiss_notifications"
case "$prompt" in *"- widget {"*) fail "kiroshi: a switched-off tool not offered" ;; *) pass "kiroshi: a switched-off tool not offered" ;; esac
expect_contains_ "kiroshi: notifications with their ids" "$prompt" "- #42 [10:01] Signal · Ana: dinner friday 19:30? (buttons: Reply; can reply)"
expect_contains_ "kiroshi: the trivial offers named as forbidden" "$prompt" "NEVER offer: opening, focusing"
expect_eq "kiroshi: the feedback asked once" "feedback list 50" "$(cat "$tmp/feedback.log")"
# Without desktop-mcp's tool list, the allow-list's own rules still apply.
kpy() { python3 -I -c 'import importlib.util,json,sys; s=importlib.util.spec_from_file_location("qa",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(json.dumps(eval(sys.argv[2]), ensure_ascii=False))' "$script" "$1"; }
expect_eq "kiroshi: no schema, the rules: a task needs its title" "[]" \
  "$(kpy 'm.scan_options([{"title": "File it", "kind": "quick", "value": 2, "tool": "tasks", "args": {"action": "create"}}])')"
expect_eq "kiroshi: no schema, the notes widget allowed, its text the draft" '[["widget", "text", false]]' \
  "$(kpy '[[o["tool"], o["draftKey"], o["confirm"]] for o in m.scan_options([{"title": "Save the action items", "kind": "quick", "value": 2, "tool": "widget", "args": {"widget": "notes", "text": "- call Bo"}}])]')"
expect_eq "kiroshi: a page opened to look nothing up is no offer" "[]" \
  "$(kpy 'm.scan_options([{"title": "Open AI book repo", "kind": "quick", "value": 2, "tool": "browser_open", "args": {"url": "https://github.com/x/ai-book"}}, {"title": "Look up the fix", "kind": "quick", "value": 1, "tool": "browser_open", "args": {"url": "https://nixos.wiki/x"}}])')"
expect_eq "kiroshi: an agent option needs a plan or a draft" "[]" \
  "$(kpy 'm.scan_options([{"title": "Summarize the post", "kind": "agent", "value": 2, "plan": ["Read it"], "instruction": "Summarize the post"}])')"
expect_eq "kiroshi: an older answer's handle is an agent option" '["Reply to Bo", "Reply to Bo"]' \
  "$(kpy '(lambda d: [d["options"][0]["title"], d["handle"]["title"]])(m.scan_item({"detail": "Bo asks", "handle": {"title": "Reply to Bo", "plan": ["Open Signal", "Send it"], "draft": "Yes", "instruction": "Reply yes to Bo in Signal"}}))')"
rm "$tmp/tools.json" "$tmp/feedback.json"

# Full AI mode's reactions: ask by default, act alone only when told or
# after the user agreed twice; their answers kept and given back.
export XDG_STATE_HOME="$tmp/state" NIXBOOK_AI_BIG_MODEL=big-model
: >"$tmp/requests.log"
: >"$tmp/broker.log"
ask react1 '{"mode": "react", "event": {"event": "notification", "app": "Chat", "title": "Ana", "text": "dinner?"}}'
expect_eq "react: asks by default" '"ask"' "$(event react1 react .action)"
expect_eq "react: the decisions model (ai.routing: big), minimal reasoning on the fast endpoint" '"big-model" "minimal" "/v1/chat/completions"' \
  "$(jq -c 'select(.body.messages | tostring | contains("dinner?")) | "\(.body.model | tojson) \(.body.reasoning_effort | tojson) \(.path | tojson)"' -r "$tmp/requests.log" | head -n1)"
expect_eq "react: the broker for the event" "react|Chat Ana dinner?|Chat|no" "$(head -n1 "$tmp/broker.log")"
expect_contains_ "react: its context sent" "$(grep -F 'dinner?' "$tmp/requests.log" | head -n1)" "BROKER for=react"
ask react2 '{"mode": "react", "event": {"event": "notification", "app": "Chat", "title": "Bo", "text": "TOLDIT ping"}}'
expect_eq "react: does what it was told" '"do"' "$(event react2 react .action)"
ask react3 '{"mode": "react", "event": {"event": "notification", "app": "Mail", "title": "x", "text": "GUESSDO spam"}}'
expect_eq "react: never acts on a guess" '"ask"' "$(event react3 react .action)"
ev='{"mode": "react", "event": {"event": "notification", "app": "Chat", "title": "Ana", "text": "LEARNED dinner?"}}'
ask react4 "$ev"
expect_eq "react: learned, but not agreed twice yet: asks" '"ask"' "$(event react4 react .action)"
for _ in 1 2; do python3 -I "$script" learn '{"event": {"event": "notification", "app": "Chat", "title": "Ana"}, "decision": "ask", "outcome": "agreed", "said": "yes"}'; done
ask react5 "$ev"
expect_eq "react: agreed twice: acts alone" '"do"' "$(event react5 react .action)"
expect_contains_ "react: the past answers go along" "$(grep LEARNED "$tmp/requests.log" | tail -n1)" "the user agreed: yes"
expect_eq "react: what it learned is said" '"answer yes to Ana"' "$(event react5 react .learn)"
python3 -I "$script" learn '{"pref": "Ana is my sister", "app": "Chat", "sig": "notification|chat|ana"}'
expect_eq "learn: a preference into the one memory (prefs add)" \
  'add {"text": "Ana is my sister", "source": "fullai", "app": "Chat", "signature": "notification|chat|ana"}' "$(tail -n1 "$tmp/prefs.log")"
expect_eq "learn: not kept here too" "null" "$(python3 -I "$script" learned | jq -c '.prefs')"
touch "$tmp/prefs-off"
python3 -I "$script" learn '{"pref": "Bo is my brother"}'
expect_eq "learn: kept here when desktop-mcp can't" '"Bo is my brother"' "$(python3 -I "$script" learned | jq -c '.prefs[-1].text')"
rm "$tmp/prefs-off"
python3 -I "$script" learn '{"forget": true}'
expect_eq "learn: forgotten" '{}' "$(python3 -I "$script" learned)"
unset XDG_STATE_HOME NIXBOOK_AI_BIG_MODEL

# The answers read out (scripts/voice-speak.py): the text made speakable,
# the language, and the cute chain run with stub tools (no model).
speak="$root/scripts/voice-speak.py"
vs() { python3 -I -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("vs",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(eval(sys.argv[2]))' "$speak" "$1"; }
expect_eq "speak: English picked" en "$(vs 'm.language("Firefox is open on workspace 3.")')"
expect_eq "speak: French picked" fr "$(vs 'm.language("Julien demande si tu viens ce soir.")')"
expect_eq "speak: numbers and units spelled out" "It's twenty-one degrees, battery at eighty-five percent." \
  "$(vs 'm.speakable("It'"'"'s **21°C**, battery at 85%. 🔋", "en")')"
expect_eq "speak: clock times" "Meeting at nine oh five, then fourteen thirty." "$(vs 'm.speakable("Meeting at 9:05, then 14:30.", "en")')"
expect_eq "speak: French times and numbers" "Réunion à quatorze heures trente avec soixante et onze personnes, à une heure." \
  "$(vs 'm.speakable("Réunion à 14h30 avec 71 personnes, à 1h.", "fr")')"
# shellcheck disable=SC2016 # Markdown backticks, not an expansion
expect_eq "speak: code, links and lists out" "Done: see here.
Firefox" \
  "$(vs 'm.speakable("Done: see [here](https://x.y).\n```\nrm -rf\n```\n- Firefox", "en")')"
expect_eq "speak: short pieces joined" "['Done! Firefox is open.', 'Anything else?']" "$(vs 'm.sentences("Done! Firefox is open. Anything else?")')"
mkdir -p "$tmp/voices/en" "$tmp/voices/fr" "$tmp/sbin"
touch "$tmp/voices/en/model.onnx" "$tmp/voices/fr/model.onnx"
cat >"$tmp/sbin/sherpa-onnx-offline-tts" <<EOF
#!/usr/bin/env bash
for a; do case "\$a" in --vits-model=*) m="\${a#*=}" ;; --output-filename=*) o="\${a#*=}" ;; esac; done
case "\$1" in --*) ;; *) echo "not an option first: \$1" >&2; exit 255 ;; esac
case "\${@: -1}" in -*) echo "unknown option \${@: -1}" >&2; exit 255 ;; *FAIL*) echo "it broke" >&2; exit 3 ;; esac
echo "tts \$(basename "\$(dirname "\$m")") \${@: -1}" >>"$tmp/speak.log"; echo raw >"\$o"
EOF
cat >"$tmp/sbin/ffmpeg" <<EOF
#!/usr/bin/env bash
echo "ffmpeg \$*" >>"$tmp/speak.log"; cp "\$5" "\${@: -1}" 2>/dev/null || echo joined >"\${@: -1}"
EOF
cat >"$tmp/sbin/rubberband-r3" <<EOF
#!/usr/bin/env bash
echo "rubberband \$*" >>"$tmp/speak.log"; cp "\${@: -2:1}" "\${@: -1}"
EOF
cat >"$tmp/sbin/pw-play" <<EOF
#!/usr/bin/env bash
echo "play \$(basename "\${@: -1}")" >>"$tmp/speak.log"
EOF
chmod +x "$tmp/sbin/"*
sp() { PATH="$tmp/sbin:$PATH" NIXBOOK_MMS_VOICES="$tmp/voices" python3 -I "$speak" "$@"; }
# As the shell calls it (Voice.qml: --style STYLE -- TEXT).
sp --style cute -- "Firefox is open on workspace three. Anything else for you?"
expect_eq "speak: English voice, sentence by sentence" "tts en Firefox is open on workspace three.|tts en Anything else for you?" \
  "$(grep '^tts' "$tmp/speak.log" | paste -sd'|')"
expect_contains_ "speak: cute = voice and timbre raised together" "$(cat "$tmp/speak.log")" "asetrate=16000*1.35"
expect_contains_ "speak: cute = then the pitch alone, formants kept" "$(grep rubberband "$tmp/speak.log" | head -n1)" "-F -f 1.5"
expect_eq "speak: played in order" "play cute1.wav|play cute2.wav" "$(grep '^play' "$tmp/speak.log" | paste -sd'|')"
: >"$tmp/speak.log"
sp --style natural "Coucou ! Julien demande si tu viens ce soir."
expect_eq "speak: French voice" "tts fr" "$(grep '^tts' "$tmp/speak.log" | cut -d' ' -f1-2 | sort -u)"
expect_eq "speak: natural = no cute chain" "" "$(grep -E '^(ffmpeg|rubberband)' "$tmp/speak.log" || true)"
: >"$tmp/speak.log"
sp -- "-5 degrees outside."
expect_eq "speak: a sentence never starts with a dash (an option to sherpa-onnx)" "tts en five degrees outside." "$(grep '^tts' "$tmp/speak.log")"
expect_eq "speak: a failure said, not silent" "sherpa-onnx-offline-tts failed (3): it broke 1" \
  "$(
    sp -- "This will FAIL now." 2>&1 >/dev/null | tr -d '\n'
    echo " ${PIPESTATUS[0]}"
  )"
: >"$tmp/speak.log"
# shellcheck disable=SC2016 # Markdown backticks, not an expansion
sp '🎉 ```x```'
expect_eq "speak: nothing speakable, nothing run" "" "$(cat "$tmp/speak.log")"
expect_eq "speak: no voice installed" 2 "$(
  PATH="$tmp/sbin:$PATH" NIXBOOK_MMS_VOICES="$tmp/none" python3 -I "$speak" "Hello there" 2>/dev/null
  echo $?
)"

# --stream: the text as an answer streams in, each sentence spoken once complete.
: >"$tmp/speak.log"
(
  printf 'Firefox is open on workspace three. And'
  sleep 1.5
  printf ' anything else for you?'
) | sp --stream --style natural >"$tmp/upto.log" &
speaker=$!
sleep 1
expect_eq "speak --stream: the first sentence spoken before the text ended" "tts en Firefox is open on workspace three.|play raw1.wav" \
  "$(grep -E '^(tts|play)' "$tmp/speak.log" | paste -sd'|')"
wait "$speaker"
expect_eq "speak --stream: then the rest, at the end" "tts en Firefox is open on workspace three.|play raw1.wav|tts en And anything else for you?|play raw2.wav" \
  "$(grep -E '^(tts|play)' "$tmp/speak.log" | paste -sd'|')"
# Where each sentence ends in the text, said as it starts playing: the shell
# shows the answer up to there (text and voice together).
expect_eq "speak --stream: each sentence's end told as it plays" "35 62" "$(jq -r .upto "$tmp/upto.log" | paste -sd' ')"
: >"$tmp/speak.log"
# shellcheck disable=SC2016 # Markdown backticks, not an expansion
printf 'Bonjour, voici la commande. ```\nrm -rf /\n``` Elle est prête.' | sp --stream --style natural
expect_eq "speak --stream: the voice from the first sentence, code left out" "tts fr Bonjour, voici la commande.|tts fr Elle est prête." \
  "$(grep '^tts' "$tmp/speak.log" | paste -sd'|')"

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
