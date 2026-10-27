"""A fake Messages API (Meta's wire protocol) for tests/quick-ai.sh and
tests/meta-agent.sh.

Usage: fake-messages.py PORT_FILE REQUESTS_LOG [SCRIPTS_DIR]. Listens on
127.0.0.1 (a free port, written to PORT_FILE) and logs every request body as
{n, path, body}. What it answers depends on the request:
  - AGENTTEST:NAME in it (and a SCRIPTS_DIR): the scripted conversation
    SCRIPTS_DIR/NAME.json, a list of replies, the one taken being the number
    of assistant messages already in the request (the last one repeats).
    A reply is a content list, {content, stop_reason}, {status, error}, or
    {tool_choice: A, otherwise: B} (A when the request forces a tool);
    streamed when the request asks for it. The file may also be an object
    {steps: [the list], system: {TEXT: reply}}: a request whose system
    prompt contains TEXT gets that reply (a side call: the agent's request
    resolver), the others the steps;
  - text with RETRY429:N: an HTTP 429 (retry-after 0) the first N times;
  - GET /page: an HTML page; GET /search?q=: a search engine's results page;
  - tools offered: a tool call (launch_app firefox, or close_window 7 when
    the order says CLOSE), then, once the tool result comes back, the text;
  - a "replies" task: a JSON object of three replies;
  - text with FAIL500: an HTTP 500; NOEFFORT: a 400 while output_config is
    sent; BIGTOKENS: a 400 naming max_tokens above 8192; PRIVATE: an answer
    naming the masked person back;
  - otherwise "Hello world", streamed in two deltas when asked to stream.
"""

import json
import os
import re
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT_FILE, LOG = sys.argv[1], sys.argv[2]
SCRIPTS = sys.argv[3] if len(sys.argv) > 3 else ""
count = 0
busy = {}

PAGE = """<!doctype html><html><head><title>Fake page</title><style>p{color:red}</style>
<script>var hidden = 1;</script></head><body><h1>Muse news</h1><p>The answer is <b>42</b>.</p></body></html>"""
SEARCH = """<html><body><div class="result"><a rel="nofollow" class="result__a"
href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fnixos&amp;rut=x">NixOS <b>wiki</b></a>
<a class="result__snippet" href="x">The <b>purely functional</b> distribution.</a></div>
<div class="result"><a class="result__a" href="https://blocked.example/a">Blocked</a>
<a class="result__snippet" href="y">Not shown.</a></div></body></html>"""


