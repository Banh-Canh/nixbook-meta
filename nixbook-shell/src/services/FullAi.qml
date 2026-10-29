pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Full AI mode (Mod+Shift+T, `fullAi toggle`): the AI runs the desktop and
 * the user talks to it. A cute mascot (modules/ii/fullAi) moves around the
 * screen as the MC: it shows what it hears, what it is doing and what it
 * answers, over a glow at the screens' edges (FullAiOverlay.qml) that takes
 * neither keys nor clicks: the user keeps their desktop. Mod+T mutes or
 * unmutes the microphone, Mod+Shift+T (or Escape in the bubble) leaves.
 * With ai.quick.bubble "needed" the bubble stays out of sight
 * (Initiative.quiet): the mascot's balloon and its voice answer.
 * The microphone stays open the whole time, also while the agent works: a
 * new order takes over (Muse's agent, in the speech bubble's session, which
 * keeps the conversation and goes on in the side panel when expanded).
 * It reacts to what happens (ai.fullAi.react): a notification, a download,
 * the battery, a screen or an audio output plugged in, the network lost,
 * the user back: the model (`nixbook-quick-ai` react mode) ignores it,
 * tells it, asks what to do ("Julien asks if you come tonight. Shall I say
 * yes?") or does it — alone only on what the user told it (this session,
 * a note, a routine) or chose twice before. Every reaction and the user's
 * answer is kept (`nixbook-quick-ai learn`, full-ai-learned.json) and given
 * back the next time: it keeps learning what the user wants. What happens
 * comes from the one event reactor (services/Reactor.qml), first while the
 * mode is on (one model decision per event, the initiative gets the rest),
 * within ai.fullAi.reactPerHour model decisions an hour.
 */
