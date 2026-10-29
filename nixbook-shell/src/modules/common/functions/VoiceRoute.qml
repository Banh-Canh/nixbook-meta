pragma Singleton
import Quickshell
import "voice_route.js" as Route

/**
 * Where the microphone's audio goes (voice_route.js, plain code): private
 * listening keeps what listens on its own on this computer
 * (services/Voice.qml).
 */
Singleton {
    function settingEngine(setting, metaReady) {
        return Route.settingEngine(setting, metaReady)
    }
    function captureEngine(c) {
        return Route.captureEngine(c)
    }
    function micAllowed(c) {
        return Route.micAllowed(c)
    }
    function judged(c) {
        return Route.judged(c)
    }
    function maxSeconds(c) {
        return Route.maxSeconds(c)
    }
    function micState(c) {
        return Route.micState(c)
    }
}
