#!/usr/bin/env bash
# Project contexts and teach mode (scripts/desktop-mcp.py: project_* tools,
# `project` and `teach` commands), against a fake niri, Zen bridge, kitty,
# shell and model (tests/projects-tests.py), plus the bubble's plain-code
# phrases for them (src/modules/common/functions/project_intent.js, node):
#   - a project saved: its hidden layout, the tabs of its Zen window (not
#     pinned, private or another workspace's), its terminals' folders (not
#     the home nor a hidden folder), its options; 0600;
#   - opened: terminals in their folders, the layout, the tabs not open (in
#     the background), DND and the focus timer; nothing opened twice; Zen
#     started for its tabs; its Undo; refused on the agent desktop;
#   - paused: saved, then its rule (tabs, close: only idle terminals), DND
#     and the timer back as they were; an agent can't choose `close`;
#   - teach mode: what is recorded and what never is (password managers,
#     secrets, an agent's input, non-web links), the steps in plain code,
#     one masked model call choosing among them, its variables checked,
#     saved as the user's recipe; the user's commands only.
# Needs bash, python3 and node. Run: bash tests/projects.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/state" "$tmp/cfg/nixbook-shell" "$tmp/run" "$tmp/home" "$tmp/data/applications"
chmod 700 "$tmp/run"
export XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/cfg" XDG_RUNTIME_DIR="$tmp/run" HOME="$tmp/home"
export XDG_DATA_HOME="$tmp/data" XDG_DATA_DIRS="$tmp/none"
export NIXBOOK_PRIVACY_PSEUDONYMS=0
unset NIXBOOK_MUSE_TASK_ID NIXBOOK_META_AGENT_CHILD NIXBOOK_DESKTOP_MCP_NO_TASKS NIXBOOK_DESKTOP_MCP_CONFIG
unset NIRI_SOCKET

status=0
python3 -I "$root/tests/projects-tests.py" "$root/scripts/desktop-mcp.py" || status=1
if command -v node >/dev/null; then
  node "$root/tests/project-intent-tests.js" || status=1
else
  nix-shell -p nodejs --run "node '$root/tests/project-intent-tests.js'" || status=1
fi
exit "$status"
