pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import Quickshell
import Quickshell.Wayland

/**
 * Muse on the desktop (ai.mascot, services/MascotState.qml): the Full AI
 * mascot (Mascot.qml, the same art), small in a corner of the focused
 * screen. A small surface on the Top layer that takes no keys and lets every
 * click through but on the mascot itself (a click calls Muse's bubble up,
 * Initiative.toggle). Kept mapped once built: hidden (locked, fullscreen,
 * Full AI mode, `mascot hide`) it fades out and takes no input, so showing
 * it again costs nothing. At rest it stands still (no idle loops: a still
 * corner costs no frame); it blinks now and then, and moves for what
 * happens. Out of an agent's screenshots (MakeWay).
 */
Scope {
    id: root

    LazyLoader {
        active: MascotState.enabled
        component: PanelWindow {
            id: window
            screen: Quickshell.screens.find(s => s.name === MascotState.screenName) ?? Quickshell.screens[0]
            readonly property bool right: MascotState.corner.endsWith("Right")
            readonly property bool bottom: MascotState.corner.startsWith("bottom")
            color: "transparent"
            implicitWidth: 300
            implicitHeight: 230
            anchors {
                top: !window.bottom
                bottom: window.bottom
                left: !window.right
                right: window.right
            }
            // Beside the bar and the dock, never reserving space itself.
            exclusionMode: ExclusionMode.Normal
            exclusiveZone: 0
            WlrLayershell.namespace: "quickshell:mascot"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            // Clicks only on the mascot, and none while hidden or while an
            // agent works on the desktop.
            property Region noInput: Region {}
            property Region hitInput: Region { item: hit }
            mask: MascotState.shown && !MakeWay.active ? window.hitInput : window.noInput

            readonly property real margin: 14
            readonly property real zoom: 0.85

            Item {
                id: stage
                anchors.fill: parent
                opacity: MascotState.shown && !MakeWay.capture ? 1 : 0
                Behavior on opacity {
                    // Gone at once for a screenshot; a fade otherwise.
                    enabled: !MakeWay.capture
                    NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                }
                readonly property bool live: stage.opacity > 0 && !Idle.screensOff

                // The mascot, in its corner.
                Item {
                    id: hit
                    width: 120 * window.zoom
                    height: 140 * window.zoom
                    x: window.right ? parent.width - width - window.margin : window.margin
                    y: window.bottom ? parent.height - height - window.margin : window.margin

                    // Its centre on its screen, for where it looks.
                    readonly property real cx: window.right ? window.width - window.margin - width / 2 : window.margin + width / 2
                    readonly property real cy: window.bottom ? window.height - window.margin - height / 2 : window.margin + height / 2
                    readonly property real screenW: window.screen?.width ?? 1920
                    readonly property real screenH: window.screen?.height ?? 1080
                    readonly property real gazeX: {
                        const g = MascotState.gaze;
                        if (!g) return window.right ? -0.2 : 0.2; // a little towards the screen
                        const sx = window.right ? hit.screenW - window.width + hit.cx : hit.cx;
                        return Math.max(-1, Math.min(1, (g.x * hit.screenW - sx) / (hit.screenW / 2)));
                    }
                    readonly property real gazeY: {
                        const g = MascotState.gaze;
                        if (!g) return 0.1;
                        const sy = window.bottom ? hit.screenH - window.height + hit.cy : hit.cy;
                        return Math.max(-1, Math.min(1, (g.y * hit.screenH - sy) / (hit.screenH / 2)));
                    }

                    // A little lean towards where it looks (the head turns).
                    transform: Rotation {
                        origin.x: hit.width / 2
                        origin.y: hit.height
                        angle: mascot.lookX * 6
                    }

                    Mascot {
                        id: mascot
                        scale: window.zoom
                        transformOrigin: Item.TopLeft
                        mood: MascotState.mood
                        level: Voice.level
                        talking: Voice.speaking || MascotState.mood === "speaking"
                        lip: lipSync.value
                        // The idle loops only while something goes on.
                        ambient: ["thinking", "acting", "speaking", "listening", "sleepy"].includes(MascotState.mood)
                        suspended: !stage.live
                        lookX: hit.gazeX
                        lookY: MascotState.mood === "thinking" ? -1 : hit.gazeY
                        Behavior on lookX { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                        Behavior on lookY { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton
                        onClicked: {
                            mascot.hop();
                            Initiative.toggle();
                        }
                        // Hovered: it notices (at most every few seconds).
                        property real lastPerk: 0
                        onEntered: {
                            if (Date.now() - lastPerk < 4000) return;
                            lastPerk = Date.now();
                            mascot.perk();
                        }
                    }
                }

                // Its quip (MascotState.line): a tiny balloon over it (under
                // it in a top corner), its tail towards it.
                Rectangle {
                    id: balloon
                    readonly property real maxW: 250
                    visible: MascotState.line.length > 0 || pop.running
                    width: Math.min(balloon.maxW, quipText.implicitWidth + 24)
                    height: quipText.implicitHeight + 16
                    x: window.right ? Math.max(4, hit.x + hit.width - width + 6) : Math.min(window.width - width - 4, hit.x - 6)
                    // Clear of its antenna and thinking dots (above its box).
                    y: window.bottom ? Math.max(2, hit.y - height - 16) : hit.y + hit.height + 6
                    radius: Math.min(16, height / 2)
                    color: Appearance.m3colors.m3surfaceContainerHigh
                    border.width: 2
                    border.color: mascot.outline
                    transformOrigin: window.bottom ? (window.right ? Item.BottomRight : Item.BottomLeft)
                        : (window.right ? Item.TopRight : Item.TopLeft)
                    scale: MascotState.line.length > 0 ? 1 : 0.6
                    opacity: MascotState.line.length > 0 ? 1 : 0
                    Behavior on scale { NumberAnimation { id: pop; duration: 240; easing.type: Easing.OutBack } }
                    Behavior on opacity { NumberAnimation { duration: 180 } }
                    // The tail.
                    Rectangle {
                        width: 12
                        height: 12
                        rotation: 45
                        color: balloon.color
                        border.width: 2
                        border.color: balloon.border.color
                        x: window.right ? balloon.width - 34 : 22
                        y: window.bottom ? balloon.height - 7 : -5
                        z: -1
                    }
                    StyledText {
                        id: quipText
                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, balloon.maxW - 24)
                        text: MascotState.line
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.m3colors.m3onSurface
                    }
                }
            }

            // Lip-sync: the sentence playing (Voice.saying grows as each
            // starts) read out at a speaking pace, the mouth open on vowels,
            // half on consonants, shut on spaces and punctuation; past the
            // text, a soft babble until the next sentence (the voice still
            // on it). Nothing reported yet: shut (it is still being made).
            QtObject {
                id: lipSync
                property string queue: ""
                property int fed: 0
                property real mouth: 0
                property bool babble: false
                readonly property real value: Voice.speaking && stage.live ? lipSync.mouth : -1
                readonly property var vowels: /[aeiouyàâäéèêëîïôöùûüÿœæăắằẳẵặâấầẩẫậêếềểễệôốồổỗộơớờởỡợưứừửữựíìỉĩịóòỏõọúùủũụýỳỷỹỵ]/i
            }
            Connections {
                target: Voice
                function onSayingChanged() {
                    const s = Voice.saying;
                    if (s === null || s === undefined) {
                        lipSync.queue = "";
                        lipSync.fed = 0;
                        lipSync.babble = false;
                        return;
                    }
                    // A new answer started over.
                    if (s.length < lipSync.fed) lipSync.fed = 0;
                    if (s.length > lipSync.fed) {
                        lipSync.queue += s.slice(lipSync.fed);
                        lipSync.fed = s.length;
                        lipSync.babble = true;
                    }
                }
            }
            Timer {
                running: Voice.speaking && stage.live
                interval: 70
                repeat: true
                onTriggered: {
                    const q = lipSync.queue;
                    if (q.length === 0) {
                        lipSync.mouth = lipSync.babble ? 0.15 + Math.random() * 0.5 : 0;
                        return;
                    }
                    const c = q.charAt(0);
                    lipSync.queue = q.slice(1);
                    lipSync.mouth = lipSync.vowels.test(c) ? 0.65 + Math.random() * 0.35
                        : /[\s.,!?;:…\-]/.test(c) ? 0.04 : 0.28;
                }
                onRunningChanged: if (!running) lipSync.mouth = 0
            }

            Connections {
                target: MascotState
                function onReaction(kind) {
                    if (!stage.live) return;
                    if (kind === "hop") mascot.hop();
                    else if (kind === "celebrate") mascot.celebrate();
                    else if (kind === "shake") mascot.shake();
                    else if (kind === "stretch") mascot.stretch();
                    else if (kind === "perk") mascot.perk();
                }
            }
        }
    }
}
