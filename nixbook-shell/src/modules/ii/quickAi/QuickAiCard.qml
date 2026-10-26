pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

/**
 * The Quick AI card (services/QuickAi.qml): at the top of the focused
 * screen, under the bar. What it is about (the selected text, the screen
 * region, the notification), the modes as chips, the answer typed out as
 * it comes (a pulsing orb while the model thinks), then Copy / Replace /
 * the suggested replies / Continue in chat, and a field to follow up.
 * Escape, a click outside or the key again closes it.
 */
Scope {
    id: root

    property bool everOpened: false
    // The card's buttons: an icon and a word, the main one filled.
    component Action: RippleButton {
        id: action
        property string glyph
        property string label
        property bool main: false
        implicitHeight: 32
        implicitWidth: actionRow.implicitWidth + 24
        buttonRadius: 16
        colBackground: action.main ? Appearance.colors.colPrimary : Appearance.colors.colLayer1
        colBackgroundHover: action.main ? Appearance.colors.colPrimaryHover : Appearance.colors.colLayer1Hover
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
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: action.main ? Appearance.colors.colOnPrimary : root.fg
            }
        }
    }

    readonly property color bg: Appearance.m3colors.m3surfaceContainerLow
    readonly property color fg: Appearance.m3colors.m3onSurface
    readonly property color accent: Appearance.colors.colPrimary
    readonly property color accent2: Appearance.m3colors.m3tertiary
    readonly property color sub: Appearance.colors.colSubtext
    Connections {
        target: QuickAi
        function onOpenChanged() { if (QuickAi.open) root.everOpened = true }
    }

    Loader {
        active: root.everOpened
        sourceComponent: PanelWindow {
            id: window
            visible: QuickAi.open && !GlobalStates.screenLocked
            screen: Quickshell.screens.find(s => s.name === WM.focusedMonitor?.name) ?? Quickshell.screens[0]

            WlrLayershell.namespace: "quickshell:quickAi"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: window.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            // Top only: centred horizontally by the compositor.
            anchors.top: true
            readonly property bool barTop: !(Config.options.bar.bottom ?? false) && !(Config.options.bar.vertical ?? false)
            margins.top: window.barTop ? Appearance.sizes.barHeight + 8 : 16
            implicitWidth: card.width + 40
            implicitHeight: card.height + 40
            mask: Region { item: card }

            onVisibleChanged: {
                if (visible) {
                    GlobalFocusGrab.addDismissable(window);
                    focusLater.restart();
                } else {
                    GlobalFocusGrab.removeDismissable(window);
                    input.text = "";
                }
            }
            Connections {
                target: GlobalFocusGrab
                function onDismissed() {
                    if (!GlobalFocusGrab.spares(window)) QuickAi.close();
                }
            }
            Timer {
                id: focusLater
                interval: 40
                onTriggered: input.forceActiveFocus()
            }
            Connections {
                target: QuickAi
                // A new answer: typed out from the start.
                function onRevisionChanged() { body.shown = 0 }
            }


            StyledRectangularShadow { target: card }

            Rectangle {
                id: card
                x: 20
                y: 20
                width: Math.min(640, (window.screen?.width ?? 1200) - 80)
                height: Math.min(content.implicitHeight + 28, (window.screen?.height ?? 900) * 0.72)
                radius: Appearance.rounding.large
                color: root.bg
                border.width: 1
                border.color: QuickAi.busy ? Qt.alpha(root.accent, 0.35 + 0.35 * glow.v) : Appearance.colors.colLayer0Border
                clip: true

                // Slides down and fades in.
                opacity: 0
                transform: Translate { id: slide; y: -14 }
                Component.onCompleted: enter.restart()
                Connections {
                    target: window
                    function onVisibleChanged() { if (window.visible) enter.restart() }
                }
                ParallelAnimation {
                    id: enter
                    NumberAnimation { target: card; property: "opacity"; from: 0; to: 1; duration: 180; easing.type: Easing.OutCubic }
                    NumberAnimation { target: slide; property: "y"; from: -14; to: 0; duration: 320; easing.type: Easing.OutBack }
                }

                // A glow sweeping under the header while it thinks.
                QtObject {
                    id: glow
                    property real v: 0
                }
                SequentialAnimation {
                    running: QuickAi.busy && window.visible
                    loops: Animation.Infinite
                    NumberAnimation { target: glow; property: "v"; from: 0; to: 1; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { target: glow; property: "v"; from: 1; to: 0; duration: 700; easing.type: Easing.InOutSine }
                }
                Rectangle {
                    id: sweep
                    visible: QuickAi.busy
                    height: 2
                    width: card.width * 0.35
                    y: header.y + header.height + 10
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: "transparent" }
                        GradientStop { position: 0.5; color: root.accent }
                        GradientStop { position: 1; color: "transparent" }
                    }
                    NumberAnimation on x {
                        running: QuickAi.busy && window.visible
                        loops: Animation.Infinite
                        from: -card.width * 0.35
                        to: card.width
                        duration: 1100
                        easing.type: Easing.InOutQuad
                    }
                }

                Keys.onEscapePressed: (Voice.listening || Voice.transcribing) ? Voice.cancel() : QuickAi.close()

                StyledFlickable {
                    id: scroller
                    anchors.fill: parent
                    anchors.margins: 14
                    contentHeight: content.implicitHeight
                    clip: true
                    // Follows the answer while it is typed.
                    // (Once the card has grown to it: scrolling first left the
                    // header out of view.)
                    onContentHeightChanged: if (QuickAi.busy || body.typing) Qt.callLater(scroller.follow)
                    function follow() { scroller.contentY = Math.max(0, scroller.contentHeight - scroller.height) }

                    ColumnLayout {
                        id: content
                        width: scroller.width
                        spacing: 10

                        // ── Header: the orb, what it is about, the model ──
                        RowLayout {
                            id: header
                            Layout.fillWidth: true
                            spacing: 10

                            Item {
                                implicitWidth: 34
                                implicitHeight: 34
                                Rectangle {
                                    id: orb
                                    anchors.centerIn: parent
                                    width: 30
                                    height: 30
                                    radius: 15
                                    scale: QuickAi.busy ? 0.9 + 0.18 * glow.v : 1
                                    gradient: Gradient {
                                        GradientStop { position: 0; color: root.accent }
                                        GradientStop { position: 1; color: root.accent2 }
                                    }
                                    MaterialSymbol {
                                        anchors.centerIn: parent
                                        text: QuickAi.error.length > 0 ? "error" : "auto_awesome"
                                        iconSize: 18
                                        fill: 1
                                        color: Appearance.colors.colOnPrimary
                                        rotation: QuickAi.busy ? 360 * glow.v : 0
                                    }
                                }
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 30 + 14 * glow.v
                                    height: width
                                    radius: width / 2
                                    color: "transparent"
                                    border.width: 2
                                    border.color: Qt.alpha(root.accent, 0.5 * (1 - glow.v))
                                    visible: QuickAi.busy
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                StyledText {
                                    Layout.fillWidth: true
                                    text: QuickAi.sourceLabel
                                    font.pixelSize: Appearance.font.pixelSize.normal
                                    font.weight: Font.DemiBold
                                    color: root.fg
                                    elide: Text.ElideRight
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    text: {
                                        const who = QuickAi.provider ? `${QuickAi.provider}${QuickAi.model ? " · " + QuickAi.model : ""}` : Translation.tr("Quick AI");
                                        if (QuickAi.busy) return Translation.tr("%1 is thinking… %2 s").arg(who).arg((ticker.now - QuickAi.startedAt) / 1000 > 0 ? ((ticker.now - QuickAi.startedAt) / 1000).toFixed(1) : "0.0");
                                        if (QuickAi.lastMs > 0 && QuickAi.answer.length > 0) return `${who} · ${(QuickAi.lastMs / 1000).toFixed(1)} s`;
                                        return who;
                                    }
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: root.sub
                                    elide: Text.ElideRight
                                }
                                Timer {
                                    id: ticker
                                    property real now: Date.now()
                                    interval: 100
                                    repeat: true
                                    running: QuickAi.busy && window.visible
                                    onTriggered: now = Date.now()
                                }
                            }
                            RippleButton {
                                implicitWidth: 30
                                implicitHeight: 30
                                buttonRadius: 15
                                onClicked: QuickAi.close()
                                contentItem: MaterialSymbol { anchors.centerIn: parent; text: "close"; iconSize: 18; color: root.sub }
                                StyledToolTip { text: Translation.tr("Close (Esc)") }
                            }
                        }

                        // ── What it is about ──
                        Rectangle {
                            Layout.fillWidth: true
                            // The selected text, else what was asked or ordered
                            // (by voice, from Kiroshi, the launcher).
                            readonly property string shown: QuickAi.source?.text || (QuickAi.mode === "do" ? QuickAi.firstQuestion : "")
                            visible: shown.length > 0
                            implicitHeight: quote.implicitHeight + 16
                            radius: Appearance.rounding.small
                            color: Appearance.colors.colLayer1
                            Rectangle { width: 3; height: parent.height - 12; x: 6; y: 6; radius: 2; color: root.accent }
                            StyledText {
                                id: quote
                                x: 18
                                y: 8
                                width: parent.width - 28
                                text: parent.shown
                                maximumLineCount: 3
                                elide: Text.ElideRight
                                wrapMode: Text.Wrap
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: root.sub
                            }
                        }
                        Image {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.maximumWidth: content.width
                            Layout.preferredHeight: Math.min(160, implicitHeight)
                            visible: (QuickAi.source?.image ?? "").length > 0
                            source: visible ? "file://" + QuickAi.source.image : ""
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            cache: false
                        }

                        // ── The modes ──
                        Flow {
                            Layout.fillWidth: true
                            visible: QuickAi.modes.length > 0
                            spacing: 6
                            Repeater {
                                model: QuickAi.modes
                                delegate: RippleButton {
                                    id: chip
                                    required property string modelData
                                    required property int index
                                    readonly property bool current: QuickAi.mode === chip.modelData
                                    implicitHeight: 30
                                    implicitWidth: chipRow.implicitWidth + 22
                                    buttonRadius: 15
                                    toggled: chip.current
                                    colBackground: Appearance.colors.colLayer1
                                    onClicked: QuickAi.run(chip.modelData)
                                    contentItem: Row {
                                        id: chipRow
                                        anchors.centerIn: parent
                                        spacing: 5
                                        MaterialSymbol {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: QuickAi.modeInfo[chip.modelData]?.icon ?? ""
                                            iconSize: 16
                                            color: chip.current ? Appearance.colors.colOnPrimary : root.fg
                                        }
                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: QuickAi.modeInfo[chip.modelData]?.label ?? chip.modelData
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                            color: chip.current ? Appearance.colors.colOnPrimary : root.fg
                                        }
                                    }
                                    StyledToolTip { text: `Ctrl+${chip.index + 1}` }
                                }
                            }
                        }

                        // ── The voice (services/Voice.qml): listening, a live meter ──
                        RowLayout {
                            Layout.fillWidth: true
                            visible: Voice.listening || Voice.transcribing || (Voice.error.length > 0 && QuickAi.source?.kind === "voice" && !QuickAi.busy && QuickAi.answer.length === 0)
                            spacing: 10
                            MaterialSymbol {
                                text: Voice.transcribing ? "graphic_eq" : Voice.listening ? "mic" : "mic_off"
                                iconSize: 22
                                fill: 1
                                color: Voice.listening ? Appearance.m3colors.m3error : root.accent
                            }
                            // Bars following the microphone's level.
                            Row {
                                visible: Voice.listening
                                spacing: 3
                                Layout.alignment: Qt.AlignVCenter
                                Repeater {
                                    model: 12
                                    delegate: Rectangle {
                                        required property int index
                                        // A little wave: the middle bars taller.
                                        readonly property real shape: 1 - Math.abs(index - 5.5) / 7
                                        width: 4
                                        radius: 2
                                        height: 4 + 22 * Math.min(1, Voice.level * (0.6 + shape))
                                        anchors.verticalCenter: parent?.verticalCenter
                                        color: Voice.heard ? root.accent : root.sub
                                        Behavior on height { NumberAnimation { duration: 70 } }
                                    }
                                }
                            }
                            StyledText {
                                Layout.fillWidth: true
                                text: Voice.transcribing ? Translation.tr("Transcribing…")
                                    : Voice.listening ? (Voice.heard ? (Voice.engine === "meta" ? Translation.tr("Listening… (stop talking to send, Esc to cancel)") : Translation.tr("Listening… (pause to send, Esc to cancel)"))
                                        : Translation.tr("Listening… speak now"))
                                    : Voice.error
                                elide: Text.ElideRight
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Voice.listening || Voice.transcribing ? root.fg : root.sub
                            }
                        }
                        // Meta: the words as they are recognised.
                        StyledText {
                            Layout.fillWidth: true
                            visible: (Voice.listening || Voice.transcribing) && Voice.partial.length > 0
                            text: "“" + Voice.partial + "”"
                            wrapMode: Text.Wrap
                            font.pixelSize: Appearance.font.pixelSize.larger
                            font.italic: true
                            color: root.fg
                        }

                        // ── The answer ──
                        Item {
                            Layout.fillWidth: true
                            visible: QuickAi.busy && QuickAi.answer.length === 0
                            implicitHeight: 26
                            Row {
                                spacing: 6
                                anchors.verticalCenter: parent.verticalCenter
                                Repeater {
                                    model: 3
                                    delegate: Rectangle {
                                        required property int index
                                        width: 8
                                        height: 8
                                        radius: 4
                                        color: root.accent
                                        opacity: 0.3
                                        SequentialAnimation on opacity {
                                            running: QuickAi.busy && window.visible
                                            loops: Animation.Infinite
                                            PauseAnimation { duration: index * 160 }
                                            NumberAnimation { to: 1; duration: 300 }
                                            NumberAnimation { to: 0.3; duration: 300 }
                                            PauseAnimation { duration: (2 - index) * 160 }
                                        }
                                    }
                                }
                            }
                        }

                        // ── Doing things: the steps as they happen ──
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: QuickAi.steps.length > 0 || QuickAi.notes.length > 0
                            spacing: 4
                            Repeater {
                                model: QuickAi.notes
                                delegate: StyledText {
                                    required property string modelData
                                    Layout.fillWidth: true
                                    text: modelData
                                    wrapMode: Text.Wrap
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    font.italic: true
                                    color: root.sub
                                }
                            }
                            Repeater {
                                model: QuickAi.steps
                                delegate: RowLayout {
                                    id: stepRow
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Item {
                                        implicitWidth: 18
                                        implicitHeight: 18
                                        MaterialSymbol {
                                            anchors.centerIn: parent
                                            text: ({ run: "progress_activity", ok: "check_circle", error: "error", denied: "block" })[stepRow.modelData.status] ?? "radio_button_unchecked"
                                            iconSize: 17
                                            fill: 1
                                            color: stepRow.modelData.status === "ok" ? root.accent
                                                : stepRow.modelData.status === "error" ? Appearance.m3colors.m3error : root.sub
                                            RotationAnimation on rotation {
                                                running: stepRow.modelData.status === "run" && window.visible
                                                loops: Animation.Infinite
                                                from: 0
                                                to: 360
                                                duration: 900
                                            }
                                        }
                                    }
                                    StyledText {
                                        Layout.fillWidth: true
                                        text: `<b>${stepRow.modelData.tool.replace(/_/g, " ")}</b>${stepRow.modelData.summary ? "  ·  " + stepRow.modelData.summary : ""}`
                                        textFormat: Text.StyledText
                                        elide: Text.ElideRight
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: root.fg
                                    }
                                }
                            }
                        }
                        // A step waiting for the user's OK.
                        Rectangle {
                            Layout.fillWidth: true
                            visible: QuickAi.pending !== null
                            implicitHeight: approveRow.implicitHeight + 16
                            radius: Appearance.rounding.small
                            color: Appearance.colors.colTertiaryContainer
                            RowLayout {
                                id: approveRow
                                anchors.fill: parent
                                anchors.margins: 8
                                spacing: 8
                                MaterialSymbol { text: "shield_question"; iconSize: 20; color: Appearance.colors.colOnTertiaryContainer }
                                StyledText {
                                    Layout.fillWidth: true
                                    text: Translation.tr("Allow <b>%1</b>%2?").arg((QuickAi.pending?.tool ?? "").replace(/_/g, " "))
                                        .arg(QuickAi.pending?.summary ? " (" + QuickAi.pending.summary + ")" : "")
                                    textFormat: Text.StyledText
                                    wrapMode: Text.Wrap
                                    color: Appearance.colors.colOnTertiaryContainer
                                }
                                Action { glyph: "check"; label: Translation.tr("Allow"); main: true; onClicked: QuickAi.approve(true) }
                                Action { glyph: "close"; label: Translation.tr("No"); onClicked: QuickAi.approve(false) }
                            }
                        }
                        // Desktop control paused: allowed again from here.
                        Rectangle {
                            Layout.fillWidth: true
                            visible: QuickAi.paused && !QuickAi.busy
                            implicitHeight: pausedRow.implicitHeight + 16
                            radius: Appearance.rounding.small
                            color: Appearance.colors.colLayer1
                            RowLayout {
                                id: pausedRow
                                anchors.fill: parent
                                anchors.margins: 8
                                MaterialSymbol { text: "back_hand"; iconSize: 20; color: root.fg }
                                StyledText {
                                    Layout.fillWidth: true
                                    text: Translation.tr("Desktop control is paused (Mod+Shift+Escape).")
                                    wrapMode: Text.Wrap
                                    color: root.fg
                                }
                                Action { glyph: "play_arrow"; label: Translation.tr("Allow and retry"); main: true; onClicked: QuickAi.allowControl() }
                            }
                        }

                        // The conversation before the current answer.
                        Repeater {
                            model: QuickAi.turns
                            delegate: StyledText {
                                required property var modelData
                                Layout.fillWidth: true
                                text: modelData.role === "user" ? "› " + modelData.text : modelData.text
                                wrapMode: Text.Wrap
                                textFormat: modelData.role === "user" ? Text.PlainText : Text.MarkdownText
                                font.weight: modelData.role === "user" ? Font.DemiBold : Font.Normal
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: modelData.role === "user" ? root.accent : root.sub
                            }
                        }

                        TextEdit {
                            id: body
                            Layout.fillWidth: true
                            visible: QuickAi.answer.length > 0
                            // Typed out (ai.quick.typewriter): the model sends its
                            // answer at once, the card reveals it ~1800 chars/s.
                            property int shown: 0
                            readonly property bool typing: body.shown < QuickAi.answer.length
                            readonly property bool typewriter: Config.options.ai.quick?.typewriter ?? true
                            text: body.typewriter ? QuickAi.answer.slice(0, body.shown) : QuickAi.answer
                            textFormat: TextEdit.MarkdownText
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.Wrap
                            color: root.fg
                            selectionColor: Appearance.colors.colPrimary
                            selectedTextColor: Appearance.colors.colOnPrimary
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.normal
                            onLinkActivated: (link) => AppLaunch.openUrl(link)
                            Timer {
                                interval: 16
                                repeat: true
                                running: body.typing && body.typewriter && window.visible
                                onTriggered: body.shown = Math.min(QuickAi.answer.length, body.shown + Math.max(6, Math.ceil(QuickAi.answer.length / 90)))
                            }
                        }

                        StyledText {
                            Layout.fillWidth: true
                            visible: QuickAi.error.length > 0
                            text: QuickAi.error
                            wrapMode: Text.Wrap
                            color: Appearance.m3colors.m3error
                            font.pixelSize: Appearance.font.pixelSize.small
                        }

                        // ── Suggested replies ──
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: QuickAi.replies.length > 0
                            spacing: 6
                            StyledText {
                                text: QuickAi.source?.inline ? Translation.tr("Send a reply:") : Translation.tr("Copy a reply:")
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: root.sub
                            }
                            Repeater {
                                model: QuickAi.replies
                                delegate: RippleButton {
                                    id: replyButton
                                    required property string modelData
                                    required property int index
                                    Layout.fillWidth: true
                                    implicitHeight: replyText.implicitHeight + 16
                                    buttonRadius: Appearance.rounding.small
                                    colBackground: Appearance.colors.colSecondaryContainer
                                    onClicked: QuickAi.sendReply(replyButton.modelData)
                                    contentItem: RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 12
                                        anchors.rightMargin: 12
                                        StyledText {
                                            id: replyText
                                            Layout.fillWidth: true
                                            text: replyButton.modelData
                                            wrapMode: Text.Wrap
                                            color: Appearance.colors.colOnSecondaryContainer
                                        }
                                        MaterialSymbol {
                                            text: QuickAi.source?.inline ? "send" : "content_copy"
                                            iconSize: 16
                                            color: Appearance.colors.colOnSecondaryContainer
                                        }
                                    }
                                    StyledToolTip { text: `Alt+${replyButton.index + 1}` }
                                }
                            }
                        }

                        // ── Actions ──
                        RowLayout {
                            Layout.fillWidth: true
                            visible: !QuickAi.busy && (QuickAi.answer.length > 0 || QuickAi.error.length > 0 || QuickAi.replies.length > 0)
                            spacing: 6
                            Action {
                                visible: QuickAi.canReplace
                                main: true
                                glyph: "find_replace"
                                label: Translation.tr("Replace")
                                onClicked: QuickAi.replace()
                                StyledToolTip { text: Translation.tr("Type it over the selection (Ctrl+Enter)") }
                            }
                            Action {
                                visible: QuickAi.answer.length > 0
                                main: !QuickAi.canReplace
                                glyph: copied.running ? "check" : "content_copy"
                                label: copied.running ? Translation.tr("Copied") : Translation.tr("Copy")
                                onClicked: { QuickAi.copy(); copied.restart() }
                                Timer { id: copied; interval: 1400 }
                                StyledToolTip { text: Translation.tr("Copy the answer (Ctrl+C)") }
                            }
                            Action {
                                glyph: "refresh"
                                label: Translation.tr("Retry")
                                onClicked: QuickAi.retry()
                            }
                            Action {
                                visible: Ai.claudeCodePath.length > 0
                                glyph: "open_in_new"
                                label: Translation.tr("Continue in chat")
                                onClicked: QuickAi.continueInChat()
                                StyledToolTip { text: Translation.tr("Go further in the side panel, with the desktop tools") }
                            }
                            Item { Layout.fillWidth: true }
                        }

                        // ── Follow up ──
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 40
                            radius: 20
                            color: Appearance.colors.colLayer1
                            border.width: input.activeFocus ? 1 : 0
                            border.color: root.accent
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                anchors.rightMargin: 6
                                spacing: 6
                                TextField {
                                    id: input
                                    Layout.fillWidth: true
                                    background: null
                                    color: root.fg
                                    placeholderTextColor: root.sub
                                    font.family: Appearance.font.family.main
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    placeholderText: QuickAi.busy ? Translation.tr("Working on it…")
                                        : QuickAi.answer.length > 0 || QuickAi.turns.length > 0 || QuickAi.steps.length > 0
                                        ? Translation.tr("Ask a follow-up…")
                                        : QuickAi.mode === "do" ? Translation.tr("Say or type what to do… (Mod+T to talk)")
                                        : Translation.tr("Ask anything…")
                                    onAccepted: {
                                        QuickAi.followUp(text);
                                        text = "";
                                    }
                                    Keys.onEscapePressed: (Voice.listening || Voice.transcribing) ? Voice.cancel() : QuickAi.close()
                                    Keys.onPressed: (event) => {
                                        const ctrl = event.modifiers & Qt.ControlModifier;
                                        const alt = event.modifiers & Qt.AltModifier;
                                        const n = event.key - Qt.Key_1;
                                        if (QuickAi.pending && input.text.length === 0
                                                && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                                            QuickAi.approve(true);
                                            event.accepted = true;
                                        } else if (ctrl && n >= 0 && n < QuickAi.modes.length) {
                                            QuickAi.run(QuickAi.modes[n]);
                                            event.accepted = true;
                                        } else if (alt && n >= 0 && n < QuickAi.replies.length) {
                                            QuickAi.sendReply(QuickAi.replies[n]);
                                            event.accepted = true;
                                        } else if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && QuickAi.canReplace) {
                                            QuickAi.replace();
                                            event.accepted = true;
                                        } else if (ctrl && event.key === Qt.Key_C && input.selectedText.length === 0 && body.selectedText.length === 0) {
                                            QuickAi.copy();
                                            event.accepted = true;
                                        }
                                    }
                                }
                                RippleButton {
                                    visible: Voice.available
                                    implicitWidth: 30
                                    implicitHeight: 30
                                    buttonRadius: 15
                                    colBackground: Voice.listening ? Appearance.m3colors.m3error : "transparent"
                                    onClicked: Voice.toggle()
                                    contentItem: MaterialSymbol {
                                        anchors.centerIn: parent
                                        text: Voice.listening ? "stop" : "mic"
                                        iconSize: 18
                                        fill: Voice.listening ? 1 : 0
                                        color: Voice.listening ? Appearance.m3colors.m3onError : root.sub
                                    }
                                    StyledToolTip { text: Voice.listening ? Translation.tr("Stop and send (Mod+T)") : Translation.tr("Talk (Mod+T)") }
                                }
                                RippleButton {
                                    implicitWidth: 30
                                    implicitHeight: 30
                                    buttonRadius: 15
                                    enabled: input.text.trim().length > 0
                                    colBackground: input.text.trim().length > 0 ? root.accent : "transparent"
                                    onClicked: input.accepted()
                                    contentItem: MaterialSymbol {
                                        anchors.centerIn: parent
                                        text: "arrow_upward"
                                        iconSize: 18
                                        color: input.text.trim().length > 0 ? Appearance.colors.colOnPrimary : root.sub
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
