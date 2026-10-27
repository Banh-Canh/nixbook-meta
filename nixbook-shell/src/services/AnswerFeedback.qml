pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import QtQuick

/**
 * 👍 / 👎 on Muse's answers (ai.agent.feedback), in the side panel
 * (AiMessage.qml) and the speech bubble (AgentSpeech.qml), both through
 * modules/common/widgets/AnswerFeedbackRow.qml. Kept by the desktop MCP
 * server's one memory (`nixbook-desktop-mcp feedback add`, on the helper's
 * thread):
 *   - 👍 reinforces what the answer used and keeps it as a good example;
 *   - 👎 opens a one-line "What did you mean?" field: Enter saves the
 *     correction ("when asked «…», the user meant: …"), which the context
 *     broker gives back for similar requests from then on, and offers to
 *     ask again with it (retry). Escape (or an empty Enter) saves the 👎
 *     alone.
 * Nothing is sent to a model here.
 */
Singleton {
    id: root

    readonly property bool enabled: Config.ready && (Config.options.ai.agent?.feedback ?? true)
        && (Config.options.policies.ai ?? 1) !== 0

    // An answer worth a verdict: Muse's (not the config assistant's, not an
    // error), finished.
    function rates(message) {
        // Not a plain command the shell did itself (QuickIntent: no model).
        return root.enabled && !!message && message.role === "assistant" && message.done === true && !(message.quick ?? false)
            && (message.model ?? "") !== Ai.configAssistantId && String(message.content ?? "").trim().length > 0
    }

    // The request it answered: the user's message before it.
    function requestFor(chat, message) {
        if (!chat || !message) return "";
        const ids = chat.messageIDs;
        let i = ids.findIndex(id => chat.messageByID[id] === message);
        for (i = i - 1; i >= 0; i--) {
            const m = chat.messageByID[ids[i]];
            if (m?.role === "user") return String(m.rawContent || m.content || "");
        }
        return "";
    }
    function plain(text) {
        return String(text ?? "").replace(/<think>[\s\S]*?(<\/think>|$)/g, "").replace(/<report>[\s\S]*?(<\/report>|$)/g, "").trim();
    }
    function _send(chat, message, surface, verdict, correction) {
        const entry = {
            verdict: verdict,
            request: root.requestFor(chat, message).slice(0, 2000),
            answer: root.plain(message.content).slice(0, 2000),
            app: message.requestApp ?? "",
            surface: surface,
        };
        if (correction) entry.correction = String(correction).slice(0, 1000);
        DesktopHelper.run(["feedback", "add", JSON.stringify(entry)], "", (code, out) => {
            if (code !== 0) console.log("[AnswerFeedback] Not saved:", out);
        });
    }

    function up(chat, message, surface) {
        if (!root.rates(message) || message.feedback === "up") return;
        message.feedback = "up";
        root._send(chat, message, surface, "up", "");
    }
    // 👎: the field opens; nothing saved until it is answered or left.
    function down(chat, message) {
        if (!root.rates(message)) return;
        message.feedback = message.feedback === "down" ? "" : "down";
    }
    // The field answered (Enter): the correction kept; empty, the 👎 alone.
    function correct(chat, message, surface, correction) {
        if (!message) return;
        const text = String(correction ?? "").trim();
        message.feedback = text.length > 0 ? "corrected" : "downSent";
        message.correction = text;
        root._send(chat, message, surface, "down", text);
    }
    // Asked again with what they meant: in the conversation it came from
    // (the bubble's own path, so it stays on its command line).
    function retry(chat, message, surface) {
        const text = String(message?.correction ?? "").trim();
        if (!chat || text.length === 0) return;
        message.feedback = "retried";
        const ask = Translation.tr("That's not what I meant: %1. Try again.").arg(text);
        if (surface === "bubble" && Initiative.holds(chat)) Initiative.reply(ask);
        else chat.sendUserMessage(ask);
    }
}
