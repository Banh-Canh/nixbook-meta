.pragma library

// A mood asked of the desktop, as one of the shell's themes (modules/common/
// themes.json), in plain code: "make my desktop calmer and cozier" → Studio
// Ghibli, "something cute" → Chiikawa, "neon, edgy" → Cyberpunk 2077,
// "bold and stylish" → Persona, "back to something plain" → Material. For
// QuickIntent (done at once, with Undo); anything unsure is Muse's.
//   mood(text) -> {theme, word} or null (the theme keeps its own variant)
// It answers only when the text is about the desktop's look (a word for the
// desktop, the theme, its look or vibe) and names moods of ONE theme: two
// themes' moods ("cute but clean"), a negation ("less cute", "pas trop
// sombre"), a question about themes ("which theme is cozy?") are Muse's.
// "Dark" alone stays dark mode (QuickIntent's own rule). English, French,
// German (its adjective endings: gemütlicher, niedliches), Vietnamese.
// QML's JS engine: no ES2019+.

// The desktop's look, in the four languages.
var TARGET = new RegExp("(?:^|[^\\wÀ-ỹ])(?:desktop|screen|theme|themes|look|looks|vibe|vibes|setup|style|colou?rs|aesthetic|ui|"
    + "bureau|[eé]cran|th[eè]me|ambiance|apparence|couleurs|"
    + "bildschirm|design|thema|stil|farben|oberfl[aä]che|optik|"
    + "m[aà]n h[iì]nh|giao di[eệ]n|m[aá]y t[ií]nh|phong c[aá]ch|ch[uủ] [dđ][eề]|kh[oô]ng kh[ií])(?![\\wÀ-ỹ])", "i")

// theme id -> its mood words (stems: "cal(m|mer)", "coz(y|ier)").
var MOODS = [
    { theme: "ghibli",
      words: "ghibli|totoro|coz(?:y|ier|iness)|cos(?:y|ier)|comfy|calm(?:er|ing)?|relax(?:ing|ed)?|peaceful|serene|soothing|gentle|chill(?:er)?|warm(?:er)?|soft(?:er)?|"
           + "douillet(?:te)?|calme|apaisant(?:e)?|reposant(?:e)?|relaxant(?:e)?|paisible|chaleureu(?:x|se)|zen|"
           + "gem[uü]tlich[a-z]*|ruhig[a-z]*|entspann[a-z]*|behaglich[a-z]*|sanft[a-z]*|"
           + "[aấ]m c[uú]ng|th[uư] gi[aã]n|y[eê]n b[iì]nh|nh[eẹ] nh[aà]ng|[eê]m d[iị]u|d[eễ] ch[iị]u" },
    { theme: "chiikawa",
      words: "chiikawa|cute(?:r)?|kawaii|adorable|playful|sweet(?:er)?|cheerful|"
           + "mignon(?:ne)?|ludique|rigolo(?:te)?|"
           + "s[uü](?:ß|ss)[a-z]*|niedlich[a-z]*|verspielt[a-z]*|"
           + "d[eễ] th[uư][oơ]ng|[dđ][aá]ng y[eê]u|vui nh[oộ]n" },
    { theme: "cyberpunk",
      words: "cyberpunk(?: 2077)?|edg(?:y|ier)|neon|futuristic|cyber|hacker|gritty|"
           + "n[eé]on|futuriste|"
           + "d[uü]ster[a-z]*|futuristisch[a-z]*|"
           + "ng[aầ]u|t[uư][oơ]ng lai" },
    { theme: "persona",
      words: "persona|bold(?:er)?|stylish|punchy|striking|flashy|dramatic|"
           + "audacieu(?:x|se)|styl[eé](?:e)?|percutant(?:e)?|"
           + "mutig[a-z]*|stylisch[a-z]*|auff[aä]llig[a-z]*|knallig[a-z]*|"
           + "t[aá]o b[aạ]o|c[aá] t[ií]nh|n[oổ]i b[aậ]t|s[aà]nh [dđ]i[eệ]u" },
    { theme: "material",
      words: "material(?: you)?|plain(?:er)?|clean(?:er)?|default|simple(?:r)?|minimal(?:ist)?|neutral|sober|standard|normal|"
           + "sobre|[eé]pur[eé]|par d[eé]faut|neutre|minimaliste|"
           + "schlicht[a-z]*|sauber[a-z]*|neutral[a-z]*|minimalistisch[a-z]*|"
           + "[dđ][oơ]n gi[aả]n|m[aặ]c [dđ][iị]nh|b[iì]nh th[uư][oờ]ng|t[oố]i gi[aả]n|g[oọ]n g[aà]ng" }
]
for (var i = 0; i < MOODS.length; i++)
    MOODS[i].re = new RegExp("(?:^|[^\\wÀ-ỹ])(" + MOODS[i].words + ")(?![\\wÀ-ỹ])", "i")

// Not that mood (less, not, without…), or a question about the themes: Muse's.
var NEGATION = /(?:^|[^\wÀ-ỹ])(?:not|no|less|without|pas|moins|sans|nicht|kein(?:e|en)?|weniger|ohne|kh[oô]ng|b[oớ]t|[ií]t)(?![\wÀ-ỹ])/i
var QUESTION = /^(?:what|which|why|how|is|are|does|do|quel(?:le)?s?|pourquoi|comment|est-ce|welche[rs]?|was|warum|wie|gibt es|c[aá]i n[aà]o|t[aạ]i sao|l[aà]m sao)(?![\wÀ-ỹ])|(?:^|[^\wÀ-ỹ])(?:n[aà]o|kh[oô]ng)\s*\??$/i

function mood(text) {
    var t = String(text || "").trim().toLowerCase().replace(/\s+/g, " ")
    if (!t || t.length > 100 || t.indexOf("\n") >= 0) return null
    // "không khí" (the atmosphere) isn't "không" (not).
    if (!TARGET.test(t) || NEGATION.test(t.replace(/kh[oô]ng kh[ií]/g, "")) || QUESTION.test(t)) return null
    var found = null
    for (var i = 0; i < MOODS.length; i++) {
        var m = MOODS[i].re.exec(t)
        if (!m) continue
        // Two themes' moods: which one? Muse's.
        if (found) return null
        found = { theme: MOODS[i].theme, word: m[1] }
    }
    return found
}
