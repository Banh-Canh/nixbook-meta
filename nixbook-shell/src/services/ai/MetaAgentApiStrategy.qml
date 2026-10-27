import QtQuick

// Muse through nixbook-meta-agent (`nixbook-meta-agent -p … --output-format
// stream-json`, scripts/meta-agent.py), on Meta's Model API with the user's
// key (nixbook-model-provider). The agent runs the tools itself (the desktop
// MCP server, web search, reading files), so this only turns its event
// stream into the chat message: text as it streams, thinking and each tool
// call with its result in one collapsible <think> block, the session id (the
// next message resumes it) and the token usage. The command line is built by
// Ai.qml (agentScript).
//
// With the flags the bubble and the side panel give it (Ai.agentScript):
// a risky tool call waits for the user's OK (approval_request, --confirm:
// `approval`, answered on stdin by AiChatSession.approve), a turn that
// acted is checked again with read-only tools (verify, --verify: the
// message's `verify`), an ambiguous request gets a question instead of an
// action (the result's clarify, --resolve: the message's `clarify`), and
// the bubble's turns end with a report (the result's report, --report:
// `report`, shown as the bubble's REPORT brief; its <report> block is
// never shown as text). `steps`: the turn's tool calls as Quick AI's were
// ({id, tool, summary, status: run|ok|error}), for Full AI's mascot.
//
// Autonomy (--trust, ai.autonomy): a step of a class the user trusts it
// with is told after it ran ({"type":"told"}: the message's `told`, a "Did:
// … Undo" line), three yeses in a row for one class bring a suggestion to
// stop asking ({"type":"trust_suggest"}: `trustSuggest`, a chip), and a
// standing_order tool result is a card to turn the order on (`orders`).
//
// Speed: the turn's final text is complete before its checks
// ({"type":"answer"}: the message's `answered`, shown and read out at once;
// `verify` comes after it), and each tool says when it starts, while the
// answer still streams ({"type":"tool_started"}: `doing`, the bubble's
// "Doing X…").
QtObject {
    // Tool calls of the current answer, by id: "name input", shown with
    // their result in one block.
    property var toolCalls: ({})
    property bool finished: false
    // The privacy mask: placeholders (⟦Person 2⟧) shown as the real values.
    // A placeholder cut between two pieces of the stream waits for its end.
    property var unmask: text => text
    property string held: ""
    // The turn's tool calls, in order (a new list each change: bindings
    // see it).
    property var steps: []
    // Inside the answer's <report>…</report> block: not shown.
    property bool inReport: false
    // The turn's end: its report, whether it asked back, the error.
    property var report: null
    property bool clarify: false
    property string error: ""
    // The tools running now (tool_started, until their result), by id ->
    // name; `doing`: the one started last, as the bubble says it.
    property var running: ({})
    property string doing: ""
    // The turn's final answer, before its checks (the `answer` event).
    property string answer: ""

    function reset() {
        toolCalls = ({});
        toolNames = ({});
        finished = false;
        held = "";
        steps = [];
        inReport = false;
        report = null;
        clarify = false;
        error = "";
        running = ({});
        doing = "";
        answer = "";
    }
    function _ran(id) {
        if (!(id in running)) return;
        const left = Object.assign({}, running);
        delete left[id];
        running = left;
        const names = Object.values(left);
        doing = names.length > 0 ? names[names.length - 1] : "";
    }

    // The answer's text as it streams, without its <report> block (the
    // tags themselves may come cut between two pieces: the end of the
    // message is cleaned up again once the turn is over, `stripReport`).
    function appendText(message, text) {
        let s = text;
        let shown = "";
        while (s.length > 0) {
            if (inReport) {
                const end = s.indexOf("</report>");
                if (end < 0) break;
                inReport = false;
                s = s.slice(end + 9);
            } else {
                const start = s.indexOf("<report>");
                if (start < 0) {
                    shown += s;
                    break;
                }
                shown += s.slice(0, start);
                inReport = true;
                s = s.slice(start + 8);
            }
        }
        if (shown.length > 0) append(message, shown);
    }
    function stripReport(text) {
        return String(text ?? "").replace(/<report>[\s\S]*?(<\/report>|$)/g, "").replace(/\s+$/, "");
    }

    // Tool call id -> tool name (a standing_order's result is a card).
    property var toolNames: ({})
    function _push(message, prop, value) {
        message[prop] = [...(message[prop] ?? []), value];
    }
    function _order(message, text) {
        let r = null;
        try {
            r = JSON.parse(unmask(String(text ?? "")));
        } catch (e) {
            return;
        }
        if (!r || typeof r !== "object" || r.error || (!r.id && !(r.questions ?? []).length)) return;
        _push(message, "orders", { id: String(r.id ?? ""), summary: String(r.summary ?? ""),
            routine: r.routine ?? null, questions: (r.questions ?? []).map(q => String(q)).slice(0, 4) });
    }

    function toolName(name) {
        // mcp__desktop__close_window -> close_window
        const m = /^mcp__.+?__(.+)$/.exec(name ?? "");
        return m ? m[1] : (name ?? "");
    }
    function setStep(id, fields) {
        const list = steps.slice();
        const i = list.findIndex(x => x.id === id);
        if (i >= 0) list[i] = Object.assign({}, list[i], fields);
        else list.push(Object.assign({ id: id }, fields));
        steps = list;
    }

    function append(message, text) {
        let s = held + text;
        const open = s.lastIndexOf("⟦");
        held = open >= 0 && s.indexOf("⟧", open) < 0 && s.length - open < 40 ? s.slice(open) : "";
        if (held.length > 0) s = s.slice(0, open);
        s = unmask(s);
        message.rawContent += s;
        message.content += s;
    }

    function flush(message) {
        if (held.length === 0) return;
        const s = unmask(held);
        held = "";
        message.rawContent += s;
        message.content += s;
    }

    // One line of JSON, short enough to read in the chat.
    function brief(value, max) {
        let s = typeof value === "string" ? value : JSON.stringify(value);
        s = (s ?? "").replace(/\s+/g, " ").trim();
        return s.length > max ? s.slice(0, max) + "…" : s;
    }

    function toolLabel(name) {
        // mcp__desktop__click -> desktop: click
        const m = /^mcp__([^_]+(?:_[^_]+)*)__(.+)$/.exec(name ?? "");
        return m ? `${m[1]}: ${m[2]}` : name;
    }

    function resultText(content) {
        if (typeof content === "string") return content;
        if (!Array.isArray(content)) return "";
        return content.map(c => c.type === "text" ? c.text : c.type === "image" ? "[image]" : "").join(" ");
    }

    function parseResponseLine(line, message) {
        const data = line.trim();
        if (data.length === 0 || data[0] !== "{") return {};
        const ev = JSON.parse(data);
        const out = {};
        if (ev.session_id) out.sessionId = ev.session_id;

        if (ev.type === "stream_event") {
            // Text and thinking as they come (--include-partial-messages).
            const e = ev.event ?? {};
            if (e.type === "content_block_start" && e.content_block?.type === "thinking")
                append(message, "\n\n<think>\n");
            else if (e.type === "content_block_delta" && e.delta?.type === "text_delta")
                appendText(message, e.delta.text);
            else if (e.type === "content_block_delta" && e.delta?.type === "thinking_delta")
                append(message, e.delta.thinking);
            else if (e.type === "content_block_stop" && message.rawContent.lastIndexOf("<think>") > message.rawContent.lastIndexOf("</think>"))
                append(message, "\n</think>\n\n");
        } else if (ev.type === "assistant") {
            // Whole messages repeat the streamed text: only the tool calls.
            for (const block of (ev.message?.content ?? [])) {
                if (block.type !== "tool_use") continue;
                toolCalls[block.id] = `**${toolLabel(block.name)}** ${brief(block.input, 300)}`;
                toolNames[block.id] = toolName(block.name);
                // Started while the message streamed, maybe done already.
                const before = steps.find(x => x.id === block.id);
                setStep(block.id, { tool: toolName(block.name), summary: brief(block.input, 80),
                                    status: before && before.status !== "run" ? before.status : "run" });
            }
        } else if (ev.type === "user") {
            for (const block of (ev.message?.content ?? [])) {
                if (block.type !== "tool_result") continue;
                _ran(block.tool_use_id);
                const call = toolCalls[block.tool_use_id] ?? "**tool**";
                const text = brief(resultText(block.content), 400);
                setStep(block.tool_use_id, { status: block.is_error ? "error" : "ok", result: brief(resultText(block.content), 120) });
                if (!block.is_error && toolNames[block.tool_use_id] === "standing_order") _order(message, resultText(block.content));
                append(message, `\n\n<think>\n${call}\n\n${block.is_error ? "⚠ " : "→ "}${text}\n</think>\n\n`);
            }
        } else if (ev.type === "tool_started") {
            // Started as soon as its call was complete, the message still
            // streaming (no approval needed).
            const id = String(ev.id ?? "");
            const name = toolName(ev.name);
            running = Object.assign({}, running, { [id]: name });
            doing = name;
            if (!steps.some(x => x.id === id)) setStep(id, { tool: name, summary: "", status: "run" });
        } else if (ev.type === "answer") {
            // The final text, complete before the checks: shown as done and
            // read out now; `verify` and `result` follow.
            flush(message);
            answer = stripReport(unmask(String(ev.text ?? "")));
            message.answered = true;
            message.thinking = false;
            out.answer = answer;
        } else if (ev.type === "approval_request") {
            // A risky step waiting for the user's OK (--confirm).
            out.approval = { id: String(ev.id ?? ""), tool: toolName(ev.tool), input: ev.input ?? {},
                             summary: brief(ev.summary || ev.input || "", 120) };
            setStep(String(ev.id ?? ""), { tool: toolName(ev.tool), summary: brief(ev.summary || ev.input || "", 80), status: "run" });
        } else if (ev.type === "told") {
            // Done without asking (trusted: tell), journaled: "Did: … Undo".
            _push(message, "told", { class: String(ev.class ?? ""), summary: unmask(brief(ev.summary || ev.class || "", 160)),
                                     id: String(ev.journal ?? ev.id ?? ""), undo: ev.undo !== false });
        } else if (ev.type === "trust_suggest") {
            // Allowed three times in a row: stop asking? (the user's click).
            if (!(message.trustSuggest ?? []).some(x => x.class === ev.class))
                _push(message, "trustSuggest", { class: String(ev.class ?? ""), summary: unmask(brief(ev.summary || ev.class || "", 120)) });
        } else if (ev.type === "verify") {
            // Checked after acting (--verify): met, or why not.
            message.verify = { met: ev.met === true, note: String(ev.note ?? "") };
            out.verify = message.verify;
        } else if (ev.type === "result") {
            flush(message);
            finished = true;
            running = ({});
            doing = "";
            out.finished = true;
            if (ev.is_error) {
                const why = ev.result || (ev.errors ?? []).join("; ") || ev.subtype;
                error = String(why ?? "");
                append(message, `\n\n**Error**: ${why}`);
            }
            // The <report> block out of the text, whatever came cut.
            if (message.rawContent.indexOf("<report>") >= 0) {
                message.rawContent = stripReport(message.rawContent);
                message.content = stripReport(message.content);
            }
            if (ev.clarify === true) {
                clarify = true;
                message.clarify = true;
            }
            if (ev.verified !== undefined && message.verify === null)
                message.verify = { met: ev.verified === true, note: "" };
            if (ev.report && typeof ev.report === "object") {
                // Steps counted from what really ran.
                const ran = steps.filter(x => x.status === "ok" || x.status === "error");
                report = Object.assign({ steps: ran.length, ok: ran.filter(x => x.status === "ok").length,
                    ko: ran.filter(x => x.status === "error").length }, ev.report);
                out.report = report;
            }
            const u = ev.usage ?? {};
            const input = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
            out.tokenUsage = { input: input, output: u.output_tokens ?? 0, total: input + (u.output_tokens ?? 0) };
        }
        return out;
    }

    function onRequestFinished(message) {
        flush(message);
        // The agent exited without a result: say so (no key, crashed…).
        if (!finished && message.rawContent.trim().length === 0)
            append(message, "**Error**: Muse's agent (nixbook-meta-agent) stopped without an answer. Is your Meta API key saved (Settings > Desktop agents > Model provider)?");
    }
}
