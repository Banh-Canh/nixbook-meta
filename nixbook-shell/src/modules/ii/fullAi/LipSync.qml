import qs.services
import QtQuick

/**
 * Lip-sync for a mascot (Mascot.lip): the sentence playing (Voice.saying
 * grows as each starts) read out at a speaking pace, the mouth open on
 * vowels, half on consonants, shut on spaces and punctuation; past the text,
 * a soft babble until the next sentence (the voice still on it). Nothing
 * reported yet: shut (it is still being made). -1 while not speaking or not
 * `live` (the mascot's own mouth then). Shared by the Full AI stage and the
 * desktop mascot.
 */
Item {
    id: root
    property bool live: true
    readonly property real value: Voice.speaking && root.live ? root.mouth : -1

    property string queue: ""
    property int fed: 0
    property real mouth: 0
    property bool babble: false
    readonly property var vowels: /[aeiouyàâäéèêëîïôöùûüÿœæăắằẳẵặâấầẩẫậêếềểễệôốồổỗộơớờởỡợưứừửữựíìỉĩịóòỏõọúùủũụýỳỷỹỵ]/i

    Connections {
        target: Voice
        function onSayingChanged() {
            const s = Voice.saying;
            if (s === null || s === undefined) {
                root.queue = "";
                root.fed = 0;
                root.babble = false;
                return;
            }
            // A new answer started over.
            if (s.length < root.fed) root.fed = 0;
            if (s.length > root.fed) {
                root.queue += s.slice(root.fed);
                root.fed = s.length;
                root.babble = true;
            }
        }
    }
    Timer {
        running: Voice.speaking && root.live
        interval: 70
        repeat: true
        onTriggered: {
            const q = root.queue;
            if (q.length === 0) {
                root.mouth = root.babble ? 0.15 + Math.random() * 0.5 : 0;
                return;
            }
            const c = q.charAt(0);
            root.queue = q.slice(1);
            root.mouth = root.vowels.test(c) ? 0.65 + Math.random() * 0.35
                : /[\s.,!?;:…\-]/.test(c) ? 0.04 : 0.28;
        }
        onRunningChanged: if (!running) root.mouth = 0
    }
}
