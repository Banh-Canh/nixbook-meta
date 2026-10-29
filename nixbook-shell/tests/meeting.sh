#!/usr/bin/env bash
# Tests for the meeting companion (scripts/meeting.py, `nixbook-meeting`)
# and the caption streams it runs (scripts/voice-stream.py --segments),
# against a fake Meta (tests/fake-meeting.py: the realtime ASR WebSocket and
# the Messages API on one port) and WAV files instead of the audio:
#   - the captions: both sides' streams, partials and finals labelled them /
#     you, voice-stream's hello (model, mode, language hint);
#   - the translation of the lines in another language (only those), the
#     running notes, the record (the big model) — every text sent masked,
#     everything printed unmasked;
#   - the transcript file (0600 in a 0700 folder), list / show / prune;
#   - nothing with AI off (policies.ai 0) or the companion off;
#   - desktop-mcp's read-only meeting_notes tool on the saved meeting.
# Needs bash, python3 and jq. Run: bash tests/meeting.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/meeting.py"
tmp="$(mktemp -d)"
server=""
trap '[ -z "$server" ] || kill "$server" 2>/dev/null; rm -rf "$tmp"' EXIT

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

# Two seconds of a constant sample: 1000 is the call, 2000 the microphone
# (the fake server picks its script by it).
python3 - "$tmp" <<'EOF'
import struct, sys
for name, value in (("call", 1000), ("mic", 2000)):
    data = struct.pack("<h", value) * 32000
    with open(f"{sys.argv[1]}/{name}.wav", "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
                + b"data" + struct.pack("<I", len(data)) + data)
EOF

python3 "$root/tests/fake-meeting.py" "$tmp/port" "$tmp/log.jsonl" &
server=$!
for _ in $(seq 50); do
  [ -s "$tmp/port" ] && break
  sleep 0.1
done
port=$(cat "$tmp/port")

# desktop-mcp's privacy mask and sent log, as a stub: "Alice" is hidden.
mkdir -p "$tmp/bin" "$tmp/runtime" "$tmp/config"
cat >"$tmp/bin/nixbook-desktop-mcp" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
"privacy mask") sed 's/Alice/⟦Person 1⟧/g' ;;
"privacy unmask") sed 's/⟦Person 1⟧/Alice/g' ;;
"sent note") printf "%s\t%s\n" "$3" "$5" >>"$SENT_LOG" ;;
*) exit 127 ;;
esac
EOF
chmod +x "$tmp/bin/nixbook-desktop-mcp"
echo '{"policies": {"ai": 1}, "ai": {"meeting": {"enable": true}}}' >"$tmp/config/on.json"

export PATH="$tmp/bin:$PATH" SENT_LOG="$tmp/sent.log"
export XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" XDG_RUNTIME_DIR="$tmp/runtime"
export NIXBOOK_SHELL_CONFIG="$tmp/config/on.json"
export NIXBOOK_AI_KEY=test-key NIXBOOK_AI_BASE_URL="http://127.0.0.1:$port" NIXBOOK_AI_PROVIDED=1
export NIXBOOK_AI_MODEL=main-m NIXBOOK_AI_SMALL_MODEL=small-m NIXBOOK_AI_BIG_MODEL=big-m NIXBOOK_AI_LABEL=Meta
export NIXBOOK_AI_RETRIES=0 NIXBOOK_MEETING_TRANSLATE_EVERY=0.5
unset NIXBOOK_VOICE_STREAM

# -- voice-stream as the voice uses it (no --segments): one utterance --------
timeout 30 python3 -I "$root/scripts/voice-stream.py" --file "$tmp/call.wav" --lang en </dev/null >"$tmp/voice.jsonl" 2>&1 ||
  fail "voice-stream without --segments ends well" "$(cat "$tmp/voice.jsonl")"
expect_eq "without --segments: the turns make one final" \
  "Bonjour à tous, on commence. Alice will send the report by Friday." \
  "$(jq -rs '[.[] | select(.type == "final")] | map(.text) | join("|")' "$tmp/voice.jsonl")"
expect_eq "without --segments: the meter is there" "true" \
  "$(jq -s '[.[] | select(.type == "level")] | length > 0' "$tmp/voice.jsonl")"
: >"$tmp/log.jsonl"

# -- A call -------------------------------------------------------------------
# The files end after 2 s, then the streams: the meeting ends by itself
# (stdin held open meanwhile, as the shell does).
sleep 6 | timeout 60 python3 -I "$script" run --title "Weekly sync" --mic --translate en --lang fr,en \
  --notes-every 1 --monitor-file "$tmp/call.wav" --mic-file "$tmp/mic.wav" >"$tmp/run.jsonl" 2>"$tmp/run.err" ||
  fail "the run ends well" "$(cat "$tmp/run.err")"
events="$tmp/run.jsonl"

expect_eq "it says where the transcript is" "1" "$(jq -s '[.[] | select(.type == "started" and (.path | test("/meetings/")))] | length' "$events")"
expect_eq "both sides are up" "them,you" "$(jq -rs '[.[] | select(.type == "ready") | .who] | sort | join(",")' "$events")"
expect_eq "the call's words show as they come" "true" \
  "$(jq -s '[.[] | select(.type == "partial" and .who == "them" and .text == "Bonjour à tous")] | length > 0' "$events")"
expect_eq "each turn is its own caption line" \
  "them:Bonjour à tous, on commence.|them:Alice will send the report by Friday.|you:I agree, we ship it on Monday then." \
  "$(jq -rs '[.[] | select(.type == "final")] | sort_by(.who) | map("\(.who):\(.text)") | join("|")' "$events")"
