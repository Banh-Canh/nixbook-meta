#!/usr/bin/env bash
# Tests for "Next up" predictions (scripts/desktop-mcp.py `predict`, what
# services/NextUp.qml calls), no model and no shell:
#   - the statistics: a step after its cue, by time of day, decayed; the
#     time-of-day prior when nothing just happened;
#   - the bar: probability >= threshold, seen >= minCount times, the step in
#     front or just done never offered, quiet hours, an hour's offers;
#   - learning: accepted counted again, ignored and dismissed lower its odds
#     and rest it, never mutes it (after its cue, or anywhere), done by hand;
#   - follow-ups from the start (a pull request), only with policies.ai 1;
#     nothing at all with policies.ai 0; private windows never counted;
#   - the CLI: seed, show, explain, status, unmute, clear; the four
#     languages; the file 0600 and bounded; the helper serves it, the socket
#     and agents' processes don't get to feed it.
# Needs bash, python3 and jq. Run: bash tests/predict.sh
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

mkdir -p "$tmp/state" "$tmp/cfg/nixbook-shell" "$tmp/run" "$tmp/home" "$tmp/data/applications"
export XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/cfg" XDG_RUNTIME_DIR="$tmp/run" HOME="$tmp/home"
export XDG_DATA_HOME="$tmp/data" XDG_DATA_DIRS="$tmp/none"
unset NIXBOOK_MUSE_TASK_ID NIXBOOK_META_AGENT_CHILD NIXBOOK_DESKTOP_MCP_NO_TASKS NIXBOOK_DESKTOP_MCP_CONFIG
# No quiet hours unless a test asks (the defaults, 22-8, would fail at night).
echo '{"initiativeQuietHours": "3-3"}' >"$tmp/cfg/nixbook-shell/desktop-mcp.json"
policy() { echo "{\"policies\": {\"ai\": $1}}" >"$tmp/cfg/nixbook-shell/config.json"; }
policy 1
cat >"$tmp/data/applications/firefox.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Firefox
Exec=firefox
EOF
dm() { python3 -I "$root/scripts/desktop-mcp.py" "$@"; }
file="$tmp/state/nixbook-shell/predictions.json"
reset() { dm predict clear >/dev/null; }
# A seed of observations replayed: $1 python producing the list (t: now).
replay() {
  python3 -c "import json, time; t = time.time(); print(json.dumps({'observations': $1}))" >"$tmp/seed.json"
  dm predict seed "$tmp/seed.json"
}
opts='{"lang": "en", "threshold": 0.5, "minCount": 4}'

# -- the demo's seed: a step after a meeting ----------------------------------
cat >"$tmp/demo.json" <<'EOF'
{"labels": {"app:jira": {"name": "Jira"}, "meeting_end:daily standup": {"name": "Daily standup", "at": "09:00"}},
 "transitions": [{"from": "meeting_end:daily standup", "to": "app:jira", "count": 14, "at": "09:30"}]}
EOF
expect_eq "seed: the transitions and labels given" '{"transitions": 1, "observations": 0, "labels": 2}' \
  "$(dm predict seed "$tmp/demo.json")"
out=$(dm predict observe '{"kind": "event", "event": "meeting_end", "title": "Daily standup", "at": "09:00", "lang": "en", "threshold": 0.5, "minCount": 4}')
expect_eq "a meeting over: open Jira offered" "app:jira" "$(jq -r '.offer.action' <<<"$out")"
expect_eq "its chip" "Next: open Jira" "$(jq -r '.offer.chip' <<<"$out")"
expect_eq "its explain line" "You usually open Jira after your 09:00 Daily standup — 14 times" \
  "$(jq -r '.offer.explain' <<<"$out")"
expect_eq "it carries what to do (an app)" "jira" "$(jq -r '.offer.app' <<<"$out")"
expect_eq "no model needed" "false" "$(jq -r '.offer.model' <<<"$out")"
expect_eq "the file is the user's only" "600" "$(stat -c %a "$file")"
id=$(jq -r '.offer.id' <<<"$out")
out=$(dm predict observe '{"kind": "app", "app": "jira", "lang": "en"}')
expect_eq "done by hand: the offer is resolved" "[\"$id\"]" "$(jq -c '.done' <<<"$out")"
expect_eq "done: no feedback asked any more" "1" "$(
  dm predict feedback "$id" ignored >/dev/null
  echo $?
)" || true

