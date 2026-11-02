.pragma library

// Muse's steps in plain words, wherever they are shown (the bubble's "Doing
// …" line, its "Did: …" lines, a chat's tool blocks, Full AI's balloon, the
// Muse tab's tasks and journal): "Checked your watch list", "Changed the
// theme", "Looked something up", "Read a file" — never a server id
// (`mcp__jellyfin__next_up`), a raw tool name (`Bash`), a path or an
// argument. The raw name stays where it was (a tooltip, the tool block's
// body). Plain code, in English, French, German and Vietnamese.
//
// A step is named as it comes: a tool's full name (`mcp__<server>__<tool>`),
// the chat's "server: tool", a built-in (Read, Bash, WebSearch…), a bare
// desktop tool (`set_theme`, its words "set theme"), or a trust class
// (`media_control:pause@firefox`: the tool, its action, the app).
//   say(name, args, lang, form) -> the phrase ("done": "Checked your watch
//       list", "doing": "Checking your watch list")
//   key(name, args) -> its kind ("watchlist"), the same for steps said the
//       same way (the "Did: …" lines group by it)
//   detail(args) -> a short human value of the call's arguments ("K/DA
//       MORE"), never a path, a link's path or an id; "" when none
//   argsOf(summary) -> {key: value} from a step's summary ("set wallpaper
//       (path=/x, name=Dune)" or "path=/x, name=Dune")
//   thinkName(content) -> the tool named by a chat's tool block ("**jellyfin:
//       next_up** {…}" -> "jellyfin: next_up"), "" when it isn't one
// QML's JS engine: no ES2019+.

var LANGS = ["en", "fr", "de", "vi"]

