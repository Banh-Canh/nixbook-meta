"""The daily brief and the reply batch (scripts/desktop-mcp.py: brief_collect,
brief_plain, brief_compose, reply_candidates, replies_draft, daily_brief),
with the shell and the model faked: run by brief.sh (python3 -I, in a
scratch XDG tree it sets up)."""

import importlib.util
import json
import os
import sys
import time

ROOT = sys.argv[1]
spec = importlib.util.spec_from_file_location("dm", os.path.join(ROOT, "scripts", "desktop-mcp.py"))
dm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dm)

failed = 0
passed = 0


def check(name, got, want):
    global failed, passed
    if got == want:
        passed += 1
        print(f"ok   - {name}")
    else:
        failed += 1
        print(f"FAIL - {name}\n       expected: {want!r}\n       actual:   {got!r}", file=sys.stderr)


def truthy(name, value):
    check(name, bool(value), True)


def policy(n, extra=None):
    path = os.path.join(os.environ["XDG_CONFIG_HOME"], "nixbook-shell", "config.json")
    with open(path, "w") as f:
        json.dump({"policies": {"ai": n}, "ai": extra or {}}, f)


policy(1)
cfg = dm.load_config()
NOW = time.mktime(time.strptime("2026-11-02 08:30", "%Y-%m-%d %H:%M"))
TODAY, TOMORROW = "2026-11-02", "2026-11-03"

# -- the shell, faked ----------------------------------------------------------
CALENDAR = {
    TODAY: [{"summary": "Dentist", "start": f"{TODAY}T14:00", "end": f"{TODAY}T15:00", "allDay": False,
             "location": "12 rue Victor Hugo"},
            {"summary": "Standup", "start": f"{TODAY}T09:30", "end": f"{TODAY}T09:45", "allDay": False},
            {"summary": "Mum's birthday", "start": TODAY, "end": TODAY, "allDay": True}],
    TOMORROW: [{"summary": "Flight to Hanoi", "start": f"{TOMORROW}T07:10", "end": f"{TOMORROW}T19:00", "allDay": False}],
}
TASKS = {"today": TODAY, "lists": [], "tasks": [
    {"id": "1", "title": "Pay rent", "done": False, "deadline": "today"},
    {"id": "2", "title": "Call the bank", "done": False, "deadline": "overdue"},
    {"id": "3", "title": "Buy milk", "done": True, "completed": TODAY},
    {"id": "4", "title": "Old thing", "done": True, "completed": "2026-10-30"},
    {"id": "5", "title": "Sub-step", "done": False, "deadline": "today", "parent": "1"},
    {"id": "6", "title": "Someday", "done": False, "deadline": "none"},
]}
NOTIFS = [
    # oldest first, as the shell lists them
    {"id": 1, "app": "Signal", "summary": "Lan", "body": "old message", "time": 1000, "actions": ["Reply"], "canReply": False},
    {"id": 2, "app": "Muse", "summary": "Muse", "body": "a word of mine", "time": 2000, "actions": [], "canReply": True},
    {"id": 3, "app": "Messages", "summary": "Bank", "body": "Your verification code is 482913", "time": 3000,
     "actions": ["Reply"], "canReply": True},
    {"id": 4, "app": "KDE Connect", "summary": "Mum", "body": "You: ok see you", "time": 4000, "actions": [], "canReply": True},
    {"id": 5, "app": "Vesktop", "summary": "Alan Smith", "body": "are we still on for tonight?", "time": 5000,
     "actions": [], "canReply": False},
    {"id": 6, "app": "Vesktop", "summary": "Bob (#general, Nix)", "body": "hello all", "time": 6000, "actions": [],
     "canReply": False},
    {"id": 7, "app": "Signal", "summary": "Lan", "body": "can you call me back? urgent", "time": 7000,
     "actions": ["Reply", "Mark as read"], "canReply": False},
    {"id": 8, "app": "KDE Connect", "summary": "Paul", "body": "<b>Lunch</b> tomorrow?", "time": 8000, "actions": [],
     "canReply": True},
    {"id": 9, "app": "Firefox", "summary": "Download finished", "body": "report.pdf", "time": 9000,
     "actions": ["Open"], "canReply": False},
    {"id": 10, "app": "KeePassXC", "summary": "Database", "body": "locked", "time": 10000, "actions": ["Reply"],
     "canReply": True},
]
calls = []


