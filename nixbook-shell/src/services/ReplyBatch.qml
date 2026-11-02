pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * The reply batch (ai.replies): the messages in the notification centre
 * that wait for an answer, each with a draft by Muse, in one card
 * (modules/ii/replies/ReplyBatchWindow.qml): Send / Edit / Skip. The
 * messages come from `nixbook-desktop-mcp replies draft` (plain code picks
 * them — a typed reply the app takes, a Discord DM through nixbook's
 * bridge, a chat app's Reply button —, one model call drafts them all,
 * masked for the provider). Nothing is ever sent without the user's click
 * on Send, and only through the path the message came with: the
 * notification's inline reply, `discord send` (as the user's own message:
 * the agents' pause and the bridge's rate limits apply), or, for an app
 * taking no typed reply, the draft copied and the conversation opened.
 *
 * Entry points: a chip in the bubble when two or more wait
 * (ai.replies.offer; with ai.replies.prepare the drafts are made first:
 * "drafts ready"), the daily brief's Help me reply, the bubble command
 * "help me reply" (QuickIntent), IPC `replies show`. Agents can't open it
 * (`replies` is in desktop-mcp's shellIpcDenyTargets).
 */
Singleton {
    id: root
    function load() {}

    readonly property var settings: Config.options?.ai?.replies ?? ({})
    readonly property bool enabled: Config.ready && (root.settings.enable ?? true) && (Config.options?.policies?.ai ?? 1) !== 0

    // The card: shown, drafting, the messages {id, app, who, text, via,
    // channel?, draft} (kept as they came: the card's edits live in it),
    // what came of each {id: {status: sending|sent|copied|skipped|error, error}}.
    property bool open: false
    readonly property bool busy: drafter.running
    property var items: []
    property var states: ({})
    property string error: ""
    property bool drafted: false
    property real _draftedAt: 0

    // Waiting now, by a quick look at the centre (desktop-mcp decides for
    // the card): those the app takes a typed reply for, or a chat app's
    // message with a Reply button.
    readonly property var _replyApps: /signal|whatsapp|telegram|discord|vesktop|webcord|slack|element|fractal|nheko|beeper|messages|messenger|instagram|teams|\bsms\b|kde ?connect|gsconnect|thunderbird|betterbird|evolution|geary|kmail|\bmail\b/i
    readonly property var _ownApps: ["muse", "reminder", "calendar", "nixbook-shell", "quick ai", "desktop agents", "desktop agent", "snoozed"]
    readonly property int waiting: {
        const seen = {}
        let n = 0
        for (const x of Notifications.list) {
            const app = String(x.appName ?? "")
            if (root._ownApps.includes(app.toLowerCase())) continue
            const replyable = x.hasInlineReply === true || (root._replyApps.test(app)
                && (x.actions ?? []).some(a => /reply|r[ée]pond|antwort|tr[ảa] l[ờo]i/i.test(`${a.identifier} ${a.text}`)))
            const key = `${app}|${x.summary}`
            if (!replyable || seen[key]) continue
            seen[key] = true
            n++
        }
        return n
    }

    function show() {
        if (!root.enabled) return Translation.tr("Reply drafts are off (Settings > Desktop agents)")
        root.open = true
        // Drafts made lately (ai.replies.prepare's "drafts ready") are kept.
        const fresh = root.items.length > 0 && root.left > 0 && Date.now() - root._draftedAt < 10 * 60000
        if (!drafter.running && !fresh) root._draft()
        return ""
    }
    function close() {
        root.open = false
    }
    function _draft() {
        root.items = []
        root.states = ({})
        root.error = ""
        root.drafted = false
        drafter.command = ["nixbook-desktop-mcp", "replies", "draft", "--lang", ConfigAssistant.uiLang()]
        drafter.running = true
    }
    function redraft() {
        if (!drafter.running) root._draft()
    }
    Process {
        id: drafter
        stdout: StdioCollector {
            id: draftOut
            onStreamFinished: {
                let r
                try { r = JSON.parse(draftOut.text) } catch (e) { r = null }
                if (!r || r.error) {
                    root.error = r?.error ?? Translation.tr("The messages couldn't be read")
                    return
                }
                root.items = r.items ?? []
                root.drafted = r.drafted === true
                root._draftedAt = Date.now()
                if (root.items.length === 0) root.error = Translation.tr("No message waits for a reply.")
                else if (!r.drafted) root.error = r.why ? Translation.tr("No drafts (%1): write your answers here.").arg(r.why)
                    : Translation.tr("No drafts: write your answers here.")
                if (root._announce) {
                    root._announce = false
                    if (root.items.length >= 2 && root.drafted) root._offerWord(root.items.length, true)
                }
            }
        }
    }

    function _set(id, status, error) {
        root.states = Object.assign({}, root.states, { [id]: { status: status, error: error ?? "" } })
    }
    function stateOf(id) {
        return root.states[id] ?? { status: "", error: "" }
    }
    // The user's Send: `text` as they left it in the card.
    function send(item, text) {
        const said = String(text ?? "").trim()
        if (!item || said.length === 0) return
        if (item.via === "inline") {
            if (Notifications.sendReply(item.id, said)) root._set(item.id, "sent")
            else root._set(item.id, "error", Translation.tr("That notification is gone: answer in the app."))
        } else if (item.via === "discord") {
            root._set(item.id, "sending")
            root._queue = [...root._queue, { id: item.id, channel: item.channel, text: said }]
            root._next()
        } else {
            // No typed reply: the draft to paste, the conversation opened.
            Quickshell.clipboardText = said
            Notifications.replyViaApp(item.id)
            root._set(item.id, "copied")
        }
    }
    function skip(item) {
        if (item) root._set(item.id, "skipped")
    }
    readonly property int left: root.items.filter(i => !["sent", "copied", "skipped"].includes(root.stateOf(i.id).status)).length

    // Discord: one send at a time, as the user (nixbook-desktop-mcp call
    // discord: the bridge's checks, the pause and its rate limit apply).
    property var _queue: []
    function _next() {
        if (sender.running || root._queue.length === 0) return
        const job = root._queue[0]
        root._queue = root._queue.slice(1)
        sender.job = job
        sender.command = ["nixbook-desktop-mcp", "call", "discord", JSON.stringify({ action: "send", channel: job.channel, content: job.text })]
        sender.running = true
    }
    Process {
        id: sender
        property var job: null
        environment: ({ NIXBOOK_DESKTOP_MCP_CLIENT: "Replies" })
        stdout: StdioCollector { id: sendOut }
        stderr: StdioCollector { id: sendErr }
        onExited: (code) => {
            if (sender.job) {
                if (code === 0) root._set(sender.job.id, "sent")
                else root._set(sender.job.id, "error", (sendOut.text || sendErr.text).trim().split("\n")[0] || Translation.tr("Not sent"))
            }
            sender.job = null
            root._next()
        }
    }

    // -- The offer: a chip in the bubble when two or more wait ---------------
    property bool _announce: false
    property real _offeredAt: 0
    property int _offeredCount: 0
    function _offerWord(n, ready) {
        Initiative.briefWord({ kind: "replies", offer: true,
            text: ready ? Translation.tr("%1 messages are waiting for a reply — drafts ready.").arg(n)
                        : Translation.tr("%1 messages are waiting for a reply. Want me to draft answers?").arg(n),
            actions: [{ label: ready ? Translation.tr("Review drafts") : Translation.tr("Draft replies"), do: "replies" }] })
    }
    function _maybeOffer() {
        if (!root.enabled || !(root.settings.offer ?? true) || root.open || drafter.running) return
        const n = root.waiting
        if (n < 2) {
            root._offeredCount = 0
            return
        }
        // More than last time, 30 minutes apart, never while busy.
        if (n <= root._offeredCount || Date.now() - root._offeredAt < 30 * 60000 || Initiative.busy()) return
        root._offeredAt = Date.now()
        root._offeredCount = n
        // Drafted first only when the user asked for it (their messages go to
        // the model before they said so otherwise), online only.
        if ((root.settings.prepare ?? false) && (Config.options?.policies?.ai ?? 1) === 1) {
            root._announce = true
            root._draft()
        } else root._offerWord(n, false)
    }
    onWaitingChanged: offerSoon.restart()
    Timer {
        id: offerSoon
        // A burst of messages settles first.
        interval: 20000
        onTriggered: root._maybeOffer()
    }

    IpcHandler {
        target: "replies"
        // The card, with fresh drafts.
        function show(): string {
            return root.show() || "ok: drafting"
        }
        function close(): string {
            root.close()
            return "ok"
        }
        function status(): string {
            return JSON.stringify({ enabled: root.enabled, waiting: root.waiting, open: root.open, busy: root.busy,
                items: root.items.length, left: root.left, error: root.error })
        }
    }
}
