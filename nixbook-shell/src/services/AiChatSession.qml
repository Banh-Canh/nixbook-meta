pragma ComponentBehavior: Bound

import qs.modules.common.functions as CF
import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.services.ai

/**
 * One conversation of the side panel's chat, in a tab of its own (Ai.chats):
 * its messages, its Muse agent (nixbook-meta-agent, kept running between
 * messages, resuming its session) and its own agent desktop when agents work on theirs, so tabs
 * work in parallel without fighting over one pointer and keyboard. Slot 1
 * uses the first agent desktop (nixbook-agent-desktop), slot N the
 * nixbook-agent-desktop@N one (NIXBOOK_AGENT_DESKTOP, given to the desktop
 * MCP server). The models, settings and history are Ai.qml's.
 */
Scope {
    id: chat

    required property int slot
    readonly property string desktopInstance: chat.slot > 1 ? String(chat.slot) : ""
    readonly property bool isCurrent: Ai.current === chat

    property var messageIDs: []
    property var messageByID: ({})
    property QtObject tokenCount: QtObject {
        property int input: -1
        property int output: -1
        property int total: -1
    }
    property string chatId: "" // its conversation in the history ("" until saved)
    property string agentSessionId: ""
    property string pendingFilePath: ""
    // Where it is talked to: "chat" (the side panel) or "bubble" (Muse's
    // speech bubble, services/QuickAi.qml). The agent's command line
    // follows it (Ai.agentScript: the bubble's asks before risky steps and
    // reports, on the quick model), so the same session goes on in the
    // panel when the bubble is expanded: the agent started again with
    // --resume, nothing replayed.
    property string surface: "chat"
    // What goes with the next message only, on its stream-json line
    // ("nixbook"): {noActivity: the user took what they were doing out of
    // it (the bubble's ×, the panel's history button), app, title} for the
    // context broker (meta-agent --context-for).
    property var nextNixbook: ({})
    // The panel's history button: this message without what the user was
    // just doing (RecentContext). Back on after each message.
    property bool noActivity: false
    // A risky step waiting for the user's OK (meta-agent --confirm):
    // {id, tool, input, summary}; approve() answers it.
    property var approval: null
    // The last turn's end, for the bubble (QuickAi): its report and the
    // message it belongs to, its answer as text, its error.
    property var lastReport: null
    property var lastReportMsg: null
    property string lastAnswer: ""
    property string lastError: ""
    // Answered while not looked at (another tab, or the panel closed).
    property bool unread: false
    readonly property bool responding: requester.turnActive || chat.preparing > 0
    // A message's personal context and privacy mask being made (DesktopHelper).
    property int preparing: 0

    // The tab for what Muse says on its own (services/Initiative.qml): a
    // thread for each, one at a time (Ai.agentThread).
    property bool fromAgent: false
    // Made for a conversation of the bubble (Ai.askThread): closed again
    // when left empty (Ai.dropIfEmpty).
    property bool fromBubble: false
    readonly property string title: {
        if (chat.fromAgent) return Translation.tr("From Muse");
        const saved = Ai.history.find(c => c.id === chat.chatId)?.title;
        if (saved) return saved;
        const first = chat.messageIDs.map(id => chat.messageByID[id]).find(m => m?.role === "user");
        return first ? (Ai.titleFor(first.rawContent) || Translation.tr("New chat")) : Translation.tr("New chat");
    }

    readonly property bool seen: chat.isCurrent && GlobalStates.sidebarLeftOpen
    // Its last message, or the last time it was looked at: when a "From
    // Muse" tab left alone expires (Ai.expireAgentThreads).
    property real lastActivity: Date.now()
    onSeenChanged: {
        chat.lastActivity = Date.now();
        if (seen) chat.unread = false;
    }

    property MetaAgentApiStrategy strategy: MetaAgentApiStrategy {
        unmask: text => Ai.unmaskPrivate(text)
    }

    // Files of its own: the command line the agent runs with, and the task
    // for the desktop MCP server's memory (NIXBOOK_DESKTOP_MCP_QUERY_FILE):
    // written before each message, read by the running server on its next call.
    readonly property string requestScriptFilePath: `${Directories.aiTemp}/request-${chat.slot}.sh`
    readonly property string desktopTaskFilePath: `${Directories.aiTemp}/desktop-task-${chat.slot}.txt`
    // Written, never read: no "file does not exist" before the first write.
    FileView {
        id: desktopTaskFile
        blockWrites: true
        printErrors: false
    }
    FileView {
        id: requesterScriptFile
        blockWrites: true
        printErrors: false
    }

    function addMessage(message, role, unsent = false, learnHint = "") {
        if (message.length === 0) return;
        const aiMessage = Ai.aiMessageComponent.createObject(chat, {
            "role": role,
            "content": message,
            "rawContent": message,
            "thinking": false,
            "done": true,
            "unsent": unsent,
            "initiative": unsent,
            "learnHint": learnHint,
        });
        const id = Ai.idForMessage(aiMessage);
        // The message first: what reads the list as it changes finds it.
        chat.messageByID[id] = aiMessage;
        chat.messageIDs = [...chat.messageIDs, id];
        chat.lastActivity = Date.now();
    }

    function removeMessage(index) {
        if (index < 0 || index >= chat.messageIDs.length) return;
        const id = chat.messageIDs[index];
        chat.messageIDs.splice(index, 1);
        chat.messageIDs = [...chat.messageIDs];
        delete chat.messageByID[id];
    }

    function clearMessages() {
        chat.runMemoryPass(); // the chat being left
        chat.memoryReadUpTo = 0;
        chat.agentSessionId = "";
        chat.chatId = "";
        chat.messageIDs = [];
        chat.messageByID = ({});
        chat.tokenCount.input = -1;
        chat.tokenCount.output = -1;
        chat.tokenCount.total = -1;
    }

    function chatToJson() {
        return chat.messageIDs.map(id => {
            const message = chat.messageByID[id];
            return ({
                "role": message.role,
                "rawContent": message.rawContent,
                "fileMimeType": message.fileMimeType,
                "fileUri": message.fileUri,
                "localFilePath": message.localFilePath,
                "model": message.model,
                "thinking": false,
                "done": true,
                "annotations": message.annotations,
                "annotationSources": message.annotationSources,
                "functionName": message.functionName,
                "functionCall": message.functionCall,
                "functionResponse": message.functionResponse,
                "visibleToUser": message.visibleToUser,
                "initiative": message.initiative,
                "learnHint": message.learnHint,
                "offSession": message.offSession,
                "agentText": message.agentText,
                "clarify": message.clarify,
                "verify": message.verify,
                "feedback": message.feedback,
                "correction": message.correction,
                "requestApp": message.requestApp,
            });
        });
    }

    // Replaces the messages with saved ones (the history, /load).
    function setMessages(saved) {
        chat.clearMessages();
        const ids = [];
        const byID = {};
        for (const message of saved) {
            const messageId = Ai.idForMessage();
            ids.push(messageId);
            byID[messageId] = Ai.aiMessageComponent.createObject(chat, Object.assign({}, message, {
                "content": message.rawContent ?? "",
                "thinking": false,
                "done": true,
            }));
        }
        chat.messageByID = byID;
        chat.messageIDs = ids;
        // A saved chat: the pass read it when it was left.
        chat.memoryReadUpTo = ids.length;
    }

    // A conversation of the history, opened here: the agent's session too
    // when the agent still has it (it deletes them after a week), else the
    // next message sends the conversation so far as context. (A session saved
    // before Muse, claudeSessionId, was Claude Code's: not resumed.)
    function openSaved(id, saved) {
        // The answer being written stays with the conversation it is for.
        if (requester.turnActive) {
            chat.stopResponse();
            Ai.saveHistory(chat);
        }
        chat.setMessages(saved.messages ?? []);
        chat.chatId = id;
        chat.lastActivity = Date.now();
        const session = saved.agentSessionId ?? "";
        if (/^[A-Za-z0-9_-]{8,100}$/.test(session)) {
            agentSessionCheck.chat = id;
            agentSessionCheck.session = session;
            agentSessionCheck.running = true;
        }
    }
    Process {
        id: agentSessionCheck
        property string chat
        property string session
        command: ["bash", "-c", `test -f "\${XDG_STATE_HOME:-$HOME/.local/state}/nixbook-shell/agent-sessions/$1.json"`,
            "agent-session", session]
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0 && chat.chatId === agentSessionCheck.chat && chat.agentSessionId.length === 0)
                chat.agentSessionId = agentSessionCheck.session;
        }
    }

    function attachFile(filePath: string) {
        chat.pendingFilePath = CF.FileUtils.trimFileProtocol(filePath);
    }

    function sendUserMessage(message) {
        // An agent typing into this chat would act with this Muse's tools.
        if (DesktopControl.refuseIfAgentInput(Translation.tr("a message to Muse in the side panel"))) return;
        if (chat.fromAgent) Initiative.engaged();
        if (message.length === 0) return;
        chat.addMessage(message, "user");
        requester.makeRequest();
    }
    // A message of the bubble's (QuickAi.agentTurn): on the bubble's command
    // line, with what the broker needs to know of it (`nixbook`). `label`:
    // what the bubble shows as the user's message when it differs from what
    // the agent is told (a Kiroshi task, Full AI's own order).
    function sendFromBubble(message, nixbook, label) {
        if (message.length === 0) return;
        chat.surface = "bubble";
        chat.nextNixbook = nixbook ?? {};
        if (chat.fromAgent) Initiative.engaged();
        const shown = label && label !== message ? label : message;
        chat.addMessage(shown, "user");
        // The agent gets the order itself, the bubble shows the label.
        if (shown !== message) {
            const ids = chat.messageIDs;
            chat.messageByID[ids[ids.length - 1]].agentText = message;
        }
        requester.makeRequest();
    }
    // The step waiting for an OK: done (allow) or not; a line on the
    // agent's stdin, which goes on with the turn.
    function approve(allow) {
        const a = chat.approval;
        if (!a) return;
        chat.approval = null;
        if (requester.running && requester.turnActive)
            requester.write(JSON.stringify({ type: "approval", id: a.id, allow: allow === true }) + "\n");
    }

    function regenerate(messageIndex) {
        if (messageIndex < 0 || messageIndex >= chat.messageIDs.length) return;
        const message = chat.messageByID[chat.messageIDs[messageIndex]];
        if (message.role !== "assistant") return;
        // Remove all messages after this one
        for (let i = chat.messageIDs.length - 1; i >= messageIndex; i--) {
            chat.removeMessage(i);
        }
        // The agent's session still holds the removed answer: start a new
        // one, with the chat so far as context.
        chat.agentSessionId = "";
        requester.makeRequest();
    }

    // Stops the answer being written (and, for Muse, what it is doing): the
    // agent is stopped (the next message resumes its session, which holds
    // the turns it finished).
    function stopResponse() {
        if (!requester.turnActive) return;
        requester.restartPending = false;
        requester.pendingLine = "";
        requester.interrupting = true;
        requester.signal(15);
        stopFallback.restart();
    }

    // The tab closed: its agent stopped, its agent desktop (not the
    // first, which other tools use too) closed, what it said remembered.
    function close() {
        chat.runMemoryPass();
        requester.pendingLine = "";
        requester.restartPending = false;
        requester.launchGen++; // a start being prepared: dropped
        requester.masking = false;
        if (requester.running) requester.signal(15);
        if (chat.desktopInstance.length > 0)
            Quickshell.execDetached(["systemctl", "--user", "stop", `nixbook-agent-desktop@${chat.desktopInstance}.service`]);
    }

    // The panel opened on this tab, on Muse: the agent started ahead, so
    // the first message doesn't wait for it.
    function prewarm() {
        if (!Ai.agentReady || requester.running || requester.turnActive || (Config.options.policies.ai ?? 1) !== 1) return;
        // Only a new chat or the session of this one, with no file attached.
        requester.pendingLine = "";
        requester.launch("", chat.agentSessionId);
    }

    // The privacy mask (`nixbook-desktop-mcp privacy mask`): the message, with
    // its context, reaches Muse with placeholders for the private details.
    // Never sent as it is: if masking fails, the message isn't sent.
    function maskFailed() {
        const message = requester.message;
        if (!message) return;
        message.content += Translation.tr("**Not sent**: the private details couldn't be hidden (`nixbook-desktop-mcp privacy mask` failed). Turn off Settings > Desktop agents > Private details to send it as it is.");
        message.done = true;
        message.thinking = false;
    }

    // The memory pass (`nixbook-desktop-mcp personal learn`): Muse is told
    // to save what matters about the user, but mid-task it often doesn't.
    // So once a chat with Muse goes quiet (ai.agent.autoMemory), or
    // is left (cleared, another loaded, its tab closed), the turns the pass
    // hasn't read go to a small model that saves what is worth keeping.
    // Detached: it outlives the chat, and costs nothing while the chat goes on.
    property int memoryReadUpTo: 0 // the messages the pass has read
    FileView {
        id: memoryPassFile
        blockWrites: true
    }
    Timer {
        id: memoryPassTimer
        interval: 2 * 60 * 1000
        onTriggered: requester.turnActive ? restart() : chat.runMemoryPass()
    }
    // Quick AI answered in this chat (the speech bubble's): the pass once
    // it goes quiet, as after Muse.
    function queueMemoryPass() {
        memoryPassTimer.restart();
    }
    function runMemoryPass() {
        memoryPassTimer.stop();
        const messages = chat.messageIDs.map(id => chat.messageByID[id]);
        const from = Math.min(chat.memoryReadUpTo, messages.length);
        chat.memoryReadUpTo = messages.length;
        if (!(Config.options?.ai?.agent?.autoMemory ?? true) || !Ai.agentReady) return;
        const isTurn = m => m && (m.role === "user" || m.role === "assistant") && !m.functionName && (m.rawContent ?? "").length > 0;
        const fresh = messages.slice(from).filter(isTurn);
        // Only what the user said to an AI (Muse, Quick AI's model; not the
        // config assistant, which answers from the configuration).
        if (!fresh.some(m => m.role === "user") || !fresh.some(m => m.role === "assistant" && (m.model ?? "").length > 0
            && m.model !== Ai.configAssistantId)) return;
        const line = m => m.role === "user" ? `User: ${m.rawContent}`
            : `Assistant: ${m.rawContent.length > 1200 ? m.rawContent.slice(0, 1200) + "…" : m.rawContent}`;
        const earlier = messages.slice(0, from).filter(isTurn).slice(-2);
        const transcript = (earlier.length > 0 ? `(Earlier, read already:)\n${earlier.map(line).join("\n\n")}\n\n(New:)\n` : "")
            + fresh.map(line).join("\n\n");
        const path = `${Directories.aiTemp}/memory-pass-${Date.now()}-${chat.slot}.txt`;
        memoryPassFile.path = Qt.resolvedUrl(path);
        memoryPassFile.setText(transcript);
        Quickshell.execDetached([Ai.desktopMcpCommand, "personal", "learn",
            "--model", Config.options.ai.agent.memoryModel || "small", "--delete", path]);
    }

    // The agent (nixbook-meta-agent), kept running between messages: a message is one line on
    // its stdin, the answer ends with a "result" event. Started again
    // (resuming the session) when the command line it needs changes (the
    // settings, an attached file) or for another chat; started ahead when
    // the panel opens; closed after a while unused.
    Process {
        id: requester
        property list<string> baseCommand: ["bash"]
        stdinEnabled: true
        property AiMessageData message
        property AiMessageData activeMessage
        property bool restartPending: false
        // The command line it runs, without --resume, and the session it
        // goes on with ("" for a new one, until its first answer names it);
        // ready once started (stdin open).
        property string script: ""
        property string session: ""
        property bool ready: false
        // The line to send once it has started; the message being answered.
        property string pendingLine: ""
        property bool turnActive: false
        property bool interrupting: false
        // The message's `nixbook` field (makeRequest).
        property var nixbook: ({})

        function markDone() {
            const stopped = requester.interrupting;
            const message = requester.activeMessage;
            const finishing = !!message && !message.done;
            // The turn's end, for the bubble (QuickAi), known before the
            // turn shows as over (Full AI reads it as it ends).
            if (finishing) {
                chat.lastReport = chat.strategy.report;
                chat.lastReportMsg = chat.strategy.report ? message : null;
                chat.lastError = chat.strategy.error;
                chat.lastAnswer = String(message.content ?? "").replace(/<think>[\s\S]*?(<\/think>|$)/g, "").trim();
            }
            requester.turnActive = false;
            chat.approval = null;
            requester.interrupting = false;
            stopFallback.stop();
            idleClose.restart();
            chat.lastActivity = Date.now();
            if (!finishing) return;
            message.done = true;
            message.thinking = false;
            // Not when another conversation was opened here meanwhile.
            if (Object.values(chat.messageByID).includes(requester.activeMessage)) {
                if (chat.isCurrent) Ai.saveChat("lastSession");
                Ai.saveHistory(chat);
            }
            Ai.responseFinished();
            memoryPassTimer.restart();
            if (!chat.seen) chat.unread = true;
            // Stopped by the user: they're there already.
            if (!stopped) chat.notifyDone(requester.activeMessage);
        }

        function makeRequest() {
            // The config assistant: answered here from the configuration, no
            // request. Not in the bubble (it always talks to Muse's agent),
            // nor in a conversation Muse's agent already has a session of (one
            // of the bubble's, expanded here: it goes on in that session).
            const viaAgent = chat.surface === "bubble" || !Ai.usingConfigAssistant || chat.agentSessionId.length > 0;
            if (!viaAgent) {
                const turns = chat.messageIDs.map(id => chat.messageByID[id]).filter(m => m?.role === "user");
                const question = turns[turns.length - 1]?.rawContent ?? "";
                const previous = turns[turns.length - 2]?.rawContent ?? "";
                let answer = Translation.tr("The configuration facts aren't loaded (~/.config/nixbook-shell/system-facts.json, generated by the Home Manager module).");
                try {
                    if (ConfigAssistant.ready) answer = ConfigAssistant.answer(question, previous);
                } catch (e) {
                    console.warn("[Ai] ConfigAssistant.answer failed:", e);
                }
                const reply = Ai.aiMessageComponent.createObject(chat, {
                    "role": "assistant", "model": Ai.currentModelId,
                    "content": answer, "rawContent": answer, "thinking": false, "done": true,
                });
                const replyId = Ai.idForMessage(reply);
                chat.messageByID[replyId] = reply;
                chat.messageIDs = [...chat.messageIDs, replyId];
                if (chat.isCurrent) Ai.saveChat("lastSession");
                Ai.saveHistory(chat);
                Ai.responseFinished();
                return;
            }

            const messageArray = chat.messageIDs.map(id => chat.messageByID[id]);
            const filteredMessageArray = messageArray.filter(message => message.role !== Ai.interfaceRole);
            chat.strategy.reset();

            /* Create local message object */
            requester.message = Ai.aiMessageComponent.createObject(chat, {
                "role": "assistant",
                "model": Ai.usingConfigAssistant ? Ai.agentModelId : Ai.currentModelId,
                "content": "",
                "rawContent": "",
                "thinking": true,
                "done": false,
            });
            const id = Ai.idForMessage(requester.message);
            chat.messageByID[id] = requester.message;
            chat.messageIDs = [...chat.messageIDs, id];

            let attachedFile = chat.pendingFilePath;
            if (attachedFile && attachedFile.length > 0) {
                requester.message.localFilePath = attachedFile;
                chat.pendingFilePath = "";
            }
            const attached = attachedFile && attachedFile.length > 0 && attachedFile.startsWith("/") ? attachedFile : "";

            // AI features off or local only (policies.ai, switched while a
            // Muse chat was open), or no key saved yet: said, nothing sent.
            if ((Config.options.policies.ai ?? 1) !== 1 || !ModelProvider.ready) {
                requester.message.content = (Config.options.policies.ai ?? 1) !== 1
                    ? Translation.tr("**Not sent**: online AI features are off (Settings > Desktop agents > AI features).")
                    : Translation.tr("**Not sent**: Muse needs your %1 API key. Save it in Settings > Desktop agents > Model provider.").arg(ModelProvider.label);
                requester.message.rawContent = requester.message.content;
                requester.message.done = true;
                requester.message.thinking = false;
                return;
            }

            /* Send the request */
            // What the user was doing, what Muse remembers of them, the
            // facts the shell knows (time, weather, battery, events,
            // music): the agent asks the context broker itself before each
            // turn (meta-agent --context-for, `nixbook-desktop-mcp context
            // build`), on its own budget; the shell only says whether to
            // leave the activity out (`nixbook`).
            const prompt = Ai.agentPrompt(filteredMessageArray, attached, chat.agentSessionId);
            for (const m of filteredMessageArray) {
                m.unsent = false;
                m.learnHint = "";
                m.offSession = false;
            }
            const turns = filteredMessageArray.filter(m => m.role === "user");
            desktopTaskFile.path = Qt.resolvedUrl(chat.desktopTaskFilePath);
            desktopTaskFile.setText((turns[turns.length - 1]?.agentText || turns[turns.length - 1]?.rawContent || "").slice(0, 500));
            const top = ToplevelManager.activeToplevel;
            requester.nixbook = Object.assign({ app: top?.appId ?? "", title: top?.title ?? "" },
                chat.noActivity ? { noActivity: true } : {}, chat.nextNixbook);
            chat.nextNixbook = {};
            chat.noActivity = false;
            requester.message.requestApp = requester.nixbook.app ?? "";
            requester.sendPrompt(prompt, attached);
        }

        function sendPrompt(prompt, attached) {
            const content = Ai.messageContext() + prompt;
            if (Config.options.ai.privacy.mask) {
                chat.preparing++;
                DesktopHelper.run(["privacy", "mask", "--typed"], content, (code, masked) => {
                    chat.preparing--;
                    if (code === 0 && masked.length > 0) requester.sendContent(masked, attached);
                    else chat.maskFailed();
                });
                return;
            }
            requester.sendContent(content, attached);
        }

        function sendContent(content, attached) {
            requester.pendingLine = JSON.stringify({ type: "user", message: { role: "user", content: content },
                nixbook: requester.nixbook }) + "\n";
            requester.start(attached);
        }

        // Sends the pending message: to the agent running, when it fits,
        // else to one started for it.
        function start(attached) {
            if (requester.running && !requester.restartPending && !requester.turnActive
                    && requester.script === Ai.agentScript(chat, attached, "")
                    && requester.session === chat.agentSessionId) {
                if (requester.ready) requester.send(); // else once started
                return;
            }
            if (requester.activeMessage && requester.activeMessage !== requester.message && !requester.activeMessage.done) {
                requester.activeMessage.done = true;
                requester.activeMessage.thinking = false;
            }
            requester.launch(attached, chat.agentSessionId);
        }

        // Starts the agent (after stopping the one running): resume, the
        // session to go on with. With the privacy mask, its system prompt is
        // masked by the shell's helper first (DesktopHelper: a millisecond,
        // not a process in the script); the one running is stopped meanwhile.
        property int launchGen: 0
        property bool masking: false
        function launch(attached, resume) {
            requester.script = Ai.agentScript(chat, attached, "");
            requester.session = resume;
            const gen = ++requester.launchGen;
            if (requester.running) {
                requester.restartPending = true;
                requester.signal(15);
            }
            const write = masked => {
                if (gen !== requester.launchGen) return;
                requester.masking = false;
                requesterScriptFile.path = Qt.resolvedUrl(CF.FileUtils.trimFileProtocol(chat.requestScriptFilePath));
                requesterScriptFile.setText("#!/usr/bin/env bash\n" + Ai.agentScript(chat, attached, resume, masked));
                // Else started once the one before has exited (onExited).
                if (!requester.running) requester.spawn();
            };
            if (!Config.options.ai.privacy.mask) {
                write("");
                return;
            }
            requester.masking = true;
            // Failed: the script masks it itself (and stops if that fails too).
            DesktopHelper.run(["privacy", "mask"], Ai.agentBuild(chat, attached).system,
                (code, out) => write(code === 0 ? String(out ?? "").replace(/\n+$/, "") : ""));
        }

        function spawn() {
            requester.turnActive = false;
            requester.ready = false;
            requester.command = baseCommand.concat([CF.FileUtils.trimFileProtocol(chat.requestScriptFilePath)]);
            requester.running = true;
        }

        function send() {
            if (requester.pendingLine.length === 0) return;
            requester.activeMessage = requester.message;
            requester.turnActive = true;
            chat.approval = null;
            chat.lastReport = null;
            chat.lastReportMsg = null;
            chat.lastAnswer = "";
            chat.lastError = "";
            idleClose.stop();
            requester.write(requester.pendingLine);
            requester.pendingLine = "";
        }

        onStarted: {
            requester.ready = true;
            requester.send();
        }

        stdout: SplitParser {
            onRead: data => {
                // A superseded turn's last lines (the agent flushes them as it
                // stops): not the new turn's, nor its fresh stream state.
                if (data.length === 0 || !requester.activeMessage || !requester.turnActive
                        || requester.restartPending || requester.activeMessage.done) return;
                if (requester.activeMessage.thinking) requester.activeMessage.thinking = false;

                try {
                    // Stopped: the "result" that ends the answer is no error to show.
                    if (requester.interrupting && data.trim().startsWith("{") && JSON.parse(data).type === "result") {
                        chat.strategy.finished = true;
                        requester.markDone();
                        return;
                    }
                    const result = chat.strategy.parseResponseLine(data, requester.activeMessage);

                    if (result.sessionId) {
                        chat.agentSessionId = result.sessionId;
                        requester.session = result.sessionId;
                    }
                    if (result.tokenUsage) {
                        chat.tokenCount.input = result.tokenUsage.input;
                        chat.tokenCount.output = result.tokenUsage.output;
                        chat.tokenCount.total = result.tokenUsage.total;
                    }
                    if (result.approval) chat.approval = result.approval;
                    if (result.approvalExpired && chat.approval?.id === result.approvalExpired) chat.approval = null;
                    // The final answer, before its checks (meta-agent's
                    // `answer`): the bubble shows it as the answer and reads
                    // it out now; `verify` and the turn's end come after.
                    if (result.answer !== undefined)
                        chat.lastAnswer = String(requester.activeMessage.content ?? "").replace(/<think>[\s\S]*?(<\/think>|$)/g, "").trim();
                    if (result.finished) {
                        requester.markDone();
                    }
                } catch (e) {
                    console.log("[AI] Could not parse response: ", e);
                    requester.activeMessage.rawContent += data;
                    requester.activeMessage.content += data;
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (requester.turnActive && requester.activeMessage && !requester.activeMessage.done && !requester.interrupting)
                chat.strategy.onRequestFinished(requester.activeMessage);
            requester.markDone();
            requester.ready = false;
            idleClose.stop();
            if (requester.restartPending) {
                requester.restartPending = false;
                // Its script is still being written (masking): started then.
                if (!requester.masking) requester.spawn();
            }
        }
    }

    // Stop: the agent ends on SIGTERM; killed if it doesn't.
    Timer {
        id: stopFallback
        interval: 5000
        onTriggered: if (requester.running && requester.interrupting) { requester.restartPending = false; requester.signal(9); }
    }

    // Unused for a while: closed (a few hundred MB); the next message
    // resumes the session. Kept warm ai.agent.keepWarmMinutes (60) while the
    // session is unlocked, 15 minutes while locked; started again on unlock
    // (Ai.qml).
    Timer {
        id: idleClose
        interval: (GlobalStates.screenLocked ? 15 : Math.max(1, Config.options?.ai?.agent?.keepWarmMinutes ?? 60)) * 60 * 1000
        onTriggered: if (requester.running && !requester.turnActive) { requester.restartPending = false; requester.signal(15); }
    }

    // Muse finished a turn while the panel is closed (ai.notifyWhenDone):
    // Muse's speech bubble says so with its answer, to reply to right
    // there (Initiative.chatDone); a notification when the bubble is taken
    // (the user typing in it), "waiting for you" when it ends on a question,
    // and its Open button opens the panel on this tab. Not in Do Not Disturb.
    // A conversation held in the bubble shows its answers there itself (not
    // one put away that the open panel shows: read there).
    function notifyDone(message) {
        if (Initiative.holds(chat)) {
            // Read in the side panel open on it: not brought back in the bubble.
            if (!(GlobalStates.sidebarLeftOpen && chat.isCurrent)) Initiative.chatAnswered(chat);
            return;
        }
        if (!(Config.options?.ai?.notifyWhenDone ?? true) || GlobalStates.sidebarLeftOpen || Notifications.silent) return;
        if (Initiative.chatDone(chat)) return;
        const lines = (message?.rawContent ?? "").split("\n")
            .map(l => l.replace(/[*_`#>]+/g, "").replace(/\s+/g, " ").trim())
            .filter(l => l.length > 0);
        const last = lines.length > 0 ? lines[lines.length - 1] : "";
        const asks = /[?？]$/.test(last);
        const notice = last.length > 140 ? last.slice(0, 139) + "…" : last;
        const summary = asks ? Translation.tr("The assistant is waiting for you") : Translation.tr("The assistant is done");
        doneNotifier.command = ["notify-send", "-a", "Shell", "-A", "open=" + Translation.tr("Open"), "--",
            Ai.chats.length > 1 ? `${summary} · ${chat.title}` : summary, notice];
        doneNotifier.running = false;
        doneNotifier.running = true;
    }
    Process {
        id: doneNotifier
        stdout: StdioCollector {
            onStreamFinished: {
                if (this.text.trim() !== "open") return;
                Ai.selectChat(chat);
                GlobalStates.sidebarLeftOpen = true;
            }
        }
    }
}
