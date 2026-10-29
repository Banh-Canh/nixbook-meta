pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

/**
 * The meeting companion (ai.meeting): Muse listens to a call and helps,
 * live. `nixbook-meeting run` (scripts/meeting.py) streams what the user
 * hears (the default output's monitor) and, with ai.meeting.includeMic,
 * their microphone ("You") to Meta's Muse Voice Transcribe; its caption
 * lines show in a small floating window (modules/ii/meeting/
 * MeetingCaptions.qml), translated into the user's language when spoken in
 * another (ai.meeting.translate); running notes every
 * ai.meeting.notesEveryS seconds (the small model); when it stops, the
 * record (the big model, ai.routing.meeting): the summary, decisions,
 * action items and a follow-up draft, said in Muse's bubble with Add tasks /
 * Save as note / Draft follow-up.
 *
 * Never silently: started by the user (a button, `meeting start`, "take
 * notes" in the bubble or by voice) or from an offer they accept (a
 * calendar event with a link starting, a call app taking the microphone),
 * and shown the whole time (the caption window, the bar's red icon) with
 * Stop. It stops by itself when the call app lets the microphone go, or
 * five minutes after the event's end. Nothing with AI off or local only.
 * Listening isn't acting: the agents' pause doesn't stop it, and agents
 * can't start it (`meeting` is in desktop-mcp's shellIpcDenyTargets);
 * Do Not Disturb only keeps the offers away.
 */
