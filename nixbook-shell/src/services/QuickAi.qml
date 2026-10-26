pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

/**
 * Quick AI (ai.quick): fast answers and actions, in Claude's speech bubble
 * (modules/ii/notificationPopup/AgentSpeech.qml, the Mod+C one): one box to
 * talk to the AI. What the user asks there (typed, said with Mod+T, from
 * the launcher's "!", a notification's Summarize / Suggest replies, the
 * screenshot app's Ask AI, a Kiroshi task) is answered by the model
 * provider's small model called directly (`nixbook-quick-ai`,
 * scripts/quick-ai.py, through `nixbook-model-provider run`; Meta: Muse
 * Spark, a few seconds), not by an agent that has to start: plain commands
 * are done at once by QuickIntent first (Initiative.reply), anything else
 * by the model with the desktop tools ("do"), each step in the bubble's
 * status line. Its answers are messages of the bubble's conversation (an
 * AiChatSession), so expanding the bubble carries it on in the side panel
 * with Claude Code. Under the answer, the bubble shows `chips`: Allow / No
 * for a destructive step, the suggested replies, the modes of a screen
 * region (What's this, Explain, Summarize, Translate, Copy text), Copy.
 * With Anthropic as the provider, `claude -p` (Haiku) answers instead.
 * Text goes through desktop-mcp's privacy mask on the way.
 */
