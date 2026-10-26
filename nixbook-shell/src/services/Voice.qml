pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Talking to the desktop (ai.voice): push to talk (Mod+T, `voice toggle`,
 * the card's mic button). Records the default microphone (PipeWire, 16 kHz
 * mono, ffmpeg), stops by itself once the user has spoken and then been
 * quiet for ai.voice.silenceSeconds (or the key again, or 30 s), and
 * transcribes on this computer with whisper.cpp (`nixbook-voice-transcribe`,
 * nothing leaves it). What was said goes to the Quick AI card: a follow-up
 * when a conversation is open in it, else an order (QuickAi.command: a
 * plain command done at once by QuickIntent, else the model with the
 * desktop tools). The card shows the listening (`level`, a live meter) and
 * the transcribing; Escape cancels.
 */
Singleton {
    id: root

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

    readonly property string dir: `${Directories.runtimeTemp}/voice`

    function toggle() {
        if (root.listening) root.stop();
        else root.start();
    }
    function start() {
        if (root.listening || root.transcribing) return;
        if (!QuickAi.available) return QuickAi.refuse();
        if (!root.available) {
            Quickshell.execDetached(["notify-send", "-a", "Quick AI", "-t", "4000", Translation.tr("Voice input is off"),
                Translation.tr("Turn it on in Settings > Desktop agents > Quick AI")]);
            return;
        }
        // The card shows the listening (an empty one when nothing is open).
        if (!QuickAi.open) QuickAi.askQuestion("", "voice");
        root.error = "";
        root.heard = false;
        root.level = 0;
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
        root.listening = false;
        maxTimer.stop();
        if (rec.running) rec.signal(2); // SIGINT: ffmpeg finishes the file
    }
    // Stops without sending anything.
    function cancel() {
        rec.wanted = false;
        root.stop();
        if (transcriber.running) {
            transcriber.wanted = false;
            transcriber.signal(15);
        }
        root.transcribing = false;
        root.level = 0;
        // A card that only listened: closed.
        if (QuickAi.open && QuickAi.source?.kind === "voice" && !QuickAi.busy && QuickAi.answer.length === 0
                && QuickAi.steps.length === 0 && QuickAi.turns.length === 0)
            QuickAi.close();
    }

    // A recording (16 kHz mono WAV, deleted afterwards) taken as said.
    function transcribeFile(path) {
        if (root.listening || root.transcribing || !root.available) return;
        if (!QuickAi.open) QuickAi.askQuestion("", "voice");
        root.error = "";
        transcriber.file = path;
        transcriber.wanted = true;
        root.transcribing = true;
        transcriber.running = true;
    }

    // What was said: into the conversation open in the card, else an order.
    function deliver(text) {
        root.lastText = text;
        const conversing = QuickAi.open && (QuickAi.answer.length > 0 || QuickAi.turns.length > 0
            || QuickAi.steps.length > 0 || QuickAi.busy) && !QuickAi.instant;
        if (conversing) QuickAi.followUp(text);
        else QuickAi.command(text, "voice");
    }

    Timer {
        id: maxTimer
        interval: 30000
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
        command: ["bash", "-c", 'mkdir -p -m 700 "$(dirname "$1")" && find "$(dirname "$1")" -name "rec-*.wav" -mmin +1 -delete; exec setpriv --pdeathsig INT timeout -s INT 31 ffmpeg -hide_banner -loglevel error -nostdin '
            + '-f pulse -i default -ac 1 -ar 16000 '
            + '-af "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=/dev/stdout:direct=1" '
            + '-y "$1"', "_", rec.file]
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
                        if (rec.quiet >= (Config.options.ai.voice?.silenceSeconds ?? 1.2)) root.stop();
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
                if (rec.wanted) root.error = Translation.tr("I didn't hear anything");
                Quickshell.execDetached(["rm", "-f", rec.file]);
                return;
            }
            transcriber.file = rec.file;
            transcriber.wanted = true;
            root.transcribing = true;
            transcriber.running = true;
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
        // A recording sent as if it had just been said (16 kHz mono WAV;
        // the file is deleted afterwards).
        function transcribe(path: string): void { root.transcribeFile(path); }
        function status(): string {
            return JSON.stringify({ available: root.available, listening: root.listening, transcribing: root.transcribing,
                heard: root.heard, level: root.level, error: root.error, last: root.lastText });
        }
    }
}
