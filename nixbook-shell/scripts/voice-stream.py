"""nixbook-voice-stream: what the user says, transcribed by Meta's Muse
Voice Transcribe while they speak (services/Voice.qml, ai.voice.engine
meta). The microphone (PipeWire through ffmpeg, 16 kHz mono PCM) is
streamed to wss://api.meta.ai/v1/asr/realtime in ENDPOINTING mode: the
server says when the speech has ended, so nothing waits on a local silence
detector, and the words show up as they are recognised. The computer only
records; no model runs on it.

Run through `nixbook-model-provider run nixbook-voice-stream [--lang L]
[--file WAV]` (the key and the server from the Meta provider). One JSON
object per line on stdout:
  {"type": "source", "name"}        the microphone recorded (the echo-
                                    cancelled one when it exists)
  {"type": "ready"}                 the server took the session
  {"type": "level", "db"}           the microphone's level, every 80 ms
  {"type": "speech"}                speech started
  {"type": "partial", "text"}       what is recognised so far
  {"type": "final", "text"}         the whole utterance (then it exits)
  {"type": "nothing"}               nothing said (8 s), or stopped before
  {"type": "error", "error"}
stdin: "stop" (the key again: the audio ends, the last words are awaited),
"cancel" (gone at once), "hold" / "resume" (the agent speaking: silence
streamed instead of the microphone; --held starts held). --file streams a WAV (16 kHz mono 16-bit) at real
time instead of the microphone (tests).
"""

import base64
import json
import queue
import math
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.parse

RATE = 16000
CHUNK = RATE * 2 * 80 // 1000  # 80 ms of 16-bit mono
NOTHING_AFTER = 8.0
# A sentence can take a pause: the server ends a turn at each, the user's
# message ends only once no new speech starts within `pause` seconds.
PAUSE_SECONDS = 1.8
MAX_SECONDS = 120.0
LANGS = {"en": "English", "fr": "French", "de": "German", "vi": "Vietnamese", "es": "Spanish",
         "it": "Italian", "ja": "Japanese", "zh": "Chinese", "pt": "Portuguese", "nl": "Dutch",
         "ko": "Korean", "ru": "Russian", "ar": "Arabic", "hi": "Hindi"}

out_lock = threading.Lock()


def emit(kind, **fields):
    with out_lock:
        sys.stdout.write(json.dumps({"type": kind, **fields}, ensure_ascii=False) + "\n")
        sys.stdout.flush()


class WebSocket:
    """The little of RFC 6455 a client needs: text and binary frames out
    (masked), text/close/ping in."""

    def __init__(self, url, timeout=15):
        u = urllib.parse.urlsplit(url)
        port = u.port or (443 if u.scheme == "wss" else 80)
        raw = socket.create_connection((u.hostname, port), timeout=timeout)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=u.hostname) if u.scheme == "wss" else raw
        key = base64.b64encode(os.urandom(16)).decode()
        path = u.path + ("?" + u.query if u.query else "")
        self.sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {u.hostname}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            data = self.sock.recv(4096)
            if not data:
                raise ConnectionError("the server closed the connection during the handshake")
            head += data
        head, self.buf = head.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n", 1)[0].decode("latin-1")
        if " 101 " not in status + " ":
            raise ConnectionError(f"the server refused the WebSocket: {status}")
        self.sock.settimeout(None)
        self.send_lock = threading.Lock()
        self.closed = False

    def send(self, payload, opcode):
        mask = os.urandom(4)
        n = len(payload)
        head = bytes([0x80 | opcode])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        with self.send_lock:
            if not self.closed:
                self.sock.sendall(head + mask + body)

    def send_text(self, text):
        self.send(text.encode(), 0x1)

    def send_binary(self, data):
        self.send(data, 0x2)

    def _read(self, n):
        while len(self.buf) < n:
            data = self.sock.recv(65536)
            if not data:
                raise ConnectionError("closed")
            self.buf += data
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        """The next text message, or None once closed."""
        message = b""
        while True:
            b1, b2 = self._read(2)
            opcode, n = b1 & 0x0F, b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b2 & 0x80 else None
            data = self._read(n)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x8:
                self.closed = True
                return None
            if opcode == 0x9:
                self.send(data, 0xA)
                continue
            if opcode in (0x0, 0x1, 0x2):
                message += data
                if b1 & 0x80:
                    return message.decode("utf-8", "replace")

    def close(self):
        try:
            self.send(struct.pack(">H", 1000), 0x8)
        except OSError:
            pass
        self.closed = True
        try:
            self.sock.close()
        except OSError:
            pass


