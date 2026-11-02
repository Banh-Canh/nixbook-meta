pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Accessibility (ai.accessibility; Settings > Desktop agents > Talk to your
 * desktop > Accessibility):
 *   - Read this to me (Mod+Alt+R, `voice readFocused`, "read this" in Muse's
 *     bubble): `nixbook-desktop-mcp read-aloud --capture` gives the window in
 *     front as text — a page in Zen or a bridged app through the page itself,
 *     other apps through their accessibility tree — read out by
 *     Voice.readAloud (even with Muse's voice muted: it was asked for). An
 *     app with neither gives a capture of its window instead, read by the
 *     vision model (Quick AI's one-shot `read` mode, said as it ends; only
 *     with policies.ai 1). The key again, Mod+T or Escape in the bubble
 *     stops it. Terminals and password managers are never read.
 *   - Describe this (`voice describeFocused`, "describe the screen"): the
 *     window's capture described as alt text (Quick AI's `describe` mode),
 *     said out loud. A region: the screenshot app's Ask AI, chip Describe.
 *   - The voice-only preset (voiceOnly): Full AI mode at login, every
 *     answer said (ai.voice.speak "always"), the conversation kept open
 *     (ai.voice.conversation), every question before a step said
 *     (Voice.qml), the bubble's text larger. Turning it on writes those
 *     settings (not the ones set in Nix) and keeps what they were, which
 *     turning it off gives back (Persistent.states.ai.voiceOnlyBefore).
 *   - readSpeed: how fast Muse speaks (Voice.speechRate, nixbook-voice-speak
 *     --rate); largeText: the bubble's text larger (textScale).
 */
Singleton {
    id: root
    // Referenced at startup (shell.qml): the voice-only preset's Full AI
    // mode at login.
    function load() {}

    readonly property var cfg: Config.options?.ai?.accessibility ?? ({})
    readonly property bool voiceOnly: root.cfg.voiceOnly ?? false
    readonly property bool largeText: (root.cfg.largeText ?? false) || root.voiceOnly
    // The speech bubble's text (AgentSpeech.qml).
    readonly property real textScale: root.largeText ? 1.3 : 1
    readonly property int policy: Config.options?.policies?.ai ?? 1
    // Reading the window in front (asking desktop-mcp for its text).
    readonly property bool busy: reader.running

    // ── Read this to me / Describe this ──
    function readFocused() {
        // Again while it reads: stop.
        if (reader.running || Voice.reading) return root.stop();
        reader.mode = "read";
        reader.running = true;
    }
    function describeFocused() {
        if (reader.running) return root.stop();
        if (root.policy !== 1 || !QuickAi.available) return root.say(root.noAi);
        reader.mode = "describe";
        reader.running = true;
    }
    function stop() {
        if (reader.running) {
            reader.wanted = false;
            reader.running = false;
        }
        if (QuickAi.busy && ["read", "describe"].includes(QuickAi.convo.mode ?? "")) QuickAi.stop();
        Voice.stopSpeaking();
    }
    // A short line said (and shown when the bubble is out): what went wrong.
    function say(text) {
        if (!Voice.readAloud(text))
            Quickshell.execDetached(["notify-send", "-a", "Muse", "-t", "5000", Translation.tr("Read this to me"), text]);
    }
    readonly property string noAi: Translation.tr("This window has no text I can reach, and reading its picture needs the AI (Settings > Desktop agents).")

    function _handle(out, mode) {
        let r = null;
        try {
            r = JSON.parse(out);
        } catch (e) {
            return root.say(Translation.tr("I couldn't read this window."));
        }
        if (r.error) return root.say(Translation.tr("I won't read this window: %1").arg(r.error));
        if (mode === "read" && r.text) {
            Voice.readAloud(r.text);
            return;
        }
        if (r.image) {
            if (root.policy !== 1 || !QuickAi.available) return root.say(root.noAi);
            QuickAi.readImage(r.image, mode, mode === "describe" ? Translation.tr("Describe: %1").arg(r.title || r.app)
                : Translation.tr("Read it to me: %1").arg(r.title || r.app));
            return;
        }
        root.say(Translation.tr("I found nothing to read in this window."));
    }
    Process {
        id: reader
        property string mode: "read"
        property bool wanted: true
        // --capture: a picture when there is no text; --picture: only one.
        command: ["nixbook-desktop-mcp", "read-aloud", reader.mode === "describe" ? "--picture" : "--capture"]
        stdout: StdioCollector { id: readerOut }
        onStarted: reader.wanted = true
        onExited: (code) => {
            if (!reader.wanted) return;
            root._handle(readerOut.text, reader.mode);
        }
    }

    // ── The voice-only preset ──
    // The settings it sets, and their values with it on.
    readonly property var presetKeys: ({
        "ai.voice.speak": "always",
        "ai.voice.conversation": true,
        "ai.voice.enable": true,
        "ai.quick.bubble": "always",
    })
    function _get(path) {
        let o = Config.options;
        for (const k of path.split(".")) o = o?.[k];
        return o;
    }
    function _set(path, value) {
        const parts = path.split(".");
        let o = Config.options;
        for (const k of parts.slice(0, -1)) o = o?.[k];
        if (o && !NixManaged.isPinned(path)) o[parts[parts.length - 1]] = value;
    }
    function setVoiceOnly(on) {
        if (!Config.options.ai.accessibility || NixManaged.isPinned("ai.accessibility.voiceOnly")) return;
        if (on === root.voiceOnly) return;
        if (on) {
            const before = {};
            for (const k in root.presetKeys) {
                before[k] = root._get(k);
                root._set(k, root.presetKeys[k]);
            }
            Persistent.states.ai.voiceOnlyBefore = JSON.stringify(before);
            Config.options.ai.accessibility.voiceOnly = true;
            if (!FullAi.active && root.policy === 1) FullAi.enter();
        } else {
            let before = {};
            try {
                before = JSON.parse(Persistent.states.ai.voiceOnlyBefore || "{}");
            } catch (e) {}
            for (const k in before) if (before[k] !== undefined && before[k] !== null) root._set(k, before[k]);
            Persistent.states.ai.voiceOnlyBefore = "";
            Config.options.ai.accessibility.voiceOnly = false;
        }
    }

    // Full AI mode at login with the preset on: once, when the shell is up
    // (after the loading screen) and unlocked.
    property bool _started: false
    function _maybeStart() {
        if (root._started || !Config.ready || !root.voiceOnly || root.policy !== 1) return;
        if (Preloader.booting || GlobalStates.screenLocked || !QuickAi.available) return;
        root._started = true;
        if (!FullAi.active) FullAi.enter();
    }
    Timer {
        id: atLogin
        interval: 2500
        running: Config.ready && root.voiceOnly && !root._started
        repeat: true
        onTriggered: root._maybeStart()
    }
}