for lang in fr de vi; do
  reset
  dm predict seed "$tmp/demo.json" >/dev/null
  out=$(dm predict observe "{\"kind\": \"event\", \"event\": \"meeting_end\", \"title\": \"Daily standup\", \"at\": \"09:00\", \"lang\": \"$lang\"}")
  case $lang in
  fr) want="Ensuite : ouvrir Jira|Ouvrir Jira : ce que tu fais d'habitude après « Daily standup » de 09:00 (14 fois)" ;;
  de) want='Als Nächstes: Jira öffnen|Jira öffnen: das machst du meistens nach „Daily standup“ um 09:00 (14-mal)' ;;
  vi) want='Tiếp theo: mở Jira|Bạn thường mở Jira sau cuộc họp “Daily standup” lúc 09:00 — 14 lần' ;;
  esac
  expect_eq "the chip and explain line in $lang" "$want" "$(jq -r '"\(.offer.chip)|\(.offer.explain)"' <<<"$out")"
done

# -- the statistics -------------------------------------------------------------
reset
# Five mornings: firefox then kitty a minute later (a day apart, 20 days ago on).
replay "[o for d in range(5) for o in ({'time': t - (20 - d) * 86400, 'kind': 'app', 'app': 'firefox'}, {'time': t - (20 - d) * 86400 + 60, 'kind': 'app', 'app': 'kitty'})]" >/dev/null
out=$(dm predict offer '{"lang": "en", "threshold": 0.5, "minCount": 4}')
expect_eq "nothing just happened, nothing in this hour: none" "null" "$(jq -c '.offer' <<<"$out")"
out=$(dm predict observe '{"kind": "app", "app": "firefox", "name": "Firefox", "lang": "en", "openApps": ["kitty"]}')
expect_eq "after Firefox: kitty (seen 5 times)" "app:kitty" "$(jq -r '.offer.action' <<<"$out")"
expect_eq "kitty open: switch to it" "Next: switch to Kitty" "$(jq -r '.offer.chip' <<<"$out")"
p=$(jq -r '.offer.p' <<<"$out")
# All of it after Firefox (0.85 of it), half of this hour's uses (0.15 × 0.5).
if python3 -c "import sys; p = float(sys.argv[1]); sys.exit(0 if 0.88 < p <= 0.925 else 1)" "$p"; then
  pass "its odds: the share after its cue, a little of the time prior ($p)"
else
  fail "its odds" "p = $p, expected in (0.88, 0.925]"
fi
expect_contains "decayed: 20 days on, still counted" "$(jq -r '.offer.explain' <<<"$out")" "5 times"
offer=$(jq -r '.offer.id' <<<"$out")
dm predict feedback "$offer" ignored >/dev/null
out=$(dm predict explain "$opts")
expect_contains "explain: the cue in words" "$out" "app:firefox (after Firefox)"
expect_contains "explain: let go, it rests" "$out" "resting after being turned down or offered"

reset
replay "[o for d in range(3) for o in ({'time': t - d * 86400 - 7200, 'kind': 'app', 'app': 'firefox'}, {'time': t - d * 86400 - 7140, 'kind': 'app', 'app': 'kitty'})]" >/dev/null
out=$(dm predict observe '{"kind": "app", "app": "firefox", "lang": "en", "minCount": 4}')
expect_contains "three times only: not offered (minCount 4)" "$(jq -r '.why' <<<"$out")" "seen 3 times, fewer than 4"
out=$(dm predict offer '{"lang": "en", "minCount": 3}')
expect_eq "minCount 3: offered" "app:kitty" "$(jq -r '.offer.action' <<<"$out")"

reset
# After Firefox, kitty and Thunderbird as often: about half each.
replay "[o for d in range(6) for o in ({'time': t - d * 86400 - 7200, 'kind': 'app', 'app': 'firefox'}, {'time': t - d * 86400 - 7140, 'kind': 'app', 'app': 'kitty' if d % 2 else 'thunderbird'})]" >/dev/null
out=$(dm predict observe '{"kind": "app", "app": "firefox", "lang": "en", "threshold": 0.6}')
expect_contains "two steps as likely: under a 0.6 threshold" "$(jq -r '.why' <<<"$out")" "below the threshold"
out=$(dm predict offer '{"lang": "en", "threshold": 0.4, "minCount": 3}')
expect_contains "a 0.4 threshold: one of them" "app:kitty app:thunderbird" "$(jq -r '.offer.action // "none"' <<<"$out")"