Singleton {
    id: root
    // Referenced at startup (shell.qml): its IPC target exists from the start.
    function load() {}

    readonly property bool available: Config.ready && (Config.options.ai.quick?.enable ?? true)
        && Config.options.policies.ai === 1

    // The bubble's conversation it answers in, and what it is about: its
    // first turn {mode, question, text, image, context, notificationId,
    // inline, start (the index of its first message)}.
    property var chat: null
    property var convo: ({})
    // The answer being written (an AiMessageData of `chat`).
    property var msg: null
    property string answer: ""
    property var steps: []
    property var replies: []
    // The step waiting for the user's OK ({id, tool, summary}).
    property var pending: null
    property bool paused: false
    property bool busy: false
    property string error: ""
    property string provider: ""
    property string model: ""
    // After acting: the report ({summary, done, failed, needsYou, steps,
    // ok, ko}) the bubble shows as a brief under its message (reportMsg).
    property var report: null
    property var reportMsg: null

    readonly property var modeInfo: ({
        explain: Translation.tr("Explain"),
        summarize: Translation.tr("Summarize"),
        translate: Translation.tr("Translate"),
        rewrite: Translation.tr("Rewrite"),
        fix: Translation.tr("Fix"),
        ask: Translation.tr("Ask"),
        reply: Translation.tr("Suggest replies"),
        do: Translation.tr("Do it"),
        screen: Translation.tr("What's this?"),
        extract: Translation.tr("Copy text"),
    })

    function owns(chat) {
        return chat !== null && chat !== undefined && chat === root.chat;
    }

    // Under the answer in the bubble: {label, main, run}.
    readonly property var chips: {
        const out = [];
        if (root.pending) {
            const what = root.pending.tool.replace(/_/g, " ") + (root.pending.summary ? ` (${root.pending.summary})` : "");
            out.push({ label: Translation.tr("Allow: %1").arg(what), main: true, run: () => root.approve(true) });
            out.push({ label: Translation.tr("No"), main: false, run: () => root.approve(false) });
            return out;
        }
        if (root.busy) return out;
        if (root.paused) {
            out.push({ label: Translation.tr("Allow desktop control and retry"), main: true, run: () => root.allowControl() });
            return out;
        }
        for (const r of root.replies)
            out.push({ label: r, main: out.length === 0, run: () => root.sendReply(r) });
        if (out.length > 0) return out;
        if (root.convo.image) {
            for (const m of ["screen", "explain", "summarize", "translate", "extract"])
                if (m !== root.convo.mode || root.answer.length === 0)
                    out.push({ label: root.modeInfo[m], main: out.length === 0 && root.answer.length === 0, run: () => root.run(m) });
        }
        if (root.answer.length > 0)
            out.push({ label: Translation.tr("Copy"), main: false, run: () => root.copy() });
        return out;
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

    // What the shell already knows, sent along: the model answers "what's the
    // weather?", "what time is it?", "what's next today?" from it at once,
    // without a tool (it used to go looking on the screen).
    function facts() {
        const out = [];
        const now = new Date();
        out.push(`Now: ${now.toLocaleString(Qt.locale("en_US"), "dddd d MMMM yyyy, HH:mm")}`);
        try {
            const w = Weather.data;
            if (w && w.temp && w.city && w.city !== "City")
                out.push(`Weather in ${w.city}${w.country ? ", " + w.country : ""}: ${w.description || "?"}, ${w.temp}`
                    + `${w.tempFeelsLike ? " (feels like " + w.tempFeelsLike + ")" : ""}, humidity ${w.humidity}, wind ${w.wind}`
                    + `${w.sunrise && w.sunrise !== "0" ? ", sunrise " + w.sunrise + ", sunset " + w.sunset : ""}`);
        } catch (e) {}
        try {
            if (Battery.available)
                out.push(`Battery: ${Math.round(Battery.percentage * 100)}%${Battery.isCharging ? ", charging" : ""}`);
        } catch (e) {}
        try {
            const next = CalendarEvents.upcoming(3, now);
            if (next.length > 0)
                out.push("Next events: " + next.map(e => `${e.title} (${CalendarEvents.whenText(e, now)})`).join("; "));
        } catch (e) {}
        try {
            const p = MprisController.activePlayer;
            if (p && p.trackTitle)
                out.push(`Music: ${p.isPlaying ? "playing" : "paused"} "${p.trackTitle}"${p.trackArtist ? " by " + p.trackArtist : ""}`);
        } catch (e) {}
        return out.join("\n");
    }

    function focusedApp() {
        const top = ToplevelManager.activeToplevel;
        return { app: top?.appId ?? "", title: top?.title ?? "" };
    }

    function refuse() {
        Quickshell.execDetached(["notify-send", "-a", "Quick AI", "-t", "4000", Translation.tr("Quick AI is off"),
            Config.options.policies.ai !== 1 ? Translation.tr("AI features are off (Settings > Desktop agents)")
                : Translation.tr("Turn it on in Settings > Desktop agents > Talk to your desktop")]);
    }

    // ── The bubble ──
    // A conversation in the bubble to start: the one called up and still
    // empty, else a new one (the one before stays in the history).
    function newConversation() {
        const it = Initiative.speaking;
        if (it && it.kind === "ask" && !Initiative.conversing) Initiative.focusWanted();
        else Initiative.fresh();
        Initiative.prepare();
        return Initiative.chat;
    }
    // The bubble called up for a question or an order (Mod+T, the launcher,
    // Settings' Try it): asked at once when there is one.
    function askQuestion(question, kind = "launcher") {
        if (!root.available) return root.refuse();
        const q = String(question ?? "").trim();
        if (q.length === 0) {
            if (!Initiative.speaking) Initiative.summon();
            else Initiative.focusWanted();
            return;
        }
        root.newConversation();
        Initiative.reply(q);
    }
    // An order given by the shell itself (a Kiroshi task): `label` is what
    // the bubble shows as the user's message.
    function command(text, kind = "scan", label = "") {
        if (!root.available) return root.refuse();
        root.begin({ mode: "do", question: String(text ?? "").trim() }, label || text);
    }
    // A region of the screen (the screenshot app's Ask AI, Kiroshi's Tell me
    // more): the modes as chips, or the question asked at once.
    function askImage(path, question = "", label = "") {
        if (!root.available) return root.refuse();
        const q = String(question ?? "").trim();
        if (q.length > 0) {
            root.begin({ mode: "screen", image: path, question: q }, label || q);
            return;
        }
        const chat = root.newConversation();
        if (!chat) return;
        root.stop();
        root.chat = chat;
        root.clear();
        root.convo = { mode: "screen", image: path, question: "", context: root.focusedApp(), start: chat.messageIDs.length };
        chat.addMessage(Translation.tr("📷 A region of the screen: what do you want to know?"), "user");
    }
    // The screenshot app in its Ask AI action.
    function askScreen() {
        if (!root.available) return root.refuse();
        GlobalStates.regionAskAiRequested();
    }
    // A notification: summarized, or replies to send in one click.
    function askNotification(notif, mode = "summarize") {
        if (!root.available || !notif) return root.refuse();
        const text = [notif.summary, String(notif.body ?? "").replace(/<[^>]+>/g, "")].filter(s => s).join("\n");
        const inline = (Notifications.replyMethod(notif)?.kind ?? "") === "inline";
        const who = [notif.appName, notif.summary].filter(s => s).join(" — ");
        root.begin({ mode: mode, text: text, notificationId: notif.notificationId, inline: inline,
                     context: { app: notif.appName ?? "", title: notif.summary ?? "" } },
            mode === "reply" ? Translation.tr("Suggest replies: %1").arg(who) : Translation.tr("Summarize: %1").arg(who));
    }
    // A text (`quickAi selection`: the primary selection, else the clipboard).
    function askText(text, kind = "selection", where = null, mode = "") {
        if (!root.available) return root.refuse();
        const t = String(text ?? "").trim();
        if (t.length === 0) return root.askQuestion("", kind);
        const m = mode || root.autoMode(t);
        root.begin({ mode: m, text: t, context: where ?? root.focusedApp() },
            `${root.modeInfo[m] ?? m}: “${t.length > 120 ? t.slice(0, 117) + "…" : t}”`);
    }
    function askSelection() {
        if (!root.available) return root.refuse();
        selectionReader.where = root.focusedApp();
        selectionReader.primary = true;
        selectionReader.running = false;
        selectionReader.running = true;
    }

    // What the user says in the bubble (Initiative.reply, after QuickIntent):
    // answered here when it is a conversation this started or a new one of
    // theirs; false for Claude's own threads (Claude Code answers them).
    function handle(said, attach = "") {
        if (!root.available) return false;
        const chat = Initiative.chat;
        if (root.owns(chat)) {
            // A region still waiting for its question: this is it.
            if (!attach && root.convo.image && root.answer.length === 0 && !root.busy)
                root.convo = Object.assign({}, root.convo, { mode: "screen", question: said, start: chat.messageIDs.length });
            if (attach) {
                chat.attachFile("");
                root.convo = Object.assign({}, root.convo, { image: attach, mode: "screen", question: said,
                    start: chat.messageIDs.length });
            }
            chat.addMessage(said, "user");
            root.request();
            return true;
        }
        const item = Initiative.speaking;
        if (!Initiative.isAsk(item) || Initiative.conversing) return false;
        if (!chat) Initiative.prepare();
        const fresh = Initiative.chat;
        if (!fresh) return false;
        if (attach) fresh.attachFile("");
        root.stop();
        root.chat = fresh;
        root.clear();
        root.convo = { mode: attach ? "screen" : "do", image: attach, question: said, context: root.focusedApp(),
                       start: fresh.messageIDs.length };
        fresh.addMessage(said, "user");
        root.request();
        return true;
    }

    // A conversation started by the shell, with `label` as the user's message.
    function begin(convo, label) {
        const chat = root.newConversation();
        if (!chat) return;
        root.stop();
        root.chat = chat;
        root.clear();
        root.convo = Object.assign({ context: root.focusedApp() }, convo, { start: chat.messageIDs.length });
        chat.addMessage(String(label || convo.question || ""), "user");
        root.request();
    }
    // Something Full AI mode reacted to (services/FullAi.qml): said in the
    // bubble as its message, and what the user answers is about it (the
    // event goes along as the conversation's text).
    function adopt(eventText, said) {
        if (!root.available) return;
        if (!Initiative.speaking) Initiative.summon();
        Initiative.prepare();
        const chat = Initiative.chat;
        if (!chat) return;
        if (root.busy) root.stop();
        root.chat = chat;
        root.clear();
        root.convo = { mode: "do", question: "", text: String(eventText ?? ""), context: root.focusedApp(),
                       start: chat.messageIDs.length };
        if (said) chat.addMessage(said, "assistant");
    }
    // The bubble's last messages as text (Full AI mode's reactions read what
    // the user told it this session).
    function recentText(count = 10) {
        const chat = Initiative.chat;
        if (!chat) return "";
        return chat.messageIDs.slice(-count).map(id => chat.messageByID[id])
            .filter(m => m && (m.role === "user" || m.role === "assistant") && (m.content ?? "").length > 0)
            .map(m => `${m.role === "user" ? "user" : "you"}: ${String(m.content).slice(0, 400)}`).join("\n");
    }

    // The same subject, another mode (a chip).
    function run(mode) {
        if (!root.chat || !root.modeInfo[mode]) return;
        root.convo = Object.assign({}, root.convo, { mode: mode, question: "", start: root.chat.messageIDs.length });
        root.chat.addMessage(root.modeInfo[mode], "user");
        root.request();
    }

    function clear() {
        root.report = null;
        root.reportMsg = null;
        root.answer = "";
        root.steps = [];
        root.replies = [];
        root.pending = null;
        root.paused = false;
        root.error = "";
    }

    // Asks the model: the conversation's first turn (convo) and what was said
    // since its start in the chat (history), the last user message as the
    // follow-up when there is more than the first.
    function request() {
        root.stop();
        const chat = root.chat;
        if (!chat) return;
        const said = chat.messageIDs.slice(root.convo.start ?? 0).map(id => chat.messageByID[id])
            .filter(m => m && (m.role === "user" || m.role === "assistant"));
        const users = said.filter(m => m.role === "user");
        const followUp = users.length > 1 ? users[users.length - 1].content : "";
        const history = followUp ? said.slice(1, -1).map(m => ({ role: m.role, text: m.content })) : [];
        const c = root.convo;
        const req = {
            mode: c.mode ?? "do", question: c.question || (users[0]?.content ?? ""),
            text: c.text ?? "", image: c.image ?? "",
            context: { app: c.context?.app ?? "", title: c.context?.title ?? "", source: "bubble" },
            history: history, followUp: followUp,
            lang: ConfigAssistant.uiLang(), target: Config.options.ai.quick?.translateTo || "",
            model: Config.options.ai.quick?.model ?? "small", effort: Config.options.ai.quick?.effort ?? "low",
            claude: Ai.claudeCodePath, confirm: Config.options.ai.quick?.confirm ?? "destructive",
            facts: root.facts(),
        };
        // Modes about a text or an image ask nothing themselves.
        if (!c.question && c.mode !== "do" && !followUp) req.question = "";
        // The answer's message, filled as it comes ("Thinking…" meanwhile).
        chat.addMessage("…", "assistant");
        const m = chat.messageByID[chat.messageIDs[chat.messageIDs.length - 1]];
        m.content = "";
        m.rawContent = "<think>\n";
        m.thinking = true;
        m.done = false;
        root.msg = m;
        root.clear();
        root.busy = true;
        proc.serial++;
        proc.requestJson = JSON.stringify(req);
        proc.running = true;
    }
    // The message as it stands: each step a closed think block (the bubble
    // says "Used <tool>…"), the one running open, then the text.
    function render() {
        const m = root.msg;
        if (!m) return;
        let raw = "";
        for (const s of root.steps) {
            raw += `<think>\n**${s.tool.replace(/_/g, " ")}**${s.summary ? "\n" + s.summary : ""}`;
            if (s.status !== "run")
                raw += `\n${s.status === "ok" ? "✓" : s.status === "denied" ? "✗ refused" : "✗ " + (s.result ?? "")}\n</think>\n`;
        }
        const text = root.answer.length > 0 ? root.answer : root.error.length > 0 ? "⚠ " + root.error : "";
        if (root.busy && text.length === 0 && (root.steps.length === 0 || root.steps[root.steps.length - 1].status !== "run"))
            raw += "<think>\n";
        m.rawContent = raw + text;
        m.content = text;
    }
    function finish() {
        root.busy = false;
        root.pending = null;
        const m = root.msg;
        if (!m) return;
        if (root.answer.length === 0 && root.error.length === 0 && root.replies.length > 0)
            root.answer = Translation.tr("Pick a reply below.");
        root.render();
        if (m.content.length === 0) {
            m.content = Translation.tr("(no answer)");
            m.rawContent = m.rawContent + m.content;
        }
        m.thinking = false;
        m.done = true;
        m.model = root.model;
        // It acted: the user hears of it, the bubble put away meanwhile
        // coming back (the bar's bubble lit when they are busy).
        if (root.report && root.chat) Initiative.chatAnswered(root.chat);
    }
    function stop() {
        if (proc.running) {
            proc.serial++;
            proc.running = false;
            if (root.msg && !root.msg.done) {
                if (root.answer.length === 0) root.answer = Translation.tr("(stopped)");
                root.finish();
            }
        }
        root.busy = false;
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
        onTriggered: {
            if (!root.chat) return;
            // The refused answer goes: asked again.
            const ids = root.chat.messageIDs;
            if (ids.length > 0 && root.chat.messageByID[ids[ids.length - 1]]?.role === "assistant")
                root.chat.removeMessage(ids.length - 1);
            root.request();
        }
    }
    function copy(text = root.answer) {
        if (!text) return;
        Quickshell.execDetached(["wl-copy", "--", text]);
    }
    // A suggested reply: sent inline when the app takes it, else copied and
    // the app's own reply opened.
    function sendReply(text) {
        const c = root.convo;
        if (!c.notificationId) { root.copy(text); return; }
        root.replies = [];
        if (c.inline && Notifications.sendReply(c.notificationId, text)) {
            root.chat?.addMessage(Translation.tr("Sent: %1").arg(text), "user");
            return;
        }
        root.copy(text);
        const notif = Notifications.list.find(n => n.notificationId === c.notificationId);
        const how = notif ? Notifications.replyMethod(notif) : null;
        if (how?.identifier) Notifications.attemptInvokeAction(c.notificationId, how.identifier);
        root.chat?.addMessage(Translation.tr("Copied, to paste in the conversation: %1").arg(text), "user");
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
                    root.render();
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
                case "paused":
                    root.paused = true;
                    break;
                case "report":
                    root.report = ev;
                    root.reportMsg = root.msg;
                    break;
                }
                root.render();
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
            if (code !== 0 && root.error.length === 0 && root.answer.length === 0)
                root.error = Translation.tr("The model didn't answer (exit %1)").arg(code);
            root.finish();
        }
    }

    IpcHandler {
        target: "quickAi"
        // The selection (else the clipboard), in the bubble.
        function selection(): void { root.askSelection(); }
        // A region of the screen, drawn first.
        function screen(): void { root.askScreen(); }
        // A question or an order, answered or done in the bubble.
        function ask(question: string): void { root.askQuestion(question); }
        // An image file, asked about.
        function image(path: string): void { root.askImage(path); }
        // The step waiting for an OK.
        function approve(): void { root.approve(true); }
        function deny(): void { root.approve(false); }
        function stop(): void { root.stop(); }
        function status(): string {
            return JSON.stringify({ busy: root.busy, mode: root.convo.mode ?? "", provider: root.provider, model: root.model,
                error: root.error, answer: root.answer.slice(0, 400), replies: root.replies, steps: root.steps,
                pending: root.pending, paused: root.paused, inBubble: root.chat !== null && root.chat === Initiative.chat });
        }
    }
}
