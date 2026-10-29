.pragma library

// Was it said TO Muse? The plain-code part of Full AI mode's always-open
// microphone (services/Addressee.qml): well under a millisecond, no model,
// in four languages. decide(text, ctx) gives {verdict, order, why}:
//   verdict "yes": for Muse, `order` is what to do (its name taken out);
//           "no":  not for Muse (someone else, a call, a filler): nothing sent;
//           "ask": plain code can't tell: the small model decides (smart).
// ctx: {mode "smart"|"name"|"all", now, pending (a step waits for an OK),
// asking (Muse asked a question), speaking (Muse talks right now), busy (it
// works on an order), halt (a stop word: Voice._halt), spokeAt (when Muse
// last said or wrote something), addressedAt (when the user last spoke to
// it), inCall}.
// The rules, in order: "not you" and "I'm talking to you" (ctx.overheardAt:
// when words were last let go); Muse's name; another person's name or another
// assistant's; an answer to the step waiting for an OK or to Muse's own
// question, a stop word; a call in progress; name mode stops there; Muse
// talking now or a moment ago, a back-and-forth going on (a reply-like
// sentence only); fillers; then the model.
// QML's JS engine: no ES2019+, no \p{L} (Latin ranges spelled out).

function wordSet(s) {
    var o = {}
    s.split(" ").forEach(function (w) { if (w) o[w] = true })
    return o
}

// Muse as speech recognisers write it. The strong forms count wherever a
// name is called (the start, the end, after "hey"); the weak ones are real
// words ("music", "news"): Muse only right after a greeting ("hey music").
var STRONG = "muse|muze|mews|mewse|muuse|meuse|myuse"
var WEAK = "music|moose|news|mues|mus|muz|mooz|mewz|myoos"
// What calls someone ("hey", "ok", "dis", "hallo", "ê", "này"…) and the
// polite openings.
var GREET = "hey|hei|hi|hello|ok|okay|yo|oh|oi|excuse me|please|dis|dites|h[ée]|eh|salut|coucou|bonjour|bonsoir|"
    + "all[oô]|s'il te pla[iî]t|s'il vous pla[iî]t|stp|pardon|hallo|na|bitte|servus|moin|ê|này|nay|chào|chao|alo|làm ơn"
var greetOnly = new RegExp("^(?:" + GREET + ")$", "i")
// Other assistants: their wake words are for them.
var OTHERS = "google|siri|alexa|cortana|bixby|gemini|claude|chatgpt|copilot"
// People called by what they are to the user (kin, pet names, a group).
var KIN = "mom|mum|mommy|mummy|mama|mother|dad|daddy|papa|father|honey|babe|baby|sweetie|sweetheart|darling|"
    + "guys|buddy|dude|bro|sis|grandma|grandpa|maman|chéri|chérie|mon cœur|mon coeur|mon chou|les gars|les enfants|"
    + "mamie|papi|mamy|papy|mutti|mami|vati|schatz|liebling|leute|kinder|oma|opa|"
    + "mẹ|má|bố|ba|anh|em|chị|con|ông|bà|cô|chú|bác|cậu|dì"
// Vietnamese kin words are pronouns too ("em" is also "I", "anh" "you"):
// another person only when called ("mẹ ơi", "anh,").
var KIN_VI = /^(mẹ|má|bố|ba|anh|em|chị|con|ông|bà|cô|chú|bác|cậu|dì)$/i
// Words that start (or end) a sentence before a comma without being
// anyone's name ("So, …", "Alors, …", "Also, …", "…, please").
var NOT_NAMES = wordSet(
    "ok okay so well yes yeah yep no nope now then and but also oh ah hmm um uh please thanks thank sorry wait stop "
    + "listen look alright right sure hey hi hello actually anyway anyways first next finally today tomorrow tonight "
    + "yesterday maybe honestly seriously great cool nice good fine perfect done basically like oops wow damn "
    + "open close play put set turn show call send add remove start pause find search tell give make go "
    + "alors bon oui non ouais donc enfin attends attendez écoute ecoute écoutez dis merci pardon bref voilà voila bah ben "
    + "euh d'accord puis ensuite après apres aujourd'hui demain hier ouf super parfait génial genial bien mais et "
    + "ja nein gut dann ach bitte danke moment warte hör nun jetzt übrigens heute morgen gestern genau "
    + "klar prima toll schön schon aber und oder "
    + "vâng dạ ừ ừm thôi rồi à ờ này thế vậy xong được hôm ngày trời ối")
