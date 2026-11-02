import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

/**
 * "While you were away" (services/AwaySummary.qml): the card's ranked lines
 * under Muse's summary, as Kiroshi's brief: an urgency mark (NOW, SOON, or
 * none), what it is (a notification and its app, a calendar change, a
 * background task, a routine), its words, and its buttons: Open, Reply via
 * Muse for a message that can be answered (`acted(what, line)`: the bubble
 * hands it to Initiative.act). "+N more" when more were worth a look, and
 * how many were left out as noise. Colours from the place it is in, as
 * AutonomyNotes.
 */
ColumnLayout {
    id: root
    // `away summary`'s answer: {items, more, dropped, model…}.
    property var card: null
    property color fg: Appearance.colors.colOnLayer1
    property color accent: Appearance.colors.colPrimary
    property color bg: Appearance.colors.colLayer1
    property string fontFamily: Appearance.font.family.main
    property bool square: false
    signal acted(string what, var line)

    // Fixed meanings whatever the theme (as the report's).
    readonly property color red: "#e5484d"
    readonly property color yellow: "#d99a00"

    spacing: 4

    component Chip: Rectangle {
        id: chip
        property string label
        signal clicked()
        implicitWidth: chipText.implicitWidth + 16
        implicitHeight: 22
        radius: root.square ? 0 : 11
        color: chipMouse.containsMouse ? Qt.alpha(root.accent, 0.18) : "transparent"
        border.color: root.accent
        border.width: 1
        StyledText {
            id: chipText
            anchors.centerIn: parent
            text: chip.label
            font.family: root.fontFamily
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: root.fg
        }
        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }

    Repeater {
        model: root.card?.items ?? []
        delegate: Rectangle {
            id: line
            required property var modelData
            readonly property color mark: line.modelData.urgency === "now" ? root.red
                : line.modelData.urgency === "soon" ? root.yellow : Qt.alpha(root.fg, 0.35)
            Layout.fillWidth: true
            implicitHeight: lineRow.implicitHeight + 10
            radius: root.square ? 0 : Appearance.rounding.small
            color: Qt.alpha(root.fg, 0.05)
            RowLayout {
                id: lineRow
                anchors.fill: parent
                anchors.margins: 5
                spacing: 6
                Rectangle {
                    Layout.fillHeight: true
                    implicitWidth: 3
                    color: line.mark
                }
                MaterialSymbol {
                    Layout.alignment: Qt.AlignTop
                    text: line.modelData.kind === "calendar" ? "event"
                        : line.modelData.kind === "task" ? "task_alt"
                        : line.modelData.kind === "routine" ? "event_repeat"
                        : line.modelData.reply ? "chat" : "notifications"
                    iconSize: Appearance.font.pixelSize.normal
                    color: root.accent
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        StyledText {
                            visible: line.modelData.urgency !== "later"
                            text: line.modelData.urgency === "now" ? Translation.tr("NOW") : Translation.tr("SOON")
                            font.family: root.fontFamily
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            font.weight: Font.Bold
                            font.letterSpacing: 1.2
                            color: line.mark
                        }
                        StyledText {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: [line.modelData.app, line.modelData.title].filter(x => !!x).join(" · ")
                                + ((line.modelData.count ?? 1) > 1 ? ` (${line.modelData.count})` : "")
                            font.family: root.fontFamily
                            font.pixelSize: Appearance.font.pixelSize.small
                            font.weight: Font.Medium
                            color: root.fg
                        }
                    }
                    StyledText {
                        Layout.fillWidth: true
                        visible: text.length > 0
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        textFormat: Text.PlainText // a notification's words: third-party text
                        text: line.modelData.text ?? ""
                        font.family: root.fontFamily
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: root.fg
                        opacity: 0.8
                    }
                    Row {
                        spacing: 4
                        Chip {
                            label: Translation.tr("Open")
                            onClicked: root.acted("open", line.modelData)
                        }
                        Chip {
                            visible: AwaySummary.canReply(line.modelData)
                            label: Translation.tr("Reply via Muse")
                            onClicked: root.acted("reply", line.modelData)
                        }
                    }
                }
            }
        }
    }

    StyledText {
        Layout.fillWidth: true
        visible: text.length > 0
        wrapMode: Text.Wrap
        text: [(root.card?.more ?? 0) > 0 ? Translation.tr("+%1 more in the notification centre").arg(root.card.more) : "",
               (root.card?.dropped ?? 0) > 0 ? Translation.tr("%1 left out as noise").arg(root.card.dropped) : ""]
            .filter(x => x.length > 0).join(" · ")
        font.family: root.fontFamily
        font.pixelSize: Appearance.font.pixelSize.smaller
        color: root.fg
        opacity: 0.6
    }
}
