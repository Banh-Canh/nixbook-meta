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
    property var annotations: []
    property var annotationSources: []
    property list<string> searchQueries: []
    property string functionName
    property var functionCall
    property string functionResponse
    property bool functionPending: false
    property bool visibleToUser: true
}