def events_of(content, stop_reason, model):
    """A reply as the stream events it is made of."""
    out = [{"type": "message_start", "message": {"model": model, "role": "assistant", "content": [],
                                                 "usage": {"input_tokens": 10, "output_tokens": 0}}}]
    for i, b in enumerate(content):
        t = b.get("type")
        if t == "text":
            out.append({"type": "content_block_start", "index": i, "content_block": {"type": "text", "text": ""}})
            words = b["text"].split(" ")
            for j, w in enumerate(words):
                out.append({"type": "content_block_delta", "index": i,
                            "delta": {"type": "text_delta", "text": w + (" " if j < len(words) - 1 else "")}})
        elif t == "thinking":
            out.append({"type": "content_block_start", "index": i, "content_block": {"type": "thinking", "thinking": ""}})
            out.append({"type": "content_block_delta", "index": i,
                        "delta": {"type": "thinking_delta", "thinking": b.get("thinking", "")}})
            out.append({"type": "content_block_delta", "index": i, "delta": {"type": "signature_delta", "signature": "sig"}})
        elif t == "tool_use":
            out.append({"type": "content_block_start", "index": i,
                        "content_block": {"type": "tool_use", "id": b["id"], "name": b["name"], "input": {}}})
            raw = json.dumps(b.get("input") or {})
            half = len(raw) // 2
            for piece in (raw[:half], raw[half:]):
                out.append({"type": "content_block_delta", "index": i,
                            "delta": {"type": "input_json_delta", "partial_json": piece}})
        out.append({"type": "content_block_stop", "index": i})
    out.append({"type": "message_delta", "delta": {"stop_reason": stop_reason}, "usage": {"output_tokens": 5}})
    out.append({"type": "message_stop"})
    return out


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

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        if u.path == "/page":
            data, ctype = PAGE.encode(), "text/html; charset=utf-8"
        elif u.path == "/search":
            q = urllib.parse.parse_qs(u.query).get("q", [""])[0]
            data, ctype = SEARCH.replace("NixOS", "NixOS" if q else "none").encode(), "text/html"
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def scripted(self, body, text):
        m = re.search(r"AGENTTEST:(\w+)", text)
        if not m or not SCRIPTS:
            return False
        with open(os.path.join(SCRIPTS, m.group(1) + ".json"), encoding="utf-8") as f:
            replies = json.load(f)
        reply = None
        if isinstance(replies, dict):
            system = body.get("system")
            system = system if isinstance(system, str) else " ".join(str(b.get("text", "")) for b in system or [])
            reply = next((r for k, r in (replies.get("system") or {}).items() if k in system), None)
            replies = replies.get("steps") or [[{"type": "text", "text": "…"}]]
        if reply is None:
            step = sum(1 for msg in body.get("messages", []) if msg.get("role") == "assistant")
            reply = replies[min(step, len(replies) - 1)]
        if isinstance(reply, dict) and "otherwise" in reply:
            # {"tool_choice": A, "otherwise": B}: A when a tool is forced.
            reply = reply["tool_choice"] if body.get("tool_choice") else reply["otherwise"]
        if isinstance(reply, dict) and "status" in reply:
            self.send(reply["status"], {"type": "error", "error": {"message": reply.get("error", "")}})
            return True
        content = reply if isinstance(reply, list) else reply.get("content", [])
        stop = "tool_use" if any(b.get("type") == "tool_use" for b in content) else "end_turn"
        if isinstance(reply, dict) and reply.get("stop_reason"):
            stop = reply["stop_reason"]
        if not body.get("stream"):
            self.send(200, {"type": "message", "role": "assistant", "model": body.get("model"), "content": content,
                            "stop_reason": stop, "usage": {"input_tokens": 10, "output_tokens": 5}})
            return True
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        for ev in events_of(content, stop, body.get("model")):
            self.wfile.write(f"event: {ev['type']}\ndata: {json.dumps(ev, ensure_ascii=False)}\n\n".encode())
        self.wfile.flush()
        return True

    def do_POST(self):
        global count
        count += 1
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"n": count, "path": self.path, "body": body}, ensure_ascii=False) + "\n")
        if self.headers.get("Authorization") != "Bearer test-key":
            return self.send(401, {"error": {"message": "bad key"}})
        text = text_of(body)
        if self.path.startswith("/v1/chat/completions") and "Something just happened" not in text:
            # The OpenAI-style endpoint: only for CHATOK requests (else the
            # server has none, as many Messages API servers).
            if "CHATOK" not in text:
                return self.send(404, {"error": {"message": "not found"}})
            return self.send(200, {"choices": [{"message": {"role": "assistant", "content": "Fast answer"}}],
                                   "effort": body.get("reasoning_effort")})
        if "Something just happened" in text:
            # Full AI mode's reactions: what the event says it should do.
            if "TOLDIT" in text:
                d = {"action": "do", "say": "Done as you said.", "instruction": "Reply OK", "basis": "told"}
            elif "GUESSDO" in text:
                d = {"action": "do", "say": "I'll handle it.", "instruction": "Delete it", "basis": "guess"}
            elif "LEARNED" in text:
                d = {"action": "do", "say": "As usual.", "instruction": "Reply yes", "basis": "learned",
                     "learn": "answer yes to Ana"}
            else:
                d = {"action": "ask", "say": "Shall I?", "basis": "guess"}
            content = json.dumps(d)
            if self.path.startswith("/v1/chat/completions"):
                return self.send(200, {"choices": [{"message": {"role": "assistant", "content": content}}]})
            return self.send(200, {"content": [{"type": "text", "text": content}]})
        m = re.search(r"RETRY429:(\d+)", text)
        if m:
            busy[m.group(0)] = busy.get(m.group(0), 0) + 1
            if busy[m.group(0)] <= int(m.group(1)):
                data = json.dumps({"error": {"message": "slow down"}}).encode()
                self.send_response(429)
                self.send_header("retry-after", "0")
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
        if "FAIL500" in text:
            return self.send(500, {"error": {"message": "boom"}})
        if "NOEFFORT" in text and "output_config" in body:
            return self.send(400, {"error": {"message": "unknown parameter `output_config`"}})
        if "BIGTOKENS" in text and body.get("max_tokens", 0) > 8192:
            return self.send(400, {"error": {"message": "max_tokens: 16000 > 8192, the maximum for this model"}})
        if self.path.startswith("/v1/messages") and self.scripted(body, text):
            return
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
                # Failed, then done another way.
                if "RETRY" in text and denied and json.dumps(body["messages"]).count("tool_result") == 1:
                    return self.send(200, {"content": [{"type": "tool_use", "id": "call_2", "name": "launch_app",
                                                        "input": {"app": "firefox"}}], "stop_reason": "tool_use"})
                answer = "Not done." if denied else ("Closed." if "CLOSE" in text else "Firefox is open.")
                if "REPORTME" in text:
                    answer = ('Opened it.<report>{"summary": "Firefox is ready", "done": ["Opened Firefox"], '
                              '"failed": [], "needs_you": ["Sign in to your account"]}</report>')
                return self.send(200, {"content": [{"type": "text", "text": answer}], "stop_reason": "end_turn"})
            call = ({"name": "close_window", "input": {"id": 7}} if "CLOSE" in text
                    else {"name": "tasks", "input": {"action": "delete", "id": "t1"}} if "DELETE" in text
                    else {"name": "launch_app", "input": {"app": "BROKEN"}} if "FAILSTEP" in text
                    else {"name": "launch_app", "input": {"app": "OTHERFIRST"}} if "RETRY" in text and "tool_result" not in json.dumps(body["messages"])
                    else {"name": "tasks", "input": {"action": "list"}} if "TASKS" in text
                    else {"name": "screenshot", "input": {}} if "LOOKSCREEN" in text
                    else {"name": "ask_agent", "input": {"task": "search the web for the news"}} if "DELEGATE" in text
                    else {"name": "youtube-music__play", "input": {"query": "FIRESTARTER"}} if "MUSIC" in text
                    else {"name": "open_app_tools", "input": {"server": "immich"}} if "PHOTOS" in text
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