# The voice's microphone without the computer's own sound (the PipeWire
# echo canceller of programs.nixbook-shell.voice.echoCancel), else the
# default one. NIXBOOK_VOICE_SOURCE forces one.
ECHO_CANCEL_SOURCE = "nixbook-echo-cancel-source"


def microphone():
    forced = os.environ.get("NIXBOOK_VOICE_SOURCE")
    if forced:
        return forced
    pactl = shutil.which("pactl")
    if pactl:
        try:
            out = subprocess.run([pactl, "list", "short", "sources"], capture_output=True, text=True, timeout=3).stdout
        except (OSError, subprocess.TimeoutExpired):
            out = ""
        if any(line.split("\t")[1:2] == [ECHO_CANCEL_SOURCE] for line in out.splitlines()):
            return ECHO_CANCEL_SOURCE
    return "default"


def audio_source(path):
    """The microphone (ffmpeg from PipeWire's default source), or a WAV
    paced at real time: a file-like object of raw 16 kHz mono PCM."""
    if path:
        f = open(path, "rb")
        head = f.read(12)
        if head[:4] != b"RIFF":
            raise ValueError("not a WAV file")
        while True:  # the data chunk
            cid, size = f.read(4), struct.unpack("<I", f.read(4))[0]
            if cid == b"data":
                break
            f.seek(size, 1)
        return f, None
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg isn't installed")
    source = microphone()
    emit("source", name=source)
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "pulse", "-i", source,
           "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"]
    setpriv = shutil.which("setpriv")
    if setpriv:  # never outlives this script
        cmd = [setpriv, "--pdeathsig", "TERM", *cmd]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stdin=subprocess.DEVNULL)
    return proc.stdout, proc


def level_db(chunk):
    n = len(chunk) // 2
    if n == 0:
        return -90.0
    samples = struct.unpack(f"<{n}h", chunk[:n * 2])
    rms = math.sqrt(sum(s * s for s in samples) / n) / 32768
    return round(20 * math.log10(rms), 1) if rms > 0 else -90.0


