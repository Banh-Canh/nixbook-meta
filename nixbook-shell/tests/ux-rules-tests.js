// Muse's plain-code UX rules (src/modules/common/functions/), under node:
//   - step_labels.js: steps in words in the four languages, never a server
//     id, a raw tool name, a path or an argument; grouping keys; details;
//   - offer_cues.js: what an offer is about (one offer per moment), the same
//     moment across surfaces, a text naming it;
//   - theme_moods.js: a mood asked of the desktop as a theme, in the four
//     languages; anything unsure left to Muse.
// Run by ux-rules.sh (node).
"use strict";
const fs = require("fs");
const path = require("path");

function load(file, names) {
  const src = fs
    .readFileSync(
      path.join(__dirname, "../src/modules/common/functions", file),
      "utf8",
    )
    .replace(/^\.pragma library/m, "");
  return new Function(
    src + "\nreturn { " + names.map((n) => `${n}: ${n}`).join(", ") + " }",
  )();
}
const L = load("step_labels.js", [
  "say",
  "key",
  "parse",
  "detail",
  "argsOf",
  "thinkName",
  "serverName",
  "PHRASES",
]);
const C = load("offer_cues.js", [
  "fromInitiative",
  "fromNextUp",
  "fromClipboard",
  "fromMeeting",
  "same",
  "mentions",
]);
const M = load("theme_moods.js", ["mood"]);

let failed = 0,
  passed = 0;
function check(name, got, want) {
  if (JSON.stringify(got) === JSON.stringify(want)) {
    passed++;
    return;
  }
  failed++;
  console.log(
    `FAIL ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`,
  );
}

