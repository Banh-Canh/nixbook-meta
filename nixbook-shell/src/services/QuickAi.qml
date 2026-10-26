pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

/**
 * Quick AI (ai.quick): AI where the user already is, answering in a couple
 * of seconds. One card (modules/ii/quickAi/QuickAiCard.qml) at the top of
 * the focused screen, called up on:
 *   - a selection (Mod+S, `quickAi selection`): the primary selection (else
 *     the clipboard) and the window it came from; Explain / Summarize /
 *     Translate / Rewrite / Fix / Ask, the text typed back over the
 *     selection with Replace;
 *   - the screen (Mod+Shift+S, `quickAi screen`): a region drawn with the
 *     region selector (its "Ask AI" action), sent as an image;
 *   - the launcher ("!" or the "Ask AI" row): a question;
 *   - a notification: Summarize, or three replies to send in one click.
 * Each answer can be followed up, copied, or continued in the side panel.
 * No agent: `nixbook-quick-ai` (scripts/quick-ai.py) calls the provider's
 * Messages API itself with its small model (Meta: muse-spark), through
 * `nixbook-model-provider run` for the key; with Anthropic, `claude -p`
 * with Haiku. Text goes through desktop-mcp's privacy mask on the way.
 */
Singleton {
    id: root

    readonly property bool available: Config.ready && (Config.options.ai.quick?.enable ?? true)
        && Config.options.policies.ai === 1
    property bool open: false

    // What it is about: {kind: selection|clipboard|screen|launcher|
    // notification|empty, text, image, app, title, notificationId, inline}.
    property var source: ({})
    property string mode: "explain"
    // The conversation after the first answer: [{role, text}].
    property var turns: []
    property string answer: ""
    property var replies: []
    property bool busy: false
    property string error: ""
    property string provider: ""
    property string model: ""
    property int lastMs: 0
    property real startedAt: 0
    // Bumped on every new answer: the card restarts its typewriter.
    property int revision: 0
    // Doing things (mode "do"): the tool calls as they happen, [{id, tool,
    // summary, status: run|ok|error|denied, result}], what the model said
    // between them, the step waiting for the user's OK ({id, tool,
    // summary}), and desktop control found paused.
    property var steps: []
    property var notes: []
    property var pending: null
    property bool paused: false
    // Said at once by QuickIntent (no model): music, volume, apps…
    property bool instant: false

    readonly property var modeInfo: ({
        explain: { label: Translation.tr("Explain"), icon: "lightbulb" },
        summarize: { label: Translation.tr("Summarize"), icon: "summarize" },
        translate: { label: Translation.tr("Translate"), icon: "translate" },
        rewrite: { label: Translation.tr("Rewrite"), icon: "edit_note" },
        fix: { label: Translation.tr("Fix"), icon: "spellcheck" },
        ask: { label: Translation.tr("Ask"), icon: "chat" },
        reply: { label: Translation.tr("Suggest replies"), icon: "quickreply" },
        do: { label: Translation.tr("Do it"), icon: "bolt" },
        screen: { label: Translation.tr("What's this?"), icon: "center_focus_strong" },
    })
    // The modes offered for the source.
    readonly property var modes: {
        const k = root.source?.kind ?? "";
        if (k === "screen") return ["screen", "ask"];
        if (k === "notification") return ["summarize", "reply", "explain", "translate"];
        if (k === "launcher" || k === "empty" || k === "voice" || k === "scan") return [];
        return ["explain", "summarize", "translate", "rewrite", "fix", "ask"];
    }
    // The answer stands in for the selection: Replace types it over it.
    readonly property bool canReplace: (root.source?.kind === "selection")
        && ["rewrite", "fix", "translate"].includes(root.mode) && !root.busy && root.answer.length > 0
    readonly property string sourceLabel: {
        const s = root.source ?? {};
        const app = s.app ? ` · ${s.app}` : "";
        switch (s.kind) {
        case "selection": return Translation.tr("Selection") + app;
        case "clipboard": return Translation.tr("Clipboard") + app;
        case "screen": return Translation.tr("Screen");
        case "launcher": return Translation.tr("Launcher");
        case "voice": return Translation.tr("Voice");
        case "scan": return Translation.tr("Kiroshi scan");
        case "notification": return Translation.tr("Notification") + app;
        default: return Translation.tr("Ask anything");
        }
    }

    // The mode a text gets by itself (ai.quick.defaultMode "auto"): an
    // error or code explained, a long text summarized, else explained.
    function autoMode(text) {
        const set = Config.options.ai.quick?.defaultMode ?? "auto";
        if (set !== "auto" && root.modeInfo[set]) return set;
        const t = String(text ?? "");
        if (/(error|exception|traceback|failed|panic|warning|fatal|segfault)/i.test(t)) return "explain";
        if (t.length > 700) return "summarize";
        return "explain";
    }

    function focusedApp() {
        const top = ToplevelManager.activeToplevel;
        return { app: top?.appId ?? "", title: top?.title ?? "" };
    }

    // ── Entry points ──
    // The selection (else the clipboard): read, then the card.
    function askSelection() {
        if (!root.available) return root.refuse();
        if (root.open && root.source?.kind === "selection") { root.close(); return; }
        selectionReader.where = root.focusedApp();
        selectionReader.primary = true;
        selectionReader.running = false;
        selectionReader.running = true;
    }
    function askText(text, kind = "selection", where = null, mode = "") {
        if (!root.available) return root.refuse();
        const w = where ?? root.focusedApp();
        const t = String(text ?? "").trim();
        if (t.length === 0) {
            root.start({ kind: "empty", app: w.app, title: w.title }, "ask", "");
            return;
        }
        root.start({ kind: kind, text: t, app: w.app, title: w.title }, mode || root.autoMode(t), "");
    }
    // A question or an order with no text (the launcher, the empty card,
    // the voice): done at once when QuickIntent knows it, else the model
    // with the desktop tools ("do": it answers, or acts).
    function askQuestion(question, kind = "launcher") {
        if (!root.available) return root.refuse();
        const q = String(question ?? "").trim();
        root.start(Object.assign({ kind: kind }, root.focusedApp()), "do", q);
    }
    function command(text, kind = "voice") {
        root.askQuestion(text, kind);
    }
    // A region of the screen (the region selector's Ask AI action).
    function askImage(path, question = "") {
        if (!root.available) return root.refuse();
        root.start(Object.assign({ kind: "screen", image: path }, root.focusedApp()), "screen", question);
    }
    // The region selector in its Ask AI action (Mod+Shift+S).
    function askScreen() {
        if (!root.available) return root.refuse();
        GlobalStates.regionAskAiRequested();
    }
    // A notification: Summarize or Suggest replies (mode "reply").
    function askNotification(notif, mode = "summarize") {
        if (!root.available || !notif) return root.refuse();
        const text = [notif.summary, String(notif.body ?? "").replace(/<[^>]+>/g, "")].filter(s => s).join("\n");
        const inline = (Notifications.replyMethod(notif)?.kind ?? "") === "inline";
        root.start({ kind: "notification", text: text, app: notif.appName ?? "", title: notif.summary ?? "",
            notificationId: notif.notificationId, inline: inline }, mode, "");
    }

    function refuse() {
        Quickshell.execDetached(["notify-send", "-a", "Quick AI", "-t", "4000", Translation.tr("Quick AI is off"),
            Config.options.policies.ai !== 1 ? Translation.tr("AI features are off (Settings > Desktop agents)")
                : Translation.tr("Turn it on in Settings > Desktop agents > Quick AI")]);
    }

    // ── The conversation ──
    function start(source, mode, question) {
        root.source = source;
        root.mode = mode;
        root.turns = [];
        root.open = true;
        if (!question && ["empty", "launcher", "voice", "scan"].includes(source.kind)) {
            root.stop();
            root.clearAnswer();
            return;
        }
        if (mode === "do" && root.tryInstant(question)) return;
        root.request(question, "");
    }
    // The same source, another mode.
    function run(mode) {
        if (!root.modeInfo[mode] || root.source?.kind === undefined) return;
        root.mode = mode;
        root.turns = [];
        root.request("", "");
    }
    // A question after an answer (the first one, when nothing was asked yet).
    function followUp(question) {
        const q = String(question ?? "").trim();
        if (q.length === 0) return;
        closeLater.stop();
        if (root.answer.length === 0 && root.turns.length === 0 && root.steps.length === 0) {
            if (root.mode === "do" && root.tryInstant(q)) return;
            root.request(q, "");
            return;
        }
        // After an instant command: a new order, not a follow-up.
        if (root.instant) {
            root.start(Object.assign({}, root.source), "do", q);
            return;
        }
        const turns = root.turns.slice();
        if (root.answer.length > 0) turns.push({ role: "assistant", text: root.answer });
        root.turns = turns;
        root.request(root.firstQuestion, q);
    }
    function clearAnswer() {
        root.answer = "";
        root.replies = [];
        root.error = "";
        root.steps = [];
        root.notes = [];
        root.pending = null;
        root.paused = false;
        root.instant = false;
    }
    // A plain command QuickIntent does in code: no model, no wait.
    function tryInstant(text) {
        const did = QuickIntent.run(text);
        if (!did) return false;
        root.stop();
        root.clearAnswer();
        root.firstQuestion = text;
        root.instant = true;
        root.provider = "";
        root.model = "";
        root.lastMs = 0;
        root.answer = did;
        root.revision++;
        closeLater.restart();
        return true;
    }
    // An instant command's card goes by itself.
    Timer {
        id: closeLater
        interval: 2200
        onTriggered: if (root.instant && !root.busy) root.close()
    }
    function retry() {
        root.request(root.firstQuestion, root.lastFollowUp);
    }
    property string firstQuestion: ""
    property string lastFollowUp: ""

    function request(question, followUp) {
        root.stop();
        if (!followUp) root.firstQuestion = question;
        root.lastFollowUp = followUp;
        const s = root.source;
        const turns = root.turns.slice();
        if (followUp) turns.push({ role: "user", text: followUp });
        const req = {
            mode: root.mode, question: question, text: s.text ?? "", image: s.image ?? "",
            context: { app: s.app ?? "", title: s.title ?? "", source: s.kind },
            history: followUp ? root.turns : [], followUp: followUp,
            lang: ConfigAssistant.uiLang(), target: Config.options.ai.quick?.translateTo || "",
            model: Config.options.ai.quick?.model ?? "small", effort: Config.options.ai.quick?.effort ?? "low",
            claude: Ai.claudeCodePath, confirm: Config.options.ai.quick?.confirm ?? "destructive",
        };
        if (followUp) root.turns = turns;
        root.clearAnswer();
        root.busy = true;
        root.startedAt = Date.now();
        root.revision++;
        proc.serial++;
        proc.requestJson = JSON.stringify(req);
        proc.running = true;
    }
    function stop() {
        if (proc.running) {
            proc.serial++;
            proc.running = false;
        }
        root.busy = false;
    }
    function close() {
        root.stop();
        root.open = false;
    }

    // The step waiting for an OK: done or not.
    function approve(yes) {
        if (!root.pending || !proc.running) return;
        root.pending = null;
        proc.write(yes ? "yes\n" : "no\n");
    }
    // Desktop control was paused (Mod+Shift+Escape, the bar's robot): allowed
    // again, the order asked again.
    function allowControl() {
        Quickshell.execDetached(["nixbook-desktop-mcp", "resume"]);
        allowRetry.restart();
    }
    Timer {
        id: allowRetry
        interval: 400
        onTriggered: root.retry()
    }

    // ── What to do with the answer ──
    function copy(text = root.answer) {
        if (!text) return;
        Quickshell.execDetached(["wl-copy", "--", text]);
    }
    // Typed over the selection, once the card has given the keyboard back.
    function replace() {
        if (!root.canReplace) return;
        replaceTimer.text = root.answer;
        root.close();
        replaceTimer.restart();
    }
    Timer {
        id: replaceTimer
        property string text: ""
        interval: 220
        onTriggered: Quickshell.execDetached(["wtype", "--", text])
    }
    // A suggested reply: sent inline when the app takes it, else copied and
    // the app's own reply opened.
    function sendReply(text) {
        const s = root.source;
        if (s.kind !== "notification") { root.copy(text); return; }
        if (s.inline && Notifications.sendReply(s.notificationId, text)) {
            Quickshell.execDetached(["notify-send", "-a", "Quick AI", "-t", "2500", Translation.tr("Reply sent"), text]);
            root.close();
            return;
        }
        root.copy(text);
        const notif = Notifications.list.find(n => n.notificationId === s.notificationId);
        const how = notif ? Notifications.replyMethod(notif) : null;
        if (how?.identifier) Notifications.attemptInvokeAction(s.notificationId, how.identifier);
        Quickshell.execDetached(["notify-send", "-a", "Quick AI", "-t", "3000", Translation.tr("Reply copied"),
            Translation.tr("Paste it in the conversation")]);
        root.close();
    }
    // The conversation goes on in the side panel's chat (Claude Code there,
    // with the desktop tools).
    function continueInChat() {
        const s = root.source;
        const lines = [];
        if (s.text) lines.push("> " + s.text.split("\n").slice(0, 30).join("\n> "));
        if (s.app) lines.push(Translation.tr("(from %1)").arg(s.app));
        if (root.firstQuestion) lines.push(root.firstQuestion);
        else lines.push(root.modeInfo[root.mode]?.label ?? "");
        for (const t of root.turns) lines.push((t.role === "assistant" ? "AI: " : "") + t.text);
        if (root.answer) lines.push(Translation.tr("Quick answer so far:") + "\n" + root.answer);
        lines.push(Translation.tr("Let's go further."));
        Ai.newChat();
        if (s.image) Ai.attachFile(s.image);
        GlobalStates.sidebarLeftOpen = true;
        Ai.sendUserMessage(lines.join("\n\n"));
        root.close();
    }

    // ── Processes ──
    Process {
        id: selectionReader
        property var where: ({})
        property bool primary: true
        command: ["wl-paste", "--no-newline", "--type", "text"].concat(selectionReader.primary ? ["--primary"] : [])
        stdout: StdioCollector {
            id: selectionOut
        }
        onExited: (code) => {
            const text = code === 0 ? selectionOut.text : "";
            if (text.trim().length === 0 && selectionReader.primary) {
                // No selection: the clipboard.
                selectionReader.primary = false;
                selectionReader.running = true;
                return;
            }
            root.askText(text.slice(0, 24000), selectionReader.primary ? "selection" : "clipboard", selectionReader.where);
        }
    }

    Process {
        id: proc
        property int serial: 0
        property string requestJson: "{}"
        property int mine: 0
        stdinEnabled: true
        onRunningChanged: if (running) mine = serial
        command: ["bash", "-c", 'dir="${XDG_RUNTIME_DIR:-/tmp}/nixbook-shell/quick-ai"; mkdir -p -m 700 "$dir"; '
            + 'f="$dir/request-$$.json"; printf "%s" "$1" > "$f"; '
            + 'nixbook-model-provider run nixbook-quick-ai ask "$f"; rc=$?; rm -f "$f"; exit $rc', "_", proc.requestJson]
        stdout: SplitParser {
            onRead: (line) => {
                if (proc.mine !== proc.serial) return;
                let ev;
                try { ev = JSON.parse(line); } catch (e) {
                    // nixbook-model-provider's own failure (no key…).
                    if (line.trim().length > 0) root.error = line.trim();
                    return;
                }
                switch (ev.type) {
                case "start":
                    root.provider = ev.provider ?? "";
                    root.model = ev.model ?? "";
                    break;
                case "delta":
                    root.answer = root.answer + (ev.text ?? "");
                    break;
                case "answer":
                    root.answer = ev.text ?? "";
                    break;
                case "replies":
                    root.replies = ev.replies ?? [];
                    break;
                case "error":
                    root.error = ev.error ?? Translation.tr("No answer");
                    break;
                case "step": {
                    const steps = root.steps.slice();
                    const i = steps.findIndex(x => x.id === ev.id);
                    const step = { id: ev.id, tool: ev.tool, summary: ev.summary ?? "", status: ev.status, result: ev.result ?? "" };
                    if (i >= 0) steps[i] = step; else steps.push(step);
                    root.steps = steps;
                    break;
                }
                case "approve":
                    root.pending = { id: ev.id, tool: ev.tool, summary: ev.summary ?? "" };
                    break;
                case "note":
                    root.notes = root.notes.concat([ev.text ?? ""]);
                    break;
                case "paused":
                    root.paused = true;
                    break;
                case "done":
                    root.lastMs = ev.ms ?? (Date.now() - root.startedAt);
                    break;
                }
            }
        }
        stderr: SplitParser {
            onRead: (line) => {
                if (proc.mine === proc.serial && /nixbook-model-provider:/.test(line))
                    root.error = line.replace(/^nixbook-model-provider:\s*/, "");
            }
        }
        onExited: (code) => {
            if (proc.mine !== proc.serial) return;
            root.busy = false;
            root.pending = null;
            if (code !== 0 && root.error.length === 0 && root.answer.length === 0)
                root.error = Translation.tr("The model didn't answer (exit %1)").arg(code);
        }
    }

    IpcHandler {
        target: "quickAi"
        // The selection (else the clipboard), in the card.
        function selection(): void { root.askSelection(); }
        // A region of the screen, drawn first.
        function screen(): void { root.askScreen(); }
        // A question or an order, answered or done in the card.
        function ask(question: string): void { root.askQuestion(question); }
        // The step waiting for an OK.
        function approve(): void { root.approve(true); }
        function deny(): void { root.approve(false); }
        // An image file, asked about.
        function image(path: string): void { root.askImage(path); }
        function close(): void { root.close(); }
        // The card, empty, to ask anything (again: closes it).
        function toggle(): void {
            if (root.open) root.close();
            else root.askQuestion("", "empty");
        }
        function status(): string {
            return JSON.stringify({ open: root.open, busy: root.busy, mode: root.mode, source: root.source?.kind ?? "",
                provider: root.provider, model: root.model, ms: root.lastMs, error: root.error,
                answer: root.answer.slice(0, 400), replies: root.replies, steps: root.steps,
                pending: root.pending, instant: root.instant });
        }
    }
}
