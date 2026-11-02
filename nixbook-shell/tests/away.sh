#!/usr/bin/env bash
# Tests for "While you were away" (scripts/desktop-mcp.py `away summary`, what
# services/AwaySummary.qml calls when the user comes back), no shell:
#   - the plain ranking: noise dropped (the shell's own, private codes, low
#     urgency), urgency × value (critical, urgent words, someone who matters,
#     a message waiting for an answer, a meeting soon, a task waiting), a
#     conversation's burst one line with every id, at most six lines;
#   - the one small-model call: only with policies.ai 1, desktop control not
#     paused and two lines or more; its order taken (made-up numbers left
#     out), its sentence kept; through the privacy mask;
#   - nothing with policies.ai 0, the plain list with 2;
#   - the CLI: refused in an agent's process; the helper serves it on stdin,
#     never on the socket;
#   - the shell's side: the calendar's changes while away (away_changes.js,
#     away-changes-tests.js under node).
# Needs bash, python3, jq and node (else nix-shell -p nodejs). Run: bash tests/away.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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

mkdir -p "$tmp/state/nixbook-shell" "$tmp/cfg/nixbook-shell" "$tmp/run" "$tmp/home" "$tmp/data"
export XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/cfg" XDG_RUNTIME_DIR="$tmp/run" HOME="$tmp/home"
export XDG_DATA_HOME="$tmp/data" XDG_DATA_DIRS="$tmp/none"
unset NIXBOOK_MUSE_TASK_ID NIXBOOK_META_AGENT_CHILD NIXBOOK_DESKTOP_MCP_NO_TASKS NIXBOOK_DESKTOP_MCP_CONFIG
unset NIXBOOK_META_AGENT NIXBOOK_DESKTOP_MCP_INPROCESS
settings() { echo "{\"policies\": {\"ai\": $1}, \"ai\": {\"privacy\": {\"mask\": $2}}}" >"$tmp/cfg/nixbook-shell/config.json"; }
settings 1 false
# Desktop control allowed (paused, the model is never asked).
touch "$tmp/state/nixbook-shell/desktop-control-allowed"

# The model in this process, a fake nixbook_ai beside a copy of the script:
# it logs what it was sent and answers $FAKE_AI_ANSWER.
mkdir -p "$tmp/bin"
cp "$root/scripts/desktop-mcp.py" "$tmp/bin/desktop-mcp.py"
cat >"$tmp/bin/nixbook_ai.py" <<'EOF'
import json, os
class NoProvider(Exception):
    pass
def answer(system, prompt, *, model="small", effort=None, schema=None, timeout=180):
    with open(os.environ["FAKE_AI_LOG"], "a") as f:
        f.write(json.dumps({"model": model, "effort": effort, "system": system[:40], "privacy": "stand-ins" in system, "prompt": prompt,
                            "schema": sorted((schema or {}).get("properties", {}))}) + "\n")
    return json.loads(os.environ.get("FAKE_AI_ANSWER") or '{"summary": "", "order": []}')
EOF
export FAKE_AI_LOG="$tmp/fake-ai.log"
dm() { python3 -I "$tmp/bin/desktop-mcp.py" "$@"; }
calls() { [ -e "$FAKE_AI_LOG" ] && wc -l <"$FAKE_AI_LOG" | tr -d ' ' || echo 0; }

# What the shell sends back from a break (AwaySummary.collect): oldest first.
cat >"$tmp/away.json" <<'EOF'
{"away": 47, "lang": "en", "items": [
  {"kind": "notification", "key": "n:1", "ids": [1], "app": "Vesktop", "title": "Lan", "text": "are you coming tonight?", "urgency": "normal", "canReply": true, "time": 100},
  {"kind": "notification", "key": "n:2", "ids": [2], "app": "Vesktop", "title": "Lan", "text": "we start at 8", "urgency": "normal", "canReply": true, "time": 200},
  {"kind": "notification", "key": "n:3", "ids": [3], "app": "Bank", "title": "Your code", "text": "Your verification code is 482913", "urgency": "normal", "time": 150},
  {"kind": "notification", "key": "n:4", "ids": [4], "app": "Steam", "title": "Update", "text": "A game was updated", "urgency": "low", "time": 160},
  {"kind": "notification", "key": "n:5", "ids": [5], "app": "Muse", "title": "Muse", "text": "A background task finished", "urgency": "normal", "time": 170},
  {"kind": "notification", "key": "n:6", "ids": [6], "app": "Thunderbird", "title": "Server down", "text": "prod is down, urgent", "urgency": "normal", "time": 180},
  {"kind": "notification", "key": "n:7", "ids": [7], "app": "Zen", "title": "Newsletter", "text": "This week in tech", "urgency": "normal", "time": 190},
  {"kind": "calendar", "key": "c:standup", "eventId": "standup", "app": "Calendar", "title": "Standup moved", "text": "now 14:30", "change": "moved", "startsIn": 20, "time": 120},
  {"kind": "task", "key": "t:abc", "taskId": "abc", "app": "Muse", "title": "Compare flights", "text": "3 options found", "status": "done", "time": 130},
  {"kind": "routine", "key": "r:1", "app": "Routines", "title": "Evening lights", "text": "ran", "time": 140}
]}
EOF

