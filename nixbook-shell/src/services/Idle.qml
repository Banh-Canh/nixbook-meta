pragma Singleton
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Wayland

/**
 * Idle inhibition (the idle toggle) and screens-off detection.
 */
Singleton {
    id: root

    // The idle toggle.
    property bool inhibit: false
    // Talking to Muse (Voice.qml, after each turn said to it): no key is
    // pressed meanwhile, but the user is there; the screens stay on (and
    // so does the microphone, which closes when they go off) for
    // `talkMinutes` after the last thing said to it.
    readonly property int talkMinutes: 5
    property bool talking: false
    function noteTalking() {
        root.talking = true;
        talkTimer.restart();
    }
    Timer {
        id: talkTimer
        interval: root.talkMinutes * 60000
        onTriggered: root.talking = false
    }

    // The screens are off: no input for as long as hypridle waits before
    // `niri msg action power-off-monitors` (niriConfig.nix, 300 s), with the
    // same idle inhibitors honoured (a playing video, the idle toggle). Polls
    // and per-second redraws that only feed what is on screen pause on it
    // (resources, network speed, VPN status, media position, the clock's
    // seconds…) and refresh as soon as there is input again.
    readonly property int screenOffTimeout: 300
    readonly property bool screensOff: idleMonitor.isIdle
    IdleMonitor {
        id: idleMonitor
        timeout: root.screenOffTimeout
        respectInhibitors: true
    }

    Connections {
        target: Persistent
        function onReadyChanged() {
            root.inhibit = Persistent.states.idle.inhibit;
        }
    }

    function toggleInhibit(active = null) {
        if (active !== null) {
            root.inhibit = active;
        } else {
            root.inhibit = !root.inhibit;
        }
        Persistent.states.idle.inhibit = root.inhibit;
    }

    IdleInhibitor {
        id: idleInhibitor
        enabled: root.inhibit || root.talking
        window: PanelWindow {
            // Inhibitor requires a "visible" surface
            // Actually not lol
            implicitWidth: 0
            implicitHeight: 0
            color: "transparent"
            // Just in case...
            anchors {
                right: true
                bottom: true
            }
            // Make it not interactable
            mask: Region {
                item: null
            }
        }
    }
}