# By time of day: mornings Slack after the terminal, evenings Steam.
reset
replay "[o for d in range(6) for h, nxt in ((9, 'slack'), (20, 'steam')) for o in ({'time': time.mktime(time.localtime(t - (d + 1) * 86400)[:3] + (h, 0, 0, 0, 0, -1)), 'kind': 'app', 'app': 'kitty'}, {'time': time.mktime(time.localtime(t - (d + 1) * 86400)[:3] + (h, 1, 0, 0, 0, -1)), 'kind': 'app', 'app': nxt})]" >/dev/null
morning=$(python3 -c "import time; t = time.time(); print(time.mktime(time.localtime(t)[:3] + (9, 30, 0, 0, 0, -1)))")
evening=$(python3 -c "import time; t = time.time(); print(time.mktime(time.localtime(t)[:3] + (20, 30, 0, 0, 0, -1)))")
cat >"$tmp/hour.py" <<EOF
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("dm", "$root/scripts/desktop-mcp.py")
dm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dm)
cfg = dm.load_config()
d = dm.read_predictions()
out = []
for when in ($morning, $evening):
    c = dm.predict_candidates(cfg, d, {"minCount": 4}, when, ["app:kitty"])
    out.append(f"{c[0]['x']} {c[0]['p']:.2f}")
print(" | ".join(out))
EOF
out=$(python3 -I "$tmp/hour.py")
expect_contains "by the hour: Slack after the terminal in the morning" "$out" "app:slack 0."
expect_contains "by the hour: Steam in the evening" "$out" "| app:steam 0."

# -- learning -----------------------------------------------------------------
reset
replay "[o for d in range(8) for o in ({'time': t - d * 86400 - 7200, 'kind': 'app', 'app': 'firefox'}, {'time': t - d * 86400 - 7140, 'kind': 'layout', 'name': 'coding'})]" >/dev/null
cat >"$tmp/odds.py" <<EOF
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dm", "$root/scripts/desktop-mcp.py")
dm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dm)
d = dm.read_predictions()
cue = sys.argv[2] if len(sys.argv) > 2 else "app:firefox"
c = [c for c in dm.predict_candidates(dm.load_config(), d, {"minCount": 1}, dm.time.time(), [cue]) if c["x"] == sys.argv[1]]
print(f"{c[0]['p']:.3f}" if c else "none")
EOF
odds() { python3 -I "$tmp/odds.py" "$1"; }
before=$(odds layout:coding)
out=$(dm predict observe '{"kind": "app", "app": "firefox", "lang": "en"}')
expect_eq "a layout offered" 'Next: restore the “coding” layout' "$(jq -r '.offer.chip' <<<"$out")"
expect_eq "it carries the layout" "coding" "$(jq -r '.offer.layout' <<<"$out")"
dm predict feedback "$(jq -r '.offer.id' <<<"$out")" ignored >/dev/null
ignored=$(odds layout:coding)
if python3 -c "import sys; sys.exit(0 if float(sys.argv[2]) < float(sys.argv[1]) else 1)" "$before" "$ignored"; then
  pass "let fade: its odds drop ($before -> $ignored)"
else
  fail "let fade: its odds drop" "$before -> $ignored"
fi
out=$(dm predict offer '{"lang": "en"}')
expect_contains "let fade: it rests" "$(jq -r '.why' <<<"$out")" "resting"
out=$(dm predict offer '{"lang": "en", "force": true}')
expect_eq "forced (a demo): offered past its rest" "layout:coding" "$(jq -r '.offer.action' <<<"$out")"
dm predict feedback "$(jq -r '.offer.id' <<<"$out")" dismissed >/dev/null
dismissed=$(odds layout:coding)
if python3 -c "import sys; sys.exit(0 if float(sys.argv[2]) < float(sys.argv[1]) - 0.05 else 1)" "$ignored" "$dismissed"; then
  pass "Not now: lower still ($ignored -> $dismissed)"
else
  fail "Not now: lower still" "$ignored -> $dismissed"
fi
out=$(dm predict offer '{"lang": "en", "force": true}')
dm predict feedback "$(jq -r '.offer.id' <<<"$out")" accepted >/dev/null
accepted=$(odds layout:coding)
if python3 -c "import sys; sys.exit(0 if float(sys.argv[2]) > float(sys.argv[1]) else 1)" "$dismissed" "$accepted"; then
  pass "taken: its odds go up ($dismissed -> $accepted)"
else
  fail "taken: its odds go up" "$dismissed -> $accepted"
