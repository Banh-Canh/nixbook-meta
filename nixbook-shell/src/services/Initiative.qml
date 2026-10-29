pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import Quickshell.Wayland
import QtQuick

/**
 * The desktop agent speaking first (ai.initiative): when something happens
 * it can help with, not on a schedule. This hands what happens to
 * `nixbook-desktop-mcp initiative consider` (plain code decides whether a
 * word is worth it, the user's past answers, their being busy, the day's
 * budget; a small model only reads notifications):
 *   - back: the screens come on, or the session unlocks, after a while;
 *   - focus: an app gets the focus (at most every few minutes);
 *   - notifications (ai.initiative.readNotifications, off by default):
 *     what came in, in batches;
 *   - moment: now and then, at random (40 minutes to 2 hours apart while
 *     the user is at the computer), a chance for a light word: most of the
 *     time nothing is said, at most a couple a day, as a small bubble.
 *   - happened (ai.initiative.reactions, off by default): what the user
 *     just did (a download, a screenshot, a drive), with one-click help.
 * What it says comes out loud (`speaking`: its own bubble on the left,
 * AgentSpeech.qml) or waits in the bar (`pending`: the robot's bubble),
 * until it expires. The bubble is a small chat: the user answers in it and
 * Muse answers there (`chat`, a thread of its own, the side panel's "From
 * Muse" tab, opened there only on expand()); the answer teaches it what
 * the user values. Mod+C calls the bubble up to ask anything. Notifications
 * and what the user just did come from the one event reactor
 * (services/Reactor.qml), after Full AI mode: one model decision per event.
 */
