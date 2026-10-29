"""nixbook-muse-task: Muse's background tasks.

A task is a long job of several steps (finding, comparing, preparing…) that
the user hands to Muse to do while they do something else: it runs the
shell's agent (nixbook-meta-agent, as the side panel does) in a process of
its own, out of the way, records what it does in a state file the shell
reads, and stops to ask the user over a socket and a notification when it
needs them (a risky step's OK, a question). Nobody watches it work, so every
step it takes without asking goes to the journal (source `task`) through the
trust ladder (--trust), and the user's --confirm floor stays.

    nixbook-muse-task start TEXT [--from-session ID]   → {id} or {error}
    nixbook-muse-task run ID          the runner (started by `start` with
                                      systemd-run --user, a plain background
                                      process without it)
    nixbook-muse-task list            [{id, text, status, updated, alive}]
    nixbook-muse-task show ID         the task's state
    nixbook-muse-task approve ID APPROVALID yes|no
    nixbook-muse-task answer ID TEXT  a new message to Muse (resumes it when
                                      its runner is gone)
    nixbook-muse-task stop ID
    nixbook-muse-task resume ID       after a crash or a reboot: its session
                                      goes on
    nixbook-muse-task clear           finished tasks older than 7 days removed
    nixbook-muse-task fanout TEXT     plan and fan out → {id} (the plan's): an
                                      order of several parts split by the big
                                      model into at most 4 sub-tasks, each run
                                      as a task of its own at the same time,
                                      their results merged into one answer

State: $XDG_STATE_HOME/nixbook-shell/tasks/<id>.json (0600, replaced
atomically): {id, text, status: running|waiting|done|failed|stopped,
started, updated, steps: [{id, tool, summary, status}], approval?: {id,
tool, summary, class}, question?, report?, answer?, sessionId, error?,
told: […], trustSuggest: […], activity: thinking|typing|searching|tool,
doing?}; a fan-out's worker also {parent, title, part, model: small|main,
modelId}. Control: $XDG_RUNTIME_DIR/nixbook-shell/
tasks/<id>.sock (0600, only this user's processes: SO_PEERCRED), one JSON
line each way: {"type": "approval", "id", "allow"} | {"type": "answer",
"text"} | {"type": "stop"} | {"type": "status"}.

A plan (kind "plan", `fanout`) is a task of its own with no agent: {id,
kind, text, status: running|done|failed|stopped, phase: planning|working|
merging, parts: [{title, instruction, model, modelId, needs, worker?,
status: queued|running|waiting|done|failed|stopped|skipped}], plannerModel,
mergerModel, answer?, report?, error?}. Its runner asks the big model
(ai.routing.decisions) for the parts, starts every part whose `needs` are
done while there is room, gives a part the results of those it needs, and
once all are over asks the main model to merge them. Stopping it stops its
workers; a task can't fan out again. Plans don't count in maxTasks.

At most ai.autonomy.maxTasks (4) at once, an hour each run; nothing while
policies.ai isn't 1 (Muse is an online model) or ai.autonomy.tasks is off.
NIXBOOK_MUSE_TASK_SPAWN=plain: never systemd-run (tests). The runner's and
its agent's output (stderr: what went wrong) in $XDG_RUNTIME_DIR/
nixbook-shell/tasks/<id>.log; a failed agent's last line there is in the
task's error too. The agent gets the provider's settings when the runner has
them (it keeps them from its own tools), else asks the provider itself.
Stdlib only.
"""

import fcntl
import json
import os
import queue
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import nixbook_ai  # noqa: E402

RUN_LIMIT = float(os.environ.get("NIXBOOK_MUSE_TASK_LIMIT") or 3600)
KEEP_DAYS = 7
DEFAULT_MAX = 4
# A task just started whose runner hasn't taken its lock yet still counts.
SPAWN_GRACE = 30
LIVE = ("running", "waiting")
FINISHED = ("done", "failed", "stopped")
ID_RE = re.compile(r"[a-z0-9]{6,32}")
TASK_SYSTEM = (
    "You are Muse, working on a task the user handed you to do in the background while they do something else: "
    "nobody watches you work, and they read what you did later (a notification, the Tasks list). Do the whole task "
    "with your tools, step by step, without asking for what you can find out yourself. When you can't go on "
    "without the user (a choice only they can make, a detail you can't find), end your answer with one short "
    "question, nothing after it. When it is done, answer briefly with what you did or found: the outcome first.")


class TaskError(Exception):
    pass


# ── Paths and files ────────────────────────────────────────────────────────

def xdg(var, default):
    return os.environ.get(var) or os.path.expanduser(default)