fi
out=$(dm predict offer '{"lang": "en", "force": true}')
expect_eq "answered once only" "1" "$(
  dm predict feedback "$(jq -r '.offer.id' <<<"$out")" accepted >/dev/null
  dm predict feedback "$(jq -r '.offer.id' <<<"$out")" ignored >/dev/null
  echo $?
)"
dm predict feedback "$(jq -r '.offer.id' <<<"$out")" never >/dev/null
out=$(dm predict offer '{"lang": "en", "force": true}')
expect_eq "never: not even forced" "null" "$(jq -c '.offer' <<<"$out")"
expect_contains "never: muted after its cue" "$(dm predict show | jq -c '.muted')" "app:firefox>layout:coding"
dm predict unmute >/dev/null
out=$(dm predict offer '{"lang": "en", "force": true}')
expect_eq "unmute: offered again" "layout:coding" "$(jq -r '.offer.action' <<<"$out")"
dm predict feedback "$(jq -r '.offer.id' <<<"$out")" never_any >/dev/null
expect_contains "never anywhere: muted after any cue" "$(dm predict show | jq -c '.muted')" "*>layout:coding"

# The step in front, or just taken, is never offered.
reset
replay "[o for d in range(6) for o in ({'time': t - d * 86400 - 7200, 'kind': 'app', 'app': 'firefox'}, {'time': t - d * 86400 - 7140, 'kind': 'app', 'app': 'kitty'})]" >/dev/null
out=$(dm predict observe '{"kind": "app", "app": "firefox", "focused": "kitty", "lang": "en"}')
expect_contains "the app in front: not offered" "$(jq -r '.why' <<<"$out")" "in front already"
dm predict observe '{"kind": "app", "app": "kitty"}' >/dev/null
out=$(dm predict observe '{"kind": "app", "app": "firefox", "lang": "en"}')
expect_contains "just done: not offered again" "$(jq -r '.why' <<<"$out")" "just done"

# -- an hour's offers, quiet hours ----------------------------------------------
reset
dm predict seed "$tmp/demo.json" >/dev/null
dm predict observe '{"kind": "event", "event": "meeting_end", "title": "Daily standup", "predict": false}' >/dev/null
for _ in 1 2 3 4 5 6; do dm predict offer '{"force": true}' >/dev/null; done
out=$(dm predict observe '{"kind": "event", "event": "meeting_end", "title": "Daily standup", "minCount": 1}')
expect_contains "at most 6 offers an hour" "$(jq -r '.why' <<<"$out")" "6 offers this hour already"
reset
dm predict seed "$tmp/demo.json" >/dev/null
echo '{"initiativeQuietHours": "0-24"}' >"$tmp/cfg/nixbook-shell/desktop-mcp.json"
out=$(dm predict observe '{"kind": "event", "event": "meeting_end", "title": "Daily standup"}')
expect_eq "quiet hours: nothing offered" "quiet hours" "$(jq -r '.why' <<<"$out")"
expect_eq "quiet hours: still counted" "true" "$(jq -r '.recorded' <<<"$out")"
echo '{"initiativeQuietHours": "3-3"}' >"$tmp/cfg/nixbook-shell/desktop-mcp.json"

# -- follow-ups, policies, privacy ------------------------------------------------
reset
out=$(dm predict observe '{"kind": "event", "event": "pr_page", "repo": "didactiklabs/nixbook", "lang": "en"}')
expect_eq "a pull request opened: the review follow-up from the start" "followup:review" "$(jq -r '.offer.action' <<<"$out")"
expect_eq "it needs Muse (a model)" "true" "$(jq -r '.offer.model' <<<"$out")"
expect_contains "its order for Muse" "$(jq -r '.offer.instruction' <<<"$out")" "pull request in didactiklabs/nixbook"
expect_contains "its explain line: a built-in offer that learns" "$(jq -r '.offer.explain' <<<"$out")" "it learns"
f1=$(jq -r '.offer.id' <<<"$out")
dm predict feedback "$f1" ignored >/dev/null
for _ in 2 3; do
  out=$(dm predict observe '{"kind": "event", "event": "pr_page", "lang": "en", "force": true}')
  dm predict feedback "$(jq -r '.offer.id' <<<"$out")" ignored >/dev/null
done
expect_eq "let fade three times: the follow-up falls under the threshold (2 / (2 + 3))" "0.400" \
  "$(python3 -I "$tmp/odds.py" followup:review pr_page)"
