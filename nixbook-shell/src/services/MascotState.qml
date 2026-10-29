pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

/**
 * Muse living on the desktop (ai.mascot): the Full AI mascot, small in a
 * corner of the focused screen (modules/ii/fullAi/DesktopMascot.qml), so
 * it feels present all the time, not only in Full AI mode. Everything it
 * does is plain code, no model:
 *   - it looks toward the window that gets the focus (where it is on the
 *     screen, or the screen it is on), then back at the user;
 *   - a notification: it perks up and peeks at the popups; an error one
 *     (critical, or "error", "failed"… in four languages) worries it;
 *   - idle `dozeMinutes`: it dozes; back: it stretches awake;
 *   - something succeeding (a turn of Muse's that acted, a background task
 *     done, a command that failed then worked in a terminal, a download):
 *     a little jump; failing: a wobble, worried;
 *   - Muse's agent working (the bubble, the side panel, a background task):
 *     it thinks (dots); acting: determined; listening: its ears; and it
 *     lip-syncs while the voice speaks (the speaker's progress lines say
 *     which sentence plays: the overlay opens its mouth on its vowels).
 * Rarely, a quip (ai.mascot.quips): a one-liner from the small model about
 * what is going on, through `nixbook-desktop-mcp initiative consider`
 * {event: "quip"} (desktop-mcp.py quip_consider: 20–40 min apart at random,
 * quipsPerDay, quiet hours, busy, desktop control paused, soon after an
 * initiative word: nothing; masked for the provider, real names back).
 * Hidden while locked, in front of a fullscreen window, in Full AI mode
 * (its stage has the mascot), with policies.ai 0, and from an agent's
 * screenshots (MakeWay). No quips with policies.ai 2: the reactions only.
 * IPC `mascot`: show, hide, toggle, react MOOD, quip, say TEXT, status
 * (denied to agents: desktop-mcp's shellIpcDenyTargets).
 */