// [doing, done] per language; Vietnamese: one phrase, "Đang" / "Đã" before.
// {app}: the app's own name (a known MCP server: Jellyfin, Discord…).
var PHRASES = {
    search: { en: ["Looking something up", "Looked something up"], fr: ["Je fais une recherche", "J'ai fait une recherche"],
              de: ["Suche etwas", "Etwas nachgeschlagen"], vi: "tra cứu" },
    web_read: { en: ["Reading a page", "Read a page"], fr: ["Je lis une page", "J'ai lu une page"],
                de: ["Lese eine Seite", "Eine Seite gelesen"], vi: "đọc một trang" },
    page_go: { en: ["Opening a page", "Opened a page"], fr: ["J'ouvre une page", "J'ai ouvert une page"],
               de: ["Öffne eine Seite", "Eine Seite geöffnet"], vi: "mở một trang" },
    page_act: { en: ["Working in a page", "Worked in a page"], fr: ["J'agis dans une page", "J'ai agi dans une page"],
                de: ["Arbeite auf einer Seite", "Auf einer Seite gearbeitet"], vi: "thao tác trên một trang" },
    history: { en: ["Checking your browsing history", "Checked your browsing history"],
               fr: ["Je regarde ton historique", "J'ai regardé ton historique"],
               de: ["Schaue in deinen Verlauf", "In deinen Verlauf geschaut"], vi: "xem lịch sử duyệt web" },
    file_read: { en: ["Reading a file", "Read a file"], fr: ["Je lis un fichier", "J'ai lu un fichier"],
                 de: ["Lese eine Datei", "Eine Datei gelesen"], vi: "đọc một tệp" },
    file_find: { en: ["Looking through your files", "Looked through your files"],
                 fr: ["Je parcours tes fichiers", "J'ai parcouru tes fichiers"],
                 de: ["Durchsuche deine Dateien", "Deine Dateien durchsucht"], vi: "tìm trong các tệp của bạn" },
    file_edit: { en: ["Editing a file", "Edited a file"], fr: ["Je modifie un fichier", "J'ai modifié un fichier"],
                 de: ["Bearbeite eine Datei", "Eine Datei bearbeitet"], vi: "sửa một tệp" },
    command: { en: ["Running a command", "Ran a command"], fr: ["Je lance une commande", "J'ai lancé une commande"],
               de: ["Führe einen Befehl aus", "Einen Befehl ausgeführt"], vi: "chạy một lệnh" },
    suggest: { en: ["Suggesting a command", "Suggested a command"], fr: ["Je propose une commande", "J'ai proposé une commande"],
               de: ["Schlage einen Befehl vor", "Einen Befehl vorgeschlagen"], vi: "gợi ý một lệnh" },
    terminal: { en: ["Looking at your terminal", "Looked at your terminal"], fr: ["Je regarde ton terminal", "J'ai regardé ton terminal"],
                de: ["Schaue ins Terminal", "Ins Terminal geschaut"], vi: "xem terminal" },
    editor: { en: ["Opening it in your editor", "Opened it in your editor"], fr: ["Je l'ouvre dans l'éditeur", "Je l'ai ouvert dans l'éditeur"],
              de: ["Öffne es im Editor", "Im Editor geöffnet"], vi: "mở trong trình soạn thảo" },
    screen: { en: ["Looking at the screen", "Looked at the screen"], fr: ["Je regarde l'écran", "J'ai regardé l'écran"],
              de: ["Schaue auf den Bildschirm", "Auf den Bildschirm geschaut"], vi: "xem màn hình" },
    click: { en: ["Clicking", "Clicked"], fr: ["Je clique", "J'ai cliqué"], de: ["Klicke", "Geklickt"], vi: "bấm chuột" },
    type: { en: ["Typing", "Typed"], fr: ["Je tape", "J'ai tapé"], de: ["Tippe", "Getippt"], vi: "gõ chữ" },
    keys: { en: ["Pressing keys", "Pressed keys"], fr: ["J'appuie sur des touches", "J'ai appuyé sur des touches"],
            de: ["Drücke Tasten", "Tasten gedrückt"], vi: "nhấn phím" },
    scroll: { en: ["Scrolling", "Scrolled"], fr: ["Je fais défiler", "J'ai fait défiler"], de: ["Scrolle", "Gescrollt"], vi: "cuộn" },
    steps: { en: ["Working in the app", "Worked in the app"], fr: ["Je travaille dans l'appli", "J'ai travaillé dans l'appli"],
             de: ["Arbeite in der App", "In der App gearbeitet"], vi: "thao tác trong ứng dụng" },
    open_app: { en: ["Opening an app", "Opened an app"], fr: ["J'ouvre une appli", "J'ai ouvert une appli"],
                de: ["Öffne eine App", "Eine App geöffnet"], vi: "mở một ứng dụng" },
    close_window: { en: ["Closing a window", "Closed a window"], fr: ["Je ferme une fenêtre", "J'ai fermé une fenêtre"],
                    de: ["Schließe ein Fenster", "Ein Fenster geschlossen"], vi: "đóng một cửa sổ" },
    windows: { en: ["Arranging your windows", "Arranged your windows"], fr: ["J'organise tes fenêtres", "J'ai organisé tes fenêtres"],
               de: ["Ordne deine Fenster", "Deine Fenster angeordnet"], vi: "sắp xếp cửa sổ" },
    windows_look: { en: ["Checking your windows", "Checked your windows"], fr: ["Je regarde tes fenêtres", "J'ai regardé tes fenêtres"],
                    de: ["Prüfe deine Fenster", "Deine Fenster geprüft"], vi: "xem các cửa sổ" },
    layout: { en: ["Restoring a layout", "Restored a layout"], fr: ["Je restaure une disposition", "J'ai restauré une disposition"],
              de: ["Stelle eine Anordnung wieder her", "Eine Anordnung wiederhergestellt"], vi: "khôi phục bố cục" },
    layout_save: { en: ["Saving the layout", "Saved the layout"], fr: ["J'enregistre la disposition", "J'ai enregistré la disposition"],
                   de: ["Speichere die Anordnung", "Die Anordnung gespeichert"], vi: "lưu bố cục" },
    theme: { en: ["Changing the theme", "Changed the theme"], fr: ["Je change le thème", "J'ai changé le thème"],
             de: ["Ändere das Design", "Das Design geändert"], vi: "đổi giao diện" },
    themes_look: { en: ["Checking the themes", "Checked the themes"], fr: ["Je regarde les thèmes", "J'ai regardé les thèmes"],
                   de: ["Schaue die Designs an", "Die Designs angeschaut"], vi: "xem các giao diện" },
    wallpaper: { en: ["Changing the wallpaper", "Changed the wallpaper"], fr: ["Je change le fond d'écran", "J'ai changé le fond d'écran"],
                 de: ["Ändere das Hintergrundbild", "Das Hintergrundbild geändert"], vi: "đổi hình nền" },
    sound: { en: ["Adjusting the sound", "Adjusted the sound"], fr: ["Je règle le son", "J'ai réglé le son"],
             de: ["Passe den Ton an", "Den Ton angepasst"], vi: "chỉnh âm thanh" },
    music: { en: ["Controlling the music", "Controlled the music"], fr: ["Je règle la lecture", "J'ai réglé la lecture"],
             de: ["Steuere die Wiedergabe", "Die Wiedergabe gesteuert"], vi: "điều khiển nhạc" },
    play: { en: ["Starting playback", "Started playback"], fr: ["Je lance la lecture", "J'ai lancé la lecture"],
            de: ["Starte die Wiedergabe", "Die Wiedergabe gestartet"], vi: "phát nội dung" },
    queue: { en: ["Adding to the queue", "Added to the queue"], fr: ["J'ajoute à la file d'attente", "J'ai ajouté à la file d'attente"],
             de: ["Füge zur Warteschlange hinzu", "Zur Warteschlange hinzugefügt"], vi: "thêm vào hàng chờ" },
    watchlist: { en: ["Checking your watch list", "Checked your watch list"],
                 fr: ["Je consulte ta liste à regarder", "J'ai consulté ta liste à regarder"],
                 de: ["Prüfe deine Watchlist", "Deine Watchlist geprüft"], vi: "xem danh sách phim của bạn" },
    library: { en: ["Searching your library", "Searched your library"], fr: ["Je cherche dans ta médiathèque", "J'ai cherché dans ta médiathèque"],
               de: ["Durchsuche deine Mediathek", "Deine Mediathek durchsucht"], vi: "tìm trong thư viện" },
    playing: { en: ["Checking what's playing", "Checked what's playing"], fr: ["Je regarde ce qui passe", "J'ai regardé ce qui passe"],
               de: ["Schaue, was läuft", "Nachgeschaut, was läuft"], vi: "xem đang phát gì" },
    request_media: { en: ["Requesting a title", "Requested a title"], fr: ["Je demande un titre", "J'ai demandé un titre"],
                     de: ["Fordere einen Titel an", "Einen Titel angefordert"], vi: "yêu cầu một bộ phim" },
    calendar_look: { en: ["Checking your calendar", "Checked your calendar"], fr: ["Je consulte ton agenda", "J'ai consulté ton agenda"],
                     de: ["Prüfe deinen Kalender", "Deinen Kalender geprüft"], vi: "xem lịch" },
    calendar_add: { en: ["Adding an event", "Added an event"], fr: ["J'ajoute un événement", "J'ai ajouté un événement"],
                    de: ["Trage einen Termin ein", "Einen Termin eingetragen"], vi: "thêm một sự kiện" },
    calendar_change: { en: ["Updating your calendar", "Updated your calendar"], fr: ["Je mets à jour ton agenda", "J'ai mis à jour ton agenda"],
                       de: ["Aktualisiere deinen Kalender", "Deinen Kalender aktualisiert"], vi: "cập nhật lịch" },
    tasks_look: { en: ["Checking your tasks", "Checked your tasks"], fr: ["Je consulte tes tâches", "J'ai consulté tes tâches"],
                  de: ["Prüfe deine Aufgaben", "Deine Aufgaben geprüft"], vi: "xem việc cần làm" },
    tasks_change: { en: ["Updating your tasks", "Updated your tasks"], fr: ["Je mets à jour tes tâches", "J'ai mis à jour tes tâches"],
                    de: ["Aktualisiere deine Aufgaben", "Deine Aufgaben aktualisiert"], vi: "cập nhật việc cần làm" },
    widgets: { en: ["Updating your desktop widgets", "Updated your desktop widgets"], fr: ["Je mets à jour tes widgets", "J'ai mis à jour tes widgets"],
               de: ["Aktualisiere deine Widgets", "Deine Widgets aktualisiert"], vi: "cập nhật tiện ích" },
    notif_look: { en: ["Checking your notifications", "Checked your notifications"],
                  fr: ["Je regarde tes notifications", "J'ai regardé tes notifications"],
                  de: ["Prüfe deine Benachrichtigungen", "Deine Benachrichtigungen geprüft"], vi: "xem thông báo" },
    notif_clear: { en: ["Clearing notifications", "Cleared notifications"], fr: ["J'efface des notifications", "J'ai effacé des notifications"],
                   de: ["Räume Benachrichtigungen weg", "Benachrichtigungen weggeräumt"], vi: "xóa thông báo" },
    notif_act: { en: ["Answering a notification", "Answered a notification"], fr: ["Je réponds à une notification", "J'ai répondu à une notification"],
                 de: ["Beantworte eine Benachrichtigung", "Eine Benachrichtigung beantwortet"], vi: "trả lời một thông báo" },
    notify: { en: ["Sending you a notification", "Sent you a notification"], fr: ["Je t'envoie une notification", "Je t'ai envoyé une notification"],
              de: ["Schicke dir eine Benachrichtigung", "Dir eine Benachrichtigung geschickt"], vi: "gửi bạn một thông báo" },
    dnd: { en: ["Changing Do Not Disturb", "Changed Do Not Disturb"], fr: ["Je règle Ne pas déranger", "J'ai réglé Ne pas déranger"],
           de: ["Stelle „Nicht stören“ um", "„Nicht stören“ umgestellt"], vi: "đổi chế độ không làm phiền" },
    memory_look: { en: ["Checking what I remember", "Checked what I remember"], fr: ["Je consulte ma mémoire", "J'ai consulté ma mémoire"],
                   de: ["Schaue in mein Gedächtnis", "In mein Gedächtnis geschaut"], vi: "xem lại trí nhớ" },
    memory_save: { en: ["Remembering that", "Remembered that"], fr: ["Je retiens ça", "J'ai retenu ça"],
                   de: ["Merke mir das", "Das gemerkt"], vi: "ghi nhớ điều đó" },
    memory_forget: { en: ["Forgetting that", "Forgot that"], fr: ["J'oublie ça", "J'ai oublié ça"],
                     de: ["Vergesse das", "Das vergessen"], vi: "quên điều đó" },
    reminder: { en: ["Setting a reminder", "Set a reminder"], fr: ["Je crée un rappel", "J'ai créé un rappel"],
                de: ["Lege eine Erinnerung an", "Eine Erinnerung angelegt"], vi: "đặt lời nhắc" },
    routine: { en: ["Setting up a routine", "Set up a routine"], fr: ["Je prépare une routine", "J'ai préparé une routine"],
               de: ["Richte eine Routine ein", "Eine Routine eingerichtet"], vi: "thiết lập một thói quen" },
    clipboard: { en: ["Using the clipboard", "Used the clipboard"], fr: ["J'utilise le presse-papiers", "J'ai utilisé le presse-papiers"],
                 de: ["Nutze die Zwischenablage", "Die Zwischenablage genutzt"], vi: "dùng bộ nhớ tạm" },
    messages: { en: ["Reading your messages", "Read your messages"], fr: ["Je lis tes messages", "J'ai lu tes messages"],
                de: ["Lese deine Nachrichten", "Deine Nachrichten gelesen"], vi: "đọc tin nhắn" },
    message_send: { en: ["Sending a message", "Sent a message"], fr: ["J'envoie un message", "J'ai envoyé un message"],
                    de: ["Sende eine Nachricht", "Eine Nachricht gesendet"], vi: "gửi một tin nhắn" },
    react: { en: ["Reacting to a message", "Reacted to a message"], fr: ["Je réagis à un message", "J'ai réagi à un message"],
             de: ["Reagiere auf eine Nachricht", "Auf eine Nachricht reagiert"], vi: "thả cảm xúc cho một tin nhắn" },
    contacts: { en: ["Looking up a contact", "Looked up a contact"], fr: ["Je cherche un contact", "J'ai cherché un contact"],
                de: ["Suche einen Kontakt", "Einen Kontakt gesucht"], vi: "tìm một liên hệ" },
    setup: { en: ["Checking your setup", "Checked your setup"], fr: ["Je vérifie ta configuration", "J'ai vérifié ta configuration"],
             de: ["Prüfe dein System", "Dein System geprüft"], vi: "xem cấu hình máy" },
    shell_setting: { en: ["Changing a desktop setting", "Changed a desktop setting"],
                     fr: ["Je change un réglage du bureau", "J'ai changé un réglage du bureau"],
                     de: ["Ändere eine Desktop-Einstellung", "Eine Desktop-Einstellung geändert"], vi: "đổi một cài đặt" },
    background: { en: ["Starting a background task", "Started a background task"],
                  fr: ["Je lance une tâche de fond", "J'ai lancé une tâche de fond"],
                  de: ["Starte eine Hintergrundaufgabe", "Eine Hintergrundaufgabe gestartet"], vi: "bắt đầu một việc chạy nền" },
    improve: { en: ["Noting an improvement", "Noted an improvement"], fr: ["Je note une amélioration", "J'ai noté une amélioration"],
               de: ["Notiere eine Verbesserung", "Eine Verbesserung notiert"], vi: "ghi lại một cải tiến" },
    conversation: { en: ["Tidying the conversations", "Tidied the conversations"],
                    fr: ["Je range les conversations", "J'ai rangé les conversations"],
                    de: ["Räume die Unterhaltungen auf", "Die Unterhaltungen aufgeräumt"], vi: "dọn các cuộc trò chuyện" },
    meeting: { en: ["Reading the meeting notes", "Read the meeting notes"], fr: ["Je lis les notes de réunion", "J'ai lu les notes de réunion"],
               de: ["Lese die Meeting-Notizen", "Die Meeting-Notizen gelesen"], vi: "đọc ghi chú cuộc họp" },
    tools: { en: ["Getting the right tools", "Got the right tools"], fr: ["Je prépare les bons outils", "J'ai préparé les bons outils"],
             de: ["Hole die passenden Werkzeuge", "Die passenden Werkzeuge geholt"], vi: "chuẩn bị công cụ" },
    check: { en: ["Checking it worked", "Checked it worked"], fr: ["Je vérifie que ça a marché", "J'ai vérifié que ça a marché"],
             de: ["Prüfe, ob es geklappt hat", "Geprüft, ob es geklappt hat"], vi: "kiểm tra kết quả" },
    finish: { en: ["Wrapping up", "Wrapped up"], fr: ["Je termine", "J'ai terminé"], de: ["Schließe ab", "Abgeschlossen"], vi: "hoàn tất" },
    app_look: { en: ["Checking {app}", "Checked {app}"], fr: ["Je consulte {app}", "J'ai consulté {app}"],
                de: ["Schaue in {app}", "In {app} geschaut"], vi: "xem {app}" },
    app_use: { en: ["Using {app}", "Used {app}"], fr: ["J'utilise {app}", "J'ai utilisé {app}"],
               de: ["Nutze {app}", "{app} genutzt"], vi: "dùng {app}" },
    app_look_x: { en: ["Checking one of your apps", "Checked one of your apps"], fr: ["Je consulte une de tes applis", "J'ai consulté une de tes applis"],
                  de: ["Schaue in eine deiner Apps", "In eine deiner Apps geschaut"], vi: "xem một ứng dụng" },
    app_use_x: { en: ["Using one of your apps", "Used one of your apps"], fr: ["J'utilise une de tes applis", "J'ai utilisé une de tes applis"],
                 de: ["Nutze eine deiner Apps", "Eine deiner Apps genutzt"], vi: "dùng một ứng dụng" },
    look: { en: ["Checking something", "Checked something"], fr: ["Je vérifie quelque chose", "J'ai vérifié quelque chose"],
            de: ["Prüfe etwas", "Etwas geprüft"], vi: "kiểm tra một thứ" },
    act: { en: ["Taking a step", "Took a step"], fr: ["Je m'occupe d'une étape", "Je me suis occupé d'une étape"],
           de: ["Erledige einen Schritt", "Einen Schritt erledigt"], vi: "thực hiện một bước" }
}

