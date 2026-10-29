pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import QtQuick

/**
 * The one event reactor: every notification and everything Routines sees
 * happen (a download, the battery low, a screen plugged in, the user back…)
 * comes through here, once. Routines' fixed actions run first, as they
 * always did (Routines.happen does them right after telling what happened),
 * then at most ONE model decision per event: the first handler that wants
 * it and is within its budget takes it. Full AI mode (services/FullAi.qml,
 * its react path) comes first while it is on; else the initiative
 * (services/Initiative.qml: its notification batch, its reactions). They
 * register here instead of listening to Notifications and Routines
 * themselves, so a notification is never read by two models.
 * Each keeps its own batching and quiet rules (the initiative's 45 s
 * notification batch and day budget, Full AI's 1.2 s pump); Full AI gets an
 * hourly budget here too (ai.fullAi.reactPerHour, 0: no limit), spent when
 * it actually asks its model (spend()).
 *
 * In front of the model, the instant triage (ai.reactivity.triage):
 * `nixbook-desktop-mcp triage score` (plain code on the helper, no model,
 * a few milliseconds) scores each notification and event someone wants
 * first: "drop" (muted, boring, a repeat: nothing more; Routines' fixed
 * actions and digests still had it, they see everything themselves),
 * "direct" (clearly worth saying and sayable as it is, "Thomas wrote: …":
 * said at once through the initiative, no 45 s batch, no model, counted
 * against its own hourly budget here) or "model" (the gray zone: today's
 * path). What the shell offers before being asked (ContextTriggers.qml:
 * a command failing again, an error copied…) skips it: the initiative
 * decides those as offers.
 */