Singleton {
    id: root
    // Referenced at startup (shell.qml): its IPC target exists from the start.
    function load() {}

    property bool active: false
    property bool micOn: true
    // The output the mascot lives on (the focused one when entering).
    property string screenName: ""
    // A short reaction after a task: "happy" or "sad", for a moment.
    property string flash: ""
    // What it last said, shown a while in its balloon.
    property string said: ""

    readonly property string mood: {
        if (!root.active) return "idle";
        if (root.flash) return root.flash;
        if (root.reacting) return "thinking";
        if (Voice.speaking || talk.running) return "speaking";
        if (QuickAi.busy) return QuickAi.steps.some(s => s.status === "run") ? "acting" : "thinking";
        if (!root.micOn) return "muted";
        if (Voice.listening && Voice.heard) return "listening";
        return Voice.listening ? "listening" : "idle";
    }
    // The mascot's balloon: the words heard, the step under way, the answer.
    // A question waiting for the user, shown in the balloon until answered
    // (the bubble needn't be called up): the step it asks leave for (Yes /
    // No answer it), or its last answer asking back (a clarifying
    // question, or ending with "?"; a yes/no one gets Yes / No too).
    property var oldMessages: ({})
    readonly property var question: {
        if (!root.active) return null;
        const p = QuickAi.pending;
        if (p) return { text: Translation.tr("May I %1?").arg(String(p.tool ?? "").replace(/_/g, " ")
                + (p.summary ? ` (${p.summary})` : "")), yesNo: true, approval: true };
        if (QuickAi.busy || Initiative.thinking) return null;
        const chat = Initiative.chat;
        const ids = chat?.messageIDs ?? [];
        const id = ids.length > 0 ? ids[ids.length - 1] : "";
        const m = id ? chat.messageByID[id] : null;
        if (!m || m.role !== "assistant" || root.oldMessages[id]) return null;
        const t = Voice._plain(m).replace(/\s+/g, " ").trim();
        if (!m.clarify && !/\?\s*$/.test(t)) return null;
        // The question itself: its last sentence (the rest was said).
        const parts = t.match(/[^.!?…]+[.!?…]*/g) ?? [t];
        const q = (parts[parts.length - 1] ?? t).trim();
        const yesNo = !m.clarify && /^(do|does|did|should|shall|can|could|would|will|is|are|want|may|voulez|veux|dois|est-ce|faut-il|puis-je|souhaites|soll|willst|möchtest|kann|darf|ist|sind)\b/i.test(q)
            || /\bkhông\s*\?$/i.test(q);
        return { text: q.slice(0, 300), yesNo: yesNo, approval: false };
    }
    function answer(yes) {
        const q = root.question;
        if (!q) return;
        if (q.approval) QuickAi.approve(yes);
        else Initiative.reply(yes ? Translation.tr("Yes") : Translation.tr("No"));
    }
    // The balloon: what it says ("say": a speech bubble, the words as they
    // are said — never ahead of the voice), what it thinks or does
    // ("thought": a thought cloud), what it hears ("heard": the user's words)
    // and how to talk to it ("status").
    // What fits the balloon: whitespace squashed (an agent's answer has
    // blank lines where its steps were: they ate the six lines and left
    // "…"), and the latest sentences — what is being said now, or how it
    // ended — not the beginning cut short.
    function tailOf(text, max = 220) {
        const t = String(text ?? "").replace(/\s+/g, " ").trim();
        if (t.length <= max) return t;
        const parts = t.match(/[^.!?…]+[.!?…]*\s*/g) ?? [t];
        let out = "";
        for (let i = parts.length - 1; i >= 0; i--) {
            if (out.length > 0 && out.length + parts[i].length > max) break;
            out = parts[i] + out;
        }
        out = out.trim();
        return out.length > max ? "…" + out.slice(out.length - max + 1) : out;
    }
    readonly property var balloon: {
        if (!root.active) return { text: "", kind: "status" };
        const saying = Voice.saying;
        if (Voice.listening && Voice.partial.length > 0) return { text: `“${Voice.partial}”`, kind: "heard" };
        if (saying !== null && saying !== undefined)
            return saying.trim().length > 0 ? { text: root.tailOf(saying), kind: "say" } : { text: "…", kind: "thought" };
        if (root.question) return { text: root.question.text, kind: "ask" };
        if (root.reacting) return { text: root.reactingLine, kind: "thought" };
        if (QuickAi.busy) {
            const step = [...QuickAi.steps].reverse().find(s => s.status === "run") ?? QuickAi.steps[QuickAi.steps.length - 1];
            if (step) return { text: `${step.tool.replace(/_/g, " ")}${step.summary ? " · " + step.summary : ""}…`, kind: "thought" };
            return { text: Translation.tr("Thinking…"), kind: "thought" };
        }
        if (root.said.length > 0) return { text: root.tailOf(root.said), kind: "say" };
        if (!root.micOn) return { text: Translation.tr("Mic off. Mod+T to talk to me again."), kind: "status" };
        return { text: Translation.tr("I'm listening. What should I do?"), kind: "status" };
    }
    readonly property string line: root.balloon.text
    readonly property string lineKind: root.balloon.kind
    // Yes / No on the balloon while a yes/no question waits (clickable: the
    // overlay takes clicks there only).
    readonly property bool yesNo: root.lineKind === "ask" && (root.question?.yesNo ?? false)
    readonly property string hint: Translation.tr("Mod+Shift+T: leave Full AI · Mod+T: mic %1").arg(root.micOn ? Translation.tr("off") : Translation.tr("on"))

    // A new line in the balloon, said out loud in its cute voice (Voice.speak,
    // unless ai.voice.speak is "never": then its mouth moves a moment).
    function say(text) {
        root.said = String(text ?? "");
        saidOff.restart();
        talk.restart();
        Voice.speak(root.said);
    }
    Timer {
        id: talk
        interval: 2600
    }
    function enter() {
        if (root.active) return;
        if (!QuickAi.available) return QuickAi.refuse();
        root.screenName = WM.focusedMonitor?.name ?? Quickshell.screens[0]?.name ?? "";
        root.micOn = true;
        root.said = "";
        // What was asked before the mode started isn't asked now.
        const old = {};
        for (const id of (Initiative.chat?.messageIDs ?? [])) old[id] = true;
        root.oldMessages = old;
        root.active = true;
        Voice.session = true;
        // Out of sight unless wanted (ai.quick.bubble): the mascot's balloon.
        if (Voice.hideBubble) Initiative.quiet = true;
        QuickAi.askQuestion("", "voice");
        root.say(Translation.tr("I've got it from here. Tell me what to do."));
        // Listening at once (Voice.start also calls the bubble up).
        Voice.start();
    }
    function exit() {
        if (!root.active) return;
        root.active = false;
        root.queue = [];
        root.reacting = false;
        root.asked = null;
        root.flash = "";
        // Its reaction being decided: dropped with the mode.
        reactor.running = false;
        Voice.cancel();
    }
    // AI features switched off (policies.ai) or the key gone while on: the
    // mode ends (the mic stream with it), nothing more goes out.
    Connections {
        target: QuickAi
        function onAvailableChanged() {
            if (!QuickAi.available) root.exit();
        }
    }
    function toggle() {
        if (root.active) root.exit();
        else root.enter();
    }
    // Mod+T in Full AI mode: the microphone off or on (orders keep coming
    // while it is on, also while the agent works).
    function toggleMic() {
        root.micOn = !root.micOn;
        if (!root.micOn) {
            Voice.cancel();
            Voice.session = true;
        } else {
            Voice.session = true;
            Voice.start();
        }
    }

    // ── Reacting to what happens ──
    readonly property bool reactOn: Config.options.ai.fullAi?.react ?? true
    property var queue: []
    property bool reacting: false
    property string reactingLine: ""
    // The question it asked, waiting for the user's answer: {sig, at}.
    property var asked: null
    // What it just did on its own: the user saying no undoes the learning.
    property var didAlone: null
    // Its own words and the shell's: not events.
    // (desktop-mcp.py's INITIATIVE_OWN_APPS names the same.)
    readonly property var ownApps: ["quick ai", "muse", "desktop agent", "desktop agents", "snoozed", "nixbook", "nixbook-shell",
        "nixbook-desktop-mcp", "quickshell", "shell", "window layouts", "usage habits", "screenshot", "recorder", "reminder", "calendar"]
    readonly property var reactEvents: ["download", "battery_low", "monitor_connected", "monitor_disconnected",
        "audio_output", "wifi_disconnected", "back", "day_start"]
    function event(ev) {
        if (!root.active || !root.reactOn) return;
        if (ev.event === "back" && (ev.away ?? 0) < 10) return;
        // A burst from one app: one event, its messages together (two
        // people writing in a second mustn't lose the first).
        const same = root.queue.find(q => q.event === ev.event && q.app && q.app === ev.app);
        if (same && ev.event === "notification") {
            const merged = Object.assign({}, ev, {
                title: same.title === ev.title ? ev.title : `${same.title} / ${ev.title}`.slice(0, 200),
                text: `${same.text ?? ""}\n${ev.title && same.title !== ev.title ? ev.title + ": " : ""}${ev.text ?? ""}`.trim().slice(-900),
                urgency: same.urgency === "critical" ? "critical" : ev.urgency });
            root.queue = root.queue.map(q => q === same ? merged : q);
        } else {
            root.queue = root.queue.filter(q => !(q.event === ev.event && q.app && q.app === ev.app)).concat([ev]).slice(-6);
        }
        pump.restart();
    }
    // Registered with the Reactor before the initiative (priority 0).
    Component.onCompleted: Reactor.register("fullAi", 0, {
        wants: ev => root._wants(ev),
        take: ev => root._take(ev),
    })
    function _wants(ev) {
        if (!root.active || !root.reactOn || !QuickAi.available) return false;
        if (ev.event === "notification")
            return !ev.transient && !root.ownApps.includes(String(ev.app ?? "").toLowerCase());
        if (ev.event === "back") return (ev.away ?? 0) >= 10;
        return root.reactEvents.includes(ev.event);
    }
    function _take(ev) {
        if (ev.event === "notification")
            root.event({ event: "notification", app: ev.app, title: ev.title, text: ev.text, urgency: ev.urgency, id: ev.id });
        else root.event(ev);
    }
    // One at a time, a moment after the last (a burst read as one), never
    // over an order of the user's being done or the mascot speaking.
    Timer {
        id: pump
        interval: 400
        onTriggered: {
            if (!root.active || root.reacting || root.queue.length === 0) return;
            if (QuickAi.busy || QuickAi.pending) { pump.restart(); return; }
            const ev = root.queue[0];
            root.queue = root.queue.slice(1);
            root.react(ev);
        }
    }
    function describe(ev) {
        if (ev.event === "notification") return `${ev.app}${ev.title ? " · " + ev.title : ""}${ev.text ? ": " + ev.text : ""}`;
        return [ev.event.replace(/_/g, " "), ev.name, ev.app, ev.percent !== undefined ? ev.percent + "%" : ""].filter(x => x).join(" · ");
    }
    function react(ev) {
        Reactor.spend("fullAi");
        root.reacting = true;
        root.reactingLine = "🔔 " + root.describe(ev).slice(0, 160);
        reactor.ev = ev;
        reactor.out = "";
        reactor.requestJson = JSON.stringify({ mode: "react", event: ev, lang: ConfigAssistant.uiLang(),
            facts: QuickAi.facts(), recent: QuickAi.recentText(12),
            // A decision on the user's behalf: the routing's decision model.
            model: Config.options.ai.routing?.decisions ?? "big", effort: Config.options.ai.routing?.decisionsEffort ?? "low" });
        reactor.running = true;
    }
    function decided(ev, d) {
        root.reacting = false;
        if (!d || !root.active) return;
        const said = d.say || "";
        // A lasting preference it heard: kept in the one memory (with the
        // app and the event's signature, so it comes back for the same kind).
        if (d.learn) Quickshell.execDetached(["nixbook-quick-ai", "learn",
            JSON.stringify({ pref: d.learn, app: ev.app ?? "", sig: d.sig ?? "" })]);
        if (d.action === "ignore") {
            pump.restart();
            return;
        }
        root.said = said;
        saidOff.restart();
        if (d.action === "tell") {
            QuickAi.adopt(root.describe(ev), said);
            if (said) root.say(said);
            root.remember(d.sig, "tell", "");
        } else if (d.action === "ask") {
            QuickAi.adopt(`Something happened: ${root.describe(ev)}. You asked the user: ${said}`, said);
            root.asked = { sig: d.sig, at: Date.now() };
            if (said) root.say(said);
        } else if (d.action === "do") {
            root.didAlone = { sig: d.sig, at: Date.now() };
            if (said) root.say(said);
            QuickAi.command(d.instruction, "react", said || root.describe(ev));
            root.remember(d.sig, "do", "did it");
        }
        pump.restart();
    }
    function remember(sig, decision, outcome, words = "") {
        Quickshell.execDetached(["nixbook-quick-ai", "learn",
            JSON.stringify({ sig: sig, decision: decision, outcome: outcome, said: words })]);
    }
    // What the user said next (Voice.deliver): the answer to its question,
    // or a no to what it just did alone; it learns from both.
    readonly property var yes: Voice.yesWords
    readonly property var no: Voice.noWords
    function userSaid(text) {
        const t = String(text ?? "").trim();
        if (root.asked && Date.now() - root.asked.at < 120000) {
            root.remember(root.asked.sig, "ask", root.no.test(t) ? "declined" : root.yes.test(t) ? "agreed" : "answered", t);
            root.asked = null;
        } else if (root.didAlone && Date.now() - root.didAlone.at < 45000 && root.no.test(t)) {
            root.remember(root.didAlone.sig, "do", "undone", t);
            root.didAlone = null;
            if (QuickAi.busy) QuickAi.stop();
        }
    }
    Process {
        id: reactor
        property var ev: ({})
        property string out: ""
        property string requestJson: "{}"
        command: ["bash", "-c", QuickAi.modelRun + 'dir="${XDG_RUNTIME_DIR:-/tmp}/nixbook-shell/quick-ai"; mkdir -p -m 700 "$dir"; '
            + 'f="$dir/react-$$.json"; trap \'rm -f "$f"\' EXIT; printf "%s" "$1" > "$f"; '
            + 'model nixbook-quick-ai ask "$f"', "_", reactor.requestJson]
        stdout: SplitParser {
            onRead: (line) => {
                let ev;
                try { ev = JSON.parse(line); } catch (e) { return; }
                if (ev.type === "react") reactor.out = line;
            }
        }
        onExited: {
            let d = null;
            try { d = reactor.out ? JSON.parse(reactor.out) : null; } catch (e) {}
            root.decided(reactor.ev, d);
        }
    }

    // A task done: a happy jump, or a wobble when something failed; the
    // answer's outcome stays in the balloon a while.
    Connections {
        target: QuickAi
        function onBusyChanged() {
            if (!root.active || QuickAi.busy) return;
            // Decided a moment later: the session marks the answer done just
            // after it stops; a turn that only looked over (before the agent
            // took it, its answer there, still empty) has no outcome yet.
            Qt.callLater(root._taskEnded);
        }
    }
    // A task over (Qt.callLater after QuickAi.busy turned off).
    function _taskEnded() {
        if (!root.active || QuickAi.busy || Voice._unfinished()) return;
        const r = QuickAi.report;
        const failed = QuickAi.error.length > 0 || (r && r.ko > 0 && r.ok === 0);
        root.flash = failed ? "sad" : (r || QuickAi.answer.length > 0 ? "happy" : "");
        const text = r?.summary || QuickAi.answer || QuickAi.error;
        // How it ended (the answer's last sentences), not its opening line.
        root.said = root.tailOf(text);
        flashOff.restart();
        saidOff.restart();
        talk.restart();
        // Said out loud: the report's outcome (and what needs the user),
        // unless the answer was read out as it streamed.
        if (!Voice.streamedTurn) Voice.speakLastAnswer(root.said);
    }
    Timer {
        id: flashOff
        interval: 1800
        onTriggered: root.flash = ""
    }
    Timer {
        id: saidOff
        interval: 12000
        onTriggered: root.said = ""
    }
    // Locked: out of the mode (the lock screen takes over).
    Connections {
        target: GlobalStates
        function onScreenLockedChanged() { if (GlobalStates.screenLocked) root.exit(); }
    }

    IpcHandler {
        target: "fullAi"
        function enter(): void { root.enter(); }
        function exit(): void { root.exit(); }
        function toggle(): void { root.toggle(); }
        function mic(): void { if (root.active) root.toggleMic(); }
        function status(): string {
            return JSON.stringify({ active: root.active, micOn: root.micOn, mood: root.mood, line: root.line, screen: root.screenName,
                react: root.reactOn, queued: root.queue.length, reacting: root.reacting });
        }
        // An event as if it had happened (tests): {event, app, title, text…}.
        function simulate(json: string): void {
            try { root.event(JSON.parse(json)); } catch (e) {}
        }
    }
}
