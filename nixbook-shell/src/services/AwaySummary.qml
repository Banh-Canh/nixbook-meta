pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import qs.modules.common.functions
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import QtQuick

/**
 * "While you were away" (ai.away): back at the computer after at least
 * `minMinutes` (Routines' "back": the screens on again, or the session
 * unlocked), ONE compact card in Muse's bubble (AgentSpeech.qml, AwayCard.qml)
 * with what happened meanwhile. Collected here in plain code: the
 * notifications still in the centre that came meanwhile (those that can be
 * answered marked so), the calendar's changes (an event new, moved or
 * cancelled in the next three days, against what it was when the user left),
 * the background tasks finished, failed or waiting (MuseTasks), the routines
 * that ran (Routines.ran). `nixbook-desktop-mcp away summary` (on the helper)
 * ranks it like Kiroshi's scan, in plain code (noise dropped: the shell's own,
 * private codes and banks, low urgency, what the user muted; then urgency ×
 * value), and with policies.ai 1 ONE small-model call, through the privacy
 * mask, orders the top lines and says them in a sentence; with 2 the plain
 * list only, nothing with 0. Each line: Open (the notification's own action,
 * else its app's window; the event in the Calendar; the task in the Muse
 * tab; the journal for a routine), Reply via Muse for a message (an order to
 * Muse in the bubble, online only); the card: Dismiss all (the notifications
 * it lists cleared from the centre) and OK. Never while the user is busy (Do
 * Not Disturb, a meeting, a fullscreen window, locked: Initiative.busy()),
 * in Full AI mode or while an agent acts: it waits for them, at most 30
 * minutes, then lets it go. IPC `away`: status, show MINUTES (the card for
 * the last minutes now, a demo); agents can't call it (desktop-mcp's
 * shellIpcDenyTargets: it spends a model call and shows the notifications).
 */
