.pragma library

// What an offer is about (its cue), so the shell makes ONE offer per moment
// (services/Offers.qml): Muse's word after a download ("report.pdf just
// landed in Downloads. Want the gist?") and Next up's chip ("Next:
// summarize report.pdf") are the same moment; so are a copied link and the
// same link offered elsewhere. Plain code.
//   fromInitiative(item) -> cue of a word of Muse's (a reaction's file, an
//       offer's trigger), or null
//   fromNextUp(offer) -> cue of Next up's chip (its follow-up's file, pull
//       request or meeting; its link, its app)
//   fromClipboard(text, kind) -> cue of the smart clipboard's chips (a link)
//   fromMeeting(title) -> cue of a meeting's record or follow-up
//   same(a, b) -> the same moment
//   mentions(text, cue) -> a text (the user's request, Muse's answer) names
//       what the cue is about: the offer was acted on by another path
// A cue: {key, path?, words: [what names it in a text]}.
// QML's JS engine: no ES2019+.

function _fold(s) {
    return String(s || "").toLowerCase()
        .replace(/[àáâãäå]/g, "a").replace(/[èéêë]/g, "e").replace(/[ìíîï]/g, "i")
        .replace(/[òóôõö]/g, "o").replace(/[ùúûü]/g, "u").replace(/ç/g, "c").replace(/ß/g, "ss").replace(/đ/g, "d")
        .replace(/\s+/g, " ").trim()
}
function _base(path) {
    var s = String(path || "")
    var i = s.lastIndexOf("/")
    return i >= 0 ? s.slice(i + 1) : s
}
// What names a file: its name, and its name without the extension when that
// is distinctive (not "file", "image", "download"…).
var PLAIN_STEMS = /^(file|image|img|photo|picture|document|doc|download|untitled|scan|screenshot|export|data|report|invoice|test|new|copy)$/
function _fileWords(path) {
    var name = _base(path)
    if (!name) return []
    var out = [name]
    var dot = name.lastIndexOf(".")
    var stem = dot > 0 ? name.slice(0, dot) : ""
    if (stem.length >= 4 && !PLAIN_STEMS.test(_fold(stem))) out.push(stem)
    return out
}
function _url(u) {
    var m = /^[a-z][\w+.-]*:\/\/([^\/?#\s]+)([^?#\s]*)/i.exec(String(u || "").trim())
    if (!m) return null
    var host = m[1].toLowerCase().replace(/^www\./, "")
    var path = m[2].replace(/\/+$/, "")
    return { key: "url:" + host + path, host: host, path: path }
}

function fromInitiative(item) {
    if (!item || typeof item !== "object") return null
    var actions = item.actions || []
    for (var i = 0; i < actions.length; i++) {
        var p = actions[i] && actions[i].path
        if (typeof p === "string" && p.charAt(0) === "/" && actions[i].do !== "ask") {
            return { key: "file:" + p, path: p, words: _fileWords(p) }
        }
    }
    for (i = 0; i < actions.length; i++) {
        var a = actions[i] && actions[i].attach
        if (typeof a === "string" && a.charAt(0) === "/") return { key: "file:" + a, path: a, words: _fileWords(a) }
    }
    var t = item.trigger
    if (t && t.kind) return { key: "trigger:" + t.kind + ":" + (t.key || ""), words: [] }
    for (i = 0; i < actions.length; i++) {
        var u = actions[i] && actions[i].url && _url(actions[i].url)
        if (u) return { key: u.key, words: [u.host + u.path] }
    }
    return null
}

function fromNextUp(offer) {
    if (!offer || typeof offer !== "object") return null
    var target = offer.target || {}
    if (typeof target.path === "string" && target.path.charAt(0) === "/")
        return { key: "file:" + target.path, path: target.path, words: _fileWords(target.path) }
    if (target.repo) return { key: "pr:" + _fold(target.repo), words: [String(target.repo)] }
    if (target.title) return fromMeeting(target.title)
    if (offer.kind === "url") {
        var u = _url(offer.url)
        if (u) return { key: u.key, words: [u.host + u.path] }
    }
    if (offer.kind === "app" && offer.app) return { key: "app:" + String(offer.app).toLowerCase(), words: [] }
    return offer.action ? { key: "nextup:" + offer.action, words: [] } : null
}

function fromMeeting(title) {
    var t = String(title || "").trim()
    if (!t) return null
    return { key: "meeting:" + _fold(t), words: t.length >= 4 ? [t] : [] }
}

function fromClipboard(text, kind) {
    var s = String(text || "").trim()
    if (kind === "url") {
        var u = _url(s)
        if (u) return { key: u.key, words: [u.host + u.path] }
    }
    if (s.charAt(0) === "/" && s.indexOf("\n") < 0 && s.length < 400) return { key: "file:" + s, path: s, words: _fileWords(s) }
    return null
}

function same(a, b) {
    if (!a || !b) return false
    if (a.key === b.key) return true
    // A file moved or renamed by the download's last step: its name.
    return !!a.path && !!b.path && _base(a.path) === _base(b.path)
}

function mentions(text, cue) {
    if (!cue) return false
    var t = _fold(text)
    if (!t) return false
    if (cue.path && t.indexOf(_fold(cue.path)) >= 0) return true
    var words = cue.words || []
    for (var i = 0; i < words.length; i++) {
        var w = _fold(words[i])
        if (w.length < 4) continue
        var at = t.indexOf(w)
        while (at >= 0) {
            var before = at === 0 ? " " : t.charAt(at - 1)
            var after = at + w.length >= t.length ? " " : t.charAt(at + w.length)
            // Whole words (a file name may end the sentence: "report.pdf.").
            if (!/[a-z0-9]/.test(before) && !/[a-z0-9]/.test(after)) return true
            at = t.indexOf(w, at + 1)
        }
    }
    return false
}
