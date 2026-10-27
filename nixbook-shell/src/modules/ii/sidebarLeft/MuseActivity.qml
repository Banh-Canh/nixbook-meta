import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/**
 * The side panel's Muse tab: what Muse does on its own.
 *   - Background tasks (services/MuseTasks.qml): each with its status and
 *     steps; Allow / No for a step waiting for the user's OK, a field to
 *     answer its question, Open (its session in the chat), Stop.
 *   - What Muse did (services/Autonomy.qml, the journal): by day, each with
 *     where it came from (a routine, a standing order, a task…) and Undo
 *     when it can be taken back.
 * `section`: "tasks" or "journal", scrolled to when asked for
 * (GlobalStates.museActivityRequested).
 */
Item {
    id: root
    property string section: "tasks"
    onSectionChanged: Qt.callLater(root.scrollToSection)
    function scrollToSection() {
        const target = root.section === "journal" ? journalHeader : tasksHeader
        flick.contentY = Math.max(0, Math.min(target.y, flick.contentHeight - flick.height))
    }
    Component.onCompleted: Autonomy.refreshJournal()

    function ago(seconds) {
        const s = Math.max(0, Math.round(Date.now() / 1000 - Number(seconds ?? 0)))
        if (s < 60) return Translation.tr("just now")
        if (s < 3600) return Translation.tr("%1 min ago").arg(Math.round(s / 60))
        if (s < 86400) return Translation.tr("%1 h ago").arg(Math.round(s / 3600))
        return Translation.tr("%1 d ago").arg(Math.round(s / 86400))
    }
    function sourceLabel(src) {
        return src === "routine" ? Translation.tr("routine") : src === "order" ? Translation.tr("standing order")
            : src === "reaction" ? Translation.tr("reaction") : src === "task" ? Translation.tr("background task")
            : src === "agent" ? Translation.tr("Muse") : String(src ?? "")
    }

    component SectionHeader: RowLayout {
        property string icon
        property string title
        property string detail
        Layout.fillWidth: true
        Layout.topMargin: 6
        spacing: 6
        MaterialSymbol {
            text: parent.icon
            iconSize: Appearance.font.pixelSize.larger
            color: Appearance.colors.colPrimary
        }
        StyledText {
            Layout.fillWidth: true
            text: parent.title
            font.pixelSize: Appearance.font.pixelSize.large
            font.weight: Font.Medium
            color: Appearance.colors.colOnLayer1
        }
        StyledText {
            text: parent.detail
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
        }
    }
    component SmallButton: RippleButton {
        id: smallButton
        property string label
        property bool main: false
        implicitHeight: 28
        implicitWidth: smallText.implicitWidth + 22
        buttonRadius: Appearance.rounding.full
        colBackground: smallButton.main ? Appearance.colors.colPrimary : Appearance.colors.colLayer2
        colBackgroundHover: smallButton.main ? Appearance.colors.colPrimaryHover : Appearance.colors.colLayer2Hover
        contentItem: StyledText {
            id: smallText
            anchors.centerIn: parent
            text: smallButton.label
            font.pixelSize: Appearance.font.pixelSize.small
            color: smallButton.main ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2
        }
    }

    StyledFlickable {
        id: flick
        anchors.fill: parent
        anchors.margins: 10
        contentHeight: content.implicitHeight
        clip: true

        ColumnLayout {
            id: content
            width: flick.width
            spacing: 8

            // -- background tasks --------------------------------------------
            SectionHeader {
                id: tasksHeader
                icon: "pending_actions"
                title: Translation.tr("Background tasks")
                detail: MuseTasks.activeCount > 0 ? Translation.tr("%1 on").arg(MuseTasks.activeCount) : ""
            }
            StyledText {
                Layout.fillWidth: true
                visible: MuseTasks.tasks.length === 0
                wrapMode: Text.Wrap
                text: MuseTasks.enabled
                    ? Translation.tr("None. Ask Muse to do something long \"in the background\", or use the bubble's \"Do it in the background\" while it works.")
                    : Translation.tr("Background tasks are off (Settings > Desktop agents > Autonomy).")
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colSubtext
            }
            Repeater {
                model: MuseTasks.tasks
                delegate: Rectangle {
                    id: task
                    required property var modelData
                    readonly property bool live: ["running", "waiting"].includes(task.modelData.status)
                    Layout.fillWidth: true
                    implicitHeight: taskColumn.implicitHeight + 16
                    radius: Appearance.rounding.small
                    color: task.modelData.status === "waiting" ? Appearance.colors.colSecondaryContainer : Appearance.colors.colLayer2
                    ColumnLayout {
                        id: taskColumn
                        anchors.fill: parent
                        anchors.margins: 8
                        spacing: 4
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            MaterialSymbol {
                                text: task.modelData.status === "running" ? "progress_activity"
                                    : task.modelData.status === "waiting" ? "front_hand"
                                    : task.modelData.status === "done" ? "check_circle"
                                    : task.modelData.status === "failed" ? "error" : "stop_circle"
                                iconSize: Appearance.font.pixelSize.normal
                                color: task.modelData.status === "failed" ? Appearance.colors.colError : Appearance.colors.colPrimary
                            }
                            StyledText {
                                text: MuseTasks.statusText(task.modelData)
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                font.weight: Font.Medium
                                color: Appearance.colors.colOnLayer2
                            }
                            Item { Layout.fillWidth: true }
                            StyledText {
                                text: root.ago(task.modelData.updated ?? task.modelData.started)
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colSubtext
                            }
                        }
                        StyledText {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            maximumLineCount: 4
                            elide: Text.ElideRight
                            text: task.modelData.text ?? ""
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colOnLayer2
                        }
                        // Its last steps.
                        Repeater {
                            model: (task.modelData.steps ?? []).slice(-4)
                            delegate: StyledText {
                                required property var modelData
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                                text: `${modelData.status === "error" ? "✗" : modelData.status === "run" ? "…" : "✓"} ${String(modelData.tool ?? "").replace(/_/g, " ")}${modelData.summary ? " · " + modelData.summary : ""}`
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colSubtext
                            }
                        }
                        // What it waits for: an OK, or an answer.
                        StyledText {
                            Layout.fillWidth: true
                            visible: text.length > 0
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: task.modelData.status !== "waiting" ? ""
                                : task.modelData.approval ? Translation.tr("Asks before: %1").arg(task.modelData.approval.summary || String(task.modelData.approval.tool ?? "").replace(/_/g, " "))
                                : String(task.modelData.question ?? "")
                            font.pixelSize: Appearance.font.pixelSize.small
                            font.weight: Font.Medium
                            color: Appearance.colors.colOnSecondaryContainer
                        }
                        // Its outcome.
                        StyledText {
                            Layout.fillWidth: true
                            visible: text.length > 0 && !task.live
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            maximumLineCount: 6
                            elide: Text.ElideRight
                            text: String(task.modelData.report?.summary ?? task.modelData.answer ?? task.modelData.error ?? "")
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: task.modelData.status === "failed" ? Appearance.colors.colError : Appearance.colors.colOnLayer2
                        }
                        // What it did trusted to tell after (Undo), stop asking before…?
                        AutonomyNotes {
                            Layout.fillWidth: true
                            visible: (task.modelData.told ?? []).length > 0 || (task.modelData.trustSuggest ?? []).length > 0
                            message: ({ orders: [], told: (task.modelData.told ?? []).slice(-3).map(t => Object.assign({}, t, { id: String(t.journal ?? t.id ?? "") })),
                                        trustSuggest: task.modelData.trustSuggest ?? [] })
                            fg: Appearance.colors.colOnLayer2
                            accent: Appearance.colors.colPrimary
                            bg: Appearance.colors.colLayer2
                        }
                        // A reply to its question.
                        Rectangle {
                            Layout.fillWidth: true
                            visible: task.modelData.status === "waiting" && !task.modelData.approval
                            implicitHeight: 30
                            radius: Appearance.rounding.small
                            color: Appearance.colors.colLayer1
                            StyledTextInput {
                                id: reply
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                verticalAlignment: TextInput.AlignVCenter
                                clip: true
                                color: Appearance.colors.colOnLayer1
                                onAccepted: {
                                    MuseTasks.answer(task.modelData, reply.text)
                                    reply.text = ""
                                }
                            }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                visible: reply.text.length === 0
                                text: Translation.tr("Your answer (Enter)")
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colSubtext
                            }
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 6
                            SmallButton {
                                visible: task.modelData.status === "waiting" && !!task.modelData.approval
                                main: true
                                label: Translation.tr("Allow")
                                onClicked: MuseTasks.approve(task.modelData, true)
                            }
                            SmallButton {
                                visible: task.modelData.status === "waiting" && !!task.modelData.approval
                                label: Translation.tr("No")
                                onClicked: MuseTasks.approve(task.modelData, false)
                            }
                            SmallButton {
                                label: Translation.tr("Open")
                                onClicked: MuseTasks.open(task.modelData)
                            }
                            SmallButton {
                                visible: task.live
                                label: Translation.tr("Stop")
                                onClicked: MuseTasks.stop(task.modelData)
                            }
                            SmallButton {
                                visible: task.modelData.status === "failed" || task.modelData.status === "stopped"
                                label: Translation.tr("Resume")
                                onClicked: MuseTasks.resume(task.modelData)
                            }
                        }
                    }
                }
            }
            SmallButton {
                visible: MuseTasks.tasks.some(t => !["running", "waiting"].includes(t.status))
                label: Translation.tr("Clear finished (older than a week)")
                onClicked: MuseTasks.clearFinished()
            }

            // -- what Muse did --------------------------------------------------
            SectionHeader {
                id: journalHeader
                icon: "history"
                title: Translation.tr("What Muse did")
                detail: Autonomy.journal.length > 0 ? Translation.tr("last 30 days") : ""
            }
            StyledText {
                Layout.fillWidth: true
                visible: Autonomy.journal.length === 0
                wrapMode: Text.Wrap
                text: Autonomy.journalOn
                    ? Translation.tr("Nothing yet. What Muse does without asking you first (routines, standing orders, steps you trust it with, background tasks) shows here, with Undo.")
                    : Translation.tr("The journal is off (Settings > Desktop agents > Autonomy).")
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colSubtext
            }
            Repeater {
                model: Autonomy.byDay
                delegate: ColumnLayout {
                    id: day
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 4
                    StyledText {
                        Layout.topMargin: 4
                        text: day.modelData.label
                        font.pixelSize: Appearance.font.pixelSize.small
                        font.weight: Font.Bold
                        color: Appearance.colors.colOnLayer1
                    }
                    Repeater {
                        model: day.modelData.entries
                        delegate: RowLayout {
                            id: entry
                            required property var modelData
                            readonly property string undoState: Autonomy.undoState[entry.modelData.id] ?? ""
                            Layout.fillWidth: true
                            spacing: 6
                            StyledText {
                                text: Qt.formatTime(new Date(entry.modelData.time * 1000), Config.options?.time?.format ?? "hh:mm")
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colSubtext
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                StyledText {
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                    textFormat: Text.PlainText
                                    text: String(entry.modelData.summary ?? entry.modelData.class ?? "")
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    font.strikeout: entry.modelData.undone === true || entry.undoState === "done"
                                    color: Appearance.colors.colOnLayer1
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                    text: [root.sourceLabel(entry.modelData.source),
                                           entry.modelData.undone === true || entry.undoState === "done" ? Translation.tr("undone") : "",
                                           entry.undoState.startsWith("error") ? entry.undoState.replace(/^error: /, "") : ""]
                                        .filter(s => s).join(" · ")
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: entry.undoState.startsWith("error") ? Appearance.colors.colError : Appearance.colors.colSubtext
                                }
                            }
                            SmallButton {
                                visible: Autonomy.canUndo(entry.modelData) && entry.undoState !== "busy"
                                label: Translation.tr("Undo")
                                onClicked: Autonomy.undo(entry.modelData.id)
                            }
                        }
                    }
                }
            }
        }
    }
}