// ── step_labels.js ──
const done = (n, a, l) => L.say(n, a, l || "en", "done");
const doing = (n, a, l) => L.say(n, a, l || "en", "doing");
check(
  "jellyfin next_up (full name)",
  done("mcp__jellyfin__next_up"),
  "Checked your watch list",
);
check(
  "jellyfin next_up (the chat's label)",
  done("jellyfin: next_up"),
  "Checked your watch list",
);
check(
  "jellyfin next_up, doing",
  doing("mcp__jellyfin__next_up"),
  "Checking your watch list",
);
check("Bash", done("Bash"), "Ran a command");
check("WebSearch", done("WebSearch"), "Looked something up");
check("WebFetch", done("WebFetch"), "Read a page");
check("Read", done("Read"), "Read a file");
check("Grep", done("Grep"), "Looked through your files");
check(
  "set_wallpaper (bare)",
  done("set_wallpaper", { path: "/home/u/Pictures/a.png" }),
  "Changed the wallpaper",
);
check(
  "set wallpaper (its words)",
  done("set wallpaper"),
  "Changed the wallpaper",
);
check("set_theme", done("mcp__desktop__set_theme"), "Changed the theme");
check("desktop: click", done("desktop: click"), "Clicked");
check(
  "a trust class: media_control:pause",
  done("media_control:pause"),
  "Controlled the music",
);
check(
  "a trust class with its app",
  done("close_window@firefox"),
  "Closed a window",
);
check("calendar add", done("calendar:add"), "Added an event");
check(
  "calendar list (args)",
  done("calendar", { action: "list" }),
  "Checked your calendar",
);
check("calendar delete", done("calendar:delete"), "Updated your calendar");
check(
  "tasks create",
  done("tasks", { action: "create" }),
  "Updated your tasks",
);
check("terminal_run class", done("terminal_run:git-status"), "Ran a command");
check(
  "discord send",
  done("mcp__desktop__discord", { action: "send" }),
  "Sent a message",
);
check("discord read", done("discord:read"), "Read your messages");
check("page_read", done("page_read"), "Read a page");
check("page_go", done("page_go"), "Opened a page");
check("open_tools", done("open_tools__desktop_media"), "Got the right tools");
check("seerr request", done("mcp__seerr__request"), "Requested a title");
check(
  "jellyfin search",
  done("mcp__jellyfin__search"),
  "Searched your library",
);
check("jellyfin play", done("mcp__jellyfin__play"), "Started playback");
check(
  "jellyfin sessions",
  done("mcp__jellyfin__sessions"),
  "Checked what's playing",
);
check(
  "youtube music queue",
  done("mcp__youtube-music__add_to_queue"),
  "Added to the queue",
);
check(
  "a known app, reading",
  done("mcp__linkedin__get_profile"),
  "Checked LinkedIn",
);
check("a known app, acting", done("mcp__immich__upload_asset"), "Used Immich");
check(
  "an unknown server: never its id",
  done("mcp__my-weird-srv__do_thing"),
  "Used one of your apps",
);
check(
  "an unknown server reading: never its id",
  done("mcp__x9z__list_items"),
  "Checked one of your apps",
);
check("an unknown desktop tool", done("frobnicate"), "Took a step");
check("an unknown reading tool", done("get_widget_state"), "Checked something");
check("nothing", done(""), "Took a step");
check(
  "French",
  done("mcp__jellyfin__next_up", null, "fr"),
  "J'ai consulté ta liste à regarder",
);
check("French doing", doing("Bash", null, "fr"), "Je lance une commande");
check("German", done("set_theme", null, "de"), "Das Design geändert");
check("Vietnamese done", done("set_theme", null, "vi"), "Đã đổi giao diện");
check("Vietnamese doing", doing("WebSearch", null, "vi"), "Đang tra cứu");
check(
  "an unknown language: English",
  done("Bash", null, "ja"),
  "Ran a command",
);
check(
  "a known app in French",
  done("mcp__immich__upload_asset", null, "fr"),
  "J'ai utilisé Immich",
);
// Never a server id, a raw tool name, a path: whatever the name.
const names = [
  "mcp__jellyfin__next_up",
  "mcp__zz_srv__x_y",
  "Bash",
  "set_wallpaper",
  "terminal_run:rm-rf",
  "mcp__a__b",
  "jellyfin: continue_watching",
  "frobnicate_widget",
  "close_window@org.mozilla.firefox",
];
for (const lang of ["en", "fr", "de", "vi"]) {
  for (const n of names) {
    const s =
      done(n, { path: "/home/u/x" }, lang) +
      " " +
      doing(n, { path: "/home/u/x" }, lang);
    check(
      `no raw words (${lang}, ${n})`,
      /mcp__|_|\/|zz_srv|frobnicate|org\.mozilla/.test(s),
      false,
    );
  }
}
// Every phrase in the four languages, both forms.
for (const k of Object.keys(L.PHRASES)) {
  const p = L.PHRASES[k];
  check(
    `phrase ${k}: four languages`,
    ["en", "fr", "de"].every((l) => Array.isArray(p[l]) && p[l].length === 2) &&
      typeof p.vi === "string",
    true,
  );
}
check(
  "same kind, same key (grouping)",
  L.key("mcp__youtube-music__add_to_queue") ===
    L.key("youtube_music: queue_add"),
  true,
);
check(
  "argsOf a told summary",
  L.argsOf("add to queue (query=K/DA MORE, path=/x)"),
  { query: "K/DA MORE", path: "/x" },
);
check("argsOf a bare summary", L.argsOf("app=firefox, name=Dune"), {
  app: "firefox",
  name: "Dune",
});
check("detail: a title", L.detail({ query: "K/DA MORE" }), "K/DA MORE");
check("detail: never a path", L.detail({ path: "/home/u/Pictures/x.png" }), "");
check(
  "detail: a path in the name too",
  L.detail({ name: "/home/u/Downloads/report.pdf" }),
  "",
);
check(
  "detail: a link, its host",
  L.detail({ title: "https://www.example.com/a/b?q=1" }),
  "example.com",
);
check("detail: never an id", L.detail({ name: "3f2a9c1e-77aa-4b1c" }), "");
check(
  "detail: a desktop id as a name",
  L.detail({ app: "firefox.desktop" }),
  "firefox",
);
check("detail: long, cut", L.detail({ text: "word ".repeat(15) }).length, 40);
check(
  "thinkName",
  L.thinkName('**jellyfin: next_up** {"limit": 5}'),
  "jellyfin: next_up",
);
check("thinkName, a plain thought", L.thinkName("Let me think about it"), "");