Singleton {
    id: root
    function load() {
        pruner.running = true
    }

    readonly property var settings: Config.options?.ai?.meeting ?? ({})
    readonly property bool enabled: (root.settings.enable ?? true) && (Config.options?.policies?.ai ?? 1) === 1
    // Captions need Meta's realtime transcriber (the provider's key).
    readonly property bool ready: root.enabled && ModelProvider.kind === "meta" && ModelProvider.keySaved
    readonly property bool offers: root.ready && (root.settings.offer ?? true)

    // Listening (the process up and not ending yet), then writing the record.
    property bool active: false
    property bool ending: false
    readonly property bool running: runner.running
    property string meetingId: ""
    property string title: ""
    property real startedAt: 0
    // Why it was started: the event (its end, ms) or the call app holding
    // the microphone (its name): what ends it by itself.
    property real eventEnd: 0
    property string callApp: ""
    property bool micOn: false
    property bool translateOn: false
    // The last caption lines {i, who, text, tr}, and what is being said.
    property var lines: []
    property string partialThem: ""
    property string partialYou: ""
    property var notes: null
    property string status: ""
    property string error: ""
    // The record of the last call, shown in its window until closed.
    property var summary: null
    property string summaryTitle: ""
    // The caption window: its notes panel open, kept after the call for the
    // record, the screen it shows on.
    property bool panelOpen: false
    property bool keepShown: false
    readonly property bool shown: root.active || root.ending || root.keepShown
    property string screenName: ""
    // The first call ever: tell the others (the window's line, "Got it").
    readonly property bool consentNeeded: !(Persistent.states?.ai?.meetingConsentShown ?? false)
    function consentSeen() {
        Persistent.states.ai.meetingConsentShown = true
    }
    property real now: Date.now()
    readonly property string elapsed: {
        if (root.startedAt <= 0) return ""
        const s = Math.max(0, Math.floor((root.now - root.startedAt) / 1000))
        const m = Math.floor(s / 60)
        return m >= 60 ? `${Math.floor(m / 60)}:${String(m % 60).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`
            : `${m}:${String(s % 60).padStart(2, "0")}`
    }

    // Starts listening. `opts`: {title, end (ms), app, from}. "" when it
    // started, else why not (said by the voice command, the IPC).
    function start(opts) {
        const o = opts ?? {}
        if (root.running) return root.ending ? Translation.tr("Still writing the last call's summary") : ""
        if ((Config.options?.policies?.ai ?? 1) !== 1) return Translation.tr("AI is off or local only")
        if (!(root.settings.enable ?? true)) return Translation.tr("The meeting companion is off (Settings > Desktop agents)")
        if (!root.ready) return Translation.tr("Live captions need Meta as the model provider, with its key")
        const ev = root._eventNow()
        root.title = String(o.title || ev?.summary || "").slice(0, 200)
        root.eventEnd = Number(o.end || ev?.end?.getTime?.() || 0)
        root.callApp = String(o.app ?? "")
        root.micOn = root.settings.includeMic ?? true
        root.translateOn = root.settings.translate ?? true
        root.lines = []
        root.partialThem = ""
        root.partialYou = ""
        root.notes = null
        root.summary = null
        root.error = ""
        root.status = Translation.tr("Connecting…")
        root.meetingId = ""
        root.panelOpen = false
        root.keepShown = false
        root.screenName = WM.focusedMonitor?.name ?? ""
        root.startedAt = Date.now()
        root.now = Date.now()
        root._missed = 0
        const args = ["--title", root.title, "--lang", Voice.languages, "--notes-every", String(root.settings.notesEveryS ?? 75),
                      "--keep-days", String(root.settings.keepDays ?? 30)]
        if (root.micOn) args.push("--mic")
        if (root.translateOn) args.push("--translate", ConfigAssistant.uiLang())
        if (root.callApp) args.push("--app", root.callApp)
        runner.command = ["bash", "-c", 'exec setpriv --pdeathsig TERM nixbook-model-provider run nixbook-meeting run "$@"', "_", ...args]
        root.active = true
        runner.running = true
        return ""
    }
    // Stops listening: the record is written (the caption window says so).
    function stop() {
        if (!root.running || root.ending) return
        root.active = false
        root.ending = true
        root.status = Translation.tr("Writing the summary…")
        root.partialThem = ""
        root.partialYou = ""
        runner.write("stop\n")
    }
    // Stops without a record (the transcript stays, kept ai.meeting.keepDays).
    function cancel() {
        if (!root.running) return
        root.active = false
        runner.write("cancel\n")
    }
    function toggleMic() {
        if (!root.active) return
        root.micOn = !root.micOn
        runner.write(root.micOn ? "mic on\n" : "mic off\n")
    }
    // Locked: the user has left the computer, so their microphone ("You")
    // is closed until they are back; the call's own sound goes on being
    // captioned (the companion was started by them, and is still shown).
    property bool _micOffWhileLocked: false
    Connections {
        target: GlobalStates
        function onScreenLockedChanged() {
            if (GlobalStates.screenLocked && root.active && root.micOn) {
                root._micOffWhileLocked = true
                root.toggleMic()
            } else if (!GlobalStates.screenLocked && root._micOffWhileLocked) {
                root._micOffWhileLocked = false
                if (root.active && !root.micOn) root.toggleMic()
            }
        }
    }
    function toggleTranslate() {
        if (!root.active) return
        root.translateOn = !root.translateOn
        runner.write(root.translateOn ? `translate ${ConfigAssistant.uiLang()}\n` : "translate off\n")
    }
    function close() {
        root.keepShown = false
    }

    // The record as text, `style`: "note" (the Notes app: its title on the
    // first line, as Keep takes it, then the date), "panel" (Markdown, bold
    // labels: the window, whose header has the title), "plain" (the bubble).
    function recordText(s, title, style) {
        if (!s) return ""
        const out = []
        const label = (t) => style === "panel" ? `**${t}**` : t
        if (style === "note") out.push(`${title || Translation.tr("Call notes")}\n` + Qt.formatDateTime(new Date(root.startedAt || Date.now()), "yyyy-MM-dd hh:mm"))
        if (s.summary) out.push(s.summary)
        if ((s.decisions ?? []).length > 0)
            out.push(`${label(Translation.tr("Decisions"))}\n` + s.decisions.map(d => `- ${d}`).join("\n"))
        if ((s.actions ?? []).length > 0)
            out.push(`${label(Translation.tr("Action items"))}\n` + s.actions.map(a => `- ${root.actionText(a)}`).join("\n"))
        if (style !== "plain" && (s.questions ?? []).length > 0)
            out.push(`${label(Translation.tr("Open questions"))}\n` + s.questions.map(q => `- ${q}`).join("\n"))
        return out.join("\n\n")
    }
    function actionText(a) {
        return `${a.what}${a.owner ? ` (${a.owner})` : ""}${a.due ? `, ${a.due}` : ""}`
    }

    // A button of the bubble's words (Initiative.act → here).
    function act(a) {
        const s = root.summary
        if (a.what === "start") {
            const why = root.start({ title: a.title ?? "", end: a.end ?? 0, app: a.app ?? "", from: "offer" })
            if (why) Quickshell.execDetached(["notify-send", "-a", "Muse", "Muse", why])
        } else if (a.what === "tasks" && s) {
            // The user's click: their tasks, the call named in each.
            const from = Translation.tr("From the call: %1").arg(root.summaryTitle || Translation.tr("untitled"))
            for (const item of (s.actions ?? []).slice(0, 15))
                Todo.addTask(root.actionText(item), { notes: from })
            Quickshell.execDetached(["notify-send", "-a", "Muse", "Muse",
                Translation.tr("%1 tasks added").arg((s.actions ?? []).length)])
        } else if (a.what === "note" && s) {
            const id = Notes.addNote(root.recordText(s, root.summaryTitle, "note"))
            GlobalStates.openNotesApp(id)
        } else if (a.what === "followup" && s) {
            const draft = [s.followup?.subject ? `${Translation.tr("Subject")}: ${s.followup.subject}` : "", s.followup?.body ?? ""]
                .filter(x => x).join("\n\n")
            // Sending is Muse's, through its usual approval (a risky step):
            // nothing goes out from here.
            Initiative.meetingWord({ kind: "meeting", text: draft || Translation.tr("No follow-up was drafted."),
                actions: draft ? [{ label: Translation.tr("Copy"), do: "meeting", what: "copy", draft: draft },
                    { label: Translation.tr("Send it with Muse"), do: "ask",
                      text: `Send this follow-up of the call "${root.summaryTitle}" to the people who were on it (ask me who and where if you can't tell). Show it to me before it goes:\n\n${draft}` }] : [] })
        } else if (a.what === "copy") {
            Quickshell.clipboardText = String(a.draft ?? "")
        } else if (a.what === "open") {
            root.keepShown = true
            root.panelOpen = true
        }
    }

    // -- Offers: a meeting starting, a call app taking the microphone --------
    // Offered once each (an event at its start, a call while the app holds
    // the microphone), never during Do Not Disturb, never twice in 10 min.
    property var _offered: ({})
    property string _offeredCall: ""
    property real _lastOffer: 0
    function _link(e) {
        if (e.meetingUrl) return e.meetingUrl
        const m = /https?:\/\/[^\s<>"]+/i.exec(`${e.location ?? ""} ${e.description ?? ""}`)
        return m ? m[0] : ""
    }
    // The event going on now (or starting within a minute) with a link.
    function _eventNow() {
        const t = new Date()
        for (const e of CalendarEvents.upcoming(6, t, true)) {
            if (e.start.getTime() - t.getTime() > 60000) continue
            if (root._link(e).length > 0) return e
        }
        return null
    }
    function _offer(key, text, action) {
        if (Notifications.silent || GlobalStates.screenLocked) return
        if (Date.now() - root._lastOffer < 10 * 60000 || root._offered[key]) return
        root._offered = Object.assign({}, root._offered, { [key]: Date.now() })
        root._lastOffer = Date.now()
        Initiative.meetingWord({ kind: "meeting", offer: true, text: text,
            actions: [Object.assign({ label: Translation.tr("Take notes"), do: "meeting", what: "start" }, action)] })
    }
    function _checkCalendar() {
        const t = new Date()
        for (const e of CalendarEvents.upcoming(6, t, true)) {
            const since = t.getTime() - e.start.getTime()
            if (since < -60000 || since > 10 * 60000 || root._link(e).length === 0) continue
            root._offer(`${e.id}@${e.start.getTime()}`,
                Translation.tr("“%1” is starting. Want me to take notes, with live captions?").arg(e.summary),
                { title: e.summary, end: e.end.getTime() })
            return
        }
    }
    // The apps of calls, by what PipeWire says of a microphone stream; a
    // browser counts while one of its windows is a meeting.
    readonly property var callApps: /zoom|teams|discord|vesktop|webcord|slack|skype|jitsi|signal|telegram|whatsapp|element|webex/i
    readonly property var browsers: /firefox|zen|chrom|brave|vivaldi|librewolf|floorp|edge|epiphany/i
    readonly property var meetingTitle: /\bmeet\b|google meet|teams|zoom|jitsi|whereby|webex|huddle/i
    function _callIn(outputs) {
        for (const o of outputs) {
            const p = o?.properties ?? {}
            const names = [p["application.process.binary"], p["application.name"], p["application.id"]].filter(x => x).join(" ")
            if (/ffmpeg|whisper|nixbook|lavf/i.test(names)) continue
            const app = String(p["application.name"] ?? p["application.process.binary"] ?? "")
            if (root.callApps.test(names)) return app
            if (root.browsers.test(names) && ToplevelManager.toplevels.values.some(t => root.meetingTitle.test(t.title ?? "")))
                return app
        }
        return ""
    }
    property int _missed: 0
    // A call app holding the microphone now ("" when none), the companion
    // listening or not: Full AI mode's always-open microphone leaves what the
    // user says in a call to the call (services/Addressee.qml).
    property string callNow: ""
    readonly property bool inCall: root.running || root.callNow !== ""
    function _sawOutputs(outputs) {
        const app = root._callIn(outputs)
        root.callNow = app
        if (root.running) {
            // Listening because of a call: over once its app has let the
            // microphone go for 20 s.
            if (root.active && root.callApp) {
                root._missed = app ? 0 : root._missed + 1
                if (root._missed >= 2) root.stop()
            }
            return
        }
        if (!app) {
            root._offeredCall = ""
            return
        }
        if (app === root._offeredCall || !root.offers) return
        root._offeredCall = app
        const ev = root._eventNow()
        root._offer(`call:${app}:${Math.floor(Date.now() / 3600000)}`,
            ev ? Translation.tr("“%1” is on in %2. Want me to take notes, with live captions?").arg(ev.summary).arg(app)
               : Translation.tr("You're on a call in %1. Want me to take notes, with live captions?").arg(app),
            { title: ev?.summary ?? "", end: ev?.end?.getTime?.() ?? 0, app: app })
    }
    Timer {
        // Every 15 s while it could offer, every 10 s while a call it
        // follows goes on; every 5 s in Full AI mode (is the user on a call?).
        interval: root.running ? 10000 : FullAi.active ? 5000 : 15000
        repeat: true
        triggeredOnStart: FullAi.active
        running: (root.offers && !root.running && !GlobalStates.screenLocked && !Idle.screensOff)
            || (root.active && (root.callApp !== "" || root.eventEnd > 0)) || FullAi.active
        onTriggered: {
            if (!root.running && root.offers) root._checkCalendar()
            // The event over (5 min of grace) and no call app holding on.
            if (root.active && root.eventEnd > 0 && Date.now() > root.eventEnd + 5 * 60000 && !root.callApp) {
                root.stop()
                return
            }
            if (!sources.running) sources.running = true
        }
    }
    Process {
        id: sources
        command: ["pactl", "-f", "json", "list", "source-outputs"]
        stdout: StdioCollector { id: sourcesOut }
        onExited: (code) => {
            if (code !== 0) return
            let outputs
            try { outputs = JSON.parse(sourcesOut.text) } catch (e) { return }
            if (Array.isArray(outputs)) root._sawOutputs(outputs)
        }
    }
    Timer {
        // The elapsed time in the window.
        interval: 1000
        repeat: true
        running: root.active
        onTriggered: root.now = Date.now()
    }

    // -- nixbook-meeting ------------------------------------------------------
    Process {
        id: runner
        stdinEnabled: true
        stdout: SplitParser {
            onRead: (line) => {
                let ev
                try { ev = JSON.parse(line) } catch (e) { return }
                switch (ev.type) {
                case "started":
                    root.meetingId = ev.id ?? ""
                    break
                case "ready":
                    root.status = ""
                    break
                case "partial":
                    if (ev.who === "you") root.partialYou = ev.text ?? ""
                    else root.partialThem = ev.text ?? ""
                    break
                case "final": {
                    if (ev.who === "you") root.partialYou = ""
                    else root.partialThem = ""
                    root.lines = [...root.lines, { i: ev.i, who: ev.who, text: ev.text ?? "", tr: "" }].slice(-6)
                    break
                }
                case "translation":
                    root.lines = root.lines.map(l => l.i === ev.i ? Object.assign({}, l, { tr: ev.text ?? "" }) : l)
                    break
                case "notes":
                    root.notes = ev.notes ?? null
                    break
                case "status":
                    root.status = ev.text ?? ""
                    break
                case "summary":
                    // Nothing was said: no record, the window says so.
                    if (ev.summary?.empty) {
                        root.error = Translation.tr("Nothing was heard on the call: no notes to write.")
                        break
                    }
                    root.summary = ev.summary ?? null
                    root.summaryTitle = ev.summary?.title || root.title
                    root._said()
                    break
                case "error":
                    root.error = String(ev.error ?? "")
                    break
                }
            }
        }
        stderr: SplitParser {
            onRead: (line) => {
                if (/nixbook-model-provider:/.test(line)) root.error = line.replace(/^nixbook-model-provider:\s*/, "")
            }
        }
        onExited: (code) => {
            // Stopped before it said anything (no key, AI off, the network).
            if (root.active && !root.error && code !== 0) root.error = Translation.tr("The meeting companion stopped (%1)").arg(code)
            root.active = false
            root.ending = false
            root.status = ""
            root.partialThem = ""
            root.partialYou = ""
            // The record (or why there is none) stays in its window.
            root.keepShown = root.summary !== null || root.error !== ""
            if (root.summary) root.panelOpen = true
        }
    }
    // The record, said in Muse's bubble with its buttons.
    function _said() {
        const s = root.summary
        if (!s || s.empty) return
        Initiative.meetingWord({ kind: "meeting", text: `${Translation.tr("Notes from “%1”").arg(root.summaryTitle || Translation.tr("the call"))}\n\n${root.recordText(s, root.summaryTitle, "plain")}`,
            actions: [
                ...((s.actions ?? []).length > 0 ? [{ label: Translation.tr("Add tasks"), do: "meeting", what: "tasks" }] : []),
                { label: Translation.tr("Save as note"), do: "meeting", what: "note" },
                ...(s.followup?.body ? [{ label: Translation.tr("Draft follow-up"), do: "meeting", what: "followup" }] : [])] })
    }
    Process {
        id: pruner
        command: ["bash", "-c", 'command -v nixbook-meeting >/dev/null && exec nixbook-meeting prune --keep-days "$1"', "_",
            String(Config.options?.ai?.meeting?.keepDays ?? 30)]
    }

    // What an agent may do with the call notes (`meeting` itself is denied
    // to agents: it opens the microphone): close the record's window and its
    // word in the bubble once the call is over; never start nor stop one.
    IpcHandler {
        target: "meetingNotes"
        function close(): string {
            if (root.active || root.ending)
                return "error: still taking notes of the call (the user stops it with Mod+Alt+N)"
            const words = Initiative.putAway(p => p.kind === "meeting" && !p.offer)
            if (!root.keepShown) return words > 0 ? "ok: the call notes put away from the bubble" : "ok: no call notes on screen"
            root.panelOpen = false
            root.close()
            return "ok: the call notes window closed (the notes stay saved: meeting_notes)"
        }
        function status(): string {
            return JSON.stringify({ shown: root.shown, listening: root.active, ending: root.ending,
                record: root.summary !== null, title: root.summaryTitle })
        }
    }
    IpcHandler {
        target: "meeting"
        // Starts listening to the call (TITLE: optional): "" or why not.
        function start(title: string): string {
            return root.start({ title: title, from: "ipc" }) || "listening"
        }
        function stop(): string {
            if (!root.running) return "not listening"
            root.stop()
            return "writing the summary"
        }
        function toggle(): string {
            if (root.active) {
                root.stop()
                return "writing the summary"
            }
            return root.start({ from: "ipc" }) || "listening"
        }
        function mic(): string {
            root.toggleMic()
            return root.micOn ? "mic on" : "mic off"
        }
        function status(): string {
            return JSON.stringify({ enabled: root.enabled, ready: root.ready, active: root.active, ending: root.ending,
                id: root.meetingId, title: root.title, mic: root.micOn, translate: root.translateOn,
                lines: root.lines.length, notes: root.notes, error: root.error })
        }
    }
}
