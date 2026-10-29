import QtQuick;

/**
 * Represents a message in an AI conversation. (Kind of) follows the OpenAI API message structure.
 */
QtObject {
    property string role
    property string content
    property string rawContent
    property string fileMimeType
    property string fileUri
    property string localFilePath
    property string model
    property bool thinking: true
    property bool done: false
    // Said by Muse on its own (services/Initiative.qml) and not yet in its
    // agent session: goes with the user's next message.
    property bool unsent: false
    // Said by Muse on its own from what happens on the computer
    // (Initiative): told to Muse as information, never as instructions.
    property bool initiative: false
    // What Muse is to do with the user's answer (a question it asked to
    // learn: save it), told with the answer and then dropped.
    property string learnHint: ""
    // Answered outside the agent's session (one of Quick AI's one-shot
    // modes in the bubble: Explain, Summarize…): told to the session with
    // the next message, then dropped.
    property bool offSession: false
    // What the agent is told, when the message shows something shorter (a
    // Kiroshi task, Full AI's own order: their label is shown).
    property string agentText: ""
    // The agent's checks on its own answer (meta-agent --resolve/--verify):
    // `clarify`, the answer is a question asking which of several readings
    // the user meant (nothing was done); `verify`, after acting it looked
    // again with read-only tools: {met: bool, note} (null: not checked).
    property bool clarify: false
    property var verify: null
    // Its final text was complete (meta-agent's `answer` event): shown and
    // read out, its checks (verify) still to come.
    property bool answered: false
    // A plain command QuickIntent did at once in the bubble (`quick`: the
    // command and its "Done: …"), and its Undo (a function), offered under
    // it while it is the last message.
    property bool quick: false
    property var quickUndo: null
    // The user's 👍 / 👎 on the answer (services/AnswerFeedback.qml): "",
    // "up", "down" (the correction field open), "downSent" (👎 alone),
    // "corrected" (with `correction`, offered to ask again) or "retried".
    property string feedback: ""
    property string correction: ""
    // The app in front when it was asked (the feedback's app).
    property string requestApp: ""
    // Autonomy (meta-agent --trust, the standing_order tool): the standing
    // orders Muse compiled in this answer ({id, summary, routine,
    // questions}: a card with Turn on / Edit / No), what it did trusted to
    // tell after ({class, summary, id?}: "Did: … Undo"), and the classes it
    // suggests to stop asking about ({class, summary}: a chip).
    property var orders: []
    property var told: []
    property var trustSuggest: []
    // The commands Muse ran in this answer (terminal_run: {id, command,
    // cwd, exit, output, duration, visible, error}): "Ran `cmd` (exit N)"
    // with Show output (TerminalNotes).
    property var terminalRuns: []
    // An order split into workers (nixbook-muse-task fanout): the plan's id,
    // its live card under the message (PlanCard: the parts, each worker's
    // figure, the merged answer).
    property string planId: ""
    property var annotations: []
    property var annotationSources: []
    property list<string> searchQueries: []
    property string functionName
    property var functionCall
    property string functionResponse
    property bool functionPending: false
    property bool visibleToUser: true
}