# -- the plain ranking ----------------------------------------------------------
out=$(dm away summary - <"$tmp/away.json")
expect_eq "noise dropped: the code, the low urgency, the shell's own" "3" "$(jq -r .dropped <<<"$out")"
expect_eq "every item counted" "10" "$(jq -r .total <<<"$out")"
expect_eq "the private code never shown" "" "$(jq -r '.items[] | select(.app == "Bank") | .key' <<<"$out")"
expect_eq "a conversation's burst: one line" "1" "$(jq '[.items[] | select(.app == "Vesktop")] | length' <<<"$out")"
expect_eq "its every id kept" "[1,2]" "$(jq -c '.items[] | select(.app == "Vesktop") | .ids' <<<"$out")"
expect_eq "its newest words" "we start at 8" "$(jq -r '.items[] | select(.app == "Vesktop") | .text' <<<"$out")"
expect_eq "it waits for an answer" "true" "$(jq -r '.items[] | select(.app == "Vesktop") | .reply' <<<"$out")"
expect_contains "counted in why" "$(jq -r '.items[] | select(.app == "Vesktop") | .why' <<<"$out")" "2 notifications"
expect_eq "urgency × value, the newest first among equals" "n:6 c:standup n:2 t:abc n:7 r:1" \
  "$(jq -r '[.items[].key] | join(" ")' <<<"$out")"
expect_eq "urgent words: now" "now" "$(jq -r '.items[] | select(.app == "Thunderbird") | .urgency' <<<"$out")"
expect_eq "a meeting in 20 min: now" "now" "$(jq -r '.items[] | select(.kind == "calendar") | .urgency' <<<"$out")"
expect_eq "a routine that ran: last" "routine" "$(jq -r '.items[-1].kind' <<<"$out")"
expect_eq "the shell's fields carried back" "abc" "$(jq -r '.items[] | select(.kind == "task") | .taskId' <<<"$out")"

# -- someone who matters ------------------------------------------------------------
pmem="$tmp/state/nixbook-shell/personal-memory.json"
python3 - "$pmem" <<'EOF'
import json, sys, time
t = int(time.time())
json.dump({"version": 1, "entries": [{"id": "p1", "topic": "Lan", "kind": "person", "text": "Lan, my sister",
                                      "importance": 4, "created": t, "updated": t}]}, open(sys.argv[1], "w"))
EOF
out=$(dm away summary - <"$tmp/away.json")
expect_contains "from someone who matters" "$(jq -r '.items[] | select(.app == "Vesktop") | .why' <<<"$out")" "who matters"
expect_eq "worth the most" "3" "$(jq -r '.items[] | select(.app == "Vesktop") | .value' <<<"$out")"
rm -f "$pmem"

# -- the one model call ---------------------------------------------------------------
rm -f "$FAKE_AI_LOG"
out=$(FAKE_AI_ANSWER='{"summary": "Lan is waiting for you, and prod is down.", "order": [3, 1, 99, 3]}' dm away summary - <"$tmp/away.json")
expect_eq "one call" "1" "$(calls)"
expect_eq "the small model, minimal effort, its schema" "small minimal order,summary" \
  "$(jq -r '"\(.model) \(.effort) \(.schema | join(","))"' "$FAKE_AI_LOG")"
