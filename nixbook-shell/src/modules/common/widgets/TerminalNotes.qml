import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

/**
 * Muse in the terminal (services/TerminalAccess.qml), in the bubble and the
 * side panel:
 *   - `approval`: a terminal_run waiting for the user's OK — the command in
 *     monospace and the folder it runs in, and where (Muse's kitty tab, or
 *     without a terminal); Allow / No are the place's own;
 *   - `message`: the commands Muse ran in that answer (its `terminalRuns`):
 *     "Ran `cmd` (exit N)" with Show output (the output's tail from the
 *     tool's result) and Muse's tab (focuses it, with runVisible); one not
 *     run (refused, the user said no) says why.
 * Colours from the place it is in, as AutonomyNotes.
 */
ColumnLayout {
    id: root
    property var message: null
    property var approval: null
    property color fg: Appearance.colors.colOnLayer1
    property color accent: Appearance.colors.colPrimary
    property color bg: Appearance.colors.colLayer1
    property string fontFamily: Appearance.font.family.main
    property bool square: false

    readonly property var pendingRun: TerminalAccess.runApproval(root.approval)
    readonly property var runs: root.message?.terminalRuns ?? []

    visible: root.pendingRun !== null || root.runs.length > 0
    spacing: 6

    component Link: StyledText {
        id: link
        signal clicked()
        font.family: root.fontFamily
        font.pixelSize: Appearance.font.pixelSize.smaller
        font.underline: true
        color: root.accent
        MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: link.clicked()
        }
    }

    // The command waiting for the user's OK.
    Rectangle {
        Layout.fillWidth: true
        visible: root.pendingRun !== null
        implicitHeight: askColumn.implicitHeight + 16
        radius: root.square ? 0 : 10
        color: Qt.alpha(root.accent, 0.10)
        border.color: Qt.alpha(root.accent, 0.5)
        border.width: 1
        ColumnLayout {
            id: askColumn
            anchors.fill: parent
            anchors.margins: 8
            spacing: 4
            RowLayout {
                spacing: 6
                MaterialSymbol {
                    text: "terminal"
                    iconSize: Appearance.font.pixelSize.normal
                    color: root.accent
                }
                StyledText {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: root.pendingRun?.visible ? Translation.tr("Muse wants to run, in its kitty tab:")
                        : Translation.tr("Muse wants to run, without a terminal:")
                    font.family: root.fontFamily
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.Bold
                    color: root.accent
                }
            }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: askCommand.implicitHeight + 10
                radius: root.square ? 0 : 6
                color: Qt.alpha(root.fg, 0.08)
                TextEdit {
                    id: askCommand
                    anchors.fill: parent
                    anchors.margins: 5
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.WrapAnywhere
                    textFormat: TextEdit.PlainText
                    text: root.pendingRun ? `$ ${root.pendingRun.command}` : ""
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: root.fg
                    selectionColor: Qt.alpha(root.accent, 0.4)
                }
            }
            StyledText {
                Layout.fillWidth: true
                visible: text.length > 0
                wrapMode: Text.WrapAnywhere
                textFormat: Text.PlainText
                text: root.pendingRun?.cwd ? Translation.tr("in %1").arg(root.pendingRun.cwd)
                    : root.pendingRun ? Translation.tr("in the folder of the terminal in front") : ""
                font.family: Appearance.font.family.monospace
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: root.fg
                opacity: 0.8
            }
        }
    }

    // The commands it ran.
    Repeater {
        model: root.runs
        delegate: ColumnLayout {
            id: run
            required property var modelData
            property bool expanded: false
            readonly property bool ran: run.modelData.exit !== null && run.modelData.exit !== undefined
            readonly property bool failed: run.ran && Number(run.modelData.exit) !== 0
            Layout.fillWidth: true
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                MaterialSymbol {
                    text: !run.ran ? "block" : run.failed ? "error" : "terminal"
                    iconSize: Appearance.font.pixelSize.normal
                    color: run.failed || !run.ran ? "#e5484d" : root.accent
                }
                StyledText {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    text: run.ran ? Translation.tr("Ran `%1` (exit %2)").arg(TerminalAccess.shortCommand(run.modelData.command, 60)).arg(run.modelData.exit)
                            + (run.modelData.duration >= 1 ? ` · ${Math.round(run.modelData.duration)} s` : "")
                        : Translation.tr("Didn't run `%1`: %2").arg(TerminalAccess.shortCommand(run.modelData.command, 50)).arg(run.modelData.error || Translation.tr("refused"))
                    font.family: root.fontFamily
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: root.fg
                    opacity: 0.85
                    HoverHandler { id: runHover }
                    StyledToolTip {
                        text: `$ ${run.modelData.command}${run.modelData.cwd ? `\n${Translation.tr("in %1").arg(run.modelData.cwd)}` : ""}`
                        extraVisibleCondition: runHover.hovered
                    }
                }
                Link {
                    visible: run.ran && String(run.modelData.output ?? "").length > 0
                    text: run.expanded ? Translation.tr("Hide output") : Translation.tr("Show output")
                    onClicked: run.expanded = !run.expanded
                }
                Link {
                    visible: run.ran && run.modelData.visible && TerminalAccess.runVisible
                    text: Translation.tr("Muse's tab")
                    onClicked: TerminalAccess.focusMuseTab()
                }
            }
            // The output's tail, as the tool gave it (redacted, capped).
            Rectangle {
                Layout.fillWidth: true
                visible: run.expanded
                implicitHeight: Math.min(outputText.implicitHeight, 220) + 10
                radius: root.square ? 0 : 6
                color: Qt.alpha(root.fg, 0.08)
                clip: true
                Flickable {
                    id: outputFlick
                    anchors.fill: parent
                    anchors.margins: 5
                    contentWidth: width
                    contentHeight: outputText.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    // The end first: the last lines are the ones that matter.
                    onContentHeightChanged: contentY = Math.max(0, contentHeight - height)
                    onVisibleChanged: if (visible) contentY = Math.max(0, contentHeight - height)
                    TextEdit {
                        id: outputText
                        width: outputFlick.width
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.WrapAnywhere
                        textFormat: TextEdit.PlainText
                        text: run.expanded ? String(run.modelData.output ?? "") : ""
                        font.family: Appearance.font.family.monospace
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: root.fg
                        selectionColor: Qt.alpha(root.accent, 0.4)
                    }
                }
            }
        }
    }
    StyledText {
        Layout.fillWidth: true
        visible: TerminalAccess.focusError.length > 0 && root.runs.length > 0
        text: `⚠ ${TerminalAccess.focusError}`
        font.family: root.fontFamily
        font.pixelSize: Appearance.font.pixelSize.smaller
        color: root.fg
        opacity: 0.7
    }
}
