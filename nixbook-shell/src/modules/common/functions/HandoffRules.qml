pragma Singleton
import Quickshell
import "handoff.js" as Rules

/**
 * What goes to the phone when the user leaves, and whether now
 * (handoff.js, plain code): services/PhoneHandoff.qml.
 */
Singleton {
    function decide(state) {
        return Rules.decide(state)
    }
}
