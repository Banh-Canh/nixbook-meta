#!/usr/bin/env bash
# The daily brief, the reply batch and the phone handoff, without a shell or
# a model:
#   - brief-tests.py: scripts/desktop-mcp.py's brief_collect, brief_plain
#     (four languages), brief_compose (one masked small-model call, plain
#     words without), reply_candidates (which messages wait, how each is
#     answered), replies_draft, the daily_brief tool, the agents' guards;
#   - the CLI (`brief collect|compose`, `replies list`) against a stub
#     `nixbook-shell ipc` (the calendar, the tasks' transfer file, the
#     notification centre);
#   - handoff-tests.js: the phone handoff's rules (handoff.js) under node.
# Needs bash, python3 and jq (node, else nix-shell -p nodejs). Run: bash tests/brief.sh
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

mkdir -p "$tmp/state" "$tmp/cfg/nixbook-shell" "$tmp/run" "$tmp/home" "$tmp/data" "$tmp/bin"
chmod 700 "$tmp/run"
export XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/cfg" XDG_RUNTIME_DIR="$tmp/run" HOME="$tmp/home"
export XDG_DATA_HOME="$tmp/data" XDG_DATA_DIRS="$tmp/none"
unset NIXBOOK_MUSE_TASK_ID NIXBOOK_META_AGENT_CHILD NIXBOOK_DESKTOP_MCP_NO_TASKS NIXBOOK_DESKTOP_MCP_CONFIG
unset NIXBOOK_DESKTOP_MCP_QS NIXBOOK_DESKTOP_MCP_QS_CONFIG NIXBOOK_AI_KEY NIXBOOK_AI_BASE_URL
echo '{"initiativeQuietHours": "3-3"}' >"$tmp/cfg/nixbook-shell/desktop-mcp.json"
echo '{"policies": {"ai": 1}}' >"$tmp/cfg/nixbook-shell/config.json"

# -- the logic (python, the shell and the model faked) -------------------------
if python3 -I "$root/tests/brief-tests.py" "$root"; then pass "brief-tests.py"; else fail "brief-tests.py"; fi

# -- the CLI, through a stub `nixbook-shell ipc` --------------------------------
rm -rf "$tmp/state" "$tmp/run"
mkdir -p "$tmp/state" "$tmp/run"
chmod 700 "$tmp/run"
today=$(date +%F)
cat >"$tmp/bin/nixbook-shell" <<EOF
#!/usr/bin/env python3
import json, sys
a = [x for x in sys.argv[1:] if x != "--"]
# ipc call TARGET FN ARGS…
target, fn, rest = a[2], a[3], a[4:]
if target == "calendar" and fn == "day":
    ev = [{"summary": "Standup", "start": rest[0] + "T09:30", "end": rest[0] + "T09:45", "allDay": False}] if rest[0] == "$today" else []
    print(json.dumps({"date": rest[0], "events": ev}))
elif target == "todo" and fn == "query":
    json.dump({"today": "$today", "lists": [], "tasks": [{"id": "1", "title": "Pay rent", "done": False, "deadline": "today"}]},
              open(rest[0], "w"))
    print("ok")
elif target == "notifications" and fn == "list":
    print(json.dumps([{"id": 4, "app": "Signal", "summary": "Lan", "body": "lunch?", "time": 1, "actions": [], "canReply": True},
                      {"id": 5, "app": "Firefox", "summary": "Done", "body": "x", "time": 2, "actions": [], "canReply": False}]))
else:
    print("error: no such target")
EOF
chmod +x "$tmp/bin/nixbook-shell"
dm() { PATH="$tmp/bin:$PATH" python3 -I "$root/scripts/desktop-mcp.py" "$@"; }

out=$(dm brief collect morning)
expect_eq "brief collect: today's events from the shell" "Standup 09:30" "$(jq -r '.events[0] | "\(.title) \(.start)"' <<<"$out")"
expect_eq "brief collect: the tasks through the transfer file" "Pay rent" "$(jq -r '.tasks.dueToday[0]' <<<"$out")"
expect_eq "brief collect: who waits" '[{"app":"Signal","who":"Lan"}]' "$(jq -c '.replies' <<<"$out")"
out=$(dm brief compose morning --lang en)
# Desktop control is paused until allowed: plain words, no model.
expect_eq "brief compose: paused, plain words" "false" "$(jq -r '.phrased' <<<"$out")"
greet="Good morning!"
[ "$(date +%H)" -lt 12 ] || greet="Hello!"
expect_eq "brief compose: its text" "$greet Today: Standup at 09:30. One task due today: Pay rent. One message waits for a reply (Lan)." \
  "$(jq -r '.text' <<<"$out")"
out=$(dm brief compose evening --lang fr --plain)
expect_eq "brief compose evening --plain (fr)" "Votre journée." "$(jq -r '.text' <<<"$out" | cut -d' ' -f1-2)"
expect_eq "replies list" '[[4,"inline"]]' "$(dm replies list | jq -c '[.[] | [.id, .via]]')"
expect_eq "replies list --ids: none of those" '[]' "$(dm replies list --ids 99 | jq -c '.')"
expect_eq "brief: unknown kind" "2" "$(
  dm brief compose noon >/dev/null 2>&1
  echo $?
)" || true
echo '{"policies": {"ai": 0}}' >"$tmp/cfg/nixbook-shell/config.json"
expect_eq "AI off: no brief" "1" "$(
  dm brief compose morning >/dev/null 2>&1
  echo $?
)" || true
expect_eq "AI off: no drafts" "AI features are off (policies.ai)" "$(dm replies draft | jq -r '.error' || true)"

# -- the phone handoff (node) ---------------------------------------------------
if command -v node >/dev/null; then
  if node "$root/tests/handoff-tests.js"; then pass "handoff-tests.js"; else fail "handoff-tests.js"; fi
elif nix-shell -p nodejs --run "node '$root/tests/handoff-tests.js'"; then
  pass "handoff-tests.js"
else
  fail "handoff-tests.js"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all brief, replies and handoff tests passed"
