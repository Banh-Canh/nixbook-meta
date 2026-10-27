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
 * `museTasks` lists and stops, nothing more (not `tasks`: that is the
 * to-do panel's).
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
    readonly property int maxTasks: Config.options?.ai?.autonomy?.maxTasks ?? 3
    readonly property string dir: `${Quickshell.env("XDG_STATE_HOME") || `${Quickshell.env("HOME")}/.local/state`}/nixbook-shell/tasks`
    readonly property string command: "nixbook-muse-task"

    // path -> task (as its file says); `tasks` newest first.
    property var _byPath: ({})
    readonly property var tasks: Object.values(root._byPath).filter(t => t && t.id)
        .sort((a, b) => Number(b.updated ?? b.started ?? 0) - Number(a.updated ?? a.started ?? 0))
    readonly property var running: root.tasks.filter(t => t.status === "running")
    readonly property var waiting: root.tasks.filter(t => t.status === "waiting")
    readonly property int activeCount: root.running.length + root.waiting.length
    readonly property bool canStart: root.enabled && root.activeCount < root.maxTasks

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
                try {
                    root._byPath = Object.assign({}, root._byPath, { [taskFile.filePath]: JSON.parse(taskFile.text()) })
                } catch (e) {
                    // Being written (they are written whole, renamed into place).
                }
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
    function statusText(t) {
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
            return JSON.stringify(root.tasks.map(t => ({ id: t.id, text: t.text, status: t.status, updated: t.updated })))
        }
        function stop(id: string): string {
            return root.tasks.some(t => t.id === id) && root.stop(id) ? "ok: stopping it" : "error: no such task"
        }
    }
}
