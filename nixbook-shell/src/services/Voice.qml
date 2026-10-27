pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Talking to the desktop (ai.voice): push to talk (Mod+T, `voice toggle`,
 * the mic button of Muse's speech bubble). Two engines (ai.voice.engine; "auto": Meta when
 * it is the model provider with a key, else this computer):
 *   - meta: the microphone streamed to Muse Voice Transcribe while the user
 *     speaks (`nixbook-voice-stream`, scripts/voice-stream.py): the words
 *     show as they are recognised (`partial`) and the server says when the
 *     speech has ended; nothing heavy runs here;
 *   - local: records (PipeWire, 16 kHz mono, ffmpeg), stops once the user
 *     has spoken and then been quiet for ai.voice.pauseSeconds (or the key
 *     again, or ai.voice.maxSeconds), and transcribes with whisper.cpp
 *     (`nixbook-voice-transcribe`, nothing leaves the computer).
 * It all happens in Muse's speech bubble (the Mod+C one, AgentSpeech.qml):
 * listening calls it up, the words show in its field as they come, and
 * what was said is sent there (Initiative.reply: a plain command done at
 * once by QuickIntent, else Quick AI answers or acts with the desktop
 * tools, or Muse in its own thread). Escape in the bubble cancels.
 * The answers are read out (ai.voice.speak) in a cute voice: Meta's MMS-TTS
 * on this computer (`nixbook-voice-speak`, English or French), as they
 * stream: one `nixbook-voice-speak --stream` per answer, fed the text as it
 * comes, so the first sentence plays before the answer is over.
 */