expect_eq "the French line is translated" "Hello everyone, let's start." \
  "$(jq -rs '[.[] | select(.type == "final" and (.text | startswith("Bonjour")))][0].i as $i
     | [.[] | select(.type == "translation" and .i == $i)][0].text' "$events")"
expect_eq "only that one" "1" "$(jq -s '[.[] | select(.type == "translation")] | length' "$events")"
expect_eq "the running notes, with the real name" "Alice" \
  "$(jq -rs '[.[] | select(.type == "notes")][-1].notes.actions[0].owner' "$events")"
expect_eq "the record, with the real name" "Thanks all. Alice sends the report by Friday." \
  "$(jq -rs '[.[] | select(.type == "summary")][0].summary.followup.body' "$events")"
expect_eq "the record's decisions" "Ship on Monday" "$(jq -rs '[.[] | select(.type == "summary")][0].summary.decisions[0]' "$events")"
expect_eq "it ends last" "ended" "$(jq -rs '.[-1].type' "$events")"

log="$tmp/log.jsonl"
expect_eq "voice-stream's sessions: Meta's transcriber, end of turn by the server" \
  "muse-voice-transcribe-1.0 ENDPOINTING French,English" \
  "$(jq -rs '[.[] | select(.kind == "asr")][0].hello | "\(.model) \(.mode) \(.languageBias | join(","))"' "$log")"
expect_eq "with the provider's key" "Bearer test-key" "$(jq -rs '[.[] | select(.kind == "asr")][0].hello.authorization.accessToken' "$log")"
msgs() { jq -c 'select(.kind == "messages" and (.path | startswith("/v1/messages")))' "$log"; }
expect_eq "the translation and the notes on the small model" "small-m" \
  "$(msgs | jq -rs '[.[] | select(.body.system | test("translate the live captions|running notes of a call")) | .body.model] | unique | join(",")')"
expect_eq "the record on the big model (Muse Wonder)" "big-m" \
  "$(msgs | jq -rs '[.[] | select(.body.system | test("The call is over")) | .body.model] | unique | join(",")')"
expect_eq "no name reaches the model" "0" "$(msgs | grep -c 'Alice' || true)"
expect_eq "the hidden person did" "true" "$(msgs | grep -q '⟦Person 1⟧' && echo true || echo false)"
expect_eq "what was sent is in the sent log" "meeting notes,meeting record,meeting translation" \
  "$(cut -f1 "$tmp/sent.log" | sort -u | paste -sd,)"
expect_eq "with the model each went to" "Meta:big-m,Meta:small-m" "$(cut -f2 "$tmp/sent.log" | sort -u | paste -sd,)"

file=$(jq -rs '[.[] | select(.type == "started")][0].path' "$events")
expect_eq "the transcript is the user's alone" "600 700" "$(stat -c %a "$file") $(stat -c %a "$(dirname "$file")")"
expect_eq "it keeps every line, the translation and the record" "3 Hello everyone, let's start. Weekly sync" \
  "$(jq -r '"\(.lines | length) \([.lines[] | .tr // empty][0]) \(.summary.title)"' "$file")"

# -- list, show, prune --------------------------------------------------------
expect_eq "list" "Weekly sync 3" "$(python3 -I "$script" list --json | jq -r '.[0] | "\(.title) \(.lines)"')"
out=$(python3 -I "$script" show last)
case "$out" in
*"Action items:"*"Send the report (Alice), Friday"*) pass "show: the record as text" ;;
*) fail "show: the record as text" "$out" ;;
esac
expect_eq "show --json leaves the transcript out" "null" "$(python3 -I "$script" show last --json | jq '.lines')"
old="$XDG_STATE_HOME/nixbook-shell/meetings/old.json"
echo '{"id": "old", "started": 1000, "lines": []}' >"$old"
expect_eq "prune: the old one goes" "1" "$(python3 -I "$script" prune --keep-days 30)"
expect_eq "prune: the new one stays" "1" "$(python3 -I "$script" list --json | jq length)"

# -- desktop-mcp's meeting_notes ---------------------------------------------
out=$(python3 -I "$root/scripts/desktop-mcp.py" call meeting_notes '{"query": "report"}' 2>&1) || true
case "$out" in
*"Weekly sync"*"Send the report"*) pass "meeting_notes reads the saved meeting" ;;
*) fail "meeting_notes reads the saved meeting" "$out" ;;
esac

# -- Never with AI off --------------------------------------------------------
: >"$log"
echo '{"policies": {"ai": 0}}' >"$tmp/config/off.json"
NIXBOOK_SHELL_CONFIG="$tmp/config/off.json" python3 -I "$script" run --monitor-file "$tmp/call.wav" </dev/null >"$tmp/off.jsonl" 2>&1 || true
expect_eq "AI off: refused" "error" "$(jq -rs '.[0].type' "$tmp/off.jsonl")"
echo '{"policies": {"ai": 1}, "ai": {"meeting": {"enable": false}}}' >"$tmp/config/disabled.json"
NIXBOOK_SHELL_CONFIG="$tmp/config/disabled.json" python3 -I "$script" run --monitor-file "$tmp/call.wav" </dev/null >"$tmp/disabled.jsonl" 2>&1 || true
expect_eq "companion off: refused" "error" "$(jq -rs '.[0].type' "$tmp/disabled.jsonl")"
expect_eq "nothing was heard nor sent" "0" "$(wc -l <"$log" | tr -d ' ')"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all meeting companion tests passed"