// ── offer_cues.js ──
const reaction = {
  id: "a1",
  kind: "react",
  text: "report.pdf just landed in Downloads. Want the gist of it?",
  actions: [
    {
      label: "Summarize it",
      do: "ask",
      text: "Summarize this file for me.",
      path: "/home/u/Downloads/report.pdf",
      attach: "/home/u/Downloads/report.pdf",
    },
    { label: "Open", do: "open", path: "/home/u/Downloads/report.pdf" },
  ],
};
const r = C.fromInitiative(reaction);
check("a reaction's file", r.key, "file:/home/u/Downloads/report.pdf");
const nu = C.fromNextUp({
  kind: "followup",
  action: "followup:summarize",
  target: { path: "/home/u/Downloads/report.pdf" },
});
check(
  "Next up's follow-up of the same file: the same moment",
  C.same(r, nu),
  true,
);
check(
  "a renamed download (same name): the same moment",
  C.same(
    r,
    C.fromNextUp({
      kind: "followup",
      target: { path: "/home/u/Documents/report.pdf" },
    }),
  ),
  true,
);
check(
  "another file: not the same",
  C.same(
    r,
    C.fromNextUp({
      kind: "followup",
      target: { path: "/home/u/Downloads/other.pdf" },
    }),
  ),
  false,
);
check(
  "a command reaction: no file cue (its folder)",
  C.fromInitiative({
    actions: [{ do: "ask", path: "/home/u/src", text: "x" }],
  }),
  null,
);
check(
  "an offer's trigger",
  C.fromInitiative({ trigger: { kind: "error_copied", key: "abc" } }).key,
  "trigger:error_copied:abc",
);
check(
  "Next up's review: its repo",
  C.fromNextUp({ kind: "followup", target: { repo: "didactiklabs/nixbook" } })
    .key,
  "pr:didactiklabs/nixbook",
);
check(
  "Next up's meeting = the meeting's record",
  C.same(
    C.fromNextUp({ kind: "followup", target: { title: "Daily standup" } }),
    C.fromMeeting("Daily Standup"),
  ),
  true,
);
check(
  "Next up's link = the clipboard's",
  C.same(
    C.fromNextUp({ kind: "url", url: "https://www.github.com/a/b/" }),
    C.fromClipboard("https://github.com/a/b?x=1", "url"),
  ),
  true,
);
check(
  "Next up's app: its own cue",
  C.fromNextUp({ kind: "app", app: "Jira" }).key,
  "app:jira",
);
check(
  "a text naming the file",
  C.mentions("Summarize report.pdf for me", r),
  true,
);
check(
  "its name without the extension (distinctive)",
  C.mentions(
    "what's in quarterly-budget?",
    C.fromInitiative({
      actions: [{ do: "open", path: "/d/quarterly-budget.xlsx" }],
    }),
  ),
  true,
);
check(
  "a plain stem doesn't count (report)",
  C.mentions("write a report on cats", r),
  false,
);
check(
  "the full path",
  C.mentions("I read /home/u/Downloads/report.pdf", r),
  true,
);
check(
  "a file name at a sentence's end",
  C.mentions("Here is the gist of report.pdf.", r),
  true,
);
check("inside another word: no", C.mentions("myreport.pdfs", r), false);
check(
  "accents folded",
  C.mentions(
    "Résumé de Été.pdf",
    C.fromInitiative({ actions: [{ do: "open", path: "/d/été.pdf" }] }),
  ),
  true,
);
check("nothing about it", C.mentions("pause the music", r), false);
check(
  "a repo named",
  C.mentions(
    "review didactiklabs/nixbook#12",
    C.fromNextUp({
      kind: "followup",
      target: { repo: "didactiklabs/nixbook" },
    }),
  ),
  true,
);
check("no cue: never mentioned", C.mentions("anything", null), false);

// ── theme_moods.js ──
const theme = (t) => (M.mood(t) || {}).theme || null;
check("cozy and calm", theme("make my desktop calmer and cozier"), "ghibli");
check("cozy", theme("I want a cozy desktop"), "ghibli");
check("relaxing vibe", theme("give me a relaxing vibe"), "ghibli");
check("cute", theme("make the theme cute"), "chiikawa");
check("kawaii look", theme("a kawaii look please"), "chiikawa");
check("neon and edgy", theme("make my screen neon and edgy"), "cyberpunk");
check(
  "bold, stylish",
  theme("something bold and stylish for my desktop"),
  "persona",
);
check("plain", theme("back to a plain desktop"), "material");
check("default theme", theme("default theme"), "material");
check("a theme by name", theme("switch to the ghibli theme"), "ghibli");
check("French: cosy", theme("rends mon bureau plus cosy et calme"), "ghibli");
check("French: mignon", theme("un thème mignon"), "chiikawa");
check("French: sobre", theme("un bureau sobre"), "material");
check("German: gemütlich", theme("mach meinen Desktop gemütlicher"), "ghibli");
check("German: niedlich", theme("ein niedliches Design"), "chiikawa");
check(
  "German: einfach is a filler",
  theme("mach einfach den desktop gemütlich"),
  "ghibli",
);
check("Vietnamese: ấm cúng", theme("làm màn hình ấm cúng hơn"), "ghibli");
check("Vietnamese: dễ thương", theme("giao diện dễ thương"), "chiikawa");
check(
  "Vietnamese: không khí is not a negation",
  theme("cho không khí thư giãn"),
  "ghibli",
);
check("no desktop word: Muse's", theme("I feel cozy"), null);
check(
  "two themes' moods: Muse's",
  theme("make my desktop cute but clean"),
  null,
);
check("a negation: Muse's", theme("make my desktop less cute"), null);
check("French negation", theme("un bureau pas trop mignon"), null);
check("a question: Muse's", theme("which theme is the coziest?"), null);
check("dark alone stays dark mode", theme("dark theme"), null);
check(
  "a long story: Muse's",
  theme("make my desktop cozy " + "and ".repeat(40)),
  null,
);
check("nothing", theme(""), null);

// Speed: well under a millisecond each.
const t0 = Date.now();
for (let i = 0; i < 2000; i++) {
  L.say("mcp__jellyfin__next_up", {}, "fr", "done");
  C.mentions("Summarize report.pdf for me", r);
  M.mood("make my desktop calmer and cozier");
}
const per = (Date.now() - t0) / 2000;
check(`fast (${per.toFixed(3)} ms for the three)`, per < 1, true);

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
