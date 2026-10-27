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
 {"name": "screenshot", "description": "A screenshot", "inputSchema": {"type": "object", "properties": {}},
  "annotations": {"readOnlyHint": true}, "_meta": {"nixbook/group": "screen"}},
 {"name": "desktop", "description": "Not offered", "inputSchema": {"type": "object"}, "annotations": {}}]
JSON
;;
call) echo "\$2 \$3" >>"$tmp/calls.log"
  case "\$3" in *BROKEN* | *OTHERFIRST*) echo "error: no such app"; exit 1 ;; esac
  if [ "\$2" = screenshot ]; then echo '[{"type": "text", "text": "the screen"}, {"type": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png"}]'
  else echo "done: \$2"; fi ;;
privacy)
  if [ "\$2" = mask ]; then sed 's/Julien/⟦Person 1⟧/g'; else sed 's/⟦Person 1⟧/Julien/g'; fi ;;
sent) echo "\$3|\$5" >>"$tmp/sent.log" ;;
instructions) echo "Tools to see and drive the desktop. Notes: QUERY=\$NIXBOOK_DESKTOP_MCP_QUERY" ;;
app-tools) cat "$tmp/app-tools.json" 2>/dev/null || echo '{}' ;;
episode) cat >>"$tmp/episode.log"; echo >>"$tmp/episode.log" ;;
app-call) echo "app \$2 \$3 \$4" >>"$tmp/calls.log"; echo '{"title": "FIRESTARTER", "isPaused": false}' ;;
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
expect_eq "do: just the answer when it went well, as in a chat" '"Firefox is open."' "$(event act answer .text)"
expect_eq "do: no report when it went well" "" "$(event act report .summary)"
expect_eq "do: every tool but the agent desktop's switch, without desktop-mcp's extras" '["launch_app","close_window","tasks","screenshot"]
[]' "$(jq -c 'select(.body.tools) | [.body.tools[].name], [.body.tools[0].input_schema.properties | keys[] | select(. == "wait_ms")]' "$tmp/requests.log" | head -n2)"

# What it did goes to the desktop memory's learning pass (as an MCP session's
# task does); a task that only read, not.
sleep 0.3
expect_eq "learn: the episode told" '{"task":"open firefox","actions":[{"tool":"launch_app","do":"app=firefox","error":null}]}' \
  "$(head -n1 "$tmp/episode.log" | jq -c .)"
# The side panel's knowledge (Ai.stableSystemPrompt) first, cached.
: >"$tmp/requests.log"
ask brain '{"mode": "do", "question": "open firefox", "lang": "en", "panel": "PANELBRAIN: host totoro, theme Momonga"}'
expect_eq "brain: the panel's prompt, first and cached" '{"type":"ephemeral"} true' \
  "$(jq -c 'select(.body.tools) | .body.system[0] | "\(.cache_control | tojson) \(.text | contains("PANELBRAIN"))"' -r "$tmp/requests.log" | head -n1)"
expect_contains_ "brain: the memory for this task after it" "$(jq -c 'select(.body.tools) | .body.system[1].text' "$tmp/requests.log" | head -n1)" "QUERY=open firefox"

