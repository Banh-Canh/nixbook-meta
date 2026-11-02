// "While you were away"'s calendar changes (src/modules/common/functions/
// away_changes.js): new, moved and cancelled events against the calendar as
// it was when the user left, within the window both snapshots cover; nothing
// from a calendar not loaded. Run by away.sh (node).
"use strict";
const fs = require("fs");
const path = require("path");

const src = fs
  .readFileSync(
    path.join(__dirname, "../src/modules/common/functions/away_changes.js"),
    "utf8",
  )
  .replace(/^\.pragma library/m, "");
const lib = new Function(src + "\nreturn { changes: changes }")();

let failed = 0,
  passed = 0;
function eq(name, want, got) {
  const a = JSON.stringify(want),
    b = JSON.stringify(got);
  if (a === b) {
    passed++;
    console.log(`ok   - ${name}`);
  } else {
    failed++;
    console.log(`FAIL - ${name}\n       expected: ${a}\n       actual:   ${b}`);
  }
}

const H = 3600000;
const now = 100 * H;
const ev = (id, start, title) => ({
  id: id,
  title: title || id,
  start: start,
  end: start + H,
});
const snap = (until, list) => ({
  until: until,
  events: Object.fromEntries(list.map((e) => [e.id, e])),
});
const kinds = (out) => out.map((c) => `${c.change}:${c.key}`);

const before = snap(now + 60 * H, [
  ev("standup", now + 2 * H),
  ev("lunch", now + 5 * H),
  ev("review", now + 8 * H),
  ev("past", now - 3 * H),
  ev("late", now + 59 * H),
]);
const current = snap(now + 70 * H, [
  ev("standup", now + 3 * H),
  ev("review", now + 8 * H),
  ev("dentist", now + 1 * H),
  ev("late", now + 59 * H),
  ev("beyond", now + 65 * H),
]);
const out = lib.changes(before, current, now);
eq(
  "new, moved and cancelled, soonest first",
  ["new:dentist", "moved:standup", "cancelled:lunch"],
  kinds(out),
);
eq(
  "each with its id, title and start",
  {
    key: "standup",
    id: "standup",
    title: "standup",
    change: "moved",
    start: now + 3 * H,
  },
  out[1],
);
eq(
  "nothing past the window the lock-time snapshot covered",
  false,
  kinds(out).includes("new:beyond"),
);
eq(
  "an event over is no change",
  [],
  kinds(
    lib.changes(
      snap(now + 60 * H, [ev("past", now - 3 * H)]),
      snap(now + 60 * H, [ev("x", now + H)]),
      now,
    ),
  ).filter((k) => k.endsWith(":past")),
);
eq(
  "a calendar empty when the user left: nothing (not all new)",
  [],
  lib.changes(snap(now + 60 * H, []), current, now),
);
eq(
  "a calendar empty on return: nothing (not all cancelled)",
  [],
  lib.changes(before, snap(now + 70 * H, []), now),
);
eq("no snapshot at all: nothing", [], lib.changes(null, current, now));
eq("the same calendar: nothing", [], lib.changes(before, before, now));
eq(
  "an event that already started is not cancelled",
  [],
  kinds(
    lib.changes(
      snap(now + 60 * H, [ev("a", now - 0.5 * H), ev("b", now + 4 * H)]),
      snap(now + 60 * H, [ev("b", now + 4 * H)]),
      now,
    ),
  ),
);

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
