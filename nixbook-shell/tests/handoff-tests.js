// The phone handoff's plain-code rules (src/modules/common/functions/
// handoff.js): when a message goes to the phone, what it says (the kind of
// thing waiting and when, never its text), in the four languages, and never
// the same twice while away. Run by brief.sh (node).
"use strict";
const fs = require("fs");
const path = require("path");

const src = fs
  .readFileSync(
    path.join(__dirname, "../src/modules/common/functions/handoff.js"),
    "utf8",
  )
  .replace(/^\.pragma library/m, "");
const lib = new Function(src + "\nreturn { decide: decide, lines: lines }")();

let failed = 0,
  passed = 0;
function check(name, got, want) {
  const g = JSON.stringify(got),
    w = JSON.stringify(want);
  if (g === w) {
    passed++;
    return;
  }
  failed++;
  console.log(`FAIL ${name}: got ${g}, want ${w}`);
}

const NOW = new Date(2026, 10, 2, 15, 0, 0).getTime();
const MIN = 60000;
function state(extra) {
  return Object.assign(
    {
      enabled: true,
      policy: 1,
      paused: false,
      dnd: false,
      presenting: false,
      away: true,
      awayMinutes: 6,
      afterMinutes: 5,
      phone: true,
      sent: [],
      question: false,
      approvals: 0,
      tasks: 0,
      reminders: [],
      events: [],
      now: NOW,
      horizonMinutes: 60,
      lang: "en",
    },
    extra || {},
  );
}

// -- when ---------------------------------------------------------------------
check("nothing waits: nothing sent", lib.decide(state()).why, "nothing waits");
const q = state({ question: true });
check("a question waits: sent", lib.decide(q).send, true);
check("off", lib.decide(Object.assign({}, q, { enabled: false })).why, "off");
check(
  "AI off",
  lib.decide(Object.assign({}, q, { policy: 0 })).why,
  "AI is off",
);
check(
  "desktop control paused",
  lib.decide(Object.assign({}, q, { paused: true })).why,
  "desktop control is paused",
);
check(
  "Do Not Disturb",
  lib.decide(Object.assign({}, q, { dnd: true })).why,
  "Do Not Disturb",
);
check(
  "presenting",
  lib.decide(Object.assign({}, q, { presenting: true })).why,
  "presenting",
);
check(
  "at the computer",
  lib.decide(Object.assign({}, q, { away: false })).why,
  "at the computer",
);
check(
  "not away long enough",
  lib.decide(Object.assign({}, q, { awayMinutes: 2 })).why,
  "not away long enough",
);
check(
  "no phone",
  lib.decide(Object.assign({}, q, { phone: false })).why,
  "no phone",
);
check("no state at all", lib.decide(undefined).why, "off");

// -- what -----------------------------------------------------------------------
const all = lib.decide(
  state({
    question: true,
    approvals: 2,
    tasks: 1,
    reminders: [
      { id: "r1", at: NOW + 30 * MIN },
      { id: "r2", at: NOW + 3 * 60 * MIN }, // past the hour: not yet
      { id: "r0", at: NOW - MIN }, // gone
    ],
    events: [{ id: "e1", at: NOW + 20 * MIN }],
  }),
);
check("everything, a line each", all.lines, [
  "I asked you something and I'm waiting for your answer.",
  "2 steps wait for your OK.",
  "A background task needs you.",
  "Reminder at 15:30.",
  "Event at 15:20.",
]);
check(
  "the text: a header, then the lines",
  all.text.split("\n")[0],
  "Muse, from your computer:",
);
check("its keys", all.keys, [
  "q",
  "a2",
  "t1",
  "r:r1@" + (NOW + 30 * MIN),
  "e:e1@" + (NOW + 20 * MIN),
]);
check(
  "never a reminder's or an event's text",
  /dentist|rent|password/i.test(
    lib.decide(
      state({
        reminders: [
          { id: "r1", at: NOW + 5 * MIN, text: "pay the rent, password 1234" },
        ],
        events: [{ id: "e1", at: NOW + 5 * MIN, title: "Dentist" }],
      }),
    ).text,
  ),
  false,
);
check("one approval", lib.decide(state({ approvals: 1 })).lines, [
  "A step waits for your OK.",
]);
check(
  "bad counts are none",
  lib.decide(state({ approvals: -3, tasks: "2" })).why,
  "nothing waits",
);

// -- never twice ----------------------------------------------------------------
const first = lib.decide(state({ question: true, approvals: 1 }));
check(
  "the same again: not sent",
  lib.decide(state({ question: true, approvals: 1, sent: first.keys })).why,
  "already sent",
);
check(
  "less than before: not sent",
  lib.decide(state({ question: true, sent: first.keys })).why,
  "already sent",
);
check(
  "something new: sent, with what still waits",
  lib.decide(
    state({ question: true, approvals: 1, tasks: 1, sent: first.keys }),
  ).lines,
  [
    "I asked you something and I'm waiting for your answer.",
    "A step waits for your OK.",
    "A background task needs you.",
  ],
);

// -- languages ------------------------------------------------------------------
const many = {
  question: true,
  approvals: 2,
  reminders: [{ id: "r", at: NOW + 10 * MIN }],
};
check("fr", lib.decide(state(Object.assign({ lang: "fr" }, many))).lines, [
  "Je vous ai posé une question et j'attends votre réponse.",
  "2 étapes attendent votre accord.",
  "Rappel à 15:10.",
]);
check("de", lib.decide(state(Object.assign({ lang: "de" }, many))).lines, [
  "Ich habe dich etwas gefragt und warte auf deine Antwort.",
  "2 Schritte warten auf dein OK.",
  "Erinnerung um 15:10.",
]);
check(
  "vi",
  lib.decide(state(Object.assign({ lang: "vi" }, many))).text.split("\n"),
  [
    "Muse, từ máy tính của bạn:",
    "Tôi đã hỏi bạn một điều và đang chờ câu trả lời.",
    "2 bước đang chờ bạn đồng ý.",
    "Lời nhắc lúc 15:10.",
  ],
);
check(
  "an unknown language: English",
  lib.decide(state({ lang: "xx", tasks: 2 })).lines,
  ["2 background tasks need you."],
);

// -- speed ----------------------------------------------------------------------
const t0 = Date.now();
for (let i = 0; i < 10000; i++) lib.decide(state(many));
const each = (Date.now() - t0) / 10000;
check("well under a millisecond", each < 0.5, true);

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
