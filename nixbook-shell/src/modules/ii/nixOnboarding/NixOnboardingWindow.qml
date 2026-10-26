pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

/**
 * Setting up the desktop by talking (services/NixOnboarding.qml): an app
 * window (xdg-toplevel, like Settings) with the conversation, the checks Nix
 * runs on the model's configuration as they happen, then the configuration
 * with its "checked by Nix" badge and Copy / Build it for me / Apply now.
 */
Scope {
    id: root

    property bool everOpened: false
    Connections {
        target: NixOnboarding
        function onOpenChanged() { if (NixOnboarding.open) root.everOpened = true }
    }

    readonly property color fg: Appearance.m3colors.m3onSurface
    readonly property color sub: Appearance.colors.colSubtext
    readonly property color accent: Appearance.colors.colPrimary

    // The window's buttons: an icon and a word, the main one filled.
    component Action: RippleButton {
        id: action
        property string glyph
        property string label
        property bool main: false
        implicitHeight: 34
        implicitWidth: actionRow.implicitWidth + 26
        buttonRadius: 17
        colBackground: action.main ? Appearance.colors.colPrimary : Appearance.colors.colLayer2
        colBackgroundHover: action.main ? Appearance.colors.colPrimaryHover : Appearance.colors.colLayer2Hover
        contentItem: Row {
            id: actionRow
            anchors.centerIn: parent
            spacing: 6
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: action.glyph
                iconSize: 17
                color: action.main ? Appearance.colors.colOnPrimary : root.fg
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: action.label
                font.pixelSize: Appearance.font.pixelSize.small
                color: action.main ? Appearance.colors.colOnPrimary : root.fg
            }
        }
    }

    Loader {
        active: root.everOpened
        sourceComponent: FloatingWindow {
            id: window
            title: Translation.tr("Set up my desktop")
            visible: NixOnboarding.open
            implicitWidth: 760
            implicitHeight: 820
            minimumSize: Qt.size(520, 480)
            color: Appearance.colors.colLayer0

            Connections {
                target: NixOnboarding
                function onOpenChanged() {
                    window.visible = NixOnboarding.open;
                    if (NixOnboarding.open) focusLater.restart();
                }
                function onMessagesChanged() { scrollLater.restart() }
                function onConfigChanged() { scrollLater.restart() }
            }
            onClosed: NixOnboarding.close()
            onVisibleChanged: if (!visible && NixOnboarding.open) NixOnboarding.close()
            Component.onCompleted: focusLater.restart()
            Timer {
                id: focusLater
                interval: 60
                onTriggered: input.forceActiveFocus()
            }
            Timer {
                id: scrollLater
                interval: 30
                onTriggered: flick.contentY = Math.max(0, flick.contentHeight - flick.height)
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 18
                spacing: 12

                // ── Header ──
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Rectangle {
                        implicitWidth: 40
                        implicitHeight: 40
                        radius: 20
                        gradient: Gradient {
                            GradientStop { position: 0; color: Appearance.colors.colPrimary }
                            GradientStop { position: 1; color: Appearance.m3colors.m3tertiary }
                        }
                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: "magic_button"
                            iconSize: 22
                            fill: 1
                            color: Appearance.colors.colOnPrimary
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        StyledText {
                            text: Translation.tr("Set up my desktop")
                            font.pixelSize: Appearance.font.pixelSize.larger
                            font.family: Appearance.font.family.title
                            color: root.fg
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: Translation.tr("Tell it how you work: it writes the Nix, and Nix checks it before you see it.")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: root.sub
                            elide: Text.ElideRight
                        }
                    }
                    Action {
                        glyph: "restart_alt"
                        label: Translation.tr("Start over")
                        onClicked: NixOnboarding.reset()
                    }
                }

                // ── The conversation and the configuration ──
                StyledFlickable {
                    id: flick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: column.implicitHeight
                    clip: true

                    ColumnLayout {
                        id: column
                        width: flick.width
                        spacing: 10

                        Repeater {
                            model: NixOnboarding.messages
                            delegate: Item {
                                id: line
                                required property var modelData
                                readonly property bool mine: modelData.role === "user"
                                readonly property bool note: ["check", "fix", "error"].includes(modelData.role)
                                Layout.fillWidth: true
                                visible: !modelData.hidden
                                implicitHeight: visible ? bubble.height : 0

                                Rectangle {
                                    id: bubble
                                    x: line.mine ? parent.width - width : 0
                                    width: Math.min(parent.width * (line.note ? 1 : 0.82), bubbleText.implicitWidth + 28)
                                    height: bubbleText.implicitHeight + 20
                                    radius: Appearance.rounding.normal
                                    color: line.mine ? Appearance.colors.colPrimaryContainer
                                        : line.modelData.role === "error" ? Appearance.m3colors.m3errorContainer
                                        : line.note ? "transparent" : Appearance.colors.colLayer1
                                    border.width: line.note && line.modelData.role !== "error" ? 1 : 0
                                    border.color: line.modelData.role === "check" && line.modelData.text.startsWith("✓")
                                        ? root.accent : Appearance.colors.colOutlineVariant
                                    StyledText {
                                        id: bubbleText
                                        x: 14
                                        y: 10
                                        width: Math.min(implicitWidth, (line.width * (line.note ? 1 : 0.82)) - 28)
                                        text: line.modelData.text
                                        wrapMode: Text.Wrap
                                        textFormat: line.note ? Text.PlainText : Text.MarkdownText
                                        font.family: line.note && line.modelData.role !== "fix" ? Appearance.font.family.monospace : Appearance.font.family.main
                                        font.pixelSize: line.note ? Appearance.font.pixelSize.smaller : Appearance.font.pixelSize.normal
                                        color: line.mine ? Appearance.colors.colOnPrimaryContainer
                                            : line.modelData.role === "error" ? Appearance.m3colors.m3onErrorContainer
                                            : line.note ? root.sub : root.fg
                                    }
                                }
                            }
                        }

                        // What runs now.
                        RowLayout {
                            Layout.fillWidth: true
                            visible: NixOnboarding.busy
                            spacing: 8
                            MaterialSymbol {
                                text: "progress_activity"
                                iconSize: 18
                                color: root.accent
                                RotationAnimation on rotation {
                                    running: NixOnboarding.busy && window.visible
                                    loops: Animation.Infinite
                                    from: 0
                                    to: 360
                                    duration: 900
                                }
                            }
                            StyledText {
                                Layout.fillWidth: true
                                text: NixOnboarding.status
                                color: root.sub
                                font.pixelSize: Appearance.font.pixelSize.small
                                elide: Text.ElideRight
                            }
                        }

                        // ── The configuration ──
                        Rectangle {
                            Layout.fillWidth: true
                            visible: NixOnboarding.config !== null
                            implicitHeight: configColumn.implicitHeight + 24
                            radius: Appearance.rounding.normal
                            color: Appearance.colors.colLayer1
                            border.width: 1
                            border.color: NixOnboarding.config?.checked ? root.accent : Appearance.m3colors.m3error

                            ColumnLayout {
                                id: configColumn
                                x: 12
                                y: 12
                                width: parent.width - 24
                                spacing: 10

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Rectangle {
                                        implicitHeight: 26
                                        implicitWidth: badgeRow.implicitWidth + 18
                                        radius: 13
                                        color: NixOnboarding.config?.checked ? root.accent : Appearance.m3colors.m3error
                                        Row {
                                            id: badgeRow
                                            anchors.centerIn: parent
                                            spacing: 4
                                            MaterialSymbol {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: NixOnboarding.config?.checked ? "verified" : "error"
                                                iconSize: 16
                                                fill: 1
                                                color: NixOnboarding.config?.checked ? Appearance.colors.colOnPrimary : Appearance.m3colors.m3onError
                                            }
                                            StyledText {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: NixOnboarding.config?.checked ? Translation.tr("Checked by Nix") : Translation.tr("Not passing the check")
                                                font.pixelSize: Appearance.font.pixelSize.smaller
                                                color: NixOnboarding.config?.checked ? Appearance.colors.colOnPrimary : Appearance.m3colors.m3onError
                                            }
                                        }
                                    }
                                    StyledText {
                                        Layout.fillWidth: true
                                        text: NixOnboarding.config?.where ?? ""
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: root.sub
                                        elide: Text.ElideMiddle
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: Math.min(code.implicitHeight + 20, 380)
                                    radius: Appearance.rounding.small
                                    color: Appearance.colors.colLayer0
                                    StyledFlickable {
                                        anchors.fill: parent
                                        anchors.margins: 10
                                        contentHeight: code.implicitHeight
                                        contentWidth: code.implicitWidth
                                        clip: true
                                        TextEdit {
                                            id: code
                                            text: NixOnboarding.config?.nix ?? ""
                                            readOnly: true
                                            selectByMouse: true
                                            color: root.fg
                                            selectionColor: Appearance.colors.colPrimary
                                            selectedTextColor: Appearance.colors.colOnPrimary
                                            font.family: Appearance.font.family.monospace
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                        }
                                    }
                                }

                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Action {
                                        main: true
                                        glyph: copied.running ? "check" : "content_copy"
                                        label: copied.running ? Translation.tr("Copied") : Translation.tr("Copy")
                                        onClicked: { NixOnboarding.copy(); copied.restart() }
                                        Timer { id: copied; interval: 1400 }
                                    }
                                    Action {
                                        visible: NixOnboarding.canBuild && (NixOnboarding.config?.checked ?? false)
                                        glyph: "construction"
                                        label: Translation.tr("Build it for me")
                                        onClicked: NixOnboarding.buildIt()
                                        StyledToolTip { text: Translation.tr("The desktop agent's fixer puts it in your configuration and opens a pull request") }
                                    }
                                    Action {
                                        visible: (NixOnboarding.config?.checked ?? false) && NixOnboarding.config?.settings
                                        glyph: "bolt"
                                        label: Translation.tr("Apply now")
                                        onClicked: NixOnboarding.applyNow()
                                        StyledToolTip { text: Translation.tr("Set the shell settings in the running shell now (not in your Nix files)") }
                                    }
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    visible: NixOnboarding.applied.length > 0
                                    text: NixOnboarding.applied
                                    wrapMode: Text.Wrap
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: root.sub
                                }
                            }
                        }
                    }
                }

                // ── The user's turn ──
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 44
                        radius: 22
                        color: Appearance.colors.colLayer1
                        border.width: input.activeFocus ? 1 : 0
                        border.color: root.accent
                        TextField {
                            id: input
                            anchors.fill: parent
                            anchors.leftMargin: 16
                            anchors.rightMargin: 16
                            background: null
                            color: root.fg
                            placeholderTextColor: root.sub
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.normal
                            enabled: !NixOnboarding.busy
                            placeholderText: NixOnboarding.config
                                ? Translation.tr("Change something… (\"also hide the dock\")")
                                : Translation.tr("Answer, or say how you want your desktop…")
                            onAccepted: {
                                NixOnboarding.send(text);
                                text = "";
                            }
                            Keys.onEscapePressed: NixOnboarding.close()
                        }
                    }
                    Action {
                        visible: !NixOnboarding.config
                        enabled: !NixOnboarding.busy && NixOnboarding.messages.length > 1
                        glyph: "auto_fix_high"
                        label: Translation.tr("Write it now")
                        onClicked: NixOnboarding.writeNow()
                    }
                }
            }
        }
    }
}