// The apps behind the user's MCP servers, by their own names; another
// server is "one of your apps" (its id is a config key, not a name).
// `desktop` is Muse's own desktop server: no app to name.
var SERVERS = {
    jellyfin: "Jellyfin", seerr: "Seerr", jellyseerr: "Seerr", overseerr: "Seerr",
    "youtube-music": "YouTube Music", youtube_music: "YouTube Music", youtubemusic: "YouTube Music", ytmusic: "YouTube Music",
    spotify: "Spotify", linkedin: "LinkedIn", immich: "Immich", kdeconnect: "KDE Connect", "kde-connect": "KDE Connect",
    github: "GitHub", gitlab: "GitLab", nixos: "NixOS", discord: "Discord", slack: "Slack", zen: "Zen", notion: "Notion",
    gmail: "Gmail", calendar: "Calendar", jira: "Jira", linear: "Linear", obsidian: "Obsidian", home: "Home Assistant",
    "home-assistant": "Home Assistant", homeassistant: "Home Assistant", firefox: "Firefox", actual: "Actual Budget"
}
var MEDIA_SERVERS = /^(jellyfin|seerr|jellyseerr|overseerr|youtube[-_]?music|ytmusic|spotify|plex|emby|kodi|mpd|navidrome)$/
var READING = /^(list|get|search|find|show|status|read|query|fetch|lookup|look|describe|info|check|count|recall|view|browse|whoami|upcoming|current|now)(_|$)|_(list|get|search|find|status|info|details?|show|read|lookup)$|^(item|details|sessions|trending)$/
var READ_ACTIONS = /^(list|get|search|find|show|status|read|query|upcoming|day|range|next|lookup|count|view|info|channels|guilds|dms|members|current|recent)$/

