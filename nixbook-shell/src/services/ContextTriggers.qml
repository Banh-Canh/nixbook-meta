pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

/**
 * Offers before being asked (ai.reactivity.triggers): moments the shell sees
 * where one concrete order would help, sent to the one event reactor
 * (services/Reactor.qml) as events of their own. The initiative's `consider`
 * (nixbook-desktop-mcp) words each as an offer ("That command failed twice —
 * want me to look into it?") with the order Muse would do on Yes, within the
 * day's budget and quiet rules. Each kind has its switch and a cooldown:
 *   - command_failed_again {command, error}: the same command failed twice
 *     in 10 minutes in a terminal (RecentContext's shell hook);
 *   - error_copied {text}: what was copied looks like an error or a stack
 *     trace (two lines or more saying Error, Exception, Traceback, panic,
 *     failed, or "at …:line");
 *   - returning_window {app, title, times}: the same window gone back to 4
 *     times or more in 30 minutes;
 *   - meeting_soon {title, start, link}: an event with a link starting in 5
 *     minutes or less (once per event);
 *   - error_dialog {app, title}: a window in front whose title says error /
 *     failed / erreur / Fehler / lỗi, still there after 20 s.
 * Never while locked, while an agent drives the desktop, nor with AI off or
 * local only (an offer is an order for Muse). "Never for this" in the bubble
 * mutes the trigger (that kind, and the command or window it was about) for
 * 30 days (`mute`, kept in $XDG_STATE_HOME/nixbook-shell/triggers.json) and
 * tells the one memory.
 */
