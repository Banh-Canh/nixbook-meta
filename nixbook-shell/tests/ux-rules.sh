#!/usr/bin/env bash
# Muse's plain-code UX rules (src/modules/common/functions/: step_labels.js,
# offer_cues.js, theme_moods.js — QML's `.pragma library` JavaScript) under
# node: steps in words (never a server id, a tool name, a path), one offer
# per moment, a theme by its mood; the four languages; their speed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v node >/dev/null; then
  node "$here/ux-rules-tests.js"
else
  nix-shell -p nodejs --run "node '$here/ux-rules-tests.js'"
fi