// {server, tool, action, app} of a step's name.
function parse(name) {
    var s = String(name === undefined || name === null ? "" : name).trim()
    var out = { server: "", tool: "", action: "", app: "" }
    if (!s) return out
    var m = /^mcp__(.+?)__(.+)$/.exec(s)
    if (m) {
        out.server = m[1].toLowerCase()
        s = m[2]
    } else if ((m = /^([\w.-]+): ([\w.:@ -]+)$/.exec(s))) {
        // The chat's "server: tool".
        out.server = m[1].toLowerCase()
        s = m[2]
    }
    // A trust class: tool[:action][@app].
    var at = s.indexOf("@")
    if (at > 0) {
        out.app = s.slice(at + 1)
        s = s.slice(0, at)
    }
    var colon = s.indexOf(":")
    if (colon > 0) {
        out.action = s.slice(colon + 1).toLowerCase()
        s = s.slice(0, colon)
    }
    out.tool = s.trim().toLowerCase().replace(/[\s-]+/g, "_")
    if (out.server === "desktop") out.server = ""
    return out
}

function serverName(server) {
    return SERVERS[String(server || "").toLowerCase()] || ""
}

function _action(p, args) {
    if (p.action) return p.action
    var a = args && typeof args === "object" ? args.action : ""
    return typeof a === "string" ? a.toLowerCase() : ""
}

