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
 * new order takes over (Quick AI's agent, in Muse's speech bubble, which
 * keeps the conversation).
 * It reacts to what happens (ai.fullAi.react): a notification, a download,
 * the battery, a screen or an audio output plugged in, the network lost,
 * the user back: the model (`nixbook-quick-ai` react mode) ignores it,
 * tells it, asks what to do ("Julien asks if you come tonight. Shall I say
 * yes?") or does it — alone only on what the user told it (this session,
 * a note, a routine) or chose twice before. Every reaction and the user's
 * answer is kept (`nixbook-quick-ai learn`, full-ai-learned.json) and given
 * back the next time: it keeps learning what the user wants.
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
    readonly property string line: {
        if (!root.active) return "";
        if (root.reacting) return root.reactingLine;
        if (Voice.listening && Voice.partial.length > 0) return `“${Voice.partial}”`;
        if (QuickAi.pending)
            return Translation.tr("May I %1? Say yes or no.").arg(QuickAi.pending.tool.replace(/_/g, " "));
        if (QuickAi.busy) {
            const step = [...QuickAi.steps].reverse().find(s => s.status === "run") ?? QuickAi.steps[QuickAi.steps.length - 1];
            if (step) return `${step.tool.replace(/_/g, " ")}${step.summary ? " · " + step.summary : ""}…`;
            return Translation.tr("Thinking…");
        }
        if (root.said.length > 0) return root.said;
        if (!root.micOn) return Translation.tr("Mic off. Mod+T to talk to me again.");
        return Translation.tr("I'm listening. What should I do?");
    }
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
        Voice.cancel();
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
    readonly property var ownApps: ["quick ai", "muse", "desktop agent", "snoozed", "nixbook", "nixbook-shell", "quickshell"]
    readonly property var reactEvents: ["download", "battery_low", "monitor_connected", "monitor_disconnected",
        "audio_output", "wifi_disconnected", "back", "day_start"]
    function event(ev) {
        if (!root.active || !root.reactOn) return;
        if (ev.event === "back" && (ev.away ?? 0) < 10) return;
        // A burst from one app: only its latest.
        root.queue = root.queue.filter(q => !(q.event === ev.event && q.app && q.app === ev.app)).concat([ev]).slice(-6);
        pump.restart();
    }
    Connections {
        target: Notifications
        function onNotify(n) {
            if (!root.active || !root.reactOn || n.isTransient) return;
            if (root.ownApps.includes(String(n.appName ?? "").toLowerCase())) return;
            root.event({ event: "notification", app: n.appName ?? "", title: n.summary ?? "",
                         text: String(n.body ?? "").replace(/<[^>]+>/g, "").slice(0, 600),
                         urgency: String(n.urgency ?? ""), id: n.notificationId });
        }
    }
    Connections {
        target: Routines
        function onHappened(ev) {
            if (root.reactEvents.includes(ev.event)) root.event(ev);
        }
    }
    // One at a time, a moment after the last (a burst read as one), never
    // over an order of the user's being done or the mascot speaking.
    Timer {
        id: pump
        interval: 1200
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
        root.reacting = true;
        root.reactingLine = "🔔 " + root.describe(ev).slice(0, 160);
        reactor.ev = ev;
        reactor.out = "";
        reactor.requestJson = JSON.stringify({ mode: "react", event: ev, lang: ConfigAssistant.uiLang(),
            facts: QuickAi.facts(), recent: QuickAi.recentText(12),
            model: Config.options.ai.quick?.model ?? "small" });
        reactor.running = true;
    }
    function decided(ev, d) {
        root.reacting = false;
        if (!d || !root.active) return;
        const said = d.say || "";
        if (d.learn) Quickshell.execDetached(["nixbook-quick-ai", "learn", JSON.stringify({ pref: d.learn })]);
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
    readonly property var yes: /^(yes|yeah|yep|sure|ok(ay)?|go( ahead)?|do it|please|oui|ouais|vas-?y|d'?accord|ja|klar|mach|c[oó]|[dđ][uư][oợ]c)\b/i
    readonly property var no: /^(no|nope|don'?t|stop|cancel|non|nein|kh[oô]ng|annule|laisse)\b/i
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
        command: ["bash", "-c", 'dir="${XDG_RUNTIME_DIR:-/tmp}/nixbook-shell/quick-ai"; mkdir -p -m 700 "$dir"; '
            + 'f="$dir/react-$$.json"; printf "%s" "$1" > "$f"; '
            + 'nixbook-model-provider run nixbook-quick-ai ask "$f"; rc=$?; rm -f "$f"; exit $rc', "_", reactor.requestJson]
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
            const r = QuickAi.report;
            const failed = QuickAi.error.length > 0 || (r && r.ko > 0 && r.ok === 0);
            root.flash = failed ? "sad" : (r || QuickAi.answer.length > 0 ? "happy" : "");
            const text = r?.summary || QuickAi.answer || QuickAi.error;
            root.said = String(text ?? "").replace(/\n[\s\S]*/, "").slice(0, 220);
            flashOff.restart();
            saidOff.restart();
            talk.restart();
            // Said out loud: the report's outcome (and what needs the user).
            Voice.speak(Voice.lastAnswer() || root.said);
        }
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
