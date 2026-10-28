pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import QtQuick

/**
 * What is asked in Muse's bubble that is a plain command, done at once in
 * plain code instead of a Muse run (zero tokens, no model): the music
 * (play, pause, next, previous), the volume (a level, up, down, mute), the
 * brightness, an app (open, close, switch to it), a workspace (one by its
 * number, the next, the previous; the window moved to one), dark or light
 * mode, Do Not Disturb, night light, a screenshot, locking the screen, a
 * timer or a pomodoro, a saved window layout, a task added, the shell's
 * settings. In English, French, German and Vietnamese (`_english` turns the
 * three others into the English commands first).
 *
 * Strict patterns only: anything else, or anything unsure (an app it can't
 * name for sure, two windows of the app to close), goes to Muse as before.
 * In a conversation (`inConversation`) only commands that name what they
 * act on: "pause the music", "volume 30", "open Firefox", "workspace 2" —
 * never "pause", "next", "louder" (the next result? the video they were
 * talking about?) nor anything with "it", "that", "this one" ("pause it",
 * "open the file I just downloaded" are Muse's).
 *
 * `run(text, inConversation)`: done, {text: what it did, undo: a function
 * when it can be undone} — else null.
 *
 * `video(text, inConversation, done)`: a film or an episode from Jellyfin
 * ("play edgerunners season 2 episode 1", "regarde Dune", "S2E1"), found
 * and played by `jellyfin-mcp play-query` (one search, the episodes, the
 * player: about a second, no model), only once jellyfin-mcp is set up and
 * on for Muse. Never the music: a request naming music, a song, an album… is
 * left alone, and without a season or an episode only a strong title match
 * plays (--strict). Asynchronous: true when it took the request, `done(r)`
 * then gets play-query's answer ({ok, matched, said}; not matched: Muse's).
 */
