// Was it said to Muse? Full AI mode's plain-code rules
// (src/modules/common/functions/addressee.js) on sentences in the four
// languages: its name (and how recognisers write it), another person's,
// answers to it, stop words, calls, fillers, the reply windows, the modes,
// and its speed. Run by addressee.sh (node).
"use strict";
const fs = require("fs");
const path = require("path");

const src = fs
  .readFileSync(
    path.join(__dirname, "../src/modules/common/functions/addressee.js"),
    "utf8",
  )
  .replace(/^\.pragma library/m, "");
const lib = new Function(
  src +
    "\nreturn { decide: decide, calledByName: calledByName, otherPerson: otherPerson, claimOf: claimOf, notYou: notYou }",
)();

const NOW = 1000000000;
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
function decide(text, ctx) {
  return lib.decide(
    text,
    Object.assign({ mode: "smart", now: NOW }, ctx || {}),
  );
}
// verdict, and the order when it is for Muse.
function yes(text, order, ctx) {
  const d = decide(text, ctx);
  check(`yes: ${text}`, d.verdict, "yes");
  if (order !== undefined) check(`order: ${text}`, d.order, order);
  return d;
}
function no(text, why, ctx) {
  const d = decide(text, ctx);
  check(`no: ${text}`, d.verdict, "no");
  if (why) check(`why: ${text}`, d.why, why);
}
function unsure(text, ctx) {
  check(`ask the model: ${text}`, decide(text, ctx).verdict, "ask");
}

// 1. Its name, at the start, after a greeting, at the end, mid-sentence.
yes("Muse, open Firefox", "open Firefox");
yes("Muse open Firefox", "open Firefox");
yes("hey Muse what's the weather", "what's the weather");
yes("Ok Muse, play some jazz.", "play some jazz.");
yes("What time is it, Muse?", "What time is it?");
yes("open the calendar Muse", "open the calendar");
yes("Could you, Muse, close this window", "Could you, close this window");
yes("Please Muse turn it down", "turn it down");
// How recognisers write it.
yes("Mews, open the calendar", "open the calendar");
yes("Muze, mute", "mute");
yes("hey music, pause", "pause");
yes("ok moose next song", "next song");
// The name alone calls it.
check("name alone", decide("Hey Muse!").why, "name-only");
check("name alone, a question", decide("Muse?").why, "name-only");
// French, German, Vietnamese.
yes("Muse, ouvre Firefox", "ouvre Firefox");
yes("Dis Muse, quel temps fait-il ?", "quel temps fait-il ?");
yes("Salut Muse, mets de la musique", "mets de la musique");
yes("Tu peux baisser le son, Muse ?", "Tu peux baisser le son?");
yes("Hallo Muse, mach das Licht aus", "mach das Licht aus");
yes("Muse, wie spät ist es?", "wie spät ist es?");
yes("Kannst du das schließen, Muse?", "Kannst du das schließen?");
yes("Muse ơi, mở nhạc", "mở nhạc");
yes("Này Muse, mấy giờ rồi", "mấy giờ rồi");
yes("Mở nhạc đi Muse ơi", "Mở nhạc đi");
// About Muse, not to it: the model decides.
unsure("Muse is slow today");
unsure("I should ask Muse");
unsure("demande à Muse");
unsure("I love music");
unsure("play some music");
unsure("hey, can you open Firefox");
unsure("Muse's voice is weird");
unsure("she was my muse");
check("about it: not called by name", lib.calledByName("Muse a planté"), null);

// 2. Someone else called.
no("Paul, can you pass the salt?", "other-person");
no("Maman, tu viens manger ?", "other-person");
no("hey Julia", "other-person");
no("Can you close the door, Paul?", "other-person");
no("Schatz, kommst du?", "other-person");
no("Mẹ ơi, con đói", "other-person");
no("Anh ơi, đợi em", "other-person");
no("Lan ơi", "other-person");
no("ok Google, set a timer", "other-person");
no("Alexa play music", "other-person");
no("Honey, where are the keys?", "other-person");
no("hey guys, dinner is ready", "other-person");
// Not names: sentence openings before a comma, a Vietnamese pronoun.
unsure("So, what do we do tonight?");
unsure("Alors, on fait quoi ?");
unsure("Also, wann kommst du?");
unsure("Okay, Firefox is slow");
unsure("Em mở nhạc nhé");
unsure("Bonjour, ça va ?");
unsure("Trời ơi nóng quá");
// Even with its question waiting, another person's name wins.
no("Paul, yes", "other-person", { pending: true });

// 3. Answers to it, stop words.
yes("yes", "yes", { pending: true });
yes("no, don't", "no, don't", { pending: true, inCall: true });
no("yes I think we should move the release to Friday", "call", {
  pending: true,
  inCall: true,
});
yes("the blue one", "the blue one", { asking: true });
yes("stop", "stop", { halt: true, speaking: true });
yes("wait", "wait", { halt: true, busy: true });
no("wait", "call", { halt: true, busy: true, inCall: true });
yes("stop", "stop", { halt: true, speaking: true, inCall: true });

// 4. A call: by name only.
no("let's move the meeting to Friday", "call", { inCall: true });
no("can you hear me", "call", { inCall: true, spokeAt: NOW - 2000 });
yes("Muse, mute me", "mute me", { inCall: true });

