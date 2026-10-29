pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Setting up the desktop by talking (modules/ii/nixOnboarding/): a short
 * conversation with the provider's model (Meta: muse-spark) about who the
 * user is and how they want their desktop, then a Nix configuration it
 * writes and `nixbook-nix-onboard` (scripts/nix-onboard.py) checks with Nix
 * itself — parsed, and the shell's settings evaluated against their typed
 * options — the errors handed back to the model until it passes. The
 * result can be copied, filed for the desktop agent's fixer to build into
 * the configuration (nixbook-improve request), or its shell settings
 * applied at once (live, not declarative; keys set in Nix are skipped).
 * IPC target `nixOnboarding`: open, close, toggle, say TEXT.
 */
Singleton {
    id: root
    // Referenced at startup (shell.qml): its IPC target exists from the start.
    function load() {}

    readonly property bool available: QuickAi.available
    property bool open: false
    // The conversation: [{role: user|assistant|check|fix|error, text}].
    property var messages: []
    property bool busy: false
    // What runs now ("Checking with nix-instantiate… round 2").
    property string status: ""
    // The last configuration: {nix, where, explanation, checked, shell,
    // settings, blocks}.
    property var config: null
    property string applied: ""
    // nixbook-improve on PATH, and its features on: "Build it for me".
    property bool improveFound: false
    readonly property bool canBuild: root.improveFound && (Config.options.ai.improve?.enable ?? false)
        && (Config.options.ai.improve?.features?.enable ?? false)

    function openWindow() {
        if (!root.available) {
            QuickAi.refuse();
            return;
        }
        root.open = true;
        improveProbe.running = true;
        if (root.messages.length === 0) root.send(Translation.tr("Hi! Help me set up my desktop."), true);
    }
    function close() {
        root.open = false;
    }
    function reset() {
        root.stop();
        root.messages = [];
        root.config = null;
        root.applied = "";
        root.status = "";
        if (root.open) root.send(Translation.tr("Hi! Help me set up my desktop."), true);
    }
    // A message from the user (`hidden`: the opening one, not shown).
    function send(text, hidden = false, now = false) {
        const t = String(text ?? "").trim();
        if (t.length === 0 || root.busy) return;
        const convo = root.messages.slice();
        convo.push({ role: "user", text: t, hidden: hidden });
        root.messages = convo;
        const req = {
            messages: convo.filter(m => m.role === "user" || m.role === "assistant").map(m => ({ role: m.role, text: m.text })),
            lang: ConfigAssistant.uiLang(), user: Quickshell.env("USER") ?? "", now: now,
        };
        root.busy = true;
        root.status = Translation.tr("Thinking…");
        proc.serial++;
        proc.requestJson = JSON.stringify(req);
        proc.running = true;
    }
    // "Write it now": no more questions.
    function writeNow() {
        root.send(Translation.tr("That's all, write the configuration now."), false, true);
    }
    function stop() {
        if (proc.running) {
            proc.serial++;
            proc.running = false;
        }
        root.busy = false;
        root.status = "";
    }
    function add(role, text) {
        if (!text) return;
        root.messages = root.messages.concat([{ role: role, text: text }]);
    }

    function copy() {
        if (root.config?.nix) Quickshell.execDetached(["wl-copy", "--", root.config.nix]);
    }
    // Filed for the desktop agent's fixer, which builds it into the
    // configuration on a branch and opens a pull request.
    function buildIt() {
        if (!root.config?.nix || !root.canBuild) return;
        const text = Translation.tr("Add this configuration (written with the user and checked with nix-instantiate):") + "\n\n"
            + root.config.explanation + "\n\n```nix\n" + root.config.nix + "\n```";
        Quickshell.execDetached(["nixbook-improve", "request", text, "--where", root.config.where || "profiles"]);
        root.applied = Translation.tr("Filed for the desktop agent's fixer: it builds it on a branch and opens a pull request (Settings > Desktop agents).");
    }
    // The shell settings, set now in the running shell: not declarative (the
    // next Nix switch keeps them only because Nix doesn't set them), and the
    // keys set in Nix are left alone.
    function applyNow() {
        const s = root.config?.settings;
        if (!s) return;
        const leaves = NixManaged.leafEntries(s, "", []);
        let done = 0;
        const skipped = [];
        for (const [path, value] of leaves) {
            if (NixManaged.isPinned(path)) {
                skipped.push(path);
                continue;
            }
            Config.setNestedValue(path, value);
            done++;
        }
        Config.save();
        root.applied = skipped.length > 0
            ? Translation.tr("Applied %1 settings now (not in your Nix files). Set in Nix, left alone: %2").arg(done).arg(skipped.join(", "))
            : Translation.tr("Applied %1 settings now. They live in the shell's settings, not in your Nix files: use \"Build it for me\" or paste the Nix to keep them declarative.").arg(done);
    }

    Process {
        id: improveProbe
        command: ["bash", "-c", "command -v nixbook-improve"]
        onExited: (code) => root.improveFound = code === 0
    }

    Process {
        id: proc
        property int serial: 0
        property int mine: 0
        property string requestJson: "{}"
        onRunningChanged: if (running) mine = serial
        command: ["bash", "-c", QuickAi.modelRun + 'dir="${XDG_RUNTIME_DIR:-/tmp}/nixbook-shell/nix-onboard"; mkdir -p -m 700 "$dir"; '
            + 'f="$dir/request-$$.json"; trap \'rm -f "$f"\' EXIT; printf "%s" "$1" > "$f"; '
            + 'model nixbook-nix-onboard turn "$f"', "_", proc.requestJson]
        stdout: SplitParser {
            onRead: (line) => {
                if (proc.mine !== proc.serial) return;
                let ev;
                try { ev = JSON.parse(line); } catch (e) {
                    if (line.trim().length > 0) root.add("error", line.trim());
                    return;
                }
                switch (ev.type) {
                case "say":
                    root.add("assistant", ev.text);
                    break;
                case "checking":
                    root.status = ev.round > 1
                        ? Translation.tr("Checking with nix-instantiate… round %1").arg(ev.round)
                        : Translation.tr("Checking with nix-instantiate…");
                    break;
                case "check":
                    root.add("check", ev.ok
                        ? Translation.tr("✓ Checked by Nix (round %1, %2 ms)").arg(ev.round).arg(ev.ms ?? 0)
                        : Translation.tr("✗ Round %1: %2").arg(ev.round).arg(ev.errors));
                    if (!ev.ok) root.status = Translation.tr("Round %1 failed: fixing it…").arg(ev.round);
                    break;
                case "fix":
                    root.add("fix", ev.text);
                    break;
                case "config":
                    root.config = ev;
                    root.applied = "";
                    break;
                case "error":
                    root.add("error", ev.error);
                    break;
                }
            }
        }
        stderr: SplitParser {
            onRead: (line) => {
                if (proc.mine === proc.serial && /nixbook-model-provider:/.test(line))
                    root.add("error", line.replace(/^nixbook-model-provider:\s*/, ""));
            }
        }
        onExited: (code) => {
            if (proc.mine !== proc.serial) return;
            root.busy = false;
            root.status = "";
        }
    }

    IpcHandler {
        target: "nixOnboarding"
        function open(): void { root.openWindow(); }
        function close(): void { root.close(); }
        function toggle(): void { if (root.open) root.close(); else root.openWindow(); }
        function say(text: string): void { root.openWindow(); root.send(text); }
        function status(): string {
            return JSON.stringify({ open: root.open, busy: root.busy, status: root.status, messages: root.messages.length,
                config: root.config ? { checked: root.config.checked, where: root.config.where } : null });
        }
    }
}
