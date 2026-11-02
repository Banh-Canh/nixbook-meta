#!/usr/bin/env bash
# "Read this to me" (nixbook-desktop-mcp read-aloud): a window's content in
# reading order from a fake accessibility tree (embedded objects in their
# place, controls and hidden parts left out, a web view's document first),
# the page tools first for Zen and the bridged apps, terminals and password
# managers refused, the capture fallback, the command refused to agents,
# and the phrases in Muse's bubble (read-intent-tests.js, node).
# Needs python3. Run: bash tests/read-aloud.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export XDG_RUNTIME_DIR="$tmp/run" XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config"
export XDG_DATA_HOME="$tmp/data" NIRI_SOCKET=/dev/null
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

python3 - "$root/scripts/desktop-mcp.py" <<'EOF'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("dm", sys.argv[1])
dm = importlib.util.module_from_spec(spec)
sys.argv = ["x"]
spec.loader.exec_module(dm)
failures = 0


def check(what, ok, got=None):
    global failures
    if ok:
        print(f"ok   - {what}")
    else:
        failures += 1
        print(f"FAIL - {what}\n       {got!r}")


class States:
    def __init__(self, s):
        self.s = set(s)

    def contains(self, x):
        return x in self.s


class Node:
    def __init__(self, role, text=None, children=(), name="", states=("visible", "showing")):
        self.role, self.text, self.children, self.name, self.states = role, text, list(children), name, states

    def get_state_set(self):
        return States(self.states)

    def get_role_name(self):
        return self.role

    def get_child_count(self):
        return len(self.children)

    def get_child_at_index(self, i):
        return self.children[i]

    def get_text_iface(self):
        return self if self.text is not None else None

    def get_name(self):
        return self.name


class Atspi:
    class StateType:
        VISIBLE, SHOWING = "visible", "showing"

    class Text:
        @staticmethod
        def get_character_count(n):
            return len(n.text)

        @staticmethod
        def get_text(n, a, b):
            return n.text[a:b]


E = "￼"
link = Node("link", "the docs")
para = Node("paragraph", f"Read {E} before you start.", [link])
heading = Node("heading", "Welcome")
offscreen = Node("paragraph", "Further down the page.", states=("visible",))
hidden = Node("paragraph", "display none", states=())
img = Node("image", name="A red bicycle")
doc = Node("document web", E * 5, [heading, para, offscreen, img, hidden])
toolbar = Node("tool bar", children=[Node("push button", name="Back"), Node("entry", "https://example.org")])
other_tab = Node("page tab", children=[Node("label", "Another tab's page")], states=("visible",))
frame = Node("frame", children=[toolbar, Node("panel", children=[doc]), other_tab], name="Example")

text = dm.read_aloud_collect(Atspi, doc)
check("a document: in reading order, a link in its sentence", text ==
      "Welcome\nRead the docs before you start.\nFurther down the page.\nImage: A red bicycle.", text)
check("the document found in the window", dm.read_aloud_document(Atspi, frame) is doc)
whole = dm.read_aloud_collect(Atspi, frame)
check("a window: buttons, fields and another tab's page left out",
      "Back" not in whole and "example.org" not in whole and "Another tab" not in whole and "Welcome" in whole, whole)
labels = Node("frame", children=[Node("label", "Battery"), Node("label", "82%"), Node("push button", name="OK"),
                                 Node("label", "82%"), Node("password text", "hunter2")])
check("a dialog: its labels, one per line, a repeated line once, no password",
      dm.read_aloud_collect(Atspi, labels) == "Battery\n82%", dm.read_aloud_collect(Atspi, labels))
check("capped", len(dm.read_aloud_collect(Atspi, Node("frame", children=[Node("label", "x" * 50000)]), cap=1000)) <= 1000)

# The flow: page tools first, then the tree, then a capture.
cfg = dm.load_config()
win = {"id": 7, "app_id": "zen", "title": "Example — Zen", "pid": 1}
dm.focused_window = lambda: dict(win)
dm.window_by_id = lambda wid: dict(win)
dm.bridged_apps = lambda: ["actual"]
calls = []


def fake_zen(ctx, cmd, **kw):
    calls.append(("zen", cmd, kw))
    return {"text": "The page's text.", "selection": ""}


dm.zen = fake_zen
r = dm.read_aloud(cfg)
check("Zen: through the page", r["source"] == "zen" and r["text"] == "The page's text." and calls[0][1] == "read", r)
dm.zen = lambda ctx, cmd, **kw: {"text": "All of it.", "selection": "Just this."}
check("Zen: the selection when there is one", dm.read_aloud(cfg)["text"] == "Just this.")
win.update(app_id="Actual", title="Actual Budget")
dm.electron = lambda ctx, app, cmd, **kw: calls.append((app, cmd)) or {"text": "Budget: November"}
r = dm.read_aloud(cfg)
check("a bridged app: through its page", r["source"] == "actual" and calls[-1] == ("actual", "read"), r)
win.update(app_id="org.gnome.Calculator", title="Calculator")
dm.ui_read_aloud = lambda w: "Result 42"
check("another app: its accessibility tree", dm.read_aloud(cfg) == {
    "app": "org.gnome.Calculator", "title": "Calculator", "window": 7, "source": "accessibility", "text": "Result 42"})
dm.ui_read_aloud = lambda w: ""
r = dm.read_aloud(cfg)
check("no text anywhere: said, no capture unasked", r["source"] == "none" and "image" not in r, r)
dm.capture_window_file = lambda ctx, wid, max_edge=None: (f"/run/shot-{wid}.jpg", (800, 600))
r = dm.read_aloud(cfg, capture=True)
check("--capture: the window's picture for the vision model", r["source"] == "screen" and r["image"] == "/run/shot-7.jpg", r)
dm.ui_read_aloud = lambda w: "Result 42"
r = dm.read_aloud(cfg, picture=True)
check("--picture (Describe this): the capture only, its text not read", r["source"] == "screen" and "text" not in r, r)
for app_id in ("kitty", "org.keepassxc.KeePassXC"):
    win.update(app_id=app_id, title="x")
    try:
        dm.read_aloud(cfg, capture=True)
        check(f"{app_id}: refused", False, "read")
    except dm.ToolError as e:
        check(f"{app_id}: refused, never captured either", "off limits" in str(e) or "never" in str(e), str(e))
sys.exit(1 if failures else 0)
EOF

out=$(NIXBOOK_META_AGENT_CHILD=1 python3 "$root/scripts/desktop-mcp.py" read-aloud 2>&1 || true)
if grep -qF "refused: only the user" <<<"$out"; then
  echo "ok   - read-aloud: refused to an agent's process"
else
  echo "FAIL - read-aloud: refused to an agent's process"
  echo "       $out"
  exit 1
fi
# The phrases in Muse's bubble (QuickIntent.qml), four languages.
if command -v node >/dev/null; then
  node "$root/tests/read-intent-tests.js"
else
  nix-shell -p nodejs --run "node '$root/tests/read-intent-tests.js'"
fi
echo "all read-aloud tests passed"
