.pragma library

// The phone handoff (ai.handoff; services/PhoneHandoff.qml): when the user
// leaves (the screen locked, or no input) for ai.handoff.afterMinutes while
// something waits for them, one message to the paired phone through KDE
// Connect. Plain code, well under a millisecond. decide(state) gives
// {send, why, text, keys, lines}:
//   send: whether to send now; why: why not (or "ok");
//   text: the message (a header line, then one line per kind of thing);
//   keys: what it says, one key a line: sent again only when one is new
//   (state.sent: the keys already sent while away).
// Lock-screen level: the KIND of what waits, how many, and a time — never
// a question's words, an approval's step, a reminder's or a task's text,
// so nothing private (and never a secret) leaves for the phone.
// state: {enabled, policy (policies.ai), paused (desktop control), dnd,
// presenting (a fullscreen window while not locked), away (bool),
// awayMinutes, afterMinutes, phone (a reachable paired device), sent,
// question (Muse asked something and waits), approvals (steps waiting for
// an OK), tasks (background tasks waiting for the user), reminders
// [{id, at: ms}], events [{id, at: ms}], now (ms), horizonMinutes (60),
// lang (en, fr, de, vi)}.
// QML's JS engine: ES5-style, no ES2019+.

var WORDS = {
    en: {
        header: "Muse, from your computer:",
        question: "I asked you something and I'm waiting for your answer.",
        approval: ["A step waits for your OK.", "%n steps wait for your OK."],
        tasks: ["A background task needs you.", "%n background tasks need you."],
        reminder: "Reminder at %t.",
        event: "Event at %t.",
    },
    fr: {
        header: "Muse, depuis votre ordinateur :",
        question: "Je vous ai posé une question et j'attends votre réponse.",
        approval: ["Une étape attend votre accord.", "%n étapes attendent votre accord."],
        tasks: ["Une tâche de fond a besoin de vous.", "%n tâches de fond ont besoin de vous."],
        reminder: "Rappel à %t.",
        event: "Événement à %t.",
    },
    de: {
        header: "Muse, von deinem Computer:",
        question: "Ich habe dich etwas gefragt und warte auf deine Antwort.",
        approval: ["Ein Schritt wartet auf dein OK.", "%n Schritte warten auf dein OK."],
        tasks: ["Eine Hintergrundaufgabe braucht dich.", "%n Hintergrundaufgaben brauchen dich."],
        reminder: "Erinnerung um %t.",
        event: "Termin um %t.",
    },
    vi: {
        header: "Muse, từ máy tính của bạn:",
        question: "Tôi đã hỏi bạn một điều và đang chờ câu trả lời.",
        approval: ["Một bước đang chờ bạn đồng ý.", "%n bước đang chờ bạn đồng ý."],
        tasks: ["Một tác vụ nền cần bạn.", "%n tác vụ nền cần bạn."],
        reminder: "Lời nhắc lúc %t.",
        event: "Sự kiện lúc %t.",
    },
}

function pad(n) {
    return (n < 10 ? "0" : "") + n
}

function clock(ms) {
    var d = new Date(ms)
    return pad(d.getHours()) + ":" + pad(d.getMinutes())
}

function count(forms, n) {
    return (n === 1 ? forms[0] : forms[1]).replace("%n", String(n))
}

function num(v) {
    return typeof v === "number" && isFinite(v) && v > 0 ? Math.floor(v) : 0
}

// The times coming within the horizon, the soonest first: [{id, at}].
function soon(list, now, horizon) {
    var out = []
    var items = list || []
    for (var i = 0; i < items.length; i++) {
        var it = items[i]
        if (!it || typeof it.at !== "number") continue
        if (it.at < now || it.at > now + horizon) continue
        out.push({ id: String(it.id || ""), at: it.at })
    }
    out.sort(function (a, b) { return a.at - b.at })
    return out.slice(0, 3)
}

// What waits, as lines (and the key of what they say).
function lines(s) {
    var lang = WORDS[s.lang] ? s.lang : "en"
    var w = WORDS[lang]
    var now = typeof s.now === "number" ? s.now : Date.now()
    var horizon = (num(s.horizonMinutes) || 60) * 60000
    var out = [], key = []
    if (s.question) {
        out.push(w.question)
        key.push("q")
    }
    var approvals = num(s.approvals)
    if (approvals > 0) {
        out.push(count(w.approval, approvals))
        key.push("a" + approvals)
    }
    var tasks = num(s.tasks)
    if (tasks > 0) {
        out.push(count(w.tasks, tasks))
        key.push("t" + tasks)
    }
    var reminders = soon(s.reminders, now, horizon)
    for (var i = 0; i < reminders.length; i++) {
        out.push(w.reminder.replace("%t", clock(reminders[i].at)))
        key.push("r:" + reminders[i].id + "@" + reminders[i].at)
    }
    var events = soon(s.events, now, horizon)
    for (var j = 0; j < events.length; j++) {
        out.push(w.event.replace("%t", clock(events[j].at)))
        key.push("e:" + events[j].id + "@" + events[j].at)
    }
    return { lines: out, keys: key, header: w.header }
}

function decide(state) {
    var s = state || {}
    function no(why) {
        return { send: false, why: why, text: "", keys: [], lines: [] }
    }
    if (!s.enabled) return no("off")
    if (s.policy === 0) return no("AI is off")
    if (s.paused) return no("desktop control is paused")
    if (s.dnd) return no("Do Not Disturb")
    if (s.presenting) return no("presenting")
    if (!s.away) return no("at the computer")
    if (num(s.awayMinutes) < num(s.afterMinutes)) return no("not away long enough")
    if (!s.phone) return no("no phone")
    var l = lines(s)
    if (l.lines.length === 0) return no("nothing waits")
    var sent = s.sent || []
    var fresh = l.keys.filter(function (k) { return sent.indexOf(k) < 0 })
    if (fresh.length === 0) return no("already sent")
    return { send: true, why: "ok", text: l.header + "\n" + l.lines.join("\n"), keys: l.keys, lines: l.lines }
}
