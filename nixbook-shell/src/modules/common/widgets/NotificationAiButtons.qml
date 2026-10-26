import qs.services
import qs.modules.common
import QtQuick
import QtQuick.Layouts

/**
 * Quick AI on a notification (ai.quick.notifications): Summarize, and
 * Suggest replies on what looks like a message (the app takes a reply, or
 * it is a chat app). Both open the Quick AI card (services/QuickAi.qml),
 * whose replies are sent inline or copied; the popup is hidden (kept in
 * the centre), like mark-as-read. Used by NotificationGroup (Material) and
 * PersonaMessage (the Persona chat), each passing its own button look.
 */
RowLayout {
    id: root
    // The group's notifications (Notif objects), the latest last.
    required property var notifications
    property bool popup: false
    property real buttonSize: 26
    property real iconSize: Appearance.font.pixelSize.normal
    property real buttonRadius: Appearance.rounding.full
    property color colBackground: "transparent"
    property color colBackgroundHover: Appearance.colors.colLayer2Hover
    property color colRipple: Appearance.colors.colLayer2Active
    property color iconColor: Appearance.colors.colOnLayer2

    readonly property var latest: root.notifications.length > 0 ? root.notifications[root.notifications.length - 1] : null
    readonly property bool enabledHere: QuickAi.available && (Config.options.ai.quick?.notifications ?? true) && root.latest !== null
    // A message: the app takes a reply (inline or its Reply action), it
    // stays on screen as a chat (notifications.persistent), or comes from a
    // chat app (a phone's relayed messages included). Only live ones: a
    // reply from the history would go nowhere.
    readonly property bool looksLikeMessage: {
        const n = root.latest;
        if (!n?.notification) return false;
        if (Notifications.replyMethod(n) !== null || Notifications.staysOnScreen(n)) return true;
        return /vesktop|discord|slack|whatsapp|telegram|signal|messenger|instagram|messages|element|teams|thunderbird|mail|kde ?connect|gsconnect/i
            .test(`${n.appName ?? ""} ${n.desktopEntry ?? ""}`);
    }

    visible: root.enabledHere
    spacing: 2

    // A group of several: summarized together (the latest's id, for the record).
    function subject() {
        const ns = root.notifications;
        if (ns.length <= 1) return root.latest;
        return {
            summary: root.latest.appName ?? "",
            body: ns.map(n => [n.summary, n.body].filter(s => s).join(": ")).join("\n"),
            appName: root.latest.appName ?? "",
            notificationId: root.latest.notificationId,
        };
    }
    function hidePopup() {
        if (root.popup) root.notifications.forEach(n => Notifications.timeoutNotification(n.notificationId));
    }

    component AiButton: RippleButton {
        id: aiButton
        property string glyph
        property string tip
        implicitWidth: root.buttonSize
        implicitHeight: root.buttonSize
        buttonRadius: root.buttonRadius
        colBackground: root.colBackground
        colBackgroundHover: root.colBackgroundHover
        colRipple: root.colRipple
        contentItem: MaterialSymbol {
            anchors.centerIn: parent
            text: aiButton.glyph
            iconSize: root.iconSize
            color: root.iconColor
        }
        PopupToolTip {
            text: aiButton.tip
        }
    }

    AiButton {
        glyph: "summarize"
        tip: Translation.tr("Summarize with AI")
        onClicked: {
            QuickAi.askNotification(root.subject(), "summarize");
            root.hidePopup();
        }
    }
    AiButton {
        visible: root.looksLikeMessage
        glyph: "quickreply"
        tip: Translation.tr("Suggest replies with AI")
        onClicked: {
            // The latest message: the one a reply goes to.
            QuickAi.askNotification(root.latest, "reply");
            root.hidePopup();
        }
    }
}
