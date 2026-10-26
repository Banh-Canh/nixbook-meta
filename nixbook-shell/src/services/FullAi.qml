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
 * answers (also said out loud). The user's keyboard and mouse are taken by
 * a transparent layer over every screen (FullAiOverlay.qml): only Escape
 * (leave), and the compositor's own shortcuts — Mod+T mutes or unmutes the
 * microphone, Mod+Shift+T leaves — still work. The agent's own clicks and
 * keys go through (MakeWay, as for the shell's other overlays).
 * The microphone stays open the whole time, also while the agent works: a
 * new order takes over (Quick AI's agent, in Claude's speech bubble, which
 * keeps the conversation). It only closes while the voice speaks.
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
        if (Voice.speaking) return "speaking";
        if (QuickAi.busy) return QuickAi.steps.some(s => s.status === "run") ? "acting" : "thinking";
        if (!root.micOn) return "muted";
        if (Voice.listening && Voice.heard) return "listening";
        return Voice.listening ? "listening" : "idle";
    }
    // The mascot's balloon: the words heard, the step under way, the answer.
    readonly property string line: {
        if (!root.active) return "";
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
    readonly property string hint: Translation.tr("Esc: leave Full AI · Mod+T: mic %1").arg(root.micOn ? Translation.tr("off") : Translation.tr("on"))

    function enter() {
        if (root.active) return;
        if (!QuickAi.available) return QuickAi.refuse();
        root.screenName = WM.focusedMonitor?.name ?? Quickshell.screens[0]?.name ?? "";
        root.micOn = true;
        root.said = "";
        root.active = true;
        Voice.session = true;
        QuickAi.askQuestion("", "voice");
        Voice.speak(Translation.tr("I've got it from here. Tell me what to do."));
    }
    function exit() {
        if (!root.active) return;
        root.active = false;
        root.flash = "";
        Voice.cancel();
        Voice.stopSpeaking();
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
            return JSON.stringify({ active: root.active, micOn: root.micOn, mood: root.mood, line: root.line, screen: root.screenName });
        }
    }
}
