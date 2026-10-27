pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Muse doing things on its own, with the user in charge (ai.autonomy):
 *   - standing orders ("from now on, when I join a meeting, mute the music"):
 *     Muse's `standing_order` tool compiles one into a routine, saved off;
 *     the card under its answer (StandingOrderCard.qml) turns it on with the
 *     user's own click (`order accept ID`), or declines it;
 *   - the trust ladder: each class of action (a tool, its action, the app it
 *     acts on: `media_control:pause`, `close_window@firefox`) is asked
 *     about, told about after, or done silently. Muse suggests "stop asking
 *     before …" after three yeses in a row; only the user raises a class,
 *     here (`setTrust`: the suggestion's Yes, Settings > Desktop agents >
 *     Autonomy) — `trust set` never comes from an agent;
 *   - the journal: what Muse did without the user approving that very step
 *     (routines, standing orders, digests, its reactions, steps it was
 *     trusted with, background tasks), kept 30 days, each with its Undo
 *     when it can be taken back ("What Muse did" in the side panel, the
 *     bubble's line about yesterday at the day's start).
 * Everything goes through nixbook-desktop-mcp's helper (DesktopHelper).
 * IPC `journal list|undo` is the user's (agents are refused it).
 */
Singleton {
    id: root
    function load() {
        root.refreshJournal()
    }

    readonly property bool aiOn: (Config.options?.policies?.ai ?? 1) !== 0
    readonly property bool orders: root.aiOn && (Config.options?.ai?.autonomy?.orders ?? true)
    readonly property bool trust: root.aiOn && (Config.options?.ai?.autonomy?.trust ?? true)
    readonly property bool journalOn: root.aiOn && (Config.options?.ai?.autonomy?.journal ?? true)
    readonly property string stateDir: `${Quickshell.env("XDG_STATE_HOME") || `${Quickshell.env("HOME")}/.local/state`}/nixbook-shell`

    function _json(code, out) {
        if (code !== 0) return null
        try {
            return JSON.parse(out)
        } catch (e) {
            return null
        }
    }
    function _list(data, key) {
        if (Array.isArray(data)) return data
        if (data && Array.isArray(data[key])) return data[key]
        // {name: {...}}: a list with the name in it.
        if (data && typeof data === "object")
            return Object.keys(data).map(k => Object.assign({ class: k }, typeof data[k] === "object" ? data[k] : { level: data[k] }))
        return []
    }

    // -- standing orders -----------------------------------------------------
    // id -> "on" | "declined" | "busy" | "error: …": what the user answered
    // on its card (the card shows it).
    property var orderState: ({})
    function _setOrder(id, state) {
        root.orderState = Object.assign({}, root.orderState, { [id]: state })
    }
    function acceptOrder(id) {
        if (!/^[\w.:-]{1,64}$/.test(String(id ?? ""))) return
        root._setOrder(id, "busy")
        DesktopHelper.run(["order", "accept", String(id)], "", (code, out) => {
            const r = root._json(code, out)
            root._setOrder(id, r && !r.error ? "on" : `error: ${r?.error ?? Translation.tr("couldn't turn it on")}`)
        })
    }
    function declineOrder(id) {
        if (!/^[\w.:-]{1,64}$/.test(String(id ?? ""))) return
        root._setOrder(id, "declined")
        DesktopHelper.run(["order", "decline", String(id)], "", () => {})
    }
    function editOrders() {
        GlobalStates.settingsPage = "Desktop agents:Routines"
        GlobalStates.settingsOpen = true
    }

    // -- the trust ladder ----------------------------------------------------
    // [{class, level: ask|tell|silent, streak, last, …}], as `trust list`.
    property var trustList: []
    property bool trustLoaded: false
    function refreshTrust() {
        DesktopHelper.run(["trust", "list"], "", (code, out) => {
            const data = root._json(code, out)
            root.trustList = root._list(data, "classes").filter(c => typeof c?.class === "string")
                .sort((a, b) => String(a.class).localeCompare(String(b.class)))
            root.trustLoaded = data !== null
        })
    }
    // The user's own choice (a click): never called for an agent.
    // done(ok, why).
    function setTrust(cls, level, done) {
        if (!["ask", "tell", "silent"].includes(level) || !/^[\w.:@+-]{1,200}$/.test(String(cls ?? ""))) {
            if (done) done(false, "")
            return
        }
        DesktopHelper.run(["trust", "set", String(cls), level], "", (code, out) => {
            const r = root._json(code, out)
            const ok = code === 0 && !(r?.error)
            root.trustAnswered = Object.assign({}, root.trustAnswered, { [cls]: ok ? level : "error" })
            root.refreshTrust()
            if (done) done(ok, String(r?.error ?? (ok ? "" : out)).trim())
        })
    }
    // The "Stop asking before …?" chips answered, by class: the level set,
    // "no" (asked again later), or "error".
    property var trustAnswered: ({})
    function declineSuggestion(cls) {
        root.trustAnswered = Object.assign({}, root.trustAnswered, { [cls]: "no" })
    }

    // -- the journal ---------------------------------------------------------
    // [{id, time (s), source, class, summary, tool, undo?, undone?}], newest
    // first.
    property var journal: []
    // id -> "busy" | "done" | "error: …" (an Undo clicked).
    property var undoState: ({})
    function _time(e) {
        const t = Number(e?.time ?? e?.ts ?? e?.created ?? 0)
        return t > 1e12 ? t / 1000 : t
    }
    function refreshJournal() {
        if (!root.journalOn) {
            root.journal = []
            return
        }
        DesktopHelper.run(["journal", "list"], "", (code, out) => {
            const data = root._json(code, out)
            if (data === null) return
            root.journal = root._list(data, "entries").filter(e => e && e.id !== undefined)
                .map(e => Object.assign({}, e, { id: String(e.id), time: root._time(e) }))
                .sort((a, b) => b.time - a.time)
        })
    }
    function canUndo(e) {
        return !!e?.undo && !e.undone && root.undoState[e.id] !== "done"
    }
    // done(ok, text).
    function undo(id, done) {
        const key = String(id ?? "")
        if (!/^[\w.:-]{1,64}$/.test(key)) {
            if (done) done(false, "")
            return
        }
        root.undoState = Object.assign({}, root.undoState, { [key]: "busy" })
        DesktopHelper.run(["journal", "undo", key], "", (code, out) => {
            const r = root._json(code, out)
            const ok = !!r && !r.error && r.ok !== false
            const said = ok ? String(r.summary ?? Translation.tr("Undone")) : String(r?.error ?? Translation.tr("can't be undone"))
            root.undoState = Object.assign({}, root.undoState, { [key]: ok ? "done" : `error: ${said}` })
            root.refreshJournal()
            if (done) done(ok, said)
        })
    }
    // Entries by day, newest first: [{day: "YYYY-MM-DD", label, entries}].
    readonly property var byDay: {
        const days = []
        for (const e of root.journal) {
            const d = new Date(e.time * 1000)
            const key = Qt.formatDate(d, "yyyy-MM-dd")
            let g = days.find(x => x.day === key)
            if (!g) {
                g = { day: key, label: root.dayLabel(d), entries: [] }
                days.push(g)
            }
            g.entries.push(e)
        }
        return days
    }
    function dayLabel(d) {
        const today = new Date()
        const yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1)
        if (d.toDateString() === today.toDateString()) return Translation.tr("Today")
        if (d.toDateString() === yesterday.toDateString()) return Translation.tr("Yesterday")
        return Qt.locale().toString(d, "dddd d MMMM")
    }
    // The journal changed (a routine ran, Muse acted): read again, once a
    // burst settles.
    FileView {
        path: root.journalOn ? `${root.stateDir}/journal.json` : ""
        watchChanges: true
        printErrors: false
        onFileChanged: journalSoon.restart()
    }
    Timer {
        id: journalSoon
        interval: 800
        onTriggered: root.refreshJournal()
    }

    // The day's start: one line in the bubble about what Muse did yesterday
    // (a small word, the journal one click away).
    Connections {
        target: Routines
        function onHappened(ev) {
            if (ev.event === "day_start") root.daySummary()
        }
    }
    property string _summarized: ""
    function daySummary() {
        if (!root.journalOn || !Initiative.enabled) return
        const t = new Date()
        const day = Qt.formatDate(new Date(t.getFullYear(), t.getMonth(), t.getDate() - 1), "yyyy-MM-dd")
        if (root._summarized === day) return
        root._summarized = day
        DesktopHelper.run(["journal", "list", "--day", day], "", (code, out) => {
            const entries = root._list(root._json(code, out), "entries")
            if (entries.length === 0) return
            const shown = entries.slice(0, 3).map(e => String(e.summary ?? "").trim()).filter(s => s).join(" · ")
            Initiative.journalLine(entries.length === 1 ? Translation.tr("Yesterday I did one thing for you: %1").arg(shown)
                : Translation.tr("Yesterday I did %1 things for you: %2").arg(entries.length).arg(shown))
        })
    }
    // "What Muse did" in the side panel.
    function openJournal() {
        GlobalStates.sidebarLeftOpen = true
        GlobalStates.museActivityRequested("journal")
    }

    IpcHandler {
        target: "journal"
        // JSON: the entries (of one day, YYYY-MM-DD, or all kept), newest first.
        function list(day: string): string {
            const d = String(day ?? "").trim()
            return JSON.stringify(root.journal.filter(e => !d || Qt.formatDate(new Date(e.time * 1000), "yyyy-MM-dd") === d))
        }
        // Undoes one (the answer comes in the journal and the bubble).
        function undo(id: string): string {
            if (!root.journal.some(e => e.id === String(id))) return "error: no such entry"
            root.undo(id, (ok, said) => {
                if (ok) Quickshell.execDetached(["notify-send", "-a", "Muse", "-t", "4000", "Muse", Translation.tr("Undone: %1").arg(said)])
            })
            return "ok: undoing it"
        }
    }
}