// 5. Replies: while it talks, right after, a back-and-forth.
yes("actually make it louder", undefined, { speaking: true });
yes("and the next one", undefined, { spokeAt: NOW - 5000 });
unsure("and the next one", { spokeAt: NOW - 9000 });
yes("and tomorrow?", undefined, {
  addressedAt: NOW - 20000,
  spokeAt: NOW - 15000,
});
unsure("and tomorrow?", { addressedAt: NOW - 20000, spokeAt: NOW - 30000 });
unsure("and tomorrow?", { addressedAt: NOW - 30000, spokeAt: NOW - 28000 });
// Fillers: nobody's.
no("hmm", "filler");
no("euh", "filler");
no("äh, hm", "filler");
no("ờ", "filler");
yes("hmm", undefined, { asking: true });

// 6. Correcting it: "not you" (before its name), and claiming it.
for (const t of [
  "No, not you",
  "not you Muse",
  "I'm not talking to you",
  "I wasn't talking to you, Muse",
  "that wasn't for you",
  "Non, pas toi",
  "je ne te parle pas Muse",
  "c'était pas pour toi",
  "Nein, nicht du",
  "ich rede nicht mit dir",
  "das war nicht für dich",
  "không phải nói với bạn",
  "tôi không nói với bạn đâu",
])
  no(t, "not-you");
// A claim alone: named always, unnamed only with words let go lately.
for (const t of [
  "Yes I'm talking to you Muse",
  "yes, I'm talking to you, Muse!",
  "Muse, that was for you",
  "Oui Muse, c'est à toi que je parle",
  "Muse, je te parle",
  "Ja Muse, ich rede mit dir",
  "Muse ơi, tôi đang nói với bạn đó",
])
  check(`claim, named: ${t}`, decide(t).verdict, "claim");
check(
  "claim, unnamed, something let go",
  decide("I'm talking to you", { overheardAt: NOW - 10000 }).verdict,
  "claim",
);
check(
  "claim, unnamed, nothing let go: someone else's",
  decide("I'm talking to you!").verdict === "claim",
  false,
);
check(
  "claim, unnamed, let go too long ago",
  decide("c'est à toi que je parle", { overheardAt: NOW - 200000 }).verdict ===
    "claim",
  false,
);
// A claim with an order: the order alone.
yes("I'm talking to you, open Firefox", "open Firefox");
yes("Muse, I'm talking to you: play some jazz", "play some jazz");
// Talk to a person that looks like a claim: not one.
unsure("c'est à toi de jouer");
unsure("je te parle de mon boulot demain");
// Right after it spoke, a long sentence for the room: the model judges it.
unsure("I told my sister we would visit them next weekend after lunch", {
  spokeAt: NOW - 3000,
});
unsure("tu crois qu'on aura le temps de passer chez ta mère ce soir", {
  speaking: true,
});
yes("and make it louder please", undefined, { spokeAt: NOW - 3000 });
yes("ouvre aussi le calendrier s'il te plaît", undefined, {
  spokeAt: NOW - 3000,
});

// Modes.
check(
  "name mode: unnamed",
  decide("open firefox", { mode: "name" }).why,
  "not-named",
);
check(
  "name mode: named",
  decide("Muse open firefox", { mode: "name" }).verdict,
  "yes",
);
check(
  "name mode: right after it spoke, still unnamed",
  decide("and the next one", { mode: "name", spokeAt: NOW - 2000 }).verdict,
  "no",
);
check(
  "name mode: its question answered",
  decide("yes", { mode: "name", pending: true }).verdict,
  "yes",
);
check(
  "all mode",
  decide("Paul, can you pass the salt?", { mode: "all" }).verdict,
  "yes",
);
check("empty", decide("   ").verdict, "no");

// Private listening (ai.voice.privateListening): no model, what the rules
// can't tell is not for Muse; everything they decide stays as it was.
no("I think we should repaint the kitchen", "private", { private: true });
no("so what do you think about it", "private", { private: true });
yes("Muse, open Firefox", "open Firefox", { private: true });
yes("and the next one", "and the next one", {
  private: true,
  spokeAt: NOW - 2000,
});
yes("yes", "yes", { private: true, pending: true });
no("Paul, can you pass the salt?", "other-person", { private: true });
no("what do you mean", "call", { private: true, inCall: true });
check(
  "private listening: never 'ask the model'",
  [
    "open the calendar",
    "hmm the calendar maybe",
    "tomorrow at nine",
    "c'est quoi déjà",
    "wie spät ist es",
    "mấy giờ rồi",
  ].some((t) => decide(t, { private: true }).verdict === "ask"),
  false,
);
check(
  "private listening off: the model still decides the unclear",
  decide("I think we should repaint the kitchen", { private: false }).verdict,
  "ask",
);

// Speed: plain code, no model.
const t0 = Date.now();
for (let i = 0; i < 20000; i++)
  decide(i % 2 ? "Muse, open Firefox" : "Paul, can you pass the salt?");
const ms = Date.now() - t0;
check(`20000 decisions under 1 s (${ms} ms)`, ms < 1000, true);

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
