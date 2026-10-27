//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
import "modules/common"
import "services"
import QtQuick
import Quickshell
import qs.modules.ii.notificationPopup
import qs.modules.ii.fullAi

ShellRoot {
    AgentSpeech {}
    FullAiOverlay {}
    Timer { interval: 2000; running: Config.ready; onTriggered: FullAi.enter() }
    Timer { interval: 13000; running: Config.ready; onTriggered: { console.log("[QA] mute"); FullAi.toggleMic() } }
    Connections { target: Voice; function onListeningChanged() { console.log("[QA] listening", Voice.listening, "t", Date.now() % 100000) } }
}
