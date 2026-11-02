pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

/**
 * "Next up"'s chip (services/NextUp.qml): ONE chip beside the desktop
 * mascot, in its corner (ai.mascot.corner; in the corner itself without the
 * mascot): "Next: open Jira ⇧⏎", under it why ("You usually open Jira after
 * your 09:00 standup — 14 times") and what taking it does ("Opens Jira, or
 * brings it to the front"; a follow-up: "Muse will read the pull request and
 * review it — nothing is posted"). It slides in from its side with a short
 * accent glow, so it is seen. A small Top-layer surface
 * that never takes the keyboard (the key is niri's Mod+Shift+Return) and lets
 * every click through but on the pill: a click does it, a right click opens
 * Not now / Never after this / Never suggest this. It fades after 12 s
 * (NextUp's timer), not while hovered. Mapped only while there is an offer
 * (and a moment more for its fade): at rest nothing is drawn. Gone from an
 * agent's screenshots (MakeWay).
 */
Scope {
    id: root

    LazyLoader {
        active: NextUp.enabled && NextUp.chipMapped
        component: PanelWindow {
            id: window
            screen: Quickshell.screens.find(s => s.name === NextUp.screenName) ?? Quickshell.screens[0]
            readonly property string corner: ["bottomRight", "bottomLeft", "topRight", "topLeft"].includes(Config.options?.ai?.mascot?.corner)
                ? Config.options.ai.mascot.corner : "bottomRight"
            readonly property bool right: window.corner.endsWith("Right")
            readonly property bool bottom: window.corner.startsWith("bottom")
            // Beside the mascot when it lives there (DesktopMascot: 14 px from
            // the edge, about 102 × 119 px), at the height of its middle.
            readonly property bool mascot: (Config.options?.ai?.mascot?.enable ?? false) && (Config.options?.policies?.ai ?? 1) !== 0
            readonly property var offer: NextUp.offer ?? NextUp.last
            color: "transparent"
            implicitWidth: 440
            implicitHeight: 280
            anchors {
                top: !window.bottom
                bottom: window.bottom
                left: !window.right
                right: window.right
            }
            margins {
                right: window.right ? (window.mascot ? 122 : 14) : 0
                left: window.right ? 0 : (window.mascot ? 122 : 14)
                bottom: window.bottom ? (window.mascot ? 40 : 14) : 0
                top: window.bottom ? 0 : (window.mascot ? 40 : 14)
            }
            exclusionMode: ExclusionMode.Normal
            exclusiveZone: 0
            WlrLayershell.namespace: "quickshell:nextUp"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            // Clicks only on what shows (the pill, its menu, the reason), none
            // while an agent works on the desktop or once it faded.
            property Region noInput: Region {}
            property Region hitInput: Region { item: stack }
            mask: NextUp.offer !== null && !MakeWay.active ? window.hitInput : window.noInput

            property bool menuOpen: false
            readonly property bool hovering: pillMouse.containsMouse || menuHover.hovered
            onHoveringChanged: NextUp.held = window.hovering || window.menuOpen
            onMenuOpenChanged: NextUp.held = window.hovering || window.menuOpen
            // A new offer comes with its menu shut.
            Connections {
                target: NextUp
                function onOffered() {
                    window.menuOpen = false;
                    window.arrive();
                }
            }
            // It arrives: slides in from its side, its accent glow pulses
            // twice (not while an agent captures the screen).
            function arrive() {
                if (MakeWay.capture) return;
                slide.x = window.right ? 56 : -56;
                slideIn.restart();
                pulse.restart();
            }
            Component.onCompleted: if (NextUp.offer !== null) window.arrive()

            GridLayout {
                id: stack
                columns: 1
                rowSpacing: 6
                x: window.right ? window.width - width - 4 : 4
                y: window.bottom ? window.height - height - 4 : 4
                opacity: NextUp.offer !== null && !MakeWay.capture ? 1 : 0
                scale: NextUp.offer !== null ? 1 : 0.92
                transformOrigin: window.bottom ? (window.right ? Item.BottomRight : Item.BottomLeft)
                    : (window.right ? Item.TopRight : Item.TopLeft)
                Behavior on opacity {
                    enabled: !MakeWay.capture
                    NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
                }
                Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
                transform: Translate { id: slide }
                NumberAnimation {
                    id: slideIn
                    target: slide
                    property: "x"
                    to: 0
                    duration: 420
                    easing.type: Easing.OutBack
                }

                // How to take it, on hover (why it is offered is on the chip).
                Rectangle {
                    id: why
                    Layout.row: window.bottom ? 0 : 2
                    Layout.alignment: window.right ? Qt.AlignRight : Qt.AlignLeft
                    visible: window.hovering && !window.menuOpen
                    implicitWidth: Math.min(360, whyText.implicitWidth + 20)
                    implicitHeight: whyText.implicitHeight + 14
                    radius: 12
                    color: Appearance.m3colors.m3surfaceContainerHighest
                    border.width: 1
                    border.color: Appearance.m3colors.m3outlineVariant
                    StyledText {
                        id: whyText
                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, 340)
                        wrapMode: Text.Wrap
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.m3colors.m3onSurface
                        text: Translation.tr("Click or Super+Shift+Enter · right click: Not now, Never")
                    }
                }

                // Not now / Never after this / Never suggest this.
                Rectangle {
                    Layout.row: 1
                    Layout.alignment: window.right ? Qt.AlignRight : Qt.AlignLeft
                    visible: window.menuOpen
                    implicitWidth: menuColumn.implicitWidth + 12
                    implicitHeight: menuColumn.implicitHeight + 12
                    radius: 14
                    color: Appearance.m3colors.m3surfaceContainerHigh
                    border.width: 1
                    border.color: Appearance.m3colors.m3outlineVariant
                    HoverHandler { id: menuHover }
                    ColumnLayout {
                        id: menuColumn
                        anchors.centerIn: parent
                        spacing: 2
                        Repeater {
                            model: [
                                { icon: "schedule", text: Translation.tr("Not now"), act: () => NextUp.dismiss() },
                                { icon: "block", text: Translation.tr("Never after this"), act: () => NextUp.never(false) },
                                { icon: "do_not_disturb_on", text: Translation.tr("Never suggest this"), act: () => NextUp.never(true) }
                            ]
                            delegate: Rectangle {
                                id: item
                                required property var modelData
                                Layout.fillWidth: true
                                implicitWidth: itemRow.implicitWidth + 16
                                implicitHeight: itemRow.implicitHeight + 8
                                radius: 10
                                color: itemMouse.containsMouse ? Appearance.m3colors.m3secondaryContainer : "transparent"
                                RowLayout {
                                    id: itemRow
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: 8
                                    spacing: 6
                                    MaterialSymbol {
                                        text: item.modelData.icon
                                        iconSize: Appearance.font.pixelSize.normal
                                        color: Appearance.m3colors.m3onSurface
                                    }
                                    StyledText {
                                        text: item.modelData.text
                                        font.pixelSize: Appearance.font.pixelSize.small
                                        color: Appearance.m3colors.m3onSurface
                                    }
                                }
                                MouseArea {
                                    id: itemMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        window.menuOpen = false;
                                        item.modelData.act();
                                    }
                                }
                            }
                        }
                    }
                }

                // The chip: the step, why it is offered ("You usually open Jira
                // after your 09:00 standup — 14 times"), what taking it does
                // ("Muse will read the pull request and review it").
                Rectangle {
                    id: pill
                    Layout.row: window.bottom ? 2 : 0
                    Layout.alignment: window.right ? Qt.AlignRight : Qt.AlignLeft
                    implicitWidth: Math.min(380, pillColumn.implicitWidth + 28)
                    implicitHeight: pillColumn.implicitHeight + 16
                    radius: Math.min(20, height / 2)
                    color: pillMouse.containsMouse ? Appearance.m3colors.m3secondaryContainer : Appearance.m3colors.m3surfaceContainerHigh
                    border.width: 1
                    border.color: pillMouse.containsMouse ? Appearance.m3colors.m3primary : Appearance.m3colors.m3outlineVariant
                    Behavior on color { ColorAnimation { duration: 140 } }
                    // The accent glow it arrives with (window.arrive()).
                    Rectangle {
                        id: glow
                        anchors.fill: parent
                        anchors.margins: -4
                        radius: pill.radius + 4
                        color: "transparent"
                        border.width: 2
                        border.color: Appearance.m3colors.m3primary
                        opacity: 0
                        SequentialAnimation {
                            id: pulse
                            loops: 2
                            NumberAnimation { target: glow; property: "opacity"; from: 0; to: 0.9; duration: 240; easing.type: Easing.OutCubic }
                            NumberAnimation { target: glow; property: "opacity"; to: 0; duration: 560; easing.type: Easing.InCubic }
                        }
                    }
                    ColumnLayout {
                        id: pillColumn
                        x: 14
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, 352)
                        spacing: 2
                        RowLayout {
                            id: pillRow
                            spacing: 8
                            MaterialSymbol {
                                // A follow-up is Muse's work (a model); the rest a step of yours.
                                text: window.offer?.model ? "auto_awesome" : "magic_button"
                                iconSize: Appearance.font.pixelSize.large
                                color: Appearance.m3colors.m3primary
                            }
                            StyledText {
                                Layout.fillWidth: true
                                Layout.maximumWidth: 270
                                elide: Text.ElideRight
                                text: window.offer?.chip ?? ""
                                font.pixelSize: Appearance.font.pixelSize.small
                                font.weight: Font.Medium
                                color: Appearance.m3colors.m3onSurface
                            }
                            // The key: Super+Shift+Enter.
                            Rectangle {
                                implicitWidth: keyText.implicitWidth + 10
                                implicitHeight: keyText.implicitHeight + 4
                                radius: 6
                                color: "transparent"
                                border.width: 1
                                border.color: Appearance.m3colors.m3outlineVariant
                                StyledText {
                                    id: keyText
                                    anchors.centerIn: parent
                                    text: "⇧⏎"
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.colors.colSubtext
                                }
                            }
                        }
                        // Why: the habit behind it, or that Muse offers it and learns.
                        StyledText {
                            Layout.fillWidth: true
                            Layout.maximumWidth: 352
                            visible: text.length > 0
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            text: window.offer?.explain ?? ""
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colSubtext
                        }
                        // What taking it does.
                        RowLayout {
                            Layout.maximumWidth: 352
                            visible: (window.offer?.preview ?? "").length > 0
                            spacing: 4
                            MaterialSymbol {
                                text: "subdirectory_arrow_right"
                                iconSize: Appearance.font.pixelSize.small
                                color: Appearance.m3colors.m3primary
                            }
                            StyledText {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                                text: window.offer?.preview ?? ""
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.m3colors.m3primary
                            }
                        }
                    }
                    MouseArea {
                        id: pillMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: mouse => {
                            if (mouse.button === Qt.RightButton) {
                                window.menuOpen = !window.menuOpen;
                                return;
                            }
                            window.menuOpen = false;
                            NextUp.accept();
                        }
                    }
                }
            }
        }
    }
}