Singleton {
    id: root

    // Lowercase, no politeness around it, no final punctuation.
    function _clean(text) {
        return String(text ?? "").trim().toLowerCase()
            .replace(/^(hey |ok |okay )?(muse[,:]?\s+)?/, "")
            .replace(/^(please |pls |can you |could you |would you |will you |s'il te pla[iî]t,? |s'il vous pla[iî]t,? |peux-tu |tu peux |pourrais-tu |bitte |kannst du |k[oö]nntest du |l[aà]m [oơ]n |h[aã]y |b[aạ]n c[oó] th[eể] |gi[uú]p (m[iì]nh|t[oô]i|em) )+/, "")
            .replace(/([,\s]+(please|pls|thanks|thank you|s'il te pla[iî]t|s'il vous pla[iî]t|stp|svp|merci|bitte|danke|nh[eé]|nha|gi[uú]p (m[iì]nh|t[oô]i|em)|[dđ]i))+$/, "")
            .replace(/[.!?\s]+$/, "")
            .replace(/\s+/g, " ")
            .trim()
    }

    // French, German and Vietnamese commands as the English ones (the same
    // patterns then do them). Specific phrases before the generic open /
    // close / switch-to ones.
    readonly property var _phrases: [
        // ── French ──
        [/^(?:mets?|met) (?:la )?(?:musique|chanson|lecture) en pause$|^(?:mets|fais) pause(?: (?:la|à la) musique)?$|^pause (?:la|sur la) musique$/, "pause the music"],
        [/^(?:mets? )?en pause$/, "pause"],
        [/^(?:reprends?|relance|remets|joue|lance|mets) (?:la )?(?:musique|lecture|chanson)$/, "play the music"],
        [/^(?:passe (?:à )?la |mets la )?(?:chanson|musique|piste|morceau|titre) suivante?$|^(?:chanson|morceau|piste|titre) d'apr[eè]s$/, "next song"],
        [/^(?:remets la |reviens à la )?(?:chanson|musique|piste|morceau|titre) pr[eé]c[eé]dente?$/, "previous song"],
        [/^suivante?$/, "next"],
        [/^pr[eé]c[eé]dente?$/, "previous"],
        [/^(?:mets |r[eè]gle |monte |baisse )?(?:le )?(?:volume|son) (?:à |a |sur )?(\d{1,3}) ?(?:%|pour ?cent)?$/, "volume $1"],
        [/^(?:monte|augmente) (?:le )?(?:son|volume)$/, "volume up"],
        [/^(?:baisse|diminue) (?:le )?(?:son|volume)$/, "volume down"],
        [/^plus fort$/, "louder"],
        [/^moins fort$/, "quieter"],
        [/^(?:coupe|d[eé]sactive|enl[eè]ve) (?:le )?son$|^mets (?:le son )?en sourdine$/, "mute the sound"],
        [/^sourdine$/, "mute"],
        [/^(?:remets|r[eé]active|active|rallume) (?:le )?son$/, "unmute the sound"],
        [/^(?:augmente|monte) (?:la )?luminosit[eé]$/, "brightness up"],
        [/^(?:baisse|diminue) (?:la )?luminosit[eé]$/, "brightness down"],
        [/^(?:passe |mets |active )?(?:le |en )?(?:mode|th[eè]me) sombre$/, "dark mode"],
        [/^(?:passe |mets |active )?(?:le |en )?(?:mode|th[eè]me) clair$/, "light mode"],
        [/^(?:active |mets |allume )?(?:le )?(?:mode )?ne pas d[eé]ranger$/, "turn on dnd"],
        [/^(?:d[eé]sactive|enl[eè]ve|coupe|arr[eê]te) (?:le )?(?:mode )?ne pas d[eé]ranger$/, "turn off dnd"],
        [/^(?:active |allume |mets )?(?:la |le )?(?:lumi[eè]re nocturne|veilleuse|mode nuit|filtre (?:de )?lumi[eè]re bleue|[eé]clairage nocturne)$/, "night light on"],
        [/^(?:d[eé]sactive|[eé]teins|coupe|enl[eè]ve) (?:la |le )?(?:lumi[eè]re nocturne|veilleuse|mode nuit|filtre (?:de )?lumi[eè]re bleue|[eé]clairage nocturne)$/, "night light off"],
        [/^(?:fais |prends )?(?:une )?capture(?: d'[eé]cran)?$/, "take a screenshot"],
        [/^verrouille (?:l'[eé]cran|la session|l'ordinateur|le pc|l'ordi)$/, "lock the screen"],
        [/^verrouille$/, "lock"],
        [/^(?:lance |d[eé]marre )?(?:un )?(?:minuteur|minuterie|timer|compte [aà] rebours) (?:de )?(\d{1,3}) ?(?:min|minutes?)$/, "timer $1 minutes"],
        [/^(?:ouvre |affiche )?(?:les )?(?:param[eè]tres|r[eé]glages)(?: du shell)?$/, "settings"],
        [/^(?:(?:va|passe|bascule) (?:sur|au|à|vers) (?:le |l')?)?(?:bureau|espace(?: de travail)?) (?:num[eé]ro )?(\d{1,2})$/, "workspace $1"],
        [/^(?:(?:va|passe) (?:sur|au|à) (?:le |l')?)?(?:bureau|espace(?: de travail)?) suivant$/, "next workspace"],
        [/^(?:(?:va|passe) (?:sur|au|à) (?:le |l')?)?(?:bureau|espace(?: de travail)?) pr[eé]c[eé]dent$/, "previous workspace"],
        [/^(?:d[eé]place|mets|envoie|bouge) (?:la |cette )?fen[eê]tre (?:sur|vers|dans|au|à) (?:le |l')?(?:bureau |espace (?:de travail )?)?(\d{1,2})$/, "move window to workspace $1"],
        [/^ferme (?:la |cette )?fen[eê]tre$/, "close the window"],
        [/^(?:ouvre|lance|d[eé]marre) (?:l'|le |la |les |mon |ma )?(.+)$/, "open $1"],
        [/^(?:ferme|quitte) (?:l'|le |la |les |mon |ma )?(.+)$/, "close $1"],
        [/^(?:va sur|passe (?:à|sur)|bascule (?:sur|vers)|affiche|montre(?:-moi)?) (?:l'|le |la |mon |ma )?(.+)$/, "switch to $1"],
        // ── German ──
        [/^(?:pausiere|pausier|halte|stoppe|stopp) (?:die )?musik(?: an)?$|^(?:die )?musik (?:pausieren|anhalten|stoppen)$/, "pause the music"],
        [/^pausieren$|^anhalten$/, "pause"],
        [/^(?:spiel|spiele) (?:die )?musik(?: ab| weiter)?$|^(?:die )?musik (?:abspielen|fortsetzen|weiterspielen)$/, "play the music"],
        [/^(?:abspielen|fortsetzen|weiterspielen)$/, "play"],
        [/^(?:n[aä]chstes|n[aä]chster|n[aä]chste) (?:lied|titel|song|track)$/, "next song"],
        [/^(?:vorheriges|vorheriger|vorherige|letztes|letzter|letzte) (?:lied|titel|song|track)$/, "previous song"],
        [/^(?:stell |setz |mach )?(?:die )?lautst[aä]rke (?:auf )?(\d{1,3}) ?(?:%|prozent)?$/, "volume $1"],
        [/^(?:mach )?(?:den )?(?:ton|sound) lauter$|^lautst[aä]rke (?:hoch|erh[oö]hen|rauf)$/, "volume up"],
        [/^(?:mach )?(?:den )?(?:ton|sound) leiser$|^lautst[aä]rke (?:runter|senken|verringern)$/, "volume down"],
        [/^lauter$/, "louder"],
        [/^leiser$/, "quieter"],
        [/^(?:schalte )?(?:den )?(?:ton|sound) (?:aus|stumm)$|^(?:ton|sound) stummschalten$/, "mute the sound"],
        [/^stumm(?:schalten)?$/, "mute"],
        [/^(?:schalte )?(?:den )?(?:ton|sound) (?:wieder )?an$/, "unmute the sound"],
        [/^(?:mach )?(?:den )?bildschirm heller$|^helligkeit (?:hoch|erh[oö]hen)$/, "brightness up"],
        [/^(?:mach )?(?:den )?bildschirm dunkler$|^helligkeit (?:runter|senken)$/, "brightness down"],
        [/^(?:dunkler|dunkles) (?:modus|design|thema)$|^dunkelmodus$/, "dark mode"],
        [/^(?:heller|helles) (?:modus|design|thema)$|^hellmodus$/, "light mode"],
        [/^(?:schalte )?nicht st[oö]ren(?: an| ein)?$/, "turn on dnd"],
        [/^(?:schalte )?nicht st[oö]ren aus$/, "turn off dnd"],
        [/^(?:schalte )?(?:das )?nachtlicht(?: an| ein)?$/, "night light on"],
        [/^(?:schalte )?(?:das )?nachtlicht aus$/, "night light off"],
        [/^(?:mach |mache |nimm )?(?:ein(?:en)? )?(?:bildschirmfoto|screenshot)$/, "take a screenshot"],
        [/^(?:bildschirm|computer|sitzung|pc) sperren$|^sperre (?:den bildschirm|den computer|die sitzung)$/, "lock the screen"],
        [/^sperren$/, "lock"],
        [/^(?:starte |stell )?(?:einen )?(?:timer|countdown) (?:f[uü]r |auf )?(\d{1,3}) ?(?:min|minuten?)$/, "timer $1 minutes"],
        [/^(?:[oö]ffne )?(?:die )?einstellungen$/, "settings"],
        [/^(?:(?:wechsle|wechsel|geh|gehe) (?:zu|zum|auf|zur) )?(?:arbeitsbereich|arbeitsfl[aä]che|desktop) (?:nummer )?(\d{1,2})$/, "workspace $1"],
        [/^(?:n[aä]chster|n[aä]chste|n[aä]chstes) (?:arbeitsbereich|arbeitsfl[aä]che|desktop)$/, "next workspace"],
        [/^(?:vorheriger|vorherige|vorheriges|letzter) (?:arbeitsbereich|arbeitsfl[aä]che|desktop)$/, "previous workspace"],
        [/^(?:verschiebe|schiebe|bewege) (?:das |dieses )?fenster (?:auf|zu|nach|in|zum) (?:den )?(?:arbeitsbereich |arbeitsfl[aä]che |desktop )?(\d{1,2})$/, "move window to workspace $1"],
        [/^(?:schlie(?:ß|ss)e?) (?:das |dieses )?fenster$/, "close the window"],
        [/^(?:[oö]ffne|starte) (?:das |die |den |mein |meine )?(.+)$|^(.+) (?:[oö]ffnen|starten)$/, "open $1$2"],
        [/^(?:schlie(?:ß|ss)e?|beende) (?:das |die |den |mein |meine )?(.+)$|^(.+) (?:schlie(?:ß|ss)en|beenden)$/, "close $1$2"],
        [/^(?:wechsle|wechsel|geh|gehe) (?:zu|zum|zur) (?:dem |der )?(.+)$|^zeig(?:e)? (?:mir )?(?:das |die |den )?(.+)$/, "switch to $1$2"],
        // ── Vietnamese ──
        [/^(?:t[aạ]m d[uừ]ng|d[uừ]ng) (?:nh[aạ]c|b[aà]i h[aá]t|b[aà]i)$/, "pause the music"],
        [/^t[aạ]m d[uừ]ng$/, "pause"],
        [/^(?:ph[aá]t|b[aậ]t|m[oở]) (?:ti[eế]p )?(?:nh[aạ]c|b[aà]i h[aá]t)$|^ti[eế]p t[uụ]c ph[aá]t nh[aạ]c$/, "play the music"],
        [/^ph[aá]t ti[eế]p$|^ti[eế]p t[uụ]c ph[aá]t$/, "play"],
        [/^(?:chuy[eể]n )?b[aà]i (?:ti[eế]p theo|k[eế] ti[eế]p|ti[eế]p|sau)$|^chuy[eể]n b[aà]i$/, "next song"],
        [/^(?:quay l[aạ]i )?b[aà]i (?:tr[uư][oớ]c|tr[uư][oớ]c [dđ][oó])$/, "previous song"],
        [/^(?:ch[iỉ]nh |[dđ][aặ]t |cho )?[aâ]m l[uư][oợ]ng (?:l[eê]n |xu[oố]ng |v[eề] )?(?:m[uứ]c )?(\d{1,3}) ?%?$/, "volume $1"],
        [/^t[aă]ng [aâ]m l[uư][oợ]ng$|^v[aặ]n to (?:l[eê]n)?$|^to l[eê]n$/, "volume up"],
        [/^gi[aả]m [aâ]m l[uư][oợ]ng$|^v[aặ]n nh[oỏ] (?:l[aạ]i)?$|^nh[oỏ] l[aạ]i$/, "volume down"],
        [/^t[aắ]t (?:ti[eế]ng|[aâ]m thanh)$/, "mute the sound"],
        [/^b[aậ]t (?:ti[eế]ng|[aâ]m thanh)$/, "unmute the sound"],
        [/^t[aă]ng [dđ][oộ] s[aá]ng$/, "brightness up"],
        [/^gi[aả]m [dđ][oộ] s[aá]ng$/, "brightness down"],
        [/^(?:b[aậ]t )?ch[eế] [dđ][oộ] t[oố]i$|^giao di[eệ]n t[oố]i$/, "dark mode"],
        [/^(?:b[aậ]t )?ch[eế] [dđ][oộ] s[aá]ng$|^giao di[eệ]n s[aá]ng$/, "light mode"],
        [/^(?:b[aậ]t )?(?:ch[eế] [dđ][oộ] )?kh[oô]ng l[aà]m phi[eề]n$/, "turn on dnd"],
        [/^t[aắ]t (?:ch[eế] [dđ][oộ] )?kh[oô]ng l[aà]m phi[eề]n$/, "turn off dnd"],
        [/^(?:b[aậ]t )?(?:[dđ][eè]n ng[uủ]|[aá]nh s[aá]ng ban [dđ][eê]m|ch[eế] [dđ][oộ] ban [dđ][eê]m)$/, "night light on"],
        [/^t[aắ]t (?:[dđ][eè]n ng[uủ]|[aá]nh s[aá]ng ban [dđ][eê]m|ch[eế] [dđ][oộ] ban [dđ][eê]m)$/, "night light off"],
        [/^ch[uụ]p (?:[aả]nh )?m[aà]n h[iì]nh$/, "take a screenshot"],
        [/^kh[oó]a (?:m[aà]n h[iì]nh|m[aá]y)$|^kho[aá] (?:m[aà]n h[iì]nh|m[aá]y)$/, "lock the screen"],
        [/^(?:h[eẹ]n gi[oờ]|[dđ][eế]m ng[uư][oợ]c) (\d{1,3}) ?ph[uú]t$/, "timer $1 minutes"],
        [/^(?:m[oở] )?c[aà]i [dđ][aặ]t$/, "settings"],
        [/^(?:chuy[eể]n (?:sang|qua|t[oớ]i|[dđ][eế]n) )?(?:kh[oô]ng gian l[aà]m vi[eệ]c|workspace|m[aà]n h[iì]nh [aả]o) (?:s[oố] )?(\d{1,2})$/, "workspace $1"],
        [/^(?:kh[oô]ng gian l[aà]m vi[eệ]c|workspace|m[aà]n h[iì]nh [aả]o) (?:ti[eế]p theo|k[eế] ti[eế]p|sau)$/, "next workspace"],
        [/^(?:kh[oô]ng gian l[aà]m vi[eệ]c|workspace|m[aà]n h[iì]nh [aả]o) tr[uư][oớ]c$/, "previous workspace"],
        [/^(?:di chuy[eể]n|chuy[eể]n|[dđ][uư]a) c[uử]a s[oổ] (?:n[aà]y )?(?:sang|qua|t[oớ]i|[dđ][eế]n|v[aà]o) (?:kh[oô]ng gian l[aà]m vi[eệ]c |workspace |m[aà]n h[iì]nh [aả]o )?(?:s[oố] )?(\d{1,2})$/, "move window to workspace $1"],
        [/^(?:[dđ][oó]ng|t[aắ]t) c[uử]a s[oổ](?: n[aà]y)?$/, "close the window"],
        [/^(?:m[oở]|kh[oở]i [dđ][oộ]ng|ch[aạ]y) (?:[uứ]ng d[uụ]ng )?(.+)$/, "open $1"],
        [/^(?:[dđ][oó]ng|t[aắ]t|tho[aá]t) (?:[uứ]ng d[uụ]ng )?(.+)$/, "close $1"],
        [/^chuy[eể]n (?:sang|qua|t[oớ]i|[dđ][eế]n) (.+)$/, "switch to $1"],
    ]
    function _english(t) {
        for (const [re, to] of root._phrases) {
            const m = re.exec(t);
            if (!m) continue;
            return to.replace(/\$(\d)/g, (_, i) => m[Number(i)] ?? "").trim();
        }
        return t;
    }

    // "it", "that", "this one", "the other one", "there": what it points at
    // is in the conversation, which only Muse reads. ("this song", "this
    // window": the one playing, the one in front.)
    function _deictic(t) {
        const s = t.replace(/\bthis (song|track|music|window|app)\b/g, "the $1");
        return /(?:^|[^\wÀ-ỹ])(it|its|this|that|them|these|those|one|ones|there|here|other|same|again|ça|ca|cela|ceci|celui|celle|ceux|celles|dies|diese|dieses|dieser|nó|này|đó|kia|ấy)(?![\wÀ-ỹ])/.test(s);
    }

    function _done(text, undo) {
        return { text: text, undo: undo ?? null };
    }

    function run(text, inConversation = false) {
        const raw = String(text ?? "").trim();
        // Short and on one line: a command, not a question or a story.
        if (raw.length === 0 || raw.length > 80 || raw.includes("\n")) return null;
        const t = root._english(root._clean(raw));
        if (t.length === 0) return null;
        // In a conversation, nothing pointing back at it.
        if (inConversation && root._deictic(t)) return null;
        // Bare commands ("pause", "next", "louder"): only when nothing is
        // being talked about.
        const bare = !inConversation;
        let m;

        // ── The music ──
        if ((m = /^(play|resume|unpause)( (the )?(music|song))?$/.exec(t)) && (bare || m[2])) {
            const p = MprisController.activePlayer;
            if (!p) return null;
            const was = p.isPlaying;
            if (!p.isPlaying && p.canPlay) p.play();
            return root._done(Translation.tr("Playing."), was ? null : () => { if (p.canPause) p.pause(); });
        }
        if ((m = /^(pause|stop)( (the )?(music|song))?$/.exec(t)) && (bare || m[2])) {
            if (Mpris.players.values.length === 0) return null;
            const playing = Mpris.players.values.filter(p => p.isPlaying && p.canPause);
            for (const player of Mpris.players.values) if (player.canPause) player.pause();
            return root._done(Translation.tr("Paused."), playing.length === 0 ? null
                : () => { for (const p of playing) if (p.canPlay) p.play(); });
        }
        if ((m = /^(next|skip)( (the |this )?(song|track))?$/.exec(t)) && (bare || m[2])) {
            if (!MprisController.canGoNext) return null;
            MprisController.next();
            return root._done(Translation.tr("Next track."), () => { if (MprisController.canGoPrevious) MprisController.previous(); });
        }
        if ((m = /^(previous|prev)( (song|track))?$|^(go back|last) (song|track)$/.exec(t)) && (bare || m[2] || m[4])) {
            if (!MprisController.canGoPrevious) return null;
            MprisController.previous();
            return root._done(Translation.tr("Previous track."), () => { if (MprisController.canGoNext) MprisController.next(); });
        }

        // ── The volume ──
        const volumeUndo = () => {
            const a = Audio.sink?.audio;
            if (!a) return null;
            const volume = a.volume, muted = a.muted;
            return () => { if (Audio.sink?.audio) { Audio.sink.audio.volume = volume; Audio.sink.audio.muted = muted; } };
        };
        if ((m = /^(?:set |turn |put )?(?:the )?(?:volume|sound)(?: to| at)? (\d{1,3}) ?(?:%|percent)?$/.exec(t))) {
            if (!Audio.sink?.audio) return null;
            const undo = volumeUndo();
            const v = Math.min(100, Number(m[1]));
            Audio.sink.audio.muted = false;
            Audio.sink.audio.volume = v / 100;
            return root._done(Translation.tr("Volume %1%.").arg(v), undo);
        }
        if ((m = /^(?:turn )?(?:the )?(?:volume|sound) (up|down)$|^(?:turn it |turn )?(louder|quieter|softer)$/.exec(t)) && (bare || m[1])) {
            if (!Audio.sink?.audio) return null;
            const undo = volumeUndo();
            const up = m[1] === "up" || m[2] === "louder";
            Audio.sink.audio.volume = Math.max(0, Math.min(1, Math.round((Audio.value + (up ? 0.1 : -0.1)) * 100) / 100));
            return root._done(Translation.tr("Volume %1%.").arg(Math.round(Audio.sink.audio.volume * 100)), undo);
        }
        if ((m = /^(mute|unmute)( (the )?(sound|audio|volume|speakers?))?$/.exec(t)) && (bare || m[2])) {
            if (!Audio.sink?.audio) return null;
            const undo = volumeUndo();
            Audio.sink.audio.muted = m[1] === "mute";
            return root._done(m[1] === "mute" ? Translation.tr("Muted.") : Translation.tr("Sound on."), undo);
        }

        // ── The brightness ──
        if ((m = /^(?:turn )?(?:the )?(?:brightness|screen) (up|down)$|^(brighter|darker|dimmer)$/.exec(t)) && (bare || m[1])) {
            const up = m[1] === "up" || m[2] === "brighter";
            if (up) Brightness.increaseBrightness();
            else Brightness.decreaseBrightness();
            return root._done(up ? Translation.tr("Brighter.") : Translation.tr("Dimmer."),
                () => up ? Brightness.decreaseBrightness() : Brightness.increaseBrightness());
        }

        // ── Dark or light ──
        if ((m = /^(?:switch to |turn on |use |go |enable )?(dark|light)( mode| theme)?(?: on)?$|^(?:turn off|disable) (dark|light)( mode| theme)?$/.exec(t))
                && (bare || m[2] || m[4])) {
            const mode = m[1] ?? (m[3] === "dark" ? "light" : "dark");
            const before = (Appearance.m3colors?.darkmode ?? true) ? "dark" : "light";
            Quickshell.execDetached([Directories.wallpaperSwitchScriptPath, "--mode", mode, "--noswitch"]);
            return root._done(mode === "dark" ? Translation.tr("Dark mode on.") : Translation.tr("Light mode on."),
                before === mode ? null : () => Quickshell.execDetached([Directories.wallpaperSwitchScriptPath, "--mode", before, "--noswitch"]));
        }

        // ── Do Not Disturb ──
        if ((m = /^(?:turn |switch )?(on |off )?(?:the )?(?:do not disturb|dnd)( mode)?( on| off)?$/.exec(t))) {
            const on = (m[1] ?? m[3] ?? " on").trim() !== "off";
            const before = Notifications.silent;
            Notifications.silent = on;
            return root._done(on ? Translation.tr("Do Not Disturb on.") : Translation.tr("Do Not Disturb off."),
                before === on ? null : () => Notifications.silent = before);
        }

        // ── Night light ──
        if ((m = /^(?:turn |switch )?(on |off )?(?:the )?(?:night ?light|night mode|blue light filter)( on| off)?$/.exec(t))) {
            const on = (m[1] ?? m[2] ?? " on").trim() !== "off";
            const before = NightLightService.temperatureActive;
            NightLightService.toggleTemperature(on);
            return root._done(on ? Translation.tr("Night light on.") : Translation.tr("Night light off."),
                before === on ? null : () => NightLightService.toggleTemperature(before));
        }

        // ── A screenshot: the screenshot app (Print) ──
        if (/^(?:take |make |grab )?(?:a )?screen ?shot$|^capture the screen$/.test(t)) {
            Quickshell.execDetached(["nixbook-shell", "ipc", "call", "region", "screenshot"]);
            return root._done(Translation.tr("Screenshot: drag over what to capture."));
        }

        // ── Lock ──
        if ((m = /^lock( the| my)?( screen| computer| session| pc| laptop)?$/.exec(t)) && (bare || m[2])) {
            Qt.callLater(() => GlobalStates.screenLocked = true);
            return root._done(Translation.tr("Locking."));
        }

        // ── A timer, a pomodoro ──
        if ((m = /^(?:set |start )?(?:a )?(?:timer|countdown)(?: for| of)? (\d{1,3}) ?(?:m|min|mins|minutes?)$|^(?:set |start )?(?:a )?(\d{1,3}) ?(?:m|min|mins|minutes?) (?:timer|countdown)$/.exec(t))) {
            const minutes = Number(m[1] ?? m[2]);
            if (minutes <= 0) return null;
            TimerService.resetCountdown();
            TimerService.addCountdownMinutes(minutes);
            TimerService.toggleCountdown();
            return root._done(Translation.tr("Timer: %1 min.").arg(minutes), () => TimerService.resetCountdown());
        }
        if (/^(start )?(a )?pomodoro$/.test(t)) {
            if (!TimerService.pomodoroRunning) TimerService.togglePomodoro();
            return root._done(Translation.tr("Pomodoro started."));
        }

        // ── Workspaces ──
        if ((m = /^(?:go to |switch to |focus |open )?(?:the )?workspace (?:number )?(\d{1,2})$|^(?:go to |switch to )?(?:the )?(\d{1,2})(?:st|nd|rd|th) workspace$/.exec(t))) {
            const n = Number(m[1] ?? m[2]);
            if (n < 1) return null;
            Quickshell.execDetached(["niri", "msg", "action", "focus-workspace", String(n)]);
            return root._done(Translation.tr("Workspace %1.").arg(n), root._workspaceBack());
        }
        if ((m = /^(?:go to |switch to )?(?:the )?(next|previous|prev) workspace$|^workspace (up|down|next|previous)$/.exec(t))) {
            const next = ["next", "down"].includes(m[1] ?? m[2]);
            WM.switchWorkspaceRelative(next ? "next" : "previous");
            return root._done(next ? Translation.tr("Next workspace.") : Translation.tr("Previous workspace."), root._workspaceBack());
        }
        if ((m = /^(?:move|send|put) (?:the |this |my )?(?:window|app) to (?:the )?(?:workspace )?(\d{1,2})$/.exec(t))) {
            const n = Number(m[1]);
            const w = (WM.windowList ?? []).find(x => x.focused);
            if (n < 1 || !w) return null;
            const from = WM.workspaceById?.[w.workspaceId]?.idx;
            Quickshell.execDetached(["niri", "msg", "action", "move-window-to-workspace", "--window-id", w.id, String(n)]);
            return root._done(Translation.tr("Window moved to workspace %1.").arg(n),
                from ? () => WM.moveWindowToWorkspace(w.id, from) : null);
        }

        // ── A saved window layout, by its name ──
        if ((m = /^(?:restore |load |switch to |open )?(?:the |my )?(.+?) layout$|^layout (.+)$/.exec(t))) {
            const want = (m[1] ?? m[2]).trim();
            const layout = WindowLayouts.layouts.find(l => String(l.name).toLowerCase() === want);
            if (!layout) return null;
            WindowLayouts.restore(layout.name);
            return root._done(Translation.tr("Restoring the %1 layout.").arg(layout.name));
        }

        // ── A task ──
        if ((m = /^(?:add )?(?:a )?(?:todo|task)[: ]+(.+)$/.exec(t)) || (m = /^add (.+) to (?:my )?(?:todo|tasks|to-?do list)$/.exec(t))) {
            // In the user's own words, not lowercased.
            const words = raw.replace(/[.!]+$/, "");
            const at = words.toLowerCase().indexOf(m[1]);
            const content = (at >= 0 ? words.slice(at, at + m[1].length) : m[1]).trim();
            if (content.length === 0) return null;
            Todo.addTask(content);
            return root._done(Translation.tr("Added to your tasks: %1").arg(content));
        }

        // ── The shell's settings ──
        if (/^(open )?(the )?(shell )?settings$/.test(t)) {
            GlobalStates.settingsOpen = true;
            return root._done(Translation.tr("Opening Settings."), () => GlobalStates.settingsOpen = false);
        }

        // ── Windows: the one in front closed ──
        if (/^close (?:the |this |my )?(?:current |focused |active )?window$/.test(t)) {
            const w = (WM.windowList ?? []).find(x => x.focused);
            if (!w) return null;
            WM.closeWindow(w.id);
            return root._done(Translation.tr("Closed %1.").arg(w.title || w.appId || Translation.tr("the window")));
        }

        // ── An app, only when its name is certain ──
        if ((m = /^(?:switch to|go to|focus|bring up) (?:the |my )?(.+?)(?: app| window)?$/.exec(t))) {
            const entry = root._app(m[1]);
            if (!entry) return null;
            const wins = root._windowsOf(entry);
            if (wins.length === 0) {
                AppLaunch.launchEntry(entry);
                return root._done(Translation.tr("Opening %1.").arg(entry.name));
            }
            const before = (WM.windowList ?? []).find(x => x.focused);
            const w = wins.reduce((a, b) => (b.focusedAt > a.focusedAt ? b : a));
            WM.focusWindow(w.id);
            return root._done(Translation.tr("Switched to %1.").arg(entry.name),
                before && before.id !== w.id ? () => WM.focusWindow(before.id) : null);
        }
        if ((m = /^(?:close|quit|exit) (?:the |my )?(.+?)(?: app| window)?$/.exec(t))) {
            const entry = root._app(m[1]);
            if (!entry) return null;
            const wins = root._windowsOf(entry);
            // None open, or several (which one?): Muse's.
            if (wins.length !== 1) return null;
            WM.closeWindow(wins[0].id);
            return root._done(Translation.tr("Closed %1.").arg(entry.name));
        }
        if ((m = /^(?:open|launch|start|run) (?:the |my )?(.+?)(?: app)?$/.exec(t))) {
            const entry = root._app(m[1]);
            if (!entry) return null;
            AppLaunch.launchEntry(entry);
            return root._done(Translation.tr("Opening %1.").arg(entry.name));
        }
        return null;
    }

    // ── Jellyfin ──
    readonly property string jellyfinBin: Ai.assistantMcpServers.jellyfin?.command ?? ""
    readonly property bool jellyfinOn: root.jellyfinBin !== ""
        && !(Config.options.ai.agent.mcpServersOff ?? []).includes("jellyfin")
    // Set up (a server and a key): `jellyfin-mcp configured`, checked at
    // start and whenever its settings change (Settings calls it after a save).
    property bool jellyfinReady: false
    readonly property string jellyfinSignature: root.jellyfinOn ? `${root.jellyfinBin} ${JSON.stringify(Ai.jellyfinEnv)}` : ""
    onJellyfinSignatureChanged: root.refreshJellyfin()
    Component.onCompleted: root.refreshJellyfin()
    function refreshJellyfin() {
        if (!root.jellyfinOn) {
            root.jellyfinReady = false
            return
        }
        jellyfinCheck.running = false
        jellyfinCheck.command = [root.jellyfinBin, "configured"]
        jellyfinCheck.environment = Ai.jellyfinEnv
        jellyfinCheck.running = true
    }
    Process {
        id: jellyfinCheck
        onExited: code => root.jellyfinReady = code === 0
    }
    readonly property var _videoVerb: /^(?:play|watch|put on|stream|lance|mets|regarde|joue|spiel(?:e)?|schau(?:e)?(?: mir)?|xem|m[oở]|ph[aá]t|b[aậ]t|cho (?:t[oô]i|m[iì]nh|em) xem) (.+)$/
    readonly property var _episodeWords: /\bs\d{1,2} ?e\d{1,3}\b|\b\d{1,2}x\d{1,3}\b|(?:season|saison|staffel|m[uù]a) \d{1,2}\b|(?:episode|[eé]pisode|ep|folge|t[aậ]p) \d{1,3}\b/
    readonly property var _musicWords: /(?:^|[^\wÀ-ỹ])(music|songs?|albums?|playlists?|artists?|tracks?|radio|podcasts?|spotify|youtube|musique|chansons?|musik|lied(?:er)?|nh[aạ]c|b[aà]i h[aá]t)(?![\wÀ-ỹ])/
    function video(text, inConversation, done) {
        if (!root.jellyfinReady || !root.jellyfinOn || videoPlay.running) return false
        const t = root._clean(text)
        if (t.length === 0 || t.length > 100 || t.includes("\n")) return false
        const m = root._videoVerb.exec(t)
        if (!m || root._musicWords.test(t)) return false
        // "play it", "watch the other one": the conversation's, Muse's.
        if (inConversation && root._deictic(m[1])) return false
        const episodic = root._episodeWords.test(t)
        videoPlay.done = done
        videoPlay.command = [root.jellyfinBin, "play-query", t, ...(episodic ? [] : ["--strict"])]
        videoPlay.environment = Ai.jellyfinEnv
        videoPlay.running = true
        return true
    }
    Process {
        id: videoPlay
        property var done: null
        stdout: StdioCollector { id: videoOut }
        onExited: {
            let result = null
            try {
                result = JSON.parse(videoOut.text)
            } catch (e) {}
            const done = videoPlay.done
            videoPlay.done = null
            if (done) done(result)
        }
    }

    // Back to the workspace before (niri's focus-workspace-previous).
    function _workspaceBack() {
        return () => Quickshell.execDetached(["niri", "msg", "action", "focus-workspace-previous"]);
    }

    // The app named exactly (its name, its id, or the start of its name),
    // else none: an app opened by mistake is worse than asking Muse.
    function _app(name) {
        const want = name.trim();
        if (want.length < 2 || root._deictic(want)) return null;
        for (const entry of AppSearch.fuzzyQuery(want).slice(0, 5)) {
            const n = String(entry.name ?? "").toLowerCase();
            const id = String(entry.id ?? "").toLowerCase().replace(/\.desktop$/, "");
            if (n === want || id === want || id.split(".").pop() === want || (want.length >= 4 && n.startsWith(want + " ")))
                return entry;
        }
        return null;
    }
    // Its windows open now (niri's app id against the entry's id, its last
    // part, its executable, or its name).
    function _windowsOf(entry) {
        const id = String(entry.id ?? "").toLowerCase().replace(/\.desktop$/, "");
        const keys = new Set([id, id.split(".").pop(), String(entry.name ?? "").toLowerCase(),
            String(entry.startupClass ?? "").toLowerCase(), String(entry.execString ?? "").split(/\s+/)[0].split("/").pop().toLowerCase()]
            .filter(k => k.length > 1));
        return (WM.windowList ?? []).filter(w => {
            const app = String(w.appId ?? "").toLowerCase();
            return keys.has(app) || keys.has(app.split(".").pop());
        });
    }
}