def widget_call(target, fn, *args):
    calls.append((target, fn) + args)
    if target == "calendar" and fn == "day":
        return json.dumps({"date": args[0], "events": CALENDAR.get(args[0], [])})
    raise dm.ToolError("not faked")


dm.widget_call = widget_call
dm.tasks_call = lambda fn, request=None: json.loads(json.dumps(TASKS))
dm.shell_notifications = lambda fn, *a: json.loads(json.dumps(NOTIFS))
dm.quip_facts = lambda: {"weather": "12°C, light rain"}
dm.read_personal = lambda: [{"kind": "person", "topic": "Alan Smith", "importance": 4}]
# Vesktop with nixbook's bridge.
os.makedirs(dm.electron_dir(), exist_ok=True)
open(os.path.join(dm.electron_dir(), "discord.sock"), "w").close()

# -- which messages wait for a reply -------------------------------------------
cands = dm.reply_candidates(cfg, NOTIFS, NOW)
check("replies: the people who matter, urgent ones, then the newest", [c["id"] for c in cands], [5, 7, 8])
by_id = {c["id"]: c for c in cands}
check("replies: a Discord DM goes through the bridge", (by_id[5]["via"], by_id[5]["channel"]), ("discord", "Alan Smith"))
check("replies: someone who matters", by_id[5].get("important"), True)
check("replies: a chat app's Reply button: copy & open", by_id[7]["via"], "open")
check("replies: one per conversation, its newest", by_id[7]["text"], "can you call me back? urgent")
check("replies: urgent words", by_id[7].get("urgent"), True)
check("replies: a typed reply the app takes", by_id[8]["via"], "inline")
check("replies: markup left out", by_id[8]["text"], "Lunch tomorrow?")
ids = {c["id"] for c in cands}
check("replies: never the shell's own, codes, echoes, channels, downloads, password managers",
      ids & {2, 3, 4, 6, 9, 10}, set())
os.unlink(os.path.join(dm.electron_dir(), "discord.sock"))
check("replies: no bridge, no Discord DM", [c["id"] for c in dm.reply_candidates(cfg, NOTIFS, NOW)], [7, 8])
open(os.path.join(dm.electron_dir(), "discord.sock"), "w").close()
blocked = dict(cfg, pages={"blockedApps": ["discord"]})
check("replies: Discord blocked to agents (pages.blockedApps)", 5 in {c["id"] for c in dm.reply_candidates(blocked, NOTIFS, NOW)}, False)

# -- the brief's facts ---------------------------------------------------------
data = dm.brief_collect(cfg, "morning", NOW)
check("brief: the day's events, all-day first, then by time",
      [(e["title"], e["start"]) for e in data["events"]], [("Mum's birthday", ""), ("Standup", "09:30"), ("Dentist", "14:00")])
check("brief: an event's place", data["events"][2].get("location"), "12 rue Victor Hugo")
t = data["tasks"]
check("brief: tasks due today (top-level ones)", (t["dueToday"], t["dueTodayCount"]), (["Pay rent"], 1))
check("brief: overdue", (t["overdue"], t["overdueCount"]), (["Call the bank"], 1))
check("brief: done today", (t["doneToday"], t["open"]), (["Buy milk"], 3))
check("brief: who waits for a reply, never what they wrote", data["replies"],
      [{"app": "Vesktop", "who": "Alan Smith"}, {"app": "Signal", "who": "Lan"}, {"app": "KDE Connect", "who": "Paul"}])
check("brief: the weather in the morning", data.get("weather"), "12°C, light rain")
check("brief: no recap fields in the morning", ("journal" in data, "tomorrow" in data), (False, False))
try:
    dm.brief_collect(cfg, "noon", NOW)
    check("brief: only morning or evening", "accepted", "refused")
except dm.ToolError:
    check("brief: only morning or evening", "refused", "refused")

# The journal: what Muse did today.
policy(1, {"autonomy": {"journal": True}})
dm.journal_add(cfg, {"source": "routine", "summary": "Paused the music when the call started", "tool": "media_control"},
               now=NOW - 600)