# The report only when it matters: a step that failed for good (said even
# when the model leaves it out), or something the user must do.
ask failed '{"mode": "do", "question": "FAILSTEP open it", "lang": "en"}'
expect_eq "report: a failed step, from the steps" '["launch app (app=BROKEN): error: no such app"]' "$(event failed report .failed)"
expect_eq "report: the steps counted" '1 0 1' "$(event failed report ' | "\(.steps) \(.ok) \(.ko)"' | tr -d '"')"
expect_contains_ "report: in the answer too" "$(event failed answer .text)" "✗ launch app"
ask retried '{"mode": "do", "question": "RETRY open firefox", "lang": "en"}'
expect_eq "report: none when a failed step was then done" "" "$(event retried report .summary)"
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
# Eyes: a screenshot comes back to the model as an image.
: >"$tmp/calls.log"
ask look '{"mode": "do", "question": "LOOKSCREEN what is on my screen?", "lang": "en"}'
expect_contains_ "eyes: the image in the tool result" "$(jq -c 'select(.body.tools) | .body.messages[-1].content' "$tmp/requests.log" | grep tool_result | tail -n1)" '"type":"image"'
# The whole assistant: a task handed over to Claude Code.
ask handoff '{"mode": "do", "question": "DELEGATE find the news", "lang": "en", "claude": "/bin/true"}'
expect_eq "ask_claude: handed over" '"search the web for the news"' "$(event handoff delegate .task)"
expect_eq "ask_claude: offered only with Claude Code" "" "$(jq -c 'select(.body.tools) | [.body.tools[].name] | index("ask_claude")' "$tmp/requests.log" | head -n1 | grep -v null)"
# What the machine is (system-context.md) and what the user just did.
mkdir -p "$tmp/cfg/nixbook-shell"
printf '# About\n## This machine\nHost testhost\n## Packages installed\nhuge list\n' >"$tmp/cfg/nixbook-shell/system-context.md"
XDG_CONFIG_HOME="$tmp/cfg" ask ctx '{"mode": "do", "question": "open firefox CTX", "lang": "en", "activity": "opened kitty"}'
sys=$(jq -c 'select(.body.tools) | .body.system' "$tmp/requests.log" | grep -F "CTX" -m1 || jq -c 'select(.body.tools) | .body.system' "$tmp/requests.log" | tail -n1)
expect_contains_ "context: the machine" "$sys" "Host testhost"
expect_contains_ "context: not the package lists" "$(echo "$sys" | grep -c 'huge list' | sed 's/^0$/none/')" "none"
expect_contains_ "context: what the user just did" "$sys" "opened kitty"

# The user's apps' tools (app-tools / app-call): a small server's up front,
# a big one's on demand (open_app_tools) or when it is named.
python3 - "$tmp/app-tools.json" <<'PY'
import json, sys
tool = lambda n: {"name": n, "description": f"{n} it", "inputSchema": {"$schema": "x", "type": "object", "properties": {"query": {"type": "string"}}}}
json.dump({"youtube-music": {"instructions": "Plays songs in YouTube Music.", "tools": [tool("play"), tool("now_playing")]},
           "immich": {"instructions": "Photos.", "tools": [tool(f"search_{i}") for i in range(13)]}}, open(sys.argv[1], "w"))
PY
: >"$tmp/calls.log"
: >"$tmp/requests.log"
ask music '{"mode": "do", "question": "MUSIC play FIRESTARTER", "lang": "en"}'
expect_eq "apps: called through app-call" 'app youtube-music play {"query": "FIRESTARTER"}' "$(head -n1 "$tmp/calls.log")"
tools=$(jq -c 'select(.body.tools) | [.body.tools[].name]' "$tmp/requests.log" | head -n1)
expect_contains_ "apps: a small app's tools up front" "$tools" '"youtube-music__play"'
expect_contains_ "apps: a big app's on demand only" "$(echo "$tools" | grep -c immich__ | sed 's/^0$/none/')" none
expect_contains_ "apps: offered to open" "$tools" '"open_app_tools"'
expect_eq "apps: no schema dialect key sent" "null" "$(jq -c 'select(.body.tools) | .body.tools[] | select(.name == "youtube-music__play") | .input_schema["$schema"]' "$tmp/requests.log" | head -n1)"
expect_contains_ "apps: their instructions" "$(jq -c 'select(.body.tools) | .body.system' "$tmp/requests.log" | head -n1)" "Plays songs in YouTube Music."
expect_eq "apps: a step like any other" '"ok"' "$(event music step .status | tail -n1)"
expect_eq "apps: shown as app: tool" '"youtube-music: play"' "$(event music step .tool | tail -n1)"
expect_eq "apps: done, just said" "" "$(event music report .summary)"
: >"$tmp/requests.log"
ask photos '{"mode": "do", "question": "PHOTOS find my holiday pictures", "lang": "en"}'
expect_contains_ "apps: opened on demand, for the next steps" "$(jq -c 'select(.body.tools) | [.body.tools[].name]' "$tmp/requests.log" | tail -n1)" '"immich__search_12"'
: >"$tmp/requests.log"
ask named '{"mode": "do", "question": "open firefox and search immich", "lang": "en"}'
expect_contains_ "apps: a big app up front when named" "$(jq -c 'select(.body.tools) | [.body.tools[].name]' "$tmp/requests.log" | head -n1)" '"immich__search_0"'
rm -f "$tmp/app-tools.json"

