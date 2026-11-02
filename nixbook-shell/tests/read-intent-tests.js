// "Read this to me" / "describe this" said or typed in Muse's bubble
// (src/services/QuickIntent.qml): French, German and Vietnamese turned into
// the English command, which its patterns take; and what must not match.
// The phrases, _clean and the two patterns are read from the QML file.
// Run by read-aloud.sh.
"use strict";
const fs = require("fs");
const path = require("path");

const src = fs.readFileSync(
  path.join(__dirname, "..", "src", "services", "QuickIntent.qml"),
  "utf8",
);
const a =
  src.indexOf("readonly property var _phrases: [") +
  "readonly property var _phrases: ".length;
const b = src.indexOf("\n    ]\n", a) + 6;
const phrases = eval(src.slice(a, b));
const c = src.indexOf("function _clean(text) {");
const d = src.indexOf("\n    }\n", c) + 6;
const clean = eval(
  "(" + src.slice(c, d).replace("function _clean", "function") + ")",
);
// The two patterns of run(): the regex literals starting /^read(?: and /^describe(?:.
function literal(start) {
  const i = src.indexOf(start);
  const j = src.indexOf("$/", i) + 2;
  return eval(src.slice(i, j));
}
const readRe = literal("/^read(?:");
const descRe = literal("/^describe(?:");

function english(t) {
  for (const [re, to] of phrases) {
    const m = re.exec(t);
    if (!m) continue;
    return to.replace(/\$(\d)/g, (_, i) => m[Number(i)] ?? "").trim();
  }
  return t;
}
const samples = {
  read: [
    "read this",
    "Read this to me",
    "read it to me",
    "read the page out loud",
    "please read this",
    "lis-moi ça",
    "Lis ça",
    "lis-moi cette page",
    "lis à voix haute",
    "lies das vor",
    "Lies mir das vor",
    "vorlesen",
    "đọc cái này",
    "đọc cái này cho tôi nghe",
    "đọc cho tôi nghe",
    "đọc màn hình",
    "read",
  ],
  describe: [
    "describe this",
    "describe the screen",
    "décris ça",
    "décris l'écran",
    "beschreib das",
    "beschreibe den bildschirm",
    "mô tả cái này",
    "mô tả màn hình",
  ],
  none: [
    "read my mail",
    "open firefox",
    "lis le livre",
    "describe your day",
    "lies ein buch",
    "ouvre firefox",
    "read the news on reddit",
  ],
};
let bad = 0;
for (const [want, list] of Object.entries(samples))
  for (const s of list) {
    const t = english(clean(s));
    const got = readRe.test(t) ? "read" : descRe.test(t) ? "describe" : "none";
    if (got !== want) {
      bad++;
      console.log(`FAIL - ${s} -> ${t}: ${got}, not ${want}`);
    } else console.log(`ok   - ${want}: ${s}`);
  }
process.exit(bad ? 1 : 0);
