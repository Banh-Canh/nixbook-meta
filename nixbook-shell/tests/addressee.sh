#!/usr/bin/env bash
# Was it said to Muse? Full AI mode's plain-code rules
# (src/modules/common/functions/addressee.js, QML's `.pragma library`
# JavaScript) under node: its name in the four languages, other people's,
# answers, stop words, calls, fillers, the reply windows, the modes, speed.
# The model's part is in quick-ai.sh (the addressee mode).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v node >/dev/null; then
  node "$here/addressee-tests.js"
else
  nix-shell -p nodejs --run "node '$here/addressee-tests.js'"
fi