def main(argv):
    langs, path, continuous, held = [], None, False, False
    pause, longest = PAUSE_SECONDS, MAX_SECONDS
    args = list(argv[1:])
    while args:
        a = args.pop(0)
        if a == "--pause" and args:
            pause = max(0.5, min(10.0, float(args.pop(0))))
            continue
        if a == "--max" and args:
            longest = max(5.0, min(600.0, float(args.pop(0))))
            continue
        if a == "--continuous":
            # Full AI mode: one stream for the whole session, each utterance
            # sent as a "final" when the user pauses, the microphone kept
            # open (no reconnecting between orders).
            continuous = True
            continue
        if a == "--held":
            held = True
            continue
        if a == "--lang" and args:
            # A hint, not a constraint: "fr,en" (the interface's, then English).
            langs = [LANGS[c.strip()[:2].lower()] for c in args.pop(0).split(",") if c.strip()[:2].lower() in LANGS]
        elif a == "--file" and args:
            path = args.pop(0)
    base = os.environ.get("ANTHROPIC_BASE_URL", "")
    key = os.environ.get("ANTHROPIC_AUTH_TOKEN", "")
    if not base or not key:
        emit("error", error="voice through Meta needs the Meta model provider and its key "
                            "(Settings > Desktop agents > Model provider)")
        return 2
    u = urllib.parse.urlsplit(base.rstrip("/"))
    url = f"{'wss' if u.scheme == 'https' else 'ws'}://{u.netloc}/v1/asr/realtime"
    # The microphone first: what is said while the connection opens (about
    # a second) waits in the queue (the server takes up to 5 s of backlog).
    try:
        source, proc = audio_source(path)
    except Exception as e:  # noqa: BLE001
        emit("error", error=f"the microphone: {e}")
        return 1
    chunks = queue.Queue()
    paced = path is not None

    def capture():
        try:
            while True:
                chunk = source.read(CHUNK)
                if not chunk:
                    break
                chunks.put(chunk)
                emit("level", db=level_db(chunk))
                if paced:
                    time.sleep(len(chunk) / (RATE * 2))
        except (OSError, ValueError):
            pass
        chunks.put(None)

    threading.Thread(target=capture, daemon=True).start()
    try:
        ws = WebSocket(url)
        hello = {"authorization": {"accessToken": f"Bearer {key}"}, "audioEncoding": "PCM_16KHZ",
                 "model": os.environ.get("NIXBOOK_VOICE_MODEL", "muse-voice-transcribe-1.0"),
                 "mode": "ENDPOINTING", "partialMode": "CUMULATIVE", "emitAudioProgress": False}
        if langs:
            hello["languageBias"] = list(dict.fromkeys(langs))
        ws.send_text(json.dumps(hello))
        ack = json.loads(ws.recv() or "{}")
        if ack.get("type") == "error" or "sessionId" not in ack:
            raise ConnectionError(ack.get("message") or "the server refused the session")
    except Exception as e:  # noqa: BLE001 — every failure is the card's to show
        if proc:
            proc.terminate()
        emit("error", error=f"Meta voice: {e}")
        return 1
    emit("ready")

    state = {"done": False, "ending": False, "heard": False, "parts": [], "partial": "", "error": None,
             "speaking": False, "lastEnd": 0.0, "held": held}
    done = threading.Event()

    def reader():
        try:
            while True:
                text = ws.recv()
                if text is None:
                    break
                try:
                    ev = json.loads(text)
                except ValueError:
                    continue
                kind = ev.get("type")
                if kind == "speechStart":
                    state["heard"] = True
                    state["speaking"] = True
                    emit("speech")
                elif kind == "transcript":
                    state["partial"] = ev.get("transcript", "")
                    whole = " ".join(state["parts"] + [state["partial"]]).strip()
                    if whole:
                        state["heard"] = True
                        emit("partial", text=whole)
                elif kind == "speechEnd":
                    state["speaking"] = False
                    state["lastEnd"] = time.monotonic()
                elif kind == "speechComplete":
                    said = (ev.get("transcript") or state["partial"]).strip()
                    if said:
                        state["parts"].append(said)
                    state["partial"] = ""
                    state["speaking"] = False
                    state["lastEnd"] = time.monotonic()
                elif kind == "error":
                    state["error"] = ev.get("message") or "error"
                    break
        except (OSError, ConnectionError):
            pass
        done.set()

    def commands():
        for line in sys.stdin:
            cmd = line.strip()
            if cmd == "cancel":
                state["done"] = True
                done.set()
                return
            if cmd == "stop":
                state["ending"] = True
                return
            # The agent speaking: silence sent instead of the microphone (it
            # never hears itself), the stream kept open.
            if cmd == "hold":
                state["held"] = True
            if cmd == "resume":
                state["held"] = False

    threading.Thread(target=reader, daemon=True).start()
    threading.Thread(target=commands, daemon=True).start()

    started = time.monotonic()
    if continuous:
        longest = 3600.0
    finished = False
    try:
        while not done.is_set() and not state["ending"]:
            try:
                chunk = chunks.get(timeout=0.5)
            except queue.Empty:
                continue
            if chunk is None:
                break
            ws.send_binary(bytes(len(chunk)) if state.get("held") else chunk)
            now = time.monotonic()
            elapsed = now - started
            if not continuous and not state["heard"] and elapsed > NOTHING_AFTER:
                break
            if elapsed > longest:
                break
            # The user has finished: words said, then a long enough pause.
            if state["parts"] and not state["speaking"] and not state["partial"] and now - state["lastEnd"] > pause:
                if not continuous:
                    finished = True
                    break
                said, state["parts"], state["heard"] = " ".join(state["parts"]).strip(), [], False
                if said:
                    emit("final", text=said)
    except (OSError, ConnectionError):
        pass
    finally:
        if proc:
            proc.terminate()
    # Words still being recognised (the key pressed mid-sentence, the file
    # or the time over): the server's last ones, a moment at most. A user
    # who just paused has nothing pending: gone at once (the microphone
    # reopens without waiting for the server to close).
    if not state["done"] and not done.is_set() and (not finished or state["speaking"] or state["partial"]):
        try:
            ws.send_text(json.dumps({"type": "endStream"}))
        except OSError:
            pass
        done.wait(3)
    ws.close()
    if state["done"]:
        return 0
    if state["error"]:
        emit("error", error=f"Meta voice: {state['error']}")
        return 1
    said = " ".join(state["parts"] + ([state["partial"]] if state["partial"] else [])).strip()
    if said:
        emit("final", text=said)
    else:
        emit("nothing")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
