pragma Singleton
import Quickshell
import "offer_cues.js" as Cues

/**
 * What an offer is about (offer_cues.js, plain code): the cue that tells
 * services/Offers.qml two surfaces offer the same moment (Muse's word about
 * a download and Next up's "summarize it"), and whether a text names it.
 */
Singleton {
    function fromInitiative(item) {
        return Cues.fromInitiative(item)
    }
    function fromNextUp(offer) {
        return Cues.fromNextUp(offer)
    }
    function fromClipboard(text, kind) {
        return Cues.fromClipboard(text, kind)
    }
    function fromMeeting(title) {
        return Cues.fromMeeting(title)
    }
    function same(a, b) {
        return Cues.same(a, b)
    }
    function mentions(text, cue) {
        return Cues.mentions(text, cue)
    }
}
