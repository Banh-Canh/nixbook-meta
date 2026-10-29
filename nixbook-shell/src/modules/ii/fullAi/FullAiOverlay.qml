pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import Quickshell
import Quickshell.Wayland

/**
 * Full AI mode's layer (services/FullAi.qml): the mascot (MascotStage) on
 * the screen the mode was started on, the mode's only sign on screen (no
 * glow, no "how to leave" hint: the user asked for the mascot alone). It takes no keys and
 * no clicks but on the balloon's Yes / No while a question waits: the user
 * keeps working, the agent's own clicks and keys go through too. While the
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
            // Never in the way: no keys, every click through to the apps
            // (the user keeps their desktop; Mod+Shift+T leaves the mode).
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            // Clicks only on the balloon's Yes / No while a question waits.
            property Region noInput: Region {}
            property Region choicesInput: Region {
                item: stageLoader.item ? stageLoader.item.choicesArea : null
            }
            mask: FullAi.yesNo && stageLoader.item && !MakeWay.capture ? window.choicesInput : window.noInput

            Item {
                id: keys
                anchors.fill: parent
                // Hidden from the agent's own screenshots.
                opacity: MakeWay.capture ? 0 : 1

                Loader {
                    id: stageLoader
                    anchors.fill: parent
                    active: window.main && window.visible
                    sourceComponent: MascotStage {
                        active: true
                        mood: FullAi.mood
                        line: FullAi.line
                        lineKind: FullAi.lineKind
                        yesNo: FullAi.yesNo
                        onChose: yes => FullAi.answer(yes)
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