Singleton {
    id: root
    function load() {
        stateFile.reload()
    }

    readonly property var triggers: Config.options?.ai?.reactivity?.triggers ?? ({})
    readonly property bool active: Initiative.enabled && Initiative.online && (Config.options?.policies?.ai ?? 1) === 1
    readonly property bool commandFailedAgain: root.active && (root.triggers.commandFailedAgain ?? true)
    readonly property bool errorCopied: root.active && (root.triggers.errorCopied ?? true)
    readonly property bool returningWindow: root.active && (root.triggers.returningWindow ?? true)
    readonly property bool meetingSoon: root.active && (root.triggers.meetingSoon ?? true)
    readonly property bool errorDialog: root.active && (root.triggers.errorDialog ?? true)
    readonly property int cooldownMinutes: 30

    // "kind|key" -> until (ms): muted ("Never for this"); the kind alone
    // ("kind|") mutes all of it.
    property var muted: ({})
    // "kind|key" -> last sent (ms): the cooldown.
    property var _sent: ({})
    // What it offered lately, newest last (Settings): {time, kind, key, sent}.
    property var recent: []

    function _key(kind, key) {
        return `${kind}|${String(key ?? "").slice(0, 200)}`
    }
    function isMuted(kind, key) {
        const t = Date.now()
        return (root.muted[root._key(kind, "")] ?? 0) > t || (root.muted[root._key(kind, key)] ?? 0) > t
    }
    // An error copied and a meeting are each new every time: muted as a kind.
    readonly property var mutedAsKind: ["error_copied", "meeting_soon"]
    function mute(kind, key, days) {
        const until = Date.now() + Math.max(1, days ?? 30) * 86400000
        const kept = {}
        for (const k in root.muted) if (root.muted[k] > Date.now()) kept[k] = root.muted[k]
        kept[root._key(kind, root.mutedAsKind.includes(kind) ? "" : key)] = until
        root.muted = kept
        root._save()
    }
    function unmuteAll() {
        root.muted = {}
        root._save()
    }
    function _save() {
        Quickshell.execDetached(["bash", "-c", 'mkdir -p "${1%/*}" && printf "%s" "$2" >"$1.tmp" && mv -f "$1.tmp" "$1"',
            "triggers", root.statePath, JSON.stringify({ muted: root.muted })])
    }
    readonly property string statePath: `${Quickshell.env("XDG_STATE_HOME") || `${Quickshell.env("HOME")}/.local/state`}/nixbook-shell/triggers.json`
    // What a trigger was about, in words (the preference saved by Never for this).
    function describe(tag) {
        const k = tag?.kind ?? ""
        const key = String(tag?.key ?? "")
        return k === "command_failed_again" ? `when the command \`${key.slice(0, 120)}\` fails again`
            : k === "error_copied" ? "when they copy an error"
            : k === "returning_window" ? `when they keep going back to ${tag.app || "the same window"}`
            : k === "meeting_soon" ? "before a meeting starts"
            : k === "error_dialog" ? `about error windows${tag.app ? ` of ${tag.app}` : ""}`
            : "about this"
    }

    // An offer to the reactor: not muted, not within its cooldown (`once`:
    // never again for that key while the shell runs, as a meeting).
    function emit(kind, key, fields, once) {
        if (!root.active || GlobalStates.screenLocked || DesktopControl.active) return false
        const k = root._key(kind, key)
        const t = Date.now()
        if (root.isMuted(kind, key)) return false
        const last = root._sent[k] ?? 0
        if (last > 0 && (once || t - last < root.cooldownMinutes * 60000)) return false
        root._sent = Object.assign({}, root._sent, { [k]: t })
        const ev = Object.assign({ event: kind, key: String(key ?? "").slice(0, 200) }, fields)
        const to = Reactor.react(ev)
        root.recent = [...root.recent, { time: t, kind: kind, key: ev.key, sent: to }].slice(-20)
        return true
    }

    // -- from RecentContext: a command failing again, an error copied -------
    function commandFailed(command, cwd, exit) {
        if (!root.commandFailedAgain) return false
        return root.emit("command_failed_again", command, { command: String(command).slice(0, 300), cwd: cwd,
            error: exit ? `exit ${exit}` : "" })
    }
    // Two lines or more that say an error happened (a stack trace).
    readonly property var errorLine: /\b(error|exception|traceback|panic|failed)\b|^\s*at\s+\S.*:\d+/i
    function looksLikeError(text) {
        return String(text ?? "").split("\n").filter(l => root.errorLine.test(l)).length >= 2
    }
    function copied(text) {
        if (!root.errorCopied || !root.looksLikeError(text)) return false
        // The same error copied again: the same key, within the cooldown.
        return root.emit("error_copied", Qt.md5(String(text)).slice(0, 12), { text: String(text).slice(0, 3000) })
    }

    // -- windows: gone back to again and again, an error dialog --------------
    // {key, time} of the windows focused, the last 30 minutes.
    property var _focuses: []
    property string _topKey: ""
    function _focused() {
        const top = ToplevelManager.activeToplevel
        if (!top) return
        const app = top.appId ?? ""
        const title = String(top.title ?? "").trim()
        const key = `${app}\u0001${title}`
        if (key === root._topKey) return
        root._topKey = key
        dialogTimer.restart()
        if (!root.returningWindow || !app || title.length === 0) return
        const t = Date.now()
        root._focuses = [...root._focuses.filter(f => t - f.time < 30 * 60000), { key: key, time: t }].slice(-200)
        const times = root._focuses.filter(f => f.key === key).length
        if (times >= 4) root.emit("returning_window", `${app}:${title}`, { app: app, title: title.slice(0, 200), times: times })
    }
    Connections {
        target: ToplevelManager
        enabled: root.returningWindow || root.errorDialog
        function onActiveToplevelChanged() {
            root._focused()
        }
    }
    Connections {
        target: ToplevelManager.activeToplevel
        enabled: root.returningWindow || root.errorDialog
        ignoreUnknownSignals: true
        function onTitleChanged() {
            root._focused()
        }
    }
    readonly property var errorTitle: /\b(error|failed|failure|erreur|échec|fehler|fehlgeschlagen)\b|lỗi/i
    Timer {
        id: dialogTimer
        interval: 20000
        onTriggered: {
            const top = ToplevelManager.activeToplevel
            const title = String(top?.title ?? "").trim()
            if (!root.errorDialog || !top || `${top.appId ?? ""}\u0001${title}` !== root._topKey) return
            if (!root.errorTitle.test(title)) return
            root.emit("error_dialog", `${top.appId ?? ""}:${title}`, { app: top.appId ?? "", title: title.slice(0, 200) })
        }
    }

    // -- a meeting about to start ---------------------------------------------
    function _link(e) {
        if (e.meetingUrl) return e.meetingUrl
        const m = /https?:\/\/[^\s<>"]+/i.exec(`${e.location ?? ""} ${e.description ?? ""}`)
        return m ? m[0] : ""
    }
    Timer {
        interval: 60000
        repeat: true
        running: root.meetingSoon && !Idle.screensOff
        triggeredOnStart: true
        onTriggered: {
            const now = new Date()
            for (const e of CalendarEvents.upcoming(6, now, true)) {
                const inMin = (e.start - now) / 60000
                if (inMin <= 0 || inMin > 5) continue
                const link = root._link(e)
                if (link.length === 0) continue
                root.emit("meeting_soon", `${e.id}@${e.start.getTime()}`, { title: e.summary, link: link,
                    start: Qt.formatTime(e.start, "hh:mm"), inMinutes: Math.round(inMin) }, true)
            }
        }
    }

    FileView {
        id: stateFile
        path: root.statePath
        printErrors: false
        onLoaded: {
            try {
                root.muted = JSON.parse(stateFile.text()).muted ?? {}
            } catch (e) {
                root.muted = {}
            }
        }
    }
}