# A tool that also writes, asked only to read (its action): no OK needed,
# even when every action is asked about; and no report for it.
: >"$tmp/calls.log"
ask reads '{"mode": "do", "question": "TASKS what is on my list?", "lang": "en", "confirm": "actions"}'
expect_eq "read actions: not asked" "" "$(event reads approve .tool)"
expect_eq "read actions: run" 'tasks {"action": "list"}' "$(cat "$tmp/calls.log")"
expect_eq "read actions: no report" "" "$(event reads report .summary)"

# A destructive step: asked, refused, not run.
: >"$tmp/calls.log"
ask deny '{"mode": "do", "question": "DELETE the task", "lang": "en"}' $'no\n'
expect_eq "deny: a risky step asked first" '"tasks"' "$(event deny approve .tool)"
expect_eq "deny: not run" '"denied"' "$(event deny step .status)"
expect_eq "deny: nothing called" "" "$(cat "$tmp/calls.log")"
expect_eq "deny: reported as failed" '["tasks (id=t1, action=delete): you said no"]' "$(event deny report .failed)"
: >"$tmp/calls.log"
ask closing '{"mode": "do", "question": "CLOSE the window", "lang": "en"}'
expect_eq "risky only: closing a window isn't asked" "" "$(event closing approve .tool)"
expect_eq "risky only: done at once" 'close_window {"id": 7}' "$(cat "$tmp/calls.log")"
risky() { python3 -I -c 'import importlib.util,json,sys; s=importlib.util.spec_from_file_location("q",sys.argv[1]); q=importlib.util.module_from_spec(s); s.loader.exec_module(q); print(q.is_risky(sys.argv[2], json.loads(sys.argv[3]), {}))' "$script" "$1" "$2"; }
expect_eq "risky: a browser click on Send" True "$(risky browser_act '{"ref": 1, "name": "Send", "action": "click"}')"
expect_eq "risky: a browser form placing an order" True "$(risky browser_act '{"ref": 4, "name": "Place order", "action": "submit"}')"
expect_eq "risky: a browser click elsewhere isn't" False "$(risky browser_act '{"ref": 2, "name": "Liked Music", "action": "click"}')"
expect_eq "risky: typing in a page isn't" False "$(risky browser_act '{"ref": 3, "name": "Message", "action": "type", "value": "send it"}')"
: >"$tmp/calls.log"
ask allow '{"mode": "do", "question": "DELETE the task", "lang": "en"}' $'yes\n'
expect_eq "allow: run once allowed" 'tasks {"action": "delete", "id": "t1"}' "$(cat "$tmp/calls.log")"
: >"$tmp/calls.log"
ask never '{"mode": "do", "question": "DELETE the task", "lang": "en", "confirm": "never"}'
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
for _ in 1 2; do python3 -I "$script" learn '{"event": {"event": "notification", "app": "Chat", "title": "Ana"}, "decision": "ask", "outcome": "agreed", "said": "yes"}'; done
ask react5 "$ev"
expect_eq "react: agreed twice: acts alone" '"do"' "$(event react5 react .action)"
expect_contains_ "react: the past answers go along" "$(grep LEARNED "$tmp/requests.log" | tail -n1)" "the user agreed: yes"
expect_eq "react: what it learned is said" '"answer yes to Ana"' "$(event react5 react .learn)"
python3 -I "$script" learn '{"pref": "Ana is my sister"}'
expect_eq "learn: a preference kept" '"Ana is my sister"' "$(python3 -I "$script" learned | jq -c '.prefs[-1].text')"
python3 -I "$script" learn '{"forget": true}'
expect_eq "learn: forgotten" '{}' "$(python3 -I "$script" learned)"
unset XDG_STATE_HOME

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