Singleton {
    id: root
    // Referenced at startup (shell.qml): its IPC target exists from the start.
    function load() {}

    readonly property int policy: Config.options?.policies?.ai ?? 1
    readonly property var cfg: Config.options?.ai?.mascot ?? ({})
    // On the desktop outside Full AI mode too (off by default: the mascot
    // is Full AI mode's; its reactions play on the Full AI stage then).
    readonly property bool enabled: (root.cfg.enable ?? false) && root.policy !== 0
    readonly property string corner: ["bottomRight", "bottomLeft", "topRight", "topLeft"].includes(root.cfg.corner)
        ? root.cfg.corner : "bottomRight"
    readonly property bool quipsOn: root.enabled && root.policy === 1 && (root.cfg.quips ?? true)
    readonly property int quipsPerDay: Math.max(0, root.cfg.quipsPerDay ?? 6)
    readonly property int dozeMinutes: Math.max(1, root.cfg.dozeMinutes ?? 3)
    // `mascot hide` (until `show`, or the shell restarts).
    property bool hiddenByUser: false

    // The output it lives on: the focused one, a moment after the focus
    // moves there (moving a mapped surface recreates it: not on every
    // glance at another screen).
    property string screenName: ""
    Timer {
        id: follow
        interval: 1500
        onTriggered: {
            const name = WM.focusedMonitor?.name ?? "";
            if (name) root.screenName = name;
        }
    }
    Connections {
        target: WM
        function onFocusedMonitorChanged() { follow.restart(); }
    }
    Component.onCompleted: follow.restart()

    readonly property bool fullscreen: root.screenName !== "" && WM.fullscreenOnMonitor(root.screenName)
    readonly property bool shown: root.enabled && !root.hiddenByUser && !GlobalStates.screenLocked
        && !FullAi.active && !root.fullscreen
    // A mascot on screen to react: the desktop one, or Full AI mode's.
    readonly property bool live: root.policy !== 0 && (root.shown || FullAi.active)
    // Nothing animates while nobody can see it.
    readonly property bool asleep: Idle.screensOff || !root.live

    // ── Mood ──
    // A short one after something happened: happy, worried, sad, or one
    // asked over IPC (any of the mascot's moods).
    property string flash: ""
    function setFlash(mood, ms) {
        root.flash = mood;
        flashOff.interval = ms ?? 2400;
        flashOff.restart();
    }
    Timer {
        id: flashOff
        interval: 2400
        onTriggered: root.flash = ""
    }
    readonly property bool working: Initiative.thinking || QuickAi.busy || Ai.responding || MuseTasks.running.length > 0
    readonly property bool acting: QuickAi.busy && QuickAi.steps.some(s => s.status === "run")
    property bool dozing: false
    readonly property string mood: {
        if (Voice.speaking) return "speaking";
        if (root.flash) return root.flash;
        if (Voice.listening) return "listening";
        if (root.acting) return "acting";
        if (root.working) return "thinking";
        if (root.dozing) return "sleepy";
        return "idle";
    }
    // One-shot moves for the overlay's mascot: hop, celebrate, shake,
    // stretch, perk.
    signal reaction(string kind)

    // ── Where it looks: a point on its screen (0..1 of its size), held a
    // few seconds, then back at the user (null).
    property var gaze: null
    function lookAt(x, y, ms) {
        root.gaze = { x: Math.max(0, Math.min(1, x)), y: Math.max(0, Math.min(1, y)) };
        gazeOff.interval = ms ?? 3500;
        gazeOff.restart();
    }
    Timer {
        id: gazeOff
        interval: 3500
        onTriggered: root.gaze = null
    }
    // The focused window's place, from niri's layout: a floating one's
    // rect; a tiled one's column among its workspace's columns (niri gives
    // tiled windows no position: the view scrolls); another screen: that
    // way.
    function _lookAtFocused() {
        if (root.asleep) return;
        const w = WM.windowList.find(x => x.focused);
        if (!w) return;
        const ws = WM.workspaceById[w.workspaceId];
        const here = WM.monitors.find(m => m.name === root.screenName);
        const there = WM.monitors.find(m => m.name === ws?.output);
        if (here?.logical && there?.logical && there.name !== here.name) {
            const dx = (there.logical.x + there.logical.width / 2) - (here.logical.x + here.logical.width / 2);
            const dy = (there.logical.y + there.logical.height / 2) - (here.logical.y + here.logical.height / 2);
            root.lookAt(dx < 0 ? 0 : dx > 0 ? 1 : 0.5, dy < 0 ? 0 : dy > 0 ? 1 : 0.5);
            return;
        }
        const lw = here?.logical?.width ?? 0, lh = here?.logical?.height ?? 0;
        if (w.floating && w.tileX !== null && lw > 0 && lh > 0) {
            root.lookAt((w.tileX + w.tileWidth / 2) / lw, (w.tileY + w.tileHeight / 2) / lh);
            return;
        }
        if (w.column !== null) {
            const cols = [];
            for (const x of WM.windowList)
                if (x.workspaceId === w.workspaceId && !x.floating && x.column !== null && !cols.includes(x.column)) cols.push(x.column);
            cols.sort((a, b) => a - b);
            const i = cols.indexOf(w.column);
            root.lookAt(cols.length <= 1 ? 0.5 : (i + 0.5) / cols.length, 0.45);
        }
    }
    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() { lookSoon.restart(); }
    }
    // The layout catches up with the focus a moment later.
    Timer {
        id: lookSoon
        interval: 120
        onTriggered: root._lookAtFocused()
    }

    // ── Notifications: a peek, or worried by an error ──
    // (\b is ASCII-only in JS: the accented words go without it.)
    readonly property var errorWords: /\b(error|failed|failure|crash(ed)?|erreur|fehler|fehlgeschlagen)\b|échec|échoué|lỗi|thất bại/i
    readonly property var ownApps: FullAi.ownApps
    Connections {
        target: Notifications
        function onNotify(n) {
            if (root.asleep || Notifications.silent || !n) return;
            if (root.ownApps.includes(String(n.appName ?? "").toLowerCase())) return;
            const critical = n.urgency === "critical" || String(n.urgency) === "2";
            if (critical || root.errorWords.test(`${n.summary ?? ""} ${n.body ?? ""}`)) {
                root.setFlash("worried", 4000);
                root.reaction("shake");
            } else {
                root.reaction("perk");
            }
            const pos = String(Config.options?.notifications?.position ?? "top_right");
            root.lookAt(pos.endsWith("left") ? 0.04 : pos.endsWith("right") || pos === "top" || pos === "bottom" ? 0.96 : 0.5,
                pos.startsWith("bottom") ? 0.96 : 0.04, 2500);
        }
    }

    // ── Something done: a jump; failed: a wobble ──
    Connections {
        target: QuickAi
        function onBusyChanged() {
            // Decided a moment later: the session marks the answer done just
            // after it stops (as FullAi._taskEnded).
            if (!QuickAi.busy) Qt.callLater(root._turnEnded);
        }
    }
    function _turnEnded() {
        if (QuickAi.busy || root.asleep) return;
        const r = QuickAi.report;
        if (QuickAi.error.length > 0 || (r && r.ko > 0 && r.ok === 0)) {
            root.setFlash("sad", 2200);
            root.reaction("shake");
        } else if ((r && r.ok > 0) || QuickAi.steps.some(s => s.status === "ok")) {
            root.setFlash("happy", 1800);
            root.reaction("celebrate");
        }
    }
    // A background task's end (MuseTasks: running → done / failed).
    property var _taskStatus: ({})
    Connections {
        target: MuseTasks
        function onTasksChanged() {
            const seen = {};
            for (const t of MuseTasks.tasks) {
                const before = root._taskStatus[t.id];
                seen[t.id] = t.status;
                if (before !== "running" && before !== "waiting") continue;
                if (t.status === "done") {
                    root.setFlash("happy", 1800);
                    root.reaction("celebrate");
                } else if (t.status === "failed") {
                    root.setFlash("worried", 3000);
                    root.reaction("shake");
                }
            }
            root._taskStatus = seen;
        }
    }
    // A command that failed, then worked (the terminal hook's
    // terminal-fixed; RecentContext watches it while this is on).
    Connections {
        target: RecentContext
        function onCommandFixed(command) {
            if (root.asleep) return;
            root.setFlash("happy", 1600);
            root.reaction("hop");
        }
    }
    Connections {
        target: Routines
        function onHappened(ev) {
            if (root.asleep || !ev) return;
            if (ev.event === "download" || ev.event === "screenshot") root.reaction("hop");
            else if (ev.event === "battery_low") {
                root.setFlash("worried", 4000);
                root.reaction("shake");
            }
        }
    }

    // ── Dozing ──
    IdleMonitor {
        id: idle
        enabled: root.shown
        timeout: root.dozeMinutes * 60
        respectInhibitors: true
        onIsIdleChanged: {
            if (idle.isIdle) {
                root.dozing = true;
            } else if (root.dozing) {
                root.dozing = false;
                root.reaction("stretch");
            }
        }
    }
    onShownChanged: if (!root.shown) root.dozing = false

    // ── Quips ──
    // What it says in its little balloon now ("" none), a few seconds.
    property string line: ""
    function say(text) {
        root.line = String(text ?? "").trim().slice(0, 160);
        lineOff.interval = Math.max(6000, Math.min(14000, root.line.length * 120));
        lineOff.restart();
        if (root.line) root.reaction("hop");
    }
    Timer {
        id: lineOff
        interval: 9000
        onTriggered: root.line = ""
    }
    property bool asking: false
    property string lastWhy: ""
    function quipNow(force) {
        if (root.asking || !root.quipsOn) return;
        root.asking = true;
        const top = ToplevelManager.activeToplevel;
        const ev = { event: "quip", force: force === true, perDay: root.quipsPerDay,
                     app: top?.appId ?? "", title: top?.title ?? "", lang: ConfigAssistant.uiLang(),
                     busy: Initiative.busy() };
        DesktopHelper.run(["initiative", "consider", JSON.stringify(ev)], "", (code, out) => {
            root.asking = false;
            try {
                const a = JSON.parse(out);
                root.lastWhy = a.why ?? "";
                // Not over a conversation going on, nor after it hid.
                if (a.action === "quip" && a.text && root.shown && !root.working && Initiative.speaking === null)
                    root.say(a.text);
            } catch (e) {
                root.lastWhy = "no answer";
            }
        });
    }
    // Asks every few minutes; whether one is due is kept by
    // nixbook-desktop-mcp (20–40 minutes apart, the day's budget), so a
    // shell restart doesn't start the wait over.
    Timer {
        running: root.quipsOn && root.quipsPerDay > 0 && root.shown && !Idle.screensOff && !root.dozing
        interval: 5 * 60000
        repeat: true
        onTriggered: {
            if (root.working || Voice.speaking || Initiative.speaking !== null) return;
            root.quipNow(false);
        }
    }

    // "Next up" offered a step (its chip sits beside the mascot): it perks
    // up, so the eye goes to the chip.
    Connections {
        target: NextUp
        function onOffered(offer) {
            if (root.asleep) return;
            root.reaction("perk");
        }
    }
    IpcHandler {
        target: "mascot"
        function show(): void { root.hiddenByUser = false; }
        function hide(): void { root.hiddenByUser = true; }
        function toggle(): void { root.hiddenByUser = !root.hiddenByUser; }
        // A mood for a few seconds (idle, listening, thinking, acting,
        // speaking, happy, sad, muted, sleepy, worried), or a move (hop,
        // celebrate, shake, stretch, perk).
        function react(mood: string): string {
            const moves = ["hop", "celebrate", "shake", "stretch", "perk"];
            const moods = ["idle", "listening", "thinking", "acting", "speaking", "happy", "sad", "muted", "sleepy", "worried"];
            if (moves.includes(mood)) {
                root.reaction(mood);
                return "ok";
            }
            if (!moods.includes(mood)) return `error: ${moves.concat(moods).join(", ")}`;
            root.setFlash(mood, 5000);
            if (mood === "happy") root.reaction("celebrate");
            else if (mood === "worried" || mood === "sad") root.reaction("shake");
            return "ok";
        }
        function quip(): void { root.quipNow(true); }
        function say(text: string): void { root.say(text); }
        function status(): string {
            return JSON.stringify({ enabled: root.enabled, shown: root.shown, screen: root.screenName, corner: root.corner,
                mood: root.mood, line: root.line, quips: root.quipsOn, lastQuip: root.lastWhy });
        }
    }
}
