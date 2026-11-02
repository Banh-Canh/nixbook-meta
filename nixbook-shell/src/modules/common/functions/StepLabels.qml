pragma Singleton
import Quickshell
import "step_labels.js" as Labels

/**
 * Muse's steps in plain words (step_labels.js, plain code): "Checked your
 * watch list", "Changed the theme" — never a server id, a raw tool name, a
 * path or an argument. In the UI's language (en/fr/de/vi; Qt.locale()).
 * The raw name stays reachable where the step is shown (a tooltip, the tool
 * block's body).
 */
Singleton {
    readonly property string lang: Qt.locale().name.slice(0, 2)
    // "Checked your watch list".
    function done(name, args) {
        return Labels.say(name, args, lang, "done")
    }
    // "Checking your watch list".
    function doing(name, args) {
        return Labels.say(name, args, lang, "doing")
    }
    function key(name, args) {
        return Labels.key(name, args)
    }
    function detail(args) {
        return Labels.detail(args)
    }
    function argsOf(summary) {
        return Labels.argsOf(summary)
    }
    function thinkName(content) {
        return Labels.thinkName(content)
    }
}
