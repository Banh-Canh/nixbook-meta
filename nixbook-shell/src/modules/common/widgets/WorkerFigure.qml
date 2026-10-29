import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick

/**
 * A little worker: one of Muse's background tasks, a fan-out's worker or
 * the plan being written (services/MuseTasks.qml, its `figures`), on the
 * bar and in the plan cards. Muse's robot in miniature, with what it is
 * doing beside it:
 *   think  — tilts its head (a plan being written or merged, the agent
 *            thinking between steps);
 *   type   — bobs, a keyboard under it (its answer streams);
 *   search — a magnifier sweeping (the web searched or read);
 *   tool   — a gear turning (any other tool: the calendar, an app…);
 *   wait   — an hourglass, the whole figure pulsing (an OK or an answer);
 *   cheer  — hops and celebrates (done);
 *   slump  — droops, faded (failed or stopped);
 *   queued — faint and still (a part not started yet: waiting for the
 *            part it needs, or for room).
 * Under it, the model it runs (Spark, Wonder). Its animations run only
 * while it can be seen (ObjectUtils.shown).
 */
Item {
    id: root
    property var figure: null
    property color tone: Appearance.colors.colOnLayer1
    property color accent: Appearance.colors.colPrimary
    property color bad: Appearance.colors.colError
    property real size: Appearance.font.pixelSize.normal
    property bool showLabel: true
    property string fontFamily: Appearance.font.family.main

    readonly property string mood: root.figure?.state ?? "think"
    readonly property string modelLabel: MuseTasks.modelLabel(root.figure?.modelId ?? "")
    readonly property bool animate: ObjectUtils.shown(root)

    implicitWidth: Math.max(root.size + 8, label.visible ? label.implicitWidth : 0)
    implicitHeight: root.size + 2 + (label.visible ? label.implicitHeight : 0)

    // The whole figure: the hop (cheer) and the pulse (wait).
    property real hop: 0
    property real pulse: 1
    SequentialAnimation on pulse {
        running: root.animate && root.mood === "wait"
        loops: Animation.Infinite
        NumberAnimation { to: 0.45; duration: 800; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1; duration: 800; easing.type: Easing.InOutSine }
        onRunningChanged: if (!running) root.pulse = 1
    }
    // Done: three hops, then still (it stays a few seconds on the bar).
    SequentialAnimation on hop {
        running: root.animate && root.mood === "cheer"
        loops: 3
        NumberAnimation { to: -4; duration: 160; easing.type: Easing.OutQuad }
        NumberAnimation { to: 0; duration: 340; easing.type: Easing.OutBounce }
        onRunningChanged: if (!running) root.hop = 0
    }
    // Typing: a quick bob.
    property real bob: 0
    SequentialAnimation on bob {
        running: root.animate && root.mood === "type"
        loops: Animation.Infinite
        NumberAnimation { to: -1.5; duration: 140 }
        NumberAnimation { to: 0; duration: 140 }
        onRunningChanged: if (!running) root.bob = 0
    }
    // Thinking: the head tilts one way, then the other.
    property real tilt: 0
    SequentialAnimation on tilt {
        running: root.animate && root.mood === "think"
        loops: Animation.Infinite
        NumberAnimation { to: 8; duration: 700; easing.type: Easing.InOutSine }
        NumberAnimation { to: -8; duration: 1400; easing.type: Easing.InOutSine }
        NumberAnimation { to: 0; duration: 700; easing.type: Easing.InOutSine }
        onRunningChanged: if (!running) root.tilt = 0
    }

    Item {
        id: body
        width: root.size + 8
        height: root.size + 2
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.hop + root.bob + (root.mood === "slump" ? 2 : 0)
        opacity: root.mood === "slump" ? 0.5 : root.mood === "queued" ? 0.3 : root.pulse

        MaterialSymbol {
            id: head
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: -2
            text: "smart_toy"
            fill: 1
            iconSize: root.size
            color: root.mood === "slump" ? root.tone : root.mood === "cheer" || root.mood === "wait" ? root.accent : root.tone
            rotation: root.mood === "slump" ? 22 : root.tilt
            Behavior on rotation {
                enabled: root.mood === "slump"
                NumberAnimation { duration: 400; easing.type: Easing.OutBack }
            }
        }
        // What it holds: the keyboard, the magnifier, the gear…
        MaterialSymbol {
            id: prop
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: -1 + root.sweep
            anchors.bottomMargin: -2
            visible: text.length > 0
            text: root.mood === "type" ? "keyboard"
                : root.mood === "search" ? "search"
                : root.mood === "tool" ? "settings"
                : root.mood === "wait" ? "hourglass_top"
                : root.mood === "cheer" ? "celebration"
                : root.mood === "slump" ? "close" : ""
            fill: 1
            iconSize: Math.round(root.size * 0.62)
            color: root.mood === "slump" ? root.bad : root.accent
            rotation: root.spin
        }
    }
    // Searching: the magnifier sweeps; a tool: the gear turns.
    property real sweep: 0
    SequentialAnimation on sweep {
        running: root.animate && root.mood === "search"
        loops: Animation.Infinite
        NumberAnimation { to: -4; duration: 450; easing.type: Easing.InOutSine }
        NumberAnimation { to: 0; duration: 450; easing.type: Easing.InOutSine }
        onRunningChanged: if (!running) root.sweep = 0
    }
    property real spin: 0
    NumberAnimation on spin {
        running: root.animate && root.mood === "tool"
        loops: Animation.Infinite
        from: 0
        to: 360
        duration: 1600
        onRunningChanged: if (!running) root.spin = 0
    }

    StyledText {
        id: label
        visible: root.showLabel && root.modelLabel.length > 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: body.bottom
        anchors.topMargin: -1
        text: root.modelLabel
        font.family: root.fontFamily
        font.pixelSize: Math.max(7, Appearance.font.pixelSize.smallest - 2)
        font.weight: Font.DemiBold
        color: root.mood === "slump" ? root.bad : root.tone
        opacity: 0.8
    }
}
