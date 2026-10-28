pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Muse in the terminal and the editor (ai.terminal; nixbook-desktop-mcp's
 * `terminal` tools do the work, over kitty's remote control socket —
 * homeManagerModules/kittyConfig.nix — and nvim's server socket):
 *   - which switches are on (`read`, `suggest`, `run`, `runVisible`,
 *     `editor`, `context`; nothing with policies.ai 0);
 *   - what is in front: a kitty window (`frontIsTerminal`) or Neovim
 *     (`frontIsEditor`: in kitty, or a GUI front end), for the bubble's
 *     "Ask about this terminal…";
 *   - a terminal_run waiting for the user's OK (`runApproval(approval)` ->
 *     {command, cwd, visible} or null), shown with the command in
 *     monospace and its folder (TerminalNotes);
 *   - `focusMuseTab()`: Muse's own kitty tab ("Muse", where terminal_run
 *     runs with runVisible) brought to the front: the tab in its kitty, then
 *     that kitty's window in niri.
 */
Singleton {
    id: root

    readonly property bool aiOn: (Config.options?.policies?.ai ?? 1) !== 0
    readonly property var cfg: Config.options?.ai?.terminal ?? ({})
    readonly property bool read: root.aiOn && (root.cfg.read ?? true)
    readonly property bool suggest: root.aiOn && (root.cfg.suggest ?? true)
    readonly property bool run: root.aiOn && (root.cfg.run ?? true)
    readonly property bool runVisible: root.run && (root.cfg.runVisible ?? true)
    readonly property bool editor: root.aiOn && (root.cfg.editor ?? true)
    readonly property bool context: root.aiOn && (root.cfg.context ?? true)

    // The window in front: the focused one, else (the bubble has the keys,
    // a layer surface) the one focused last.
    readonly property var frontWindow: {
        const ws = WM.windowList ?? [];
        return ws.find(w => w.focused) ?? ws.slice().sort((a, b) => (b.focusedAt ?? 0) - (a.focusedAt ?? 0))[0] ?? null;
    }
    readonly property bool frontIsKitty: /^kitty$/i.test(root.frontWindow?.appId ?? "")
    // Neovim: a GUI front end, or kitty whose title is the nvim command
    // (shell integration titles a window with what runs in it).
    readonly property bool frontIsEditor: /^(neovide|nvim-qt|org\.neovim\..*)$/i.test(root.frontWindow?.appId ?? "")
        || (root.frontIsKitty && /(^|[\s\/:])n?vim(\s|$)/.test(root.frontWindow?.title ?? ""))
    readonly property bool frontIsTerminal: root.frontIsKitty && !root.frontIsEditor
    // Muse can see what is in front (the bubble's hint).
    readonly property bool seesFront: (root.frontIsTerminal && (root.read || root.context))
        || (root.frontIsEditor && (root.editor || root.context))

    // A step waiting for the user's OK that runs a command: what it runs.
    function runApproval(approval) {
        if (!approval || String(approval.tool ?? "") !== "terminal_run") return null;
        const input = approval.input ?? {};
        const command = String(input.command ?? "");
        if (command.length === 0) return null;
        return { command: command, cwd: String(input.cwd ?? ""), visible: root.runVisible && input.visible !== false };
    }

    // "Ran `cmd` (exit N)": the command on one line, short.
    function shortCommand(command, max) {
        const s = String(command ?? "").replace(/\s+/g, " ").trim();
        const m = max ?? 60;
        return s.length > m ? s.slice(0, m - 1) + "…" : s;
    }

    // -- Muse's tab -----------------------------------------------------------
    property bool focusing: false
    // Why the last "Muse's tab" click did nothing ("" = it worked).
    property string focusError: ""
    function focusMuseTab() {
        if (root.focusing) return;
        root.focusError = "";
        root.focusing = true;
        focusProc.running = true;
    }
    Process {
        id: focusProc
        // Each kitty listens on $XDG_RUNTIME_DIR/kitty-<pid>.sock: the one
        // with a tab titled Muse focuses it, then niri its window (same pid).
        command: ["bash", "-c", `
d=\${XDG_RUNTIME_DIR:-}
[ -n "$d" ] || exit 2
command -v kitty >/dev/null 2>&1 || exit 3
for s in "$d"/kitty-*.sock; do
  [ -S "$s" ] || continue
  if kitty @ --to "unix:$s" focus-tab --match 'title:^Muse$' >/dev/null 2>&1; then
    pid=\${s##*/kitty-}; pid=\${pid%.sock}
    case "$pid" in ''|*[!0-9]*) exit 0 ;; esac
    id=$(niri msg --json windows 2>/dev/null | jq -r --argjson p "$pid" 'first(.[] | select(.pid == $p) | .id) // empty')
    [ -n "$id" ] && niri msg action focus-window --id "$id"
    exit 0
  fi
done
exit 1`]
        onExited: (code, status) => {
            root.focusing = false;
            root.focusError = code === 0 ? "" : code === 3 ? Translation.tr("kitty isn't installed")
                : Translation.tr("Muse's tab isn't open");
        }
    }
}
