pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Muse's background tasks (ai.autonomy.tasks): a long multi-step task
 * (finding, comparing, preparing…) run by `nixbook-muse-task` in a user unit
 * of its own, while the user does something else. Each writes its state to
 * $XDG_STATE_HOME/nixbook-shell/tasks/<id>.json ({id, text, status:
 * running|waiting|done|failed|stopped, started, updated, steps, approval?,
 * question?, report?, answer?, sessionId, error?}), read here as it
 * changes: the bar's robot shows a count while some run or wait, the side
 * panel's Muse tab lists them (MuseActivity.qml) with Allow / No for a step
 * waiting for the user's OK, a field to answer its question, Open (its
 * session in the side panel) and Stop. They are started by the bubble's
 * "Do it in the background" chip, or by Muse's background_task tool when
 * the user asks for it. Approving and answering are the user's only: IPC
 * `museTasks` lists, stops and fans out, nothing more (not `tasks`: that
 * is the to-do panel's). An order of several parts can be split up instead
 * (the bubble's "Split it up", Muse's fan_out tool): a plan and its
 * workers, each worker a figure on the bar (figures, WorkerFigure.qml).
 */
Singleton {
    id: root
    // The folder made first (0700), then watched (a folder that doesn't
    // exist yet isn't watched once made).
    function load() {
        Quickshell.execDetached(["mkdir", "-p", "-m", "700", root.dir])
        folderSoon.start()
    }
    property string _folder: ""
    Timer {
        id: folderSoon
        interval: 500
        onTriggered: root._folder = `file://${root.dir}`
    }

    readonly property bool enabled: (Config.options?.ai?.autonomy?.tasks ?? true) && (Config.options?.policies?.ai ?? 1) === 1
    readonly property int maxTasks: Config.options?.ai?.autonomy?.maxTasks ?? 4
    // Plan and fan out (ai.autonomy.fanOut): an order of several parts
    // planned by the big model (Muse Wonder), each part a task of its own
    // (a worker) running at the same time, their results merged into one
    // answer (nixbook-muse-task fanout). A plan is a task file too (kind
    // "plan": {phase planning|working|merging, parts: [{title, model,
    // modelId, needs, worker, status}], plannerModel, mergerModel}); its
    // workers carry {parent, title, part, model, modelId}.
    readonly property bool fanOutEnabled: root.enabled && (Config.options?.ai?.autonomy?.fanOut ?? true)
    readonly property string dir: `${Quickshell.env("XDG_STATE_HOME") || `${Quickshell.env("HOME")}/.local/state`}/nixbook-shell/tasks`
    readonly property string command: "nixbook-muse-task"

    // path -> task (as its file says); `tasks` newest first.
    property var _byPath: ({})
    readonly property var tasks: Object.values(root._byPath).filter(t => t && t.id)
        .sort((a, b) => Number(b.updated ?? b.started ?? 0) - Number(a.updated ?? a.started ?? 0))
    readonly property var byId: {
        const out = {};
        for (const t of root.tasks) out[t.id] = t;
        return out;
    }
    // The tasks with an agent (a plan only waits for its workers): what is
    // counted, against maxTasks too.
    readonly property var agentTasks: root.tasks.filter(t => t.kind !== "plan")
    readonly property var running: root.agentTasks.filter(t => t.status === "running")
    readonly property var waiting: root.agentTasks.filter(t => t.status === "waiting")
    readonly property int activeCount: root.running.length + root.waiting.length
    readonly property bool canStart: root.enabled && root.activeCount < root.maxTasks
    readonly property bool canFanOut: root.fanOutEnabled && root.canStart
    // The Muse tab's list: plans and lone tasks (a plan's workers go under it).
    readonly property var topLevel: root.tasks.filter(t => !t.parent || !root.byId[t.parent])
    function workersOf(plan) {
        const id = typeof plan === "string" ? plan : plan?.id;
        return root.agentTasks.filter(t => t.parent === id).sort((a, b) => Number(a.part ?? 0) - Number(b.part ?? 0));
    }
    function isLive(t) {
        return t?.status === "running" || t?.status === "waiting";
    }

    // -- The workers on the bar ---------------------------------------------
    // Each running task is a little figure (modules/common/widgets/
    // WorkerFigure.qml); a finished one stays a few seconds to cheer or
    // slump; a plan being written (Muse Wonder) or merged is one too. Its
    // state comes from the task file only (written as the agent's activity
    // changes: nothing is polled), the clock below just lets the finished
    // ones go.
    readonly property int lingerSeconds: 10
    property real now: Date.now() / 1000
    Timer {
        interval: 2000
        repeat: true
        running: root._lingering
        onTriggered: root.now = Date.now() / 1000
    }
    readonly property bool _lingering: root.tasks.some(t => !root.isLive(t) && root.now - Number(t.updated ?? 0) < root.lingerSeconds)
    function figureFor(t) {
        if (t.kind === "plan") {
            const merging = t.phase === "merging";
            return { id: t.id, task: t.id, plan: true, state: "think", status: "running",
                     title: merging ? Translation.tr("Merging the results") : Translation.tr("Planning the parts"),
                     doing: String(t.text ?? ""), modelId: String((merging ? t.mergerModel : t.plannerModel) ?? "") };
        }
        return { id: t.id, task: t.id, plan: false, state: root.figureState(t), status: t.status,
                 title: String(t.title || t.text || ""), doing: root.doingText(t), modelId: String(t.modelId ?? "") };
    }
    // id -> figure, and the ids in a stable order (oldest first, a plan's
    // parts in their order): the bar's Repeater keeps its delegates (their
    // animations) across file changes.
    readonly property var figures: {
        const now = root.now;
        const shown = root.tasks.filter(t => t.kind === "plan" ? (t.status === "running" && (t.phase === "planning" || t.phase === "merging"))
            : (root.isLive(t) || now - Number(t.updated ?? 0) < root.lingerSeconds));
        shown.sort((a, b) => Number(a.started ?? 0) - Number(b.started ?? 0) || Number(a.part ?? 0) - Number(b.part ?? 0));
        const out = {};
        const ids = [];
        for (const t of shown) {
            out[t.id] = root.figureFor(t);
            ids.push(t.id);
        }
        return { map: out, ids: ids };
    }
    readonly property var figureIds: root.figures.ids
    function figureOf(id) {
        return root.figures.map[id] ?? null;
    }
    // A plan's part as a figure (its card): its worker's, faint and still
    // while it hasn't started.
    function partFigure(plan, part) {
        const w = part?.worker ? root.byId[part.worker] : null;
        if (w) return root.figureFor(w);
        return { id: "", task: "", plan: false, state: part?.status === "skipped" ? "slump" : "queued", status: part?.status ?? "queued",
                 title: String(part?.title ?? ""), modelId: String(part?.modelId ?? part?.model ?? ""),
                 doing: part?.status === "skipped" ? Translation.tr("Not done: a part it needed failed")
                     : (part?.needs ?? []).length > 0 ? Translation.tr("Waiting for: %1").arg(part.needs.map(n => plan?.parts?.[n]?.title ?? "").filter(s => s).join(", "))
                     : Translation.tr("Waiting for room (at most %1 tasks at once)").arg(root.maxTasks) };
    }
    // cheer (done), slump (failed, stopped), wait (an OK or an answer), type
    // (its answer streams), search (the web), tool (any other tool), think.
    function figureState(t) {
        const s = t?.status;
        if (s === "done") return "cheer";
        if (s === "failed" || s === "stopped") return "slump";
        if (s === "waiting") return "wait";
        const a = t?.activity;
        return a === "typing" ? "type" : a === "searching" ? "search" : a === "tool" ? "tool" : "think";
    }
    function doingText(t) {
        const s = t?.status;
        if (s === "waiting") return t.approval ? Translation.tr("Waiting for your OK: %1").arg(t.approval.summary || String(t.approval.tool ?? "").replace(/_/g, " "))
            : Translation.tr("Waiting for your answer: %1").arg(String(t.question ?? ""));
        if (s === "done") return String(t.report?.summary ?? t.answer ?? Translation.tr("Done")).split("\n")[0];
        if (s === "failed") return String(t.error ?? Translation.tr("Failed"));
        if (s === "stopped") return Translation.tr("Stopped");
        const d = String(t?.doing ?? "");
        return t?.activity === "typing" ? Translation.tr("Writing its answer")
            : t?.activity === "searching" ? (d === "WebFetch" ? Translation.tr("Reading a web page") : Translation.tr("Searching the web"))
            : t?.activity === "tool" ? Translation.tr("Using %1").arg(d.replace(/_/g, " "))
            : Translation.tr("Thinking");
    }
    // A model's short name from the provider's id: muse-spark-1.3 → Spark,
    // muse-wonder-1.0 → Wonder (a custom provider's model: its name).
    function modelLabel(id) {
        const s = String(id ?? "").trim();
        if (s.length === 0) return "";
        const m = /^muse[-_ ]([a-z]+)/i.exec(s);
        const name = m ? m[1] : s.replace(/[-_.:]?\d[\w.]*$/, "");
        return name.length > 0 ? name.charAt(0).toUpperCase() + name.slice(1) : s;
    }
    function modelName(id) {
        const short = root.modelLabel(id);
        return /^muse/i.test(String(id ?? "")) ? `Muse ${short}` : short;
    }

    // -- Splitting an order up ------------------------------------------------
    // How many parts an order seems to have: its clauses joined by commas or
    // "and / then" (English, French, German, Vietnamese), each two words or
    // more. Only a hint for the bubble's chip: the plan decides.
    function partsIn(text) {
        let t = ` ${String(text ?? "").toLowerCase().replace(/[,;\n]+/g, " | ")} `;
        t = t.replace(/\s(?:and then|after that|then|and|also|plus|puis|ensuite|et|aussi|und dann|danach|dann|und|außerdem|sau đó|rồi|và|cũng)(?=\s)/g, " |");
        return t.split("|").filter(s => s.trim().split(/\s+/).length >= 2).length;
    }
    // The chat each plan talks back in (the bubble's, the side panel's):
    // its plan card, then the merged answer.
    property var _chats: ({})
    function chatOf(plan) {
        const c = root._chats[plan?.id ?? ""] ?? null;
        return c && Ai.chats.includes(c) ? c : null;
    }
    // A plan started: done(id, error). CHAT: where its card and answer go.
    function fanOut(text, chat, done) {
        const t = String(text ?? "").trim();
        if (!root.fanOutEnabled || t.length === 0) {
            if (done) done("", Translation.tr("Splitting orders up is off (Settings > Desktop agents > Autonomy)"));
            return;
        }
        if (!root.canStart) {
            if (done) done("", Translation.tr("%1 tasks already run: wait for one to finish").arg(root.activeCount));
            return;
        }
        starter.createObject(root, { command: [root.command, "fanout", t], done: (id, error) => {
            if (id && chat) root._chats[id] = chat;
            if (done) done(id, error);
        } });
    }
    // A plan's parts written (planned), a plan over (planFinished: done or
    // failed): said once each, never for plans of an earlier session.
    signal planned(var plan)
    signal planFinished(var plan)
    property var _announced: ({})
    function _planChanged(prev, next) {
        const seen = root._announced[next.id] ?? {};
        root._announced[next.id] = seen;
        const nowS = Date.now() / 1000;
        if (!seen.planned && (next.parts ?? []).length > 0 && (prev || nowS - Number(next.started ?? 0) < 120)) {
            seen.planned = true;
            root.planned(next);
        }
        if (!seen.finished && (next.status === "done" || next.status === "failed")
                && (prev?.status === "running" || nowS - Number(next.updated ?? 0) < 60)) {
            seen.finished = true;
            root.planFinished(next);
        }
    }

    FolderListModel {
        id: files
        folder: root._folder
        nameFilters: ["*.json"]
        showDirs: false
        showHidden: false
    }
    Instantiator {
        model: root._folder.length > 0 ? files : 0
        delegate: FileView {
            id: taskFile
            required property string filePath
            path: taskFile.filePath
            watchChanges: true
            printErrors: false
            onFileChanged: reload()
            onLoaded: {
                let next = null
                try {
                    next = JSON.parse(taskFile.text())
                } catch (e) {
                    // Being written (they are written whole, renamed into place).
                    return
                }
                const prev = root._byPath[taskFile.filePath] ?? null
                root._byPath = Object.assign({}, root._byPath, { [taskFile.filePath]: next })
                if (next?.kind === "plan") root._planChanged(prev, next)
            }
            Component.onDestruction: {
                const rest = Object.assign({}, root._byPath)
                delete rest[taskFile.filePath]
                root._byPath = rest
            }
        }
    }

    // A task started: done(id, error).
    function start(text, fromSession, done) {
        const t = String(text ?? "").trim()
        if (!root.enabled || t.length === 0) {
            if (done) done("", Translation.tr("Background tasks are off (Settings > Desktop agents > Autonomy)"))
            return
        }
        if (!root.canStart) {
            if (done) done("", Translation.tr("%1 tasks already run: wait for one to finish").arg(root.activeCount))
            return
        }
        const argv = [root.command, "start", t]
        if (/^[A-Za-z0-9_-]{8,100}$/.test(String(fromSession ?? ""))) argv.push("--from-session", String(fromSession))
        starter.createObject(root, { command: argv, done: done ?? null })
    }
    Component {
        id: starter
        Process {
            id: proc
            property var done: null
            running: true
            stdout: StdioCollector { id: startOut }
            stderr: StdioCollector { id: startErr }
            onExited: code => {
                let id = "", error = ""
                try {
                    const r = JSON.parse(startOut.text)
                    id = String(r.id ?? "")
                    error = String(r.error ?? "")
                } catch (e) {
                    error = startErr.text.trim() || Translation.tr("nixbook-muse-task didn't start (is it installed?)")
                }
                if (!id && !error) error = Translation.tr("it didn't start")
                if (proc.done) proc.done(id, error)
                proc.destroy()
            }
        }
    }

    function _valid(id) {
        return /^[\w-]{1,64}$/.test(String(id ?? ""))
    }
    // The user's answers: a step allowed or not, a reply to its question.
    function approve(task, allow) {
        if (!root._valid(task?.id) || !task.approval?.id) return
        Quickshell.execDetached([root.command, "approve", task.id, String(task.approval.id), allow ? "yes" : "no"])
    }
    function answer(task, text) {
        const t = String(text ?? "").trim()
        if (!root._valid(task?.id) || t.length === 0) return
        Quickshell.execDetached([root.command, "answer", task.id, t])
    }
    function stop(task) {
        const id = typeof task === "string" ? task : task?.id
        if (!root._valid(id)) return false
        Quickshell.execDetached([root.command, "stop", id])
        return true
    }
    function resume(task) {
        if (!root._valid(task?.id)) return
        Quickshell.execDetached([root.command, "resume", task.id])
    }
    function clearFinished() {
        Quickshell.execDetached([root.command, "clear"])
    }
    // Its session, opened in the side panel: a chat of its own going on
    // where the task is (--resume), with what it was asked and its answer.
    function open(task) {
        if (!task) return
        const chat = Ai.askThread(true)
        if (!chat) return
        chat.addMessage(String(task.text ?? ""), "user")
        const said = String(task.report?.summary ?? task.answer ?? task.question ?? task.error ?? "").trim()
        if (said.length > 0) chat.addMessage(said, "assistant")
        if (/^[A-Za-z0-9_-]{8,100}$/.test(String(task.sessionId ?? ""))) chat.agentSessionId = task.sessionId
        chat.surface = "chat"
        GlobalStates.sidebarLeftOpen = true
        GlobalStates.aiChatRequested()
    }
    function openList() {
        GlobalStates.sidebarLeftOpen = true
        GlobalStates.museActivityRequested("tasks")
    }
    // One task shown in the Muse tab (a worker clicked on the bar): its card
    // is scrolled to and outlined.
    property string focusId: ""
    function openTask(id) {
        root.focusId = ""
        root.focusId = String(id ?? "")
        root.openList()
    }
    function statusText(t) {
        if (t?.kind === "plan" && t.status === "running")
            return t.phase === "planning" ? Translation.tr("Planning") : t.phase === "merging" ? Translation.tr("Merging the results")
                : Translation.tr("%1 workers on it").arg(root.workersOf(t).filter(w => root.isLive(w)).length)
        return t?.status === "running" ? Translation.tr("Working")
            : t?.status === "waiting" ? (t.approval ? Translation.tr("Waiting for your OK") : Translation.tr("Waiting for your answer"))
            : t?.status === "done" ? Translation.tr("Done")
            : t?.status === "failed" ? Translation.tr("Failed")
            : t?.status === "stopped" ? Translation.tr("Stopped") : String(t?.status ?? "")
    }

    IpcHandler {
        target: "museTasks"
        // JSON: [{id, text, status, updated}], newest first.
        function list(): string {
            return JSON.stringify(root.tasks.map(t => Object.assign({ id: t.id, text: t.text, status: t.status, updated: t.updated },
                t.kind ? { kind: t.kind, phase: t.phase ?? "" } : {}, t.parent ? { parent: t.parent, title: t.title ?? "" } : {})))
        }
        function stop(id: string): string {
            return root.tasks.some(t => t.id === id) && root.stop(id) ? "ok: stopping it" : "error: no such task"
        }
        // An order planned and split into workers (tests, the user's own
        // scripts; no agent may call it: fanOut is in desktop-mcp's
        // shellIpcDenyFunctions, agents have fan_out). Answered at once; the
        // plan's id comes with `list`.
        function fanOut(text: string): string {
            if (!root.canFanOut) return "error: " + (root.fanOutEnabled ? "no room for another task" : "splitting orders up is off")
            root.fanOut(text, null, null)
            return "ok: planning it"
        }
    }
}
