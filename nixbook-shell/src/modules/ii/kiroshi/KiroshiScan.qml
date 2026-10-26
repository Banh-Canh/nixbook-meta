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
 * The Kiroshi scan overlay (services/Kiroshi.qml): over the scanned screen,
 * a scan sweep while the model looks, then a brief at the top (what the
 * user is doing, the one thing that matters now, "Handle the routine ones")
 * and the things that matter in corner brackets coloured by urgency (noise
 * dimmed), each with a small tag (number, label, urgency, its gist). A
 * click on a box or tag, or its number key, opens its card: the substance,
 * what the agent would do (the plan as a checklist, the draft to edit) and
 * Do it / Copy draft / Tell me more. Enter does it, Esc closes the card
 * then the overlay. The Cyberpunk theme's colours and font when it is on,
 * else Kiroshi yellow / cyan / red that read on any wallpaper. Nothing
 * animates once the scan is done.
 */
Scope {
    id: root

    readonly property color yellow: Cyberpunk.enabled ? Cyberpunk.accent : "#fcee0a"
    readonly property color cyan: Cyberpunk.enabled ? Cyberpunk.glitchColor : "#02d7f2"
    readonly property color red: Cyberpunk.enabled ? Cyberpunk.alertColor : "#ff2a6d"
    readonly property color ink: Cyberpunk.enabled ? Cyberpunk.ink : "#f2f0e3"
    readonly property color panel: Cyberpunk.enabled ? Cyberpunk.panel : "#0b0b0d"
    readonly property color grey: "#8a8a92"
    readonly property string font: Cyberpunk.enabled ? Cyberpunk.font : Appearance.font.family.title
    readonly property string mono: Appearance.font.family.monospace
    readonly property string body: Appearance.font.family.main

    function urgencyColor(u) {
        return u === "now" ? root.red : u === "soon" ? root.yellow : u === "later" ? root.cyan : root.grey;
    }
    function urgencyText(u) {
        return u === "now" ? Translation.tr("NOW") : u === "soon" ? Translation.tr("SOON")
            : u === "later" ? Translation.tr("LATER") : Translation.tr("NOISE");
    }

    // A flat button in the overlay's look.
    component KButton: Rectangle {
        id: kb
        signal clicked()
        property string text
        property color tint: root.yellow
        property bool main: false
        property bool active: true
        implicitWidth: kbText.implicitWidth + 24
        implicitHeight: kbText.implicitHeight + 12
        opacity: kb.active ? 1 : 0.4
        color: kb.main || kbMouse.containsMouse && kb.active ? kb.tint : "transparent"
        border.width: 1
        border.color: kb.tint
        Text {
            id: kbText
            anchors.centerIn: parent
            text: kb.text
            font.family: root.body
            font.pixelSize: 13
            font.weight: Font.DemiBold
            color: kb.main || kbMouse.containsMouse && kb.active ? root.panel : kb.tint
        }
        MouseArea {
            id: kbMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: kb.active ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: if (kb.active) kb.clicked()
        }
    }

    Loader {
        active: Kiroshi.open
        sourceComponent: PanelWindow {
            id: window
            screen: Quickshell.screens.find(s => s.name === Kiroshi.screenName) ?? Quickshell.screens[0]
            visible: !GlobalStates.screenLocked
            WlrLayershell.namespace: "quickshell:kiroshi"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            anchors { top: true; bottom: true; left: true; right: true }

            readonly property real sx: Kiroshi.imageWidth > 0 ? window.width / Kiroshi.imageWidth : 1
            readonly property real sy: Kiroshi.imageHeight > 0 ? window.height / Kiroshi.imageHeight : 1
            readonly property bool looking: !Kiroshi.itemsIn && Kiroshi.scanning

            // Where each tag goes, so none covers another (nor the brief): each
            // wants its spot by its box (in the items' order, the most
            // important first) and is pushed under, else beside, whatever it
            // would overlap. Run once the tags know their sizes.
            property var tagSizes: ({})
            property var tagSpots: ({})
            property rect briefRect: Qt.rect(0, 0, 0, 0)
            function tagWants(i, w, h) {
                const b = Kiroshi.items[i]?.box ?? [0, 0, 0, 0];
                const bx = b[0] * window.sx, by = b[1] * window.sy, bh = b[3] * window.sy;
                const x = Math.max(8, Math.min(bx + 6, window.width - w - 8));
                if (bh > h + 40) return { x: x, y: Math.max(8, by + 8) };
                const above = by > h + 16 && by + bh + h + 12 > window.height;
                return { x: x, y: above ? by - h - 6 : Math.min(window.height - h - 8, by + bh + 6) };
            }
            function placeTags() {
                const placed = [];
                if (window.briefRect.width > 0) placed.push({ x: window.briefRect.x, y: window.briefRect.y,
                    w: window.briefRect.width, h: window.briefRect.height });
                const spots = {};
                const hit = (a, r) => a.x < r.x + r.w + 4 && r.x < a.x + a.w + 4 && a.y < r.y + r.h + 4 && r.y < a.y + a.h + 4;
                for (let i = 0; i < Kiroshi.items.length; i++) {
                    const size = window.tagSizes[i];
                    if (!size) continue;
                    const want = window.tagWants(i, size.w, size.h);
                    const a = { x: want.x, y: want.y, w: size.w, h: size.h };
                    for (let tries = 0; tries < 16; tries++) {
                        const r = placed.find(r => hit(a, r));
                        if (!r) break;
                        if (r.y + r.h + 6 + a.h <= window.height - 8) a.y = r.y + r.h + 6;
                        else if (r.x + r.w + 6 + a.w <= window.width - 8) { a.x = r.x + r.w + 6; a.y = want.y; }
                        else if (r.x - a.w - 6 >= 8) { a.x = r.x - a.w - 6; a.y = want.y; }
                        else break;
                    }
                    placed.push(a);
                    spots[i] = { x: a.x, y: a.y };
                }
                window.tagSpots = spots;
            }
            function tagSized(i, w, h) {
                const old = window.tagSizes[i];
                if (old && old.w === w && old.h === h) return;
                window.tagSizes[i] = { w: w, h: h };
                Qt.callLater(window.placeTags);
            }
            Connections {
                target: Kiroshi
                function onItemsInChanged() {
                    window.tagSizes = {};
                    window.tagSpots = {};
                }
            }

            Item {
                id: content
                anchors.fill: parent
                focus: true
                Component.onCompleted: forceActiveFocus()
                Keys.onEscapePressed: {
                    if (Kiroshi.expanded >= 0) Kiroshi.expand(-1);
                    else Kiroshi.close();
                }
                Keys.onPressed: (event) => {
                    const n = event.key - Qt.Key_1;
                    if (n >= 0 && n < 8 && n < Kiroshi.items.length) {
                        Kiroshi.expand(n);
                        content.forceActiveFocus();
                        event.accepted = true;
                    } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && Kiroshi.expanded >= 0) {
                        card.doIt();
                        event.accepted = true;
                    }
                }

                // A click on the screen, not on a label: the card closes, then the overlay.
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (Kiroshi.expanded >= 0) Kiroshi.expand(-1);
                        else Kiroshi.close();
                    }
                }

                // The optics' tint.
                Rectangle {
                    anchors.fill: parent
                    color: Qt.alpha(root.panel, Kiroshi.expanded >= 0 ? 0.45 : Kiroshi.itemsIn ? 0.32 : 0.22)
                    Behavior on color { ColorAnimation { duration: 250 } }
                }

                // Scanlines (drawn once) while it looks.
                Canvas {
                    anchors.fill: parent
                    opacity: window.looking ? 0.5 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 250 } }
                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        ctx.fillStyle = Qt.alpha(root.cyan, 0.08);
                        for (let y = 0; y < height; y += 4) ctx.fillRect(0, y, width, 1);
                    }
                }

                // The sweep.
                Rectangle {
                    visible: window.looking
                    width: parent.width
                    height: 90
                    gradient: Gradient {
                        GradientStop { position: 0; color: "transparent" }
                        GradientStop { position: 0.85; color: Qt.alpha(root.cyan, 0.16) }
                        GradientStop { position: 1; color: Qt.alpha(root.cyan, 0.55) }
                    }
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 2
                        color: root.cyan
                    }
                    NumberAnimation on y {
                        running: window.looking
                        loops: Animation.Infinite
                        from: -90
                        to: window.height
                        duration: 1600
                        easing.type: Easing.InOutSine
                    }
                }

                // The screen's corners.
                Repeater {
                    model: 4
                    delegate: Item {
                        id: corner
                        required property int index
                        readonly property bool atRight: index % 2 === 1
                        readonly property bool atBottom: index >= 2
                        width: 60
                        height: 60
                        x: atRight ? window.width - width - 24 : 24
                        y: atBottom ? window.height - height - 24 : 24
                        Rectangle { width: 60; height: 3; color: root.yellow; y: corner.atBottom ? 57 : 0 }
                        Rectangle { width: 3; height: 60; color: root.yellow; x: corner.atRight ? 57 : 0 }
                    }
                }

                // ── While it looks: SCANNING, glitched ──
                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: parent.height * 0.45
                    visible: window.looking
                    width: scanLabel.implicitWidth
                    height: scanLabel.implicitHeight + 40
                    property real jitter: 0
                    Timer {
                        interval: 90
                        repeat: true
                        running: window.looking
                        onTriggered: parent.jitter = Math.random() < 0.3 ? (Math.random() - 0.5) * 10 : 0
                    }
                    Text {
                        x: parent.jitter + 3
                        text: scanLabel.text
                        font: scanLabel.font
                        color: Qt.alpha(root.red, 0.8)
                        visible: parent.jitter !== 0
                    }
                    Text {
                        x: -parent.jitter - 3
                        text: scanLabel.text
                        font: scanLabel.font
                        color: Qt.alpha(root.cyan, 0.8)
                        visible: parent.jitter !== 0
                    }
                    Text {
                        id: scanLabel
                        text: "SCANNING…"
                        font.family: root.font
                        font.pixelSize: 54
                        font.weight: Font.Black
                        font.letterSpacing: 6
                        color: root.yellow
                    }
                    Text {
                        anchors.top: scanLabel.bottom
                        anchors.topMargin: 6
                        anchors.horizontalCenter: scanLabel.horizontalCenter
                        text: `${Kiroshi.provider ? Kiroshi.provider.toUpperCase() + " · " + Kiroshi.model : "KIROSHI OPTICS"}  ·  ${((elapsed.now - Kiroshi.startedAt) / 1000).toFixed(1)} S`
                        font.family: root.mono
                        font.pixelSize: 15
                        color: root.cyan
                        Timer {
                            id: elapsed
                            property real now: Date.now()
                            interval: 100
                            repeat: true
                            running: window.looking
                            onTriggered: now = Date.now()
                        }
                    }
                }

                // ── What it found: boxes and tags ──
                Repeater {
                    // By count: an item's details coming in updates its delegate
                    // instead of rebuilding them all.
                    model: Kiroshi.itemsIn ? Kiroshi.items.length : 0
                    delegate: Item {
                        id: mark
                        required property int index
                        readonly property var modelData: Kiroshi.items[mark.index] ?? ({ box: [0, 0, 8, 8] })
                        readonly property color col: root.urgencyColor(modelData.urgency)
                        readonly property bool noise: modelData.urgency === "noise"
                        readonly property bool open: Kiroshi.expanded === mark.index
                        readonly property bool dimmed: Kiroshi.expanded >= 0 && !mark.open
                        readonly property real bx: modelData.box[0] * window.sx
                        readonly property real by: modelData.box[1] * window.sy
                        readonly property real bw: modelData.box[2] * window.sx
                        readonly property real bh: modelData.box[3] * window.sy
                        anchors.fill: parent
                        z: mark.open ? 5 : 1

                        opacity: 0
                        readonly property real rest: mark.dimmed ? 0.25 : mark.noise ? 0.55 : 1
                        Component.onCompleted: appear.start()
                        SequentialAnimation {
                            id: appear
                            PauseAnimation { duration: mark.index * 70 }
                            NumberAnimation { target: mark; property: "opacity"; to: mark.rest; duration: 180; easing.type: Easing.OutCubic }
                        }
                        onRestChanged: if (!appear.running) mark.opacity = mark.rest
                        Behavior on opacity { enabled: !appear.running; NumberAnimation { duration: 160 } }

                        // The box: a faint fill, corner brackets; a click opens the card.
                        Rectangle {
                            x: mark.bx
                            y: mark.by
                            width: mark.bw
                            height: mark.bh
                            color: Qt.alpha(mark.col, mark.open ? 0.12 : 0.06)
                            border.width: mark.open ? 2 : 1
                            border.color: Qt.alpha(mark.col, mark.open ? 0.9 : 0.35)
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Kiroshi.expand(mark.index)
                            }
                            Repeater {
                                model: 4
                                delegate: Item {
                                    id: bracket
                                    required property int index
                                    readonly property bool atRight: index % 2 === 1
                                    readonly property bool atBottom: index >= 2
                                    readonly property real len: Math.min(22, parent.width / 3, parent.height / 3)
                                    x: atRight ? parent.width - len : 0
                                    y: atBottom ? parent.height - len : 0
                                    width: len
                                    height: len
                                    Rectangle { width: bracket.len; height: 3; color: mark.col; y: bracket.atBottom ? bracket.len - 3 : 0 }
                                    Rectangle { width: 3; height: bracket.len; color: mark.col; x: bracket.atRight ? bracket.len - 3 : 0 }
                                }
                            }
                        }

                        // The tag: number, label, urgency, the gist on one line.
                        Rectangle {
                            id: tag
                            readonly property var spot: window.tagSpots[mark.index] ?? window.tagWants(mark.index, tag.width, tag.height)
                            x: tag.spot.x
                            y: tag.spot.y
                            width: 290
                            height: tagColumn.implicitHeight + 14
                            onHeightChanged: window.tagSized(mark.index, tag.width, tag.height)
                            Component.onCompleted: window.tagSized(mark.index, tag.width, tag.height)
                            color: Qt.alpha(root.panel, 0.92)
                            border.width: 1
                            border.color: mark.col
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Kiroshi.expand(mark.index)
                            }
                            Rectangle { width: 4; height: parent.height; color: mark.col }
                            ColumnLayout {
                                id: tagColumn
                                x: 12
                                y: 7
                                width: tag.width - 20
                                spacing: 3
                                RowLayout {
                                    spacing: 7
                                    Rectangle {
                                        implicitWidth: 20
                                        implicitHeight: 20
                                        color: mark.col
                                        Text {
                                            anchors.centerIn: parent
                                            text: mark.index + 1
                                            font.family: root.mono
                                            font.pixelSize: 12
                                            font.weight: Font.Bold
                                            color: root.panel
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: mark.modelData.label
                                        font.family: root.font
                                        font.pixelSize: 15
                                        font.weight: Font.Bold
                                        color: root.ink
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        text: root.urgencyText(mark.modelData.urgency)
                                        font.family: root.mono
                                        font.pixelSize: 10
                                        font.letterSpacing: 1.5
                                        color: mark.col
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: mark.modelData.gist || mark.modelData.detail || ""
                                    visible: text.length > 0
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                    font.family: root.body
                                    font.pixelSize: 12
                                    color: Qt.alpha(root.ink, 0.75)
                                }
                                Text {
                                    text: mark.modelData.pending ? Translation.tr("▸ reading…")
                                        : mark.modelData.handle ? "▸ " + mark.modelData.handle.title : ""
                                    visible: text.length > 0
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    font.family: root.mono
                                    font.pixelSize: 11
                                    color: mark.modelData.pending ? root.grey : mark.col
                                }
                            }
                        }
                    }
                }

                // ── The brief, on top ──
                Rectangle {
                    id: brief
                    visible: Kiroshi.briefIn || Kiroshi.itemsIn || Kiroshi.error.length > 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 30
                    z: 4
                    width: Math.min(parent.width - 240, 760)
                    height: briefColumn.implicitHeight + 24
                    color: Qt.alpha(root.panel, 0.95)
                    border.width: 1
                    border.color: Kiroshi.error.length > 0 && Kiroshi.items.length === 0 ? root.red : root.yellow
                    onVisibleChanged: report()
                    onHeightChanged: report()
                    onWidthChanged: report()
                    function report() {
                        window.briefRect = brief.visible ? Qt.rect(brief.x, brief.y, brief.width, brief.height) : Qt.rect(0, 0, 0, 0);
                        Qt.callLater(window.placeTags);
                    }
                    MouseArea { anchors.fill: parent }
                    Rectangle { width: 4; height: parent.height; color: root.yellow }
                    ColumnLayout {
                        id: briefColumn
                        x: 20
                        y: 12
                        width: brief.width - 36
                        spacing: 6
                        Text {
                            text: `KIROSHI  ·  ${Kiroshi.provider ? Kiroshi.provider.toUpperCase() + " " + Kiroshi.model : ""}`
                                + (Kiroshi.itemsIn ? `  ·  ${Kiroshi.items.length} ${Translation.tr("FOUND")}` : "")
                                + (Kiroshi.scanning ? (Kiroshi.itemsIn ? `  ·  ${Translation.tr("READING")} ${Kiroshi.items.filter(i => !i.pending).length}/${Kiroshi.items.length}` : `  ·  ${Translation.tr("LOOKING")}`)
                                    : `  ·  ${(Kiroshi.lastMs / 1000).toFixed(1)} S`)
                            font.family: root.mono
                            font.pixelSize: 11
                            font.letterSpacing: 1
                            color: root.cyan
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            visible: Kiroshi.focus.length > 0
                            spacing: 10
                            Text {
                                Layout.alignment: Qt.AlignTop
                                text: Translation.tr("FOCUS")
                                font.family: root.mono
                                font.pixelSize: 11
                                font.letterSpacing: 2
                                topPadding: 4
                                color: root.red
                            }
                            Text {
                                Layout.fillWidth: true
                                text: Kiroshi.focus
                                wrapMode: Text.Wrap
                                font.family: root.font
                                font.pixelSize: 19
                                font.weight: Font.Bold
                                color: root.ink
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            visible: Kiroshi.doing.length > 0
                            spacing: 10
                            Text {
                                text: Translation.tr("DOING")
                                font.family: root.mono
                                font.pixelSize: 11
                                font.letterSpacing: 2
                                color: root.cyan
                            }
                            Text {
                                Layout.fillWidth: true
                                text: Kiroshi.doing
                                wrapMode: Text.Wrap
                                font.family: root.body
                                font.pixelSize: 14
                                color: Qt.alpha(root.ink, 0.85)
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: Kiroshi.error.length > 0
                            text: Kiroshi.error
                            wrapMode: Text.Wrap
                            font.family: root.body
                            font.pixelSize: 13
                            color: root.red
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            visible: Kiroshi.itemsIn
                            spacing: 8
                            KButton {
                                visible: Kiroshi.routine.length > 0 && (Kiroshi.scanning || Kiroshi.routineReady.length > 0)
                                active: Kiroshi.routineReady.length > 0
                                main: true
                                text: Kiroshi.routineReady.length > 0
                                    ? Translation.tr("Handle the routine ones (%1)").arg(Kiroshi.routineReady.length)
                                    : Translation.tr("Routine ones (%1): reading…").arg(Kiroshi.routine.length)
                                onClicked: Kiroshi.handleRoutine()
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: Translation.tr("1–%1 open · Enter do it · Esc").arg(Math.max(1, Kiroshi.items.length))
                                font.family: root.mono
                                font.pixelSize: 11
                                color: root.grey
                            }
                        }
                    }
                }

                // ── The open item's card ──
                Rectangle {
                    id: card
                    readonly property var it: Kiroshi.expanded >= 0 ? Kiroshi.items[Kiroshi.expanded] ?? null : null
                    readonly property color col: root.urgencyColor(card.it?.urgency ?? "later")
                    readonly property var handle: card.it?.handle ?? null
                    visible: card.it !== null
                    z: 10
                    width: Math.min(500, window.width - 32)
                    height: cardColumn.implicitHeight + 28
                    // Beside the box: right of it if it fits, else left, else under the brief.
                    readonly property real bx: (card.it?.box[0] ?? 0) * window.sx
                    readonly property real by: (card.it?.box[1] ?? 0) * window.sy
                    readonly property real bw: (card.it?.box[2] ?? 0) * window.sx
                    x: card.bx + card.bw + 16 + card.width <= window.width - 16 ? card.bx + card.bw + 16
                        : card.bx - card.width - 16 >= 16 ? card.bx - card.width - 16
                        : (window.width - card.width) / 2
                    y: Math.max(brief.visible ? brief.y + brief.height + 12 : 16, Math.min(card.by, window.height - card.height - 16))
                    color: Qt.alpha(root.panel, 0.97)
                    border.width: 1
                    border.color: card.col
                    MouseArea { anchors.fill: parent }
                    Rectangle { width: 4; height: parent.height; color: card.col }

                    // The draft as edited: kept per item while the overlay is open.
                    property var drafts: ({})
                    function doIt() {
                        if (!card.handle) return;
                        Kiroshi.doIt(Kiroshi.expanded, draftField.visible ? draftField.text : undefined);
                    }
                    onItChanged: {
                        // (From `it` itself: `handle`'s binding may not have followed yet.)
                        draftField.text = card.drafts[Kiroshi.expanded] ?? card.it?.handle?.draft ?? "";
                    }

                    ColumnLayout {
                        id: cardColumn
                        x: 20
                        y: 14
                        width: card.width - 36
                        spacing: 10
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Rectangle {
                                implicitWidth: 22
                                implicitHeight: 22
                                color: card.col
                                Text {
                                    anchors.centerIn: parent
                                    text: Kiroshi.expanded + 1
                                    font.family: root.mono
                                    font.pixelSize: 13
                                    font.weight: Font.Bold
                                    color: root.panel
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: card.it?.label ?? ""
                                font.family: root.font
                                font.pixelSize: 18
                                font.weight: Font.Bold
                                color: root.ink
                                elide: Text.ElideRight
                            }
                            Text {
                                text: `${root.urgencyText(card.it?.urgency ?? "")} · ${String(card.it?.kind ?? "").toUpperCase()}`
                                font.family: root.mono
                                font.pixelSize: 10
                                font.letterSpacing: 1.5
                                color: card.col
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: card.it?.pending ? (card.it?.gist ?? "") + "\n" + Translation.tr("Reading the details…")
                                : (card.it?.detail || card.it?.gist || "")
                            wrapMode: Text.Wrap
                            font.family: root.body
                            font.pixelSize: 14
                            lineHeight: 1.15
                            color: Qt.alpha(root.ink, 0.92)
                        }
                        // What the agent would do.
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: card.handle !== null
                            spacing: 4
                            Text {
                                text: Translation.tr("AI CAN") + " — " + (card.handle?.title ?? "")
                                font.family: root.mono
                                font.pixelSize: 11
                                font.letterSpacing: 1
                                color: card.col
                            }
                            Repeater {
                                model: card.handle?.plan ?? []
                                delegate: Text {
                                    required property string modelData
                                    Layout.fillWidth: true
                                    text: "☐  " + modelData
                                    wrapMode: Text.Wrap
                                    font.family: root.body
                                    font.pixelSize: 13
                                    color: Qt.alpha(root.ink, 0.85)
                                }
                            }
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            visible: (card.handle?.draft ?? "").length > 0
                            implicitHeight: Math.min(160, draftField.implicitHeight + 8)
                            color: Qt.alpha(root.ink, 0.06)
                            border.width: draftField.activeFocus ? 1 : 0
                            border.color: card.col
                            ScrollView {
                                anchors.fill: parent
                                TextArea {
                                    id: draftField
                                    wrapMode: TextEdit.Wrap
                                    selectByMouse: true
                                    font.family: root.body
                                    font.pixelSize: 13
                                    color: root.ink
                                    selectionColor: card.col
                                    selectedTextColor: root.panel
                                    background: null
                                    placeholderText: Translation.tr("The text it will send")
                                    onTextChanged: if (activeFocus) card.drafts[Kiroshi.expanded] = text
                                    Keys.onEscapePressed: content.forceActiveFocus()
                                    Keys.onPressed: (event) => {
                                        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                                            card.doIt();
                                            event.accepted = true;
                                        }
                                    }
                                }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: !card.it?.pending && card.handle === null
                            text: Translation.tr("Only you can decide this one.")
                            font.family: root.body
                            font.pixelSize: 12
                            font.italic: true
                            color: root.grey
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            KButton {
                                visible: card.handle !== null
                                main: true
                                tint: card.col
                                text: Translation.tr("Do it  ⏎")
                                onClicked: card.doIt()
                            }
                            KButton {
                                visible: (card.handle?.draft ?? "").length > 0
                                tint: card.col
                                text: Translation.tr("Copy draft")
                                onClicked: Quickshell.execDetached(["wl-copy", "--", draftField.text])
                            }
                            KButton {
                                tint: root.cyan
                                text: Translation.tr("Tell me more")
                                onClicked: Kiroshi.tellMore(Kiroshi.expanded)
                            }
                            Item { Layout.fillWidth: true }
                        }
                    }
                }
            }
        }
    }
}
