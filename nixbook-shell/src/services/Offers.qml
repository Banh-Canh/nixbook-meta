pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common.functions
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * One offer per moment. Several surfaces offer help on their own: Muse's
 * words (Initiative.qml: "report.pdf just landed in Downloads. Want the
 * gist?"), Next up's chip (NextUp.qml: "Next: summarize report.pdf"), the
 * smart clipboard's chips (SmartClipboard.qml). About the same thing (the
 * same file, link, pull request, meeting, trigger: OfferCues), only one
 * shows: an offer `claim`s its moment before it shows, and
 *   - a moment already offered elsewhere is refused (`claim` false), unless
 *     the new surface ranks higher (Muse's word, with its buttons, before
 *     Next up's chip, before the clipboard's): the other is withdrawn;
 *   - taken through one surface (`taken`), the others offering it go;
 *   - a turn of Muse's that names it (`mentioned`: the user's request, its
 *     answer — "summarize report.pdf" asked in the bubble) takes it too;
 *   - its context gone (the file deleted or moved away), it goes.
 * Withdrawn offers are the surfaces' to take away (`withdraw`): nothing is
 * learned from them, the user never turned them down.
 */
Singleton {
    id: root

    // The offers showing now: {surface, id, cue, time}.
    property var live: []
    // Higher first.
    readonly property var rank: ({ initiative: 3, nextup: 2, clipboard: 1 })
    // Kept at most this long (the surfaces have their own, shorter, ends).
    readonly property int maxAgeMs: 30 * 60000
    signal withdraw(string surface, string id, string why)

    function _prune() {
        const t = Date.now()
        root.live = root.live.filter(o => t - o.time < root.maxAgeMs)
    }
    function _drop(o, why) {
        root.live = root.live.filter(x => x !== o)
        root.withdraw(o.surface, o.id, why)
    }
    // Before showing an offer: false when this moment is offered elsewhere
    // already (it isn't shown). No cue: always shown.
    function claim(surface, id, cue) {
        if (!cue || !id) return true
        root._prune()
        for (const o of root.live.filter(x => x.surface !== surface && OfferCues.same(x.cue, cue))) {
            if ((root.rank[o.surface] ?? 0) >= (root.rank[surface] ?? 0)) return false
            root._drop(o, "merged")
        }
        root.live = [...root.live.filter(x => !(x.surface === surface && x.id === id)), { surface: surface, id: String(id), cue: cue, time: Date.now() }]
        return true
    }
    // Its own offer gone (answered, faded, closed).
    function release(surface, id) {
        root.live = root.live.filter(x => !(x.surface === surface && x.id === String(id)))
    }
    // Taken through one surface: the same moment elsewhere goes.
    function taken(surface, id) {
        const mine = root.live.find(x => x.surface === surface && x.id === String(id))
        root.release(surface, id)
        if (!mine) return
        for (const o of root.live.filter(x => OfferCues.same(x.cue, mine.cue))) root._drop(o, "taken")
    }
    // A request or an answer naming what an offer is about: acted on by
    // another path.
    function mentioned(text) {
        const t = String(text ?? "")
        if (t.length === 0 || root.live.length === 0) return
        for (const o of root.live.filter(x => OfferCues.mentions(t, x.cue))) root._drop(o, "mentioned")
    }

    // Its context gone: a file offered about that isn't there any more.
    Timer {
        interval: 30000
        repeat: true
        running: root.live.some(o => !!o.cue?.path)
        onTriggered: {
            root._prune()
            const paths = [...new Set(root.live.filter(o => !!o.cue?.path).map(o => o.cue.path))]
            if (paths.length === 0 || gone.running) return
            gone.command = ["sh", "-c", 'for p in "$@"; do [ -e "$p" ] || printf "%s\\n" "$p"; done', "sh", ...paths]
            gone.running = true
        }
    }
    Process {
        id: gone
        stdout: StdioCollector {
            id: goneOut
            onStreamFinished: {
                const missing = goneOut.text.split("\n").filter(p => p.length > 0)
                for (const o of root.live.filter(x => missing.includes(x.cue?.path ?? ""))) root._drop(o, "gone")
            }
        }
    }
}
