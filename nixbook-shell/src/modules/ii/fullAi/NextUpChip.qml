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
 * "Next up"'s chip (services/NextUp.qml): ONE quiet pill beside the desktop
 * mascot, in its corner (ai.mascot.corner; in the corner itself without the
 * mascot): "Next: open Jira ⇧⏎", why on hover. A small Top-layer surface
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
            implicitWidth: 400
            implicitHeight: 190
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
                function onOffered() { window.menuOpen = false; }
            }

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

                // Why: on hover ("You usually open Jira after your 09:00
                // standup — 14 times"), and how to take it.
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
                        text: `${window.offer?.explain ?? ""}\n${Translation.tr("Click or Super+Shift+Enter · right click: Not now, Never")}`
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

                // The pill.
                Rectangle {
                    id: pill
                    Layout.row: window.bottom ? 2 : 0
                    Layout.alignment: window.right ? Qt.AlignRight : Qt.AlignLeft
                    implicitWidth: pillRow.implicitWidth + 24
                    implicitHeight: pillRow.implicitHeight + 14
                    radius: height / 2
                    color: pillMouse.containsMouse ? Appearance.m3colors.m3secondaryContainer : Appearance.m3colors.m3surfaceContainerHigh
                    border.width: 1
                    border.color: pillMouse.containsMouse ? Appearance.m3colors.m3primary : Appearance.m3colors.m3outlineVariant
                    Behavior on color { ColorAnimation { duration: 140 } }
                    RowLayout {
                        id: pillRow
                        anchors.centerIn: parent
                        spacing: 8
                        MaterialSymbol {
                            // A follow-up is Muse's work (a model); the rest a step of yours.
                            text: window.offer?.model ? "auto_awesome" : "magic_button"
                            iconSize: Appearance.font.pixelSize.large
                            color: Appearance.m3colors.m3primary
                        }
                        StyledText {
                            Layout.maximumWidth: 280
                            elide: Text.ElideRight
                            text: window.offer?.chip ?? ""
                            font.pixelSize: Appearance.font.pixelSize.small
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
