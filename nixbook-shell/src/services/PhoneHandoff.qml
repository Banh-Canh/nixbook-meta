pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import qs.modules.common.functions
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

/**
 * The phone handoff (ai.handoff, off by default): when the user leaves —
 * the screen locked, or no input — for ai.handoff.afterMinutes while
 * something waits for them (Muse asked a question, a step waits for their
 * OK, a background task needs them, a reminder or an event comes within
 * the hour), one message to the paired phone through KDE Connect: a ping
 * with its text (a notification on the phone), else the text shared;
 * never an SMS. Sent again while away only when something new waits.
 *
 * Lock-screen level (handoff.js): what KIND of thing waits, how many and
 * when — never a question's words, a step, a reminder's or a task's text.
 * Not with AI off, desktop control paused, Do Not Disturb or a fullscreen
 * window (presenting); nothing without a reachable phone. Agents can't
 * send (`handoff` is in desktop-mcp's shellIpcDenyTargets).
 */
Singleton {
    id: root
    function load() {}

    readonly property var settings: Config.options?.ai?.handoff ?? ({})
    readonly property bool enabled: (root.settings.enable ?? false) && (Config.options?.policies?.ai ?? 1) !== 0
    readonly property int afterMinutes: Math.max(1, root.settings.afterMinutes ?? 5)
    readonly property var device: KdeConnect.noteDevice

    // Away since (ms; 0: here): the lock, or the last input before idling.
    property real awaySince: 0
    // The keys of what was sent while away (handoff.js: only new ones send).
    property var sent: []
    property string lastWhy: ""
    property real lastSent: 0
    property string lastText: ""

    IdleMonitor {
        id: idle
        enabled: root.enabled
        // Video players and calls inhibit idling: not away then.
        respectInhibitors: true
        timeout: root.afterMinutes * 60
        onIsIdleChanged: {
            if (isIdle) {
                if (root.awaySince === 0) root.awaySince = Date.now() - root.afterMinutes * 60000
                root.check()
            } else if (!GlobalStates.screenLocked) root._back()
        }
    }
    Connections {
        target: GlobalStates
        function onScreenLockedChanged() {
            if (GlobalStates.screenLocked) {
                if (root.awaySince === 0) root.awaySince = Date.now()
            } else if (!idle.isIdle) root._back()
        }
    }
    function _back() {
        root.awaySince = 0
        root.sent = []
    }
    // While away: checked every minute (a task may start waiting, a
    // reminder come within the hour).
    Timer {
        interval: 60000
        repeat: true
        running: root.enabled && root.awaySince > 0
        triggeredOnStart: true
        onTriggered: root.check()
    }

    // Muse asked something in the bubble and waits: its last answer asks
    // back (a clarifying question, or ends with "?") and nothing came after.
    function _asked() {
        const chat = Initiative.chat
        const ids = chat?.messageIDs ?? []
        const id = ids.length > 0 ? ids[ids.length - 1] : ""
        const m = id ? chat.messageByID[id] : null
        if (!m || m.role !== "assistant" || Initiative.thinking) return false
        return !!m.clarify || /[?？]\s*$/.test(String(m.content ?? "").trim())
    }
    function state() {
        const t = Date.now()
        const mon = WM.focusedMonitor?.name ?? ""
        const reminders = (MemoryReminders.triggers ?? [])
            .filter(r => r.after && !(r.match?.length) && !r.title && !MemoryReminders.fired[r.id])
            .map(r => ({ id: r.id, at: r.after * 1000 }))
        const events = CalendarEvents.upcoming(4, new Date(t), true)
            .map(e => ({ id: e.id ?? "", at: e.start.getTime() }))
        return {
            enabled: root.enabled,
            policy: Config.options?.policies?.ai ?? 1,
            paused: DesktopControl.paused,
            dnd: Notifications.silent,
            presenting: !GlobalStates.screenLocked && mon !== "" && WM.fullscreenOnMonitor(mon),
            away: root.awaySince > 0,
            awayMinutes: root.awaySince > 0 ? Math.floor((t - root.awaySince) / 60000) : 0,
            afterMinutes: root.afterMinutes,
            phone: root.device !== null,
            sent: root.sent,
            question: root._asked(),
            approvals: (QuickAi.pending ? 1 : 0) + (Ai.current?.approval ? 1 : 0),
            tasks: MuseTasks.waiting.length,
            reminders: reminders,
            events: events,
            now: t,
            horizonMinutes: 60,
            lang: ConfigAssistant.uiLang(),
        }
    }
    function check() {
        const d = HandoffRules.decide(root.state())
        root.lastWhy = d.why
        if (!d.send) return d
        if (!KdeConnect.sendNote(root.device.id, d.text)) {
            root.lastWhy = "no phone"
            return d
        }
        root.sent = [...new Set([...root.sent, ...d.keys])]
        root.lastSent = Date.now()
        root.lastText = d.text
        return d
    }

    IpcHandler {
        target: "handoff"
        // JSON: whether it would send now, why, what (the user's check).
        function status(): string {
            const d = HandoffRules.decide(root.state())
            return JSON.stringify({ enabled: root.enabled, phone: root.device?.name ?? "", away: root.awaySince > 0,
                why: d.why, would: d.text, lastWhy: root.lastWhy, lastSent: root.lastSent })
        }
        // A test message to the phone now (Settings' button).
        function test(): string {
            if (!root.device) return "error: no reachable phone (pair one in KDE Connect)"
            return KdeConnect.sendNote(root.device.id, Translation.tr("Muse: the phone handoff works.")) ? "ok: sent to " + root.device.name
                : "error: the phone takes neither ping nor share"
        }
    }
}
