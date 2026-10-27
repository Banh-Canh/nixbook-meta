import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

/**
 * Under one of Muse's answers, in the bubble and the side panel
 * (services/Autonomy.qml):
 *   - a standing order it compiled (the standing_order tool): "When …, I'll
 *     …", what it still needs to know, and Turn on (the user's yes: `order
 *     accept`), Edit (Settings > Desktop agents > Routines), No;
 *   - what it did without asking, trusted to tell after: "Did: …" and Undo
 *     (the journal's);
 *   - a suggestion after three yeses in a row: "Stop asking before …?" —
 *     Yes raises that class to "tell" (`trust set`, the user's click),
 *     Not now leaves it.
 * Colours from the place it is in (the bubble's theme, the side panel's).
 */
ColumnLayout {
    id: root
    property var message: null
    property color fg: Appearance.colors.colOnLayer1
    property color accent: Appearance.colors.colPrimary
    property color bg: Appearance.colors.colLayer1
    property string fontFamily: Appearance.font.family.main
    property bool square: false

    readonly property var orders: Autonomy.orders ? (root.message?.orders ?? []) : []
    readonly property var told: root.message?.told ?? []
    readonly property var suggestions: Autonomy.trust
        ? (root.message?.trustSuggest ?? []).filter(s => !Autonomy.trustAnswered[s.class]) : []
    readonly property var answeredSuggestions: (root.message?.trustSuggest ?? []).filter(s => !!Autonomy.trustAnswered[s.class]
        && Autonomy.trustAnswered[s.class] !== "no")

    visible: root.orders.length > 0 || root.told.length > 0 || root.suggestions.length > 0 || root.answeredSuggestions.length > 0
    spacing: 6

    component Chip: Rectangle {
        id: chip
        property string label
        property bool main: false
        signal clicked()
        implicitWidth: chipText.implicitWidth + 20
        implicitHeight: 26
        radius: root.square ? 0 : 13
        color: chip.main ? (chipMouse.containsMouse ? Qt.lighter(root.accent, 1.1) : root.accent)
            : (chipMouse.containsMouse ? Qt.alpha(root.accent, 0.18) : "transparent")
        border.color: root.accent
        border.width: chip.main ? 0 : 1
        StyledText {
            id: chipText
            anchors.centerIn: parent
            text: chip.label
            font.family: root.fontFamily
            font.pixelSize: Appearance.font.pixelSize.small
            font.weight: chip.main ? Font.Bold : Font.Normal
            color: chip.main ? root.bg : root.fg
        }
        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }

    // Standing orders.
    Repeater {
        model: root.orders
        delegate: Rectangle {
            id: card
            required property var modelData
            readonly property string orderState: Autonomy.orderState[card.modelData.id] ?? ""
            readonly property bool needs: (card.modelData.questions ?? []).length > 0
            Layout.fillWidth: true
            implicitHeight: cardColumn.implicitHeight + 16
            radius: root.square ? 0 : 10
            color: Qt.alpha(root.accent, 0.10)
            border.color: Qt.alpha(root.accent, 0.5)
            border.width: 1
            ColumnLayout {
                id: cardColumn
                anchors.fill: parent
                anchors.margins: 8
                spacing: 4
                RowLayout {
                    spacing: 6
                    MaterialSymbol {
                        text: "event_repeat"
                        iconSize: Appearance.font.pixelSize.normal
                        color: root.accent
                    }
                    StyledText {
                        text: Translation.tr("STANDING ORDER")
                        font.family: root.fontFamily
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        font.weight: Font.Bold
                        font.letterSpacing: 1.2
                        color: root.accent
                    }
                }
                StyledText {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    text: card.modelData.summary
                    font.family: root.fontFamily
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: root.fg
                }
                Repeater {
                    model: card.modelData.questions ?? []
                    delegate: StyledText {
                        required property string modelData
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: `? ${modelData}`
                        font.family: root.fontFamily
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: root.fg
                        opacity: 0.85
                    }
                }
                StyledText {
                    Layout.fillWidth: true
                    visible: card.orderState.length > 0 && card.orderState !== "busy"
                    wrapMode: Text.Wrap
                    text: card.orderState === "on" ? Translation.tr("✓ On. It's in Settings > Desktop agents > Routines.")
                        : card.orderState === "declined" ? Translation.tr("Not kept.")
                        : card.orderState.replace(/^error: /, "⚠ ")
                    font.family: root.fontFamily
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: card.orderState.startsWith("error") ? "#e5484d" : root.fg
                    opacity: 0.85
                }
                Flow {
                    Layout.fillWidth: true
                    visible: card.orderState === "" || card.orderState.startsWith("error")
                    spacing: 6
                    Chip {
                        visible: !card.needs && card.modelData.id.length > 0
                        label: Translation.tr("Turn on")
                        main: true
                        onClicked: Autonomy.acceptOrder(card.modelData.id)
                    }
                    Chip {
                        label: Translation.tr("Edit")
                        onClicked: Autonomy.editOrders()
                    }
                    Chip {
                        visible: card.modelData.id.length > 0
                        label: Translation.tr("No")
                        onClicked: Autonomy.declineOrder(card.modelData.id)
                    }
                }
            }
        }
    }

    // What it did, trusted to tell after: Undo.
    Repeater {
        model: root.told
        delegate: RowLayout {
            id: did
            required property var modelData
            // Its journal entry: by id, else the latest with this class and words.
            readonly property var entry: did.modelData.id ? Autonomy.journal.find(e => e.id === did.modelData.id)
                : Autonomy.journal.find(e => e.class === did.modelData.class && (!did.modelData.summary || e.summary === did.modelData.summary))
            readonly property string undoState: did.entry ? (Autonomy.undoState[did.entry.id] ?? "") : ""
            Layout.fillWidth: true
            spacing: 8
            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                text: did.undoState === "done" ? Translation.tr("Undone: %1").arg(did.modelData.summary)
                    : did.undoState.startsWith("error") ? `${Translation.tr("Did: %1").arg(did.modelData.summary)} · ${did.undoState.replace(/^error: /, "")}`
                    : Translation.tr("Did: %1").arg(did.modelData.summary)
                font.family: root.fontFamily
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: root.fg
                opacity: 0.8
            }
            StyledText {
                visible: Autonomy.journalOn && did.undoState === "" && did.modelData.undo !== false
                    && (did.entry ? Autonomy.canUndo(did.entry) : true)
                text: Translation.tr("Undo")
                font.family: root.fontFamily
                font.pixelSize: Appearance.font.pixelSize.smaller
                font.underline: true
                color: root.accent
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (did.entry) Autonomy.undo(did.entry.id)
                        else Autonomy.undo(did.modelData.id)
                    }
                }
            }
        }
    }

    // Three yeses in a row: stop asking?
    Repeater {
        model: root.suggestions
        delegate: Flow {
            id: suggestion
            required property var modelData
            Layout.fillWidth: true
            spacing: 6
            Chip {
                label: Translation.tr("Stop asking before %1?").arg(suggestion.modelData.summary || suggestion.modelData.class)
                main: true
                onClicked: Autonomy.setTrust(suggestion.modelData.class, "tell")
            }
            Chip {
                label: Translation.tr("Keep asking")
                onClicked: Autonomy.declineSuggestion(suggestion.modelData.class)
            }
        }
    }
    Repeater {
        model: root.answeredSuggestions
        delegate: StyledText {
            required property var modelData
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: Autonomy.trustAnswered[modelData.class] === "error" ? Translation.tr("⚠ Couldn't change it (some actions always ask).")
                : Translation.tr("✓ I'll do it and tell you after (Settings > Desktop agents > Autonomy).")
            font.family: root.fontFamily
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: root.fg
            opacity: 0.8
        }
    }
}
