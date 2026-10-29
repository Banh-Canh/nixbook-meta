import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

/**
 * An order split into workers (plan and fan out: services/MuseTasks.qml,
 * `nixbook-muse-task fanout`), live from its task files: who planned it
 * (Muse Wonder), each part with its worker figure, its model and what it is
 * doing now, and — once they are all over — the merged answer (`showAnswer`:
 * the Muse tab; the bubble and the chat have it as their message). A part
 * clicked opens its task in the side panel's Muse tab. Colours from the
 * place it is in, as AutonomyNotes.
 */
ColumnLayout {
    id: root
    property string planId: ""
    property color fg: Appearance.colors.colOnLayer1
    property color accent: Appearance.colors.colPrimary
    property color bg: Appearance.colors.colLayer1
    property color bad: Appearance.colors.colError
    property string fontFamily: Appearance.font.family.main
    property bool square: false
    property bool showAnswer: false

    readonly property var plan: MuseTasks.byId[root.planId] ?? null
    readonly property bool busy: root.plan?.status === "running" && (root.plan?.phase === "planning" || root.plan?.phase === "merging")

    visible: root.plan !== null
    spacing: 4

    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        WorkerFigure {
            visible: root.busy
            figure: root.busy ? MuseTasks.figureFor(root.plan) : null
            tone: root.fg
            accent: root.accent
            bad: root.bad
            fontFamily: root.fontFamily
            size: Appearance.font.pixelSize.normal
        }
        MaterialSymbol {
            visible: !root.busy
            text: root.plan?.status === "done" ? "task_alt" : root.plan?.status === "failed" ? "error"
                : root.plan?.status === "stopped" ? "stop_circle" : "account_tree"
            iconSize: Appearance.font.pixelSize.normal
            color: root.plan?.status === "failed" ? root.bad : root.accent
        }
        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: {
                const p = root.plan;
                if (!p) return "";
                const n = (p.parts ?? []).length;
                const by = MuseTasks.modelName(p.plannerModel);
                if (p.phase === "planning") return by ? Translation.tr("%1 is splitting it up…").arg(by) : Translation.tr("Splitting it up…");
                const head = by ? Translation.tr("Planned by %1: %2 parts").arg(by).arg(n) : Translation.tr("%1 parts").arg(n);
                return `${head} · ${MuseTasks.statusText(p)}`;
            }
            font.family: root.fontFamily
            font.pixelSize: Appearance.font.pixelSize.smaller
            font.weight: Font.Medium
            color: root.fg
        }
    }

    // The merged answer, at the top once it is there (the Muse tab).
    StyledText {
        Layout.fillWidth: true
        visible: root.showAnswer && text.length > 0
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        maximumLineCount: 10
        elide: Text.ElideRight
        text: root.plan?.status === "done" ? String(root.plan.answer ?? "")
            : root.plan?.status === "failed" ? String(root.plan.error ?? "") : ""
        font.family: root.fontFamily
        font.pixelSize: Appearance.font.pixelSize.small
        color: root.plan?.status === "failed" ? root.bad : root.fg
    }

    Repeater {
        model: root.plan?.parts ?? []
        delegate: Rectangle {
            id: part
            required property var modelData
            required property int index
            readonly property var figure: MuseTasks.partFigure(root.plan, part.modelData)
            Layout.fillWidth: true
            implicitHeight: partRow.implicitHeight + 8
            radius: root.square ? 0 : Appearance.rounding.small
            color: partMouse.containsMouse && part.figure.task ? Qt.alpha(root.accent, 0.14) : Qt.alpha(root.fg, 0.05)
            border.width: MuseTasks.focusId !== "" && MuseTasks.focusId === part.figure.task ? 1 : 0
            border.color: root.accent
            MouseArea {
                id: partMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: part.figure.task ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (part.figure.task) MuseTasks.openTask(part.figure.task)
            }
            RowLayout {
                id: partRow
                anchors.fill: parent
                anchors.margins: 4
                spacing: 8
                WorkerFigure {
                    figure: part.figure
                    tone: root.fg
                    accent: root.accent
                    bad: root.bad
                    fontFamily: root.fontFamily
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: `${part.index + 1}. ${part.modelData.title ?? ""}`
                        font.family: root.fontFamily
                        font.pixelSize: Appearance.font.pixelSize.small
                        font.weight: Font.Medium
                        color: root.fg
                    }
                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: part.figure.doing ?? ""
                        font.family: root.fontFamily
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: part.figure.state === "slump" ? root.bad : root.fg
                        opacity: 0.75
                    }
                }
            }
        }
    }
}