// The kind of step a name is (PHRASES' key).
function key(name, args) {
    var p = parse(name)
    var t = p.tool, a = _action(p, args), srv = p.server
    if (!t) return "act"
    if (/^open_tools__/.test(t)) return "tools"
    if (t === "verification") return "check"
    if (t === "finish") return "finish"
    // The built-ins.
    if (t === "websearch" || t === "web_search") return "search"
    if (t === "webfetch" || t === "web_fetch") return "web_read"
    if (t === "read" || t === "editor_read") return "file_read"
    if (t === "glob" || t === "grep" || t === "ls") return "file_find"
    if (/^(write|edit|multiedit|notebookedit)$/.test(t)) return "file_edit"
    if (t === "bash" || t === "terminal_run") return "command"
    if (t === "terminal_suggest") return "suggest"
    if (t === "terminal_list" || t === "terminal_read") return "terminal"
    if (t === "editor_open") return "editor"
    // The desktop's.
    if (/^(screenshot|screen_capture|read_screen|ui_read|ui_wait|page_screenshot)$/.test(t)) return "screen"
    if (/^(click|drag|move_pointer|double_click|right_click)$/.test(t)) return "click"
    if (t === "type_text" || t === "type") return "type"
    if (t === "press_keys" || t === "key" || t === "keys") return "keys"
    if (t === "scroll") return "scroll"
    if (/^(run_steps|run_recipe|ui_act)$/.test(t)) return "steps"
    if (t === "launch_app" || t === "open_app") return "open_app"
    if (t === "close_window") return "close_window"
    if (/^(focus_window|move_window|focus_workspace|window_action|move_window_to_workspace)$/.test(t)) return "windows"
    if (/^(list_windows|list_workspaces|list_apps|list_layouts)$/.test(t)) return "windows_look"
    if (t === "restore_layout") return "layout"
    if (t === "save_layout") return "layout_save"
    if (t === "set_theme") return "theme"
    if (t === "list_themes") return "themes_look"
    if (t === "set_wallpaper" || t === "wallpaper") return "wallpaper"
    if (t === "equalizer" || t === "volume" || t === "set_volume") return "sound"
    if (t === "do_not_disturb") return "dnd"
    if (t === "notifications") return "notif_look"
    if (/^(dismiss_notifications|clear_notification_history|snooze_notification)$/.test(t)) return "notif_clear"
    if (t === "notification_action") return "notif_act"
    if (t === "notify") return "notify"
    if (t === "calendar") return /^(add|create|new)$/.test(a) ? "calendar_add" : READ_ACTIONS.test(a) || !a ? "calendar_look" : "calendar_change"
    if (t === "tasks") return READ_ACTIONS.test(a) || !a ? "tasks_look" : "tasks_change"
    if (t === "widget") return "widgets"
    if (/^(recall|recall_about_user|habits)$/.test(t)) return "memory_look"
    if (t === "remember" || t === "remember_about_user") return "memory_save"
    if (t === "forget" || t === "forget_about_user") return "memory_forget"
    if (t === "remind" || t === "watch") return "reminder"
    if (t === "routine" || t === "standing_order") return "routine"
    if (t === "clipboard_get" || t === "clipboard_set") return "clipboard"
    if (t === "discord" || t === "slack" || srv === "discord" || srv === "slack")
        return a === "send" || /send/.test(t) ? "message_send" : a === "react" || /react/.test(t) ? "react" : "messages"
    if (t === "page_history") return "history"
    if (t === "page_go" || t === "browser_open") return "page_go"
    if (/^(page_read|page_list|page_wait|browser_read)$/.test(t)) return "web_read"
    if (t === "page_act" || t === "browser_act") return "page_act"
    if (t === "contacts") return "contacts"
    if (/^(machine_help|tool_help|system_info|get_status|shell_ipc_list)$/.test(t)) return "setup"
    if (t === "shell_ipc") return "shell_setting"
    if (/^(background_task|background_tasks|fan_out)$/.test(t)) return "background"
    if (/^(report_problem|request_feature|start_improvement|list_improvements|list_requests)$/.test(t)) return "improve"
    if (/^(conversation|delete_conversations|set_aside)$/.test(t)) return "conversation"
    if (t === "meeting_notes") return "meeting"
    // Music and videos (the desktop's player, Jellyfin, YouTube Music…).
    if (/^(media_control|mpris|player)$/.test(t)) return "music"
    if (MEDIA_SERVERS.test(srv) || /^(play|pause|resume|next|previous|skip)/.test(t)) {
        if (/^(next_up|continue_watching|recently_added|up_next|watch_?list|resume_list)$/.test(t)) return "watchlist"
        if (/queue|playlist_add/.test(t)) return "queue"
        if (/^request/.test(t)) return "request_media"
        if (/^(sessions|now_playing|playing|current|status|get_current|current_track)/.test(t)) return "playing"
        if (/^(play|resume|start)/.test(t)) return "play"
        if (/(pause|skip|next|previous|seek|shuffle|repeat|control|volume|stop)/.test(t)) return "music"
        if (/(search|find|item|details|trending|upcoming|browse|library|album|artist)/.test(t)) return "library"
    }
    if (t === "search" || /_search$|^search_/.test(t)) return srv && serverName(srv) ? "app_look" : srv ? "app_look_x" : "search"
    // Anyone else's: what it does, and the app it is.
    var reads = READING.test(t) || (a && READ_ACTIONS.test(a))
    if (srv) return serverName(srv) ? (reads ? "app_look" : "app_use") : (reads ? "app_look_x" : "app_use_x")
    return reads ? "look" : "act"
}

