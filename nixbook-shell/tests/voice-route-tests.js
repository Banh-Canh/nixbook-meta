// Where the microphone's audio goes (src/modules/common/functions/
// voice_route.js, used by services/Voice.qml): private listening keeps what
// listens on its own on this computer, what the user starts keeps
// ai.voice.engine, nothing is captured while away, what is judged, the
// turn limits, the mascot's badge. Run by addressee.sh (node).
"use strict";
const fs = require("fs");
const path = require("path");

const src = fs
  .readFileSync(
    path.join(__dirname, "../src/modules/common/functions/voice_route.js"),
    "utf8",
  )
  .replace(/^\.pragma library/m, "");
const r = new Function(
  src +
    "\nreturn { settingEngine, captureEngine, micAllowed, judged, maxSeconds, micState }",
)();

let failed = 0,
  passed = 0;
function check(name, got, want) {
  if (got === want) {
    passed++;
    return;
  }
  failed++;
  console.log(
    `FAIL ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`,
  );
}

// ai.voice.engine.
check("auto with Meta's key: Meta", r.settingEngine("auto", true), "meta");
check("auto without: this computer", r.settingEngine("auto", false), "local");
check("meta", r.settingEngine("meta", false), "meta");
check("local", r.settingEngine("local", true), "local");

// Every capture, every setting: only what the user started may go to Meta
// with private listening.
for (const setting of ["auto", "meta", "local"])
  for (const metaReady of [true, false])
    for (const solicited of [true, false])
      for (const privateListening of [true, false, undefined]) {
        const e = r.captureEngine({
          setting,
          metaReady,
          solicited,
          privateListening,
        });
        const priv = privateListening !== false;
        const want =
          priv && !solicited ? "local" : r.settingEngine(setting, metaReady);
        check(
          `capture ${setting}/${metaReady}/${solicited}/${privateListening}`,
          e,
          want,
        );
        if (priv && !solicited)
          check(`never Meta unasked (${setting})`, e === "meta", false);
      }
check(
  "Full AI's always-open mic on Meta's setting: here",
  r.captureEngine({
    setting: "meta",
    metaReady: true,
    solicited: false,
    privateListening: true,
  }),
  "local",
);
check(
  "Mod+T on Meta's setting: Meta",
  r.captureEngine({
    setting: "meta",
    metaReady: true,
    solicited: true,
    privateListening: true,
  }),
  "meta",
);
check(
  "private listening off, Full AI: as the setting",
  r.captureEngine({
    setting: "auto",
    metaReady: true,
    solicited: false,
    privateListening: false,
  }),
  "meta",
);
check(
  "default (no settings): private",
  r.captureEngine({ setting: "meta", metaReady: true }),
  "local",
);

// Away: nothing.
check("mic: here", r.micAllowed({}), true);
check("mic: locked", r.micAllowed({ locked: true }), false);
check("mic: screens off", r.micAllowed({ screensOff: true }), false);

// Judged by the rules (addressee.js) before going on.
check(
  "judged: Full AI",
  r.judged({
    mode: "smart",
    fullAi: true,
    solicited: false,
    privateListening: false,
  }),
  true,
);
check("judged: Full AI, all", r.judged({ mode: "all", fullAi: true }), false);
check(
  "judged: a conversation's next turn, private",
  r.judged({
    mode: "smart",
    fullAi: false,
    solicited: false,
    privateListening: true,
  }),
  true,
);
check(
  "judged: a conversation's next turn, not private",
  r.judged({
    mode: "smart",
    fullAi: false,
    solicited: false,
    privateListening: false,
  }),
  false,
);
check(
  "judged: after Mod+T, never",
  r.judged({
    mode: "smart",
    fullAi: false,
    solicited: true,
    privateListening: true,
  }),
  false,
);
check(
  "judged: name mode, next turn",
  r.judged({
    mode: "name",
    fullAi: false,
    solicited: false,
    privateListening: true,
  }),
  true,
);

// Turn limits.
check(
  "limit: listening on its own here",
  r.maxSeconds({ maxSeconds: 120, engine: "local", solicited: false }),
  30,
);
check(
  "limit: Mod+T here",
  r.maxSeconds({ maxSeconds: 120, engine: "local", solicited: true }),
  120,
);
check(
  "limit: Meta",
  r.maxSeconds({ maxSeconds: 90, engine: "meta", solicited: true }),
  90,
);
check(
  "limit: a short setting kept",
  r.maxSeconds({ maxSeconds: 10, engine: "local", solicited: false }),
  10,
);
check("limit: clamped", r.maxSeconds({ maxSeconds: 1, engine: "meta" }), 5);

// The mascot's badge.
check("badge: muted", r.micState({ micOn: false, allowed: true }), "off");
check(
  "badge: away",
  r.micState({
    micOn: true,
    allowed: false,
    capturing: true,
    captureEngine: "meta",
  }),
  "paused",
);
check(
  "badge: sending to Meta",
  r.micState({
    micOn: true,
    allowed: true,
    capturing: true,
    captureEngine: "meta",
    nextEngine: "local",
  }),
  "meta",
);
check(
  "badge: here, capturing",
  r.micState({
    micOn: true,
    allowed: true,
    capturing: true,
    captureEngine: "local",
    nextEngine: "meta",
  }),
  "local",
);
check(
  "badge: between turns, the next one's",
  r.micState({
    micOn: true,
    allowed: true,
    capturing: false,
    nextEngine: "local",
  }),
  "local",
);
check(
  "badge: between turns, Meta (private off)",
  r.micState({
    micOn: true,
    allowed: true,
    capturing: false,
    nextEngine: "meta",
  }),
  "meta",
);

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