Singleton {
    id: root
    // Referenced at startup (shell.qml): its IPC target exists from the start.
    function load() {}

    readonly property bool available: QuickAi.available && (Config.options.ai.voice?.enable ?? true)
    property bool listening: false
    property bool transcribing: false
    // The microphone's level above the room's noise, 0..1 (about 20
    // updates a second).
    property real level: 0
    // The user has spoken (the silence that follows ends the recording).
    property bool heard: false
    property string error: ""
    // What was understood last.
    property string lastText: ""
    // Meta: what is recognised so far, while the user speaks.
    property string partial: ""
    // The microphone last recorded: "nixbook-echo-cancel-source" (no sound of
    // the computer's own, programs.nixbook-shell.voice.echoCancel) or "default".
    property string source: ""
    readonly property string engine: {
        const set = Config.options.ai.voice?.engine ?? "auto";
        if (set === "meta" || set === "local") return set;
        return (ModelProvider.status?.kind === "meta" && ModelProvider.status?.keySaved) ? "meta" : "local";
    }
    // The languages hinted to Meta: ai.voice.language, else the interface's
    // and English.
    readonly property string languages: {
        const set = Config.options.ai.voice?.language ?? "auto";
        const ui = ConfigAssistant.uiLang();
        return set && set !== "auto" ? set : ui === "en" ? "en" : `${ui},en`;
    }

    readonly property string dir: `${Directories.runtimeTemp}/voice`
    // How long one turn may last, and the pause that ends it (a sentence
    // can take shorter ones).
    readonly property real maxSeconds: Math.max(5, Math.min(600, Config.options.ai.voice?.maxSeconds ?? 120))
    readonly property real pauseSeconds: Math.max(0.5, Math.min(10, Config.options.ai.voice?.pauseSeconds ?? 1.8))

    // A conversation by voice (ai.voice.conversation): once Mod+T started it,
    // the microphone opens again when the answer is done (or when a step
    // waits for a yes or a no), until the user says they're done ("that's
    // all", "thanks", "c'est tout"…), presses Escape, puts the bubble away,
    // or says nothing for a while.
    property bool session: false
    readonly property bool conversation: Config.options.ai.voice?.conversation ?? true
    readonly property var endWords: /^(ok\s+)?(stop|that'?s all|that is all|that'?s it|thanks?|thank you|no thanks|goodbye|bye|merci|c'?est tout|c'?est bon|stop merci|arr[eê]te|au revoir|danke|das (ist )?alles|tsch[uü]ss|c[aả]m [oơ]n|th[oô]i|xong r[oồ]i)[\s.!]*$/i
    function endSession() {
        root.session = false;
        relisten.stop();
        // A conversation out of sight, over: put away (Mod+C brings it back),
        // so the bubble is free for what comes next.
        if (Initiative.quiet && !FullAi.active && !Initiative.thinking && !root.speaking) Initiative.hush("wait");
    }
    Timer {
        id: relisten
        interval: 300
        onTriggered: {
            // Not while it talks (the speaker reopens it), but Full AI mode's
            // stream, which opens held.
            if (root.speaking && !(FullAi.active && root.engine === "meta")) return;
            // Full AI mode: always listening (orders keep coming while the
            // agent works), unless muted.
            if (FullAi.active) {
                if (FullAi.micOn && !root.listening && !root.transcribing) root.start();
                return;
            }
            if (!root.session || root.listening || root.transcribing || !Initiative.speaking) return;
            if (Initiative.thinking && !QuickAi.pending) return;
            root.start();
        }
    }
    Connections {
        target: Initiative
        function onThinkingChanged() {
            if (Initiative.thinking) {
                root._streamBegin();
                return;
            }
            // Read out as it streamed: what is left said, then the user's turn
            // again (the stream speaker's end reopens the microphone).
            if (root.streamedTurn) {
                root.voiceTurn = false;
                root._feed();
                root._streamClose();
                if (!streamSpeaker.running && !speaker.running && !FullAi.active) {
                    if (root.session) relisten.restart();
                    else if (Initiative.quiet) Initiative.hush("wait");
                }
                return;
            }
            root.streamTarget = null;
            // The answer is there: read out (Full AI mode reads its own,
            // FullAi.qml), then the user's turn again (a conversation).
            if (!FullAi.active && root.wantsSpeech()) root.speak(root.lastAnswer());
            else if (root.session) relisten.restart();
        }
        function onSpeakingChanged() {
            if (!Initiative.speaking && !FullAi.active) {
                root.endSession();
                root.stopSpeaking();
            }
        }
    }
    Connections {
        target: QuickAi
        function onPendingChanged() {
            // A step waiting for an OK: asked out loud, answered by voice
            // (yes / no).
            if (!QuickAi.pending || !(root.session || root.voiceTurn || FullAi.active)) return;
            const what = QuickAi.pending.tool.replace(/_/g, " ") + (QuickAi.pending.summary ? `, ${QuickAi.pending.summary}` : "");
            if (!root.speak(Translation.tr("May I %1?").arg(what))) relisten.restart();
        }
    }

    // ── The answers read out (ai.voice.speak: "voice", the answers to what
    // was said; "always"; "never"). Meta's model API has no speech synthesis:
    // Meta's MMS-TTS on this computer (`nixbook-voice-speak`, English or
    // French from the answer's language), made cute (ai.voice.style). The
    // microphone doesn't take it for the user: closed meanwhile, or, Full AI
    // mode's always-open stream, held (silence sent). Mod+T or Escape cuts it
    // short.
    property bool speaking: false
    // The last message was said, not typed: its answer is read out.
    property bool voiceTurn: false
    readonly property string speakMode: Config.options.ai.voice?.speak ?? "voice"
    readonly property string voiceStyle: Config.options.ai.voice?.style ?? "cute"
    // ai.quick.bubble "needed": talking to it, the bubble stays out of sight
    // (Initiative.quiet), the answers said out loud (or in Full AI's
    // mascot); not when nothing would say them.
    readonly property bool hideBubble: (Config.options.ai.quick?.bubble ?? "always") === "needed"
        && (root.speakMode !== "never" || FullAi.active)
    function wantsSpeech() {
        const yes = root.speakMode === "always" || (root.speakMode === "voice" && root.voiceTurn);
        root.voiceTurn = false;
        return yes && root.lastAnswer().length > 0;
    }
    // What to say of the last answer: a report's outcome (and what needs the
    // user), else the answer itself (the speaker keeps it short).
    function lastAnswer() {
        const chat = Initiative.chat;
        if (!chat) return "";
        const ids = chat.messageIDs;
        for (let i = ids.length - 1; i >= 0; i--) {
            const m = chat.messageByID[ids[i]];
            if (!m || m.role === "user") return "";
            if (m.role !== "assistant") continue;
            if (QuickAi.report && QuickAi.reportMsg === m) {
                const r = QuickAi.report;
                return [r.summary, ...(r.failed ?? []).slice(0, 2), ...(r.needsYou ?? [])].join(". ");
            }
            return m.content ?? "";
        }
        return "";
    }
    // Says it (cutting off what it was saying); false when nothing is said
    // (ai.voice.speak "never", no text).
    function speak(text) {
        if (root.speakMode === "never" || !String(text ?? "").trim()) return false;
        root.stopSpeaking(false);
        speaker.text = String(text);
        speaker.wanted = true;
        speaker.reopen = root._holdMic();
        speaker.running = true;
        return true;
    }
    // The microphone never hears it: the continuous stream held, a turn's
    // recording closed (true: to open again once it has spoken).
    function _holdMic() {
        root.speaking = true;
        if (stream.running && stream.continuous) {
            stream.write("hold\n");
            return false;
        }
        if (root.listening) {
            root.pauseListening();
            return true;
        }
        return false;
    }
    // byUser: Mod+T, Escape (the rest of the answer being streamed isn't
    // read out either); not when it only makes way for something else to say.
    function stopSpeaking(byUser = true) {
        if (speaker.running) {
            speaker.wanted = false;
            speaker.signal(15);
        }
        if (streamSpeaker.running) {
            streamSpeaker.wanted = false;
            streamSpeaker.signal(15);
        }
        if (byUser) {
            root.streamTarget = null;
            root.streamTurn = false;
        }
        if (root.speaking && stream.running && stream.continuous) stream.write("resume\n");
        root.speaking = false;
    }
    // Said (either speaker): the microphone back, the user's turn — unless
    // the other speaker still talks (`otherRunning`: it ends this itself).
    function _spoken(code, wanted, again, err, otherRunning) {
        if (code !== 0 && wanted)
            root.error = Translation.tr("Speaking failed: %1").arg(String(err ?? "").trim().split("\n").pop() || code);
        if (otherRunning) return;
        if (root.speaking && stream.running && stream.continuous) stream.write("resume\n");
        root.speaking = false;
        // Said: the user's turn (a conversation, Full AI mode — also
        // when Mod+T cut it short: the mic it had closed opens again); a
        // conversation out of sight and over: put away (relisten waits
        // for an answer still being written, but a yes or no it asks for).
        if (FullAi.active || (wanted && (root.session || again))) relisten.restart();
        else if (Initiative.quiet && !FullAi.active && !Initiative.thinking) Initiative.hush("wait");
    }

    // ── Read out as it streams ──
    // A turn to be read out (decided as it starts: Full AI mode, "always",
    // or "voice" and it was said): its answer's text (`streamTarget`, the
    // bubble's last message) fed to one `nixbook-voice-speak --stream` as it
    // comes (`streamFed`: how much of its plain text went), stdin closed once
    // the answer is complete (meta-agent's `answer`, before its checks).
    property bool streamTurn: false
    property bool streamedTurn: false
    property var streamTarget: null
    property int streamFed: 0
    // An older nixbook-voice-speak without --stream: read out at the end.
    property bool streamUnsupported: false
    function _lastAssistant() {
        const chat = Initiative.chat;
        if (!chat) return null;
        const ids = chat.messageIDs;
        const m = ids.length > 0 ? chat.messageByID[ids[ids.length - 1]] : null;
        return m && m.role === "assistant" ? m : null;
    }
    function _streamBegin() {
        root.streamedTurn = false;
        root.streamFed = 0;
        root.streamTurn = !root.streamUnsupported && root.speakMode !== "never"
            && (FullAi.active || root.speakMode === "always" || (root.speakMode === "voice" && root.voiceTurn));
        // The turn's own message (not the last one, already done).
        const m = root.streamTurn ? root._lastAssistant() : null;
        root.streamTarget = m && !m.done ? m : null;
        root._feed();
    }
    function _plain(m) {
        return String(m?.content ?? "").replace(/<think>[\s\S]*?(<\/think>|$)/g, "").replace(/<report>[\s\S]*?(<\/report>|$)/g, "");
    }
    function _feed() {
        const m = root.streamTarget;
        if (!m || !root.streamTurn) return;
        const plain = root._plain(m);
        const complete = m.answered || m.done;
        // Not while something else is said (a question for an OK), nor into
        // a speaker whose input is closed: on when it is done (onExited).
        if (speaker.running || streamSpeaker.closing) return;
        if (plain.length > root.streamFed) {
            const fresh = plain.slice(root.streamFed);
            if (!streamSpeaker.running) {
                if (fresh.trim().length === 0) return;
                root.streamFed = plain.length;
                root.streamedTurn = true;
                streamSpeaker.pending = fresh;
                streamSpeaker.closeAfter = false;
                streamSpeaker.wanted = true;
                streamSpeaker.reopen = root._holdMic();
                streamSpeaker.stdinEnabled = true;
                streamSpeaker.running = true;
            } else {
                root.streamFed = plain.length;
                if (streamSpeaker.started) streamSpeaker.write(fresh);
                else streamSpeaker.pending += fresh;
            }
        }
        if (complete) root._streamClose();
    }
    // The answer is complete: the last sentence said, then the speaker ends.
    function _streamClose() {
        if (!streamSpeaker.running || streamSpeaker.closing) return;
        if (!streamSpeaker.started) {
            streamSpeaker.closeAfter = true;
            return;
        }
        streamSpeaker.closing = true;
        streamSpeaker.stdinEnabled = false;
    }
    Connections {
        target: root.streamTarget
        ignoreUnknownSignals: true
        function onContentChanged() { root._feed(); }
        function onAnsweredChanged() { root._feed(); }
        function onDoneChanged() { root._feed(); }
    }
    // The bubble's answer message appears after the turn started (a
    // one-shot answer, a message made once the privacy mask is done).
    Connections {
        target: Initiative.chat
        ignoreUnknownSignals: true
        function onMessageIDsChanged() {
            if (!root.streamTurn || !Initiative.thinking) return;
            const m = root._lastAssistant();
            if (m && !m.done && !root.streamTarget) {
                root.streamTarget = m;
                root.streamFed = 0;
                root._feed();
            }
        }
    }
    Process {
        id: streamSpeaker
        property string pending: ""
        property bool started: false
        property bool closing: false
        property bool closeAfter: false
        property bool wanted: true
        property bool reopen: false
        command: ["bash", "-c", 'exec setpriv --pdeathsig TERM nixbook-voice-speak --style "$1" --stream', "_", root.voiceStyle]
        stderr: StdioCollector { id: streamSpeakerErr }
        onStarted: {
            streamSpeaker.started = true;
            if (streamSpeaker.pending.length > 0) streamSpeaker.write(streamSpeaker.pending);
            streamSpeaker.pending = "";
            if (streamSpeaker.closeAfter) root._streamClose();
        }
        onExited: (code) => {
            const err = streamSpeakerErr.text;
            streamSpeaker.started = false;
            streamSpeaker.closing = false;
            streamSpeaker.closeAfter = false;
            streamSpeaker.pending = "";
            const again = streamSpeaker.reopen;
            streamSpeaker.reopen = false;
            // No --stream (an older nixbook-voice-speak): the answer read out
            // in one go once complete, as before.
            if (code !== 0 && streamSpeaker.wanted && /unrecognized|usage|invalid choice|no such option/i.test(err)) {
                root.streamUnsupported = true;
                root.streamTurn = false;
                root.streamedTurn = false;
                root.speaking = false;
                if (!Initiative.thinking && root.streamTarget) root.speak(root.lastAnswer());
                return;
            }
            root._spoken(code, streamSpeaker.wanted, again, err, speaker.running);
            // More came while it ended (a fix after the checks): read on.
            if (streamSpeaker.wanted) root._feed();
        }
    }
    Process {
        id: speaker
        property string text: ""
        property bool wanted: true
        // The microphone was closed for it: opened again after.
        property bool reopen: false
        command: ["bash", "-c", 'exec setpriv --pdeathsig TERM nixbook-voice-speak --style "$1" -- "$2"', "_",
            root.voiceStyle, speaker.text]
        stderr: StdioCollector { id: speakerErr }
        onExited: (code) => {
            const again = speaker.reopen;
            speaker.reopen = false;
            root._spoken(code, speaker.wanted, again, speakerErr.text, streamSpeaker.running);
            // The answer being streamed waited for it: read on.
            if (speaker.wanted) root._feed();
        }
    }

    function toggle() {
        // Full AI mode: Mod+T mutes or unmutes the always-open microphone.
        if (FullAi.active) {
            // Talking: Mod+T only cuts it short.
            if (root.speaking) root.stopSpeaking();
            else FullAi.toggleMic();
            return;
        }
        if (root.listening) root.stop();
        else {
            // Talking over it: it stops.
            root.stopSpeaking();
            root.session = root.conversation;
            root.start();
        }
    }
    function start() {
        if (root.listening || root.transcribing) return;
        if (!QuickAi.available) return QuickAi.refuse();
        if (!root.available) {
            Quickshell.execDetached(["notify-send", "-a", "Quick AI", "-t", "4000", Translation.tr("Voice input is off"),
                Translation.tr("Turn it on in Settings > Desktop agents > Quick AI")]);
            return;
        }
        // The bubble shows the listening (called up when it isn't), or stays
        // out of sight (ai.quick.bubble "needed") unless already shown.
        if (root.hideBubble && !(Initiative.speaking && !Initiative.quiet)) Initiative.quiet = true;
        QuickAi.askQuestion("", "voice");
        root.error = "";
        root.heard = false;
        root.level = 0;
        root.partial = "";
        if (root.engine === "meta") {
            // The last stream still closing: started again once it has.
            if (stream.running) {
                stream.again = true;
                return;
            }
            // Full AI mode: one stream for the whole session (each sentence
            // sent when the user pauses, nothing to reopen between orders).
            stream.continuous = FullAi.active;
            // It is talking: the stream opens held (resumed when it is done).
            stream.held = stream.continuous && root.speaking;
            stream.wanted = true;
            stream.frames = 0;
            stream.floor = -50;
            root.listening = true;
            stream.running = true;
            return;
        }
        // It is talking (Full AI mode's greeting, an answer): the mic opens
        // once it is done (the speaker calls relisten), so it doesn't take
        // the room's noise, or a word, from its voice.
        if (root.speaking && FullAi.active) return;
        rec.frames = 0;
        rec.floor = -50;
        rec.first = [];
        rec.loud = 0;
        rec.quiet = 0;
        rec.wanted = true;
        rec.file = `${root.dir}/rec-${Date.now()}.wav`;
        root.listening = true;
        rec.running = true;
        maxTimer.restart();
    }
    // Stops recording; what was said is transcribed and sent.
    function stop() {
        if (!root.listening) return;
        if (stream.running) {
            // The last words come once the audio has ended.
            root.listening = false;
            root.transcribing = true;
            stream.write("stop\n");
            return;
        }
        root.listening = false;
        maxTimer.stop();
        if (rec.running) rec.signal(2); // SIGINT: ffmpeg finishes the file
    }
    // Stops without sending anything.
    // The microphone closed without sending, the session kept.
    function pauseListening() {
        if (stream.running) {
            stream.wanted = false;
            stream.write("cancel\n");
            stream.signal(15);
        }
        if (rec.running) {
            rec.wanted = false;
            rec.signal(2);
        }
        root.listening = false;
        root.partial = "";
        root.level = 0;
        root.delivered();
    }
    function cancel() {
        root.endSession();
        root.stopSpeaking();
        root.voiceTurn = false;
        stream.again = false;
        if (stream.running) {
            stream.wanted = false;
            stream.write("cancel\n");
            stream.signal(15);
        }
        root.partial = "";
        rec.wanted = false;
        root.stop();
        if (transcriber.running) {
            transcriber.wanted = false;
            transcriber.signal(15);
        }
        root.transcribing = false;
        root.level = 0;
        root.delivered();
    }

    // A recording (16 kHz mono WAV, deleted afterwards) taken as said.
    function transcribeFile(path) {
        if (root.listening || root.transcribing || !root.available) return;
        QuickAi.askQuestion("", "voice");
        root.error = "";
        transcriber.file = path;
        transcriber.wanted = true;
        root.transcribing = true;
        transcriber.running = true;
    }

    // The bubble's field is emptied (what was said is sent, or cancelled).
    signal delivered()
    // What was said: sent in the bubble, as if typed there.
    function deliver(text) {
        root.lastText = text;
        root.delivered();
        // "That's all": the conversation ends, nothing sent (not Full AI
        // mode: only Escape leaves it).
        if (root.session && !FullAi.active && root.endWords.test(text.trim())) {
            root.endSession();
            return;
        }
        // A step waiting for an OK: yes or no, said.
        if (QuickAi.pending) {
            if (/^(yes|yeah|yep|sure|ok(ay)?|go( ahead)?|do it|oui|ouais|vas-?y|d'?accord|ja|klar|mach|c[oó]|[dđ][uư][oợ]c|l[aà]m [dđ]i)\b/i.test(text.trim())) {
                QuickAi.approve(true);
                return;
            }
            if (/^(no|nope|don'?t|non|nein|kh[oô]ng)\b/i.test(text.trim())) {
                QuickAi.approve(false);
                return;
            }
        }
        // Full AI mode learns from the answer (its question, what it did alone).
        if (FullAi.active) FullAi.userSaid(text);
        root.voiceTurn = true;
        Initiative.lastQuickText = "";
        if (Initiative.speaking) Initiative.reply(text);
        else QuickAi.askQuestion(text, "voice");
        // Full AI mode: listening again at once (the next order can come
        // while this one is done).
        if (FullAi.active) relisten.restart();
        // A plain command done at once (QuickIntent): what it did, said, then
        // the user's turn again.
        const quick = Initiative.lastQuickText;
        Initiative.lastQuickText = "";
        if (quick.length > 0 && !Initiative.thinking) {
            root.voiceTurn = false;
            if (!root.speak(quick) && root.session && !FullAi.active) relisten.restart();
        }
    }

    Timer {
        id: maxTimer
        interval: root.maxSeconds * 1000
        onTriggered: root.stop()
    }

    // The recording: ffmpeg prints each 50 ms frame's RMS level (dB) while
    // writing the WAV.
    Process {
        id: rec
        property string file: ""
        property bool wanted: true
        // Silence detection against the room's own noise (the floor):
        // speech is 15 dB above it for 150 ms, then anything under half way
        // up to the speaker's level is the pause. The floor is the noise's
        // median, not its quietest frame: behind the echo canceller's noise
        // suppression a room swings 15–20 dB (totoro: -71 to -44 dB), and
        // against its minimum ordinary noise never counted as silence (the
        // turn ran to maxSeconds) while its bumps counted as speech.
        property int frames: 0
        property real floor: -50
        property var first: []
        // The user's speaking level (dB), learnt while they speak.
        property real peak: -30
        property int loud: 0
        property real quiet: 0
        // The recorder never outlives the shell (an orphan would go on
        // listening): stopped when the shell dies (pdeathsig), and after
        // 31 s whatever happens. direct=1: each frame's level written at
        // once, not buffered.
        command: ["bash", "-c", 'mkdir -p -m 700 "$(dirname "$1")" && find "$(dirname "$1")" -name "rec-*.wav" -mmin +1 -delete; src=default; pactl list short sources 2>/dev/null | cut -f2 | grep -qx nixbook-echo-cancel-source && src=nixbook-echo-cancel-source; echo "SOURCE=$src"; '
            + 'exec setpriv --pdeathsig INT timeout -s INT "$2" ffmpeg -hide_banner -loglevel error -nostdin '
            + '-f pulse -i "$src" -ac 1 -ar 16000 '
            + '-af "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=/dev/stdout:direct=1" '
            + '-y "$1"', "_", rec.file, String(Math.ceil(root.maxSeconds) + 1)]
        stdout: SplitParser {
            onRead: (line) => {
                if (line.startsWith("SOURCE=")) {
                    root.source = line.slice(7);
                    return;
                }
                const m = /RMS_level=(-?[0-9.]+|-inf)/.exec(line);
                if (!m || !root.listening) return;
                const db = m[1] === "-inf" ? -90 : parseFloat(m[1]);
                rec.frames++;
                // The meter: above the room's noise (0 when quiet).
                root.level = rec.frames <= 10 ? 0 : Math.max(0, Math.min(1, (db - rec.floor - 6) / 28));
                // The first 200 ms are the device starting (silence, a
                // click); the median of the next 300 ms is the floor.
                if (rec.frames <= 4) return;
                if (rec.frames <= 10) {
                    rec.first = rec.first.concat([db]);
                    if (rec.frames === 10) rec.floor = rec.first.slice().sort((a, b) => a - b)[3];
                    return;
                }
                // Once the user has spoken, still speaking means close to
                // their own level (half way from the noise up to it), so a
                // click or a key well under the voice doesn't hold the turn
                // open; everything under that counts as the pause.
                const talk = rec.floor + Math.max(15, root.heard ? (rec.peak - rec.floor) / 2 : 15);
                const isLoud = db > talk;
                // It follows the noise's median (0.2 dB a frame towards each
                // one), never speech: a fan starting, a quiet room after a
                // noisy start.
                if (db > -85 && db <= rec.floor + 15) rec.floor += db > rec.floor ? 0.2 : -0.2;
                if (isLoud) {
                    rec.loud++;
                    if (rec.loud >= 3 && !root.heard) {
                        root.heard = true;
                        rec.peak = db;
                    }
                    if (root.heard) rec.peak += (db - rec.peak) * 0.1;
                    if (rec.loud >= 2) rec.quiet = 0;
                } else {
                    rec.loud = 0;
                    if (root.heard) {
                        rec.quiet += 0.05;
                        if (rec.quiet >= root.pauseSeconds) root.stop();
                    }
                }
                // Nothing said for 8 s: given up (the card stays, saying so).
                if (!root.heard && rec.frames > 160) root.stop();
            }
        }
        // The SIGINT stop: ffmpeg exits 255. Whatever the code, the file is
        // transcribed if it was wanted.
        onExited: (code) => {
            root.listening = false;
            root.level = 0;
            maxTimer.stop();
            if (!rec.wanted || !root.heard) {
                if (rec.wanted && FullAi.active) relisten.restart();
                else if (rec.wanted && root.session) root.endSession();
                else if (rec.wanted) root.error = Translation.tr("I didn't hear anything");
                Quickshell.execDetached(["rm", "-f", rec.file]);
                return;
            }
            transcriber.file = rec.file;
            transcriber.wanted = true;
            root.transcribing = true;
            transcriber.running = true;
        }
    }

    // Meta: the microphone streamed to Muse Voice Transcribe.
    Process {
        id: stream
        property bool wanted: true
        property bool continuous: false
        property bool held: false
        // start() came while it was still closing.
        property bool again: false
        // The meter against the room's own noise, as for the local engine.
        property int frames: 0
        property real floor: -50
        stdinEnabled: true
        command: ["bash", "-c", 'exec setpriv --pdeathsig TERM nixbook-model-provider run nixbook-voice-stream --lang "$1" --pause "$2" --max "$3" $4 $5', "_",
            root.languages, String(root.pauseSeconds), String(root.maxSeconds), stream.continuous ? "--continuous" : "",
            stream.held ? "--held" : ""]
        stdout: SplitParser {
            onRead: (line) => {
                let ev;
                try { ev = JSON.parse(line); } catch (e) { return; }
                if (!stream.wanted) return;
                switch (ev.type) {
                case "source":
                    root.source = ev.name ?? "";
                    break;
                case "level": {
                    if (!root.listening) break;
                    const db = ev.db ?? -90;
                    stream.frames++;
                    if (stream.frames <= 2) break; // the device starting
                    stream.floor = stream.frames <= 6 ? (stream.frames === 3 ? db : Math.min(stream.floor, db))
                        : (db > -85 ? Math.min(stream.floor, db) : stream.floor);
                    root.level = stream.frames <= 6 ? 0 : Math.max(0, Math.min(1, (db - stream.floor - 2) / 28));
                    break;
                }
                case "speech":
                    root.heard = true;
                    break;
                case "partial":
                    root.heard = true;
                    root.partial = ev.text ?? "";
                    break;
                case "final":
                    // Continuous (Full AI mode): an order, the microphone still
                    // open for the next one.
                    if (!stream.continuous) {
                        root.listening = false;
                        root.transcribing = false;
                        root.level = 0;
                    }
                    root.heard = false;
                    root.partial = "";
                    if ((ev.text ?? "").trim().length > 0) root.deliver(ev.text.trim());
                    break;
                case "nothing":
                    // Silence in a conversation: it ends, quietly; in Full AI
                    // mode it listens on.
                    if (FullAi.active) relisten.restart();
                    else if (root.session) root.endSession();
                    else root.error = Translation.tr("I didn't hear anything");
                    break;
                case "error":
                    root.error = ev.error ?? Translation.tr("Voice failed");
                    break;
                }
            }
        }
        stderr: SplitParser {
            onRead: (line) => {
                if (stream.wanted && /nixbook-model-provider:/.test(line))
                    root.error = line.replace(/^nixbook-model-provider:\s*/, "");
            }
        }
        onExited: {
            root.listening = false;
            root.transcribing = false;
            root.level = 0;
            root.partial = "";
            // Asked to listen while it was closing, or Full AI mode's stream
            // ended (the server, the hour): listening again at once.
            if (stream.again || (stream.wanted && FullAi.active && FullAi.micOn)) {
                stream.again = false;
                reopen.restart();
            }
        }
    }
    Timer {
        id: reopen
        interval: 150
        onTriggered: root.start()
    }

    Process {
        id: transcriber
        property string file: ""
        property bool wanted: true
        command: ["bash", "-c", 'nixbook-voice-transcribe "$1" "$2" "$3"; rc=$?; rm -f "$1"; exit $rc', "_",
            transcriber.file, Config.options.ai.voice?.language || "auto", Config.options.ai.voice?.model || "small"]
        stdout: StdioCollector { id: transcript }
        stderr: StdioCollector { id: transcriptErr }
        onExited: (code) => {
            root.transcribing = false;
            if (!transcriber.wanted) return;
            const text = transcript.text.trim();
            if (code !== 0) {
                root.error = Translation.tr("Transcription failed: %1").arg(transcriptErr.text.trim().split("\n").pop() || code);
                // Full AI mode listens on.
                if (FullAi.active) relisten.restart();
                return;
            }
            if (text.length === 0) {
                if (FullAi.active) relisten.restart();
                else root.error = Translation.tr("I didn't catch that");
                return;
            }
            root.deliver(text);
        }
    }

    IpcHandler {
        target: "voice"
        // Listen (again: stop and send what was said).
        function toggle(): void { root.toggle(); }
        function start(): void { root.start(); }
        // Stop and send what was said.
        function stop(): void { root.stop(); }
        // Stop without sending.
        function cancel(): void { root.cancel(); }
        // Says it out loud (the answers' voice), and stops it.
        function say(text: string): void { root.speak(text); }
        function hush(): void { root.stopSpeaking(); }
        // A recording sent as if it had just been said (16 kHz mono WAV;
        // the file is deleted afterwards).
        function transcribe(path: string): void { root.transcribeFile(path); }
        function status(): string {
            return JSON.stringify({ available: root.available, engine: root.engine, listening: root.listening,
                session: root.session, source: root.source, speaking: root.speaking, speak: root.speakMode,
                transcribing: root.transcribing, heard: root.heard, level: root.level, partial: root.partial,
                error: root.error, last: root.lastText });
        }
    }
}