dm.journal_add(cfg, {"source": "agent", "summary": "Added Pay rent to the tasks", "tool": "tasks"}, now=NOW - 300)
dm.journal_add(cfg, {"source": "agent", "summary": "Yesterday's thing", "tool": "tasks"}, now=NOW - 86400)
evening = dm.brief_collect(cfg, "evening", NOW)
check("recap: what Muse did today, newest first", evening["journal"],
      {"count": 2, "items": ["Added Pay rent to the tasks", "Paused the music when the call started"]})
check("recap: tomorrow's first events", evening["tomorrow"], [{"title": "Flight to Hanoi", "start": "07:10", "allDay": False}])
check("recap: no weather in the evening", "weather" in evening, False)

# -- in plain words (no model), the four languages ------------------------------
en = dm.brief_plain(data, "en")
for part in ("Good morning!", "Today: Mum's birthday, Standup at 09:30, Dentist at 14:00.", "One task due today: Pay rent.",
             "One overdue.", "3 messages wait for a reply (Alan Smith, Lan, Paul).", "Weather: 12°C, light rain."):
    check(f"plain (en): {part}", part in en, True)
fr = dm.brief_plain(data, "fr")
check("plain (fr)", ("Bonjour !" in fr, "Standup à 09:30" in fr, "3 messages attendent une réponse" in fr), (True, True, True))
de = dm.brief_plain(evening, "de")
check("plain (de, recap)", ("Heute habe ich 2 Dinge" in de, "Morgen beginnt mit Flight to Hanoi um 07:10." in de),
      (True, True))
vi = dm.brief_plain(evening, "vi")
check("plain (vi, recap)", ("Ngày mai bắt đầu với Flight to Hanoi lúc 07:10." in vi, "Bạn đã xong một việc." in vi), (True, True))
check("plain: an unknown language is English", dm.brief_plain(data, "xx").startswith("Good morning!"), True)
empty = dict(data, events=[], tasks={}, replies=[], repliesCount=0, personal=[], weather="")
check("plain: an empty day", dm.brief_plain(empty, "en"), "Good morning! Nothing on your calendar today.")
check("plain: a day starting after noon: a hello", (dm.brief_plain(dict(empty, now="14:24"), "en").split(" ")[0],
                                                     dm.brief_plain(dict(empty, now="14:24"), "de").split(" ")[0]),
      ("Hello!", "Hallo!"))
check("plain: an empty tomorrow", dm.brief_plain(dict(evening, journal={}, tasks={}, tomorrow=[], replies=[], repliesCount=0), "en"),
      "Here's your day. Nothing on your calendar tomorrow.")

# -- phrased by the model (one call, masked by ask_model) ----------------------
prompts = []


def fake_model(cfg_, system, prompt, schema=None, web=False, model=None, effort=None):
    prompts.append({"system": system, "prompt": prompt, "schema": schema, "model": model, "effort": effort})
    if system == dm.REPLIES_SYSTEM:
        return {"drafts": [{"id": 5, "text": "Yes, still on! See you at 8."}, {"id": "8", "text": "Sure, lunch works."}]}
    return {"text": "Morning! Standup at 09:30, the dentist at 14:00, and Alan is waiting for you."}


dm.ask_model = fake_model
dm.model_ready = lambda cfg_, web=False: True
os.makedirs(os.path.dirname(dm.allowed_flag()), exist_ok=True)
open(dm.allowed_flag(), "w").close()  # desktop control allowed
out = dm.brief_compose(cfg, "morning", "en", now=NOW)
check("compose: phrased by the model", (out["phrased"], out["text"]),
      (True, "Morning! Standup at 09:30, the dentist at 14:00, and Alan is waiting for you."))
check("compose: one call, the small model, its own prompt", (len(prompts), prompts[0]["model"], prompts[0]["system"]),
      (1, "small", dm.BRIEF_SYSTEM))
check("compose: no thinking to speak of", prompts[0]["effort"], "minimal")
p = prompts[0]["prompt"]
check("compose: the facts in the prompt", ("Today's events: all day: Mum's birthday; 09:30 Standup; 14:00 Dentist" in p,
                                           "Tasks due today (1): Pay rent" in p, "Language: en" in p), (True, True, True))