def state_dir():
    d = os.path.join(xdg("XDG_STATE_HOME", "~/.local/state"), "nixbook-shell", "tasks")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def run_dir():
    rt = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    d = os.path.join(rt, "nixbook-shell", "tasks")
    os.makedirs(d, mode=0o700, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def check_id(tid):
    if not ID_RE.fullmatch(str(tid or "")):
        raise TaskError(f"not a task id: {tid}")
    return tid


def task_path(tid):
    return os.path.join(state_dir(), check_id(tid) + ".json")


def sock_path(tid):
    return os.path.join(run_dir(), check_id(tid) + ".sock")


def lock_path(tid):
    return os.path.join(run_dir(), check_id(tid) + ".lock")


def log_path(tid):
    """The task's log: its runner's and its agent's output."""
    return os.path.join(run_dir(), check_id(tid) + ".log")


def last_log_line(tid, start=0):
    """The last line the agent wrote to the task's log since START (its
    error, mostly), "" when none."""
    try:
        with open(log_path(tid), "rb") as f:
            f.seek(start)
            lines = [line.strip() for line in f.read().decode("utf-8", "replace").splitlines()]
    except OSError:
        return ""
    lines = [line for line in lines if line and not line.startswith("[")]
    return lines[-1][:300] if lines else ""


def load(tid):
    try:
        with open(task_path(tid), encoding="utf-8") as f:
            d = json.load(f)
    except FileNotFoundError:
        raise TaskError(f"no such task: {tid}")
    except (OSError, ValueError) as e:
        raise TaskError(f"task {tid} can't be read: {e}")
    if not isinstance(d, dict):
        raise TaskError(f"task {tid} can't be read")
    return d


def save(task):
    """The task's state, replaced at once (the shell watches the file)."""
    task["updated"] = int(time.time())
    path = task_path(task["id"])
    tmp = f"{path}.{os.getpid()}.{threading.get_ident()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(task, f, ensure_ascii=False)
    os.replace(tmp, path)


def all_tasks():
    out = []
    try:
        names = os.listdir(state_dir())
    except OSError:
        return out
    for n in names:
        if not n.endswith(".json") or not ID_RE.fullmatch(n[:-5]):
            continue
        try:
            out.append(load(n[:-5]))
        except TaskError:
            pass
    return out


def alive(tid):
    """Whether a runner holds the task's lock (released when it dies, the
    runtime dir emptied at a reboot)."""
    try:
        fd = os.open(lock_path(tid), os.O_RDWR | os.O_CREAT, 0o600)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return True
    finally:
        os.close(fd)
    return False


def active(task):
    if task.get("status") not in LIVE:
        return False
    return alive(task["id"]) or time.time() - float(task.get("spawned") or 0) < SPAWN_GRACE


# ── Settings ───────────────────────────────────────────────────────────────

def settings():
    cfg = nixbook_ai.config()
    ai = cfg.get("ai") if isinstance(cfg.get("ai"), dict) else {}
    auto = ai.get("autonomy") if isinstance(ai.get("autonomy"), dict) else {}
    policies = cfg.get("policies") if isinstance(cfg.get("policies"), dict) else {}
    try:
        most = max(1, int(auto.get("maxTasks", DEFAULT_MAX)))
    except (TypeError, ValueError):
        most = DEFAULT_MAX
    return {"cfg": cfg, "ai": ai, "policy": policies.get("ai", 1), "tasks": auto.get("tasks", True) is not False,
            "fanOut": auto.get("fanOut", True) is not False, "max": most}


def may_run(conf):
    """Why no task may run now, or None."""
    if conf["policy"] != 1:
        return "AI is off or local only (policies.ai): Muse's tasks need its online model"
    if not conf["tasks"]:
        return "background tasks are turned off (Settings > Desktop agents > Autonomy)"
    return None


def room(conf, but=None):
    # A plan runs no agent (its workers do): not counted.
    running = [t for t in all_tasks() if t["id"] != but and t.get("kind") != "plan" and active(t)]
    if len(running) >= conf["max"]:
        return f"{len(running)} tasks are already running (at most {conf['max']}): wait for one, or stop one"
    return None


# ── Telling the user ───────────────────────────────────────────────────────

def notify(task, title, body):
    exe = shutil.which("notify-send")
    if not exe:
        return
    # Its default action, Open: the shell opens the Tasks list on a click
    # (Notifications.attemptInvokeAction, by the x-nixbook-task hint).
    # notify-send waits while a notification has actions: not waited for.
    try:
        subprocess.Popen([exe, "-a", "Muse", "-h", f"string:x-nixbook-task:{task['id']}", "-A", "default=Open",
                          "--", title[:200], body[:600]], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, env=nixbook_ai.child_env(), start_new_session=True)
    except OSError:
        pass


def label(task):
    """What a task is called where the user sees it: a worker's title (its
    text is its whole instruction), else its text."""
    return task.get("title") or task.get("text") or ""


def short(text, n=80):
    t = " ".join(str(text or "").split())
    return t if len(t) <= n else t[:n - 1] + "…"


# ── Starting a runner ──────────────────────────────────────────────────────

# What a runner started by systemd (the user manager's own environment)
# needs from the caller's.
PASS_ENV = ("PATH", "HOME", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
            "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "NIRI_SOCKET", "DISPLAY", "LANG",
            "NIXBOOK_SHELL_CONFIG", "NIXBOOK_META_AGENT", "NIXBOOK_MUSE_TASK_LIMIT", "NIXBOOK_AI_RETRY_DELAY")


def spawn(task):
    """`run ID` out of the way: a transient systemd user unit, else (no
    systemd-run, it failed, or NIXBOOK_MUSE_TASK_SPAWN=plain) a process of
    its own session."""
    task["spawned"] = int(time.time())
    task["runs"] = int(task.get("runs") or 0) + 1
    save(task)
    cmd = [sys.executable, "-I", os.path.realpath(__file__), "run", task["id"]]
    sd = shutil.which("systemd-run")
    if sd and os.environ.get("NIXBOOK_MUSE_TASK_SPAWN") != "plain":
        unit = f"nixbook-muse-task-{task['id']}-{task['runs']}"
        env = [f"--setenv={k}" for k in PASS_ENV if os.environ.get(k)]
        try:
            p = subprocess.run([sd, "--user", "--quiet", "--collect", "--unit", unit,
                                f"--description=Muse's background task {task['id']}", *env, *cmd],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               text=True, timeout=20)
            if p.returncode == 0:
                task["unit"] = unit
                save(task)
                return
        except (OSError, subprocess.SubprocessError):
            pass
    log = open(log_path(task["id"]), "ab")
    subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
                     close_fds=True)
    log.close()


# ── The control socket (client side) ───────────────────────────────────────

