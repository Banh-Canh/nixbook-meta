pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Talking to the desktop (ai.voice): push to talk (Mod+T, `voice toggle`,
 * the mic button of Claude's speech bubble). Two engines (ai.voice.engine; "auto": Meta when
 * it is the model provider with a key, else this computer):
 *   - meta: the microphone streamed to Muse Voice Transcribe while the user
 *     speaks (`nixbook-voice-stream`, scripts/voice-stream.py): the words
 *     show as they are recognised (`partial`) and the server says when the
 *     speech has ended; nothing heavy runs here;
 *   - local: records (PipeWire, 16 kHz mono, ffmpeg), stops once the user
 *     has spoken and then been quiet for ai.voice.pauseSeconds (or the key
 *     again, or ai.voice.maxSeconds), and transcribes with whisper.cpp
 *     (`nixbook-voice-transcribe`, nothing leaves the computer).
 * It all happens in Claude's speech bubble (the Mod+C one, AgentSpeech.qml):
 * listening calls it up, the words show in its field as they come, and
 * what was said is sent there (Initiative.reply: a plain command done at
 * once by QuickIntent, else Quick AI answers or acts with the desktop
 * tools, or Claude in its own thread). Escape in the bubble cancels.
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
    }
    Timer {
        id: relisten
        interval: 700
        onTriggered: {
            if (!root.session || root.listening || root.transcribing || root.speaking || !Initiative.speaking) return;
            if (Initiative.thinking && !QuickAi.pending) return;
            root.start();
        }
    }
    Connections {
        target: Initiative
        function onThinkingChanged() {
            if (Initiative.thinking) return;
            // The answer to what was said, read out (then the mic again).
            if (root.wantsSpeech()) root.speak(root.lastAnswer());
            else if (root.session) relisten.restart();
        }
        function onSpeakingChanged() {
            if (!Initiative.speaking) {
                root.endSession();
                root.stopSpeaking();
            }
        }
    }
    Connections {
        target: QuickAi
        function onPendingChanged() {
            if (!QuickAi.pending || !(root.session || root.voiceTurn)) return;
            // A step waiting for an OK, asked out loud: answered by voice.
            const what = QuickAi.pending.tool.replace(/_/g, " ") + (QuickAi.pending.summary ? `, ${QuickAi.pending.summary}` : "");
            if (!root.speak(Translation.tr("May I %1?").arg(what))) relisten.restart();
        }
    }

    // ── The agent's answers read out (ai.voice.speak: "voice", the answers to
    // what was said; "always"; "never"), by Piper on this computer
    // (`nixbook-voice-speak`: Meta has no speech synthesis). The microphone
    // waits until it has finished; Mod+T or Escape cuts it short.
    property bool speaking: false
    // The last message was said, not typed: its answer is read out.
    property bool voiceTurn: false
    readonly property string speakMode: Config.options.ai.voice?.speak ?? "voice"
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
    function speak(text) {
        if (root.speakMode === "never" || !String(text ?? "").trim()) return false;
        root.stopSpeaking();
        speaker.text = String(text);
        speaker.wanted = true;
        root.speaking = true;
        speaker.running = true;
        return true;
    }
    function stopSpeaking() {
        if (speaker.running) {
            speaker.wanted = false;
            speaker.signal(15);
        }
        root.speaking = false;
    }
    Process {
        id: speaker
        property string text: ""
        property bool wanted: true
        command: ["bash", "-c", 'exec setpriv --pdeathsig TERM nixbook-voice-speak --lang "$1" "$2"', "_",
            "auto", speaker.text]
        onExited: {
            root.speaking = false;
            // Said: the user's turn (a conversation).
            if (speaker.wanted && root.session) relisten.restart();
        }
    }
    function toggle() {
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
        // The bubble shows the listening (called up when it isn't).
        QuickAi.askQuestion("", "voice");
        root.error = "";
        root.heard = false;
        root.level = 0;
        root.partial = "";
        if (root.engine === "meta") {
            stream.wanted = true;
            stream.frames = 0;
            stream.floor = -50;
            root.listening = true;
            stream.running = true;
            return;
        }
        rec.frames = 0;
        rec.floor = -50;
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
    function cancel() {
        root.endSession();
        root.stopSpeaking();
        root.voiceTurn = false;
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
        // "That's all": the conversation ends, nothing sent.
        if (root.session && root.endWords.test(text.trim())) {
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
        root.voiceTurn = true;
        if (Initiative.speaking) Initiative.reply(text);
        else QuickAi.askQuestion(text, "voice");
        // A plain command done at once (QuickIntent): what it did, said.
        if (Initiative.speaking?.kind === "quick" && !Initiative.thinking) {
            root.voiceTurn = false;
            if (!(root.speakMode !== "never" && root.speak(Initiative.speaking.text)) && root.session) relisten.restart();
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
        // speech is 10 dB above it, silence under 5 dB above.
        property int frames: 0
        property real floor: -50
        property int loud: 0
        property real quiet: 0
        // The recorder never outlives the shell (an orphan would go on
        // listening): stopped when the shell dies (pdeathsig), and after
        // 31 s whatever happens. direct=1: each frame's level written at
        // once, not buffered.
        command: ["bash", "-c", 'mkdir -p -m 700 "$(dirname "$1")" && find "$(dirname "$1")" -name "rec-*.wav" -mmin +1 -delete; exec setpriv --pdeathsig INT timeout -s INT "$2" ffmpeg -hide_banner -loglevel error -nostdin '
            + '-f pulse -i default -ac 1 -ar 16000 '
            + '-af "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=/dev/stdout:direct=1" '
            + '-y "$1"', "_", rec.file, String(Math.ceil(root.maxSeconds) + 1)]
        stdout: SplitParser {
            onRead: (line) => {
                const m = /RMS_level=(-?[0-9.]+|-inf)/.exec(line);
                if (!m || !root.listening) return;
                const db = m[1] === "-inf" ? -90 : parseFloat(m[1]);
                rec.frames++;
                // The meter: above the room's noise (0 when quiet).
                root.level = rec.frames <= 10 ? 0 : Math.max(0, Math.min(1, (db - rec.floor - 2) / 28));
                // The first 200 ms are the device starting (silence, a
                // click); the quietest of the next 300 ms is the floor, and
                // it only goes down after (speech never raises it).
                if (rec.frames <= 4) return;
                if (rec.frames <= 10) {
                    rec.floor = rec.frames === 5 ? db : Math.min(rec.floor, db);
                    return;
                }
                if (db > -85) rec.floor = Math.min(rec.floor, db);
                if (db > rec.floor + 10) {
                    rec.loud++;
                    rec.quiet = 0;
                    if (rec.loud >= 2) root.heard = true;
                } else if (db < rec.floor + 5) {
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
                if (rec.wanted && root.session) root.endSession();
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
        // The meter against the room's own noise, as for the local engine.
        property int frames: 0
        property real floor: -50
        stdinEnabled: true
        command: ["bash", "-c", 'exec setpriv --pdeathsig TERM nixbook-model-provider run nixbook-voice-stream --lang "$1" --pause "$2" --max "$3"', "_",
            root.languages, String(root.pauseSeconds), String(root.maxSeconds)]
        stdout: SplitParser {
            onRead: (line) => {
                let ev;
                try { ev = JSON.parse(line); } catch (e) { return; }
                if (!stream.wanted) return;
                switch (ev.type) {
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
                    root.listening = false;
                    root.transcribing = false;
                    root.level = 0;
                    root.partial = "";
                    if ((ev.text ?? "").trim().length > 0) root.deliver(ev.text.trim());
                    break;
                case "nothing":
                    // Silence in a conversation: it ends, quietly.
                    if (root.session) root.endSession();
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
        }
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
                return;
            }
            if (text.length === 0) {
                root.error = Translation.tr("I didn't catch that");
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
        // Read a text out (the agent's voice); stop reading.
        function say(text: string): void { root.speak(text); }
        function hush(): void { root.stopSpeaking(); }
        // A recording sent as if it had just been said (16 kHz mono WAV;
        // the file is deleted afterwards).
        function transcribe(path: string): void { root.transcribeFile(path); }
        function status(): string {
            return JSON.stringify({ available: root.available, engine: root.engine, listening: root.listening,
                speaking: root.speaking, session: root.session,
                transcribing: root.transcribing, heard: root.heard, level: root.level, partial: root.partial,
                error: root.error, last: root.lastText });
        }
    }
}