reset
policy 2
out=$(dm predict observe '{"kind": "event", "event": "pr_page", "lang": "en"}')
expect_contains "local only (policies.ai 2): no follow-up" "$(jq -r '.why' <<<"$out")" "needs Muse online"
dm predict seed "$tmp/demo.json" >/dev/null
out=$(dm predict observe '{"kind": "event", "event": "meeting_end", "title": "Daily standup"}')
expect_eq "local only: plain steps still offered" "app:jira" "$(jq -r '.offer.action' <<<"$out")"
policy 0
out=$(dm predict observe '{"kind": "app", "app": "firefox"}')
expect_eq "AI off: nothing counted" "false|AI features are off" "$(jq -r '"\(.recorded)|\(.why)"' <<<"$out")"
policy 1
out=$(dm predict observe '{"kind": "app", "app": "org.keepassxc.KeePassXC"}')
expect_eq "a password manager: never counted" "false" "$(jq -r '.recorded' <<<"$out")"
out=$(dm predict observe '{"kind": "app", "app": "firefox", "title": "Mozilla Firefox Private Browsing"}')
expect_eq "a private window: never counted" "false" "$(jq -r '.recorded' <<<"$out")"
out=$(dm predict observe '{"kind": "url", "url": "https://github.com/didactiklabs/nixbook/pulls?q=is%3Aopen#top"}')
expect_contains "a link: kept without its query" "$(dm predict show --raw | jq -c '.recent[-1]')" '"url:https://github.com/didactiklabs/nixbook/pulls"'
expect_eq "titles never kept" "0" "$(grep -c "Private Browsing" "$file" || true)"
reset
dm predict observe '{"kind": "event", "event": "day_start"}' >/dev/null
expect_eq "the day starts once a day" "false" "$(dm predict observe '{"kind": "event", "event": "day_start"}' | jq -r '.recorded')"

# -- bounded --------------------------------------------------------------------
reset
replay "[{'time': t - 3600 + i * 2, 'kind': 'app', 'app': f'app{i}'} for i in range(400)] + [{'time': t - 600 + i, 'kind': 'app', 'app': 'hub' if i % 2 else f'leaf{i}'} for i in range(60)]" >/dev/null
expect_eq "bounded: at most 300 cues" "true" "$(dm predict show --raw | jq '(.cues | length) <= 300')"
expect_eq "bounded: at most 16 steps after one cue" "true" "$(dm predict show --raw | jq '[.cues[] | length] | max <= 16')"
expect_eq "bounded: the last 60 observations" "60" "$(dm predict show --raw | jq '.recent | length')"

# -- the CLI, the helper, agents ----------------------------------------------------
expect_eq "status" "true" "$(dm predict status | jq '.enabled and .cues > 0')"
out=$(NIXBOOK_META_AGENT_CHILD=1 dm predict seed "$tmp/demo.json" 2>&1 || echo "code $?")
expect_contains "an agent's process can't seed it" "$out" "code 126"
out=$(NIXBOOK_MUSE_TASK_ID=x dm predict observe '{"kind": "app", "app": "firefox"}' 2>&1 || echo "code $?")
expect_contains "nor feed it" "$out" "code 126"
expect_eq "an unknown offer" "1" "$(
  dm predict feedback nope accepted >/dev/null
  echo $?
)" || true
expect_eq "a bad outcome: usage" "2" "$(
  dm predict feedback x maybe >/dev/null 2>&1
  echo $?
)" || true
out=$(printf '%s\n' '{"id": 1, "argv": ["predict", "observe", "{\"kind\": \"app\", \"app\": \"firefox\"}"], "stdin": ""}' |
  timeout 20 python3 -I "$root/scripts/desktop-mcp.py" helper | grep '"id": *1' || true)
expect_eq "the shell's helper serves it" "0" "$(jq -r '.code' <<<"$out")"
cat >"$tmp/allowed.py" <<EOF
import importlib.util
spec = importlib.util.spec_from_file_location("dm", "$root/scripts/desktop-mcp.py")
dm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dm)
print(dm.helper_allowed(["predict", "observe"], stdin=True), dm.helper_allowed(["predict", "observe"], stdin=False),
      dm.helper_allowed(["predict", "seed"], stdin=True), "predict" in dm.DEFAULT_CONFIG["shellIpcDenyTargets"])
EOF
expect_eq "the helper's stdin only, never its socket; no seed; no agent IPC" "True False False True" "$(python3 -I "$tmp/allowed.py")"
dm predict clear >/dev/null
expect_eq "clear: forgotten" "false" "$([ -e "$file" ] && echo true || echo false)"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all predict tests passed"