def send(tid, msg, timeout=10):
    """MSG to the task's runner: its reply, or None when no runner listens."""
    path = sock_path(tid)
    if not os.path.exists(path):
        return None
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(timeout)
        s.connect(path)
        s.sendall((json.dumps(msg, ensure_ascii=False) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except OSError:
        return None
    finally:
        s.close()
    try:
        reply = json.loads(buf.split(b"\n", 1)[0].decode("utf-8", "replace"))
    except ValueError:
        return None
    return reply if isinstance(reply, dict) else None


# ── The runner ─────────────────────────────────────────────────────────────

def meta_agent():
    for c in (os.environ.get("NIXBOOK_META_AGENT"), shutil.which("nixbook-meta-agent")):
        if c and os.access(c, os.X_OK):
            return [c]
    here = os.path.join(os.path.dirname(os.path.realpath(__file__)), "meta-agent.py")
    if os.path.exists(here):
        return [sys.executable, "-I", here]
    raise TaskError("nixbook-meta-agent isn't installed")


def session_file(sid):
    return os.path.join(xdg("XDG_STATE_HOME", "~/.local/state"), "nixbook-shell", "agent-sessions", f"{sid}.json")


def folders(conf):
    """ai.allowedFolders, as the side panel takes them (never /, /home, the
    home or a parent of it, nor a hidden folder of the home): readable."""
    home = os.path.realpath(os.path.expanduser("~"))
    out = []
    for f in conf["ai"].get("allowedFolders") or []:
        f = str(f).strip()
        if f == "~" or f.startswith("~/"):
            f = home + f[1:]
        if not f.startswith("/") or "\0" in f:
            continue
        f = os.path.normpath(f)
        if f == "/" or (home + "/").startswith(f + "/") or f.startswith(home + "/."):
            continue
        if f not in out:
            out.append(f)
    return out


def mcp_servers(conf, query_file):
    """The servers the side panel's Muse gets: the desktop's, and the
    user's apps' (assistant-mcp.json) not turned off in Settings."""
    ai = conf["ai"]
    agent = ai.get("agent") if isinstance(ai.get("agent"), dict) else {}
    off = agent.get("mcpServersOff") or []
    servers = {}
    path = os.path.join(xdg("XDG_CONFIG_HOME", "~/.config"), "nixbook-shell", "assistant-mcp.json")
    try:
        with open(path, encoding="utf-8") as f:
            servers = (json.load(f) or {}).get("mcpServers") or {}
    except (OSError, ValueError, AttributeError):
        servers = {}
    servers = {k: v for k, v in servers.items() if k != "desktop" and k not in off and isinstance(v, dict)}
    immich = ai.get("immich") if isinstance(ai.get("immich"), dict) else {}
    if "immich" in servers:
        env = dict(servers["immich"].get("env") or {})
        if immich.get("url"):
            env["IMMICH_BASE_URL"] = str(immich["url"])
        if immich.get("apiKeyFile"):
            env["IMMICH_API_KEY_FILE"] = str(immich["apiKeyFile"])
        servers["immich"] = {**servers["immich"], "env": env}
    jellyfin = ai.get("jellyfin") if isinstance(ai.get("jellyfin"), dict) else {}
    if "jellyfin" in servers:
        env = dict(servers["jellyfin"].get("env") or {})
        for key, var in (("url", "JELLYFIN_URL"), ("user", "JELLYFIN_USER"), ("apiKeyFile", "JELLYFIN_API_KEY_FILE")):
            if jellyfin.get(key):
                env[var] = str(jellyfin[key])
        servers["jellyfin"] = {**servers["jellyfin"], "env": env}
    if "phone" in servers:
        phone = ai.get("phone") if isinstance(ai.get("phone"), dict) else {}
        servers["phone"] = {**servers["phone"], "env": {**(servers["phone"].get("env") or {}),
                                                        "KDECONNECT_MCP_READ": "1" if phone.get("readMessages") else "0"}}
    dm = shutil.which("nixbook-desktop-mcp")
    if dm:
        servers["desktop"] = {"command": dm, "env": {"NIXBOOK_DESKTOP_MCP_QUERY_FILE": query_file,
                                                     "NIXBOOK_DESKTOP_MCP_PERSONAL": "shell"}}
    return servers


def agent_argv(task, conf, query_file):
    ai = conf["ai"]
    agent = ai.get("agent") if isinstance(ai.get("agent"), dict) else {}
    system = TASK_SYSTEM
    if ai.get("includeSystemContext", True) is not False:
        try:
            with open(os.path.join(xdg("XDG_CONFIG_HOME", "~/.config"), "nixbook-shell", "system-context.md"),
                      encoding="utf-8") as f:
                system += "\n\nThe machine you run on:\n" + f.read()[:14000]
        except OSError:
            pass
    # The deltas too (--include-partial-messages): which kind of block
    # starts (text, a tool) is the worker's activity on the bar.
    argv = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--strict-mcp-config", "--append-system-prompt", system,
            "--context-for", "chat", "--trust", "--confirm", "destructive", "--report", "--verify", "--learn",
            "--lazy-mcp", "12", "--max-turns", "80", "--journal-source", "task", "--task", task["id"]]
    # The web, and the allowed folders to read: what research needs. No
    # writing, no commands: nobody is there to see them.
    web = [t for t in agent.get("allowedTools") or [] if t in ("WebFetch", "WebSearch")]
    dirs = folders(conf)
    tools = web + (["Read", "Glob", "Grep"] if dirs else [])
    argv += ["--tools", ",".join(tools), "--disallowedTools", "Bash,Edit,Write,NotebookEdit"]
    for d in dirs:
        argv += ["--add-dir", d]
    servers = mcp_servers(conf, query_file)
    if servers:
        argv += ["--mcp-config", json.dumps({"mcpServers": servers}, ensure_ascii=False),
                 "--allowedTools", ",".join(f"mcp__{n}" for n in servers)]
    privacy = ai.get("privacy") if isinstance(ai.get("privacy"), dict) else {}
    if privacy.get("mask"):
        argv.append("--privacy")
    # A fan-out's worker runs the model its plan gave it.
    model = str(task.get("model") or agent.get("model") or "")
    if model:
        argv += ["--model", model]
    effort = str(agent.get("effort") or "")
    if re.fullmatch(r"[a-z]+", effort):
        argv += ["--effort", effort]
    sid = task["sessionId"]
    if os.path.exists(session_file(sid)):
        argv += ["--resume", sid]
    elif task.get("fromSession") and os.path.exists(session_file(task["fromSession"])):
        argv += ["--resume", task["fromSession"], "--fork-session", "--session-id", sid]
    else:
        argv += ["--session-id", sid]
    return argv


def peer_uid(conn):
    try:
        raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        return struct.unpack("3i", raw)[1]
    except OSError:
        return -1


def die_with_parent():
    """The agent stopped (SIGTERM: it saves its session) when its runner
    dies, killed or not."""
    try:
        import ctypes
        ctypes.CDLL(None, use_errno=True).prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
    except (OSError, AttributeError):
        pass


class Runner:
    def __init__(self, tid):
        self.task = load(tid)
        self.tid = tid
        self.events = queue.Queue()
        self.proc = None
        self.pending = 0
        self.stopping = ""
        self.over = False
        self.srv = None
        self.lock = threading.Lock()

    # ── State ──

    def update(self, **changes):
        with self.lock:
            for k, v in changes.items():
                if v is None:
                    self.task.pop(k, None)
                else:
                    self.task[k] = v
            save(self.task)

    def act(self, activity, doing=""):
        """What the agent is doing now (the bar's worker figure: thinking,
        typing, searching, tool), written only when it changes: the shell
        reads the file as it changes, never polls it."""
        if self.task.get("activity") == activity and self.task.get("doing", "") == doing:
            return
        self.update(activity=activity, doing=doing)

    def step(self, tool_id, **fields):
        for s in self.task.get("steps") or []:
            if s.get("id") == tool_id:
                s.update(fields)
                return

    # ── The control socket ──

    def listen(self):
        path = sock_path(self.tid)
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old = os.umask(0o177)
        try:
            srv.bind(path)
        finally:
            os.umask(old)
        os.chmod(path, 0o600)
        srv.listen(8)
        self.srv = srv
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        with conn:
            if peer_uid(conn) != os.getuid():
                return
            conn.settimeout(30)
            buf = b""
            try:
                while True:
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        try:
                            msg = json.loads(line.decode("utf-8", "replace"))
                        except ValueError:
                            msg = None
                        reply = queue.Queue()
                        if isinstance(msg, dict):
                            self.events.put(("ctl", msg, reply))
                            try:
                                answer = reply.get(timeout=20)
                            except queue.Empty:
                                answer = {"error": "the task didn't answer"}
                        else:
                            answer = {"error": "not a JSON object"}
                        conn.sendall((json.dumps(answer, ensure_ascii=False) + "\n").encode())
                    chunk = conn.recv(65536)
                    if not chunk:
                        return
                    buf += chunk
            except OSError:
                return

    # ── The agent ──

    def write(self, obj):
        try:
            self.proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
            self.proc.stdin.flush()
            return True
        except (OSError, ValueError, AttributeError):
            return False

    def say(self, text):
        if self.write({"type": "user", "message": {"role": "user", "content": text}}):
            self.pending += 1
            return True
        return False

    def read(self):
        for line in self.proc.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if isinstance(ev, dict):
                self.events.put(("ev", ev, None))
        self.events.put(("eof", None, None))

    def start_agent(self, conf, deadline):
        query = os.path.join(run_dir(), self.tid + ".query")
        with open(query, "w", encoding="utf-8") as f:
            f.write(self.task.get("text") or "")
        argv = meta_agent() + agent_argv(self.task, conf, query)
        workdir = os.path.join(xdg("XDG_DATA_HOME", "~/.local/share"), "nixbook-shell", "assistant")
        os.makedirs(workdir, exist_ok=True)
        # An approval waits as long as the task may (the agent's own 120 s
        # is for a user sitting in front of the chat).
        # NIXBOOK_MUSE_TASK_ID: everything the task starts is the task's
        # (desktop-mcp starts no task from a task, and refuses the user's
        # own answers from it).
        # The provider's settings (NIXBOOK_AI_*) go to the agent when the
        # runner has them: it needs them, and keeps them from its tools (its
        # own child_env); without them it asks nixbook-model-provider.
        env = {**os.environ, "NIXBOOK_AGENT_APPROVAL_TIMEOUT": str(max(60, int(deadline - time.time()))),
               "NIXBOOK_MUSE_TASK_ID": self.tid}
        path = log_path(self.tid)
        log = open(path, "ab")
        self.log_start = log.tell()
        log.write(f"[{time.strftime('%H:%M:%S')}] agent: {' '.join(argv[:3])} …\n".encode())
        log.flush()
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True,
                                     cwd=workdir, env=env, preexec_fn=die_with_parent)
        log.close()
        threading.Thread(target=self.read, daemon=True).start()

    def stop_agent(self):
        if self.proc is None or self.proc.poll() is not None:
            return
        try:
            self.proc.terminate()
            self.proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        except OSError:
            pass

    # ── Events ──

    def on_event(self, ev):
        t = ev.get("type")
        if t == "stream_event":
            # Only a block starting says something (a delta, nothing new).
            inner = ev.get("event") if isinstance(ev.get("event"), dict) else {}
            block = inner.get("content_block") if isinstance(inner.get("content_block"), dict) else {}
            if inner.get("type") == "content_block_start":
                if block.get("type") == "text":
                    self.act("typing")
                elif block.get("type") == "thinking":
                    self.act("thinking")
                elif block.get("type") == "tool_use":
                    self.act(*tool_activity(block.get("name")))
        elif t == "tool_started":
            self.act(*tool_activity(ev.get("name")))
        elif t == "system" and ev.get("session_id"):
            self.update(sessionId=ev["session_id"])
        elif t == "assistant":
            calls = [b for b in ((ev.get("message") or {}).get("content") or []) if b.get("type") == "tool_use"]
            if calls:
                with self.lock:
                    steps = self.task.setdefault("steps", [])
                    for c in calls:
                        name = str(c.get("name") or "")
                        tool = re.sub(r"^mcp__desktop__", "", name)
                        tool = re.sub(r"^mcp__([^_].*?)__", r"\1: ", tool)
                        if c.get("name") in (nixbook_ai.STRUCTURED, "verification"):
                            continue
                        steps.append({"id": c.get("id"), "tool": tool, "summary": nixbook_ai.step_summary(
                            c.get("input") if isinstance(c.get("input"), dict) else {}), "status": "running"})
                    del steps[:-200]
                    save(self.task)
        elif t == "user":
            results = (ev.get("message") or {}).get("content") or []
            # Its results back: thinking about them (saved below).
            self.task["activity"], self.task["doing"] = "thinking", ""
            with self.lock:
                for r in results if isinstance(results, list) else []:
                    if isinstance(r, dict) and r.get("type") == "tool_result":
                        self.step(r.get("tool_use_id"), status="error" if r.get("is_error") else "ok")
                save(self.task)
        elif t == "approval_request":
            approval = {"id": ev.get("id"), "tool": ev.get("tool"), "summary": ev.get("summary") or "",
                        "class": ev.get("class") or ""}
            self.update(status="waiting", approval=approval)
            what = f"{str(ev.get('tool') or '').replace('_', ' ')}" + (f" ({approval['summary']})"
                                                                      if approval["summary"] else "")
            notify(self.task, f"Muse needs you: {short(what, 90)}",
                   f"Allow this step of “{short(label(self.task), 120)}”?")
        elif t in ("told", "trust_suggest"):
            key = "told" if t == "told" else "trustSuggest"
            with self.lock:
                items = self.task.setdefault(key, [])
                items.append({k: v for k, v in ev.items() if k not in ("type", "session_id")})
                del items[:-50]
                save(self.task)
        elif t == "verify":
            self.update(verify={"met": ev.get("met") is True, "note": str(ev.get("note") or "")})
        elif t == "result":
            self.pending = max(0, self.pending - 1)
            self.on_result(ev)

    def on_result(self, ev):
        text = str(ev.get("result") or "").strip()
        report = ev.get("report") if isinstance(ev.get("report"), dict) else None
        changes = {"report": report, "approval": None}
        if ev.get("session_id"):
            changes["sessionId"] = ev["session_id"]
        if self.stopping:
            return
        if ev.get("is_error"):
            if self.pending:
                return
            self.update(status="failed", error=text or "the agent failed", **changes)
            # A fan-out's worker: its plan says so once, with the others.
            if not self.task.get("parent"):
                notify(self.task, "Muse couldn't finish a task", f"{short(label(self.task), 120)}: {short(text, 300)}")
            self.finish()
            return
        if ev.get("clarify") or text.endswith("?"):
            # Its own question: the task waits for the user's answer.
            self.update(status="waiting", question=text, answer=text, **changes)
            if not self.pending:
                notify(self.task, f"Muse needs you: {short(text, 120)}", short(label(self.task), 200))
                # Nothing to hold meanwhile (the agent, its MCP servers, a
                # slot of maxTasks, for up to an hour, then "failed"): the
                # answer resumes the session (cmd_answer, pendingAnswer).
                self.finish()
            return
        if self.pending:
            self.update(answer=text, **changes)
            return
        self.update(status="done", answer=text, question=None, error=None, **changes)
        summary = (report or {}).get("summary") or (text.splitlines()[0] if text else "Done.")
        if not self.task.get("parent"):
            notify(self.task, f"Muse is done: {short(self.task.get('text'), 90)}", short(summary, 400))
        self.finish()

    def finish(self):
        """The task over: the agent's input closed, so it ends."""
        self.over = True
        try:
            self.proc.stdin.close()
        except (OSError, AttributeError):
            pass

    def on_control(self, msg):
        kind = msg.get("type")
        if kind == "status":
            return {"ok": True, "task": self.task}
        if kind == "approval":
            pending = self.task.get("approval") or {}
            if not pending or str(msg.get("id")) != str(pending.get("id")):
                return {"error": "no such step waits for an answer"}
            if not self.write({"type": "approval", "id": pending["id"], "allow": msg.get("allow") is True}):
                return {"error": "the agent is gone"}
            self.update(approval=None, status="waiting" if self.task.get("question") else "running")
            return {"ok": True}
        if kind == "answer":
            text = str(msg.get("text") or "").strip()
            if not text:
                return {"error": "an empty answer"}
            if self.over or not self.say(text[:8000]):
                return {"error": "the task is over"}
            self.update(status="running" if not self.task.get("approval") else "waiting", question=None)
            return {"ok": True}
        if kind == "stop":
            self.stopping = "stopped"
            self.update(status="stopped", approval=None)
            threading.Thread(target=self.stop_agent, daemon=True).start()
            return {"ok": True}
        return {"error": f"unknown message: {kind}"}

    # ── The run ──

    def run(self):
        lock = os.open(lock_path(self.tid), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            out({"error": "this task already runs"})
            return 1
        self.task = load(self.tid)
        conf = settings()
        why = may_run(conf)
        if why:
            self.update(status="failed", error=why, spawned=None)
            return 1
        deadline = time.time() + RUN_LIMIT
        first = None
        fresh = not os.path.exists(session_file(self.task["sessionId"]))
        if self.task.get("pendingAnswer"):
            first = self.task["pendingAnswer"]
        elif fresh:
            first = self.task.get("text") or ""
        elif not (self.task.get("status") == "waiting" and self.task.get("question")):
            first = ("(Your work on this task was interrupted. Go on with it from where you were, and finish it: "
                     f"{self.task.get('text') or ''})")
        status = "waiting" if first is None else "running"
        self.listen()
        self.update(status=status, pid=os.getpid(), approval=None, error=None, pendingAnswer=None, spawned=None,
                    runStarted=int(time.time()))
        allowed_at_start = os.path.exists(control_marker())
        try:
            self.start_agent(conf, deadline)
            if first is not None:
                self.say(first)
                self.act("thinking")
            while True:
                try:
                    kind, obj, reply = self.events.get(timeout=2)
                except queue.Empty:
                    kind = None
                if kind == "ev":
                    self.on_event(obj)
                elif kind == "ctl":
                    reply.put(self.on_control(obj))
                elif kind == "eof":
                    break
                if self.stopping:
                    continue
                if time.time() > deadline:
                    self.stopping = "limit"
                    self.update(status="failed", error="it took more than an hour: stopped", approval=None)
                    notify(self.task, "Muse stopped a task", f"{short(label(self.task), 120)}: it took more "
                           "than an hour.")
                    threading.Thread(target=self.stop_agent, daemon=True).start()
                elif allowed_at_start and not os.path.exists(control_marker()):
                    # The user paused the desktop agents (the panic key): the
                    # task stops with them.
                    self.stopping = "paused"
                    self.update(status="stopped", error="desktop control was paused", approval=None)
                    threading.Thread(target=self.stop_agent, daemon=True).start()
            self.stop_agent()
            code = self.proc.wait() if self.proc else 0
            asking = self.task.get("status") == "waiting" and self.task.get("question")
            if self.task.get("status") in LIVE and not self.stopping and not asking:
                why = last_log_line(self.tid, getattr(self, "log_start", 0))
                self.update(status="failed", error=f"the agent stopped (exit {code})" + (f": {why}" if why else ""),
                            approval=None)
        finally:
            try:
                if self.srv is not None:
                    self.srv.close()
                os.unlink(sock_path(self.tid))
            except OSError:
                pass
            self.update(pid=None)
        return 0


def tool_activity(name):
    """(activity, doing) for a tool call: the web searched or read, or a
    tool used (its name as the steps show it)."""
    name = str(name or "")
    if name in ("WebSearch", "WebFetch"):
        return "searching", name
    tool = re.sub(r"^mcp__desktop__", "", name)
    tool = re.sub(r"^mcp__([^_].*?)__", r"\1: ", tool)
    return "tool", tool


# ── Plan and fan out ───────────────────────────────────────────────────────
# One order of several parts ("research three restaurants, draft an
# invitation and block my Friday evening"): the big model writes the parts,
# each runs as a task of its own (its own agent, at the same time, each
# asking the user as any task does), and the main model merges what they
# found into one answer. The plan's runner only waits and starts: it runs no
# agent, so it isn't counted in maxTasks.

MAX_PARTS = 4
PART_STATUSES_OVER = ("done", "failed", "stopped", "skipped")
# Parts waiting for room or for the user (a question) may make a plan last
# longer than one task.
PLAN_LIMIT = float(os.environ.get("NIXBOOK_MUSE_PLAN_LIMIT") or RUN_LIMIT * 2)
PLAN_POLL = float(os.environ.get("NIXBOOK_MUSE_PLAN_POLL") or 1.0)
PLAN_SYSTEM = (
    "You split an order the user gave Muse, their desktop assistant, into sub-tasks that separate agents work on "
    "at the same time, each with the same tools as Muse (the web, the user's apps, calendar, tasks, notes…). "
    f"At most {MAX_PARTS} parts, as few as the order needs; an order that is really one job is one part. Each "
    "part: a title of a few words (shown on the user's screen: what it does, e.g. \"Find 3 restaurants\"), the "
    "instruction the agent gets (complete by itself: that agent sees nothing else, so say everything it needs "
    "from the order), and its model: \"small\" for a look-up or a single action, \"main\" for research, comparing "
    "or writing. A part that needs another's result (an invitation naming the restaurant found) lists that "
    "part's index (0-based, an earlier part) in `needs`: it runs after it, with its result. Steps that can't be "
    "separated stay in one part. Never add parts the user didn't ask for.")
PLAN_SCHEMA = {
    "type": "object",
    "properties": {
        "parts": {"type": "array", "maxItems": MAX_PARTS, "items": {
            "type": "object",
            "properties": {"title": {"type": "string"}, "instruction": {"type": "string"},
                           "model": {"type": "string", "enum": ["small", "main"]},
                           "needs": {"type": "array", "items": {"type": "integer"}}},
            "required": ["title", "instruction", "model"]}},
    },
    "required": ["parts"],
}
MERGE_SYSTEM = (
    "You merge what several agents did for the parts of one order the user gave Muse, their desktop assistant, "
    "into Muse's one short answer to the user: the outcome first, then what matters from each part (a few "
    "sentences or a short list, names, times and links kept), and plainly what failed or still needs the user. "
    "Speak as Muse (\"I found…\"), never of agents or parts. `summary`: one line. `done`, `failed`, `needsYou`: "
    "short items (empty lists when none).")
MERGE_SCHEMA = {
    "type": "object",
    "properties": {"answer": {"type": "string"}, "summary": {"type": "string"},
                   "done": {"type": "array", "items": {"type": "string"}},
                   "failed": {"type": "array", "items": {"type": "string"}},
                   "needsYou": {"type": "array", "items": {"type": "string"}}},
    "required": ["answer", "summary"],
}


def fan_out_refused(conf):
    """Why no order may be fanned out now, or None."""
    if os.environ.get("NIXBOOK_MUSE_TASK_ID") or os.environ.get("NIXBOOK_DESKTOP_MCP_NO_TASKS"):
        return "a background task or a routine's run can't fan out"
    why = may_run(conf)
    if why:
        return why
    if not conf["fanOut"]:
        return "splitting orders up is turned off (Settings > Desktop agents > Autonomy)"
    return None


def privacy_on(conf):
    privacy = conf["ai"].get("privacy") if isinstance(conf["ai"].get("privacy"), dict) else {}
    return bool(privacy.get("mask"))


def clean_parts(raw, order):
    """The model's parts, checked: at most MAX_PARTS, a title and an
    instruction each, small or main, `needs` only earlier parts (so they run
    one after the other, never in a loop)."""
    parts = []
    for p in raw if isinstance(raw, list) else []:
        if not isinstance(p, dict):
            continue
        title = short(p.get("title"), 60)
        instruction = str(p.get("instruction") or "").strip()[:4000]
        if not title or not instruction:
            continue
        model = p.get("model") if p.get("model") in ("small", "main") else "main"
        i = len(parts)
        needs = sorted({n for n in p.get("needs") or [] if isinstance(n, int) and 0 <= n < i})
        parts.append({"title": title, "instruction": instruction, "model": model, "needs": needs, "status": "queued"})
        if len(parts) == MAX_PARTS:
            break
    return parts or [{"title": short(order, 60), "instruction": order, "model": "main", "needs": [],
                      "status": "queued"}]


def part_result(task):
    """What a finished worker found, for the merge and the parts after it."""
    return str((task.get("answer") if task.get("status") == "done" else task.get("error")) or "").strip()


class PlanRunner:
    """A plan's runner: plans, starts the parts as room allows, merges."""

    def __init__(self, tid):
        self.tid = tid
        self.task = load(tid)

    def update(self, **changes):
        for k, v in changes.items():
            if v is None:
                self.task.pop(k, None)
            else:
                self.task[k] = v
        save(self.task)

    def provider(self):
        try:
            return nixbook_ai.Provider.from_env()
        except nixbook_ai.AIError:
            return None

    def model_id(self, p, alias):
        return p.model(alias) if p else alias

    def plan(self, conf, p):
        """The parts, from the big model (ai.routing.decisions): the text
        masked on the way when the user asks for it, the names back after."""
        route = nixbook_ai.routing(conf["cfg"])
        model = route["decisions"]
        order = self.task.get("text") or ""
        self.update(plannerModel=self.model_id(p, model))
        sent = nixbook_ai.mask(order) if privacy_on(conf) else order
        nixbook_ai.sent_note("fan-out plan", self.task["plannerModel"], sent)
        try:
            got = nixbook_ai.answer(PLAN_SYSTEM, f"The order: {sent}", model=model, schema=PLAN_SCHEMA,
                                    effort=route["decisionsEffort"], max_tokens=4000, provider=p)
        except nixbook_ai.AIError as e:
            # No plan: the whole order as one part, still done.
            self.update(planError=str(e)[:300])
            got = {}
        if privacy_on(conf):
            got = nixbook_ai.unmask_json(got)
        parts = clean_parts((got or {}).get("parts"), order)
        # The provider's model names, shown beside each part (Spark, Wonder).
        for part in parts:
            part["modelId"] = self.model_id(p, part["model"])
        return parts

    def worker_text(self, part, parts):
        """The part's instruction, the results of those it needs, and the
        whole order it is one part of."""
        text = part["instruction"]
        before = []
        for n in part.get("needs") or []:
            w = parts[n].get("worker")
            try:
                found = part_result(load(w)) if w else ""
            except TaskError:
                found = ""
            if found:
                before.append(f"- {parts[n]['title']}: {short(found, 1500)}")
        if before:
            text += "\n\nWhat was found before you, to use:\n" + "\n".join(before)
        text += ("\n\n(This is one part of a bigger order the user gave: “" + short(self.task.get("text"), 600)
                 + "”. Other parts are done at the same time by others: do only yours, and answer with what you "
                 "found or did.)")
        return text

    def start_part(self, i, parts, conf, p):
        part = parts[i]
        worker = new_task(self.worker_text(part, parts), parent=self.tid, title=part["title"], part=i,
                          model=part["model"], modelId=self.model_id(p, part["model"]))
        part.update(worker=worker["id"], status="running", modelId=worker["modelId"])

    def refresh(self, parts):
        """Each started part's status from its worker's file; True when one
        changed."""
        changed = False
        for part in parts:
            if not part.get("worker") or part["status"] in PART_STATUSES_OVER:
                continue
            try:
                w = load(part["worker"])
            except TaskError:
                status = "failed"
            else:
                status = w.get("status") or "running"
                # Its runner gone while running (killed): failed, unless it
                # waits for the user's answer (resumed by it).
                if status == "running" and not active(w):
                    status = "failed"
            if status != part["status"]:
                part["status"] = status
                changed = True
        return changed

    def stop_workers(self, parts):
        for part in parts:
            if part.get("worker") and part["status"] not in PART_STATUSES_OVER:
                stop_task(part["worker"])
                part["status"] = "stopped"

    def merge(self, conf, p, parts):
        """One answer from the parts' results (the main model); a part alone
        is its own answer."""
        done = [pt for pt in parts if pt["status"] == "done"]
        if len(parts) == 1 and done:
            w = load(done[0]["worker"])
            return part_result(w), w.get("report")
        lines = []
        for pt in parts:
            try:
                found = part_result(load(pt["worker"])) if pt.get("worker") else ""
            except TaskError:
                found = ""
            state = {"done": "done", "skipped": "not done (a part it needed failed)"}.get(pt["status"], pt["status"])
            lines.append(f"## {pt['title']} ({state})\n{short(found, 3000) or '(nothing said)'}")
        prompt = f"The user's order: {self.task.get('text') or ''}\n\nWhat each part did:\n\n" + "\n\n".join(lines)
        sent = nixbook_ai.mask(prompt) if privacy_on(conf) else prompt
        self.update(phase="merging", mergerModel=self.model_id(p, "main"))
        nixbook_ai.sent_note("fan-out merge", self.task["mergerModel"], sent)
        try:
            got = nixbook_ai.answer(MERGE_SYSTEM, sent, model="main", schema=MERGE_SCHEMA, max_tokens=4000,
                                    provider=p)
        except nixbook_ai.AIError as e:
            # No merge: each part's result as it is.
            self.update(mergeError=str(e)[:300])
            return "\n\n".join(lines), None
        if privacy_on(conf):
            got = nixbook_ai.unmask_json(got)
        report = {k: got.get(k) for k in ("summary", "done", "failed", "needsYou") if got.get(k)}
        return str(got.get("answer") or "").strip(), report or None

    def run(self):
        lock = os.open(lock_path(self.tid), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            out({"error": "this plan already runs"})
            return 1
        self.task = load(self.tid)
        conf = settings()
        why = may_run(conf)
        if why:
            self.update(status="failed", error=why, spawned=None)
            return 1
        try:
            os.unlink(stop_flag(self.tid))
        except OSError:
            pass
        allowed_at_start = os.path.exists(control_marker())
        self.update(status="running", pid=os.getpid(), error=None, spawned=None, runStarted=int(time.time()))
        p = self.provider()
        deadline = time.time() + PLAN_LIMIT
        try:
            parts = self.task.get("parts") or []
            if not parts:
                self.update(phase="planning")
                parts = self.plan(conf, p)
                self.update(parts=parts, phase="working")
            while True:
                if os.path.exists(stop_flag(self.tid)):
                    self.stop_workers(parts)
                    self.update(status="stopped", parts=parts)
                    return 0
                if allowed_at_start and not os.path.exists(control_marker()):
                    # The panic key: its workers stop by themselves, the plan too.
                    self.stop_workers(parts)
                    self.update(status="stopped", error="desktop control was paused", parts=parts)
                    return 0
                changed = self.refresh(parts)
                for i, part in enumerate(parts):
                    if part["status"] != "queued":
                        continue
                    needs = [parts[n]["status"] for n in part.get("needs") or []]
                    if any(s in ("failed", "stopped", "skipped") for s in needs):
                        part["status"] = "skipped"
                        changed = True
                    elif all(s == "done" for s in needs) and not room(conf):
                        self.start_part(i, parts, conf, p)
                        changed = True
                if changed:
                    self.update(parts=parts)
                if all(pt["status"] in PART_STATUSES_OVER for pt in parts):
                    break
                if time.time() > deadline:
                    self.stop_workers(parts)
                    self.update(parts=parts, timedOut=True)
                    break
                time.sleep(PLAN_POLL)
            if not any(pt["status"] == "done" for pt in parts):
                self.update(status="failed", phase=None, error="none of its parts got done")
                notify(self.task, "Muse couldn't finish a task", short(self.task.get("text"), 200))
                return 0
            answer, report = self.merge(conf, p, parts)
            self.update(status="done", phase=None, answer=answer, report=report)
            summary = (report or {}).get("summary") or (answer.splitlines()[0] if answer else "Done.")
            notify(self.task, f"Muse is done: {short(self.task.get('text'), 90)}", short(summary, 400))
            return 0
        except Exception as e:  # noqa: BLE001 — the plan said failed, whatever broke
            self.update(status="failed", phase=None, error=f"the plan broke: {e}"[:300])
            raise
        finally:
            self.update(pid=None)


def stop_flag(tid):
    """A plan asked to stop (its runner has no socket: it looks for this)."""
    return os.path.join(run_dir(), check_id(tid) + ".stop")


def new_task(text, **extra):
    """A task made and its runner started."""
    now = int(time.time())
    task = {"id": uuid.uuid4().hex[:12], "text": text[:8000], "status": "running", "started": now, "updated": now,
            "steps": [], "sessionId": str(uuid.uuid4()), "runs": 0, **extra}
    save(task)
    spawn(task)
    return task


def stop_task(tid):
    """A task stopped: its runner told, else its state marked."""
    task = load(tid)
    if task.get("kind") == "plan":
        with open(stop_flag(tid), "w"):
            pass
        for part in task.get("parts") or []:
            if part.get("worker"):
                try:
                    stop_task(part["worker"])
                except TaskError:
                    pass
        if alive(tid):
            return {"ok": True}
        task = load(tid)
    else:
        reply = send(tid, {"type": "stop"})
        if reply is not None:
            return reply
    if task.get("status") in LIVE:
        task.update(status="stopped")
        task.pop("approval", None)
        save(task)
    return {"ok": True}


def control_marker():
    """The desktop-control kill switch: agents act only while it exists."""
    return os.path.join(xdg("XDG_STATE_HOME", "~/.local/state"), "nixbook-shell", "desktop-control-allowed")


# ── The commands ───────────────────────────────────────────────────────────

def out(obj):
    print(json.dumps(obj, ensure_ascii=False, separators=(",", ":")))


def cmd_start(args):
    text, from_session = [], ""
    i = 0
    while i < len(args):
        if args[i] == "--from-session" and i + 1 < len(args):
            from_session = args[i + 1]
            i += 2
            continue
        text.append(args[i])
        i += 1
    text = " ".join(text).strip()
    if text == "-":
        text = sys.stdin.read().strip()
    if not text:
        raise TaskError("what should Muse do? (start TEXT)")
    if from_session and not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", from_session):
        raise TaskError(f"not a session id: {from_session}")
    conf = settings()
    why = may_run(conf) or room(conf)
    if why:
        raise TaskError(why)
    task = new_task(text, **({"fromSession": from_session} if from_session else {}))
    out({"id": task["id"]})
    return 0


def cmd_fanout(args):
    text = " ".join(args).strip()
    if text == "-":
        text = sys.stdin.read().strip()
    if not text:
        raise TaskError("what should Muse do? (fanout TEXT)")
    conf = settings()
    why = fan_out_refused(conf) or room(conf)
    if why:
        raise TaskError(why)
    now = int(time.time())
    plan = {"id": uuid.uuid4().hex[:12], "kind": "plan", "text": text[:4000], "status": "running",
            "phase": "planning", "started": now, "updated": now, "parts": [], "runs": 0}
    save(plan)
    spawn(plan)
    out({"id": plan["id"]})
    return 0


def summary_of(t):
    return {"id": t["id"], "text": t.get("text") or "", "status": t.get("status"), "updated": t.get("updated"),
            "started": t.get("started"), "alive": alive(t["id"]),
            **{k: t[k] for k in ("kind", "phase", "parent", "title", "activity") if t.get(k)},
            **({"approval": t["approval"]} if t.get("approval") else {}),
            **({"question": t["question"]} if t.get("question") and t.get("status") == "waiting" else {})}


def cmd_list(_args):
    out(sorted((summary_of(t) for t in all_tasks()), key=lambda t: -(t.get("updated") or 0)))
    return 0


def cmd_show(args):
    task = load(check_id(args[0] if args else ""))
    task["alive"] = alive(task["id"])
    out(task)
    return 0


def cmd_approve(args):
    if len(args) < 3 or args[2] not in ("yes", "no"):
        raise TaskError("approve ID APPROVALID yes|no")
    reply = send(check_id(args[0]), {"type": "approval", "id": args[1], "allow": args[2] == "yes"})
    if reply is None:
        raise TaskError("the task isn't running (resume it first)")
    out(reply)
    return 0 if reply.get("ok") else 1


def cmd_answer(args):
    if len(args) < 2:
        raise TaskError("answer ID TEXT")
    tid, text = check_id(args[0]), " ".join(args[1:]).strip()
    if load(tid).get("kind") == "plan":
        raise TaskError("a plan has no conversation: answer the part that asks")
    if text == "-":
        text = sys.stdin.read().strip()
    if not text:
        raise TaskError("an empty answer")
    reply = send(tid, {"type": "answer", "text": text})
    if reply is not None and reply.get("error") == "the task is over":
        # Its runner was just ending: once it is gone, the answer resumes it.
        for _ in range(50):
            if not alive(tid):
                break
            time.sleep(0.1)
        reply = None if not alive(tid) else reply
    if reply is not None:
        out(reply)
        return 0 if reply.get("ok") else 1
    # No runner (a crash, a reboot, or a task that is done): the answer
    # goes on in its session.
    task = load(tid)
    conf = settings()
    why = may_run(conf) or room(conf, but=tid)
    if why:
        raise TaskError(why)
    task.update(pendingAnswer=text[:8000], status="running", question=None, error=None)
    spawn(task)
    out({"ok": True, "resumed": True})
    return 0


def cmd_stop(args):
    reply = stop_task(check_id(args[0] if args else ""))
    out(reply)
    return 0 if reply.get("ok") else 1


def cmd_resume(args):
    tid = check_id(args[0] if args else "")
    task = load(tid)
    if alive(tid):
        raise TaskError("the task is running")
    conf = settings()
    why = may_run(conf) or room(conf, but=tid)
    if why:
        raise TaskError(why)
    task.update(status="running", error=None)
    task.pop("approval", None)
    if task.get("kind") == "plan":
        # Its parts that didn't get done go again (new workers).
        for part in task.get("parts") or []:
            if part.get("status") in ("stopped", "failed", "skipped"):
                part.update(status="queued", worker=None)
        task.update(phase="working" if task.get("parts") else "planning")
    spawn(task)
    out({"ok": True, "id": tid})
    return 0


def cmd_clear(_args):
    old = time.time() - KEEP_DAYS * 86400
    removed = 0
    for t in all_tasks():
        if t.get("status") in FINISHED and float(t.get("updated") or 0) < old and not alive(t["id"]):
            try:
                os.unlink(task_path(t["id"]))
                removed += 1
            except OSError:
                pass
    out({"removed": removed})
    return 0


COMMANDS = {"start": cmd_start, "list": cmd_list, "show": cmd_show, "approve": cmd_approve, "answer": cmd_answer,
            "stop": cmd_stop, "resume": cmd_resume, "clear": cmd_clear, "fanout": cmd_fanout}


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "run":
            tid = check_id(args[0] if args else "")
            if load(tid).get("kind") == "plan":
                # The plan calls the model itself: the provider's settings
                # first (this run again through nixbook-model-provider when
                # `env` gave none), before its lock is taken.
                try:
                    nixbook_ai.Provider.from_env()
                except nixbook_ai.AIError as e:
                    nixbook_ai.ensure_provider(["run", tid], script=os.path.realpath(__file__), why=str(e))
                return PlanRunner(tid).run()
            return Runner(tid).run()
        if cmd not in COMMANDS:
            raise TaskError(f"unknown command: {cmd}")
        return COMMANDS[cmd](args)
    except TaskError as e:
        out({"error": str(e)})
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(1)