Singleton {
    id: root
    // Referenced at startup (shell.qml): its IPC target exists from the start.
    function load() {}

    readonly property int policy: Config.options?.policies?.ai ?? 1
    readonly property var cfg: Config.options?.ai?.away ?? ({})
    readonly property bool enabled: (root.cfg.enable ?? true) && [1, 2].includes(root.policy)
    readonly property int minMinutes: Math.max(1, Number(root.cfg.minMinutes ?? 20))
    readonly property int waitLimitMs: 30 * 60000

    // When the user left (the screens off, the session locked), the
    // calendar as it was then, and the routines that ran since.
    property real _leftAt: 0
    property var _calendarBefore: null
    property var _ran: []
    // Back, the card waiting for the user to be free: {since, away, at}.
    property var _pending: null
    property bool working: false
    // The last card's answer (Settings, IPC status): {time, away, items, more,
    // dropped, total, model, why}; and why the last return showed nothing.
    property var last: null
    property string lastWhy: ""

    function _leave() {
        if (root._leftAt > 0) return
        root._leftAt = Date.now()
        root._calendarBefore = root._calendarNow()
        root._ran = []
    }
    Connections {
        target: GlobalStates
        function onScreenLockedChanged() { if (GlobalStates.screenLocked) root._leave() }
    }
    Connections {
        target: Idle
        function onScreensOffChanged() { if (Idle.screensOff) root._leave() }
    }
    Connections {
        target: Routines
        function onHappened(ev) {
            if (ev.event === "back") root._back(Number(ev.away ?? 0))
        }
        function onRan(r) {
            if (root._leftAt > 0 || root._pending)
                root._ran = [...root._ran, { title: String(r?.text ?? r?.order ?? r?.id ?? ""), time: Date.now() }].slice(-20)
        }
    }

    function _back(away) {
        const before = root._calendarBefore
        root._leftAt = 0
        if (!root.enabled || away < root.minMinutes) {
            root._calendarBefore = null
            return
        }
        root._pending = { since: Date.now() - away * 60000, away: away, at: Date.now(), calendar: before }
        // A moment first: the unlock settles, a notification that came as the
        // screens woke is in.
        retry.interval = 3000
        retry.restart()
    }
    Timer {
        id: retry
        onTriggered: root._try()
    }
    // Busy (Do Not Disturb, a meeting now, a fullscreen window, locked, the
    // screens off), in Full AI mode or an agent acting: later, once a minute,
    // until the user is free (at most 30 minutes).
    function blocked() {
        return Initiative.busy() || FullAi.active || DesktopControl.active
    }
    function _try() {
        const p = root._pending
        if (!p) return
        if (Date.now() - p.at > root.waitLimitMs) {
            root._pending = null
            root._calendarBefore = null
            root.lastWhy = Translation.tr("You stayed busy: nothing shown")
            return
        }
        if (root.blocked() || root.working) {
            retry.interval = 60000
            retry.restart()
            return
        }
        root._pending = null
        root._calendarBefore = null
        root.summarize(p.since, p.away, p.calendar)
    }

    // The calendar's timed events of the next three days: {until (the
    // window's end, ms), events: {key: {id, title, start, end}}} (a recurring
    // one's occurrence apart).
    function _calendarNow() {
        const events = {}
        const t = new Date()
        for (let i = 0; i < 3; i++) {
            const day = new Date(t.getFullYear(), t.getMonth(), t.getDate() + i)
            for (const e of CalendarEvents.eventsOn(day)) {
                if (e.allDay) continue
                events[e.recurring ? `${e.id}@${e.occurrence}` : e.id] = { id: e.id, title: e.summary, start: e.start.getTime(),
                                                                            end: e.end.getTime() }
            }
        }
        return { until: new Date(t.getFullYear(), t.getMonth(), t.getDate() + 3).getTime(), events: events }
    }
    function _urgency(n) {
        const u = n.urgency
        return (u == NotificationUrgency.Critical || u === "critical") ? "critical"
            : (u == NotificationUrgency.Low || u === "low") ? "low" : "normal"
    }
    function _when(ms) {
        return CalendarEvents.whenText({ allDay: false, start: new Date(ms), end: new Date(ms) }, new Date())
    }
    // What happened since `since` (ms), for `away summary`: oldest first.
    function collect(since, calendarBefore) {
        const items = []
        for (const n of Notifications.list) {
            if (Number(n.time ?? 0) < since || n.isTransient || n.hints?.["x-nixbook-task"] !== undefined) continue
            items.push({ kind: "notification", key: `n:${n.notificationId}`, ids: [n.notificationId], app: n.appName,
                         title: n.summary, text: String(n.body ?? "").replace(/<[^>]+>/g, "").slice(0, 400),
                         urgency: root._urgency(n), canReply: Notifications.replyMethod(n) !== null, time: n.time })
        }
        // The calendar: what is new, moved or gone since the user left
        // (AwayChanges: within the window both snapshots cover).
        const t = Date.now()
        const said = { new: Translation.tr("New · %1"), moved: Translation.tr("Moved to %1"), cancelled: Translation.tr("Cancelled (was %1)") }
        for (const c of AwayChanges.changes(calendarBefore, root._calendarNow(), t))
            items.push({ kind: "calendar", key: `c:${c.key}`, eventId: c.id, change: c.change, app: "Calendar", title: c.title,
                         text: said[c.change].arg(root._when(c.start)), startsIn: Math.round((c.start - t) / 60000), date: c.start, time: t })
        // Background tasks: finished, failed, or waiting for the user.
        for (const task of MuseTasks.topLevel) {
            const at = Number(task.updated ?? 0) * 1000
            if (at < since || !["done", "failed", "waiting"].includes(task.status)) continue
            items.push({ kind: "task", key: `t:${task.id}`, taskId: task.id, status: task.status, app: "Muse",
                         title: String(task.title || task.text || "").slice(0, 160),
                         text: String(task.report?.summary || task.question || task.error || MuseTasks.statusText(task)).slice(0, 300), time: at })
        }
        for (const [i, r] of root._ran.entries())
            if (r.time >= since && r.title)
                items.push({ kind: "routine", key: `r:${i}`, app: "Routines", title: r.title, text: Translation.tr("ran"), time: r.time })
        return items.sort((a, b) => Number(a.time ?? 0) - Number(b.time ?? 0))
    }

    function duration(minutes) {
        const m = Math.round(minutes)
        return m < 60 ? Translation.tr("%1 min").arg(m) : Translation.tr("%1 h %2 min").arg(Math.floor(m / 60)).arg(m % 60)
    }
    // Collects, ranks (one model call at most) and shows the card.
    function summarize(since, away, calendarBefore, forced) {
        if (!root.enabled || root.working) return
        const items = root.collect(since, calendarBefore ?? null)
        if (items.length === 0) {
            root.lastWhy = Translation.tr("Nothing happened while you were away")
            return
        }
        root.working = true
        const req = { away: Math.round(away), lang: ConfigAssistant.uiLang(), model: root.policy === 1, items: items }
        DesktopHelper.run(["away", "summary", "-"], JSON.stringify(req), (code, out) => {
            root.working = false
            let r = null
            try { r = JSON.parse(out) } catch (e) {}
            if (!r || (r.items ?? []).length === 0) {
                root.lastWhy = r ? Translation.tr("Nothing worth a look (%1 left out)").arg(r.dropped ?? 0)
                    : Translation.tr("Couldn't rank it (nixbook-desktop-mcp)")
                return
            }
            r.time = Date.now()
            r.away = Math.round(away)
            root.last = r
            root.lastWhy = r.why ?? ""
            // Busy again meanwhile (a call that started): not over it,
            // unless asked for.
            if (!forced && root.blocked()) {
                root.lastWhy = Translation.tr("You got busy: not shown")
                return
            }
            root._show(r)
        })
    }
    function _show(r) {
        const head = Translation.tr("While you were away · %1").arg(root.duration(r.away))
        const n = r.items.length + (r.more ?? 0)
        const plain = n === 1 ? Translation.tr("One thing worth a look.") : Translation.tr("%1 things worth a look.").arg(n)
        Initiative.awayCard({ text: `${head}\n${r.summary || plain}`, away: r,
                              actions: [{ label: Translation.tr("Dismiss all"), do: "away", what: "dismissAll" }] })
    }

    // A line's buttons (AwayCard.qml).
    function canReply(line) {
        return line?.kind === "notification" && line?.reply === true && QuickAi.available
    }
    function open(line) {
        if (!line) return
        if (line.kind === "calendar") GlobalStates.openCalendarApp(new Date(Number(line.date ?? Date.now())), null)
        else if (line.kind === "task") MuseTasks.openTask(line.taskId)
        else if (line.kind === "routine") Autonomy.openJournal()
        else if (line.kind === "notification") {
            const ids = line.ids ?? []
            const n = Notifications.list.find(x => x.notificationId === ids[ids.length - 1])
            if (n && (n.actions ?? []).some(a => a.identifier === "default")) {
                Notifications.attemptInvokeAction(n.notificationId, "default")
                return
            }
            // No action of its own: its app's window, else the notification centre.
            const app = String(line.app ?? "").toLowerCase()
            const w = WM.windowList.find(w => app.length > 0 && (String(w.appId).toLowerCase().includes(app)
                || app.includes(String(w.appId).toLowerCase().split(".").pop())))
            if (w) WM.focusWindow(w.id)
            else GlobalStates.sidebarRightOpen = true
        }
    }
    // Reply via Muse: an order to Muse in the bubble, the message quoted; it
    // answers through the notification (notification_action, asked first).
    function reply(line) {
        if (!root.canReply(line)) return
        const ids = line.ids ?? []
        const order = Translation.tr("Help me reply to this %1 message from %2 (notification %3): “%4”. Suggest a short reply, and send it only once I say so.")
            .arg(line.app).arg(line.title).arg(ids[ids.length - 1]).arg(line.text)
        QuickAi.command(order, "away", Translation.tr("Reply to %1").arg(line.title))
    }
    // Dismiss all: the notifications the card lists, cleared from the centre
    // (seen in the summary: not counted as turned down).
    function dismissAll(card) {
        const ids = []
        for (const line of card?.items ?? [])
            if (line.kind === "notification") ids.push(...(line.ids ?? []))
        if (ids.length > 0) Notifications.discardNotifications(ids, false, false)
    }

    IpcHandler {
        target: "away"
        // JSON: on or off, waiting, the last card.
        function status(): string {
            return JSON.stringify({ enabled: root.enabled, minMinutes: root.minMinutes, waiting: root._pending !== null,
                                    leftAt: root._leftAt, working: root.working, lastWhy: root.lastWhy, last: root.last });
        }
        // The card for the last `minutes` now (a demo): busy or not.
        function show(minutes: int): string {
            if (!root.enabled) return "error: off (ai.away.enable, policies.ai)";
            const m = Math.max(1, minutes);
            root.summarize(Date.now() - m * 60000, m, null, true);
            return "ok";
        }
    }
}
