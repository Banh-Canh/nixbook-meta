"""A fake Anthropic-compatible Messages API for tests/quick-ai.sh.

Usage: fake-messages.py PORT_FILE REQUESTS_LOG. Listens on 127.0.0.1 (a free
port, written to PORT_FILE) and logs every request body as {n, body}. What
it answers depends on the request:
  - tools offered: a tool call (launch_app firefox, or close_window 7 when
    the order says CLOSE), then, once the tool result comes back, the text;
  - a "replies" task: a JSON object of three replies;
  - text with FAIL500: an HTTP 500; NOEFFORT: a 400 while output_config is
    sent; PRIVATE: an answer naming the masked person back;
  - otherwise "Hello world", streamed in two deltas when asked to stream.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT_FILE, LOG = sys.argv[1], sys.argv[2]
count = 0


def text_of(body):
    out = [body.get("system", "") if isinstance(body.get("system"), str) else ""]
    for m in body.get("messages", []):
        c = m.get("content")
        if isinstance(c, str):
            out.append(c)
        else:
            for b in c or []:
                out.append(str(b.get("text", "")) + str(b.get("content", "")))
    return "\n".join(out)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        global count
        count += 1
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"n": count, "body": body}, ensure_ascii=False) + "\n")
        if self.headers.get("Authorization") != "Bearer test-key":
            return self.send(401, {"error": {"message": "bad key"}})
        text = text_of(body)
        if self.path.startswith("/v1/chat/completions"):
            # The OpenAI-style endpoint: only for CHATOK requests (else the
            # server has none, as Anthropic-compatible ones often).
            if "CHATOK" not in text:
                return self.send(404, {"error": {"message": "not found"}})
            return self.send(200, {"choices": [{"message": {"role": "assistant", "content": "Fast answer"}}],
                                   "effort": body.get("reasoning_effort")})
        if "FAIL500" in text:
            return self.send(500, {"error": {"message": "boom"}})
        if "NOEFFORT" in text and "output_config" in body:
            return self.send(400, {"error": {"message": "unknown parameter `output_config`"}})
        if body.get("tools") and (body.get("tool_choice") or {}).get("type") == "none":
            return self.send(200, {"content": [{"type": "text", "text": "Concluded without more tools."}],
                                   "stop_reason": "end_turn"})
        if body.get("tools") and "LOOP" in text:
            # Never done: a tool call every time (the step limit ends it).
            return self.send(200, {"content": [{"type": "tool_use", "id": f"call_{count}", "name": "launch_app",
                                                "input": {"app": "firefox"}}], "stop_reason": "tool_use"})
        if body.get("tools"):
            last = body["messages"][-1]
            done = isinstance(last.get("content"), list) and any(b.get("type") == "tool_result" for b in last["content"])
            if done:
                denied = any(b.get("is_error") for b in last["content"] if b.get("type") == "tool_result")
                answer = "Not done." if denied else ("Closed." if "CLOSE" in text else "Firefox is open.")
                if "REPORTME" in text:
                    answer = ('Opened it.<report>{"summary": "Firefox is ready", "done": ["Opened Firefox"], '
                              '"failed": [], "needs_you": ["Sign in to your account"]}</report>')
                return self.send(200, {"content": [{"type": "text", "text": answer}], "stop_reason": "end_turn"})
            call = ({"name": "close_window", "input": {"id": 7}} if "CLOSE" in text
                    else {"name": "tasks", "input": {"action": "list"}} if "TASKS" in text
                    else {"name": "launch_app", "input": {"app": "firefox"}})
            return self.send(200, {"content": [{"type": "tool_use", "id": "call_1", **call}], "stop_reason": "tool_use"})
        if '"replies"' in text:
            answer = json.dumps({"replies": ["Oui !", "Pas ce soir", "À quelle heure ?"]}, ensure_ascii=False)
        elif "PRIVATE" in text:
            answer = "Ask ⟦Person 1⟧"
        else:
            answer = "Hello world"
        if not body.get("stream"):
            return self.send(200, {"content": [{"type": "text", "text": answer}]})
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        pieces = ["Hello ", "world"] if answer == "Hello world" else [answer]
        events = [{"type": "message_start", "message": {"model": body.get("model")}},
                  {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}]
        events += [{"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": p}} for p in pieces]
        events += [{"type": "message_stop"}]
        for ev in events:
            self.wfile.write(f"event: {ev['type']}\ndata: {json.dumps(ev, ensure_ascii=False)}\n\n".encode())
        self.wfile.flush()


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