check("compose: no message's words go to the model", any(w in p for w in ("still on for tonight", "call me back", "Lunch")), False)
check("compose: the card's counts", (out["repliesCount"], out["events"], out["dueToday"]), (3, 3, 1))
prompts.clear()
out = dm.brief_compose(cfg, "evening", "fr", plain=True, now=NOW)
check("compose --plain: no model", (len(prompts), out["phrased"], out["text"].startswith("Votre journée.")), (0, False, True))
os.unlink(dm.allowed_flag())
out = dm.brief_compose(cfg, "morning", "en", now=NOW)
check("compose: desktop control paused: plain words, no call", (len(prompts), out["phrased"]), (0, False))
open(dm.allowed_flag(), "w").close()


def broken(*a, **k):
    raise dm.ToolError("the provider said no")


dm.ask_model = broken
out = dm.brief_compose(cfg, "morning", "en", now=NOW)
check("compose: the model failing: plain words", (out["phrased"], out["text"].startswith("Good morning!")), (False, True))
dm.ask_model = fake_model

# -- the drafts ----------------------------------------------------------------
prompts.clear()
r = dm.replies_draft(cfg, cands, "en")
check("drafts: one call for all", len(prompts), 1)
check("drafts: each message gets its draft by id", [(i["id"], i["draft"]) for i in r["items"]],
      [(5, "Yes, still on! See you at 8."), (7, ""), (8, "Sure, lunch works.")])
check("drafts: drafted", r["drafted"], True)
check("drafts: the main model by default, its schema", (prompts[0]["model"], prompts[0]["schema"]), ("main", dm.REPLIES_SCHEMA))
truthy("drafts: the messages' words are what it drafts from", "are we still on for tonight?" in prompts[0]["prompt"])
policy(1, {"replies": {"model": "small"}})
prompts.clear()
dm.replies_draft(cfg, cands, "en")
check("drafts: ai.replies.model", prompts[0]["model"], "small")
policy(0)
check("drafts: AI off: none, no call", (dm.replies_draft(cfg, cands, "en")["why"], len(prompts)), ("AI is off", 1))
policy(1)
check("drafts: nothing waits", dm.replies_draft(cfg, [], "en"), {"items": [], "drafted": False})
dm.ask_model = broken
r = dm.replies_draft(cfg, cands, "en")
check("drafts: the model failing: empty drafts, why", (r["drafted"], r["why"], [i["draft"] for i in r["items"]]),
      (False, "the provider said no", ["", "", ""]))
dm.ask_model = fake_model

# -- the agents' tool ----------------------------------------------------------
t = dm.TOOLS["daily_brief"]
check("daily_brief: read-only, the shell's group, the pim bundle",
      (t["read_only"], t["group"], t["spec"]["_meta"]["nixbook/bundle"]), (True, "shell", "pim"))


class Ctx:
    cfg = cfg


got = json.loads(t["fn"](Ctx(), {})[0]["text"])
check("daily_brief: the brief's and the recap's facts in one call",
      (got["kind"], "journal" in got, "tomorrow" in got, got.get("weather"), "personal" in got),
      ("day", True, True, "12°C, light rain", True))
check("daily_brief: no arguments (a short description: the tools' budget)",
      (t["spec"]["inputSchema"].get("properties"), len(t["spec"]["description"]) <= 120), ({}, True))

# -- guards --------------------------------------------------------------------
deny = dm.DEFAULT_CONFIG["shellIpcDenyTargets"]
check("agents can't trigger the brief, open the card or write to the phone",
      ("brief" in deny, "replies" in deny, "handoff" in deny), (True, True, True))
check("not on the helper (a model call)", (dm.helper_allowed(["brief", "compose"]), dm.helper_allowed(["replies", "draft"])),
      (False, False))
item, _ = dm.brief_item(cfg, {"events": [{"title": "Standup", "start": "09:30"}], "tasksDue": 2, "ownBrief": True}, NOW)
check("the initiative's welcome back leaves the day to the daily brief", item, None)
item, _ = dm.brief_item(cfg, {"events": [{"title": "Standup", "start": "09:30"}], "tasksDue": 2}, NOW)
truthy("…and says it when the daily brief is off", item and "Today: Standup at 09:30." in item["text"])

print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
