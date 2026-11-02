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
 * The reply batch's card (services/ReplyBatch.qml): an app window
 * (xdg-toplevel, like Settings) with each message waiting for an answer
 * and Muse's draft under it, editable: Send (or Copy & open for an app
 * taking no typed reply) / Skip. Nothing goes out without the Send click.
 */
Scope {
    id: root

    property bool everOpened: false
    Connections {
        target: ReplyBatch
        function onOpenChanged() { if (ReplyBatch.open) root.everOpened = true }
    }

    readonly property color fg: Appearance.m3colors.m3onSurface
    readonly property color sub: Appearance.colors.colSubtext
    readonly property color accent: Appearance.colors.colPrimary

    component Action: RippleButton {
        id: action
        property string glyph
        property string label
        property bool main: false
        implicitHeight: 32
        implicitWidth: actionRow.implicitWidth + 24
        buttonRadius: 16
        colBackground: action.main ? Appearance.colors.colPrimary : Appearance.colors.colLayer2
        colBackgroundHover: action.main ? Appearance.colors.colPrimaryHover : Appearance.colors.colLayer2Hover
        contentItem: Row {
            id: actionRow
            anchors.centerIn: parent
            spacing: 6
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: action.glyph
                iconSize: 16
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
            title: Translation.tr("Replies")
            visible: ReplyBatch.open
            implicitWidth: 620
            implicitHeight: 720
            minimumSize: Qt.size(420, 360)
            color: Appearance.colors.colLayer0

            Connections {
                target: ReplyBatch
                function onOpenChanged() { window.visible = ReplyBatch.open }
            }
            onClosed: ReplyBatch.close()
            onVisibleChanged: if (!visible && ReplyBatch.open) ReplyBatch.close()

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
                        color: Appearance.colors.colPrimary
                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: "quickreply"
                            iconSize: 22
                            fill: 1
                            color: Appearance.colors.colOnPrimary
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        StyledText {
                            text: ReplyBatch.items.length > 0 ? Translation.tr("Replies (%1)").arg(ReplyBatch.items.length) : Translation.tr("Replies")
                            font.pixelSize: Appearance.font.pixelSize.larger
                            font.family: Appearance.font.family.title
                            color: root.fg
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: Translation.tr("Muse drafted them: edit, then Send. Nothing goes out without your click.")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: root.sub
                            wrapMode: Text.WordWrap
                        }
                    }
                    Action {
                        glyph: "refresh"
                        label: Translation.tr("Draft again")
                        enabled: !ReplyBatch.busy
                        onClicked: ReplyBatch.redraft()
                    }
                }

                StyledIndeterminateProgressBar {
                    Layout.fillWidth: true
                    visible: ReplyBatch.busy
                }
                StyledText {
                    Layout.fillWidth: true
                    visible: ReplyBatch.busy || ReplyBatch.error.length > 0
                    text: ReplyBatch.busy ? Translation.tr("Reading the messages and drafting answers…") : ReplyBatch.error
                    color: root.sub
                    wrapMode: Text.WordWrap
                }

                StyledFlickable {
                    id: flick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentHeight: list.implicitHeight
                    ColumnLayout {
                        id: list
                        width: flick.width
                        spacing: 10
                        Repeater {
                            model: ReplyBatch.items
                            delegate: Rectangle {
                                id: card
                                required property var modelData
                                readonly property var st: ReplyBatch.stateOf(card.modelData.id)
                                readonly property bool finished: ["sent", "copied", "skipped"].includes(card.st.status)
                                Layout.fillWidth: true
                                implicitHeight: cardColumn.implicitHeight + 24
                                radius: Appearance.rounding.normal
                                color: Appearance.colors.colLayer1
                                opacity: card.finished ? 0.6 : 1
                                ColumnLayout {
                                    id: cardColumn
                                    anchors.fill: parent
                                    anchors.margins: 12
                                    spacing: 6
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        MaterialSymbol {
                                            visible: card.modelData.important === true || card.modelData.urgent === true
                                            text: card.modelData.urgent ? "priority_high" : "star"
                                            iconSize: 16
                                            color: root.accent
                                        }
                                        StyledText {
                                            Layout.fillWidth: true
                                            text: `${card.modelData.who}  ·  ${card.modelData.app}`
                                            font.weight: Font.DemiBold
                                            color: root.fg
                                            elide: Text.ElideRight
                                        }
                                    }
                                    StyledText {
                                        Layout.fillWidth: true
                                        text: card.modelData.text
                                        color: root.sub
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 4
                                        elide: Text.ElideRight
                                    }
                                    MaterialTextArea {
                                        id: draft
                                        Layout.fillWidth: true
                                        enabled: !card.finished && card.st.status !== "sending"
                                        text: card.modelData.draft ?? ""
                                        placeholderText: Translation.tr("Your answer…")
                                        wrapMode: TextEdit.Wrap
                                        font.pixelSize: Appearance.font.pixelSize.normal
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        StyledText {
                                            Layout.fillWidth: true
                                            text: card.st.status === "sent" ? Translation.tr("Sent")
                                                : card.st.status === "copied" ? Translation.tr("Copied: paste it in the conversation")
                                                : card.st.status === "skipped" ? Translation.tr("Skipped")
                                                : card.st.status === "sending" ? Translation.tr("Sending…")
                                                : card.st.status === "error" ? card.st.error
                                                : card.modelData.via === "discord" ? Translation.tr("Sent on Discord as you")
                                                : card.modelData.via === "open" ? Translation.tr("This app takes no typed reply: the draft is copied and the conversation opened")
                                                : ""
                                            color: card.st.status === "error" ? Appearance.m3colors.m3error : root.sub
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                            wrapMode: Text.WordWrap
                                        }
                                        Action {
                                            visible: !card.finished
                                            glyph: "skip_next"
                                            label: Translation.tr("Skip")
                                            onClicked: ReplyBatch.skip(card.modelData)
                                        }
                                        Action {
                                            visible: !card.finished
                                            glyph: "edit"
                                            label: Translation.tr("Edit")
                                            onClicked: draft.forceActiveFocus()
                                        }
                                        Action {
                                            visible: !card.finished
                                            main: true
                                            enabled: draft.text.trim().length > 0 && card.st.status !== "sending"
                                            glyph: card.modelData.via === "open" ? "content_copy" : "send"
                                            label: card.modelData.via === "open" ? Translation.tr("Copy & open") : Translation.tr("Send")
                                            onClicked: ReplyBatch.send(card.modelData, draft.text)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    StyledText {
                        Layout.fillWidth: true
                        visible: ReplyBatch.items.length > 0
                        text: ReplyBatch.left > 0 ? Translation.tr("%1 left").arg(ReplyBatch.left) : Translation.tr("All done")
                        color: root.sub
                    }
                    Action {
                        glyph: "close"
                        label: Translation.tr("Close")
                        onClicked: ReplyBatch.close()
                    }
                }
            }
        }
    }
}
