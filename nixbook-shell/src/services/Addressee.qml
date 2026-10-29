pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import qs.modules.common.functions
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Muse only acts on what is said TO it (ai.voice.addressee). Full AI mode's
 * microphone never closes, so it hears the room too: someone else, the user
 * on a call, the user thinking aloud. Each sentence heard (Voice.deliver)
 * comes here first:
 *   - plain code (AddresseeRules, addressee.js) decides most at once: its
 *     name ("Muse, …", "hey Muse", "…, Muse?", "Muse ơi"; taken out of the
 *     order), another person's ("Paul, …", "Maman, …", "ok Google"), an
 *     answer to its question or to a step waiting for an OK, a stop word
 *     while it talks or works, a call in progress (Meeting.inCall), a reply
 *     right after it spoke or in a back-and-forth, fillers;
 *   - else ("smart") the small model judges, given the last things heard
 *     and said (masked for the provider), the focused window and the call:
 *     `nixbook-quick-ai` addressee mode, ~1 s; acted on only above
 *     `threshold`; a timeout or an error is "not for me".
 * What isn't for it is never sent: it shows dimmed in the mascot's balloon
 * ("not for me?") with a "Was that for me?" chip for a few seconds, which
 * sends it after all and is remembered as an example for the model.
 * Mod+T push-to-talk and typed messages never come here (always for it).
 */