expect_eq "its sentence kept" "Lan is waiting for you, and prod is down." "$(jq -r .summary <<<"$out")"
expect_eq "said it was the model" "true" "$(jq -r .model <<<"$out")"
expect_eq "its order taken, made-up and repeated numbers left out, the rest after" "n:2 n:6 c:standup t:abc n:7 r:1" \
  "$(jq -r '[.items[].key] | join(" ")' <<<"$out")"
expect_contains "the prompt numbers the lines" "$(jq -r .prompt "$FAKE_AI_LOG")" "[1] notification · Thunderbird"
expect_contains "the prompt says how long" "$(jq -r .prompt "$FAKE_AI_LOG")" "Away for: 47 min"
expect_eq "in the record of what was sent" "while you were away" "$(dm sent | jq -r '.[0].purpose')"

rm -f "$FAKE_AI_LOG"
dm away summary - <<<'{"away": 30, "model": false, "items": [{"kind": "routine", "key": "r", "title": "A", "text": "ran"}, {"kind": "routine", "key": "s", "title": "B", "text": "ran"}]}' >/dev/null
expect_eq "model: false: no call" "0" "$(calls)"
out=$(dm away summary - <<<'{"away": 30, "items": [{"kind": "routine", "key": "r", "title": "A", "text": "ran"}]}')
expect_eq "a single line: no call" "0" "$(calls)"
expect_eq "a single line: shown" "1" "$(jq '.items | length' <<<"$out")"

rm -f "$tmp/state/nixbook-shell/desktop-control-allowed"
out=$(dm away summary - <"$tmp/away.json")
expect_eq "desktop control paused: no call" "0" "$(calls)"
expect_contains "paused: the plain list" "$(jq -r .why <<<"$out")" "paused"
touch "$tmp/state/nixbook-shell/desktop-control-allowed"

# Through the privacy mask (ask_agent): the masked prompt and the privacy
# rules with it; without the mask, neither.
settings 1 true
rm -f "$FAKE_AI_LOG"
FAKE_AI_ANSWER='{"summary": "ok", "order": []}' dm away summary - <"$tmp/away.json" >/dev/null
expect_eq "masked: the privacy rules sent with it" "true" "$(jq -r .privacy "$FAKE_AI_LOG")"
settings 1 false
rm -f "$FAKE_AI_LOG"
FAKE_AI_ANSWER='{"summary": "ok", "order": []}' dm away summary - <"$tmp/away.json" >/dev/null
expect_eq "the mask off: no privacy rules" "false" "$(jq -r .privacy "$FAKE_AI_LOG")"

# -- the policies -------------------------------------------------------------------
rm -f "$FAKE_AI_LOG"
settings 0 false
out=$(dm away summary - <"$tmp/away.json")
expect_eq "AI off: nothing" "0" "$(jq '.items | length' <<<"$out")"
settings 2 false
out=$(dm away summary - <"$tmp/away.json")
expect_eq "local only: the plain list" "true" "$(jq '.items | length > 0' <<<"$out")"
expect_eq "local only: no model call" "0" "$(calls)"
expect_eq "local only: no sentence" "" "$(jq -r .summary <<<"$out")"
settings 1 false

# -- the command line and the helper ------------------------------------------------
expect_eq "not JSON: refused" "2" "$(
  dm away summary - <<<'[1]' >/dev/null 2>&1
  echo $?
)"
expect_eq "an agent's process: refused" "126" "$(
  NIXBOOK_META_AGENT_CHILD=1 dm away summary - <"$tmp/away.json" >/dev/null 2>&1
  echo $?
)"
out=$(
  python3 - "$tmp/bin" <<'EOF'
import importlib.util as u, sys
s = u.spec_from_file_location("m", sys.argv[1] + "/desktop-mcp.py")
m = u.module_from_spec(s)
s.loader.exec_module(m)
print(m.helper_allowed(["away", "summary"]), m.helper_allowed(["away", "summary"], stdin=False),
      ("away", "summary") in m.HELPER_THREADED)
EOF
)
expect_eq "the helper: on stdin (threaded), never on the socket" "True False True" "$out"

# -- the calendar's changes (away_changes.js, the shell's side, under node) -------
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v node >/dev/null; then
  node "$here/away-changes-tests.js" || failures=$((failures + 1))
else
  nix-shell -p nodejs --run "node '$here/away-changes-tests.js'" || failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all away tests passed"