// Fillers only ("hmm", "euh", "äh", "ờ"): nothing for anyone.
var FILLERS = wordSet("um umm uh uhh uhm hmm hmmm hm mm mmm mhm ah oh eh er erm huh ha haha hah euh bah ben hein pff "
    + "pfff bof äh ähm tja ờ ừ ừm à ơ ồ hả")
function notAName(w) {
    var l = String(w || "").toLowerCase()
    return l.length < 2 || !!NOT_NAMES[l] || !!FILLERS[l] || greetOnly.test(l) || strongOnly.test(l)
}

var PUNCT = "[\\s,.!?:;…—–-]"
var OI = "(?:\\s+(?:ơi|oi))?"
var startName = new RegExp("^\\s*(?:(?:" + GREET + ")" + PUNCT + "+)*(?:" + STRONG + ")" + OI + "(?=" + PUNCT + "|$)(" + PUNCT + "*)", "i")
var startWeak = new RegExp("^\\s*(?:(?:" + GREET + ")" + PUNCT + "+)+(?:" + WEAK + ")" + OI + "(?=" + PUNCT + "|$)(" + PUNCT + "*)", "i")
var startOi = new RegExp("^\\s*(?:ơi|oi)\\s+(?:" + STRONG + "|" + WEAK + ")(?=" + PUNCT + "|$)(" + PUNCT + "*)", "i")
// "Muse is slow today", "Muse a planté": about Muse, not to it.
var aboutIt = /^(is|was|has|had|isn't|wasn't|doesn't|does|did|didn't|says|said|thinks|est|était|a|avait|ne|n'est|ist|war|hat|hatte|sagt|là|thì|đã|bị|nói)\b/i
// The end: "…, Muse?", "… Muse ơi", "open firefox Muse"; not "the muse",
// "ask Muse", "demande à Muse" (about it).
var endName = new RegExp("(^|[\\s,]+)(?:(?:" + GREET + ")\\s+)?(?:" + STRONG + ")" + OI + "\\s*([.!?…]*)\\s*$", "i")
var NOT_CALL_BEFORE = /(^|\s)(the|a|an|my|your|his|her|our|their|this|that|la|le|les|ma|ta|sa|une|un|cette|ce|mon|ton|son|die|der|das|den|dem|meine|deine|seine|ihre|ein|eine|einer|ask|asked|tell|told|with|to|for|from|about|than|à|avec|pour|de|demande|demander|dis|que|frag|fragen|mit|für|an|von|als|hỏi|với|cho|bảo|nói|của|cái)\s*$/i
var midName = new RegExp(",\\s*(?:(?:" + GREET + ")\\s+)?(?:" + STRONG + ")\\s*,\\s*", "i")
var strongOnly = new RegExp("^(?:" + STRONG + "|" + WEAK + ")$", "i")
var others = new RegExp("^\\s*(?:(?:" + GREET + ")" + PUNCT + "+)*(?:" + OTHERS + ")(?=" + PUNCT + "|$)", "i")
var kinStart = new RegExp("^\\s*(?:(?:" + GREET + ")\\s+)?(" + KIN + ")\\s*(,|!|\\?|\\s+(?:ơi|oi)(?=" + PUNCT + "|$))", "i")
var kinGreet = new RegExp("^\\s*(?:" + GREET + ")\\s+(" + KIN + ")(?=" + PUNCT + "|$)", "i")
var kinEnd = new RegExp("(?:,\\s*(" + KIN + ")|\\s(" + KIN + ")\\s+(?:ơi|oi))\\s*[.!?…]*\\s*$", "i")
var WORD = "[A-Za-zÀ-ÖØ-öø-ɏḀ-ỿ'’-]+"
var CAP = "[A-ZÀ-ÖØ-ÞĐḀ-Ỹ]"
var nameComma = new RegExp("^\\s*(" + CAP + WORD + ")\\s*,\\s*\\S")
// "hey Paul", "salut Paul, …", "hey, Paul, …" (not "hey can you…").
var greetName = new RegExp("^\\s*(?:" + GREET + ")\\s+(" + WORD + ")(\\s*,)?", "i")
var greetCommaName = new RegExp("^\\s*(?:" + GREET + ")\\s*,\\s*(" + CAP + WORD + ")\\s*,")
var nameEnd = new RegExp(",\\s*(" + CAP + WORD + ")\\s*[.!?…]*\\s*$")
var nameOi = new RegExp("(?:^|\\s)(" + WORD + ")\\s+(?:ơi|oi)(?=" + PUNCT + "|$)", "i")

// The user correcting it: "not you", "I wasn't talking to you", "c'est pas
// pour toi", "nicht mit dir", "không phải nói với bạn": the words before
// weren't for it (Addressee.qml stops what it started on them).
var NOT_YOU = new RegExp("(?:^|[\\s,.!?])(?:" + [
    "i(?:'m| am| was)? not (?:talking|speaking) to (?:you|muse)",
    "i wasn'?t (?:talking|speaking) to (?:you|muse)",
    "(?:that|this|it) (?:wasn'?t|was not|isn'?t|is not|'s not) (?:meant )?(?:for|to) (?:you|muse)",
    "not (?:meant )?(?:for |to )?(?:you|muse)(?=[\\s,.!?]|$)",
    "pas (?:à |a |pour )?toi(?=[\\s,.!?]|$)",
    "je (?:ne )?te (?:parle|parlais) pas",
    "je (?:ne )?(?:parle|parlais) pas (?:à|a) toi",
    "(?:c'|ce n')?(?:é|e)tait pas (?:pour|à|a) toi",
    "(?:c'|ce n')?est pas (?:pour|à|a) toi",
    "nicht (?:du|dich|dir|mit dir|für dich|zu dir)(?=[\\s,.!?]|$)",
    "(?:ich )?(?:rede|spreche?|redete|sprach) nicht (?:mit|zu) dir",
    "das (?:war|ist) nicht für dich",
    "(?:ich )?meinte? nicht dich",
    "du bist nicht gemeint",
    "không phải (?:nói )?(?:với |cho )?(?:bạn|mày|em|muse)",
    "(?:không|đâu có) (?:có )?nói với (?:bạn|mày|em|muse)"
].join("|") + ")", "i")
// Claiming it: "yes I'm talking to you", "that was for you", "c'est à toi
// que je parle", "ich rede mit dir", "tôi đang nói với bạn".
var CLAIM = new RegExp("(?:^|[\\s,.!?])(?:" + [
    "(?:i'?m|i am|i was) (?:talking|speaking) to you",
    "(?:that|this|it) (?:was|is|'s) (?:meant )?(?:for|to) you",
    "i (?:mean|meant) you",
    "i'?m asking you",
    "(?:it'?s|it is) (?:you|for you)(?=[\\s,.!?]|$)",
    "(?:yes|yeah|yep),? (?:you|for you|to you)(?=[\\s,.!?]|$)",
    "je (?:te )?(?:parle|parlais) (?:à|a) toi",
    "je te (?:parle|parlais|cause|demande)",
    "je m'adresse (?:à|a) toi",
    "c'(?:é|e)tait (?:pour|à|a) toi",
    "c'est (?:pour|à|a) toi(?: que je (?:parle|parlais))?",
    "c'est toi que je (?:parle|parlais|veux|demande)",
    "oui,? (?:toi|à toi|a toi|pour toi)(?=[\\s,.!?]|$)",
    "(?:ich )?(?:rede|spreche?|redete|sprach) (?:mit|zu) dir",
    "das (?:war|ist) für dich",
    "(?:du bist|dich) gemeint",
    "ich meinte? dich",
    "ich frage? dich",
    "ja,? (?:du|dich|dir)(?=[\\s,.!?]|$)",
    "(?:tôi |em |anh |mình )?(?:đang )?nói với (?:bạn|mày|em|anh|muse)",
    "hỏi (?:bạn|mày|em) (?:đó|đấy)",
    "(?:là )?(?:cho|nói với) bạn (?:đó|đấy)"
].join("|") + ")([\\s,.!?:;…—–-]*)", "i")
// What may come with a claim without being an order.
var CLAIM_FILL = wordSet("yes yeah yep yup really now here right oui ouais si vraiment là la bien ja doch wirklich "
    + "jetzt hier vâng dạ đúng ừ đó đấy mà thật really i do am talking to you")
function notYou(text) {
    var t = String(text || "").toLowerCase()
    return words(t).length <= 12 && NOT_YOU.test(t)
}
// {order} what was said with the claim (its name and the claim taken
// out; "" for a claim alone), or null.
function claimOf(text) {
    var t = String(text || "").toLowerCase()
    var m = t.match(CLAIM)
    if (!m) return null
    var nameRe = "(?:^|[\\s,.!?])(?:(?:" + GREET + ")\\s+)?(?:" + STRONG + "|" + WEAK + ")" + OI + "(?=[\\s,.!?]|$)"
    var hasName = new RegExp(nameRe, "i").test(String(text))
    var named = new RegExp(nameRe, "gi")
    var before = String(text).slice(0, m.index)
    var after = String(text).slice(m.index + m[0].length)
    var rest = (before + " " + after).replace(named, " ")
    var left = words(rest).filter(function (w) { return !CLAIM_FILL[w] && !FILLERS[w] && !greetOnly.test(w) })
    return { order: left.length === 0 ? "" : after.replace(named, " ").replace(/^[\s,.!?:;…—–-]+/, "").trim(),
             cut: /[,.!?:;…—–-]/.test(m[1] || ""), named: hasName }
}
// A reply that goes on with it ("and the next one", "louder", "yes"): short,
// or starting like an order or a follow-up; else the model judges it.
var FOLLOW = /^(?:and|also|then|now|actually|no|yes|ok|okay|et|puis|aussi|non|oui|und|auch|dann|nein|ja|còn|và|thế|rồi|không|vâng|open|close|play|pause|stop|show|put|set|turn|make|add|remove|start|find|search|tell|give|go|call|send|read|skip|mute|ouvre|ferme|joue|mets|montre|lance|arrête|arrete|ajoute|cherche|dis|envoie|baisse|monte|passe|öffne|schließ|schliess|spiel|zeig|mach|stell|such|sag|schick|leiser|lauter|mở|đóng|phát|tắt|bật|tìm|gửi|cho)\b/i
function replyLike(text) {
    var n = words(text).length
    return n <= 5 || FOLLOW.test(String(text || "").trim())
}

function words(text) {
    return String(text || "").toLowerCase().replace(/[,.!?:;…"“”«»()\-–—]+/g, " ").trim().split(/\s+/)
        .filter(function (w) { return w.length > 0 })
}

// Muse's name where a name is called: {order} with it taken out, or null.
function calledByName(text) {
    var t = String(text || "").trim()
    var m = t.match(startName) || t.match(startWeak) || t.match(startOi)
    if (m) {
        var rest = t.slice(m[0].length).trim()
        // No pause after the name and a verb about it: a mention.
        if (!/[,.!?:;…—–-]/.test(m[1]) && aboutIt.test(rest)) return null
        return { order: rest }
    }
    m = t.match(endName)
    if (m) {
        var before = t.slice(0, m.index + m[1].length)
        if (!(m[1].indexOf(",") < 0 && NOT_CALL_BEFORE.test(before)))
            return { order: (before.replace(/[\s,]+$/, "") + (m[2] || "")).trim() }
    }
    m = t.match(midName)
    if (m) return { order: (t.slice(0, m.index) + ", " + t.slice(m.index + m[0].length)).replace(/^[\s,]+/, "").trim() }
    return null
}

// Someone else called: "Paul, …", "hey Paul", "Maman, …", "…, Paul?",
// "mẹ ơi", "ok Google". Who, else "".
function otherPerson(text) {
    var t = String(text || "").trim()
    var m = t.match(others)
    if (m) return m[0].trim()
    m = t.match(kinStart)
    // A Vietnamese kin word first is a pronoun ("em mở…"): only with "ơi"
    // or a comma.
    if (m && (!KIN_VI.test(m[1]) || /,|ơi|oi/i.test(m[2]))) return m[1]
    m = t.match(kinGreet)
    if (m && !KIN_VI.test(m[1])) return m[1]
    m = t.match(nameComma)
    if (m && !notAName(m[1])) return m[1]
    m = t.match(greetCommaName)
    if (m && !notAName(m[1])) return m[1]
    m = t.match(greetName)
    // Written as a name, or followed by a comma ("hey paul, …").
    if (m && !notAName(m[1]) && (/^[A-ZÀ-ÖØ-ÞĐḀ-Ỹ]/.test(m[1]) || m[2])) return m[1]
    m = t.match(kinEnd)
    if (m) return m[1] || m[2]
    m = t.match(nameEnd)
    if (m && m[1].length >= 3 && !notAName(m[1])) return m[1]
    m = t.match(nameOi)
    if (m && !notAName(m[1])) return m[1]
    return ""
}

function onlyFillers(text) {
    var w = words(text)
    return w.length > 0 && w.every(function (x) { return !!FILLERS[x] })
}

function decide(text, ctx) {
    var c = ctx || {}
    var t = String(text || "").trim()
    var mode = c.mode === "name" || c.mode === "all" ? c.mode : "smart"
    if (t.length === 0) return { verdict: "no", order: "", why: "empty" }
    // Everything heard is for it, but "not you" (the user correcting it).
    if (mode === "all") return notYou(t) ? { verdict: "no", order: "", why: "not-you" } : { verdict: "yes", order: t, why: "all" }
    var now = c.now || Date.now()
    // 0. The user correcting it ("not you"), or claiming it ("yes, I'm
    // talking to you"): before its name, which they often carry. A claim
    // alone takes back the words it let go (Addressee.qml); named, it
    // always answers; unnamed, only with something let go lately.
    if (notYou(t)) return { verdict: "no", order: "", why: "not-you" }
    var claim = claimOf(t)
    if (claim) {
        var recent = (c.overheardAt || 0) > 0 && now - c.overheardAt <= 90000
        if (!claim.order && (claim.named || recent)) return { verdict: "claim", order: "", why: "claim" }
        if (claim.order && (claim.named || claim.cut)) return { verdict: "yes", order: claim.order, why: "claim-order" }
    }
    // 1. Its name: for it, whatever else goes on (taken out of the order;
    // the name alone calls it).
    var named = calledByName(t)
    if (named) return { verdict: "yes", order: named.order, why: named.order ? "name" : "name-only" }
    // 2. Someone else called, or another assistant's wake word.
    if (otherPerson(t)) return { verdict: "no", order: "", why: "other-person" }
    var n = words(t).length
    // 3. An answer to it: the step waiting for an OK, its own question; in
    // a call only a short one ("yes", "no, don't"), not the call's talk.
    if (c.pending && (!c.inCall || n <= 4)) return { verdict: "yes", order: t, why: "approval" }
    if (c.asking && (!c.inCall || n <= 6)) return { verdict: "yes", order: t, why: "asked" }
    // "Stop" / "wait" while it talks, or while it works on an order (not in
    // a call: "wait" there is for the others).
    if (c.halt && (c.speaking || (c.busy && !c.inCall))) return { verdict: "yes", order: t, why: "stop" }
    // 4. A call: the user talks to the others (it, by name only).
    if (c.inCall) return { verdict: "no", order: "", why: "call" }
    if (mode === "name") return { verdict: "no", order: "", why: "not-named" }
    if (onlyFillers(t)) return { verdict: "no", order: "", why: "filler" }
    // 5. Speaking up while it talks, or right after: a reply, when it reads
    // like one (short, an order, a follow-up); a longer sentence may be
    // for someone in the room: the model judges it.
    var reply = replyLike(t)
    if (c.speaking && reply) return { verdict: "yes", order: t, why: "speaking" }
    var spoke = c.spokeAt || 0, addressed = c.addressedAt || 0
    if (reply && spoke > 0 && now - spoke <= 8000) return { verdict: "yes", order: t, why: "just-spoke" }
    // A back-and-forth: the user spoke to it lately and it answered.
    if (reply && addressed > 0 && now - addressed <= 25000 && spoke >= addressed)
        return { verdict: "yes", order: t, why: "conversation" }
    // 6. The model decides.
    return { verdict: "ask", order: t, why: "unsure" }
}