Singleton {
    id: root

    // policies.ai: 1 (online models), or 2 (local only): then only what is
    // plain code (reactions' Open and Show in folder, routines' reports,
    // watches, the brief) and what a local model reads (localModel in
    // desktop-mcp.json: notifications, pairing); nothing to answer Muse in.
    readonly property bool enabled: (Config.options?.ai?.initiative?.enable ?? false) && [1, 2].includes(Config.options?.policies?.ai ?? 1)
    readonly property bool online: (Config.options?.policies?.ai ?? 1) === 1
    readonly property bool readNotifications: Config.options?.ai?.initiative?.readNotifications ?? false
    readonly property string statePath: `${Quickshell.env("XDG_STATE_HOME") || `${Quickshell.env("HOME")}/.local/state`}/nixbook-shell/initiative.json`
    // What waits for the user, newest last: {id, kind, text, chat, time, expires}
    // (what it says out loud too: the bar shows it once its bubble goes).
    property var pending: []
    // Its last decisions, newest last: {time, event, action, said, why}.
    property var log: []
    // What agents watch for the user (the watch tool): checked every minute
    // while there are some (one short process, none otherwise), at no token; what finished is said in the
    // bubble (a notification while the initiative is off). Not while the
    // screens are off: nobody to tell, checked again as they come back.
    property var watches: []
    Timer {
        interval: 60000
        running: root.watches.length > 0 && (Config.options?.policies?.ai ?? 1) !== 0 && !Idle.screensOff
        triggeredOnStart: true
        repeat: true
        onTriggered: if (!watchCheck.running) {
            watchCheck.command = ["nixbook-desktop-mcp", "watch", "check", ...(root.busy() ? ["--busy"] : [])]
            watchCheck.running = true
        }
    }
    Process {
        id: watchCheck
        stdout: StdioCollector {
            id: watchOut
            onStreamFinished: {
                try {
                    for (const item of JSON.parse(watchOut.text).said ?? []) {
                        if (item.level === "notify") root._say(item)
                        else {
                            root.pending = [...root.pending.filter(p => p.id !== item.id), item]
                            root._feed(item)
                        }
                    }
                } catch (e) {
                    // Nothing finished, or the server is missing.
                }
            }
        }
    }
    property real now: Date.now()
    readonly property var live: root.pending.filter(p => (p.expires ?? 0) * 1000 > root.now && p.id !== root.speaking?.id
        && !root.stack.some(q => q.id === p.id))
    // Its other words, newest last: small bubbles on the left, under its
    // bubble, like notifications (AgentSpeech.qml): what it says while the
    // bubble is taken, a word put aside unread, and its quiet words (a badge:
    // `_feed`). Only the bubble holds a conversation (and only it comes back
    // from the bar or Mod+C); a small one is opened into it with a click.
    // One that waits for an answer (a question, a Yes, buttons: `waits`)
    // stays until it expires; the others go to the bar once read or after
    // 10 minutes (`unstack`).
    property var stack: []
    readonly property int stackMax: 3
    readonly property var stacked: root.stack.filter(p => (p.expires ?? 0) * 1000 > root.now && p.id !== root.speaking?.id)
    function waits(item) {
        return !!item && (!!item.accept || !!item.offer?.order || (item.actions ?? []).length > 0 || /[?？]\s*$/.test(item.text ?? ""))
    }
    function _stackPush(item) {
        if (!item?.id) return
        root.stack = [...root.stack.filter(p => p.id !== item.id), item].slice(-root.stackMax)
    }
    // To the bar (still there, answered later).
    function unstack(item) {
        root.stack = root.stack.filter(p => p.id !== item?.id)
    }
    // Closed (its x): seen, not taken up, as "Not now" in the bubble.
    function dismissStacked(item, outcome) {
        root.unstack(item)
        root.markRead(item)
        if (item?.id) root.answer(item.id, outcome ?? "later")
    }
    // Read: what the user has seen in the bubble (hovered, answered, closed
    // or opened from the bar), by id. Still there, but the bar's bubble only
    // lights up for what they haven't, and for a routine it offered until
    // they answer it (its Yes is there).
    property var _read: ({})
    // Kept across restarts (Persistent.states.ai.initiativeRead).
    property bool _readLoaded: false
    function _loadRead() {
        if (root._readLoaded || !Persistent.ready) return
        const ids = {}
        for (const id of Persistent.states.ai.initiativeRead ?? []) ids[id] = true
        root._read = Object.assign(ids, root._read)
        root._readLoaded = true
        root._feedUnread()
    }
    Connections {
        target: Persistent
        function onReadyChanged() { root._loadRead() }
    }
    // Every unread word still current gets its small bubble once (a word
    // written by the memory pass, a routine's report or a watch, those
    // waiting when the shell started): none goes to the bar unseen.
    property var _fed: ({})
    function _feedUnread() {
        if (!root._readLoaded) return
        const t = Date.now()
        for (const p of root.pending) {
            if (!p?.id || root._fed[p.id] || root._read[p.id] || (p.expires ?? 0) * 1000 <= t) continue
            root._fed[p.id] = true
            root._feed(p)
        }
    }
    readonly property var unread: root.live.filter(p => p.accept || !root._read[p.id])

    // Quiet words on their way to the small bubbles (`_feed`): they come in
    // at a pause (no input for a few seconds), never while the user is busy
    // or deep in something (`inFocus`), then together at the next break.
    property var _arrivals: []
    property var _known: null
    function _feed(item) {
        if (!item?.id || item.id === root.speaking?.id) return
        root._fed[item.id] = true
        root._arrivals = [...root._arrivals.filter(p => p.id !== item.id), item]
        root.now = Date.now()
        root._flush()
    }
    function _flush() {
        if (root._arrivals.length === 0 || !feedPause.isIdle || root.inFocus || root.busy()) return
        const t = Date.now()
        for (const it of root._arrivals)
            if ((it.expires ?? 0) * 1000 > t && root.pending.some(p => p.id === it.id)) root._stackPush(it)
        root._arrivals = []
    }
    IdleMonitor {
        id: feedPause
        enabled: root._arrivals.length > 0
        timeout: 3
        respectInhibitors: false
        onIsIdleChanged: if (isIdle) root._flush()
    }
    // Deep in something (ai.initiative.holdInFocus): at it for 10 minutes,
    // no break of a minute, on one or two apps (an editor and its terminal).
    // Quiet words wait meanwhile; urgent ones still come.
    readonly property bool holdInFocus: Config.options?.ai?.initiative?.holdInFocus ?? true
    property real _focusSince: Date.now()
    property var _focusApps: []
    readonly property bool inFocus: root.holdInFocus && root.now - root._focusSince >= 10 * 60000
    onInFocusChanged: if (!root.inFocus) root._flush()
    function _focusApp(app) {
        if (!app || root._focusApps.includes(app)) return
        if (root._focusApps.length >= 2) root._focusSince = Date.now() // a third app: a break
        root._focusApps = [...root._focusApps, app].slice(-2)
    }
    IdleMonitor {
        id: breakIdle
        enabled: root.enabled
        timeout: 60
        respectInhibitors: false
        onIsIdleChanged: {
            root._focusSince = Date.now()
            root._focusApps = []
            if (!isIdle) root.now = Date.now()
        }
    }

    property var _batch: []
    property real _awaySince: 0
    // At the computer since (back from the last break).
    property real _activeSince: Date.now()
    property real _lastFocus: 0
    property string _lastApp: ""

    function load() {
        stateFile.reload()
    }

    // Busy: not to be interrupted (Do Not Disturb, a meeting now, a
    // fullscreen window, the screens off): what it has to say then waits.
    function busy() {
        if (Notifications.silent || GlobalStates.screenLocked || Idle.screensOff) return true
        const t = new Date()
        if (CalendarEvents.eventsOn(t).some(e => !e.allDay && e.start <= t && e.end > t)) return true
        const mon = WM.focusedMonitor?.name ?? ""
        return mon !== "" && WM.fullscreenOnMonitor(mon)
    }

    function _nextEvent() {
        const e = CalendarEvents.upcoming(1, new Date(), true)[0]
        return e ? `${e.summary} ${CalendarEvents.whenText(e, new Date())}` : ""
    }

    // `tag`: what the shell offered about (ContextTriggers.qml: {kind, key,
    // app}), kept with the word that comes back, for its Never for this.
    function consider(event, tag) {
        if (!root.enabled) return
        event.busy = event.force === true ? false : root.busy()
        const what = event.force !== true ? "" : event.event === "news" ? "news" : "say"
        if (what !== "") root._askNow(what)
        // Reading the screen (pairing): the eye in the bar meanwhile.
        const looks = event.event === "pair" && event.screen === true
        if (looks) root.looking += 1
        // The helper decides on a thread of its own (a model's answer can take
        // seconds): no Python start each time.
        DesktopHelper.run(["initiative", "consider", JSON.stringify(event)], "", (code, out) => root._considered(out, what, looks, tag ?? null))
    }
    function _considered(out, asked, looks, tag) {
        if (looks) root.looking = Math.max(0, root.looking - 1)
        let action = "none"
        try {
            const answer = JSON.parse(out)
            if (tag && answer.item) {
                answer.item.trigger = tag
                if (answer.item.id) root._offerTags = Object.assign({}, root._offerTags, { [answer.item.id]: tag })
            }
            if (answer.action === "notify") root._say(answer.item)
            if (answer.action === "badge") {
                root.pending = [...root.pending, answer.item]
                root._feed(answer.item)
            }
            if (answer.action === "notify" || answer.action === "badge") action = answer.action
        } catch (e) {
            // Nothing to say, or the server is missing: silence.
        }
        if (asked !== "" && asked === root.asking) {
            root.asking = ""
            root.asked = action
        }
    }
    // Looks at the screen now (pairing with the screen read): the bar shows
    // an eye (DesktopControl.qml), so it never reads it unseen.
    property int looking: 0
    // Say something now / Find news now waiting for their answer ("say",
    // "news"; Settings shows it), and what came of the last one (its
    // action: "notify", "badge" or "none").
    property string asking: ""
    property string asked: ""
    function _askNow(what) {
        root.asking = what
        root.asked = ""
    }

    function back(awayMinutes) {
        // Full AI mode reacts to the user coming back itself (the Reactor
        // gives it Routines' "back"): not a second decision here.
        if (Reactor.takenElsewhere({ event: "back", away: awayMinutes }, "initiative")) return
        const t = new Date()
        const fmt = Config.options?.time.format ?? "hh:mm"
        const events = CalendarEvents.upcoming(4, t).filter(e => e.allDay || e.start.toDateString() === t.toDateString())
            // Untitled: no title (the calendar's "(No title)" means nothing in the brief).
            .map(e => ({ title: e.summary === Translation.tr("(No title)") ? "" : e.summary, start: e.allDay ? "" : Qt.locale().toString(e.start, fmt), allDay: e.allDay,
                         inMinutes: e.allDay ? null : Math.round((e.start - t) / 60000) }))
        // What they were on before the break (ai.initiative.recentContext).
        const recent = RecentContext.enabled && awayMinutes >= 10 ? RecentContext.snapshot(root._awaySince || Date.now()) : []
        root.consider({ event: "back", away: Math.round(awayMinutes), events: events, tasksDue: Todo.dueTodayCount,
                        open: WM.windowList.map(w => w.appId), recent: recent })
    }

    // Curiosity (ai.initiative.curious): it watches what is in front (app and
    // window title, every few minutes) and learns what the user does from it,
    // saying what it learned; the reply corrects or completes it.
    readonly property bool curious: Config.options?.ai?.initiative?.curious ?? false
    readonly property string learnHint: "You said this from watching what the user does, to learn about them. "
        + "If they correct what you noticed or tell you more, update your memory of them (recall_about_user, then "
        + "remember_about_user with the entry's id; forget_about_user what was wrong), briefly. If you offered help "
        + "and they want it, do it now with your tools (look at their screen first if needed); then answer naturally."
    // Reactions (ai.initiative.reactions): what the user just did (a file
    // downloaded, a screenshot, a drive plugged in), offered at once with
    // buttons that act in one click (services/Routines.qml sees them).
    readonly property bool reactions: Config.options?.ai?.initiative?.reactions ?? false
    // News (ai.initiative.news): about once a day, what's new on the subjects
    // the user talks about most, found on the web by the small model, said
    // with its links (buttons under the bubble).
    readonly property bool news: Config.options?.ai?.initiative?.news ?? false
    readonly property string newsHint: "You found this news for the user, from what they talk about with you. "
        + "If they want more on one, read it (WebFetch) or search for more (WebSearch) and tell them, with links. "
        + "If they say a subject doesn't interest them (any more), update your memory of them, briefly."
    // Pairing (ai.initiative.pair): while the user stays on one thing, a look
    // at it every couple of minutes (nixbook-desktop-mcp decides whether a
    // look is worth it, at no token); with ai.initiative.pairReadScreen the
    // screen's text too (OCR, redacted). A word it has comes as a small
    // bubble once the user pauses (`_feed`), never over what they type.
    readonly property bool pair: Config.options?.ai?.initiative?.pair ?? false
    readonly property bool pairReadScreen: Config.options?.ai?.initiative?.pairReadScreen ?? false
    property real _pairSince: Date.now()
    // Another window: a pairing word on its way was about the one before
    // (it stays in the bar).
    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() {
            const app = ToplevelManager.activeToplevel?.appId ?? ""
            root._pairSince = Date.now()
            root._focusApp(app)
            root._arrivals = root._arrivals.filter(p => p.kind !== "pair" || p.app === app)
        }
    }
    Timer {
        interval: 2 * 60000
        running: root.enabled && root.pair && !Idle.screensOff
        repeat: true
        onTriggered: {
            // Not right after a switch: on something, not passing through.
            if (GlobalStates.screenLocked || Date.now() - root._pairSince < 60000) return
            const top = ToplevelManager.activeToplevel
            if (!top) return
            root.consider({ event: "pair", app: top.appId ?? "", title: top.title ?? "", screen: root.pairReadScreen })
        }
    }
    // Settings > Find news now: at once, whatever the day's already had.
    function newsNow() {
        if (!root.enabled) return
        root.consider({ event: "news", force: true, location: root.newsLocation() })
    }
    // Where the user is, for local news: the weather's city (the one set,
    // or found by GPS), city and country only.
    function newsLocation() {
        const city = Weather.data?.city ?? ""
        if (city.length === 0 || city === "City") return ""
        return [city, Weather.data?.country ?? ""].filter(s => s.length > 0).join(", ")
    }
    readonly property var reactTo: ["download", "screenshot", "drive_connected"]

    // What it says out loud now (modules/ii/notificationPopup/AgentSpeech.qml,
    // on the left under the bar): one at a time, the one before to the bar.
    // {id, kind, text, chat?, accept?, actions?}; kind "ask" (the user
    // called it: Mod+C) and "done" (a chat of the side panel
    // answered while it was closed) have no id: nothing to learn from.
    property var speaking: null
    // The conversation in the bubble (an AiChatSession): Muse's own thread
    // (Ai.agentThread, the side panel's "From Muse" tab) once the user
    // answers in the bubble, or the panel's tab whose answer it shows. The
    // bubble is the chat: the panel only when asked (expand()).
    property var chat: null
    readonly property bool conversing: root.chat !== null && (root.chat.messageIDs ?? []).some(id => root.chat.messageByID[id]?.role === "user")
    // Put away with its conversation (closed, or left a while): the bar's
    // bubble brings it back, and so does Muse's next answer in it.
    // {item, chat, unread}: unread once Muse answered in it put away (not
    // brought back then: the user busy), so the bar's bubble lights up.
    property var parked: null
    readonly property bool thinking: (root.chat?.responding ?? false) || (root.parked?.chat?.responding ?? false)
        || (QuickAi.busy && (QuickAi.owns(root.chat) || QuickAi.owns(root.parked?.chat ?? null)))
    // The user is writing in the bubble: nothing takes its place meanwhile.
    property bool typing: false
    // The conversation goes on out of sight (ai.quick.bubble "needed": talking
    // to it, Full AI mode): the answers said out loud or in the mascot's
    // balloon, the bubble shown only for what needs the user's eyes (replies
    // to pick, an error, an OK that can't be said) or when called up (Mod+C,
    // which hides it again while they talk).
    property bool quiet: false
    onQuietChanged: if (!root.quiet && root.speaking) root.focusWanted()
    Connections {
        target: QuickAi
        function onRepliesChanged() { if (QuickAi.replies.length > 0) root.quiet = false }
        function onErrorChanged() { if (QuickAi.error.length > 0) root.quiet = false }
        function onPendingChanged() {
            // An OK nobody can say (no microphone coming back): asked on screen.
            if (QuickAi.pending && !Voice.session && !FullAi.active) root.quiet = false
        }
    }
    // The bubble's field wants the keys (it was called up with the keyboard).
    signal focusWanted()
    property string _answeredId: ""

    // Shows it in the bubble (the bar's bubble, a word waiting).
    function open(item) {
        if (!item) return
        root.unstack(item)
        root.markRead(item)
        if (root.speaking && root.speaking === item) return
        root._notify(item)
    }
    function openLatest() {
        if (root.parked) root.resume()
        else root.open(root.live[root.live.length - 1])
    }
    // Settings > Say something now: a light word at once, to try it.
    function sayNow() {
        root.consider({ event: "moment", force: true, curious: root.curious, app: ToplevelManager.activeToplevel?.appId ?? "",
                        title: root.curious ? (ToplevelManager.activeToplevel?.title ?? "") : "",
                        activeMinutes: Math.round((Date.now() - root._activeSince) / 60000),
                        tasksDue: Todo.dueTodayCount, weatherCode: Weather.data?.wCode ?? 0,
                        weather: Weather.data?.description ?? "" })
    }
    // Called up (Mod+C, the bar's robot): its bubble, to ask
    // anything; the conversation put away comes back instead.
    function summon() {
        // AI off (policies.ai): no bubble to ask Muse in.
        if ((Config.options?.policies?.ai ?? 1) !== 1) return
        if (root.parked && !root.speaking) root.resume()
        else if (!root.speaking) root.speaking = root._ask()
        root.focusWanted()
    }
    // A question asked in the bubble takes what the user just did along
    // (RecentContext.text, shown there), unless they leave it out (its ×).
    property bool skipContext: false
    onSpeakingChanged: {
        // Nothing said any more: the next bubble is seen.
        if (!root.speaking) root.quiet = false
        else if (root.speaking.kind === "ask" && !root.conversing) {
            root.skipContext = false
            RecentContext.refresh()
        }
    }
    // Mod+C, the bar's robot button: called up, or put away when shown.
    function toggle() {
        // Out of sight: shown. Shown while talking: out of sight again (the
        // conversation goes on by voice).
        if (root.speaking && root.quiet) root.quiet = false
        else if (root.speaking && Voice.hideBubble && (Voice.session || FullAi.active)) root.quiet = true
        else if (root.speaking) root.hush("wait")
        else {
            root.quiet = false
            root.summon()
        }
    }
    // Called up by the user (Mod+C), or what it did for them there at once
    // ("quick"): a new conversation of theirs, not a "From Muse" thread.
    function isAsk(item) {
        return item?.kind === "ask" || item?.kind === "quick"
    }
    function _ask() {
        return { id: "", kind: "ask", text: root._pick([Translation.tr("What can I do for you?"),
            Translation.tr("I'm here. What do you need?"), Translation.tr("Yes? Ask me anything.")]) }
    }
    // Its threads (the "From Muse" ones of the history, and those the user
    // started in the bubble), newest first, to go back to one in the bubble.
    readonly property var threads: Ai.history.filter(c => c.fromAgent || c.fromBubble).slice(0, 8)
    function openThread(id) {
        let chat = Ai.chats.find(c => c.chatId === id)
        if (!chat) {
            if (root.chat?.chatId === id) chat = root.chat
            else {
                // One the user started comes back as theirs, not Muse's.
                chat = Ai.history.find(c => c.id === id)?.fromBubble ? Ai.askThread(false) : Ai.agentThread(false)
                if (!Ai.openChatIn(chat, id)) return
            }
        }
        if (root.parked?.chat === chat) root.parked = null
        if (root.chat !== chat) root._aside()
        root.chat = chat
        root.speaking = { id: "", kind: "done", text: "", title: Ai.history.find(c => c.id === id)?.title ?? "" }
    }
    // A new conversation in the bubble (its new-chat button, /new or
    // /clear): the one before is left as it is, in the side panel's history
    // (the next message's thread saves it, Ai.agentThread); one still
    // answering goes on in its tab.
    function fresh() {
        const before = root.chat
        if (before && !root.conversing && before.fromAgent && !before.responding) before.clearMessages()
        if (root.parked?.chat === before) root.parked = null
        root.chat = null
        if (before && !before.fromAgent) Ai.dropIfEmpty(before)
        root.speaking = root._ask()
        root.focusWanted()
    }
    // The user saw it (the bubble hovered, typed in, closed).
    function markRead(item) {
        const it = item ?? root.speaking
        if (it?.id && !root._read[it.id]) {
            root._read = Object.assign({}, root._read, { [it.id]: true })
            if (Persistent.ready)
                Persistent.states.ai.initiativeRead = [...(Persistent.states.ai.initiativeRead ?? []).filter(id => id !== it.id), it.id].slice(-300)
        }
    }
    function _pick(list) {
        return list[Math.floor(Math.random() * list.length)]
    }

    // The conversation with what it said as Muse's first message, in its
    // own thread (the "From Muse" tab, not selected): made when the user
    // starts typing, so the agent is warm by the time they send.
    // Called up by the user for a new conversation (kind "ask"): a normal
    // one (Ai.askThread), not a "From Muse" thread: Muse said nothing yet.
    function prepare() {
        const item = root.speaking
        if (root.chat || !item) return
        const thread = root.isAsk(item) ? Ai.askThread(false) : Ai.agentThread(false)
        if (!root.isAsk(item))
            thread.addMessage(item.chat || item.text, "assistant", true, root._hint(item))
        root.chat = thread
        // Muse's agent started ahead on the bubble's command line (whatever
        // model the side panel shows): warm by the time they send.
        thread.surface = "bubble"
        if (Ai.agentReady) thread.prewarm()
    }
    function _hint(item) {
        return item.curious ? root.learnHint : item.kind === "news" ? root.newsHint : ""
    }
    // What it said, taken up: counted once, and the talk that follows too.
    function _taken(item) {
        if (!item?.id || root._answeredId === item.id) return
        root._answeredId = item.id
        root.markRead(item)
        root._opened = { id: item.id, time: Date.now() }
        root.answer(item.id, "replied")
    }
    // The user's answer, in the bubble: Muse answers there.
    function reply(text, attach) {
        const said = String(text ?? "").trim()
        if (said.length === 0) return
        const item = root.speaking
        root.lastQuickText = ""
        // A plain command asked for (open an app, pause the music, volume
        // 30, workspace 2, dark mode…): done at once, no Muse run, zero
        // tokens, at any point of a conversation; in one, only when it names
        // what it acts on (never "pause it": that one is Muse's). It says
        // what it did ("Done: …", with Undo when it can be undone), and the
        // turn goes in the conversation as an offSession note: the agent
        // hears of it with the next message (Ai.agentPrompt).
        if (!attach) {
            const did = QuickIntent.run(said, root.conversing)
            if (did) {
                root._quickDone(item, said, did)
                return
            }
            // A film or an episode from Jellyfin ("play edgerunners season 1
            // episode 2"): played at once by jellyfin-mcp (no model, about a
            // second); what it doesn't recognise goes on to Muse below.
            if (QuickIntent.video(said, root.conversing, r => root._videoDone(item, said, r)))
                return
        }
        root._toMuse(item, said, attach)
    }
    // What jellyfin-mcp play-query answered: played ("Done: Playing …"), or
    // its question / why not ("Which one: …?", "… has only 1 season"),
    // said out loud too when the request was; not a video it knows: Muse's.
    function _videoDone(item, said, r) {
        if (!r || !(r.ok || r.matched) || !r.said) {
            root._toMuse(item, said, "")
            return
        }
        root._quickDone(item, said, { text: r.said, plain: !r.ok })
        if (Voice.voiceTurn || Voice.speakMode === "always") {
            Voice.voiceTurn = false
            Voice.speak(r.said)
        }
    }
    function _toMuse(item, said, attach) {
        // Everything else (services/QuickAi.qml): Muse's agent in the
        // bubble's session (its own threads too: the bubble's command line,
        // Allow / No before risky steps), or the small model for a question
        // about an image. What the user was just doing goes along through
        // the context broker (unless its × took it out: skipContext).
        // AI off (QuickAi.handle said no for that): nothing goes to Muse.
        if (!root.online) return
        if (QuickAi.handle(said, attach ?? "")) {
            root._taken(item)
            return
        }
        if (!root.chat) root.prepare()
        if (!root.chat) return
        root._taken(item)
        if (attach) root.chat.attachFile(attach)
        if (DesktopControl.refuseIfAgentInput(Translation.tr("a message to Muse in the speech bubble"))) return
        root.chat.sendFromBubble(said, root.skipContext ? { noActivity: true } : {}, said)
    }
    // What the last plain command did, said out loud by Voice (deliver).
    property string lastQuickText: ""
    function _quickDone(item, said, did) {
        root.lastQuickText = did.text
        // A question or a refusal (did.plain: "Which one: …?") isn't "Done".
        const line = did.plain ? did.text : Translation.tr("Done: %1").arg(did.text)
        if (!root.chat) root.prepare()
        const chat = root.chat
        if (!chat) {
            root.speaking = { id: "", kind: "quick", text: line }
            return
        }
        if (!root.isAsk(item)) root._taken(item)
        chat.addMessage(said, "user")
        chat.addMessage(line, "assistant")
        const ids = chat.messageIDs
        const answer = chat.messageByID[ids[ids.length - 1]]
        const asked = chat.messageByID[ids[ids.length - 2]]
        if (asked) {
            asked.offSession = true
            asked.quick = true
        }
        if (answer) {
            answer.offSession = true
            answer.quick = true
            answer.quickUndo = did.undo ?? null
        }
        chat.lastActivity = Date.now()
    }
    // A routine it offered: "Yes, do it" turns it on.
    function accept(from) {
        const item = from ?? root.speaking
        if (!item?.accept) return
        if (root.speaking === item) root.speaking = null
        root.answer(item.id, "replied")
    }
    // A button of a reaction: open the file, show it in its folder, or ask
    // Muse about it (in the bubble, the file attached).
    // `from`: a small bubble's (Initiative.stack); "ask" opens it in the
    // bubble first, the others act from where it is.
    function act(a, from) {
        const item = from ?? root.speaking
        if (!a || !item) return
        // The meeting companion's (Meeting.qml): Add tasks, Save as note and
        // Copy leave the record where it is (the others are a click away).
        if (a.do === "meeting") {
            if (!["tasks", "note", "copy"].includes(a.what)) {
                root._taken(item)
                if (root.speaking === item) root.speaking = null
            }
            Meeting.act(a)
            return
        }
        if (a.do === "ask") {
            if (item !== root.speaking) root.open(item)
            root.reply(a.text, a.attach ?? "")
            return
        }
        // A link of the news: opened in the browser, the bubble left as it
        // is (the others to open too).
        if (a.do === "link") {
            const url = String(a.url ?? "")
            if (/^https?:\/\//.test(url)) AppLaunch.openUrl(url) // the browser brought to the front too
            root._taken(item)
            return
        }
        // What needs no thinking, done here at once: no Muse run.
        if (!root._direct(a)) {
            const path = String(a.path ?? "")
            if (!path.startsWith("/")) return
            if (a.do === "open") Quickshell.execDetached(["xdg-open", path])
            else if (a.do === "reveal") root._reveal(path)
            else if (a.do === "extract") {
                extractor.command = ["nixbook-desktop-mcp", "extract", path]
                extractor.running = true
            } else return
        }
        root._taken(item)
        if (root.speaking === item) root.speaking = null
    }
    // A button that does what it says, by the shell (the user's own click:
    // not an agent, so not subject to the agents' pause). False: not one.
    function _direct(a) {
        if (a.do === "setup") {
            // The usual start: its layout, then the apps missing.
            if (a.layout) WindowLayouts.restore(String(a.layout))
            for (const id of (a.apps ?? []).slice(0, 4)) {
                const entry = DesktopEntries.byId(String(id))
                if (entry) AppLaunch.launchEntry(entry)
            }
        } else if (a.do === "tasks") {
            if (a.what === "tomorrow") {
                const t = new Date()
                const tomorrow = new Date(t.getFullYear(), t.getMonth(), t.getDate() + 1)
                for (const task of Todo.list.filter(x => !x.done && x.due && Todo.deadlineGroup(x) === "today"))
                    Todo.updateTask(task, { due: tomorrow })
            } else GlobalStates.openTasksPanel("")
        } else if (a.do === "journal") {
            Autonomy.openJournal()
        } else if (a.do === "tasks_list") {
            MuseTasks.openList()
        } else if (a.do === "settings") {
            GlobalStates.settingsPage = String(a.page ?? "")
            GlobalStates.settingsOpen = true
        } else if (a.do === "forget") {
            if (/^[0-9a-f]{1,16}$/.test(a.note ?? "")) DesktopHelper.run(["memory", "forget", a.note])
        } else if (a.do === "log") {
            const unit = String(a.unit ?? "")
            if (!/^[\w@:.\\-]{1,200}$/.test(unit)) return true
            AppLaunch.spawnInTerminal(["journalctl", a.system ? "-u" : "--user-unit", unit, "-e", "-n", "300"])
        } else return false
        return true
    }
    function _reveal(path) {
        // The file manager with the file selected, else its folder.
        const uri = "file://" + path.split("/").map(encodeURIComponent).join("/")
        Quickshell.execDetached(["bash", "-c", 'dbus-send --session --print-reply --dest=org.freedesktop.FileManager1 '
            + '/org/freedesktop/FileManager1 org.freedesktop.FileManager1.ShowItems array:string:"$1" string:"" >/dev/null 2>&1 '
            + '|| xdg-open "$(dirname "$2")"', "reveal", uri, path])
    }
    // Extracted: shown in the file manager; failed: said.
    Process {
        id: extractor
        stdout: StdioCollector { id: extracted }
        stderr: StdioCollector { id: extractError }
        onExited: (code, status) => {
            const where = extracted.text.trim()
            if (code === 0 && where.startsWith("/")) root._reveal(where)
            else Quickshell.execDetached(["notify-send", "-a", "Muse", "Muse", extractError.text.trim() || Translation.tr("Couldn't extract it")])
        }
    }
    // The conversation (or what it said) in the side panel, for more room.
    function expand() {
        const item = root.speaking
        if (!root.chat && item) {
            const thread = root.isAsk(item) ? Ai.askThread() : Ai.agentThread()
            if (!root.isAsk(item))
                thread.addMessage(item.chat || item.text, "assistant", true, root._hint(item))
            root.chat = thread
        }
        // The same conversation and the same agent session, now on the side
        // panel's command line (Ai.agentScript): started again with --resume
        // on the panel's next message (or at once, the panel prewarming it),
        // nothing replayed.
        if (root.chat) {
            root.chat.surface = "chat"
            Ai.selectChat(root.chat)
        }
        root._taken(item)
        root.speaking = null
        root.chat = null
        root.typing = false
        GlobalStates.sidebarLeftOpen = true
        GlobalStates.aiChatRequested()
    }
    // The conversation put away, to the bar's bubble; brought back.
    function park() {
        if (!root.conversing) return
        root.parked = { item: root.speaking, chat: root.chat, unread: false }
        root.speaking = null
        root.chat = null
        root.typing = false
    }
    function resume() {
        const p = root.parked
        if (!p) return
        root._aside()
        root.parked = null
        root.chat = p.chat
        root.speaking = p.item ?? { id: "", kind: "done", text: "" }
    }
    // Whether the bubble holds this chat, now or put away.
    function holds(c) {
        return c !== null && (root.chat === c || root.parked?.chat === c)
    }
    // Muse answered in a conversation of the bubble: one put away comes
    // back to say it (not while the user is busy: the bar's bubble then).
    function chatAnswered(c) {
        if (root.parked?.chat !== c) return
        if (!root.speaking && !root.busy()) root.resume()
        else if (!root.parked.unread) root.parked = Object.assign({}, root.parked, { unread: true })
    }
    // A chat of the side panel answered while it is closed: said in the
    // bubble, to answer there. False when the bubble is taken.
    function chatDone(c) {
        if (root.typing || (root.speaking && root.chat?.responding)) return false
        root._aside()
        root.chat = c
        root.speaking = { id: "", kind: "done", text: "", title: Ai.chats.length > 1 ? c.title : "" }
        return true
    }
    // What the bubble shows now goes aside for something new: a
    // conversation put away, a word to the bar.
    function _aside() {
        const before = root.speaking
        if (root.conversing) root.park()
        else if (before) {
            if (root.chat && root.chat.fromAgent && !root.chat.responding) root.chat.clearMessages()
            if (before.id) root.pending = [...root.pending.filter(p => p.id !== before.id), before]
            // Still waiting for an answer, or not read: a small bubble, not
            // out of sight.
            if (root.waits(before) || !root._read[before.id]) root._stackPush(before)
        }
        const left = root.chat
        root.speaking = null
        root.chat = null
        root.typing = false
        if (left && !left.fromAgent && !root.holds(left)) Ai.dropIfEmpty(left)
    }
    function _notify(item) {
        root._aside()
        root.speaking = item
    }
    // Something new to say: the bubble when free, else a small bubble under
    // it (never over what the user is reading, writing or talking about).
    function _say(item) {
        if (root.speaking && item?.id) {
            if (!root.pending.some(p => p.id === item.id)) root.pending = [...root.pending, item]
            root._stackPush(item)
        } else if (root.typing) root.pending = [...root.pending, item]
        else root._notify(item)
    }
    // Its speech answered without a reply: later, never, or "wait" (no
    // answer: to the bar's bubble). A conversation is put away instead.
    function hush(outcome) {
        const item = root.speaking
        if (!item) return
        if (root.conversing) {
            root.park()
            return
        }
        root._aside()
        if (outcome !== "wait" && item.id) root.answer(item.id, outcome)
    }

    // The conversation it opened goes on: worth more than a one-word reply.
    property var _opened: null
    function engaged() {
        if (root._opened && Date.now() - root._opened.time < 1800000)
            DesktopHelper.run(["initiative", "answer", root._opened.id, "engaged"])
    }
    // The instant triage's "direct" verdict (Reactor.qml): what it says, said
    // at once by plain code, no model and no batch. Out loud when the user
    // isn't busy, else a quiet word for the next pause. False: not said
    // (the initiative off, or nothing to say): the model's path then.
    function direct(ev, text, verdict) {
        const said = String(text ?? "").trim()
        if (!root.enabled || said.length === 0) return false
        if (!ev || !root._wants(ev)) return false
        const t = Date.now()
        const item = { id: Qt.md5(`${said}|${t}`).slice(0, 12), kind: "direct", level: "notify", text: said.slice(0, 400),
                       app: String(ev?.app ?? ""), title: "Muse", time: t / 1000, expires: t / 1000 + 15 * 60,
                       why: String(verdict?.why ?? "") }
        root._local(item)
        if (root.busy()) {
            item.level = "badge"
            root.pending = [...root.pending, item]
            root._feed(item)
        } else root._say(item)
        root.log = [...root.log, { time: t / 1000, event: ev?.event ?? "", action: "direct", said: item.text, why: item.why }].slice(-30)
        return true
    }
    // The meeting companion's words (Meeting.qml): the offer to take notes
    // of a call, its record, the follow-up draft; made here (no
    // nixbook-desktop-mcp), whether or not the initiative is on: the user
    // started the call's notes, or will say yes to them.
    function meetingWord(w) {
        const t = Date.now()
        const item = Object.assign({ id: Qt.md5(`meeting|${w.text}|${t}`).slice(0, 12), level: "notify", title: "Muse",
                                     time: t / 1000, expires: t / 1000 + (w.offer ? 15 * 60 : 6 * 3600) }, w)
        item.text = String(item.text ?? "").slice(0, 4000)
        root._local(item)
        root._say(item)
    }
    // The day's line about what Muse did yesterday (Autonomy.daySummary):
    // a quiet word, the journal one click away.
    function journalLine(text) {
        if (!root.enabled) return
        const t = Date.now()
        const item = { id: Qt.md5(`journal|${text}|${t}`).slice(0, 12), kind: "journal", level: "badge", title: "Muse",
                       text: String(text).slice(0, 400), time: t / 1000, expires: t / 1000 + 6 * 3600,
                       actions: [{ label: Translation.tr("What Muse did"), do: "journal" }] }
        root._local(item)
        root.pending = [...root.pending, item]
        root._feed(item)
    }
    // Words made here (the triage's, the journal's line), not by
    // nixbook-desktop-mcp: kept across its rewrites of initiative.json, and
    // their answers not sent to it (it doesn't know them).
    property var _localItems: []
    function _local(item) {
        const t = Date.now() / 1000
        root._localItems = [...root._localItems.filter(p => (p.expires ?? 0) > t), item].slice(-20)
    }
    // What the shell offers before being asked (ContextTriggers.qml, through
    // the Reactor): `initiative consider` words it as an offer of ONE order
    // (item.offer {say, order}), within the day's budget and quiet rules.
    readonly property var triggerKinds: Reactor.triggerEvents
    property var _offerTags: ({})
    function tagOf(item) {
        return item?.trigger ?? root._offerTags[item?.id ?? ""] ?? null
    }
    // Yes: the order goes to the bubble's session (Muse's agent does it there).
    function takeOffer(from) {
        const item = from ?? root.speaking
        const order = String(item?.offer?.order ?? "").trim()
        if (!item || order.length === 0) return
        root.unstack(item)
        root.markRead(item)
        if (item.id) root.answer(item.id, "replied")
        if (root.speaking === item) root.speaking = null
        const shown = order.split("\n")[0]
        QuickAi.command(order, "offer", shown.length > 140 ? shown.slice(0, 139) + "…" : shown)
    }
    // Never for this: a preference in the one memory (never offered again),
    // and the trigger itself quiet for 30 days.
    function neverOffer(from) {
        const item = from ?? root.speaking
        if (!item) return
        const tag = root.tagOf(item) ?? { kind: String(item.app ?? "offer"), key: "", app: "" }
        ContextTriggers.mute(tag.kind, tag.key ?? "", 30)
        const about = ContextTriggers.describe(tag)
        DesktopHelper.run(["prefs", "add", JSON.stringify({ text: `Doesn't want Muse to offer help ${about}.`,
            keys: [tag.kind.replace(/_/g, " ")], app: tag.app ?? "", signature: `trigger:${tag.kind}:${tag.key ?? ""}`,
            source: "initiative" })])
        root.unstack(item)
        root.markRead(item)
        if (root.speaking === item) {
            root._aside()
            root.pending = root.pending.filter(p => p.id !== item.id)
        }
        if (item.id) root.answer(item.id, "never")
    }
    function answer(id, outcome) {
        if (!/^[0-9a-f]{1,16}$/.test(id ?? "")) return
        root.pending = root.pending.filter(p => p.id !== id)
        root.stack = root.stack.filter(p => p.id !== id)
        if (root._localItems.some(p => p.id === id)) {
            root._localItems = root._localItems.filter(p => p.id !== id)
            return
        }
        DesktopHelper.run(["initiative", "answer", id, outcome])
    }

    // What "Don't tell me this" silenced (initiative.json's muted): a
    // notification's kind (notice:discord|alesio), an app's of a kind, a kind.
    property var muted: []
    // In words, for Settings.
    function mutedLabel(key) {
        const k = String(key ?? "")
        const i = k.indexOf(":")
        const kind = i < 0 ? k : k.slice(0, i)
        const what = i < 0 ? "" : k.slice(i + 1)
        if (kind === "notice" && what.includes("|")) {
            const bar = what.indexOf("|")
            return Translation.tr("Notifications like “%1” from %2").arg(what.slice(bar + 1)).arg(what.slice(0, bar))
        }
        if (kind === "notice") return what ? Translation.tr("Every notification from %1").arg(what) : Translation.tr("Every notification")
        return what ? Translation.tr("%1 about %2").arg(kind).arg(what) : Translation.tr("Every %1").arg(kind)
    }
    function unmute(key) {
        DesktopHelper.run(["initiative", "unmute", String(key)])
    }

    FileView {
        id: stateFile
        path: root.statePath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const data = JSON.parse(stateFile.text())
                const t = Date.now() / 1000
                const theirs = data.pending ?? []
                root.pending = [...theirs, ...root._localItems.filter(p => (p.expires ?? 0) > t && !theirs.some(q => q.id === p.id))]
                root.log = data.log ?? []
                root.watches = data.watches ?? []
                root.muted = data.muted ?? []
                // A word written by something else (the memory pass, a
                // routine's report, a watch), or waiting since before the
                // shell started: a small bubble too, unless already read.
                const ids = {}
                for (const p of root.pending) ids[p.id] = true
                root._known = ids
                root._loadRead()
                root._feedUnread()
            } catch (e) {
                root.pending = []
                root.log = []
            }
        }
    }

    // What the user does with their notifications, sent every few minutes:
    // the apps they act on, the ones they dismiss.
    property var _seen: ({})
    function _count(app, what) {
        if (!root.enabled || !app) return
        const c = root._seen[app] ?? { acted: 0, dismissed: 0 }
        c[what] += 1
        root._seen = Object.assign({}, root._seen, { [app]: c })
        if (!seenTimer.running) seenTimer.start()
    }
    Connections {
        target: Notifications
        function onActed(app) { root._count(app, "acted") }
        function onDismissed(app) { root._count(app, "dismissed") }
    }
    Timer {
        id: seenTimer
        interval: 300000
        onTriggered: {
            const seen = root._seen
            root._seen = {}
            if (root.enabled)
                DesktopHelper.run(["initiative", "notices", JSON.stringify(seen)])
        }
    }

    // What happens (notifications, what the user just did) comes from the
    // one event reactor (services/Reactor.qml), after Full AI mode, which
    // takes it first while it is on: one model decision per event.
    Component.onCompleted: Reactor.register("initiative", 10, {
        wants: ev => root._wants(ev),
        take: ev => root._take(ev),
    })
    function _wants(ev) {
        if (!root.enabled) return false
        if (ev.event === "notification")
            // Not while away (locked) or on Do Not Disturb: nobody to tell,
            // and what comes then isn't read by the model either.
            return root.readNotifications && !GlobalStates.screenLocked && !Notifications.silent
        // What the shell offers (ContextTriggers.qml): an order for Muse,
        // so only with online models, never about what an agent did.
        if (root.triggerKinds.includes(ev.event)) return root.online && !DesktopControl.active
        // What the user just did, to lend a hand with (reactions): not what
        // an agent did (its downloads, its screenshots).
        return root.reactions && root.reactTo.includes(ev.event) && !!ev.path && !DesktopControl.active
    }
    function _take(ev) {
        if (ev.event === "notification") {
            root._batch = [...root._batch, { app: ev.app, summary: ev.title, body: ev.body, urgency: ev.urgency }].slice(-12)
            if (!batchTimer.running) batchTimer.start()
            return
        }
        if (root.triggerKinds.includes(ev.event)) {
            root.consider(Object.assign({}, ev, { lang: ConfigAssistant.uiLang() }),
                          { kind: ev.event, key: String(ev.key ?? ""), app: String(ev.app ?? "") })
            return
        }
        root.consider({ event: "happened", what: ev.event, name: ev.name ?? "", path: ev.path })
    }

    // The conversations, for desktop agents (nixbook-desktop-mcp's
    // conversation and delete_conversations tools): a fresh one in the
    // bubble (once the answer being written is done: an agent clearing the
    // chat it answers in), the bubble put away or shown, the saved ones
    // listed or deleted (never the one open in the bubble).
    property bool freshAfter: false
    onThinkingChanged: if (!root.thinking && root.freshAfter) {
        root.freshAfter = false
        root.fresh()
    }
    IpcHandler {
        target: "conversation"
        function clear(): string {
            if (root.thinking) {
                root.freshAfter = true
                return "ok: a new conversation once this answer is done (this one stays in the history)"
            }
            root.fresh()
            return "ok: a new conversation (the last one stays in the history)"
        }
        function hide(): string {
            if (!root.speaking) return "ok: the bubble is already away"
            root.hush("wait")
            return "ok: the bubble put away (the conversation comes back with Mod+C)"
        }
        function show(): string {
            root.quiet = false
            root.summon()
            return "ok: the bubble is up"
        }
        // JSON: [{id, title, created, updated, pinned, open}], newest first.
        function history(count: int): string {
            const open = root.chat?.chatId ?? ""
            return JSON.stringify(Ai.history.slice(0, Math.max(1, Math.min(200, count || 20))).map(c => ({
                id: c.id, title: c.title, created: c.created, updated: c.updated, pinned: c.pinned === true,
                open: c.id === open })))
        }
        // Ids separated by commas or spaces, or "all" (not the pinned ones).
        function remove(ids: string): string {
            const open = root.chat?.chatId ?? ""
            let wanted = String(ids ?? "").trim() === "all"
                ? Ai.history.filter(c => !c.pinned).map(c => c.id)
                : String(ids ?? "").split(/[\s,]+/).filter(s => s)
            const known = new Set(Ai.history.map(c => c.id))
            const kept = wanted.filter(id => id === open)
            wanted = wanted.filter(id => id !== open && known.has(id))
            Ai.deleteChats(wanted)
            return JSON.stringify({ deleted: wanted.length, keptOpen: kept.length, left: Ai.history.length })
        }
    }

    // `nixbook-shell ipc call muse toggle` (Mod+C): its bubble, to ask, or
    // put away; `ask`: always called up.
    IpcHandler {
        target: "muse"
        function ask(): void {
            root.summon()
        }
        function toggle(): void {
            root.toggle()
        }
    }

    // Notifications (from the Reactor, _take), in batches: a burst is read once.
    Timer {
        id: batchTimer
        // 20 s: a burst still read once (the urgent ones are said at once by
        // the triage, services/Reactor.qml).
        interval: 20000
        onTriggered: {
            const items = root._batch
            root._batch = []
            // The switch may have gone off while the batch waited.
            if (items.length > 0 && root.enabled && root.readNotifications)
                root.consider({ event: "notifications", read: true, items: items,
                                focused: ToplevelManager.activeToplevel?.appId ?? "", next: root._nextEvent() })
        }
    }

    // Back after a while: the screens come on again, or the session unlocks.
    Connections {
        target: Idle
        function onScreensOffChanged() {
            if (Idle.screensOff) root._awaySince = Date.now()
            else if (root._awaySince > 0 && !GlobalStates.screenLocked) {
                root.back((Date.now() - root._awaySince) / 60000)
                root._awaySince = 0
                root._activeSince = Date.now()
            }
        }
    }
    Connections {
        target: GlobalStates
        function onScreenLockedChanged() {
            if (GlobalStates.screenLocked) {
                if (root._awaySince === 0) root._awaySince = Date.now()
            } else if (root._awaySince > 0) {
                root.back((Date.now() - root._awaySince) / 60000)
                root._awaySince = 0
                root._activeSince = Date.now()
            }
        }
    }

    // A new app in front: once per app, every few minutes at most.
    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() {
            const app = ToplevelManager.activeToplevel?.appId ?? ""
            if (!app || app === root._lastApp || Date.now() - root._lastFocus < 180000) return
            root._lastApp = app
            root._lastFocus = Date.now()
            root.consider({ event: "focus", app: app })
        }
    }

    // Now and then, at random, a chance for a light word.
    Timer {
        id: momentTimer
        // Asks every few minutes; when a light word is due (40 to 120 minutes
        // apart, at random) is kept by nixbook-desktop-mcp, so a shell
        // restart doesn't start the wait over.
        running: root.enabled
        interval: 5 * 60000
        repeat: true
        onTriggered: {
            if (Idle.screensOff || GlobalStates.screenLocked) return
            root.consider({ event: "moment", curious: root.curious, news: root.news,
                            location: root.news ? root.newsLocation() : "", app: ToplevelManager.activeToplevel?.appId ?? "",
                        title: root.curious ? (ToplevelManager.activeToplevel?.title ?? "") : "",
                            activeMinutes: Math.round((Date.now() - root._activeSince) / 60000),
                            tasksDue: Todo.dueTodayCount, weatherCode: Weather.data?.wCode ?? 0,
                            weather: Weather.data?.description ?? "" })
        }
    }
    // The first start of the day counts as coming back.
    Timer {
        interval: 20000
        running: root.enabled
        onTriggered: root.back(0)
    }
    Timer {
        interval: 60000
        running: root.live.length > 0 || root.stack.length > 0 || root._arrivals.length > 0
        repeat: true
        onTriggered: {
            root.now = Date.now()
            root._flush() // the user no longer busy
        }
    }
}
