pragma Singleton
import Quickshell
import "addressee.js" as Rules

/**
 * Was it said to Muse? (addressee.js, plain code, well under a millisecond):
 * Full AI mode's always-open microphone (services/Addressee.qml).
 */
Singleton {
    function decide(text, ctx) {
        return Rules.decide(text, ctx)
    }
    function calledByName(text) {
        return Rules.calledByName(text)
    }
    function otherPerson(text) {
        return Rules.otherPerson(text)
    }
}
