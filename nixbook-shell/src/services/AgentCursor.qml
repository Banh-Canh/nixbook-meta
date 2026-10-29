pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Muse's visible cursor: what an agent does on the user's desktop, shown as
 * it does it. nixbook-desktop-mcp (agent_cursor) writes one small event in
 * `agent-cursor.json` ($XDG_RUNTIME_DIR/nixbook-shell) just before each
 * click, drag, scroll, key press or typing ({id, time, kind, x, y, toX, toY,
 * w, h, window, rel, app, label, lead}: desktop logical pixels; `window` an
 * id this shell places from its own window list), then waits `lead` ms for
 * the cursor to get there; and one after each look at a window or a region
 * (kind "read"). modules/ii/agentCursor/AgentCursorOverlay.qml draws it: a
 * second, glowing cursor gliding to the target with its label, a ripple on
 * a click, corner brackets around what was read. It fades out
 * `lingerMs` after the last event, never takes input, and hides from the
 * agent's own screenshots (listed in MakeWay's overlays while shown).
 * Nothing while it is off (ai.agent.showCursor), with AI off, paused, on the
 * agent desktop or locked. `agent-cursor.ready` says "1" while it shows
 * events: the server only waits the lead then.
 */
Singleton {
    id: root

    readonly property string dir: Directories.runtimeTemp
    readonly property bool enabled: Config.ready && (Config.options.ai?.agent?.showCursor ?? true)
        && (Config.options.policies?.ai ?? 1) !== 0
    readonly property bool live: root.enabled && !DesktopControl.paused && !DesktopControl.onAgentDesktop
        && !GlobalStates.screenLocked
    // How long it stays after the last step.
    readonly property int lingerMs: 1500

    // The last pointer/keyboard step and the last look (separate: a look
    // outlines its window without moving the cursor).
    property var action: null
    property var look: null
    property bool shown: false
    // Built once first needed, kept mapped after (AgentCursorOverlay).
    property bool everShown: false
    onShownChanged: if (root.shown) root.everShown = true
    onLiveChanged: if (!root.live) {
        root.shown = false
        linger.stop()
    }

    signal acted(var event)
    signal looked(var event)

    // An event already shown, or older than this (a file left from before a
    // restart), is not shown again.
    property string lastId: ""
    readonly property int staleMs: 4000

    function handle(event) {
        if (!event || typeof event !== "object" || typeof event.id !== "string" || event.id === root.lastId) return
        root.lastId = event.id
        if (!root.live || Math.abs(Date.now() - (event.time ?? 0)) > root.staleMs) return
        root.shown = true
        linger.interval = Math.max(0, event.lead ?? 0) + root.lingerMs
        linger.restart()
        if (event.kind === "read") {
            root.look = event
            root.looked(event)
        } else {
            root.action = event
            root.acted(event)
        }
    }

    Timer {
        id: linger
        interval: root.lingerMs
        onTriggered: root.shown = false
    }

    FileView {
        id: eventFile
        path: `${root.dir}/agent-cursor.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            let event = null
            try {
                event = JSON.parse(text())
            } catch (e) {
                // Caught mid-write (written in place): read it again.
                retry.restart()
                return
            }
            root.handle(event)
        }
    }
    Timer {
        id: retry
        interval: 40
        onTriggered: eventFile.reload()
    }

    // Whether the server should wait the lead: only when it will be seen.
    readonly property bool ready: root.enabled && !DesktopControl.onAgentDesktop
    onReadyChanged: readyFile.setText(root.ready ? "1" : "0")
    FileView {
        id: readyFile
        path: `${root.dir}/agent-cursor.ready`
        blockWrites: true
        printErrors: false
    }
    Component.onCompleted: readyWrite.restart()
    // Once Config is read (ready flips before this singleton may exist).
    Timer {
        id: readyWrite
        interval: 1000
        onTriggered: readyFile.setText(root.ready ? "1" : "0")
    }
}
