import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

/**
 * 👍 / 👎 under one of Muse's answers (services/AnswerFeedback.qml): the
 * thumbs (unless `showThumbs` is false: the side panel puts them in the
 * message's header), then for a 👎 a one-line "What did you mean?" field
 * (Enter saves the correction, Escape the 👎 alone), then "Ask again with
 * it". Hidden when ai.agent.feedback is off. Colours from the place it is
 * in (the bubble's theme, the side panel's).
 */
ColumnLayout {
    id: root
    property var chat: null
    property var message: null
    property string surface: "chat"
    property bool showThumbs: true
    property color fg: Appearance.colors.colOnLayer1
    property color accent: Appearance.colors.colPrimary
    property string fontFamily: Appearance.font.family.main
    readonly property string verdict: root.message?.feedback ?? ""

    visible: AnswerFeedback.rates(root.message)
        && (root.showThumbs || ["down", "corrected"].includes(root.verdict))
    spacing: 4

    RowLayout {
        visible: root.showThumbs
        spacing: 2
        Repeater {
            model: [
                { icon: "thumb_up", tip: Translation.tr("Good answer"), on: root.verdict === "up" },
                { icon: "thumb_down", tip: Translation.tr("Not what I meant"),
                  on: ["down", "corrected", "downSent", "retried"].includes(root.verdict) },
            ]
            delegate: Item {
                id: thumb
                required property var modelData
                required property int index
                implicitWidth: 24
                implicitHeight: 22
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: thumb.modelData.icon
                    fill: thumb.modelData.on ? 1 : 0
                    iconSize: Appearance.font.pixelSize.normal
                    color: thumb.modelData.on ? root.accent : root.fg
                    opacity: thumb.modelData.on || thumbMouse.containsMouse ? 1 : 0.55
                }
                MouseArea {
                    id: thumbMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (thumb.index === 0) AnswerFeedback.up(root.chat, root.message, root.surface);
                        else AnswerFeedback.down(root.chat, root.message);
                    }
                }
                StyledToolTip {
                    text: thumb.modelData.tip
                    extraVisibleCondition: thumbMouse.containsMouse
                }
            }
        }
    }

    // 👎: what they meant, in one line.
    Rectangle {
        Layout.fillWidth: true
        visible: root.verdict === "down"
        implicitHeight: 28
        radius: 6
        color: "transparent"
        border.width: 1
        border.color: Qt.alpha(root.accent, 0.7)
        onVisibleChanged: if (visible) correction.forceActiveFocus()
        StyledTextInput {
            id: correction
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            color: root.fg
            font.family: root.fontFamily
            Keys.onReturnPressed: event => {
                AnswerFeedback.correct(root.chat, root.message, root.surface, correction.text);
                correction.text = "";
                event.accepted = true;
            }
            Keys.onEnterPressed: event => {
                AnswerFeedback.correct(root.chat, root.message, root.surface, correction.text);
                correction.text = "";
                event.accepted = true;
            }
            Keys.onEscapePressed: event => {
                AnswerFeedback.correct(root.chat, root.message, root.surface, "");
                event.accepted = true;
            }
        }
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 8
            visible: correction.text.length === 0
            text: Translation.tr("What did you mean? (Enter)")
            font.family: root.fontFamily
            font.pixelSize: Appearance.font.pixelSize.small
            color: root.fg
            opacity: 0.5
        }
    }

    // Kept: asked again with it?
    RowLayout {
        visible: root.verdict === "corrected"
        spacing: 8
        StyledText {
            text: Translation.tr("Noted, I'll remember it.")
            font.family: root.fontFamily
            font.pixelSize: Appearance.font.pixelSize.small
            color: root.fg
            opacity: 0.75
        }
        StyledText {
            text: Translation.tr("Ask again with it")
            font.family: root.fontFamily
            font.pixelSize: Appearance.font.pixelSize.small
            font.underline: true
            color: root.accent
            MouseArea {
                anchors.fill: parent
                anchors.margins: -4
                cursorShape: Qt.PointingHandCursor
                onClicked: AnswerFeedback.retry(root.chat, root.message, root.surface)
            }
        }
    }
}
