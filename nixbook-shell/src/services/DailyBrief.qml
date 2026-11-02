pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * The daily brief (ai.brief): one card in Muse's bubble at the day's start
 * (the first time the user is at the computer today: unlocked, back, the
 * shell started) — today's events, the tasks due, who waits for a reply,
 * the weather, plans coming — and at ai.brief.eveningAt the end-of-day
 * recap: what Muse did today (the journal), the tasks finished and still
 * open, who still waits, how tomorrow starts. Collected in plain code by
 * `nixbook-desktop-mcp brief compose` (the calendar, tasks and
 * notification centre over the shell's IPC, the journal), phrased by one
 * small-model call, masked for the provider (plain words with AI local
 * only and no local model, or desktop control paused). Read out with
 * ai.brief.speak when ai.voice.speak allows it (always, or Full AI mode).
 * Once a day each, never while busy (Do Not Disturb, a meeting, a
 * fullscreen window, locked): it waits. Nothing with AI off. Agents can't
 * trigger it (`brief` is in desktop-mcp's shellIpcDenyTargets; they read
 * the day with daily_brief).
 */
Singleton {
    id: root
    function load() {}

    readonly property var settings: Config.options?.ai?.brief ?? ({})
    readonly property bool active: Config.ready && (Config.options?.policies?.ai ?? 1) !== 0
    readonly property bool morningOn: root.active && (root.settings.morning ?? true)
    readonly property bool eveningOn: root.active && (root.settings.evening ?? true)
    readonly property string eveningAt: /^\d{1,2}:\d{2}$/.test(root.settings.eveningAt ?? "") ? root.settings.eveningAt : "18:00"
    readonly property bool running: runner.running
    property string lastKind: ""
    property string lastText: ""
    property real lastTime: 0
    property string error: ""

    function _today() {
        return Qt.formatDate(new Date(), "yyyy-MM-dd")
    }
    function _minutes(hhmm) {
        const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm)
        return m ? Number(m[1]) * 60 + Number(m[2]) : 18 * 60
    }
    readonly property bool _ready: Persistent.ready && Config.ready
    // The day's start: the brief, unless the evening came first (the day
    // started late: the recap says it all) or the night isn't over.
    function _maybe() {
        if (!root._ready || root.running || Initiative.busy()) return
        const t = new Date()
        const now = t.getHours() * 60 + t.getMinutes()
        const today = root._today()
        const st = Persistent.states.ai
        if (root.morningOn && st.briefMorningDay !== today && now >= 4 * 60 && now < root._minutes(root.eveningAt)) {
            root.run("morning", false)
            return
        }
        if (root.eveningOn && st.briefEveningDay !== today && now >= root._minutes(root.eveningAt))
            root.run("evening", false)
    }
    Connections {
        target: GlobalStates
        function onScreenLockedChanged() { if (!GlobalStates.screenLocked) startSoon.restart() }
    }
    Connections {
        target: Idle
        function onScreensOffChanged() { if (!Idle.screensOff) startSoon.restart() }
    }
    // A moment after the shell starts, unlocks, the screens wake (the
    // desktop settles, the calendar loads).
    Timer {
        id: startSoon
        interval: 20000
        running: root.morningOn || root.eveningOn
        onTriggered: root._maybe()
    }
    Timer {
        interval: 60000
        repeat: true
        running: root.morningOn || root.eveningOn
        onTriggered: root._maybe()
    }

    // `kind`: morning or evening; `asked`: the user asked (IPC, a word):
    // now, whatever the day's marks.
    function run(kind, asked) {
        if (!root.active || runner.running) return false
        if (!asked) {
            const today = root._today()
            if (kind === "morning") Persistent.states.ai.briefMorningDay = today
            else Persistent.states.ai.briefEveningDay = today
        }
        root.error = ""
        runner.kind = kind
        runner.command = ["nixbook-desktop-mcp", "brief", "compose", kind, "--lang", ConfigAssistant.uiLang()]
        runner.running = true
        return true
    }
    Process {
        id: runner
        property string kind: "morning"
        stdout: StdioCollector {
            id: out
            onStreamFinished: {
                let r
                try { r = JSON.parse(out.text) } catch (e) { r = null }
                if (!r || r.error || !r.text) {
                    root.error = r?.error ?? Translation.tr("The brief couldn't be made")
                    return
                }
                root._show(runner.kind, r)
            }
        }
    }
    function _show(kind, r) {
        root.lastKind = kind
        root.lastText = r.text
        root.lastTime = Date.now()
        const actions = []
        if ((r.repliesCount ?? 0) > 0 && ReplyBatch.enabled)
            actions.push({ label: (r.repliesCount ?? 0) > 1 ? Translation.tr("Help me reply (%1)").arg(r.repliesCount) : Translation.tr("Help me reply"),
                           do: "replies" })
        if (kind === "morning" && (r.events ?? 0) > 0)
            actions.push({ label: Translation.tr("Calendar"), do: "brief", what: "calendar" })
        if (kind === "evening" && (r.journal ?? 0) > 0)
            actions.push({ label: Translation.tr("What Muse did"), do: "journal" })
        if ((r.dueToday ?? 0) > 0 || (kind === "evening" && (r.data?.tasks?.open ?? 0) > 0))
            actions.push({ label: Translation.tr("Tasks"), do: "tasks" })
        Initiative.briefWord({ kind: "dailyBrief", text: r.text, actions: actions, brief: kind })
        // Out loud when the voice says answers on its own (always), or in
        // Full AI mode; ai.brief.speak off keeps it written.
        if ((root.settings.speak ?? true) && (Voice.speakMode === "always" || (Voice.speakMode === "voice" && FullAi.active)))
            Voice.speak(r.text)
    }
    // A button of its card (Initiative.act → here).
    function act(a) {
        if (a.what === "calendar") CalendarEvents.openApp()
    }

    IpcHandler {
        target: "brief"
        // The morning brief now (in the bubble).
        function morning(): string {
            return root.run("morning", true) ? "ok: making the morning brief" : "error: AI is off, or a brief is being made"
        }
        // The end-of-day recap now.
        function evening(): string {
            return root.run("evening", true) ? "ok: making the end-of-day recap" : "error: AI is off, or a brief is being made"
        }
        function status(): string {
            return JSON.stringify({ morning: root.morningOn, evening: root.eveningOn, eveningAt: root.eveningAt,
                running: root.running, last: root.lastKind, lastTime: root.lastTime, error: root.error,
                morningDay: Persistent.states?.ai?.briefMorningDay ?? "", eveningDay: Persistent.states?.ai?.briefEveningDay ?? "" })
        }
    }
}