function _lang(lang) {
    var l = String(lang || "en").slice(0, 2).toLowerCase()
    return LANGS.indexOf(l) >= 0 ? l : "en"
}

// The phrase: form "done" (the default) or "doing".
function say(name, args, lang, form) {
    var k = key(name, args)
    var l = _lang(lang)
    var p = PHRASES[k] || PHRASES.act
    var app = serverName(parse(name).server)
    var text
    if (l === "vi") text = (form === "doing" ? "Đang " : "Đã ") + p.vi
    else text = p[l][form === "doing" ? 0 : 1]
    return text.replace("{app}", app)
}

// A short human value of the call ("K/DA MORE", "Dune"): never a path, a
// link's path, an id or a number alone.
var DETAIL_KEYS = ["title", "name", "query", "text", "summary", "content", "theme", "variant", "layout", "app", "who", "channel"]
function _human(v) {
    if (typeof v !== "string") return ""
    var s = v.replace(/\s+/g, " ").trim()
    if (!s || s.length < 2) return ""
    var url = /^[a-z][\w+.-]*:\/\/([^\/?#\s]+)/i.exec(s)
    if (url) return url[1].replace(/^www\./, "")
    if (/^(\/|~\/|\.\.?\/|[a-z]:\\)/i.test(s) || /\/[\w.-]+\//.test(s)) return ""
    if (/^[0-9a-f-]{8,}$/i.test(s) || /^[\d\s.,:-]+$/.test(s) || /^[\w-]{20,}$/.test(s)) return ""
    if (/\.desktop$/i.test(s)) s = s.replace(/\.desktop$/i, "")
    return s.length > 40 ? s.slice(0, 39) + "…" : s
}
function detail(args) {
    if (!args || typeof args !== "object") return ""
    for (var i = 0; i < DETAIL_KEYS.length; i++) {
        var v = _human(args[DETAIL_KEYS[i]])
        if (v) return v
    }
    return ""
}

// {key: value} from a step's summary: "set wallpaper (path=/x, name=Dune)",
// "path=/x, name=Dune" (meta-agent's step_summary).
function argsOf(summary) {
    var s = String(summary || "")
    var open = s.indexOf(" (")
    if (open >= 0 && /\)$/.test(s)) s = s.slice(open + 2, -1)
    var out = {}
    var parts = s.split(/, (?=[a-z_]+=)/)
    for (var i = 0; i < parts.length; i++) {
        var m = /^([a-z_]+)=([\s\S]*)$/.exec(parts[i])
        if (m) out[m[1]] = m[2]
    }
    return out
}

// The tool a chat's tool block names ("**jellyfin: next_up** {…}").
function thinkName(content) {
    var m = /^\s*\*\*([^*\n]{1,120})\*\*/.exec(String(content || ""))
    return m ? m[1].trim() : ""
}
