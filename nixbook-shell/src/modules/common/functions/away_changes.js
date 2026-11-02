.pragma library

// "While you were away" (services/AwaySummary.qml): the calendar's changes
// while the user was away, plain code. A snapshot is {until (the end of the
// window it covers, ms), events: {key: {id, title, start, end}}} (timed
// events of the next three days, a recurring one's occurrence apart).
// changes(before, current, now) gives [{key, id, title, change, start}],
// change "new" | "moved" | "cancelled", soonest first, within the window
// both cover and not over yet. Nothing when either snapshot is empty: a
// calendar not loaded yet (at the lock, or back) is neither all new nor all
// cancelled.
// QML's JS engine: no ES2019+.

function count(obj) {
    var n = 0;
    for (var k in obj)
        if (Object.prototype.hasOwnProperty.call(obj, k)) n++;
    return n;
}

function changes(before, current, now) {
    var was = (before && before.events) || {};
    var is = (current && current.events) || {};
    var out = [];
    if (count(was) === 0 || count(is) === 0) return out;
    var end = Math.min(Number(before.until) || 0, Number(current.until) || 0);
    var key, e, b;
    for (key in is) {
        if (!Object.prototype.hasOwnProperty.call(is, key)) continue;
        e = is[key];
        if (e.end <= now || e.start >= end) continue;
        b = was[key];
        if (!b) out.push({ key: key, id: e.id, title: e.title, change: "new", start: e.start });
        else if (b.start !== e.start) out.push({ key: key, id: e.id, title: e.title, change: "moved", start: e.start });
    }
    for (key in was) {
        if (!Object.prototype.hasOwnProperty.call(was, key)) continue;
        b = was[key];
        if (is[key] || b.start <= now || b.start >= end) continue;
        out.push({ key: key, id: b.id, title: b.title, change: "cancelled", start: b.start });
    }
    out.sort(function (x, y) { return x.start - y.start; });
    return out;
}
