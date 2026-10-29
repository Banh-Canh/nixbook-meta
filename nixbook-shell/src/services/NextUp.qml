pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

/**
 * "Next up" (ai.predict): Muse getting ahead of the user, the step they most
 * likely take next offered before they ask, as ONE quiet chip beside the
 * desktop mascot (modules/ii/fullAi/NextUpChip.qml). The guessing is plain
 * code in nixbook-desktop-mcp (`predict`, on the helper: no model, a few
 * milliseconds): this service tells it what happens, and shows what it
 * answers. What it tells (the user's own doing only: nothing while an agent
 * drives the desktop or the screen is locked; private windows are left out
 * there, window titles never kept):
 *   - an app used: in front for 5 s;
 *   - a layout restored, a link opened through the shell, a timer or a focus
 *     session (pomodoro) started;
 *   - events: a meeting over (a timed calendar event ending), a download, a
 *     pull or merge request open in the browser (read from its title), a
 *     command failing in a terminal, the day starting, unlocking, back from a
 *     break, a monitor / Wi-Fi / audio output / Bluetooth device, a routine
 *     having run.
 * The chip: "Next: open Jira", why on hover ("You usually open Jira after
 * your 09:00 standup — 14 times"). A click or Mod+Shift+Return does it, as
 * the user's own action (an app focused or started through AppLaunch, a
 * layout restored, a link opened, a timer, a routine run; a follow-up is an
 * order for Muse in its bubble, QuickAi.command, only with policies.ai 1).
 * Left alone it fades after 12 s (learned as let go); right click: Not now,
 * Never after this, Never suggest this. Never shown while busy (Do Not
 * Disturb, a meeting now, a fullscreen window, locked, screens off), in Full
 * AI mode, while Muse's bubble talks, nor while an agent acts. Plain steps
 * with policies.ai 1 or 2, nothing at 0.
 * IPC `predict`: status, offerNow (a demo: past the bar), accept, dismiss,
 * explain. Agents can't call it (desktop-mcp's shellIpcDenyTargets).
 */
