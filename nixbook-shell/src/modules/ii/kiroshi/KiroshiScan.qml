pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

/**
 * The Kiroshi scan overlay (services/Kiroshi.qml): over the scanned screen,
 * a scan sweep while the model looks, then what it found, each thing in
 * corner brackets with a tag (number, kind, label), a line of detail and
 * its action chips (a click, or its number key, hands the first to Quick
 * AI's "do"). The summary on top. Esc or a click on the screen closes it.
 * The Cyberpunk theme's colours and font when it is on, else Kiroshi
 * yellow / cyan that read on any wallpaper. Nothing animates once the
 * labels are shown (no redraw of the whole screen every frame).
 */
Scope {
    id: root

    readonly property color yellow: Cyberpunk.enabled ? Cyberpunk.accent : "#fcee0a"
    readonly property color cyan: Cyberpunk.enabled ? Cyberpunk.glitchColor : "#02d7f2"
    readonly property color red: Cyberpunk.enabled ? Cyberpunk.alertColor : "#ff2a6d"
    readonly property color ink: Cyberpunk.enabled ? Cyberpunk.ink : "#f2f0e3"
    readonly property color panel: Cyberpunk.enabled ? Cyberpunk.panel : "#0b0b0d"
    readonly property string font: Cyberpunk.enabled ? Cyberpunk.font : Appearance.font.family.title
    readonly property string mono: Appearance.font.family.monospace

    function kindColor(kind) {
        if (kind === "error" || kind === "notification") return root.red;
        if (kind === "button" || kind === "field" || kind === "link") return root.cyan;
        return root.yellow;
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
            readonly property bool found: !Kiroshi.scanning && Kiroshi.items.length > 0

            // Where each tag goes, so none covers another (nor the summary):
            // each wants its spot by its box (in the items' order, the most
            // important first) and is pushed under, else beside, whatever it
            // would overlap. Run once the tags know their sizes.
            property var tagSizes: ({})
            property var tagSpots: ({})
            property rect summaryRect: Qt.rect(0, 0, 0, 0)
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
                if (window.summaryRect.width > 0) placed.push({ x: window.summaryRect.x, y: window.summaryRect.y,
                    w: window.summaryRect.width, h: window.summaryRect.height });
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
                function onItemsChanged() {
                    window.tagSizes = {};
                    window.tagSpots = {};
                }
            }

            Item {
                id: content
                anchors.fill: parent
                focus: true
                Keys.onEscapePressed: Kiroshi.close()
                Keys.onPressed: (event) => {
                    const n = event.key - Qt.Key_1;
                    if (n >= 0 && n < Kiroshi.items.length && !Kiroshi.scanning) {
                        const it = Kiroshi.items[n];
                        if ((it.actions ?? []).length > 0) Kiroshi.act(it, it.actions[0]);
                        event.accepted = true;
                    }
                }
                Component.onCompleted: forceActiveFocus()

                // A click on the screen, not on a label: closed.
                MouseArea {
                    anchors.fill: parent
                    onClicked: Kiroshi.close()
                }

                // The optics' tint.
                Rectangle {
                    anchors.fill: parent
                    color: Qt.alpha(root.panel, window.found ? 0.32 : 0.22)
                    Behavior on color { ColorAnimation { duration: 300 } }
                }

                // Scanlines (drawn once) while it looks.
                Canvas {
                    anchors.fill: parent
                    opacity: Kiroshi.scanning ? 0.5 : 0
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
                    id: sweep
                    visible: Kiroshi.scanning
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
                        running: Kiroshi.scanning
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
                    anchors.centerIn: parent
                    visible: Kiroshi.scanning
                    width: scanLabel.implicitWidth
                    height: scanLabel.implicitHeight + 40
                    property real jitter: 0
                    Timer {
                        interval: 90
                        repeat: true
                        running: Kiroshi.scanning
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
                            running: Kiroshi.scanning
                            onTriggered: now = Date.now()
                        }
                    }
                }

                // ── What it found ──
                Repeater {
                    model: Kiroshi.scanning ? [] : Kiroshi.items
                    delegate: Item {
                        id: mark
                        required property var modelData
                        required property int index
                        readonly property color col: root.kindColor(modelData.kind)
                        readonly property real bx: modelData.box[0] * window.sx
                        readonly property real by: modelData.box[1] * window.sy
                        readonly property real bw: modelData.box[2] * window.sx
                        readonly property real bh: modelData.box[3] * window.sy
                        anchors.fill: parent

                        opacity: 0
                        Component.onCompleted: appear.start()
                        SequentialAnimation {
                            id: appear
                            PauseAnimation { duration: mark.index * 90 }
                            NumberAnimation { target: mark; property: "opacity"; to: 1; duration: 180; easing.type: Easing.OutCubic }
                        }

                        // The box: a faint fill, corner brackets.
                        Rectangle {
                            x: mark.bx
                            y: mark.by
                            width: mark.bw
                            height: mark.bh
                            color: Qt.alpha(mark.col, 0.07)
                            border.width: 1
                            border.color: Qt.alpha(mark.col, 0.35)
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

                        // The tag: under the box's top-left corner, kept on screen.
                        Rectangle {
                            id: tag
                            width: Math.min(380, Math.max(220, tagColumn.implicitWidth + 24))
                            height: tagColumn.implicitHeight + 16
                            // Inside the box's top when it is big, else under (or above)
                            // it; moved off the other tags by window.placeTags().
                            readonly property var spot: window.tagSpots[mark.index] ?? window.tagWants(mark.index, tag.width, tag.height)
                            x: tag.spot.x
                            y: tag.spot.y
                            onWidthChanged: window.tagSized(mark.index, tag.width, tag.height)
                            onHeightChanged: window.tagSized(mark.index, tag.width, tag.height)
                            Component.onCompleted: window.tagSized(mark.index, tag.width, tag.height)
                            color: Qt.alpha(root.panel, 0.92)
                            border.width: 1
                            border.color: mark.col
                            // A click on the tag isn't one on the screen.
                            MouseArea { anchors.fill: parent }
                            Rectangle { width: 4; height: parent.height; color: mark.col }

                            ColumnLayout {
                                id: tagColumn
                                x: 14
                                y: 8
                                width: tag.width - 24
                                spacing: 4
                                RowLayout {
                                    spacing: 8
                                    Rectangle {
                                        implicitWidth: 22
                                        implicitHeight: 22
                                        color: mark.col
                                        Text {
                                            anchors.centerIn: parent
                                            text: mark.index + 1
                                            font.family: root.mono
                                            font.pixelSize: 13
                                            font.weight: Font.Bold
                                            color: root.panel
                                        }
                                    }
                                    Text {
                                        text: String(mark.modelData.kind).toUpperCase()
                                        font.family: root.mono
                                        font.pixelSize: 11
                                        font.letterSpacing: 2
                                        color: mark.col
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: mark.modelData.label
                                        font.family: root.font
                                        font.pixelSize: 16
                                        font.weight: Font.Bold
                                        color: root.ink
                                        elide: Text.ElideRight
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    visible: text.length > 0
                                    text: mark.modelData.detail ?? ""
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                    font.family: Appearance.font.family.main
                                    font.pixelSize: 13
                                    color: Qt.alpha(root.ink, 0.8)
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    visible: (mark.modelData.actions ?? []).length > 0
                                    spacing: 6
                                    Repeater {
                                        model: mark.modelData.actions ?? []
                                        delegate: Rectangle {
                                            id: chip
                                            required property string modelData
                                            required property int index
                                            implicitWidth: Math.min(tagColumn.width, chipText.implicitWidth + 20)
                                            implicitHeight: chipText.implicitHeight + 10
                                            color: chipMouse.containsMouse ? mark.col : "transparent"
                                            border.width: 1
                                            border.color: mark.col
                                            Text {
                                                id: chipText
                                                anchors.centerIn: parent
                                                width: Math.min(implicitWidth, tagColumn.width - 20)
                                                text: (chip.index === 0 ? "▶ " : "") + chip.modelData
                                                elide: Text.ElideRight
                                                font.family: Appearance.font.family.main
                                                font.pixelSize: 12
                                                font.weight: Font.DemiBold
                                                color: chipMouse.containsMouse ? root.panel : mark.col
                                            }
                                            MouseArea {
                                                id: chipMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: Kiroshi.act(mark.modelData, chip.modelData)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ── The summary (or the error), on top ──
                Rectangle {
                    id: summaryBox
                    visible: !Kiroshi.scanning && (Kiroshi.summary.length > 0 || Kiroshi.error.length > 0)
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 34
                    onVisibleChanged: report()
                    onWidthChanged: report()
                    onHeightChanged: report()
                    function report() {
                        window.summaryRect = summaryBox.visible ? Qt.rect(summaryBox.x, summaryBox.y, summaryBox.width, summaryBox.height) : Qt.rect(0, 0, 0, 0);
                        Qt.callLater(window.placeTags);
                    }
                    width: Math.min(parent.width - 200, summaryColumn.implicitWidth + 40)
                    height: summaryColumn.implicitHeight + 18
                    color: Qt.alpha(root.panel, 0.94)
                    border.width: 1
                    border.color: Kiroshi.error.length > 0 && Kiroshi.items.length === 0 ? root.red : root.yellow
                    MouseArea { anchors.fill: parent }
                    ColumnLayout {
                        id: summaryColumn
                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, parent.width - 40)
                        spacing: 3
                        Text {
                            Layout.fillWidth: true
                            text: Kiroshi.items.length > 0 ? Kiroshi.summary : Kiroshi.error
                            wrapMode: Text.Wrap
                            horizontalAlignment: Text.AlignHCenter
                            font.family: root.font
                            font.pixelSize: 17
                            font.weight: Font.Bold
                            color: Kiroshi.items.length > 0 ? root.ink : root.red
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: `KIROSHI  ·  ${Kiroshi.items.length} ${Translation.tr("FOUND")}  ·  ${(Kiroshi.lastMs / 1000).toFixed(1)} S  ·  1–${Math.max(1, Kiroshi.items.length)} ${Translation.tr("ACT")}  ·  ESC`
                            font.family: root.mono
                            font.pixelSize: 11
                            font.letterSpacing: 1
                            color: root.cyan
                        }
                    }
                }
            }
        }
    }
}
