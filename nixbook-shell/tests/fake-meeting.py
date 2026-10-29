"""A fake Meta for tests/meeting.sh: Muse Voice Transcribe's realtime
WebSocket (GET /v1/asr/realtime) and the Messages API (POST /v1/messages),
on one port as the real base URL has both.

Usage: fake-meeting.py PORT_FILE LOG. Listens on 127.0.0.1 (a free port,
written to PORT_FILE); logs each session's hello ({kind: "asr", hello}) and
each model request ({kind: "messages", body}) as JSON lines.

The ASR session plays a script picked by the audio it gets: the tests' WAVs
are a constant sample, 1000 for the call's side, 2000 for the microphone.
Each event is sent once that many seconds of audio have come in.
The Messages API answers a structured_output call by the system prompt:
the translation (the French line in English, the others null), the running
notes and the record. /v1/chat/completions is 404 (the Messages API used).
"""

import base64
import hashlib
import json
import re
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE, LOG = sys.argv[1], sys.argv[2]
lock = threading.Lock()

SCRIPTS = {
    1000: [(0.2, {"type": "speechStart"}), (0.3, {"type": "transcript", "transcript": "Bonjour à tous"}),
           (0.5, {"type": "transcript", "transcript": "Bonjour à tous, on commence"}),
           (0.6, {"type": "speechComplete", "transcript": "Bonjour à tous, on commence."}),
           (0.9, {"type": "speechStart"}),
           (1.2, {"type": "speechComplete", "transcript": "Alice will send the report by Friday."})],
    2000: [(0.4, {"type": "speechStart"}),
           (0.7, {"type": "speechComplete", "transcript": "I agree, we ship it on Monday then."})],
}


def log(entry):
    with lock, open(LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    # -- the WebSocket --------------------------------------------------------
    def frame(self):
        head = self.rfile.read(2)
        if len(head) < 2:
            return None, None
        opcode, n = head[0] & 0x0F, head[1] & 0x7F
        if n == 126:
            n = struct.unpack(">H", self.rfile.read(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self.rfile.read(8))[0]
        mask = self.rfile.read(4) if head[1] & 0x80 else b"\0\0\0\0"
        data = bytes(b ^ mask[i % 4] for i, b in enumerate(self.rfile.read(n)))
        return opcode, data

    def send_text(self, obj):
        data = json.dumps(obj).encode()
        n = len(data)
        head = bytes([0x81, n]) if n < 126 else bytes([0x81, 126]) + struct.pack(">H", n)
        self.wfile.write(head + data)
        self.wfile.flush()

    def do_GET(self):
        if not self.path.startswith("/v1/asr/realtime") or "websocket" not in (self.headers.get("Upgrade") or "").lower():
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"]
                                                + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        _, hello = self.frame()
        log({"kind": "asr", "hello": json.loads(hello or b"{}")})
        self.send_text({"type": "session", "sessionId": "s1"})
        script, seconds = None, 0.0
        while True:
            opcode, data = self.frame()
            if opcode is None or opcode == 0x8:
                break
            if opcode == 0x1:
                if json.loads(data).get("type") == "endStream":
                    for _, ev in script or []:
                        self.send_text(ev)
                    break
                continue
            if opcode != 0x2 or not data:
                continue
            if script is None:
                sample = struct.unpack("<h", data[:2])[0]
                script = list(SCRIPTS.get(sample, []))
            seconds += len(data) / 32000
            while script and script[0][0] <= seconds:
                self.send_text(script.pop(0)[1])
        try:
            self.wfile.write(bytes([0x88, 0]))
            self.wfile.flush()
        except OSError:
            pass
        self.close_connection = True

    # -- the Messages API -----------------------------------------------------
    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        log({"kind": "messages", "path": self.path, "body": body})
        if not self.path.startswith("/v1/messages"):
            return self.reply(404, {"error": {"message": "not here"}})
        system = body.get("system") if isinstance(body.get("system"), str) else json.dumps(body.get("system"))
        prompt = json.dumps(body.get("messages"), ensure_ascii=False)
        if "translate the live captions" in system:
            lines = re.findall(r"(\d+)\. ([^\\\n]*)", json.loads(prompt)[0]["content"])
            value = {"lines": [{"n": int(n), "text": "Hello everyone, let's start." if "Bonjour" in t else None}
                               for n, t in lines]}
        elif "running notes of a call" in system:
            who = "⟦Person 1⟧" if "⟦Person 1⟧" in prompt else "Alice"
            value = {"topics": ["The report"], "decisions": ["Ship on Monday"],
                     "actions": [{"what": "Send the report", "owner": who, "due": "Friday"}]}
        elif "The call is over" in system:
            who = "⟦Person 1⟧" if "⟦Person 1⟧" in prompt else "Alice"
            value = {"title": "Weekly sync", "summary": f"The team agreed to ship on Monday; {who} sends the report.",
                     "decisions": ["Ship on Monday"], "actions": [{"what": "Send the report", "owner": who,
                                                                    "due": "Friday"}],
                     "questions": [], "followup": {"subject": "Weekly sync", "body": f"Thanks all. {who} sends the report by Friday."}}
        else:
            value = {}
        self.reply(200, {"id": "msg", "type": "message", "role": "assistant", "model": body.get("model"),
                         "content": [{"type": "tool_use", "id": "t1", "name": "structured_output", "input": value}],
                         "stop_reason": "tool_use", "usage": {"input_tokens": 10, "output_tokens": 5}})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