Singleton {
    id: root
    function load() {}

    // "smart" | "name" | "all"; only by name with AI features not fully on
    // (no model then).
    readonly property string setting: Config.options.ai.voice?.addressee ?? "smart"
    readonly property string mode: (Config.options.policies?.ai ?? 1) !== 1 ? (root.setting === "all" ? "all" : "name")
        : (root.setting === "name" || root.setting === "all" ? root.setting : "smart")
    // Judged here: Full AI mode's always-open microphone ("all": every
    // sentence goes on, as before).
    readonly property bool active: FullAi.active && root.mode !== "all"
    // The model's verdict is taken from this confidence up.
    readonly property real threshold: 0.6

    // The last things heard and said, oldest first: {t, who "user"|"muse",
    // text, verdict "yes"|"no"|""}; 8 of the user's, Muse's in between.
    property var transcript: []
    // When Muse last said or wrote something, and when the user last spoke
    // to it (ms).
    property real spokeAt: 0
    property real addressedAt: 0
    // The sentence the model is judging ("" when none), those waiting.
    property string judgingText: ""
    property var queue: []
    // The last words taken for someone else's: {text, why, at}, shown a few
    // seconds with "Was that for me?".
    property var overheard: null
    property string lastWhy: ""

    function _push(who, text, verdict) {
        const now = Date.now();
        const t = root.transcript.filter(x => now - x.t < 180000).concat([{ t: now, who: who, text: String(text).slice(0, 300), verdict: verdict }]);
        // 8 of the user's, and what Muse said among them.
        let users = 0, from = 0;
        for (let i = t.length - 1; i >= 0; i--) {
            if (t[i].who === "user" && ++users > 8) { from = i + 1; break; }
        }
        root.transcript = t.slice(from).slice(-14);
    }
    function _context(text) {
        return {
            mode: root.mode, now: Date.now(),
            pending: !!QuickAi.pending,
            asking: !!FullAi.question && !FullAi.question.approval,
            speaking: Voice.speaking,
            busy: QuickAi.busy || Initiative.thinking,
            halt: (Initiative.thinking || QuickAi.busy || Voice.speaking) && Voice._halt(text) !== null,
            spokeAt: root.spokeAt, addressedAt: root.addressedAt,
            inCall: Meeting.inCall,
        };
    }

    // A sentence heard by the always-open microphone.
    function hear(text) {
        const t = String(text ?? "").trim();
        if (t.length === 0) return;
        const d = AddresseeRules.decide(t, root._context(t));
        root.lastWhy = d.why;
        if (d.verdict === "yes") return root._forMe(t, d.order, d.why);
        if (d.verdict === "no") return root._notForMe(t, d.why);
        // The model, one sentence at a time (the rules above never wait).
        root.queue = root.queue.concat([t]).slice(-3);
        root._next();
    }
    function _forMe(heard, order, why) {
        root.addressedAt = Date.now();
        root._push("user", heard, "yes");
        if (root.overheard) root.overheard = null;
        // The name alone ("Muse?", "hey Muse"): it answers, the next words
        // are for it (said a moment ago).
        if (!String(order).trim()) {
            FullAi.say(Translation.tr("Yes?"));
            return;
        }
        Voice.deliver(order, true);
    }
    function _notForMe(heard, why) {
        root._push("user", heard, "no");
        root.overheard = { text: heard, why: why, at: Date.now() };
        overheardOff.restart();
    }
    Timer {
        id: overheardOff
        interval: 6000
        onTriggered: root.overheard = null
    }
    // "Was that for me?": sent after all, and remembered (the model is
    // shown the last few next time).
    function claim() {
        const o = root.overheard;
        if (!o) return;
        root.overheard = null;
        overheardOff.stop();
        const ex = (Persistent.states.ai.addresseeExamples ?? []).filter(x => x !== o.text);
        Persistent.states.ai.addresseeExamples = ex.concat([o.text.slice(0, 200)]).slice(-6);
        root.transcript = root.transcript.map(x => x.who === "user" && x.text === o.text.slice(0, 300) ? Object.assign({}, x, { verdict: "yes" }) : x);
        root.addressedAt = Date.now();
        // Its name taken out, if it was there.
        const named = AddresseeRules.calledByName(o.text);
        Voice.deliver(named && named.order ? named.order : o.text, true);
    }

    // A judgement under way, tracked here: `running` only turns true once
    // the process has started, and setting it again while it runs would
    // start the next one with the old one's exit.
    property bool _inFlight: false
    function _next() {
        if (root._inFlight || root.queue.length === 0) return;
        root._inFlight = true;
        const t = root.queue[0];
        root.queue = root.queue.slice(1);
        root.judgingText = t;
        const now = Date.now();
        const focus = QuickAi.focusedApp();
        judge.heard = t;
        judge.handled = false;
        judge.started = now;
        judge.requestJson = JSON.stringify({
            mode: "addressee", heard: t, lang: ConfigAssistant.uiLang(),
            transcript: root.transcript.map(x => ({ ago: Math.round((now - x.t) / 1000), who: x.who, text: x.text, verdict: x.verdict })),
            app: focus.app, title: focus.title, call: Meeting.inCall, callApp: Meeting.callNow || Meeting.callApp,
            examples: Persistent.states.ai.addresseeExamples ?? [],
            museSpokeAgo: root.spokeAt > 0 ? Math.round((now - root.spokeAt) / 1000) : -1,
            model: "small" });
        judge.running = true;
        judgeTimeout.restart();
    }
    function _judged(heard, ev) {
        judge.handled = true;
        judgeTimeout.stop();
        root.judgingText = "";
        // Full AI mode left meanwhile: nothing.
        if (root.active) {
            const yes = !!ev && ev.addressed === true && Number(ev.confidence ?? 0) >= root.threshold;
            root.lastWhy = !ev ? "timeout" : ev.failed ? "error" : yes ? "model" : "model-no";
            if (yes) root._forMe(heard, String(ev.order ?? "").trim() || heard, "model");
            else root._notForMe(heard, root.lastWhy);
        }
    }
    // The next sentence once this process is over (its verdict can come
    // before it writes its record and exits).
    function _done() {
        root._inFlight = false;
        Qt.callLater(root._next);
    }
    Process {
        id: judge
        property string heard: ""
        property bool handled: false
        property real started: 0
        property string requestJson: "{}"
        command: ["bash", "-c", QuickAi.modelRun + 'dir="${XDG_RUNTIME_DIR:-/tmp}/nixbook-shell/quick-ai"; mkdir -p -m 700 "$dir"; '
            + 'f="$dir/addressee-$$.json"; trap \'rm -f "$f"\' EXIT; printf "%s" "$1" > "$f"; '
            + 'model nixbook-quick-ai ask "$f"', "_", judge.requestJson]
        stdout: SplitParser {
            onRead: (line) => {
                let ev;
                try { ev = JSON.parse(line); } catch (e) { return; }
                // Acted on as soon as it comes (the script still writes
                // its record after).
                if (ev.type === "addressee" && !judge.handled) root._judged(judge.heard, ev);
            }
        }
        onExited: {
            if (!judge.handled) root._judged(judge.heard, null);
            root._done();
        }
    }
    // Too slow: not for it (never an action from a guess).
    Timer {
        id: judgeTimeout
        interval: 4000
        onTriggered: {
            if (judge.running) {
                judge.running = false;
                return;
            }
            // Never started: given up all the same.
            if (!judge.handled) root._judged(judge.heard, null);
            root._done();
        }
    }

    // What Muse says (the mascot's balloon, read out) and when it last did.
    Connections {
        target: FullAi
        function onSaidChanged() {
            if (!FullAi.said) return;
            root.spokeAt = Date.now();
            root._push("muse", FullAi.said, "");
        }
        function onActiveChanged() {
            if (FullAi.active) return;
            root.queue = [];
            root.overheard = null;
            root.transcript = [];
            root.spokeAt = 0;
            root.addressedAt = 0;
            judge.handled = true;
            judgeTimeout.stop();
            if (judge.running) judge.running = false;
            else root._inFlight = false;
            root.judgingText = "";
        }
    }
    Connections {
        target: Voice
        function onSpeakingChanged() {
            if (!Voice.speaking && FullAi.active) root.spokeAt = Date.now();
        }
    }
    Connections {
        target: QuickAi
        function onBusyChanged() {
            if (!QuickAi.busy && FullAi.active) root.spokeAt = Date.now();
        }
    }
    // Barge-in while it talks (Voice's partial words): the name or a stop
    // word always; other words only in smart mode and out of a call.
    function mayInterrupt(partial) {
        if (root.mode === "all" || !FullAi.active) return true;
        const t = String(partial ?? "").trim();
        if (Voice.stopWords.test(t) || AddresseeRules.calledByName(t)) return true;
        return root.mode === "smart" && !Meeting.inCall && !AddresseeRules.otherPerson(t);
    }

    IpcHandler {
        target: "addressee"
        function status(): string {
            return JSON.stringify({ mode: root.mode, active: root.active, judging: root.judgingText, queued: root.queue.length,
                overheard: root.overheard, lastWhy: root.lastWhy, inCall: Meeting.inCall, transcript: root.transcript });
        }
        // What the plain-code rules say of a sentence now (no model, nothing
        // sent).
        function check(text: string): string {
            return JSON.stringify(AddresseeRules.decide(text, root._context(text)));
        }
    }
}
