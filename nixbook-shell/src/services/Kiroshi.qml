pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

/**
 * Kiroshi scan (Mod+K, `kiroshi scan`): the focused screen read by the
 * model's vision at once, like cyberpunk optics. A screenshot of the output
 * (downscaled to 1440 px wide) and the focused window's accessibility text
 * go to `nixbook-quick-ai` (mode "scan", scripts/quick-ai.py), which labels
 * the 4–8 things that matter (an error, a message waiting, a form, the
 * main window…) with a box, a line of detail and an action or two. The
 * overlay (modules/ii/kiroshi/KiroshiScan.qml) draws them over the screen;
 * an action is handed to Quick AI's "do" mode, which runs it with the
 * desktop tools (services/QuickAi.qml). Gated like Quick AI
 * (QuickAi.available: ai.quick.enable, policies.ai).
 */
Singleton {
    id: root

    property bool open: false
    property bool scanning: false
    // The output scanned (its name) and the screenshot's size in pixels.
    property string screenName: ""
    property int imageWidth: 0
    property int imageHeight: 0
    property string imagePath: ""
    // [{label, kind, box: [x, y, w, h] (image px), detail, actions}]
    property var items: []
    property string summary: ""
    property string error: ""
    property string provider: ""
    property string model: ""
    property int lastMs: 0
    property real startedAt: 0

    function scan() {
        if (!QuickAi.available) return QuickAi.refuse();
        if (root.scanning) return;
        const name = WM.focusedMonitor?.name ?? Quickshell.screens[0]?.name ?? "";
        const top = ToplevelManager.activeToplevel;
        root.screenName = name;
        root.items = [];
        root.summary = "";
        root.error = "";
        root.imageWidth = 0;
        root.imageHeight = 0;
        root.lastMs = 0;
        root.startedAt = Date.now();
        root.scanning = true;
        // Shown once the screen is captured (the overlay isn't in it).
        root.open = false;
        proc.serial++;
        proc.requestJson = JSON.stringify({
            mode: "scan", lang: ConfigAssistant.uiLang(),
            model: Config.options.ai.quick?.model ?? "small", effort: Config.options.ai.quick?.effort ?? "low",
            claude: Ai.claudeCodePath, context: { app: top?.appId ?? "", title: top?.title ?? "", source: "scan" },
        });
        proc.output = name;
        proc.running = true;
    }
    function close() {
        if (proc.running) {
            proc.serial++;
            proc.running = false;
        }
        root.scanning = false;
        root.open = false;
    }
    // An item's action, done by the desktop agent (Quick AI's "do").
    function act(item, action) {
        if (!item || !action) return;
        const about = item.detail ? `${item.label} (${item.detail})` : item.label;
        root.close();
        QuickAi.command(`${action} — about: ${about}`, "scan");
    }

    Process {
        id: proc
        property int serial: 0
        property int mine: 0
        property string requestJson: "{}"
        property string output: ""
        onRunningChanged: if (running) mine = serial
        command: ["bash", "-c", 'dir="${XDG_RUNTIME_DIR:-/tmp}/nixbook-shell/quick-ai"; mkdir -p -m 700 "$dir"; '
            + 'shot="$dir/kiroshi-$$.png"; img="$dir/kiroshi-$$.jpg"; f="$dir/kiroshi-$$.json"; '
            + 'trap \'rm -f "$shot" "$f"\' EXIT; '
            + 'find "$dir" -maxdepth 1 -name "kiroshi-*.jpg" -mmin +60 -delete 2>/dev/null; '
            + 'grim -l 0 ${2:+-o "$2"} "$shot" || { echo \'{"type":"error","error":"no screenshot (grim)"}\'; exit 1; }; '
            + 'echo \'{"type":"captured"}\'; '
            + 'magick "$shot" -resize "1440x>" -quality 85 "$img" || { echo \'{"type":"error","error":"no image (magick)"}\'; exit 1; }; '
            + 'echo "{\\"type\\":\\"image\\",\\"path\\":\\"$img\\"}"; '
            + 'printf "%s" "$1" | jq -c --arg img "$img" \'. + {image: $img}\' > "$f"; '
            + 'nixbook-model-provider run nixbook-quick-ai ask "$f"', "_", proc.requestJson, proc.output]
        stdout: SplitParser {
            onRead: (line) => {
                if (proc.mine !== proc.serial) return;
                let ev;
                try { ev = JSON.parse(line); } catch (e) {
                    if (line.trim().length > 0) root.error = line.trim();
                    return;
                }
                switch (ev.type) {
                case "captured": root.open = true; break;
                case "image": root.imagePath = ev.path ?? ""; break;
                case "start":
                    root.provider = ev.provider ?? "";
                    root.model = ev.model ?? "";
                    break;
                case "scan":
                    root.imageWidth = ev.width ?? 0;
                    root.imageHeight = ev.height ?? 0;
                    root.summary = ev.summary ?? "";
                    root.items = ev.items ?? [];
                    break;
                case "error": root.error = ev.error ?? Translation.tr("No answer"); break;
                case "done": root.lastMs = ev.ms ?? (Date.now() - root.startedAt); break;
                }
            }
        }
        stderr: SplitParser {
            onRead: (line) => {
                if (proc.mine === proc.serial && /nixbook-model-provider:/.test(line))
                    root.error = line.replace(/^nixbook-model-provider:\s*/, "");
            }
        }
        onExited: (code) => {
            if (proc.mine !== proc.serial) return;
            root.scanning = false;
            if (code !== 0) root.open = true;
            if (code !== 0 && root.error.length === 0 && root.items.length === 0)
                root.error = Translation.tr("The scan failed (exit %1)").arg(code);
        }
    }

    IpcHandler {
        target: "kiroshi"
        // The focused screen, scanned and labelled (again while open or scanning: closes it).
        function scan(): void {
            if (root.open || root.scanning) root.close();
            else root.scan();
        }
        function close(): void { root.close(); }
        function status(): string {
            return JSON.stringify({ open: root.open, scanning: root.scanning, screen: root.screenName,
                width: root.imageWidth, height: root.imageHeight, summary: root.summary, error: root.error,
                ms: root.lastMs, items: root.items });
        }
    }
}
