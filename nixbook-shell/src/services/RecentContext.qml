pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

/**
 * What the user did the last few minutes, for Muse to know without being
 * told (ai.initiative.recentContext, off by default): the windows in front,
 * a command that failed in a terminal, an error copied. In memory only,
 * never on disk; `nixbook-desktop-mcp context` filters it (private apps and
 * windows out, secrets redacted) before it is sent: with a question asked
 * in Muse's bubble (the bubble says so, and its × leaves it out), and as
 * a word when back from a break ("before the break you were on…"). The
 * filtered text is also kept in $XDG_RUNTIME_DIR/nixbook-shell/recent.txt
 * (the runtime dir: never on disk, gone at logout; empty while this is
 * off) for the context broker (`nixbook-desktop-mcp context build`, its
 * `activity` section), which every agent turn reads.
 * Also plain code, with no model call until a click:
 *   - terminal (ai.initiative.terminal): the same command failing twice in
 *     10 minutes offers "Explain it". The shell hook (hm-module.nix) writes
 *     the last failed command to terminal-failed only while terminal-on
 *     exists, made here while a switch needs it;
 *   - clipboardErrors: an error or a stack trace copied, the same;
 *   - commandFixed: a command that failed, then worked (the hook's
 *     terminal-fixed), for the desktop mascot's little jump
 *     (services/MascotState.qml), which turns the hook on too.
 * With the context triggers on (ai.reactivity.triggers.commandFailedAgain /
 * errorCopied, services/ContextTriggers.qml), those two moments are offers
 * of the reactor instead (one order on Yes): the hook and the clipboard
 * watcher run for them too, and the old "Explain it" isn't offered twice.
 * With the smart clipboard on for errors (services/SmartClipboard.qml,
 * handlesErrors), a copied error gets its chips there instead.
 */
