pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

/**
 * The meeting companion's window (services/Meeting.qml): while Muse listens
 * to a call, a small floating card says so the whole time ("Listening to
 * the call", the time, Stop), with the last caption lines (the words being
 * said dimmer, a translation under a line in another language) and, opened
 * from its header, the running notes — after the call, its record with Add
 * tasks / Save as note / Draft follow-up. Dragged by its header (the place
 * remembered); clicks reach the call underneath everywhere but the header
 * and the open panel. Hidden while an agent's screenshot is taken.
 */
Scope {
    id: root

    PanelWindow {
        id: window
        visible: Meeting.shown && !GlobalStates.screenLocked
        screen: Quickshell.screens.find(s => s.name === Meeting.screenName) ?? Quickshell.screens[0] ?? null
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "quickshell:meetingCaptions"
        WlrLayershell.layer: WlrLayer.Overlay
        // The call keeps the keyboard.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        anchors { top: true; left: true }

        readonly property int pad: Appearance.sizes.elevationMargin
        implicitWidth: 560 + 2 * pad
        implicitHeight: card.implicitHeight + 2 * pad
        // Where it is: dragged (live), else remembered, else top centre.
        property real dragX: -1
        property real dragY: -1
        readonly property real screenW: window.screen?.width ?? 1920
        readonly property real screenH: window.screen?.height ?? 1080
        readonly property real savedX: Persistent.states.ai.meetingCaptionsX
        readonly property real savedY: Persistent.states.ai.meetingCaptionsY
        margins.left: Math.max(0, Math.min(window.screenW - window.implicitWidth,
            window.dragX >= 0 ? window.dragX : window.savedX >= 0 ? window.savedX : (window.screenW - window.implicitWidth) / 2))
        margins.top: Math.max(0, Math.min(window.screenH - window.implicitHeight,
            window.dragY >= 0 ? window.dragY : window.savedY >= 0 ? window.savedY : 56))

        // Clicks: the header and the open panel; none while an agent works
        // underneath (MakeWay).
        property Region noInput: Region {}
        property Region someInput: Region {
            item: header
            Region { item: panel.visible ? panel : null }
            Region { item: consent.visible ? consent : null }
        }
        mask: MakeWay.active ? window.noInput : window.someInput

        StyledRectangularShadow {
            target: card
        }
        Rectangle {
            id: card
            x: window.pad
            y: window.pad
            width: 560
            implicitHeight: content.implicitHeight + 20
            radius: Appearance.rounding.large
            color: Appearance.colors.colLayer0
            border.width: 1
            border.color: Appearance.colors.colLayer0Border
            opacity: MakeWay.fade(0.6, "meetingCaptions")

            ColumnLayout {
                id: content
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                spacing: 6

                // -- The header: what it does, the time, its buttons ------
                Item {
                    id: header
                    Layout.fillWidth: true
                    implicitHeight: headerRow.implicitHeight

                    MouseArea {
                        // The handle: dragging moves the window.
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        property real pressX: 0
                        property real pressY: 0
                        onPressed: (mouse) => {
                            pressX = mouse.x
                            pressY = mouse.y
                            window.dragX = window.margins.left
                            window.dragY = window.margins.top
                        }
                        onPositionChanged: (mouse) => {
                            if (!pressed) return
                            window.dragX = Math.max(0, window.dragX + mouse.x - pressX)
                            window.dragY = Math.max(0, window.dragY + mouse.y - pressY)
                        }
                        onReleased: {
                            Persistent.states.ai.meetingCaptionsX = window.margins.left
                            Persistent.states.ai.meetingCaptionsY = window.margins.top
                            window.dragX = -1
                            window.dragY = -1
                        }
                    }
                    RowLayout {
                        id: headerRow
                        anchors { left: parent.left; right: parent.right }
                        spacing: 8
                        // Recording: a red dot, breathing while it listens.
                        Rectangle {
                            implicitWidth: 10
                            implicitHeight: 10
                            radius: 5
                            color: Meeting.active ? Appearance.colors.colError : Appearance.colors.colSubtext
                            SequentialAnimation on opacity {
                                running: Meeting.active && window.visible
                                loops: Animation.Infinite
                                NumberAnimation { from: 1; to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                                NumberAnimation { from: 0.35; to: 1; duration: 900; easing.type: Easing.InOutSine }
                            }
                        }
                        StyledText {
                            // Where the audio goes, said while it goes there.
                            text: Meeting.active ? Translation.tr("Listening to the call · sent to Meta")
                                : Meeting.ending ? Translation.tr("Writing the summary…")
                                : Translation.tr("Call notes")
                            font.weight: Font.DemiBold
                            color: Appearance.colors.colOnLayer0
                        }
                        StyledText {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: [Meeting.summaryTitle || Meeting.title, Meeting.active ? Meeting.elapsed : ""].filter(x => x).join(" · ")
                            color: Appearance.colors.colSubtext
                            font.pixelSize: Appearance.font.pixelSize.small
                        }
                        HeaderButton {
                            visible: Meeting.active
                            symbol: Meeting.micOn ? "mic" : "mic_off"
                            on: Meeting.micOn
                            hint: Meeting.micOn ? Translation.tr("Your microphone is captioned (\"You\"): click to leave it out")
                                : Translation.tr("Caption your microphone too (\"You\")")
                            onClicked: Meeting.toggleMic()
                        }
                        HeaderButton {
                            visible: Meeting.active
                            symbol: "translate"
                            on: Meeting.translateOn
                            hint: Meeting.translateOn ? Translation.tr("Lines in another language are translated: click to stop")
                                : Translation.tr("Translate the lines in another language")
                            onClicked: Meeting.toggleTranslate()
                        }
                        HeaderButton {
                            symbol: Meeting.panelOpen ? "expand_less" : "notes"
                            on: Meeting.panelOpen
                            hint: Meeting.summary ? Translation.tr("The call's record") : Translation.tr("Running notes")
                            onClicked: Meeting.panelOpen = !Meeting.panelOpen
                        }
                        DialogButton {
                            visible: Meeting.active
                            buttonText: Translation.tr("Stop")
                            colEnabled: Appearance.colors.colError
                            onClicked: Meeting.stop()
                        }
                        HeaderButton {
                            visible: !Meeting.running
                            symbol: "close"
                            hint: Translation.tr("Close")
                            onClicked: Meeting.close()
                        }
                    }
                }

                // -- The first call: tell the others ------------------------
                RowLayout {
                    id: consent
                    Layout.fillWidth: true
                    visible: Meeting.active && Meeting.consentNeeded
                    spacing: 8
                    MaterialSymbol {
                        text: "campaign"
                        iconSize: Appearance.font.pixelSize.larger
                        color: Appearance.colors.colPrimary
                    }
                    StyledText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: Translation.tr("Tell the others you're taking AI notes. The transcript stays on this computer; what is sent to the model is masked.")
                        color: Appearance.colors.colOnLayer0
                        font.pixelSize: Appearance.font.pixelSize.small
                    }
                    DialogButton {
                        buttonText: Translation.tr("Got it")
                        onClicked: Meeting.consentSeen()
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: Meeting.error.length > 0 || Meeting.status.length > 0
                    wrapMode: Text.WordWrap
                    text: Meeting.error || Meeting.status
                    color: Meeting.error ? Appearance.colors.colError : Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.small
                }

                // -- The captions: the last lines, then what is being said --
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: Meeting.active || Meeting.ending
                    spacing: 4
                    Repeater {
                        model: Meeting.lines.slice(-3)
                        delegate: CaptionLine {
                            required property var modelData
                            who: modelData.who
                            said: modelData.text
                            translation: modelData.tr ?? ""
                        }
                    }
                    CaptionLine {
                        visible: Meeting.partialThem.length > 0
                        who: "them"
                        said: Meeting.partialThem
                        partial: true
                    }
                    CaptionLine {
                        visible: Meeting.partialYou.length > 0
                        who: "you"
                        said: Meeting.partialYou
                        partial: true
                    }
                    StyledText {
                        visible: Meeting.lines.length === 0 && Meeting.partialThem === "" && Meeting.partialYou === "" && Meeting.active
                        text: Translation.tr("Captions show here as people speak.")
                        color: Appearance.colors.colSubtext
                        font.italic: true
                        font.pixelSize: Appearance.font.pixelSize.small
                    }
                }

                // -- The notes, or the record after the call -----------------
                Rectangle {
                    id: panel
                    Layout.fillWidth: true
                    visible: Meeting.panelOpen
                    implicitHeight: Math.min(320, panelText.implicitHeight + (recordButtons.visible ? recordButtons.implicitHeight + 8 : 0) + 16)
                    radius: Appearance.rounding.normal
                    color: Appearance.colors.colLayer1
                    StyledFlickable {
                        id: flick
                        anchors { fill: parent; margins: 8 }
                        contentHeight: panelColumn.implicitHeight
                        contentWidth: width
                        flickableDirection: Flickable.VerticalFlick
                        clip: true
                        // A new record (or the notes replaced): from its top.
                        Connections {
                            target: Meeting
                            function onSummaryChanged() { flick.contentY = 0 }
                        }
                        ColumnLayout {
                            id: panelColumn
                            width: flick.width
                            spacing: 8
                            StyledText {
                                id: panelText
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                textFormat: Text.MarkdownText
                                color: Appearance.colors.colOnLayer1
                                font.pixelSize: Appearance.font.pixelSize.small
                                text: {
                                    if (Meeting.summary)
                                        return Meeting.recordText(Meeting.summary, Meeting.summaryTitle, "panel")
                                    const n = Meeting.notes
                                    if (!n) return Translation.tr("Notes come every %1 s or so as the call goes on.").arg(Config.options?.ai?.meeting?.notesEveryS ?? 75)
                                    const out = []
                                    const list = (label, items) => { if ((items ?? []).length > 0) out.push(`**${label}**\n` + items.map(x => `- ${x}`).join("\n")) }
                                    list(Translation.tr("Topics"), n.topics)
                                    list(Translation.tr("Decisions"), n.decisions)
                                    list(Translation.tr("Action items"), (n.actions ?? []).map(a => Meeting.actionText(a)))
                                    list(Translation.tr("Open questions"), n.questions)
                                    return out.join("\n\n") || Translation.tr("Nothing to note yet.")
                                }
                            }
                            Flow {
                                id: recordButtons
                                Layout.fillWidth: true
                                visible: Meeting.summary !== null && !(Meeting.summary?.empty ?? false)
                                spacing: 6
                                DialogButton {
                                    visible: (Meeting.summary?.actions ?? []).length > 0
                                    buttonText: Translation.tr("Add tasks")
                                    onClicked: Meeting.act({ what: "tasks" })
                                }
                                DialogButton {
                                    buttonText: Translation.tr("Save as note")
                                    onClicked: Meeting.act({ what: "note" })
                                }
                                DialogButton {
                                    visible: (Meeting.summary?.followup?.body ?? "").length > 0
                                    buttonText: Translation.tr("Draft follow-up")
                                    onClicked: Meeting.act({ what: "followup" })
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    component HeaderButton: RippleButton {
        id: button
        property string symbol
        property string hint
        property bool on: false
        implicitWidth: 30
        implicitHeight: 30
        buttonRadius: Appearance.rounding.full
        colBackground: button.on ? Appearance.colors.colSecondaryContainer : "transparent"
        colBackgroundHover: Appearance.colors.colLayer1Hover
        contentItem: MaterialSymbol {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            text: button.symbol
            iconSize: Appearance.font.pixelSize.larger
            color: button.on ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colSubtext
        }
        StyledToolTip {
            text: button.hint
        }
    }

    // A caption: "You" labelled, the others' words plain; the words still
    // being said dimmer; a translation under it.
    component CaptionLine: ColumnLayout {
        id: line
        property string who: "them"
        property string said: ""
        property string translation: ""
        property bool partial: false
        Layout.fillWidth: true
        spacing: 1
        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideLeft
            textFormat: Text.StyledText
            text: (line.who === "you" ? `<b>${Translation.tr("You")}:</b> ` : "") + StringUtils.escapeHtml(line.said)
            color: line.partial ? Appearance.colors.colSubtext : Appearance.colors.colOnLayer0
            font.pixelSize: Appearance.font.pixelSize.normal
        }
        StyledText {
            Layout.fillWidth: true
            visible: line.translation.length > 0
            wrapMode: Text.WordWrap
            text: line.translation
            color: Appearance.colors.colPrimary
            font.italic: true
            font.pixelSize: Appearance.font.pixelSize.small
        }
    }
}
