pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.ii.regionSelector
import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

/**
 * Muse's visible cursor (services/AgentCursor.qml): a second, glowing cursor
 * in the theme's accent colours with a small Muse badge, gliding to what the
 * agent clicks, drags, scrolls or types into just before it does, with its
 * label ("clicking “Send”", "typing 42 characters"), a ripple on a click,
 * and corner brackets for a moment around a window or a region it read.
 *
 * One Overlay-layer window per screen, built the first time the cursor
 * shows and kept mapped after: hiding a Wayland window destroys its surface
 * and Qt rebuilds the GL context on the next show (130–230 ms, longer than
 * the server's lead). Idle, it collapses to a 1 px transparent surface.
 * It never takes input (an empty input region, no keyboard) and vanishes
 * while the agent takes a screenshot (MakeWay.capture). Coordinates come
 * in desktop logical pixels: each window draws them less its output's
 * position (niri's logical x/y), so a glide across two screens is one move.
 */
Scope {
    id: root

    // niri's gaps and struts, to place tiled windows (RegionFunctions.windowTargets):
    // read again each time the cursor comes up (a switch replaces the file).
    FileView {
        id: niriConfigFile
        path: Quickshell.env("NIRI_CONFIG") || `${Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`}/niri/config.kdl`
        printErrors: false
    }
    property var niriLayout: RegionFunctions.parseNiriLayout("")
    Connections {
        target: AgentCursor
        function onShownChanged() {
            if (!AgentCursor.shown) {
                // Comes in again from the side next time, once faded out.
                unplace.restart()
                return
            }
            unplace.stop()
            niriConfigFile.reload()
            root.niriLayout = RegionFunctions.parseNiriLayout(niriConfigFile.text())
        }
        function onActed(event) { root.act(event) }
        function onLooked(event) { root.lookAt(event) }
    }

    // The cursor's target, in desktop logical pixels: each window glides to
    // it ({x, y, then: {x, y} for a drag, ms, id}); a ripple after the
    // glide for a click; a look's box ({x, y, w, h, label, id}).
    property var target: null
    property bool placed: false
    Timer {
        id: unplace
        interval: 450
        onTriggered: root.placed = false
    }
    property var outline: null
    property int seq: 0

    // A window's box on screen (desktop logical pixels), from niri's window
    // list as the region selector lays it out, or null when it isn't shown.
    function windowBox(id) {
        if (id === undefined || id === null) return null
        for (const s of Quickshell.screens) {
            const geo = WM.monitorGeometry(s)
            const bar = Config.options.bar
            const screens = bar.screenList ?? []
            const barHere = screens.length === 0 || screens.includes(s.name)
            const side = barHere && bar.vertical ? Appearance.sizes.verticalBarWidth : 0
            const reserved = { left: bar.bottom ? 0 : side, right: bar.bottom ? side : 0, bottom: barHere && !bar.vertical && bar.bottom }
            const targets = RegionFunctions.windowTargets(WM.windowList, WM.activeWorkspaceForMonitor(s.name),
                s.width, s.height, root.niriLayout, reserved)
            const t = targets.find(w => String(w.id) === String(id))
            if (t) return { x: geo.x + t.x, y: geo.y + t.y, width: t.width, height: t.height }
        }
        return null
    }

    // "{app}" in a label: the app's name (its desktop entry), from the
    // event or the window it names.
    function labelOf(event) {
        const label = String(event.label ?? "")
        if (!label.includes("{app}")) return label
        let appId = event.app ?? ""
        if (!appId && event.window !== undefined) {
            const w = WM.windowList.find(w => String(w.id) === String(event.window))
            appId = w?.appId ?? ""
        }
        const name = appId ? (DesktopEntries.heuristicLookup(appId)?.name ?? appId) : Translation.tr("the window")
        return label.split("{app}").join(name)
    }

    function screenCentre() {
        const name = WM.focusedMonitor?.name
        const s = Quickshell.screens.find(x => x.name === name) ?? Quickshell.screens[0]
        if (!s) return { x: 0, y: 0 }
        const geo = WM.monitorGeometry(s)
        return { x: geo.x + s.width / 2, y: geo.y + s.height / 2 }
    }

    function act(event) {
        let x = typeof event.x === "number" ? event.x : null
        let y = typeof event.y === "number" ? event.y : null
        const box = root.windowBox(event.window)
        if (x === null || y === null) {
            const now = root.target
            if (box && event.rel && typeof event.rel.x === "number") {
                // An element's box inside its window: its middle, kept inside.
                x = box.x + Math.min(Math.max(event.rel.x + event.rel.w / 2, 8), box.width - 8)
                y = box.y + Math.min(Math.max(event.rel.y + event.rel.h / 2, 8), box.height - 8)
            } else if (now && root.placed && (!box || (now.x >= box.x && now.x <= box.x + box.width
                    && now.y >= box.y && now.y <= box.y + box.height))) {
                // Keys and text go where it already is (a field it clicked).
                x = now.x
                y = now.y
            } else if (box) {
                x = box.x + box.width / 2
                y = box.y + Math.min(box.height / 2, 160)
            } else {
                const c = now && root.placed ? now : root.screenCentre()
                x = c.x
                y = c.y
            }
        }
        root.seq += 1
        const lead = Math.max(0, event.lead ?? 300)
        root.target = {
            id: root.seq, x: x, y: y, kind: event.kind, label: root.labelOf(event),
            // Arrives as the input does: the glide takes the lead, within 250–400 ms.
            ms: Math.min(400, Math.max(lead > 0 ? Math.min(lead, 250) : 120, lead)),
            first: !root.placed,
            then: event.kind === "drag" && typeof event.toX === "number" ? { x: event.toX, y: event.toY } : null,
            button: event.button ?? "left", double: event.double === true
        }
        root.placed = true
    }

    function lookAt(event) {
        let box = null
        if (typeof event.w === "number" && typeof event.x === "number")
            box = { x: event.x, y: event.y, width: event.w, height: event.h }
        else
            box = root.windowBox(event.window)
        if (!box || box.width < 4 || box.height < 4) return
        root.seq += 1
        root.outline = { id: root.seq, x: box.x, y: box.y, width: box.width, height: box.height, label: root.labelOf(event) }
    }

    Loader {
        active: AgentCursor.everShown
        sourceComponent: Variants {
            model: Quickshell.screens
            delegate: PanelWindow {
                id: window
                required property var modelData
                screen: window.modelData
                readonly property var geo: WM.monitorGeometry(window.modelData)

                // Kept mapped; full screen only while shown and fading out.
                visible: true
                readonly property bool expanded: AgentCursor.shown || fadeOut.running
                Timer {
                    id: fadeOut
                    interval: 400
                }
                Connections {
                    target: AgentCursor
                    function onShownChanged() { if (!AgentCursor.shown) fadeOut.restart() }
                }
                implicitWidth: 1
                implicitHeight: 1
                anchors {
                    top: window.expanded
                    bottom: window.expanded
                    left: window.expanded
                    right: window.expanded
                }
                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                exclusiveZone: 0
                WlrLayershell.namespace: "quickshell:agentCursor"
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                // Every click goes through, the agent's and the user's.
                mask: Region {}

                Item {
                    id: stage
                    anchors.fill: parent
                    // Gone from the agent's screenshots at once; fades out after.
                    opacity: MakeWay.capture ? 0 : AgentCursor.shown ? 1 : 0
                    Behavior on opacity {
                        enabled: !MakeWay.capture
                        NumberAnimation { duration: 350; easing.type: Easing.OutCubic }
                    }
                    readonly property bool running: AgentCursor.shown && window.expanded

                    // -- the outline of a look: corner brackets, ~800 ms -----------
                    Item {
                        id: look
                        property var box: root.outline
                        x: (look.box?.x ?? 0) - window.geo.x
                        y: (look.box?.y ?? 0) - window.geo.y
                        width: look.box?.width ?? 0
                        height: look.box?.height ?? 0
                        opacity: 0
                        visible: look.opacity > 0
                        onBoxChanged: if (look.box) lookAnim.restart()
                        SequentialAnimation {
                            id: lookAnim
                            NumberAnimation { target: look; property: "opacity"; from: 0; to: 1; duration: 120 }
                            PauseAnimation { duration: 480 }
                            NumberAnimation { target: look; property: "opacity"; to: 0; duration: 300 }
                        }
                        Rectangle {
                            anchors.fill: parent
                            color: Qt.alpha(Appearance.colors.colPrimary, 0.06)
                            border.width: 1
                            border.color: Qt.alpha(Appearance.colors.colPrimary, 0.35)
                            radius: Appearance.rounding.unsharpenmore
                        }
                        Repeater {
                            model: 4
                            delegate: Item {
                                id: bracket
                                required property int index
                                readonly property bool atRight: index % 2 === 1
                                readonly property bool atBottom: index >= 2
                                readonly property real len: Math.min(28, look.width / 3, look.height / 3)
                                x: atRight ? look.width - len : 0
                                y: atBottom ? look.height - len : 0
                                width: len
                                height: len
                                Rectangle { width: bracket.len; height: 3; color: Appearance.colors.colPrimary; y: bracket.atBottom ? bracket.len - 3 : 0 }
                                Rectangle { width: 3; height: bracket.len; color: Appearance.colors.colPrimary; x: bracket.atRight ? bracket.len - 3 : 0 }
                            }
                        }
                        CursorLabel {
                            x: 6
                            y: look.height > 60 ? 8 : -height - 6
                            text: look.box?.label ?? ""
                            visible: text.length > 0
                        }
                    }

                    // -- the cursor --------------------------------------------------
                    Item {
                        id: pointer
                        // Its tip, in this window's coordinates.
                        property real px: -100
                        property real py: -100
                        x: pointer.px
                        y: pointer.py
                        width: 1
                        height: 1
                        visible: root.placed && root.target !== null
                        property string kind: root.target?.kind ?? ""

                        property var target: root.target
                        onTargetChanged: {
                            const t = pointer.target
                            if (!t) return
                            const tx = t.x - window.geo.x
                            const ty = t.y - window.geo.y
                            glide.stop()
                            if (t.first) {
                                // First step: comes in from up-left, fading in with the stage.
                                pointer.px = tx - 70
                                pointer.py = ty - 50
                            }
                            glideX.to = tx
                            glideY.to = ty
                            glideX.duration = glideY.duration = t.ms
                            dragX.to = t.then ? t.then.x - window.geo.x : tx
                            dragY.to = t.then ? t.then.y - window.geo.y : ty
                            dragX.duration = dragY.duration = t.then ? 380 : 0
                            glide.start()
                        }
                        SequentialAnimation {
                            id: glide
                            ParallelAnimation {
                                NumberAnimation { id: glideX; target: pointer; property: "px"; easing.type: Easing.InOutCubic }
                                NumberAnimation { id: glideY; target: pointer; property: "py"; easing.type: Easing.InOutCubic }
                            }
                            ScriptAction {
                                script: {
                                    const t = pointer.target
                                    if (t && t.kind === "click") ripples.press(t.double, t.button)
                                    if (t && (t.kind === "drag")) ripples.press(false, "left")
                                }
                            }
                            ParallelAnimation {
                                NumberAnimation { id: dragX; target: pointer; property: "px"; easing.type: Easing.InOutQuad }
                                NumberAnimation { id: dragY; target: pointer; property: "py"; easing.type: Easing.InOutQuad }
                            }
                        }

                        // A soft glow around the tip, breathing while shown.
                        Rectangle {
                            id: glow
                            width: 56
                            height: 56
                            radius: 28
                            x: -width / 2 + 4
                            y: -height / 2 + 6
                            color: Qt.alpha(Appearance.colors.colPrimary, 0.18)
                            border.width: 2
                            border.color: Qt.alpha(Appearance.colors.colPrimary, 0.35)
                            SequentialAnimation on scale {
                                running: stage.running
                                loops: Animation.Infinite
                                NumberAnimation { from: 0.85; to: 1.05; duration: 900; easing.type: Easing.InOutSine }
                                NumberAnimation { from: 1.05; to: 0.85; duration: 900; easing.type: Easing.InOutSine }
                            }
                        }

                        // Ripples: a ring spreading from the tip on each click.
                        Item {
                            id: ripples
                            // A right or middle click: the tertiary colour.
                            property color tint: Appearance.colors.colPrimary
                            function press(twice, button) {
                                ripples.tint = button === "left" ? Appearance.colors.colPrimary : Appearance.colors.colTertiary
                                rippleAnim1.restart()
                                if (twice) rippleAnim2.restart()
                            }
                            Rectangle {
                                id: ripple1
                                width: 72; height: 72; radius: 36
                                x: -36; y: -36
                                scale: 0; opacity: 0
                                color: "transparent"
                                border.width: 3
                                border.color: ripples.tint
                            }
                            Rectangle {
                                id: ripple2
                                width: 72; height: 72; radius: 36
                                x: -36; y: -36
                                scale: 0; opacity: 0
                                color: "transparent"
                                border.width: 3
                                border.color: ripples.tint
                            }
                            ParallelAnimation {
                                id: rippleAnim1
                                NumberAnimation { target: ripple1; property: "scale"; from: 0.15; to: 1.2; duration: 450; easing.type: Easing.OutCubic }
                                NumberAnimation { target: ripple1; property: "opacity"; from: 0.9; to: 0; duration: 450; easing.type: Easing.OutQuad }
                            }
                            SequentialAnimation {
                                id: rippleAnim2
                                PauseAnimation { duration: 140 }
                                ParallelAnimation {
                                    NumberAnimation { target: ripple2; property: "scale"; from: 0.15; to: 1.2; duration: 450; easing.type: Easing.OutCubic }
                                    NumberAnimation { target: ripple2; property: "opacity"; from: 0.9; to: 0; duration: 450; easing.type: Easing.OutQuad }
                                }
                            }
                        }

                        // The arrow: the theme's accent, outlined so it reads on any window.
                        Shape {
                            id: arrow
                            width: 24
                            height: 30
                            preferredRendererType: Shape.CurveRenderer
                            scale: rippleAnim1.running ? 0.88 : 1
                            transformOrigin: Item.TopLeft
                            Behavior on scale { NumberAnimation { duration: 90 } }
                            ShapePath {
                                fillColor: Appearance.colors.colPrimary
                                strokeColor: Appearance.colors.colOnPrimary
                                strokeWidth: 2
                                joinStyle: ShapePath.RoundJoin
                                startX: 0; startY: 0
                                PathLine { x: 0; y: 24 }
                                PathLine { x: 6.5; y: 18.5 }
                                PathLine { x: 11; y: 28 }
                                PathLine { x: 15; y: 26.2 }
                                PathLine { x: 10.6; y: 17 }
                                PathLine { x: 19; y: 17 }
                                PathLine { x: 0; y: 0 }
                            }
                        }
                        // Muse's badge: a sparkle in the tertiary colour.
                        Rectangle {
                            x: 13
                            y: 20
                            width: 18
                            height: 18
                            radius: Persona.shapes ? 4 : 9
                            color: Appearance.colors.colTertiary
                            border.width: 1.5
                            border.color: Appearance.colors.colOnTertiary
                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: "auto_awesome"
                                iconSize: 12
                                fill: 1
                                color: Appearance.colors.colOnTertiary
                            }
                        }

                        // What it does, beside the tip (flipped near the screen's edges).
                        CursorLabel {
                            id: label
                            readonly property bool flipX: pointer.px + 34 + width > window.width - 8
                            readonly property bool flipY: pointer.py + 36 + height > window.height - 8
                            x: label.flipX ? -width - 14 : 34
                            y: label.flipY ? -height - 10 : 30
                            text: pointer.target?.label ?? ""
                            caret: pointer.kind === "type" || pointer.kind === "keys"
                            blinking: stage.running
                            visible: text.length > 0
                        }
                    }
                }
            }
        }
    }

    // The label chip: the accent's colours, the theme's title font; a caret
    // while it types.
    component CursorLabel: Item {
        id: chip
        property string text: ""
        property bool caret: false
        property bool blinking: false
        implicitWidth: row.implicitWidth + 20
        implicitHeight: row.implicitHeight + 10
        width: implicitWidth
        height: implicitHeight
        // The Persona style's hard, unblurred offset shadow.
        Rectangle {
            visible: Persona.shapes
            x: 3; y: 3
            width: chip.width; height: chip.height
            radius: bg.radius
            color: Qt.alpha("black", 0.55)
        }
        Rectangle {
            id: bg
            anchors.fill: parent
            radius: Persona.shapes ? Appearance.rounding.unsharpenmore : height / 2
            color: Appearance.colors.colPrimary
            border.width: 1
            border.color: Qt.alpha(Appearance.colors.colOnPrimary, 0.35)
        }
        Row {
            id: row
            anchors.centerIn: parent
            spacing: 6
            StyledText {
                text: chip.text
                color: Appearance.colors.colOnPrimary
                font.family: Appearance.font.family.title
                font.pixelSize: Appearance.font.pixelSize.small
                font.weight: Font.DemiBold
            }
            Rectangle {
                visible: chip.caret
                anchors.verticalCenter: parent.verticalCenter
                width: 2
                height: 14
                color: Appearance.colors.colOnPrimary
                SequentialAnimation on opacity {
                    running: chip.caret && chip.blinking
                    loops: Animation.Infinite
                    NumberAnimation { to: 0; duration: 450 }
                    NumberAnimation { to: 1; duration: 450 }
                }
            }
        }
    }
}
