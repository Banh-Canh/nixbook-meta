pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

/**
 * Kiroshi scan (Mod+K, `kiroshi scan`): a situational brief of the focused
 * screen, and the busywork on it handed off. A screenshot of the output
 * (1280 px wide) goes with what the user is doing (the focused window and
 * its accessibility text, the open windows, their recent activity when
 * ai.initiative.recentContext is on, the latest notifications, the next
 * events, the time) to `nixbook-quick-ai` (mode "scan", scripts/quick-ai.py),
 * masked on the way. It answers in three waves: the brief (what they are
 * doing, the one thing that matters now) in ~3 s, the 3–8 things on screen
 * (boxes, urgency, a gist) in ~6 s, then each one's substance and handle
 * (a plan, a draft, a self-contained instruction for the desktop agent) as
 * they come. The overlay (modules/ii/kiroshi/KiroshiScan.qml) shows them;
 * Do it hands the instruction (with the draft as edited) to Quick AI's
 * "do" (services/QuickAi.qml), Tell me more asks about the item's crop,
 * and the routine ones go in one combined instruction. Gated like Quick AI
 * (QuickAi.available: ai.quick.enable, policies.ai).
 */
Singleton {
    id: root
    // Referenced at startup (shell.qml): its IPC target exists from the start.
    function load() {}

    property bool open: false
    // From the key until every item's detail is in.
    property bool scanning: false
    // The output scanned (its name), the screenshot (kept for crops) and its size.
    property string screenName: ""
    property string imagePath: ""
    property int imageWidth: 0
    property int imageHeight: 0
    // The brief.
    property string doing: ""
    property string focus: ""
    property bool briefIn: false
    // [{label, kind, box: [x, y, w, h] (image px), urgency: now|soon|later|noise,
    // gist, detail, handle: {title, plan, draft, instruction} | null, pending}]
    property var items: []
    property bool itemsIn: false
    // Indexes of the items the agent can handle without the user's judgment.
    property var routine: []
    property string error: ""
    property string provider: ""
    property string model: ""
    property int briefMs: 0
    property int itemsMs: 0
    property int lastMs: 0
    property real startedAt: 0
    // The item opened in the overlay (-1: none).
    property int expanded: -1

    readonly property var routineReady: root.routine.filter(i => root.items[i]?.handle)

    function scan() {
        if (!QuickAi.available) return QuickAi.refuse();
        if (root.scanning) return;
        const name = WM.focusedMonitor?.name ?? Quickshell.screens[0]?.name ?? "";
        const top = ToplevelManager.activeToplevel;
        root.screenName = name;
        root.items = [];
        root.routine = [];
        root.doing = "";
        root.focus = "";
        root.briefIn = false;
        root.itemsIn = false;
        root.error = "";
        root.expanded = -1;
        root.imagePath = "";
        root.imageWidth = 0;
        root.imageHeight = 0;
        root.briefMs = 0;
        root.itemsMs = 0;
        root.lastMs = 0;
        root.startedAt = Date.now();
        root.scanning = true;
        // Shown once the screen is captured (the overlay isn't in it).
        root.open = false;
        proc.serial++;
        proc.requestJson = JSON.stringify(Object.assign({
            mode: "scan", lang: ConfigAssistant.uiLang(),
            model: Config.options.ai.quick?.model ?? "small", effort: Config.options.ai.quick?.effort ?? "low",
            context: { app: top?.appId ?? "", title: top?.title ?? "", source: "scan",
                now: Qt.formatDateTime(new Date(), "ddd d MMM yyyy hh:mm") },
        }, root.situation()));
        proc.output = name;
        proc.running = true;
    }
    // What the user is doing, for the model (masked by the script).
    function situation() {
        const windows = (WM.windowList ?? []).slice().sort((a, b) => (b.focusedAt ?? 0) - (a.focusedAt ?? 0))
            .slice(0, 10).map(w => ({ app: w.appId ?? "", title: w.title ?? "" }));
        const notifications = (Notifications.list ?? []).slice().sort((a, b) => (b.time ?? 0) - (a.time ?? 0))
            .slice(0, 8).map(n => ({ time: Qt.formatDateTime(new Date(n.time), "hh:mm"), app: n.appName ?? "",
                summary: n.summary ?? "", body: String(n.body ?? "").replace(/<[^>]+>/g, "").slice(0, 300) }));
        let events = [];
        try {
            events = CalendarEvents.upcoming(3).map(e => ({ when: CalendarEvents.whenText(e), summary: e.summary ?? "",
                location: e.location ?? "", meeting: !!e.meetingUrl }));
        } catch (e) {}
        const recent = RecentContext.enabled ? RecentContext.snapshot() : [];
        return { windows: windows, notifications: notifications, events: events, recent: recent };
    }
    function close() {
        if (proc.running) {
            proc.serial++;
            proc.running = false;
        }
        root.scanning = false;
        root.open = false;
        root.expanded = -1;
    }
    function expand(i) {
        root.expanded = root.expanded === i ? -1 : (i >= 0 && i < root.items.length ? i : -1);
    }
    function setItem(i, changes) {
        const items = root.items.slice();
        items[i] = Object.assign({}, items[i], changes);
        root.items = items;
    }

    // ── Handing off ──
    // The item's handle, done by the desktop agent; `draft` as the user left it.
    function doIt(i, draft) {
        const it = root.items[i];
        const h = it?.handle;
        if (!h) return;
        let text = h.instruction;
        if (draft !== undefined && draft !== null && String(draft) !== (h.draft ?? ""))
            text += `\n\nThe text to send or type is exactly this (the user edited it):\n<<<\n${draft}\n>>>`;
        root.close();
        // The bubble shows the task's title, the agent gets the instruction.
        QuickAi.command(text, "scan", h.title ? `${h.title} (${it.label})` : it.label);
    }
    // The routine ones, in one go.
    function handleRoutine() {
        const ready = root.routineReady;
        if (ready.length === 0) return;
        const lines = ready.map((i, n) => `${n + 1}. ${root.items[i].label}: ${root.items[i].handle.instruction}`);
        root.close();
        QuickAi.command(`Handle these small things for me, in order, without asking:\n${lines.join("\n")}`, "scan",
            Translation.tr("Handle the routine ones: %1").arg(ready.map(i => root.items[i].label).join(", ")));
    }
    // The item's part of the screen, explained in context.
    function tellMore(i) {
        const it = root.items[i];
        if (!it || !root.imagePath) return;
        const [x, y, w, h] = it.box;
        const pad = 24;
        const x0 = Math.max(0, x - pad), y0 = Math.max(0, y - pad);
        const cw = Math.min(root.imageWidth - x0, w + 2 * pad), ch = Math.min(root.imageHeight - y0, h + 2 * pad);
        crop.question = Translation.tr("Explain this in detail, in context (I'm %1). What should I know or do? It's \"%2\": %3")
            .arg(root.doing || Translation.tr("at my desk")).arg(it.label).arg(it.detail || it.gist || "");
        crop.label = Translation.tr("Tell me more: %1").arg(it.label);
        crop.target = root.imagePath.replace(/\.jpg$/, `-crop${i}.png`);
        crop.command = ["magick", root.imagePath, "-crop", `${Math.round(cw)}x${Math.round(ch)}+${Math.round(x0)}+${Math.round(y0)}`,
            "+repage", crop.target];
        root.close();
        crop.running = true;
    }
    Process {
        id: crop
        property string target: ""
        property string question: ""
        property string label: ""
        onExited: (code) => {
            if (code === 0) QuickAi.askImage(crop.target, crop.question, crop.label);
        }
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
            + 'find "$dir" -maxdepth 1 -name "kiroshi-*" -mmin +60 -delete 2>/dev/null; '
            + 'grim -l 0 ${2:+-o "$2"} "$shot" || { echo \'{"type":"error","error":"no screenshot (grim)"}\'; exit 1; }; '
            + 'echo \'{"type":"captured"}\'; '
            + 'magick "$shot" -resize "1280x>" -quality 85 "$img" || { echo \'{"type":"error","error":"no image (magick)"}\'; exit 1; }; '
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
                case "brief":
                    root.briefMs = ev.ms ?? 0;
                    root.doing = ev.doing ?? "";
                    root.focus = ev.focus ?? "";
                    root.briefIn = true;
                    break;
                case "scan":
                    root.imageWidth = ev.width ?? 0;
                    root.imageHeight = ev.height ?? 0;
                    root.itemsMs = ev.ms ?? 0;
                    root.items = (ev.items ?? []).map(it => Object.assign({ detail: "", handle: null, pending: true }, it));
                    root.routine = ev.routine ?? [];
                    root.itemsIn = true;
                    break;
                case "item":
                    if (ev.index >= 0 && ev.index < root.items.length)
                        root.setItem(ev.index, { detail: ev.detail ?? "", handle: ev.handle ?? null, pending: false,
                            failed: ev.error ?? "" });
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
            root.items = root.items.map(it => it.pending ? Object.assign({}, it, { pending: false }) : it);
            if (code !== 0) root.open = true;
            if (code !== 0 && root.error.length === 0 && root.items.length === 0)
                root.error = Translation.tr("The scan failed (exit %1)").arg(code);
        }
    }

    IpcHandler {
        target: "kiroshi"
        // The focused screen, scanned and briefed (again while open or scanning: closes it).
        function scan(): void {
            if (root.open || root.scanning) root.close();
            else root.scan();
        }
        function close(): void { root.close(); }
        // Item N (from 1): opened, done (its handle), or explained.
        function expand(n: int): void { root.expand(n - 1); }
        function doIt(n: int): void { root.doIt(n - 1); }
        function tellMore(n: int): void { root.tellMore(n - 1); }
        function handleRoutine(): void { root.handleRoutine(); }
        function status(): string {
            return JSON.stringify({ open: root.open, scanning: root.scanning, screen: root.screenName,
                width: root.imageWidth, height: root.imageHeight, doing: root.doing, focus: root.focus,
                routine: root.routine, error: root.error, briefMs: root.briefMs, itemsMs: root.itemsMs,
                ms: root.lastMs, items: root.items });
        }
    }
}
