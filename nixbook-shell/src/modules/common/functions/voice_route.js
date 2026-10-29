.pragma library

// Where the microphone's audio goes (services/Voice.qml), in plain code so
// it can be tested under node (tests/voice-route-tests.js).
// Private listening (ai.voice.privateListening, on by default): nothing
// heard leaves the computer unless it was said to Muse. What the user
// starts themselves (Mod+T, the bubble's mic, `voice start`) may use Meta's
// realtime transcriber (ai.voice.engine); everything that listens on its
// own — Full AI mode's always-open microphone, the mic opening again after
// an answer, after a "stop", for a yes or a no — uses this computer
// (whisper.cpp), and what it hears goes on as text only once the plain-code
// rules (addressee.js) say it was for Muse.
// QML's JS engine: no ES2019+.

// The engine ai.voice.engine names: "meta" | "local" ("auto": Meta when it
// is the model provider with its key).
function settingEngine(setting, metaReady) {
    if (setting === "meta" || setting === "local") return setting
    return metaReady ? "meta" : "local"
}

// The engine of one capture. c: {setting, metaReady, privateListening,
// solicited (the user started this capture: a key, a click)}.
function captureEngine(c) {
    var o = c || {}
    if (o.privateListening !== false && !o.solicited) return "local"
    return settingEngine(o.setting, !!o.metaReady)
}

// The microphone may capture at all: never while the screen is locked or
// the screens are off (the user is away), whatever started it.
function micAllowed(c) {
    var o = c || {}
    return !o.locked && !o.screensOff
}

// Is what was heard judged before it goes on (addressee.js)? Full AI mode's
// microphone always (unless "all"); with private listening, also what an
// automatic reopening heard (a conversation's next turn, the mic opened for
// a yes or a no). What the user started with a key is for Muse.
// c: {mode "smart"|"name"|"all", fullAi, solicited, privateListening}
function judged(c) {
    var o = c || {}
    if (o.mode === "all") return false
    if (o.fullAi) return true
    return o.privateListening !== false && !o.solicited
}

// The longest one capture may run (s): an order to Muse is short, and
// whisper.cpp transcribes the whole recording — what listens on its own
// stops at 30 s, what the user started at ai.voice.maxSeconds.
function maxSeconds(c) {
    var o = c || {}
    var max = Math.max(5, Math.min(600, o.maxSeconds || 120))
    return o.engine === "local" && !o.solicited ? Math.min(max, 30) : max
}

// What the mascot and the bubble show of the microphone: "off" (muted),
// "paused" (away: locked, screens off), "meta" (sending to Meta now),
// "local" (listening on this computer). c: {micOn, allowed, capturing,
// captureEngine (the engine of the capture now), nextEngine (the one the
// next automatic capture would use)}.
function micState(c) {
    var o = c || {}
    if (o.micOn === false) return "off"
    if (!o.allowed) return "paused"
    if (o.capturing) return o.captureEngine === "meta" ? "meta" : "local"
    return o.nextEngine === "meta" ? "meta" : "local"
}
