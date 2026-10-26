pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import Quickshell
import Quickshell.Wayland

/**
 * Full AI mode's layer (services/FullAi.qml): over every screen, it takes
 * the user's keyboard and mouse (Escape leaves the mode), with a soft glow
 * at the edges saying the AI is in charge, and the mascot (MascotStage) on
 * the screen the mode was started on. While the agent acts (MakeWay), it
 * lets its clicks and keys through and gives up the keyboard; while the
 * agent takes a screenshot, it vanishes.
 */
Scope {
    id: root

    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            id: window
            required property var modelData
            readonly property bool main: window.modelData.name === FullAi.screenName
                || (!Quickshell.screens.some(s => s.name === FullAi.screenName) && window.modelData === Quickshell.screens[0])
            screen: window.modelData
            visible: FullAi.active && !GlobalStates.screenLocked
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            anchors { top: true; bottom: true; left: true; right: true }
            WlrLayershell.namespace: "quickshell:fullAi"
            WlrLayershell.layer: WlrLayer.Overlay
            // The keys: one screen takes them (Escape), none while the agent acts.
            // `regrab` drops it for a moment and asks again: a surface mapped
            // after it (the speech bubble) can leave the compositor's keyboard
            // elsewhere, and Escape must always reach the mode.
            property bool regrab: false
            WlrLayershell.keyboardFocus: window.main && !MakeWay.active && !window.regrab ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            // Every click caught, but the agent's while it acts.
            mask: MakeWay.active ? noInput : null
            Region { id: noInput }

            onVisibleChanged: if (visible && window.main) {
                focusLater.restart()
                regrabTimer.count = 0
                regrabTimer.restart()
            }
            Timer {
                id: regrabTimer
                property int count: 0
                interval: 700
                onTriggered: {
                    window.regrab = true
                    regrabBack.restart()
                    if (++count < 3) restart()
                }
            }
            Timer {
                id: regrabBack
                interval: 60
                onTriggered: {
                    window.regrab = false
                    focusLater.restart()
                }
            }
            // The agent done acting: the keys back to the mode.
            Connections {
                target: MakeWay
                function onActiveChanged() { if (!MakeWay.active && window.main && window.visible) focusLater.restart() }
            }
            // Escape whatever item has the focus in the window.
            Shortcut {
                sequences: ["Escape"]
                context: Qt.WindowShortcut
                enabled: window.main && window.visible
                onActivated: FullAi.exit()
            }
            Timer {
                id: focusLater
                interval: 50
                onTriggered: keys.forceActiveFocus()
            }
            Item {
                id: keys
                anchors.fill: parent
                focus: window.main
                Component.onCompleted: if (window.main) focusLater.restart()
                // Hidden from the agent's own screenshots.
                opacity: MakeWay.capture ? 0 : 1
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) FullAi.exit();
                    event.accepted = true;
                }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    hoverEnabled: true
                    preventStealing: true
                    onWheel: wheel => wheel.accepted = true
                }

                // The AI is in charge: a breathing glow around the screen.
                Rectangle {
                    id: glow
                    anchors.fill: parent
                    color: "transparent"
                    border.width: 4
                    border.color: Qt.alpha(Appearance.colors.colPrimary, 0.55)
                    radius: Appearance.rounding.screenRounding
                    SequentialAnimation on opacity {
                        running: window.visible
                        loops: Animation.Infinite
                        NumberAnimation { from: 0.45; to: 1; duration: 1600; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 1; to: 0.45; duration: 1600; easing.type: Easing.InOutSine }
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.width: 14
                    border.color: Qt.alpha(Appearance.colors.colPrimary, 0.12)
                    radius: Appearance.rounding.screenRounding
                    opacity: glow.opacity
                }

                Loader {
                    id: stageLoader
                    anchors.fill: parent
                    active: window.main && window.visible
                    sourceComponent: MascotStage {
                        active: true
                        mood: FullAi.mood
                        line: FullAi.line
                        hint: FullAi.hint
                        level: Voice.level
                        talking: FullAi.mood === "speaking"
                    }
                }
                Connections {
                    target: QuickAi
                    // A step starting: the mascot darts there.
                    function onStepsChanged() {
                        if (stageLoader.item && QuickAi.steps.some(s => s.status === "run")) stageLoader.item.dash();
                    }
                }
                Connections {
                    target: FullAi
                    function onFlashChanged() {
                        if (!stageLoader.item) return;
                        if (FullAi.flash === "happy") stageLoader.item.celebrate();
                        else if (FullAi.flash === "sad") stageLoader.item.shake();
                    }
                }
            }
        }
    }
}