Singleton {
    id: root
    // Referenced at startup (shell.qml): its IPC target exists from the start.
    function load() {}

    readonly property int policy: Config.options?.policies?.ai ?? 1
    readonly property var cfg: Config.options?.ai?.predict ?? ({})
    readonly property bool enabled: (root.cfg.enable ?? true) && root.policy !== 0
    readonly property real threshold: Math.max(0.05, Math.min(1, Number(root.cfg.threshold ?? 0.5)))
    readonly property int minCount: Math.max(1, Number(root.cfg.minCount ?? 4))
    readonly property int showMs: 12000

    // What the chip shows (null: none): predict's offer {id, kind, action,
    // label, chip, explain, p, n, model, app?, desktop?, layout?, url?,
    // minutes?, routine?, instruction?}; `last` the one fading out.
    property var offer: null
    property var last: null
    // The chip's surface stays a moment after the offer goes, for its fade.
    property bool lingering: false
    readonly property bool chipMapped: root.offer !== null || root.lingering
    // The output it shows on: the focused one when it came.
    property string screenName: ""
    // Hovered or its menu open: it doesn't fade meanwhile.
    property bool held: false
    // Asked for (offerNow, a demo): shown whatever is going on.
    property bool forced: false
    property string lastWhy: ""
    signal offered(var offer)

    function blocked() {
        return GlobalStates.screenLocked || Idle.screensOff || FullAi.active || Initiative.busy()
            || Initiative.speaking !== null || DesktopControl.active
    }

    function _openApps() {
        const seen = [];
        for (const w of WM.windowList) {
            const a = String(w.appId ?? "").toLowerCase();
            if (a && !seen.includes(a)) seen.push(a);
        }
        return seen;
    }

    // Something happened: counted, and the step to offer now asked for in the
    // same call (none while the chip couldn't show).
    function observe(obs) {
        if (!root.enabled || GlobalStates.screenLocked || DesktopControl.active) return;
        const top = ToplevelManager.activeToplevel;
        const req = Object.assign({}, obs, {
            lang: ConfigAssistant.uiLang(), threshold: root.threshold, minCount: root.minCount,
            focused: String(top?.appId ?? "").toLowerCase(), openApps: root._openApps(),
            // One asked for (offerNow) stays until it is answered or fades.
            predict: !root.blocked() && !(root.forced && root.offer !== null)
        });
        DesktopHelper.run(["predict", "observe", JSON.stringify(req)], "", (code, out) => root._answer(out));
    }
    function _answer(out) {
        let a;
        try {
            a = JSON.parse(out);
        } catch (e) {
            return;
        }
        root.lastWhy = a.why ?? "";
        // Done by hand while it was offered: it goes, nothing to learn.
        if (root.offer && (a.done ?? []).includes(root.offer.id)) root._hide();
        if (a.offer) root._show(a.offer);
    }
    function _show(o) {
        if (root.blocked()) return;
        root.screenName = WM.focusedMonitor?.name ?? root.screenName;
        root.lingering = false;
        root.offer = o;
        root.last = o;
        root.held = false;
        root.forced = false;
        fade.restart();
        root.offered(o);
    }
    function _hide() {
        if (!root.offer) return;
        root.offer = null;
        root.held = false;
        fade.stop();
        root.lingering = true;
        linger.restart();
    }
    // What came of it, to the predictor (it learns), and the chip goes.
    function _answerOffer(outcome) {
        const o = root.offer;
        if (!o) return null;
        root._hide();
        DesktopHelper.run(["predict", "feedback", o.id, outcome], "", () => {});
        return o;
    }
    Timer {
        id: fade
        interval: root.showMs
        onTriggered: {
            if (root.held) {
                fade.restart();
                return;
            }
            root._answerOffer("ignored");
        }
    }
    Timer {
        id: linger
        interval: 400
        onTriggered: root.lingering = false
    }
    // Something that hides the chip (Do Not Disturb, a fullscreen window, the
    // lock, an agent acting…) takes it away: nothing learned, the user never
    // turned it down. Ticks only while a chip shows.
    Timer {
        running: root.offer !== null
        interval: 1000
        repeat: true
        onTriggered: if (!root.forced && root.blocked()) root._answerOffer("done")
    }

    function accept() {
        const o = root._answerOffer("accepted");
        if (!o) return "";
        root._do(o);
        return o.label;
    }
    function dismiss() { root._answerOffer("dismissed"); }
    // "Never after this" (after this cue), "Never suggest this" (anywhere).
    function never(anywhere) { root._answerOffer(anywhere ? "never_any" : "never"); }

    // The step, done as the user's own action.
    function _do(o) {
        switch (o.kind) {
        case "app": {
            const wins = WM.windowList.filter(w => String(w.appId ?? "").toLowerCase() === o.app);
            wins.sort((a, b) => b.focusedAt - a.focusedAt);
            if (wins.length > 0) {
                WM.focusWindow(wins[0].id);
                break;
            }
            const entry = (o.desktop ? DesktopEntries.byId(o.desktop) : null) ?? DesktopEntries.heuristicLookup(o.app);
            if (entry) AppLaunch.launchEntry(entry);
            else Quickshell.execDetached(["notify-send", "-a", "Muse", "-i", "dialog-warning", Translation.tr("Next up"),
                Translation.tr("Can't find how to start %1").arg(o.app)]);
            break;
        }
        case "layout":
            WindowLayouts.restore(o.layout);
            break;
        case "url":
            AppLaunch.openUrl(o.url);
            break;
        case "timer":
            TimerService.resetCountdown();
            TimerService.addCountdownMinutes(o.minutes);
            TimerService.toggleCountdown();
            break;
        case "focus":
            if (!TimerService.pomodoroRunning) TimerService.togglePomodoro();
            break;
        case "routine":
            // Its own rules apply there (the desktop-control pause for what
            // drives the desktop).
            Quickshell.execDetached(["nixbook-desktop-mcp", "routine", "run", o.routine, JSON.stringify({ event: "predict" })]);
            break;
        case "followup":
            // An order for Muse: a model, only with AI online.
            if (root.policy === 1) QuickAi.command(o.instruction, "predict", o.label);
            break;
        }
    }

    // ── What it watches ──
    // An app in front 5 s (passing through isn't using it).
    property string _focusApp: ""
    Connections {
        target: ToplevelManager
        enabled: root.enabled
        function onActiveToplevelChanged() {
            focusSettle.restart();
            prSettle.restart();
        }
    }
    Connections {
        target: ToplevelManager.activeToplevel
        enabled: root.enabled
        ignoreUnknownSignals: true
        function onTitleChanged() { prSettle.restart(); }
    }
    Timer {
        id: focusSettle
        interval: 5000
        onTriggered: {
            const top = ToplevelManager.activeToplevel;
            const app = String(top?.appId ?? "");
            if (!app || app.toLowerCase() === root._focusApp) return;
            root._focusApp = app.toLowerCase();
            const entry = DesktopEntries.heuristicLookup(app);
            // The title only to tell a private window (never kept).
            root.observe({ kind: "app", app: app.toLowerCase(), title: String(top?.title ?? ""),
                name: entry?.name ?? "", desktop: entry?.id ?? "" });
        }
    }
    // A pull request (GitHub) or merge request (GitLab) open in front.
    readonly property var prTitle: /· Pull Request #\d+ · ([\w.-]+\/[\w.-]+)|\(!\d+\) · Merge requests · ([^·]+) ·/
    property var _prSeen: []
    Timer {
        id: prSettle
        interval: 1500
        onTriggered: {
            const title = String(ToplevelManager.activeToplevel?.title ?? "");
            const m = root.prTitle.exec(title);
            if (!m || root._prSeen.includes(title)) return;
            root._prSeen = [...root._prSeen, title].slice(-50);
            root.observe({ kind: "event", event: "pr_page", repo: String(m[1] ?? m[2] ?? "").trim() });
        }
    }
    // A layout restored by the user (an agent's restore is skipped: observe
    // does nothing while one acts).
    Connections {
        target: WindowLayouts
        enabled: root.enabled
        function onRestoringChanged() {
            if (WindowLayouts.restoring && WindowLayouts.restoringName.length > 0)
                root.observe({ kind: "layout", name: WindowLayouts.restoringName });
        }
    }
    Connections {
        target: AppLaunch
        enabled: root.enabled
        function onUrlOpened(url) { root.observe({ kind: "url", url: url }); }
    }
    Connections {
        target: TimerService
        enabled: root.enabled
        function onCountdownRunningChanged() {
            if (TimerService.countdownRunning && TimerService.countdownDuration >= 60)
                root.observe({ kind: "timer", minutes: Math.round(TimerService.countdownDuration / 60) });
        }
        function onPomodoroRunningChanged() {
            if (TimerService.pomodoroRunning && !TimerService.pomodoroBreak) root.observe({ kind: "focus" });
        }
    }
    Connections {
        target: RecentContext
        enabled: root.enabled
        function onFailedCommand(command, cwd) { root.observe({ kind: "event", event: "command_failed", command: command }); }
    }
    Connections {
        target: Routines
        enabled: root.enabled
        function onHappened(ev) {
            const e = ev?.event ?? "";
            if (e === "day_start" || e === "unlocked") root.observe({ kind: "event", event: e });
            else if (e === "back" && (ev.away ?? 0) >= 30) root.observe({ kind: "event", event: "back" });
            else if (e === "download") root.observe({ kind: "event", event: "download", name: ev.name, ext: ev.ext, path: ev.path });
            else if (["monitor_connected", "wifi_connected", "audio_output", "bluetooth_connected"].includes(e))
                root.observe({ kind: "event", event: e, name: ev.name ?? "" });
        }
        function onRan(r) { root.observe({ kind: "event", event: "routine_ran", id: r?.id ?? "", name: r?.text ?? "" }); }
    }
    // A meeting over: a one-shot timer to the end of the next timed event
    // (none ticking in between), set again when the calendar changes.
    Timer {
        id: meetingEnd
        property var event: null
        onTriggered: {
            const e = meetingEnd.event;
            meetingEnd.event = null;
            // A far end is waited for in steps of 6 hours.
            if (e && new Date() >= e.end) root.observe({ kind: "event", event: "meeting_end", title: e.summary ?? "", at: Qt.formatTime(e.start, "hh:mm") });
            armMeeting.restart();
        }
    }
    function _armMeeting() {
        const now = new Date();
        // Hours-long blocks (a day off, travel) aren't meetings.
        const next = CalendarEvents.upcoming(8, now, true)
            .filter(e => e.end > now && e.end - e.start <= 4 * 3600000)
            .sort((a, b) => a.end - b.end)[0];
        if (!root.enabled || !next) {
            meetingEnd.stop();
            meetingEnd.event = null;
            return;
        }
        meetingEnd.event = next;
        // Timer intervals are 32-bit: a far one is set again on the way.
        meetingEnd.interval = Math.max(1000, Math.min(next.end - now + 5000, 6 * 3600000));
        meetingEnd.restart();
    }
    Timer {
        id: armMeeting
        interval: 2000
        onTriggered: root._armMeeting()
    }
    Connections {
        target: CalendarEvents
        function onEventsByDayChanged() { armMeeting.restart(); }
    }
    onEnabledChanged: armMeeting.restart()
    Component.onCompleted: armMeeting.restart()

    IpcHandler {
        target: "predict"
        function status(): string {
            return JSON.stringify({ enabled: root.enabled, threshold: root.threshold, minCount: root.minCount,
                offer: root.offer, lastWhy: root.lastWhy, blocked: root.blocked() });
        }
        // A demo: the best step now, past the threshold and the rests.
        function offerNow(): string {
            if (!root.enabled) return "error: off (ai.predict.enable, policies.ai)";
            const top = ToplevelManager.activeToplevel;
            const req = { lang: ConfigAssistant.uiLang(), threshold: root.threshold, minCount: root.minCount,
                focused: String(top?.appId ?? "").toLowerCase(), openApps: root._openApps(), force: true };
            DesktopHelper.run(["predict", "offer", JSON.stringify(req)], "", (code, out) => {
                try {
                    const a = JSON.parse(out);
                    root.lastWhy = a.why ?? "";
                    // Shown even while busy: asked for.
                    if (a.offer) {
                        root.screenName = WM.focusedMonitor?.name ?? root.screenName;
                        root.lingering = false;
                        root.offer = a.offer;
                        root.last = a.offer;
                        root.forced = true;
                        fade.restart();
                        root.offered(a.offer);
                    }
                } catch (e) {}
            });
            return "ok";
        }
        function accept(): string { return root.accept() || "nothing offered"; }
        function dismiss(): void { root.dismiss(); }
        function explain(): string { return root.offer ? root.offer.explain : (root.lastWhy || "nothing offered"); }
    }
}