Singleton {
    id: root
    function load() {}

    // {name, priority, wants(ev) -> bool, take(ev)}, lowest priority first.
    property var handlers: []
    function register(name, priority, handler) {
        root.handlers = [...root.handlers.filter(h => h.name !== name), Object.assign({}, handler, { name: name, priority: priority })]
            .sort((a, b) => a.priority - b.priority);
    }

    // Model decisions made lately, by handler: {name: [times (ms)]}.
    property var spent: ({})
    function perHour(name) {
        return name === "fullAi" ? (Config.options?.ai?.fullAi?.reactPerHour ?? 30)
            : name === "direct" ? root.directPerHour : 0;
    }
    // What the triage says at once (no model): at most this many an hour,
    // past it back to the model's path (which has its own budget).
    readonly property int directPerHour: 20
    readonly property bool triageOn: Config.options?.ai?.reactivity?.triage ?? true
    // Offers (ContextTriggers.qml): not triaged, the initiative words them.
    readonly property var triggerEvents: ["command_failed_again", "error_copied", "returning_window", "meeting_soon", "error_dialog"]
    function used(name) {
        const t = Date.now();
        return (root.spent[name] ?? []).filter(x => t - x < 3600000).length;
    }
    function withinBudget(name) {
        const per = root.perHour(name);
        return per <= 0 || root.used(name) < per;
    }
    // A handler asked its model (counted against its hourly budget).
    function spend(name) {
        const t = Date.now();
        root.spent = Object.assign({}, root.spent, { [name]: [...(root.spent[name] ?? []).filter(x => t - x < 3600000), t] });
    }

    // What came and who took it, newest last (the IPC status, for tests and
    // Settings): {time, event, app, to}.
    property var log: []
    function _note(ev, to) {
        root.log = [...root.log, { time: Date.now(), event: ev.event, app: ev.app ?? "", to: to }].slice(-30);
    }
    function _wants(handler, ev) {
        try {
            return handler.wants(ev) === true;
        } catch (e) {
            console.warn(`[Reactor] ${handler.name} failed to look at ${ev.event}:`, e);
            return false;
        }
    }
    // An event, to the first handler that wants it: its name, "" for none.
    function dispatch(ev) {
        for (const h of root.handlers) {
            if (!root._wants(h, ev) || !root.withinBudget(h.name)) continue;
            try {
                h.take(ev);
            } catch (e) {
                console.warn(`[Reactor] ${h.name} failed on ${ev.event}:`, e);
            }
            root._note(ev, h.name);
            return h.name;
        }
        root._note(ev, "");
        return "";
    }
    // An event as it comes (a notification, what Routines saw, an offer):
    // nobody wants it, noted; else the triage first, then dispatch().
    function react(ev) {
        // AI off, or local only: every handler here asks an online model.
        if ((Config.options?.policies?.ai ?? 1) !== 1) {
            root._note(ev, "AI off");
            return "";
        }
        if (!root.handlers.some(h => root._wants(h, ev) && root.withinBudget(h.name))) {
            // Titles change every second (a terminal's spinner): not logged,
            // or the status would show nothing else.
            if (ev.event !== "window_title") root._note(ev, "");
            return "";
        }
        if (!root.triageOn || root.triggerEvents.includes(ev.event))
            return root.dispatch(ev);
        // Full AI mode taking it: the user asked it to react, so the triage
        // leaves what their habits would drop to the model.
        const full = root.handlers.some(h => h.name === "fullAi" && root._wants(h, ev) && root.withinBudget(h.name));
        DesktopHelper.run(["triage", "score", JSON.stringify(root._triageEvent(ev, full))], "", (code, out) => root._triaged(ev, code, out, full));
        return "triage";
    }
    // What the triage reads: the event, and whether the user is busy now
    // (Do Not Disturb, a meeting, a fullscreen window), the hour, the language.
    function _triageEvent(ev, full) {
        const t = new Date();
        const mon = WM.focusedMonitor?.name ?? "";
        return Object.assign({}, ev, { fullAi: full === true, dnd: Notifications.silent === true,
            meeting: CalendarEvents.eventsOn(t).some(e => !e.allDay && e.start <= t && e.end > t),
            fullscreen: mon !== "" && WM.fullscreenOnMonitor(mon), hour: t.getHours(), lang: ConfigAssistant.uiLang() });
    }
    // The triage's verdicts lately, newest last (the IPC status, Settings):
    // {time, event, app, verdict, score, why}.
    property var verdicts: []
    function _triaged(ev, code, out, full) {
        let v = null;
        try {
            v = code === 0 ? JSON.parse(out) : null;
        } catch (e) {
            v = null;
        }
        const verdict = ["drop", "direct", "model"].includes(v?.verdict) ? v.verdict : "model";
        root.verdicts = [...root.verdicts, { time: Date.now(), event: ev.event, app: ev.app ?? "", verdict: verdict,
            score: Number(v?.score ?? 0), why: String(v?.why ?? (v ? "" : "no triage: the model decides")) }].slice(-30);
        if (verdict === "drop") {
            root._note(ev, "dropped");
            return;
        }
        // Said at once (within its budget), else the model's path. In Full
        // AI mode the mascot takes it (it speaks, asks, acts): the most
        // important ones mustn't go past it to a quiet bubble.
        if (!full && verdict === "direct" && String(v.text ?? "").trim().length > 0 && root.withinBudget("direct")
                && Initiative.direct(ev, String(v.text), v)) {
            root.spend("direct");
            root._note(ev, "direct");
            return;
        }
        root.dispatch(ev);
    }

    // Would a handler before `name` take this event? (The initiative's own
    // events, like the user coming back, that Full AI also gets from
    // Routines: decided once.)
    function takenElsewhere(ev, name) {
        for (const h of root.handlers) {
            if (h.name === name) return false;
            if (root._wants(h, ev) && root.withinBudget(h.name)) return true;
        }
        return false;
    }

    function _urgency(n) {
        const u = n.urgency;
        return (u == NotificationUrgency.Critical || u === "critical") ? "critical"
            : (u == NotificationUrgency.Low || u === "low") ? "low" : "normal";
    }
    Connections {
        target: Notifications
        function onNotify(n) {
            // A background task's own notification (nixbook-muse-task: "Muse
            // needs you", done): shown, never reacted to.
            if (n.hints?.["x-nixbook-task"] !== undefined) return;
            // The body without its markup (the triage's "X wrote: …" and the
            // models read it).
            const text = String(n.body ?? "").replace(/<[^>]+>/g, "").slice(0, 600);
            root.react({ event: "notification", app: n.appName ?? "", title: n.summary ?? "", body: text, text: text,
                            urgency: root._urgency(n), id: n.notificationId, transient: n.isTransient === true });
        }
    }
    // Everything else Routines sees (its notification events are the ones
    // above, read from the notification itself).
    Connections {
        target: Routines
        function onHappened(ev) {
            if (ev.event !== "notification") root.react(ev);
        }
    }

    IpcHandler {
        target: "reactor"
        // JSON: the handlers in order, Full AI's budget, the last events.
        function status(): string {
            return JSON.stringify({ handlers: root.handlers.map(h => h.name),
                fullAi: { perHour: root.perHour("fullAi"), used: root.used("fullAi") },
                direct: { perHour: root.perHour("direct"), used: root.used("direct") }, triage: root.triageOn,
                log: root.log.slice(-10), verdicts: root.verdicts.slice(-10) });
        }
        // An event as if it had happened (tests): {event, app, title, text…};
        // the handler that took it ("" for none).
        function simulate(json: string): string {
            try {
                return root.dispatch(JSON.parse(json));
            } catch (e) {
                return "error: " + e;
            }
        }
        // The same through the triage first: "triage" while it scores it
        // (the verdict then in status), "" when nobody wants it.
        function simulateTriaged(json: string): string {
            try {
                return root.react(JSON.parse(json));
            } catch (e) {
                return "error: " + e;
            }
        }
    }
}