Singleton {
    id: root

    readonly property bool enabled: Initiative.enabled && (Config.options?.ai?.initiative?.recentContext ?? false)
    readonly property bool terminal: Initiative.enabled && (Config.options?.ai?.initiative?.terminal ?? false)
    readonly property bool clipboardErrors: Initiative.enabled && (Config.options?.ai?.initiative?.clipboardErrors ?? false)
    readonly property int keepMinutes: 15
    readonly property string dir: Directories.runtimeTemp
    // {time (ms), kind: window|command|copied, app, title, command, cwd,
    // exit, text}, oldest first.
    property var events: []
    // The last ones, filtered by nixbook-desktop-mcp: what a question asked
    // in the bubble would send (shown there).
    property string text: ""

    function load() {
        Quickshell.execDetached(["rm", "-f", root.copiedPath])
        root._flag()
        root._writeRecent()
    }
    onEnabledChanged: root.enabled ? root.refresh() : root._writeRecent()

    function _add(e) {
        if (!root.enabled || GlobalStates.screenLocked || DesktopControl.active) return
        const t = Date.now()
        const kept = root.events.filter(x => t - x.time < 2 * root.keepMinutes * 60000)
        const last = kept[kept.length - 1]
        // The same window, its title changing (a tab, a file): one line.
        if (e.kind === "window" && last?.kind === "window" && last.app === e.app && t - last.time < 20000) kept.pop()
        root.events = [...kept, Object.assign({ time: t }, e)].slice(-40)
        refreshSoon.restart()
    }
    // recent.txt follows the events (a burst filtered once), and the
    // window of the last minutes moves on by itself.
    Timer {
        id: refreshSoon
        interval: 3000
        onTriggered: root.refresh()
    }
    Timer {
        interval: 2 * 60000
        running: root.enabled && root.events.length > 0
        repeat: true
        onTriggered: root.refresh()
    }
    FileView {
        id: recentFile
        path: `${root.dir}/recent.txt`
        blockWrites: true
        printErrors: false
    }
    property string _written: "\u0000"
    function _writeRecent() {
        const text = root.enabled ? root.text : ""
        if (text === root._written) return
        root._written = text
        // An empty text: the file emptied (FileView writes nothing for it).
        if (text.length === 0) Quickshell.execDetached(["bash", "-c", 'mkdir -p "$1" && : >"$1/recent.txt"', "recent", root.dir])
        else recentFile.setText(text)
    }
    // The events of the `keepMinutes` before `until` (ms), for the filter.
    function snapshot(until) {
        const end = until ?? Date.now()
        return root.events.filter(e => e.time <= end && end - e.time < root.keepMinutes * 60000)
            .map(e => Object.assign({}, e, { time: Math.round(e.time / 1000) }))
    }
    // Called up to ask: what it would send, filtered (`text`).
    function refresh() {
        const events = root.enabled ? root.snapshot() : []
        if (events.length === 0) {
            root.text = ""
            root._writeRecent()
            return
        }
        // On the helper's thread (no Python start each time).
        DesktopHelper.run(["context", JSON.stringify({ now: Math.round(Date.now() / 1000), events: events })], "", (code, out) => {
            root.text = code === 0 ? String(out ?? "").trim() : ""
            root._writeRecent()
        })
    }

    // The windows in front, and their titles as they change.
    Connections {
        target: ToplevelManager
        enabled: root.enabled
        function onActiveToplevelChanged() {
            const top = ToplevelManager.activeToplevel
            if (top) root._add({ kind: "window", app: top.appId ?? "", title: top.title ?? "" })
        }
    }
    Connections {
        target: ToplevelManager.activeToplevel
        enabled: root.enabled
        function onTitleChanged() {
            const top = ToplevelManager.activeToplevel
            if (top) root._add({ kind: "window", app: top.appId ?? "", title: top.title ?? "" })
        }
    }

    // The terminal hook writes only while a switch needs it.
    readonly property bool hookOn: root.enabled || root.terminal || ContextTriggers.commandFailedAgain || MascotState.enabled
    onHookOnChanged: root._flag()
    function _flag() {
        Quickshell.execDetached(root.hookOn ? ["bash", "-c", 'mkdir -p "$1" && touch "$1/terminal-on"', "flag", root.dir]
            : ["rm", "-f", `${root.dir}/terminal-on`, `${root.dir}/terminal-failed`, `${root.dir}/terminal-fixed`, root.copiedPath])
    }
    // A command that failed, then worked: "time\texit\tcwd\tcommand" (the
    // hook writes it when the same command succeeds after failing).
    signal commandFixed(string command)
    property string _lastFixed: ""
    FileView {
        id: fixed
        path: root.hookOn ? `${root.dir}/terminal-fixed` : ""
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const line = fixed.text().trim()
            if (!line || line === root._lastFixed) return
            const first = root._lastFixed === ""
            root._lastFixed = line
            const [time, , , ...rest] = line.split("\t")
            // One left from before the shell started: not news.
            if (first && Date.now() - Number(time) * 1000 > 60000) return
            root.commandFixed(rest.join(" ").trim())
        }
    }
    // "time\texit\tcwd\tcommand", the last failed command (overwritten).
    property string _lastLine: ""
    // A command failed in a terminal (NextUp: what came next).
    signal failedCommand(string command, string cwd)
    property var _fails: ({})
    property var _offered: ({})
    FileView {
        id: failed
        path: root.hookOn ? `${root.dir}/terminal-failed` : ""
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root._failed(failed.text().trim())
    }
    function _failed(line) {
        if (!line || line === root._lastLine) return
        const first = root._lastLine === ""
        root._lastLine = line
        const [time, exit, cwd, ...rest] = line.split("\t")
        const command = rest.join(" ").trim()
        const t = Number(time) * 1000
        // One left from before the shell started, or too old: not news.
        if (first && Date.now() - t > 60000) return
        if (!command || !cwd.startsWith("/")) return
        root._add({ kind: "command", command: command, cwd: cwd, exit: Number(exit) })
        root.failedCommand(command, cwd)
        if (!root.terminal && !ContextTriggers.commandFailedAgain) return
        const now = Date.now()
        const before = (root._fails[command] ?? []).filter(x => now - x < 10 * 60000)
        root._fails = Object.assign({}, root._fails, { [command]: [...before, now] })
        // The second time in 10 minutes, at most every half hour per command.
        if (before.length === 0 || now - (root._offered[command] ?? 0) < 30 * 60000) return
        root._offered = Object.assign({}, root._offered, { [command]: now })
        if (ContextTriggers.commandFailed(command, cwd, Number(exit))) return
        if (root.terminal)
            Initiative.consider({ event: "happened", what: "command_failed", name: command, path: cwd, exit: Number(exit) })
    }

    // An error copied. Quickshell sees the clipboard only while one of its
    // windows has the focus: wl-paste watches it instead, as cliphist does,
    // and writes a copy to the runtime dir only when it looks like an error
    // (never what a password manager copied: CLIPBOARD_STATE "sensitive").
    // nixbook-desktop-mcp does the rest (redaction, its own secret check).
    readonly property string errorish: "Traceback \\(most recent call last\\)|(error|exception|panic|fatal|failed)(\\[[[:alnum:]_-]+\\])?:"
        + "|^[[:space:]]+at [^ ]+ ?\\(.*:[0-9]+|segmentation fault|command not found|undefined reference"
        + "|no such file or directory|exit (code|status) [1-9]"
    readonly property string copiedPath: `${root.dir}/copied-error`
    Process {
        running: root.enabled || root.clipboardErrors || ContextTriggers.errorCopied
        command: ["wl-paste", "--type", "text", "--watch", "sh", "-c",
            '[ "$CLIPBOARD_STATE" = data ] || exit 0; t=$(head -c 20000); [ ${#t} -ge 20 ] || exit 0; '
            + 'printf "%s" "$t" | grep -qiE "$2" || exit 0; printf "%s" "$t" >"$1.tmp" && mv -f "$1.tmp" "$1"',
            "copied", root.copiedPath, root.errorish]
    }
    property var _copied: ({})
    FileView {
        id: copied
        path: root.enabled || root.clipboardErrors || ContextTriggers.errorCopied ? root.copiedPath : ""
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root._copiedError(copied.text())
    }
    function _copiedError(text) {
        if (text.length < 20 || DesktopControl.active) return
        const key = Qt.md5(text)
        if (root._copied[key]) return
        root._copied = Object.assign({}, root._copied, { [key]: true })
        root._add({ kind: "copied", text: text.slice(0, 400) })
        // The smart clipboard offers it (Explain it · Fix it): not twice.
        if (SmartClipboard.handlesErrors) return
        if (ContextTriggers.copied(text)) return
        if (root.clipboardErrors)
            Initiative.consider({ event: "happened", what: "copied_error", name: text.split("\n").find(l => /error|exception|panic|fatal|failed/i.test(l)) ?? "",
                                  text: text.slice(0, 3000) })
    }
}
