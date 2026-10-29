{
  config,
  options,
  pkgs,
  lib,
  osConfig ? null,
  ...
}:
# programs.nixbook-shell: runs nixbook-shell as a user service, publishes the
# settings set in Nix (applied on every activation and locked in the shell's
# Settings menu) and the machine context its AI chat and config assistant use.
let
  cfg = config.programs.nixbook-shell;
  # Imported directly, not taken from cfg.package: the `settings` option type
  # is generated from it, and option types can't depend on config.
  settingsLib = import ./lib.nix { inherit lib; };
  inherit (cfg.package.passthru) configName;

  jsonFormat = pkgs.formats.json { };

  # Everything set in Nix: applied on every activation with Nix winning, and
  # locked in the Settings menu. Keys Nix doesn't set are never touched: they
  # keep the shell's built-in default or the value chosen from the menu.
  pinnedSettings = settingsLib.pinnedSettings cfg.settings;
  pinnedPaths = settingsLib.flattenPaths [ ] pinnedSettings;
  pinnedFile = jsonFormat.generate "nixbook-shell-pinned.json" pinnedSettings;
  nixManagedFile = jsonFormat.generate "nix-managed.json" {
    paths = pinnedPaths;
  };

  # Where the running shell renders the apps' colours (services/AppTheming.qml,
  # which apps is up to Settings > Appearance): the Qt palette qt6ct/qt5ct read.
  appsDir = "${config.xdg.stateHome}/quickshell/user/generated/apps";
  terminalThemeDir = "${config.xdg.stateHome}/quickshell/user/generated/terminal";
  # A new interactive shell in a terminal other than kitty (which includes
  # the theme itself) starts with the generated colours. `$(<file)` is read
  # by the shell itself, without running cat.
  replayTerminalColors = ''
    if [[ $- == *i* && -t 1 && "$TERM" != xterm-kitty && -r "${terminalThemeDir}/sequences.txt" ]]; then
      printf '%s' "$(<"${terminalThemeDir}/sequences.txt")"
    fi
  '';

  # A failed command, for Muse (ai.initiative.terminal / recentContext,
  # src/services/RecentContext.qml): the last one, written to the shell's
  # runtime dir only while the shell made terminal-on there; the command
  # and its exit code, never its output; not Ctrl+C, nor a command starting
  # with a space. The same command working after it failed goes to
  # terminal-fixed (the desktop mascot's little jump).
  failedCommandZsh = ''
    if [[ -o interactive ]]; then
      zmodload zsh/datetime 2>/dev/null
      __nixbook_cmd=""
      __nixbook_failed=""
      __nixbook_preexec() { __nixbook_cmd="$1"; }
      __nixbook_precmd() {
        local code=$? cmd=$__nixbook_cmd dir="''${XDG_RUNTIME_DIR:-/run/user/$UID}/nixbook-shell"
        __nixbook_cmd=""
        [[ -n $cmd && $cmd != " "* && -e $dir/terminal-on ]] || return 0
        cmd=''${cmd//$'\n'/ }
        if (( code == 0 )); then
          [[ $cmd == "$__nixbook_failed" ]] || return 0
          __nixbook_failed=""
          printf '%s\t%s\t%s\t%s\n' "$EPOCHSECONDS" 0 "$PWD" "''${cmd//$'\t'/ }" >| "$dir/terminal-fixed"
          return 0
        fi
        (( code != 130 && code != 148 )) || return 0
        __nixbook_failed=$cmd
        printf '%s\t%s\t%s\t%s\n' "$EPOCHSECONDS" "$code" "$PWD" "''${cmd//$'\t'/ }" >| "$dir/terminal-failed"
      }
      autoload -Uz add-zsh-hook
      add-zsh-hook preexec __nixbook_preexec
      add-zsh-hook precmd __nixbook_precmd
    fi
  '';
  failedCommandBash = ''
    if [[ $- == *i* ]]; then
      __nixbook_last=""
      __nixbook_failed=""
      __nixbook_precmd() {
        local code=$? dir="''${XDG_RUNTIME_DIR:-/run/user/$UID}/nixbook-shell" n cmd
        [[ -e $dir/terminal-on ]] || return 0
        read -r n cmd < <(HISTTIMEFORMAT= history 1)
        # No new command (an empty line), or one kept out of the history.
        [[ $n != "$__nixbook_last" ]] || return 0
        __nixbook_last=$n
        [[ -n $cmd ]] || return 0
        if (( code == 0 )); then
          [[ $cmd == "$__nixbook_failed" ]] || return 0
          __nixbook_failed=""
          printf '%s\t%s\t%s\t%s\n' "$(date +%s)" 0 "$PWD" "''${cmd//$'\t'/ }" >| "$dir/terminal-fixed"
          return 0
        fi
        (( code != 130 && code != 148 )) || return 0
        __nixbook_failed=$cmd
        printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$code" "$PWD" "''${cmd//$'\t'/ }" >| "$dir/terminal-failed"
      }
      PROMPT_COMMAND="__nixbook_precmd''${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    fi
  '';

  # Neovim keymaps from an evaluated nixvim configuration
  # (`programs.nixvim`, when its Home Manager module is imported): read after
  # every override, so they are the keys Neovim really gets. Only these
  # fields are read (a keymap's removed `lua` option throws when touched).
  nixvim = config.programs.nixvim or null;
  nixvimEnabled = nixvim != null && (nixvim.enable or false);
  nixvimKeymap =
    scope: km:
    let
      action = km.action or null;
      lspBuf = km.lspBufAction or null;
    in
    {
      inherit (km) key;
      inherit scope;
      mode = km.mode or "n";
      action =
        if lspBuf != null then
          "vim.lsp.buf.${lspBuf}()"
        else if builtins.isAttrs action then
          action.__raw or (builtins.toJSON action)
        else
          action;
      lua = lspBuf != null || builtins.isAttrs action;
      desc = km.options.desc or null;
    };
  # "after/ftplugin/markdown.lua" -> "filetype:markdown"
  nixvimFileScope =
    name:
    let
      ft = builtins.match "(after/)?ftplugin/([^/]+)\\.(lua|vim)" name;
    in
    if ft != null then "filetype:${builtins.elemAt ft 1}" else "file:${name}";
  nixvimKeymaps = lib.optionals nixvimEnabled (
    map (nixvimKeymap null) (nixvim.keymaps or [ ])
    ++ lib.concatLists (
      lib.mapAttrsToList (event: map (nixvimKeymap "event:${event}")) (nixvim.keymapsOnEvents or { })
    )
    ++ map (nixvimKeymap "event:LspAttach") (nixvim.lsp.keymaps or [ ])
    ++ lib.concatLists (
      lib.mapAttrsToList (name: file: map (nixvimKeymap (nixvimFileScope name)) (file.keymaps or [ ])) (
        nixvim.files or { }
      )
    )
  );

  names = pkgList: lib.unique (lib.sort lib.lessThan (map lib.getName pkgList));

  # The operating system as configured, for questions about it ("which
  # kernel?", "is bluetooth on?", "what is my keyboard layout?"). Read from
  # the evaluated NixOS (osConfig) and Home Manager configurations; every
  # lookup has a fallback, so it evaluates on any NixOS release and under
  # standalone Home Manager (no osConfig: only the Home Manager part).
  os = osConfig;
  # Which VPN CLIs the package bundles: those the NixOS system runs, or both
  # under standalone Home Manager (no osConfig to ask).
  vpnClients = {
    withTailscale = os == null || (os.services.tailscale.enable or false);
    withNetbird = os == null || (os.services.netbird.enable or false);
  };
  osGet = path: default: if os == null then default else lib.attrByPath path default os;
  hmGet = path: default: lib.attrByPath path default config;
  osUser = config.home.username;
  pkgName =
    p:
    if p == null then
      null
    else if lib.isDerivation p then
      lib.getName p
    else
      baseNameOf (toString p);
  experimental = osGet [ "nix" "settings" "experimental-features" ] [ ];
  firstLayout = l: if l == null || l == "" then null else lib.head (lib.splitString "," l);
  # Every option set with an `enable` option, on or off (toggles.nix): the
  # NixOS ones from nixbook-shell's NixOS module (nixos-module.nix) when it is
  # imported, the Home Manager ones from this configuration's options.
  osToggles = osGet [ "nixbook-shell" "toggles" ] [ ];
  hmToggles = (import ./toggles.nix { inherit lib; }) {
    inherit options config;
    scope = "home-manager";
  };
  osInfo = {
    nixos = os != null;
    host = osGet [ "networking" "hostName" ] null;
    user = osUser;
    release = osGet [ "system" "nixos" "release" ] null;
    codeName = osGet [ "system" "nixos" "codeName" ] null;
    platform = pkgs.stdenv.hostPlatform.system;
    kernel = if os == null then null else os.boot.kernelPackages.kernel.version;
    timeZone = osGet [ "time" "timeZone" ] null;
    autoTimeZone = osGet [ "services" "automatic-timezoned" "enable" ] false;
    locale = osGet [ "i18n" "defaultLocale" ] null;
    # The compositor's own layout first (niri), else the system's.
    keyboard =
      let
        niri = hmGet [ "programs" "niri" "settings" "input" "keyboard" "xkb" ] { };
        xkb = osGet [ "services" "xserver" "xkb" ] { };
        layout = firstLayout (niri.layout or null);
      in
      if layout != null then
        {
          inherit layout;
          variant = niri.variant or "";
        }
      else
        {
          layout = firstLayout (xkb.layout or null);
          variant = xkb.variant or "";
        };
    bootloader =
      if osGet [ "boot" "lanzaboote" "enable" ] false then
        "systemd-boot (Secure Boot, lanzaboote)"
      else if osGet [ "boot" "loader" "systemd-boot" "enable" ] false then
        "systemd-boot"
      else if osGet [ "boot" "loader" "grub" "enable" ] false then
        "GRUB"
      else
        null;
    shell = pkgName (osGet [ "users" "users" osUser "shell" ] null);
    editor =
      let
        e = hmGet [ "home" "sessionVariables" "EDITOR" ] (
          osGet [ "environment" "variables" "EDITOR" ] null
        );
      in
      if e == null then null else baseNameOf (toString e);
    nix =
      let
        p = osGet [ "nix" "package" ] null;
      in
      if p == null then null else "${lib.getName p} ${lib.getVersion p}";
    flakes = lib.elem "flakes" (
      if builtins.isList experimental then experimental else lib.splitString " " experimental
    );
    users = lib.attrNames (
      lib.filterAttrs (_: u: u.isNormalUser or false) (osGet [ "users" "users" ] { })
    );
    toggles = osToggles ++ hmToggles;
  };

  # How the calendars, contacts and to-do list sync, through the shell's
  # accounts (nixbook-accounts): for the config assistant and the AI chat.
  calendarHowTo = {
    calendarConnect = {
      en = "To sync the shell's calendar, contacts and tasks with Google, open the accounts window (the person icon in a calendar or to-do widget, the Contacts or Calendar window, or `nixbook-shell ipc call accounts launch`) and add Google. The first time, it walks you through making your own Google Cloud app (about 5 minutes: a project with the People, Tasks and Calendar APIs, a published app, a Desktop client whose JSON you download); then the browser opens Google's sign-in. iCloud, Fastmail, Nextcloud or another CalDAV/CardDAV server are added in the same window with a user name and an app password. Tokens and passwords are kept in the keyring.";
      fr = "Pour synchroniser le calendrier, les contacts et les tâches du shell avec Google, ouvrez la fenêtre des comptes (l'icône de personne d'un widget calendrier ou tâches, la fenêtre Contacts ou Agenda, ou `nixbook-shell ipc call accounts launch`) et ajoutez Google. La première fois, elle vous guide pour créer votre propre application Google Cloud (environ 5 minutes : un projet avec les API People, Tasks et Calendar, une application publiée, un client Desktop dont vous téléchargez le JSON) ; ensuite le navigateur ouvre la connexion Google. iCloud, Fastmail, Nextcloud ou un autre serveur CalDAV/CardDAV s'ajoutent dans la même fenêtre avec un nom d'utilisateur et un mot de passe d'application. Jetons et mots de passe sont gardés dans le trousseau.";
      de = "Um Kalender, Kontakte und Aufgaben der Shell mit Google zu synchronisieren, öffne das Kontenfenster (das Personensymbol in einem Kalender- oder Aufgaben-Widget, das Kontakte- oder Kalenderfenster, oder `nixbook-shell ipc call accounts launch`) und füge Google hinzu. Beim ersten Mal führt es dich durch das Anlegen einer eigenen Google-Cloud-App (etwa 5 Minuten: ein Projekt mit den People-, Tasks- und Calendar-APIs, eine veröffentlichte App, ein Desktop-Client, dessen JSON du herunterlädst); danach öffnet der Browser die Google-Anmeldung. iCloud, Fastmail, Nextcloud oder ein anderer CalDAV/CardDAV-Server werden im selben Fenster mit Benutzername und App-Passwort hinzugefügt. Tokens und Passwörter liegen im Schlüsselbund.";
      vi = "Để đồng bộ lịch, danh bạ và công việc của shell với Google, mở cửa sổ tài khoản (biểu tượng người trong widget lịch hoặc công việc, cửa sổ Danh bạ hoặc Lịch, hoặc `nixbook-shell ipc call accounts launch`) và thêm Google. Lần đầu, cửa sổ hướng dẫn bạn tạo ứng dụng Google Cloud của riêng mình (khoảng 5 phút: một dự án bật các API People, Tasks và Calendar, một ứng dụng đã xuất bản, một client Desktop có tệp JSON để tải về); sau đó trình duyệt mở trang đăng nhập Google. iCloud, Fastmail, Nextcloud hoặc máy chủ CalDAV/CardDAV khác được thêm trong cùng cửa sổ bằng tên người dùng và mật khẩu ứng dụng. Token và mật khẩu được giữ trong keyring.";
    };
    calendarOtherAccounts = {
      en = "Accounts are added and removed in the accounts window (`nixbook-shell ipc call accounts launch`): Google, iCloud, Fastmail, Nextcloud or any CalDAV/CardDAV server (a user name and an app password; iCloud and Fastmail need an app password made in their settings). Several accounts work together: their calendars, contacts and task lists show side by side. Removing an account takes its data out of the shell, not out of the account. From a terminal: `nixbook-accounts status`, `nixbook-accounts add google`, `nixbook-accounts remove <account>`.";
      fr = "Les comptes s'ajoutent et se retirent dans la fenêtre des comptes (`nixbook-shell ipc call accounts launch`) : Google, iCloud, Fastmail, Nextcloud ou tout serveur CalDAV/CardDAV (un nom d'utilisateur et un mot de passe d'application ; iCloud et Fastmail demandent un mot de passe d'application créé dans leurs réglages). Plusieurs comptes fonctionnent ensemble : leurs calendriers, contacts et listes de tâches s'affichent côte à côte. Retirer un compte enlève ses données du shell, pas du compte. Depuis un terminal : `nixbook-accounts status`, `nixbook-accounts add google`, `nixbook-accounts remove <compte>`.";
      de = "Konten werden im Kontenfenster hinzugefügt und entfernt (`nixbook-shell ipc call accounts launch`): Google, iCloud, Fastmail, Nextcloud oder jeder CalDAV/CardDAV-Server (Benutzername und App-Passwort; iCloud und Fastmail brauchen ein App-Passwort aus ihren Einstellungen). Mehrere Konten arbeiten zusammen: ihre Kalender, Kontakte und Aufgabenlisten erscheinen nebeneinander. Ein Konto zu entfernen nimmt seine Daten aus der Shell, nicht aus dem Konto. Im Terminal: `nixbook-accounts status`, `nixbook-accounts add google`, `nixbook-accounts remove <konto>`.";
      vi = "Tài khoản được thêm và gỡ trong cửa sổ tài khoản (`nixbook-shell ipc call accounts launch`): Google, iCloud, Fastmail, Nextcloud hoặc bất kỳ máy chủ CalDAV/CardDAV nào (tên người dùng và mật khẩu ứng dụng; iCloud và Fastmail cần mật khẩu ứng dụng tạo trong phần cài đặt của chúng). Nhiều tài khoản dùng cùng lúc: lịch, danh bạ và danh sách công việc của chúng hiện cạnh nhau. Gỡ một tài khoản chỉ xóa dữ liệu khỏi shell, không xóa khỏi tài khoản. Từ terminal: `nixbook-accounts status`, `nixbook-accounts add google`, `nixbook-accounts remove <tài-khoản>`.";
    };
    calendarEvents = {
      en = "Calendar events show as dots in the sidebar, desktop and bar clock calendars; the Next Event bar widget and desktop widget (desktop right click > Widgets) show the next ones, with a Join button for meetings. The Calendar window (launcher entry Calendar, a click on the bar clock or a calendar day, `nixbook-shell ipc call calendar launch`) shows the month and each day's events; an event opens in its editor (title, time, calendar, repeat, reminders, place; for a recurring event, this occurrence or all of them), New (Ctrl+N) adds one. Changes go to the event's account at once; the shell syncs every 30 minutes (setting `calendar.refreshMinutes`), and the sync button (the sidebar calendar's header, the Calendar window, F5) syncs now.";
      fr = "Les événements du calendrier apparaissent en points dans les calendriers du panneau latéral, du bureau et de l'horloge de la barre ; le widget de barre et le widget de bureau Prochain événement (clic droit sur le bureau > Widgets) montrent les prochains, avec un bouton Rejoindre pour les réunions. La fenêtre Agenda (entrée Calendar du lanceur, un clic sur l'horloge de la barre ou un jour du calendrier, `nixbook-shell ipc call calendar launch`) montre le mois et les événements de chaque jour ; un événement s'ouvre dans son éditeur (titre, heure, calendrier, répétition, rappels, lieu ; pour un événement récurrent, cette occurrence ou toutes), Nouveau (Ctrl+N) en ajoute un. Les modifications partent tout de suite vers le compte de l'événement ; le shell synchronise toutes les 30 minutes (réglage `calendar.refreshMinutes`), et le bouton de synchronisation (en-tête du calendrier du panneau latéral, fenêtre Agenda, F5) synchronise tout de suite.";
      de = "Kalendertermine erscheinen als Punkte in den Kalendern der Seitenleiste, des Desktops und der Leistenuhr; das Leisten- und das Desktop-Widget Nächster Termin (Rechtsklick auf den Desktop > Widgets) zeigen die nächsten, mit einem Beitreten-Knopf für Besprechungen. Das Kalenderfenster (Starter-Eintrag Calendar, ein Klick auf die Leistenuhr oder einen Kalendertag, `nixbook-shell ipc call calendar launch`) zeigt den Monat und die Termine jedes Tages; ein Termin öffnet sich im Editor (Titel, Zeit, Kalender, Wiederholung, Erinnerungen, Ort; bei wiederkehrenden Terminen dieses Vorkommen oder alle), Neu (Strg+N) legt einen an. Änderungen gehen sofort an das Konto des Termins; die Shell synchronisiert alle 30 Minuten (Einstellung `calendar.refreshMinutes`), und der Synchronisieren-Knopf (Kopf des Seitenleisten-Kalenders, Kalenderfenster, F5) synchronisiert sofort.";
      vi = "Sự kiện lịch hiện thành chấm trong lịch ở thanh bên, màn hình nền và đồng hồ trên thanh; widget Sự kiện tiếp theo trên thanh và trên màn hình nền (chuột phải màn hình nền > Widgets) hiện các sự kiện sắp tới, có nút Tham gia cho cuộc họp. Cửa sổ Lịch (mục Calendar trong trình khởi chạy, bấm vào đồng hồ trên thanh hoặc một ngày trong lịch, `nixbook-shell ipc call calendar launch`) hiện cả tháng và sự kiện từng ngày; một sự kiện mở trong trình chỉnh sửa (tiêu đề, thời gian, lịch, lặp lại, nhắc nhở, địa điểm; với sự kiện lặp lại: lần này hoặc tất cả), Mới (Ctrl+N) thêm sự kiện. Thay đổi được gửi ngay đến tài khoản của sự kiện; shell đồng bộ mỗi 30 phút (cài đặt `calendar.refreshMinutes`), và nút đồng bộ (đầu lịch thanh bên, cửa sổ Lịch, F5) đồng bộ ngay.";
    };
    calendarReminders = {
      en = "Calendar reminders are the shell's own notifications (app \"Calendar\"): one at each reminder time of an event (its own reminders, else its calendar's defaults, as set in Google Calendar or on the server), with Join (a meeting link), Snooze 5 min and Open (the Calendar window on that day); it stays until handled and respects Do Not Disturb. An event's reminders are set in its editor (none, at the start, 5, 10, 30 minutes, 1 hour, 1 day before). A reminder missed while the shell wasn't running shows if at most 10 minutes late.";
      fr = "Les rappels du calendrier sont des notifications du shell lui-même (application « Calendar ») : une à chaque horaire de rappel d'un événement (ses propres rappels, sinon ceux par défaut de son calendrier, tels que réglés dans Google Agenda ou sur le serveur), avec Rejoindre (lien de réunion), Reporter 5 min et Ouvrir (la fenêtre Agenda sur ce jour) ; elle reste jusqu'à ce qu'on la traite et respecte Ne pas déranger. Les rappels d'un événement se règlent dans son éditeur (aucun, au début, 5, 10, 30 minutes, 1 heure, 1 jour avant). Un rappel manqué pendant que le shell ne tournait pas s'affiche s'il a au plus 10 minutes de retard.";
      de = "Kalendererinnerungen sind Benachrichtigungen der Shell selbst (App „Calendar“): eine zu jeder Erinnerungszeit eines Termins (seine eigenen Erinnerungen, sonst die Standardwerte seines Kalenders, wie in Google Kalender oder auf dem Server eingestellt), mit Beitreten (Besprechungslink), 5 Min. schlummern und Öffnen (das Kalenderfenster an diesem Tag); sie bleibt, bis sie erledigt ist, und respektiert Nicht stören. Die Erinnerungen eines Termins stellst du in seinem Editor ein (keine, zu Beginn, 5, 10, 30 Minuten, 1 Stunde, 1 Tag vorher). Eine verpasste Erinnerung, während die Shell nicht lief, erscheint, wenn sie höchstens 10 Minuten zu spät ist.";
      vi = "Nhắc nhở lịch là thông báo của chính shell (ứng dụng \"Calendar\"): một thông báo vào mỗi thời điểm nhắc của sự kiện (nhắc nhở riêng của sự kiện, nếu không thì mặc định của lịch, như đã đặt trong Google Lịch hoặc trên máy chủ), có nút Tham gia (liên kết họp), Báo lại 5 phút và Mở (cửa sổ Lịch vào ngày đó); thông báo ở lại đến khi được xử lý và tôn trọng chế độ Không làm phiền. Nhắc nhở của sự kiện được đặt trong trình chỉnh sửa (không có, lúc bắt đầu, 5, 10, 30 phút, 1 giờ, 1 ngày trước). Nhắc nhở bị lỡ khi shell không chạy vẫn hiện nếu trễ không quá 10 phút.";
    };
    calendarTasks = {
      en = "The to-do list (sidebar, desktop widget, bar clock popup, the launcher's add task) is your accounts' task lists (Google Tasks, the to-do lists of a CalDAV server such as iCloud's Reminders) once an account is added: adding, ticking, moving and deleting a task changes it in its account, new tasks go to the first task list, and finished tasks stay listed for 14 days. Without an account it is a local list.";
      fr = "La liste de tâches (panneau latéral, widget du bureau, popup de l'horloge, l'ajout de tâche du lanceur) est formée des listes de tâches de vos comptes (Google Tasks, les listes de tâches d'un serveur CalDAV comme les Rappels d'iCloud) dès qu'un compte est ajouté : ajouter, cocher, déplacer ou supprimer une tâche la modifie dans son compte, les nouvelles tâches vont dans la première liste, et les tâches terminées restent affichées 14 jours. Sans compte, c'est une liste locale.";
      de = "Die Aufgabenliste (Seitenleiste, Desktop-Widget, Uhr-Popup der Leiste, Aufgabe hinzufügen im Starter) besteht aus den Aufgabenlisten deiner Konten (Google Tasks, die Aufgabenlisten eines CalDAV-Servers wie die Erinnerungen von iCloud), sobald ein Konto hinzugefügt ist: Hinzufügen, Abhaken, Verschieben und Löschen ändert die Aufgabe in ihrem Konto, neue Aufgaben landen in der ersten Aufgabenliste, und erledigte bleiben 14 Tage sichtbar. Ohne Konto ist es eine lokale Liste.";
      vi = "Danh sách công việc (thanh bên, widget màn hình nền, popup đồng hồ trên thanh, thêm công việc từ trình khởi chạy) là các danh sách công việc của tài khoản bạn (Google Tasks, danh sách việc của máy chủ CalDAV như Lời nhắc của iCloud) khi đã thêm tài khoản: thêm, đánh dấu xong, chuyển và xóa công việc sẽ thay đổi trong tài khoản của nó, công việc mới vào danh sách đầu tiên, và công việc đã xong vẫn hiện trong 14 ngày. Khi chưa có tài khoản, đó là danh sách cục bộ.";
    };
    calendarTroubleshoot = {
      en = "If the calendar, contacts or to-do list aren't synced, open the accounts window (`nixbook-shell ipc call accounts launch`): an account that needs signing in again says so (Sign in). From a terminal, `nixbook-accounts status` shows each account and its last sync failure, and `nixbook-accounts calendar sync`, `contacts sync` or `tasks sync` sync now (their error, if any, is printed). The local copies are in ~/.local/state/nixbook-accounts/.";
      fr = "Si le calendrier, les contacts ou la liste de tâches ne se synchronisent pas, ouvrez la fenêtre des comptes (`nixbook-shell ipc call accounts launch`) : un compte à reconnecter le signale (Se connecter). Depuis un terminal, `nixbook-accounts status` montre chaque compte et son dernier échec de synchronisation, et `nixbook-accounts calendar sync`, `contacts sync` ou `tasks sync` synchronisent tout de suite (en affichant l'erreur s'il y en a une). Les copies locales sont dans ~/.local/state/nixbook-accounts/.";
      de = "Wenn Kalender, Kontakte oder Aufgabenliste nicht synchronisiert werden, öffne das Kontenfenster (`nixbook-shell ipc call accounts launch`): ein Konto, das neu angemeldet werden muss, sagt es (Anmelden). Im Terminal zeigt `nixbook-accounts status` jedes Konto und seinen letzten Synchronisierungsfehler, und `nixbook-accounts calendar sync`, `contacts sync` oder `tasks sync` synchronisieren sofort (mit dem Fehler, falls einer auftritt). Die lokalen Kopien liegen in ~/.local/state/nixbook-accounts/.";
      vi = "Nếu lịch, danh bạ hoặc danh sách công việc không đồng bộ, mở cửa sổ tài khoản (`nixbook-shell ipc call accounts launch`): tài khoản cần đăng nhập lại sẽ báo (Đăng nhập). Từ terminal, `nixbook-accounts status` hiện từng tài khoản và lỗi đồng bộ gần nhất, và `nixbook-accounts calendar sync`, `contacts sync` hoặc `tasks sync` đồng bộ ngay (in ra lỗi nếu có). Bản sao cục bộ nằm trong ~/.local/state/nixbook-accounts/.";
    };
  };

  # The shell's own features (themes, notifications, the chat panel): for
  # the config assistant and the AI chat. Keep these up to date with every
  # feature added or changed (AGENTS.md).
  shellHowTo = {
    themeSwitch = {
      en = "To change the shell's theme, open Settings > Appearance > Theme (or right click the desktop > Theme) and pick Material (colours from the wallpaper), Persona (Persona 5 Royal, 3 Reload or 4 Revival) Chiikawa (Chiikawa, Usagi or Momonga), Cyberpunk 2077 (Yellow or Red) or Studio Ghibli (My Neighbor Totoro, Spirited Away or Princess Mononoke), then its variant. Each theme keeps its own variant and options (palette, animations, shapes, fonts); in Nix it is programs.nixbook-shell.settings.appearance.theme and appearance.<theme>.variant.";
      fr = "Pour changer le thème du shell, ouvrez Paramètres > Apparence > Thème (ou clic droit sur le bureau > Thème) et choisissez Material (couleurs du fond d'écran), Persona (Persona 5 Royal, 3 Reload ou 4 Revival) Chiikawa (Chiikawa, Usagi ou Momonga), Cyberpunk 2077 (Yellow ou Red) ou Studio Ghibli (Mon voisin Totoro, Le Voyage de Chihiro ou Princesse Mononoké), puis sa variante. Chaque thème garde sa variante et ses options (palette, animations, formes, polices) ; dans Nix, c'est programs.nixbook-shell.settings.appearance.theme et appearance.<thème>.variant.";
      de = "Um das Design der Shell zu ändern, öffne Einstellungen > Darstellung > Design (oder Rechtsklick auf den Desktop > Design) und wähle Material (Farben aus dem Hintergrundbild), Persona (Persona 5 Royal, 3 Reload oder 4 Revival) Chiikawa (Chiikawa, Usagi oder Momonga), Cyberpunk 2077 (Yellow oder Red) oder Studio Ghibli (Mein Nachbar Totoro, Chihiros Reise ins Zauberland oder Prinzessin Mononoke), dann seine Variante. Jedes Design behält seine Variante und Optionen (Palette, Animationen, Formen, Schriften); in Nix ist es programs.nixbook-shell.settings.appearance.theme und appearance.<design>.variant.";
      vi = "Để đổi giao diện (theme) của shell, mở Cài đặt > Giao diện > Theme (hoặc chuột phải màn hình nền > Theme) và chọn Material (màu theo hình nền), Persona (Persona 5 Royal, 3 Reload hoặc 4 Revival) Chiikawa (Chiikawa, Usagi hoặc Momonga), Cyberpunk 2077 (Yellow hoặc Red) hoặc Studio Ghibli (Hàng xóm của tôi là Totoro, Vùng đất linh hồn hoặc Công chúa Mononoke), rồi chọn biến thể. Mỗi theme giữ biến thể và tùy chọn riêng (bảng màu, hiệu ứng, hình dạng, phông chữ); trong Nix là programs.nixbook-shell.settings.appearance.theme và appearance.<theme>.variant.";
    };
    themeWallpaper = {
      en = "Each theme variant keeps its own desktop, lock screen and login screen wallpapers: switching theme or variant puts them back (the Chiikawa, Cyberpunk and Studio Ghibli variants start with their own desktop wallpaper), and a wallpaper picked while in a variant becomes that variant's. Settings > Appearance > Theme has a table of every variant: click a cell to choose its desktop, lock or login wallpaper, the × to unset it (the lock screen then uses the desktop wallpaper, the login screen the lock screen's). A switch there turns it off (appearance.wallpaperPerTheme).";
      fr = "Chaque variante de thème garde ses fonds d'écran du bureau, de l'écran de verrouillage et de l'écran de connexion : changer de thème ou de variante les remet (les variantes Chiikawa, Cyberpunk et Studio Ghibli commencent avec leur propre fond de bureau), et un fond choisi dans une variante devient le sien. Paramètres > Apparence > Thème contient un tableau de toutes les variantes : cliquez sur une case pour choisir son fond de bureau, de verrouillage ou de connexion, sur le × pour le retirer (le verrouillage reprend alors le fond du bureau, la connexion celui du verrouillage). Un interrupteur le désactive (appearance.wallpaperPerTheme).";
      de = "Jede Designvariante behält ihre eigenen Hintergrundbilder für Desktop, Sperrbildschirm und Anmeldebildschirm: Beim Wechsel von Design oder Variante kommen sie zurück (die Chiikawa-, Cyberpunk- und Studio-Ghibli-Varianten starten mit ihrem eigenen Desktop-Bild), und ein in einer Variante gewähltes Bild wird zu ihrem. Einstellungen > Darstellung > Design enthält eine Tabelle aller Varianten: Klick auf eine Zelle wählt ihr Desktop-, Sperr- oder Anmeldebild, das × entfernt es (der Sperrbildschirm nutzt dann das Desktop-Bild, die Anmeldung das des Sperrbildschirms). Ein Schalter schaltet es ab (appearance.wallpaperPerTheme).";
      vi = "Mỗi biến thể theme giữ hình nền riêng cho màn hình nền, màn hình khóa và màn hình đăng nhập: đổi theme hoặc biến thể sẽ đặt lại chúng (các biến thể Chiikawa, Cyberpunk và Studio Ghibli bắt đầu với hình nền riêng), và hình chọn khi đang ở một biến thể sẽ thành của biến thể đó. Cài đặt > Giao diện > Theme có bảng mọi biến thể: bấm vào ô để chọn hình nền màn hình nền, khóa hoặc đăng nhập, bấm × để bỏ (màn hình khóa khi đó dùng hình nền màn hình nền, màn hình đăng nhập dùng hình của màn hình khóa). Một công tắc để tắt (appearance.wallpaperPerTheme).";
    };
    wallpaperFolders = {
      en = "In the wallpaper selector (Mod+W), click a folder to open it; the back arrow beside the title goes back to the previous folder (also Alt+Left or the mouse's back button), Alt+Right goes forward again and Alt+Up opens the parent folder.";
      fr = "Dans le sélecteur de fonds d'écran (Mod+W), cliquez sur un dossier pour l'ouvrir ; la flèche retour à côté du titre revient au dossier précédent (aussi Alt+Gauche ou le bouton précédent de la souris), Alt+Droite avance de nouveau et Alt+Haut ouvre le dossier parent.";
      de = "In der Hintergrundbild-Auswahl (Mod+W) öffnet ein Klick einen Ordner; der Zurück-Pfeil neben dem Titel geht zum vorherigen Ordner zurück (auch Alt+Links oder die Zurück-Taste der Maus), Alt+Rechts wieder vorwärts und Alt+Hoch öffnet den übergeordneten Ordner.";
      vi = "Trong trình chọn hình nền (Mod+W), bấm vào một thư mục để mở; mũi tên quay lại cạnh tiêu đề trở về thư mục trước (hoặc Alt+Trái, hay nút quay lại của chuột), Alt+Phải đi tiếp và Alt+Lên mở thư mục cha.";
    };
    themeSounds = {
      en = "Each theme has its own notification sounds: Persona 5's chime and cut-in effect in Material and Persona 5 (the Velvet Room's chime and the Evoker in Persona 3 Reload, the Midnight Channel's TV in Persona 4), the characters' chimes and little voices in Chiikawa, a message ping and the Relic malfunctioning in Cyberpunk 2077, the films' own sounds recreated in Studio Ghibli (raindrops on an umbrella and the forest spirit's roar, the bathhouse bell and drum, the kodama's rattle and the wolf's howl). A sound file set in Settings > General > Sounds (notification) or in the cut-in settings replaces the theme's.";
      fr = "Chaque thème a ses propres sons de notification : le carillon et l'effet de cut-in de Persona 5 en Material et Persona 5 (le carillon de la Velvet Room et l'Evoker dans Persona 3 Reload, la télé de la Midnight Channel dans Persona 4), les carillons et petites voix des personnages en Chiikawa, un bip de message et le Relic qui déraille en Cyberpunk 2077, les sons des films recréés en Studio Ghibli (gouttes de pluie sur un parapluie et rugissement de l'esprit de la forêt, cloche et tambour des bains, crécelle des kodamas et hurlement du loup). Un fichier son choisi dans Paramètres > Général > Sons (notification) ou dans les réglages du cut-in remplace celui du thème.";
      de = "Jedes Design hat eigene Benachrichtigungstöne: Persona 5s Glockenton und Cut-in-Effekt in Material und Persona 5 (der Klang des Velvet Room und der Evoker in Persona 3 Reload, der Fernseher des Midnight Channel in Persona 4), die Töne und kleinen Stimmen der Figuren in Chiikawa, ein Nachrichtenton und das gestörte Relic in Cyberpunk 2077, die Klänge der Filme nachgebaut in Studio Ghibli (Regentropfen auf einem Schirm und das Brüllen des Waldgeists, Glocke und Trommel des Badehauses, das Klappern der Kodama und das Heulen des Wolfs). Eine in Einstellungen > Allgemein > Töne (Benachrichtigung) oder in den Cut-in-Einstellungen gesetzte Tondatei ersetzt den des Designs.";
      vi = "Mỗi theme có âm thanh thông báo riêng: tiếng chuông và hiệu ứng cut-in của Persona 5 ở Material và Persona 5 (tiếng chuông Velvet Room và Evoker ở Persona 3 Reload, chiếc TV Midnight Channel ở Persona 4), tiếng chuông và giọng nói nhỏ của các nhân vật ở Chiikawa, tiếng báo tin nhắn và Relic trục trặc ở Cyberpunk 2077, âm thanh của các bộ phim được tái tạo ở Studio Ghibli (giọt mưa trên ô và tiếng gầm của thần rừng, chuông và trống nhà tắm, tiếng lắc lư của kodama và tiếng sói hú). Tệp âm thanh đặt trong Cài đặt > Chung > Âm thanh (thông báo) hoặc trong cài đặt cut-in sẽ thay âm thanh của theme.";
    };
    themeCutIns = {
      en = "Important notifications (critical ones and those matching the cut-in rules in Settings > Bar > Notifications > Cut-ins) take over the screen: a Persona cut-in in the Persona theme, the character popping up with a speech bubble in the Chiikawa theme, an incoming holocall glitching in in the Cyberpunk 2077 theme, a frosted-glass card drifting in on the wind with the film's spirit in the Studio Ghibli theme. Click runs the notification's action, right click or Escape dismisses it; the Preview button shows one. When a desktop agent clicks, types or presses keys on your desktop, a cut-in on screen is dismissed the same way so it doesn't get in its way (it stays in the notification centre).";
      fr = "Les notifications importantes (critiques, ou correspondant aux règles de cut-in dans Paramètres > Barre > Notifications > Cut-ins) prennent l'écran : un cut-in Persona dans le thème Persona, le personnage qui surgit avec une bulle dans le thème Chiikawa, un holoappel entrant qui apparaît en glitch dans le thème Cyberpunk 2077, une carte en verre dépoli portée par le vent avec l'esprit du film dans le thème Studio Ghibli. Un clic lance l'action de la notification, un clic droit ou Échap la ferme ; le bouton Aperçu en montre un. Quand un agent du bureau clique, tape ou appuie sur des touches sur votre bureau, un cut-in affiché est fermé de la même façon pour ne pas le gêner (il reste dans le centre de notifications).";
      de = "Wichtige Benachrichtigungen (kritische und solche, die zu den Cut-in-Regeln unter Einstellungen > Leiste > Benachrichtigungen > Cut-ins passen) übernehmen den Bildschirm: ein Persona-Cut-in im Persona-Design, die Figur mit einer Sprechblase im Chiikawa-Design, ein eingehender Holoanruf mit Glitch im Cyberpunk-2077-Design, eine Milchglas-Karte, die mit dem Geist des Films im Wind hereinschwebt, im Studio-Ghibli-Design. Klick führt die Aktion aus, Rechtsklick oder Escape schließt; der Vorschau-Knopf zeigt eines. Wenn ein Desktop-Agent auf deinem Desktop klickt, tippt oder Tasten drückt, wird ein angezeigtes Cut-in genauso geschlossen, damit es ihm nicht im Weg ist (es bleibt in der Benachrichtigungszentrale).";
      vi = "Thông báo quan trọng (khẩn cấp, hoặc khớp quy tắc cut-in trong Cài đặt > Thanh > Thông báo > Cut-ins) chiếm màn hình: cut-in Persona ở theme Persona, nhân vật hiện lên với bong bóng thoại ở theme Chiikawa, cuộc gọi holo đến kèm hiệu ứng glitch ở theme Cyberpunk 2077, một tấm thẻ kính mờ bay vào theo gió cùng linh hồn của bộ phim ở theme Studio Ghibli. Bấm để chạy hành động của thông báo, chuột phải hoặc Escape để đóng; nút Xem trước hiển thị một ví dụ. Khi một tác nhân màn hình bấm, gõ hoặc nhấn phím trên màn hình của bạn, cut-in đang hiện sẽ được đóng như vậy để không cản đường nó (thông báo vẫn còn trong trung tâm thông báo).";
    };
    notificationDuplicates = {
      en = "Duplicate notifications are filtered (Settings > Bar > Notifications > Duplicates, notifications.deduplicate): your phone's copy (KDE Connect) of a message a desktop app already showed is dropped, the same notification again within the window (30 minutes) replaces the earlier one, and a re-posted chat thread replaces the old one. The history is cleaned by the same rules when the shell starts; run `nixbook-shell ipc call notificationHistory dedupe` to clean it now.";
      fr = "Les notifications en double sont filtrées (Paramètres > Barre > Notifications > Doublons, notifications.deduplicate) : la copie de votre téléphone (KDE Connect) d'un message déjà affiché par une application du bureau est ignorée, la même notification revenue dans la fenêtre (30 minutes) remplace la précédente, et une conversation renvoyée remplace l'ancienne. L'historique est nettoyé selon les mêmes règles au démarrage du shell ; `nixbook-shell ipc call notificationHistory dedupe` le nettoie tout de suite.";
      de = "Doppelte Benachrichtigungen werden gefiltert (Einstellungen > Leiste > Benachrichtigungen > Duplikate, notifications.deduplicate): die Kopie deines Telefons (KDE Connect) einer Nachricht, die eine Desktop-App schon gezeigt hat, wird verworfen, dieselbe Benachrichtigung innerhalb des Zeitfensters (30 Minuten) ersetzt die frühere, und ein erneut gesendeter Chatverlauf ersetzt den alten. Der Verlauf wird beim Start der Shell nach denselben Regeln bereinigt; `nixbook-shell ipc call notificationHistory dedupe` bereinigt ihn sofort.";
      vi = "Thông báo trùng lặp được lọc (Cài đặt > Thanh > Thông báo > Trùng lặp, notifications.deduplicate): bản sao từ điện thoại (KDE Connect) của tin nhắn mà ứng dụng trên máy tính đã hiện sẽ bị bỏ, cùng một thông báo lặp lại trong khoảng thời gian (30 phút) sẽ thay thế thông báo trước, và cuộc trò chuyện được gửi lại sẽ thay thế bản cũ. Lịch sử được dọn theo cùng quy tắc khi shell khởi động; chạy `nixbook-shell ipc call notificationHistory dedupe` để dọn ngay.";
    };
    loginScreen = {
      en = "The login screen is nixbook-shell's own (on a machine with customNixOSModules.greetd enabled, it is the default as soon as a user runs nixbook-shell; customNixOSModules.greetd.greeter = \"tuigreet\" keeps the text login): it has your theme, palette, fonts, account picture, cursor and login screen wallpaper. Click an account picture under the card (or press Up / Down) to switch account, click or scroll the session pill to switch session, type the password and press Enter (a security key or fingerprint works too; the eye button shows what you typed, Esc clears it); the buttons in the corner suspend, reboot or power off. It remembers the last account and session. If it can't start, tuigreet (a text login) takes over.";
      fr = "L'écran de connexion est celui de nixbook-shell (sur une machine avec customNixOSModules.greetd, c'est le choix par défaut dès qu'un utilisateur utilise nixbook-shell ; customNixOSModules.greetd.greeter = \"tuigreet\" garde la connexion texte) : il reprend votre thème, palette, polices, photo de compte, curseur et fond d'écran de connexion. Cliquez une photo de compte sous la carte (ou Haut / Bas) pour changer de compte, cliquez ou faites défiler la pastille de session pour changer de session ; tapez le mot de passe puis Entrée (une clé de sécurité ou l'empreinte fonctionnent aussi ; le bouton œil affiche la saisie, Échap l'efface) ; les boutons dans le coin mettent en veille, redémarrent ou éteignent. Il retient le dernier compte et la dernière session. S'il ne peut pas démarrer, tuigreet (connexion en mode texte) prend le relais.";
      de = "Der Anmeldebildschirm ist der von nixbook-shell (auf einer Maschine mit customNixOSModules.greetd ist er Standard, sobald ein Benutzer nixbook-shell nutzt; customNixOSModules.greetd.greeter = \"tuigreet\" behält die Textanmeldung): mit deinem Design, deiner Palette, Schriften, Kontobild, Mauszeiger und Anmelde-Hintergrundbild. Klicke ein Kontobild unter der Karte (oder Hoch / Runter), um das Konto zu wechseln, klicke oder scrolle auf der Sitzungs-Pille, um die Sitzung zu wechseln, gib das Passwort ein und drücke Enter (Sicherheitsschlüssel oder Fingerabdruck gehen auch; der Augen-Knopf zeigt die Eingabe, Esc löscht sie); die Knöpfe in der Ecke versetzen in Bereitschaft, starten neu oder schalten aus. Er merkt sich das letzte Konto und die letzte Sitzung. Startet er nicht, übernimmt tuigreet (Textanmeldung).";
      vi = "Màn hình đăng nhập là của nixbook-shell (trên máy bật customNixOSModules.greetd, nó là mặc định ngay khi có người dùng chạy nixbook-shell; customNixOSModules.greetd.greeter = \"tuigreet\" giữ đăng nhập dạng chữ): có theme, bảng màu, phông chữ, ảnh tài khoản, con trỏ và hình nền đăng nhập của bạn. Bấm ảnh tài khoản dưới thẻ (hoặc phím Lên / Xuống) để đổi tài khoản, bấm hoặc cuộn nút phiên để đổi phiên, nhập mật khẩu rồi Enter (khóa bảo mật hoặc vân tay cũng được; nút con mắt hiện mật khẩu đã gõ, Esc xóa nó); các nút ở góc để ngủ, khởi động lại hoặc tắt máy. Nó nhớ tài khoản và phiên gần nhất. Nếu không khởi động được, tuigreet (đăng nhập dạng chữ) sẽ thay thế.";
    };
    chatPanel = {
      en = "The AI chat panel (left sidebar) has buttons for its shortcuts under its tabs: Extend (Ctrl+O) makes it wider, Pin (Ctrl+P) keeps it open beside your windows, Detach (Ctrl+D) opens the chat in a window of its own (Ctrl+D again, or Attach, puts it back). Ctrl+PageUp/PageDown switch between the chat and the translator.";
      fr = "Le panneau du chat IA (panneau latéral gauche) a sous ses onglets des boutons pour ses raccourcis : Étendre (Ctrl+O) l'élargit, Épingler (Ctrl+P) le garde ouvert à côté des fenêtres, Détacher (Ctrl+D) ouvre le chat dans sa propre fenêtre (Ctrl+D à nouveau, ou Rattacher, le remet). Ctrl+PageHaut/PageBas passent du chat au traducteur.";
      de = "Das KI-Chat-Panel (linke Seitenleiste) hat unter seinen Tabs Knöpfe für seine Tastenkürzel: Erweitern (Strg+O) macht es breiter, Anheften (Strg+P) hält es neben den Fenstern offen, Lösen (Strg+D) öffnet den Chat in einem eigenen Fenster (nochmals Strg+D oder Andocken holt ihn zurück). Strg+Bild auf/ab wechseln zwischen Chat und Übersetzer.";
      vi = "Bảng chat AI (thanh bên trái) có các nút phím tắt dưới các tab: Mở rộng (Ctrl+O) làm bảng rộng hơn, Ghim (Ctrl+P) giữ bảng mở cạnh cửa sổ, Tách (Ctrl+D) mở chat trong cửa sổ riêng (nhấn lại Ctrl+D hoặc Gắn lại để đưa về). Ctrl+PageUp/PageDown chuyển giữa chat và trình dịch.";
    };
    screenshot = {
      en = "To take a screenshot, open the screenshot selector (the Print key, or nixbook-shell ipc call region screenshot): drag a rectangle, then left click copies it to the clipboard and right click opens it for annotation. To take a whole window or a whole screen without drawing, pick Window or Screen in the toolbar at the bottom (or press W or S in the selector; press it again to go back to the rectangle): hovering a window or a screen selects it, and a click takes it. A window is captured whole, even where it is covered or off screen. Esc cancels. Screenshots are also saved to ~/Pictures/Screenshots (created if missing); change the folder, or empty it to only copy, in Settings > Services > Screenshot Path.";
      fr = "Pour faire une capture d'écran, ouvrez le sélecteur de capture (la touche Impr. écran, ou nixbook-shell ipc call region screenshot) : tracez un rectangle, puis clic gauche le copie dans le presse-papiers et clic droit l'ouvre pour l'annoter. Pour capturer une fenêtre entière ou un écran entier sans tracer, choisissez Fenêtre ou Écran dans la barre d'outils en bas (ou appuyez sur W ou S dans le sélecteur ; à nouveau pour revenir au rectangle) : survoler une fenêtre ou un écran le sélectionne, un clic le capture. Une fenêtre est capturée en entier, même cachée ou hors de l'écran. Échap annule. Les captures sont aussi enregistrées dans ~/Pictures/Screenshots (créé s'il manque) ; changez le dossier, ou videz-le pour seulement copier, dans Paramètres > Services > Screenshot Path.";
      de = "Für einen Screenshot öffne die Bildschirmauswahl (die Druck-Taste, oder nixbook-shell ipc call region screenshot): Ziehe ein Rechteck, dann kopiert ein Linksklick es in die Zwischenablage und ein Rechtsklick öffnet es zum Beschriften. Um ein ganzes Fenster oder einen ganzen Bildschirm ohne Zeichnen aufzunehmen, wähle Fenster oder Bildschirm in der Werkzeugleiste unten (oder drücke W oder S in der Auswahl; nochmals für das Rechteck): Mit der Maus über einem Fenster oder Bildschirm wird es ausgewählt, ein Klick nimmt es auf. Ein Fenster wird vollständig aufgenommen, auch wenn es verdeckt oder außerhalb des Bildschirms ist. Esc bricht ab. Screenshots werden auch in ~/Pictures/Screenshots gespeichert (wird bei Bedarf angelegt); den Ordner ändern, oder leeren, um nur zu kopieren, unter Einstellungen > Dienste > Screenshot Path.";
      vi = "Để chụp màn hình, mở bộ chọn chụp màn hình (phím Print, hoặc nixbook-shell ipc call region screenshot): kéo một hình chữ nhật, rồi chuột trái sao chép vào bộ nhớ tạm và chuột phải mở để chú thích. Để chụp cả một cửa sổ hoặc cả một màn hình mà không cần kéo, chọn Cửa sổ hoặc Màn hình trên thanh công cụ phía dưới (hoặc nhấn W hoặc S trong bộ chọn; nhấn lại để quay về hình chữ nhật): di chuột lên cửa sổ hoặc màn hình sẽ chọn nó, bấm chuột để chụp. Cửa sổ được chụp trọn vẹn, kể cả phần bị che hoặc nằm ngoài màn hình. Esc để hủy. Ảnh chụp cũng được lưu vào ~/Pictures/Screenshots (tự tạo nếu chưa có); đổi thư mục, hoặc để trống để chỉ sao chép, trong Cài đặt > Dịch vụ > Screenshot Path.";
    };
    screenRecord = {
      en = "To record the screen, press Shift+Print or click the record button in the bar (or the Record region button of the overlay, or nixbook-shell ipc call region recordWithSound): the same selector as for screenshots opens. Drag a rectangle, or pick Window or Screen in the toolbar at the bottom (or press W or S): hovering a window or a screen selects it, a click starts recording it. A window is recorded where it is shown on screen when you click (move it and the recording keeps that area); a screen is recorded whole. The desktop audio (what plays on the default output) is recorded too. Press Shift+Print or click the record button again (or the stop button) to stop: the video is then copied to the clipboard as a file (paste it into a file manager or a chat). Recordings are saved to ~/Videos; change the folder in Settings > Services > Video Recording Path.";
      fr = "Pour enregistrer l'écran, appuyez sur Maj+Impr. écran ou cliquez sur le bouton d'enregistrement de la barre (ou le bouton Enregistrer une zone de l'overlay, ou nixbook-shell ipc call region recordWithSound) : le même sélecteur que pour les captures s'ouvre. Tracez un rectangle, ou choisissez Fenêtre ou Écran dans la barre d'outils en bas (ou appuyez sur W ou S) : survoler une fenêtre ou un écran le sélectionne, un clic lance son enregistrement. Une fenêtre est enregistrée là où elle est affichée au moment du clic (si elle bouge, l'enregistrement garde cette zone) ; un écran est enregistré en entier. Le son du bureau (ce qui joue sur la sortie par défaut) est aussi enregistré. Appuyez à nouveau sur Maj+Impr. écran ou cliquez sur le bouton d'enregistrement (ou le bouton stop) pour arrêter : la vidéo est alors copiée dans le presse-papiers comme fichier (à coller dans un gestionnaire de fichiers ou un chat). Les enregistrements sont dans ~/Videos ; changez le dossier dans Paramètres > Services > Video Recording Path.";
      de = "Um den Bildschirm aufzunehmen, drücke Umschalt+Druck oder klicke auf den Aufnahmeknopf in der Leiste (oder den Knopf Bereich aufnehmen im Overlay, oder nixbook-shell ipc call region recordWithSound): Es öffnet sich dieselbe Auswahl wie für Screenshots. Ziehe ein Rechteck, oder wähle Fenster oder Bildschirm in der Werkzeugleiste unten (oder drücke W oder S): Mit der Maus über einem Fenster oder Bildschirm wird es ausgewählt, ein Klick startet die Aufnahme. Ein Fenster wird dort aufgenommen, wo es beim Klick angezeigt wird (wird es verschoben, bleibt die Aufnahme bei diesem Bereich); ein Bildschirm wird vollständig aufgenommen. Der Desktop-Ton (was auf der Standardausgabe spielt) wird mit aufgenommen. Drücke erneut Umschalt+Druck oder klicke auf den Aufnahmeknopf (oder den Stoppknopf), um zu beenden: Das Video wird dann als Datei in die Zwischenablage kopiert (in einen Dateimanager oder Chat einfügen). Aufnahmen werden in ~/Videos gespeichert; den Ordner ändern unter Einstellungen > Dienste > Video Recording Path.";
      vi = "Để quay màn hình, nhấn Shift+Print hoặc bấm nút quay trên thanh (hoặc nút Quay vùng trong overlay, hoặc nixbook-shell ipc call region recordWithSound): bộ chọn giống như khi chụp màn hình sẽ mở ra. Kéo một hình chữ nhật, hoặc chọn Cửa sổ hoặc Màn hình trên thanh công cụ phía dưới (hoặc nhấn W hoặc S): di chuột lên cửa sổ hoặc màn hình sẽ chọn nó, bấm chuột để bắt đầu quay. Cửa sổ được quay tại vị trí nó hiển thị lúc bấm (nếu di chuyển cửa sổ, bản quay vẫn giữ vùng đó); màn hình được quay toàn bộ. Âm thanh của máy (những gì phát ra ở đầu ra mặc định) cũng được thu. Nhấn lại Shift+Print hoặc bấm lại nút quay (hoặc nút dừng) để dừng: video sau đó được sao chép vào bộ nhớ tạm dưới dạng tệp (dán vào trình quản lý tệp hoặc cuộc trò chuyện). Bản quay được lưu vào ~/Videos; đổi thư mục trong Cài đặt > Dịch vụ > Video Recording Path.";
    };
    desktopControlStop = {
      en = "To stop the AI agents controlling the desktop (Muse, the AI chat, any agent using nixbook-desktop-mcp), press Mod+Shift+Escape, or click the robot in the bar (it turns into a red hand), or use the switch in Settings > Desktop agents: every agent's desktop tools are refused until you press or click again. Desktop control is paused until you first allow it, and keeps the position you left it in across reboots. In the AI chat, the send button becomes a stop button while an answer is being written, and /stop does the same.";
      fr = "Pour arrêter les agents IA qui contrôlent le bureau (Muse, le chat IA, tout agent utilisant nixbook-desktop-mcp), appuyez sur Mod+Maj+Échap, ou cliquez sur le robot dans la barre (il devient une main rouge), ou utilisez l'interrupteur dans Paramètres > Agents du bureau : les outils du bureau sont refusés à tous les agents jusqu'à un nouvel appui ou clic. Le contrôle du bureau est en pause tant que vous ne l'avez pas autorisé, et garde la position choisie après un redémarrage. Dans le chat IA, le bouton d'envoi devient un bouton d'arrêt pendant qu'une réponse s'écrit, et /stop fait de même.";
      de = "Um die KI-Agenten zu stoppen, die den Desktop steuern (Muse, der KI-Chat, jeder Agent über nixbook-desktop-mcp), drücke Mod+Umschalt+Escape, klicke auf den Roboter in der Leiste (er wird zu einer roten Hand) oder nutze den Schalter unter Einstellungen > Desktop-Agenten: Die Desktop-Werkzeuge werden allen Agenten verweigert, bis du erneut drückst oder klickst. Die Desktop-Steuerung ist pausiert, bis du sie zum ersten Mal erlaubst, und behält deine Einstellung auch nach einem Neustart. Im KI-Chat wird der Senden-Knopf zum Stopp-Knopf, während eine Antwort geschrieben wird, und /stop tut dasselbe.";
      vi = "Để dừng các tác nhân AI đang điều khiển màn hình (Muse, chat AI, mọi tác nhân dùng nixbook-desktop-mcp), nhấn Mod+Shift+Escape, hoặc bấm vào robot trên thanh (nó thành bàn tay đỏ), hoặc dùng công tắc trong Cài đặt > Tác nhân màn hình: công cụ điều khiển màn hình bị từ chối với mọi tác nhân cho đến khi bạn nhấn hoặc bấm lại. Điều khiển màn hình tạm dừng cho đến khi bạn cho phép lần đầu, và giữ nguyên lựa chọn của bạn sau khi khởi động lại. Trong chat AI, nút gửi thành nút dừng khi câu trả lời đang được viết, và /stop cũng vậy.";
    };
    museCursor = {
      en = "When Muse (or any agent using nixbook-desktop-mcp) works on your desktop, you see it: a second, glowing cursor in your theme's colours with a small Muse badge glides to each thing it clicks, drags, scrolls or types into before it acts, with a word of what it does (clicking Send, typing 42 characters, scrolling down), a ripple on each click, and corner brackets for a moment around a window or area it reads. It never takes your clicks or keys, never shows in the agent's own screenshots, and fades out a second and a half after its last step. It only shows on your desktop (not the agent's own desktop), never while desktop control is paused or AI features are off. To hide it, turn off Show Muse's cursor in Settings > Desktop agents > Desktop control.";
      fr = "Quand Muse (ou tout agent utilisant nixbook-desktop-mcp) travaille sur votre bureau, vous le voyez : un second curseur lumineux, aux couleurs de votre thème avec un petit badge Muse, glisse vers chaque chose qu'il clique, fait glisser, fait défiler ou dans laquelle il tape avant d'agir, avec un mot de ce qu'il fait (clique sur Envoyer, tape 42 caractères, défile vers le bas), une onde à chaque clic, et des crochets d'angle un instant autour d'une fenêtre ou d'une zone qu'il lit. Il ne prend jamais vos clics ni vos touches, n'apparaît jamais dans les captures de l'agent, et s'efface une seconde et demie après sa dernière étape. Il n'apparaît que sur votre bureau (pas sur le bureau de l'agent), jamais quand le contrôle du bureau est en pause ou les fonctions d'IA désactivées. Pour le masquer, désactivez Afficher le curseur de Muse dans Paramètres > Agents du bureau > Contrôle du bureau.";
      de = "Wenn Muse (oder ein anderer Agent über nixbook-desktop-mcp) auf deinem Desktop arbeitet, siehst du es: Ein zweiter, leuchtender Mauszeiger in den Farben deines Themes mit einem kleinen Muse-Abzeichen gleitet zu allem, was er anklickt, zieht, scrollt oder worin er tippt, bevor er handelt, mit einem Wort dazu, was er tut (klickt auf Senden, tippt 42 Zeichen, scrollt nach unten), einer Welle bei jedem Klick und kurz Eckklammern um ein Fenster oder einen Bereich, den er liest. Er nimmt nie deine Klicks oder Tasten, erscheint nie in den Screenshots des Agenten und blendet eineinhalb Sekunden nach seinem letzten Schritt aus. Er erscheint nur auf deinem Desktop (nicht auf dem eigenen Desktop des Agenten), nie, solange die Desktop-Steuerung pausiert ist oder die KI-Funktionen aus sind. Zum Ausblenden schalte Muses Mauszeiger zeigen unter Einstellungen > Desktop-Agenten > Desktop-Steuerung aus.";
      vi = "Khi Muse (hoặc bất kỳ tác nhân nào dùng nixbook-desktop-mcp) làm việc trên màn hình của bạn, bạn sẽ thấy: một con trỏ thứ hai phát sáng theo màu chủ đề của bạn, có huy hiệu Muse nhỏ, lướt tới từng thứ nó bấm, kéo, cuộn hoặc gõ vào trước khi hành động, kèm một chữ nói nó đang làm gì (đang bấm Gửi, đang gõ 42 ký tự, đang cuộn xuống), một gợn sóng mỗi lần bấm, và các dấu ngoặc góc thoáng qua quanh cửa sổ hoặc vùng nó đọc. Nó không bao giờ lấy cú bấm hay phím của bạn, không bao giờ hiện trong ảnh chụp màn hình của tác nhân, và mờ dần một giây rưỡi sau bước cuối. Nó chỉ hiện trên màn hình của bạn (không trên màn hình riêng của tác nhân), không bao giờ khi điều khiển màn hình đang tạm dừng hoặc các tính năng AI bị tắt. Để ẩn nó, tắt Hiện con trỏ của Muse trong Cài đặt > Tác nhân màn hình > Điều khiển màn hình.";
    };
    windowLayouts = {
      en = "To save and restore window layouts (where every window is: monitor, workspace, column and size, and the apps to reopen), press Mod+G: pick a saved layout to restore it, or type a new name to save the windows as they are. The desktop's right-click menu has a Window layouts submenu, and Settings > Window layouts lists them to restore, update, rename or delete. AI agents can save and restore them too.";
      fr = "Pour enregistrer et restaurer des dispositions de fenêtres (où est chaque fenêtre : écran, espace de travail, colonne et taille, et les applications à rouvrir), appuyez sur Mod+G : choisissez une disposition enregistrée pour la restaurer, ou tapez un nouveau nom pour enregistrer les fenêtres telles qu'elles sont. Le menu du clic droit sur le bureau a un sous-menu Dispositions de fenêtres, et Paramètres > Dispositions de fenêtres les liste pour restaurer, mettre à jour, renommer ou supprimer. Les agents IA peuvent aussi les enregistrer et les restaurer.";
      de = "Um Fensteranordnungen zu speichern und wiederherzustellen (wo jedes Fenster ist: Bildschirm, Arbeitsbereich, Spalte und Größe, und welche Apps wieder zu öffnen sind), drücke Mod+G: Wähle eine gespeicherte Anordnung zum Wiederherstellen oder gib einen neuen Namen ein, um die Fenster so zu speichern, wie sie sind. Das Rechtsklickmenü des Desktops hat ein Untermenü Fensteranordnungen, und Einstellungen > Fensteranordnungen listet sie zum Wiederherstellen, Aktualisieren, Umbenennen oder Löschen. KI-Agenten können sie ebenfalls speichern und wiederherstellen.";
      vi = "Để lưu và khôi phục bố cục cửa sổ (vị trí của từng cửa sổ: màn hình, không gian làm việc, cột và kích thước, và các ứng dụng cần mở lại), nhấn Mod+G: chọn một bố cục đã lưu để khôi phục, hoặc gõ tên mới để lưu các cửa sổ như hiện tại. Menu chuột phải trên màn hình nền có menu con Bố cục cửa sổ, và Cài đặt > Bố cục cửa sổ liệt kê chúng để khôi phục, cập nhật, đổi tên hoặc xóa. Tác nhân AI cũng có thể lưu và khôi phục chúng.";
    };
    agentPanel = {
      en = "To use Muse in the AI chat (left sidebar): Muse is nixbook's own agent (nixbook-meta-agent) on Meta's Model API. Save your Meta API key in Settings > Desktop agents > Muse in the side panel > Model provider, then pick Muse with /model muse or the Use in the side panel button there, where you also choose the model (Muse Spark is faster, Muse Wonder for the hardest tasks), the thinking effort, whether it may search the web, and which folders it may read (none by default: it reads none of your files unless you list a folder, or attach a file to a message). It can see and drive the desktop; it runs no commands and edits no files unless you turn on Command line there: it then runs commands as you (never in your terminal windows), only in the folders you allow (a sandbox; turn off Only in the allowed folders for full access), and asks in the chat before anything that changes the system or your files.";
      fr = "Pour utiliser Muse dans le chat IA (panneau de gauche) : Muse est l'agent de nixbook (nixbook-meta-agent) sur la Model API de Meta. Enregistrez votre clé API Meta dans Paramètres > Agents du bureau > Muse dans le panneau latéral > Fournisseur de modèles, puis choisissez Muse avec /model muse ou le bouton Utiliser dans le panneau latéral, où vous choisissez aussi le modèle (Muse Spark est plus rapide, Muse Wonder pour les tâches les plus difficiles), l'effort de réflexion, s'il peut chercher sur le web, et les dossiers qu'il peut lire (aucun par défaut : il ne lit aucun de vos fichiers sauf dans un dossier que vous ajoutez, ou un fichier joint à un message). Il peut voir et piloter le bureau ; il ne lance aucune commande et ne modifie aucun fichier, sauf si vous y activez Ligne de commande : il lance alors des commandes en votre nom (jamais dans vos fenêtres de terminal), seulement dans les dossiers autorisés (un bac à sable ; désactivez Seulement dans les dossiers autorisés pour un accès complet), et demande dans le chat avant tout ce qui modifie le système ou vos fichiers.";
      de = "Um Muse im KI-Chat (linke Seitenleiste) zu nutzen: Muse ist nixbooks eigener Agent (nixbook-meta-agent) auf Metas Model API. Speichere deinen Meta-API-Schlüssel unter Einstellungen > Desktop-Agenten > Muse in der Seitenleiste > Modellanbieter, dann wähle Muse mit /model muse oder dem Knopf In der Seitenleiste nutzen, wo du auch das Modell (Muse Spark ist schneller, Muse Wonder für die schwersten Aufgaben), den Denkaufwand, die Websuche und die Ordner festlegst, die Muse lesen darf (standardmäßig keine: es liest keine deiner Dateien, außer in Ordnern, die du einträgst, oder eine an eine Nachricht angehängte Datei). Muse kann den Desktop sehen und steuern; es führt keine Befehle aus und bearbeitet keine Dateien, außer du schaltest dort Kommandozeile ein: Dann führt es Befehle als du aus (nie in deinen Terminalfenstern), nur in den erlaubten Ordnern (eine Sandbox; schalte Nur in den erlaubten Ordnern aus für vollen Zugriff), und fragt im Chat, bevor es etwas am System oder an deinen Dateien ändert.";
      vi = "Để dùng Muse trong chat AI (thanh bên trái): Muse là tác nhân riêng của nixbook (nixbook-meta-agent) chạy trên Model API của Meta. Lưu khóa API Meta của bạn trong Cài đặt > Tác nhân màn hình > Muse trong bảng bên > Nhà cung cấp mô hình, rồi chọn Muse bằng /model muse hoặc nút Dùng trong bảng bên ở đó, nơi bạn cũng chọn mô hình (Muse Spark nhanh hơn, Muse Wonder cho việc khó nhất), mức suy nghĩ, có cho phép tìm kiếm web không, và những thư mục nó được đọc (mặc định không có: nó không đọc tệp nào của bạn, trừ trong thư mục bạn thêm vào hoặc tệp bạn đính kèm vào tin nhắn). Nó có thể xem và điều khiển màn hình; nó không chạy lệnh hay sửa tệp nào, trừ khi bạn bật Dòng lệnh ở đó: khi đó nó chạy lệnh với quyền của bạn (không bao giờ trong cửa sổ terminal của bạn), chỉ trong các thư mục được phép (một sandbox; tắt Chỉ trong thư mục được phép để có toàn quyền), và hỏi trong chat trước mọi việc thay đổi hệ thống hoặc tệp của bạn.";
    };
    modelProvider = {
      en = "Every AI feature talks to Meta's Model API (the Muse models) by default; to set it up: Settings > Desktop agents > Muse in the side panel > Model provider. Create an API key in Meta's Model API dashboard (dev.meta.ai), paste it and click Save (it is kept in your keyring), then Test. Meta's models then answer everywhere an agent works for you: the side panel (shown as Muse), the speech bubble, speaking on its own, the memory passes, routines, the equalizer agent and the fixes it makes. The main model is muse-spark-1.3, the small one (quick answers and background passes) muse-spark-1.3 and the big one muse-wonder-1.0, unless you name other models there. Other takes any server with a compatible Messages API (https, or http on this computer), with its own key.";
      fr = "Toutes les fonctions d'IA parlent à la Model API de Meta (les modèles Muse) par défaut ; pour la configurer : Paramètres > Agents du bureau > Muse dans le panneau latéral > Fournisseur de modèles. Créez une clé API dans le tableau de bord de la Model API de Meta (dev.meta.ai), collez-la et cliquez Enregistrer (elle est gardée dans votre trousseau), puis Tester. Les modèles de Meta répondent alors partout où un agent travaille pour vous : le panneau latéral (affiché Muse), la bulle, quand il parle de lui-même, les passes de mémoire, les routines, l'agent d'égaliseur et les correctifs qu'il fait. Le modèle principal est muse-spark-1.3, le petit (réponses rapides et passes en arrière-plan) muse-spark-1.3 et le grand muse-wonder-1.0, sauf si vous y nommez d'autres modèles. Autre accepte tout serveur avec une API Messages compatible (https, ou http sur cet ordinateur), avec sa propre clé.";
      de = "Alle KI-Funktionen sprechen standardmäßig mit Metas Model API (den Muse-Modellen); zum Einrichten: Einstellungen > Desktop-Agenten > Muse in der Seitenleiste > Modellanbieter. Erstelle einen API-Schlüssel im Dashboard von Metas Model API (dev.meta.ai), füge ihn ein und klicke Speichern (er bleibt in deinem Schlüsselbund), dann Testen. Metas Modelle antworten dann überall, wo ein Agent für dich arbeitet: in der Seitenleiste (angezeigt als Muse), in der Sprechblase, wenn es von sich aus spricht, bei den Gedächtnisdurchläufen, Routinen, dem Equalizer-Agenten und den Korrekturen, die es macht. Das Hauptmodell ist muse-spark-1.3, das kleine (schnelle Antworten und Hintergrunddurchläufe) muse-spark-1.3 und das große muse-wonder-1.0, außer du nennst dort andere Modelle. Andere nimmt jeden Server mit einer kompatiblen Messages-API (https, oder http auf diesem Rechner), mit eigenem Schlüssel.";
      vi = "Mọi tính năng AI mặc định nói chuyện với Model API của Meta (các mô hình Muse); để thiết lập: Cài đặt > Tác nhân màn hình > Muse trong bảng bên > Nhà cung cấp mô hình. Tạo khóa API trong bảng điều khiển Model API của Meta (dev.meta.ai), dán vào và bấm Lưu (khóa được giữ trong kho khóa của bạn), rồi bấm Thử. Khi đó mô hình của Meta trả lời ở mọi nơi một tác nhân làm việc cho bạn: bảng bên (hiển thị Muse), bong bóng thoại, khi nó tự lên tiếng, các lượt ghi nhớ, quy trình, tác nhân bộ cân bằng âm và các bản sửa nó làm. Mô hình chính là muse-spark-1.3, mô hình nhỏ (trả lời nhanh và các lượt chạy nền) là muse-spark-1.3 và mô hình lớn là muse-wonder-1.0, trừ khi bạn ghi mô hình khác ở đó. Khác nhận mọi máy chủ có API Messages tương thích (https, hoặc http trên máy này), với khóa riêng của nó.";
    };
    quickAi = {
      en = "Everything you ask the AI happens in Muse's speech bubble (Mod+C, or Mod+T to talk): Muse's agent answers there, kept running for the bubble on the quick model (Settings > Desktop agents > Accuracy and models), and Explain, Summarize, Translate and the screen region's questions are answered by the small model called directly in a second or two. Plain commands like pause the music or open Firefox are done at once; anything else is done by Muse with the desktop tools, the bubble saying which step it is on, with Allow / No only before really risky steps (deleting your data, sending messages for you); closing windows, adding events or playing music just happen. Follow-ups in the bubble keep the conversation; expand it to go on in the side panel: the same conversation and the same agent session, nothing repeated. In the screenshot app (Print), turn on Ask AI (its toolbar button, or A) and draw a region or pick a window or a screen: the bubble offers What's this, Explain, Summarize, Translate and Copy text, or type your question. Also ! in the launcher, and Summarize / Suggest replies on notifications (the replies are buttons in the bubble, sent in one click when the app allows it). Your private details are hidden from the model. It answers like Muse in the side panel, in plain words; only when part of a task failed or something needs you does it add a report like a Kiroshi brief: what it did (DONE), what failed and why (FAILED), what is left for you (NEEDS YOU), and how many steps really ran.";
      fr = "Tout ce que vous demandez à l'IA se passe dans la bulle de Muse (Mod+C, ou Mod+T pour parler) : l'agent de Muse y répond, gardé lancé pour la bulle sur le modèle rapide (Paramètres > Agents du bureau > Précision et modèles), et Expliquer, Résumer, Traduire et les questions sur une zone de l'écran sont répondus par le petit modèle appelé directement en une ou deux secondes. Les commandes simples comme mettre la musique en pause ou ouvrir Firefox sont faites tout de suite ; le reste est fait par Muse avec les outils du bureau, la bulle disant à quelle étape il en est, avec Autoriser / Non seulement avant les étapes vraiment risquées (supprimer vos données, envoyer des messages en votre nom) ; fermer des fenêtres, ajouter des évènements ou lancer la musique se font directement. Les relances dans la bulle gardent la conversation ; agrandissez-la pour continuer dans le panneau latéral : la même conversation et la même session de l'agent, rien n'est répété. Dans l'outil de capture (Impr), activez Demander à l'IA (son bouton dans la barre d'outils, ou A) et tracez une zone ou choisissez une fenêtre ou un écran : la bulle propose Qu'est-ce que c'est, Expliquer, Résumer, Traduire et Copier le texte, ou tapez votre question. Aussi ! dans le lanceur, et Résumer / Suggérer des réponses sur les notifications (les réponses sont des boutons dans la bulle, envoyées en un clic quand l'application le permet). Vos détails privés sont masqués au modèle. Il répond comme Muse dans le panneau latéral, simplement ; seulement quand une partie d'une tâche a échoué ou que quelque chose vous attend, il ajoute un compte rendu façon Kiroshi : ce qu'il a fait (FAIT), ce qui a échoué et pourquoi (ÉCHEC), ce qui reste pour vous (À VOUS), et combien d'étapes ont vraiment tourné.";
      de = "Alles, was du die KI fragst, passiert in Muses Sprechblase (Mod+C, oder Mod+T zum Sprechen): Muses Agent antwortet dort, für die Blase auf dem schnellen Modell am Laufen gehalten (Einstellungen > Desktop-Agenten > Genauigkeit und Modelle), und Erklären, Zusammenfassen, Übersetzen und Fragen zu einem Bildschirmbereich beantwortet das kleine Modell direkt in ein, zwei Sekunden. Einfache Befehle wie Musik pausieren oder Firefox öffnen werden sofort erledigt; alles andere erledigt Muse mit den Desktop-Werkzeugen, die Blase sagt, bei welchem Schritt es ist, mit Erlauben / Nein nur vor wirklich riskanten Schritten (deine Daten löschen, Nachrichten in deinem Namen senden); Fenster schließen, Termine anlegen oder Musik starten passiert einfach. Nachfragen in der Blase behalten das Gespräch; vergrößere sie, um in der Seitenleiste weiterzumachen: dasselbe Gespräch und dieselbe Sitzung des Agenten, nichts wird wiederholt. Im Screenshot-Werkzeug (Druck) schalte KI fragen ein (sein Knopf in der Werkzeugleiste, oder A) und zieh einen Bereich auf oder wähle ein Fenster oder einen Bildschirm: die Blase bietet Was ist das, Erklären, Zusammenfassen, Übersetzen und Text kopieren, oder tipp deine Frage. Außerdem ! im Starter und Zusammenfassen / Antworten vorschlagen an Benachrichtigungen (die Antworten sind Knöpfe in der Blase, mit einem Klick gesendet, wenn die App es erlaubt). Private Angaben bleiben vor dem Modell verborgen. Es antwortet wie Muse im Seitenpanel, in einfachen Worten; nur wenn ein Teil einer Aufgabe fehlschlug oder etwas dich braucht, fügt es einen Bericht wie ein Kiroshi-Briefing an: was es getan hat (ERLEDIGT), was fehlschlug und warum (FEHLGESCHLAGEN), was für dich bleibt (FÜR DICH), und wie viele Schritte wirklich liefen.";
      vi = "Mọi điều bạn hỏi AI đều diễn ra trong bong bóng thoại của Muse (Mod+C, hoặc Mod+T để nói): tác nhân Muse trả lời ở đó, luôn chạy sẵn cho bong bóng trên mô hình nhanh (Cài đặt > Tác nhân màn hình > Độ chính xác và mô hình), còn Giải thích, Tóm tắt, Dịch và câu hỏi về một vùng màn hình do mô hình nhỏ gọi trực tiếp trả lời trong một hai giây. Lệnh đơn giản như tạm dừng nhạc hay mở Firefox được làm ngay; việc khác do Muse làm bằng các công cụ màn hình, bong bóng cho biết đang ở bước nào, chỉ hỏi Cho phép / Không trước những bước thật sự rủi ro (xóa dữ liệu của bạn, gửi tin nhắn thay bạn); đóng cửa sổ, thêm sự kiện hay bật nhạc thì làm luôn. Hỏi tiếp trong bong bóng sẽ giữ cuộc trò chuyện; mở rộng nó để tiếp tục ở bảng bên: cùng cuộc trò chuyện và cùng phiên của tác nhân, không lặp lại gì. Trong công cụ chụp màn hình (Print), bật Hỏi AI (nút trên thanh công cụ, hoặc A) rồi khoanh một vùng hoặc chọn một cửa sổ hay một màn hình: bong bóng đưa ra Đây là gì, Giải thích, Tóm tắt, Dịch và Sao chép chữ, hoặc gõ câu hỏi của bạn. Ngoài ra ! trong trình khởi chạy, và Tóm tắt / Gợi ý trả lời trên thông báo (các câu trả lời là nút trong bong bóng, gửi bằng một cú nhấp khi ứng dụng cho phép). Thông tin riêng tư được che với mô hình. Nó trả lời như Muse ở bảng bên, bằng lời đơn giản; chỉ khi một phần việc thất bại hoặc có điều cần bạn, nó mới thêm một bản báo cáo kiểu Kiroshi: việc đã làm (DONE), việc thất bại và lý do (FAILED), việc còn lại cho bạn (NEEDS YOU), và số bước đã thực sự chạy.";
    };
    answerFeedback = {
      en = "To tell Muse an answer was right or wrong: under its answers, in the speech bubble and in the side panel (the message's header there), click thumbs up (👍: it was right, what it used is reinforced) or thumbs down (👎): a line asks What did you mean? Type it and press Enter: the correction is remembered and given back to Muse for similar requests from then on, and Ask again with it retries the request with your correction (Escape saves the thumbs down alone). Turn the buttons off in Settings > Desktop agents > Accuracy and models (👍 / 👎 under the answers).";
      fr = "Pour dire à Muse qu'une réponse était juste ou fausse : sous ses réponses, dans la bulle et dans le panneau latéral (dans l'en-tête du message), cliquez sur pouce levé (👍 : c'était juste, ce qu'elle a utilisé est renforcé) ou pouce baissé (👎) : une ligne demande Que vouliez-vous dire ? Tapez-le puis Entrée : la correction est retenue et redonnée à Muse pour les demandes semblables, et Redemander avec relance la demande avec votre correction (Échap enregistre le pouce baissé seul). Désactivez les boutons dans Paramètres > Agents du bureau > Précision et modèles (👍 / 👎 sous les réponses).";
      de = "Um Muse zu sagen, dass eine Antwort richtig oder falsch war: unter ihren Antworten, in der Sprechblase und in der Seitenleiste (dort im Kopf der Nachricht), auf Daumen hoch (👍: es war richtig, was sie benutzt hat, wird gestärkt) oder Daumen runter (👎) klicken: eine Zeile fragt Was meintest du? Tippe es ein und drücke Enter: die Korrektur wird gemerkt und Muse bei ähnlichen Anfragen wieder mitgegeben, und Mit der Korrektur erneut fragen wiederholt die Anfrage (Escape speichert nur den Daumen runter). Ausschalten unter Einstellungen > Desktop-Agenten > Genauigkeit und Modelle (👍 / 👎 unter den Antworten).";
      vi = "Để báo cho Muse một câu trả lời đúng hay sai: dưới các câu trả lời, trong bong bóng thoại và ở bảng bên (trên tiêu đề tin nhắn), bấm ngón cái lên (👍: đúng rồi, những gì nó dùng được củng cố) hoặc ngón cái xuống (👎): một dòng hỏi Bạn muốn nói gì? Gõ vào rồi nhấn Enter: lời sửa được ghi nhớ và đưa lại cho Muse với các yêu cầu tương tự, và Hỏi lại với lời sửa sẽ làm lại yêu cầu (Escape chỉ lưu ngón cái xuống). Tắt các nút trong Cài đặt > Tác nhân màn hình > Độ chính xác và mô hình (👍 / 👎 dưới câu trả lời).";
    };
    clarifyingQuestions = {
      en = "Why Muse asks a question instead of doing it: when a request could mean several things (which window, which contact, which file), Muse asks which one you meant before acting, and does nothing until you answer; the side panel marks such an answer with a question mark. Answer in the same conversation and it goes on. It never asks twice in a row. Turn it off in Settings > Desktop agents > Accuracy and models (Ask back when a request is ambiguous).";
      fr = "Pourquoi Muse pose une question au lieu d'agir : quand une demande peut vouloir dire plusieurs choses (quelle fenêtre, quel contact, quel fichier), Muse demande laquelle avant d'agir, et ne fait rien tant que vous n'avez pas répondu ; le panneau latéral marque une telle réponse d'un point d'interrogation. Répondez dans la même conversation et elle continue. Elle ne redemande jamais deux fois de suite. Désactivez-le dans Paramètres > Agents du bureau > Précision et modèles (Demander quand une demande est ambiguë).";
      de = "Warum Muse eine Frage stellt, statt es zu tun: wenn eine Anfrage mehreres bedeuten kann (welches Fenster, welcher Kontakt, welche Datei), fragt Muse vor dem Handeln, was du meintest, und tut nichts, bis du antwortest; die Seitenleiste markiert so eine Antwort mit einem Fragezeichen. Antworte im selben Gespräch, und es geht weiter. Sie fragt nie zweimal hintereinander. Ausschalten unter Einstellungen > Desktop-Agenten > Genauigkeit und Modelle (Bei mehrdeutigen Anfragen nachfragen).";
      vi = "Vì sao Muse hỏi lại thay vì làm ngay: khi một yêu cầu có thể hiểu theo nhiều cách (cửa sổ nào, liên hệ nào, tệp nào), Muse hỏi bạn muốn cái nào trước khi làm, và không làm gì cho đến khi bạn trả lời; bảng bên đánh dấu câu trả lời đó bằng dấu chấm hỏi. Trả lời trong cùng cuộc trò chuyện là nó tiếp tục. Nó không bao giờ hỏi lại hai lần liền. Tắt trong Cài đặt > Tác nhân màn hình > Độ chính xác và mô hình (Hỏi lại khi yêu cầu chưa rõ).";
    };
    answerVerification = {
      en = "How Muse checks what it did: after a task that changed something (a window, a setting, an event, a message), Muse looks again with read-only tools to verify the goal is met; if not, it fixes it once. Under its answer you then see Checked: done, or Couldn't confirm it worked with the reason, so you know when to look yourself. Turn it off in Settings > Desktop agents > Accuracy and models (Check the result after acting).";
      fr = "Comment Muse vérifie ce qu'elle a fait : après une tâche qui a changé quelque chose (une fenêtre, un réglage, un évènement, un message), Muse regarde de nouveau avec des outils en lecture seule pour vérifier que le but est atteint ; sinon, elle corrige une fois. Sous sa réponse vous voyez alors Vérifié : fait, ou Pas pu confirmer, avec la raison, pour savoir quand regarder vous-même. Désactivez-le dans Paramètres > Agents du bureau > Précision et modèles (Vérifier le résultat après avoir agi).";
      de = "Wie Muse prüft, was sie getan hat: nach einer Aufgabe, die etwas geändert hat (ein Fenster, eine Einstellung, ein Termin, eine Nachricht), schaut Muse mit Nur-Lese-Werkzeugen noch einmal nach, ob das Ziel erreicht ist; wenn nicht, bessert sie einmal nach. Unter ihrer Antwort steht dann Geprüft: erledigt oder Konnte nicht bestätigen, mit dem Grund, damit du weißt, wann du selbst nachsehen solltest. Ausschalten unter Einstellungen > Desktop-Agenten > Genauigkeit und Modelle (Ergebnis nach dem Handeln prüfen).";
      vi = "Cách Muse kiểm tra việc nó đã làm: sau một việc có thay đổi gì đó (một cửa sổ, một cài đặt, một sự kiện, một tin nhắn), Muse xem lại bằng các công cụ chỉ đọc để kiểm tra mục tiêu đã đạt chưa; nếu chưa, nó sửa một lần. Dưới câu trả lời bạn sẽ thấy Đã kiểm tra: xong, hoặc Không xác nhận được kèm lý do, để biết khi nào cần tự xem lại. Tắt trong Cài đặt > Tác nhân màn hình > Độ chính xác và mô hình (Kiểm tra kết quả sau khi làm).";
    };
    oneConversation = {
      en = "The speech bubble and the side panel are one conversation with one Muse: what you start in the bubble (typed, said with Mod+T, Full AI mode's orders, the launcher's !, a Kiroshi scan's Do it) runs on Muse's agent session, and the bubble's expand button opens that same conversation in the side panel, where Muse goes on in the same session (nothing is repeated, it remembers everything said). Both share the same memory of you, your corrections and what you were just doing (the history button beside the model in the side panel, or the × in the bubble, leaves that out of the next message).";
      fr = "La bulle et le panneau latéral sont une seule conversation avec une seule Muse : ce que vous commencez dans la bulle (tapé, dit avec Mod+T, les ordres du mode IA complète, le ! du lanceur, le Faire d'un scan Kiroshi) passe par la session de l'agent de Muse, et le bouton agrandir de la bulle ouvre cette même conversation dans le panneau latéral, où Muse continue dans la même session (rien n'est répété, elle se souvient de tout ce qui a été dit). Les deux partagent la même mémoire de vous, vos corrections et ce que vous faisiez à l'instant (le bouton historique à côté du modèle dans le panneau, ou le × dans la bulle, l'enlève du prochain message).";
      de = "Die Sprechblase und die Seitenleiste sind ein Gespräch mit einer Muse: was du in der Blase beginnst (getippt, mit Mod+T gesagt, Befehle im vollen KI-Modus, das ! im Starter, das Erledigen eines Kiroshi-Scans) läuft in der Sitzung von Muses Agent, und der Vergrößern-Knopf der Blase öffnet dasselbe Gespräch in der Seitenleiste, wo Muse in derselben Sitzung weitermacht (nichts wird wiederholt, sie erinnert sich an alles). Beide teilen dasselbe Gedächtnis über dich, deine Korrekturen und was du gerade getan hast (der Verlaufsknopf neben dem Modell in der Seitenleiste oder das × in der Blase lässt das bei der nächsten Nachricht weg).";
      vi = "Bong bóng thoại và bảng bên là một cuộc trò chuyện với cùng một Muse: những gì bạn bắt đầu trong bong bóng (gõ, nói bằng Mod+T, lệnh trong chế độ AI toàn phần, dấu ! trong trình khởi chạy, nút Làm của một lần quét Kiroshi) chạy trên phiên của tác nhân Muse, và nút mở rộng của bong bóng mở cùng cuộc trò chuyện đó ở bảng bên, nơi Muse tiếp tục trong cùng phiên (không lặp lại gì, nó nhớ mọi điều đã nói). Cả hai dùng chung trí nhớ về bạn, các lời sửa của bạn và việc bạn vừa làm (nút lịch sử cạnh tên mô hình ở bảng bên, hoặc dấu × trong bong bóng, bỏ nó khỏi tin nhắn tiếp theo).";
    };
    standingOrders = {
      en = "To give Muse a standing order: in the speech bubble or the side panel, say what should happen from now on, like \"from now on, when I join a meeting, mute the music and open my notes\" or \"every evening at 6, give me a digest of my Slack mentions\". Muse turns it into a routine and shows a STANDING ORDER card under its answer: \"When …, I'll …\", with what it still needs to know. Turn on starts it (nothing runs before your click), Edit opens Settings > Desktop agents > Routines, No drops it. Schedules (a time on some days, or every so many minutes) and digests (what came in between, summed up when it runs) work too. Turn standing orders off in Settings > Desktop agents > Autonomy.";
      fr = "Pour donner un ordre permanent à Muse : dans la bulle ou le panneau latéral, dites ce qui doit se passer désormais, par exemple « désormais, quand je rejoins une réunion, coupe la musique et ouvre mes notes » ou « chaque soir à 18 h, fais-moi un résumé de mes mentions Slack ». Muse en fait une routine et montre une carte ORDRE PERMANENT sous sa réponse : « Quand …, je … », avec ce qu'il lui manque. Activer la lance (rien ne tourne avant votre clic), Modifier ouvre Paramètres > Agents du bureau > Routines, Non l'abandonne. Les horaires (une heure certains jours, ou toutes les N minutes) et les résumés (ce qui est arrivé entre-temps, résumé à chaque passage) marchent aussi. Désactivez les ordres permanents dans Paramètres > Agents du bureau > Autonomie.";
      de = "Um Muse einen Dauerauftrag zu geben: sag in der Sprechblase oder der Seitenleiste, was ab jetzt passieren soll, etwa „ab jetzt, wenn ich einem Meeting beitrete, schalte die Musik stumm und öffne meine Notizen“ oder „jeden Abend um 18 Uhr eine Zusammenfassung meiner Slack-Erwähnungen“. Muse macht daraus eine Routine und zeigt unter der Antwort eine Karte DAUERAUFTRAG: „Wenn …, mache ich …“, mit dem, was noch fehlt. Einschalten startet sie (vor deinem Klick läuft nichts), Bearbeiten öffnet Einstellungen > Desktop-Agenten > Routinen, Nein verwirft sie. Zeitpläne (eine Uhrzeit an bestimmten Tagen oder alle N Minuten) und Zusammenfassungen (was dazwischen kam, bei jedem Lauf zusammengefasst) gehen auch. Ausschalten unter Einstellungen > Desktop-Agenten > Autonomie.";
      vi = "Để giao cho Muse một lệnh thường trực: trong bong bóng thoại hoặc bảng bên, nói điều cần xảy ra từ nay, ví dụ \"từ nay, khi tôi vào cuộc họp, tắt nhạc và mở ghi chú\" hoặc \"mỗi tối 6 giờ, tóm tắt các lần nhắc tên tôi trên Slack\". Muse biến nó thành một thói quen và hiện thẻ LỆNH THƯỜNG TRỰC dưới câu trả lời: \"Khi …, tôi sẽ …\", cùng những gì nó còn cần biết. Bật để chạy (không gì chạy trước khi bạn bấm), Sửa mở Cài đặt > Tác nhân màn hình > Thói quen, Không để bỏ. Lịch (một giờ vào vài ngày, hoặc mỗi N phút) và bản tóm tắt (những gì đến trong khoảng giữa, tóm lại mỗi lần chạy) cũng được. Tắt lệnh thường trực trong Cài đặt > Tác nhân màn hình > Tự chủ.";
    };
    trustLadder = {
      en = "How Muse decides to ask before acting: each kind of action (a tool, its action, the app it acts on, like pausing the music or closing a Firefox window) is either asked about first (Allow / No), done and told after (a \"Did: …\" line with Undo), or done silently (still in the journal). After you allow the same kind three times in a row, it offers \"Stop asking before …?\": Yes means done and told after from then on. Saying no or undoing it puts it back to asking. Sending, paying, deleting and passwords always ask. Only you change a kind: in Settings > Desktop agents > Autonomy (What it may do without asking: Ask, Tell after, Silent); Muse can never raise its own trust. Turn the ladder off there too.";
      fr = "Comment Muse décide de demander avant d'agir : chaque type d'action (un outil, son action, l'application visée, comme mettre la musique en pause ou fermer une fenêtre de Firefox) est soit demandé d'abord (Autoriser / Non), soit fait puis signalé (une ligne « Fait : … » avec Annuler), soit fait en silence (toujours dans le journal). Après trois autorisations de suite du même type, elle propose « Ne plus demander avant … ? » : Oui veut dire fait puis signalé désormais. Un refus ou une annulation le remet à demander. Envoyer, payer, supprimer et les mots de passe demandent toujours. Vous seul changez un type : dans Paramètres > Agents du bureau > Autonomie (Ce qu'elle peut faire sans demander : Demander, Signaler après, En silence) ; Muse ne peut jamais augmenter sa propre confiance. L'échelle se désactive au même endroit.";
      de = "Wie Muse entscheidet, vor dem Handeln zu fragen: jede Art von Aktion (ein Werkzeug, seine Aktion, die App, auf die es wirkt, etwa Musik pausieren oder ein Firefox-Fenster schließen) wird entweder vorher gefragt (Erlauben / Nein), erledigt und danach gemeldet (eine Zeile „Erledigt: …“ mit Rückgängig) oder still erledigt (trotzdem im Journal). Nachdem du dieselbe Art dreimal hintereinander erlaubt hast, bietet sie „Nicht mehr fragen vor …?“ an: Ja heißt ab dann erledigen und danach melden. Ein Nein oder Rückgängig stellt es wieder auf Fragen. Senden, Bezahlen, Löschen und Passwörter fragen immer. Nur du änderst eine Art: unter Einstellungen > Desktop-Agenten > Autonomie (Was sie ohne Fragen darf: Fragen, Danach melden, Still); Muse kann ihr eigenes Vertrauen nie erhöhen. Dort lässt sich die Leiter auch ausschalten.";
      vi = "Cách Muse quyết định có hỏi trước khi làm không: mỗi loại hành động (một công cụ, thao tác của nó, ứng dụng nó tác động, như tạm dừng nhạc hay đóng một cửa sổ Firefox) hoặc được hỏi trước (Cho phép / Không), hoặc làm rồi báo sau (một dòng \"Đã làm: …\" có Hoàn tác), hoặc làm im lặng (vẫn có trong nhật ký). Sau khi bạn cho phép cùng một loại ba lần liền, nó đề nghị \"Thôi hỏi trước khi …?\": Có nghĩa là từ nay làm rồi báo sau. Từ chối hoặc hoàn tác sẽ đưa nó về hỏi lại. Gửi, thanh toán, xóa và mật khẩu luôn phải hỏi. Chỉ bạn thay đổi một loại: trong Cài đặt > Tác nhân màn hình > Tự chủ (Những gì nó được làm không cần hỏi: Hỏi, Báo sau, Im lặng); Muse không bao giờ tự nâng mức tin cậy của mình. Tắt thang tin cậy cũng ở đó.";
    };
    journalUndo = {
      en = "To see and undo what Muse did on its own: open the side panel's Muse tab (What Muse did), or Settings > Desktop agents > Autonomy > What Muse did. It lists by day everything done without your OK on that very step: routines, standing orders, digests, its reactions, steps it was trusted with, background tasks, each with where it came from, for 30 days. Undo takes one back when it can (a window moved back, the volume or theme as it was, a launched app closed, an event or a task removed, a layout restored); after a \"Did: …\" line in the bubble or the side panel, its Undo does the same. Undoing also tells Muse to ask again next time. At the day's start the bubble says in one line what it did yesterday. Turn the journal off in Settings > Desktop agents > Autonomy.";
      fr = "Pour voir et annuler ce que Muse a fait seule : ouvrez l'onglet Muse du panneau latéral (Ce que Muse a fait), ou Paramètres > Agents du bureau > Autonomie > Ce que Muse a fait. Il liste par jour tout ce qui a été fait sans votre accord sur cette étape-là : routines, ordres permanents, résumés, ses réactions, étapes confiées, tâches de fond, chacune avec son origine, sur 30 jours. Annuler défait une action quand c'est possible (fenêtre remise en place, volume ou thème d'avant, application lancée refermée, évènement ou tâche supprimé, disposition restaurée) ; après une ligne « Fait : … » dans la bulle ou le panneau, son Annuler fait pareil. Annuler dit aussi à Muse de redemander la prochaine fois. En début de journée la bulle dit en une ligne ce qu'elle a fait la veille. Désactivez le journal dans Paramètres > Agents du bureau > Autonomie.";
      de = "Um zu sehen und rückgängig zu machen, was Muse allein getan hat: öffne den Muse-Tab der Seitenleiste (Was Muse getan hat) oder Einstellungen > Desktop-Agenten > Autonomie > Was Muse getan hat. Dort steht nach Tagen alles, was ohne dein OK zu genau diesem Schritt geschah: Routinen, Daueraufträge, Zusammenfassungen, ihre Reaktionen, anvertraute Schritte, Hintergrundaufgaben, jeweils mit Herkunft, 30 Tage lang. Rückgängig nimmt eine Aktion zurück, wenn es geht (Fenster zurückgeschoben, Lautstärke oder Thema wie vorher, gestartete App geschlossen, Termin oder Aufgabe entfernt, Anordnung wiederhergestellt); nach einer Zeile „Erledigt: …“ in der Blase oder der Seitenleiste macht ihr Rückgängig dasselbe. Rückgängig sagt Muse auch, nächstes Mal wieder zu fragen. Zu Tagesbeginn sagt die Blase in einer Zeile, was sie gestern getan hat. Journal ausschalten unter Einstellungen > Desktop-Agenten > Autonomie.";
      vi = "Để xem và hoàn tác những gì Muse tự làm: mở thẻ Muse ở bảng bên (Muse đã làm gì), hoặc Cài đặt > Tác nhân màn hình > Tự chủ > Muse đã làm gì. Nó liệt kê theo ngày mọi việc làm mà không có sự đồng ý của bạn cho đúng bước đó: thói quen, lệnh thường trực, bản tóm tắt, phản ứng của nó, các bước được tin giao, việc chạy nền, mỗi việc có nguồn gốc, trong 30 ngày. Hoàn tác đảo ngược một việc khi có thể (cửa sổ về chỗ cũ, âm lượng hay giao diện như trước, ứng dụng đã mở được đóng, sự kiện hay việc cần làm bị gỡ, bố cục được khôi phục); sau một dòng \"Đã làm: …\" trong bong bóng hoặc bảng bên, nút Hoàn tác của nó cũng vậy. Hoàn tác cũng nhắc Muse lần sau hỏi lại. Đầu ngày, bong bóng nói trong một dòng những gì nó đã làm hôm qua. Tắt nhật ký trong Cài đặt > Tác nhân màn hình > Tự chủ.";
    };
    backgroundTasks = {
      en = "To have Muse do something long in the background: ask for it (\"in the background, compare the three laptops I looked at and prepare a summary\"), or while Muse works on a long order in the bubble, click Do it in the background: the bubble is free again and the task goes on by itself (up to 4 at once by default). Each task is a little worker on the bar while it runs (typing, searching, using a tool, an hourglass when it waits for you, cheering when done); hover one for what it does, click it to see it in the side panel. The side panel's Muse tab lists them: status and steps, Allow / No when a step needs your OK, a field to answer its question, Open (its conversation in the side panel), Stop, Resume. You get a notification when one needs you or is done. Turn it off or change how many at once in Settings > Desktop agents > Autonomy.";
      fr = "Pour que Muse fasse quelque chose de long en arrière-plan : demandez-le (« en arrière-plan, compare les trois ordinateurs que j'ai regardés et prépare un résumé »), ou pendant que Muse travaille sur un ordre long dans la bulle, cliquez Le faire en arrière-plan : la bulle se libère et la tâche continue seule (jusqu'à 4 à la fois par défaut). Chaque tâche est un petit ouvrier sur la barre pendant qu'elle tourne (il tape, cherche, utilise un outil, un sablier quand il vous attend, il fête la fin) ; survolez-en un pour voir ce qu'il fait, cliquez pour le voir dans le panneau latéral. L'onglet Muse du panneau latéral les liste : état et étapes, Autoriser / Non quand une étape attend votre accord, un champ pour répondre à sa question, Ouvrir (sa conversation dans le panneau), Arrêter, Reprendre. Une notification vous prévient quand une vous attend ou a fini. Désactivez-les ou changez le nombre à la fois dans Paramètres > Agents du bureau > Autonomie.";
      de = "Um Muse etwas Langes im Hintergrund erledigen zu lassen: bitte darum („vergleiche im Hintergrund die drei Laptops, die ich mir angesehen habe, und bereite eine Zusammenfassung vor“), oder klicke, während Muse in der Blase an einem langen Auftrag arbeitet, auf Im Hintergrund erledigen: die Blase ist wieder frei und die Aufgabe läuft allein weiter (standardmäßig bis zu 4 gleichzeitig). Jede Aufgabe ist ein kleiner Arbeiter in der Leiste, solange sie läuft (er tippt, sucht, benutzt ein Werkzeug, eine Sanduhr, wenn er auf dich wartet, er jubelt, wenn er fertig ist); fahre über einen, um zu sehen, was er tut, klicke, um ihn in der Seitenleiste zu sehen. Der Muse-Tab der Seitenleiste listet sie: Status und Schritte, Erlauben / Nein, wenn ein Schritt dein OK braucht, ein Feld für die Antwort auf ihre Frage, Öffnen (ihr Gespräch in der Seitenleiste), Stoppen, Fortsetzen. Eine Benachrichtigung sagt dir, wenn eine dich braucht oder fertig ist. Ausschalten oder die Anzahl ändern unter Einstellungen > Desktop-Agenten > Autonomie.";
      vi = "Để Muse làm một việc dài ở chế độ nền: hãy yêu cầu (\"chạy nền, so sánh ba chiếc laptop tôi đã xem và chuẩn bị bản tóm tắt\"), hoặc khi Muse đang làm một lệnh dài trong bong bóng, bấm Làm ở chế độ nền: bong bóng rảnh lại và việc tự chạy tiếp (mặc định tối đa 4 việc cùng lúc). Mỗi việc là một người thợ nhỏ trên thanh khi đang chạy (gõ phím, tìm kiếm, dùng công cụ, đồng hồ cát khi chờ bạn, ăn mừng khi xong); di chuột lên để xem nó đang làm gì, bấm để xem nó ở bảng bên. Thẻ Muse ở bảng bên liệt kê chúng: trạng thái và các bước, Cho phép / Không khi một bước cần bạn đồng ý, ô để trả lời câu hỏi của nó, Mở (cuộc trò chuyện của nó ở bảng bên), Dừng, Tiếp tục. Bạn nhận thông báo khi một việc cần bạn hoặc đã xong. Tắt hoặc đổi số việc cùng lúc trong Cài đặt > Tác nhân màn hình > Tự chủ.";
    };
    fanOut = {
      en = "To have several parts of an order done at once: say it in one go (\"research three restaurants, draft an invitation and block my Friday evening\") and, while Muse works on it in the bubble, click Split it up (shown instead of Do it in the background when the order has several parts), or ask Muse to do it in parallel. Muse Wonder, the big model, writes a short plan of at most 4 parts, shown as a card in the bubble; each part then runs as a background task of its own with its own Muse (Spark for the simple ones), all at the same time, and a part that needs another's result waits for it. Each worker is a little figure on the bar with its model under it: it types while it writes, holds a magnifier while it searches the web, a gear while it uses a tool, an hourglass when it waits for your OK, cheers when done and slumps when it failed. Hover one for its part and step, click it to see it in the side panel's Muse tab, where the plan is a group with its workers under it. When they are all done, Muse merges their results into one answer in the bubble. Risky steps still ask you first. Stop all, in the Muse tab, stops every worker. Turn it off in Settings > Desktop agents > Autonomy (Split an order of several parts into workers at once); how many run at once is the background tasks' limit there.";
      fr = "Pour faire plusieurs parties d'un ordre en même temps : dites-le d'un coup (« trouve trois restaurants, rédige une invitation et bloque mon vendredi soir ») et, pendant que Muse y travaille dans la bulle, cliquez Le découper (affiché à la place de Le faire en arrière-plan quand l'ordre a plusieurs parties), ou demandez à Muse de le faire en parallèle. Muse Wonder, le grand modèle, écrit un court plan d'au plus 4 parties, affiché en carte dans la bulle ; chaque partie tourne ensuite comme une tâche de fond à part avec sa propre Muse (Spark pour les simples), toutes en même temps, et une partie qui a besoin du résultat d'une autre l'attend. Chaque ouvrier est une petite figure sur la barre avec son modèle dessous : il tape quand il écrit, tient une loupe quand il cherche sur le web, un engrenage quand il utilise un outil, un sablier quand il attend votre accord, il fête la fin et s'affaisse en cas d'échec. Survolez-en un pour sa partie et son étape, cliquez pour le voir dans l'onglet Muse du panneau latéral, où le plan forme un groupe avec ses ouvriers dessous. Quand tous ont fini, Muse fusionne leurs résultats en une seule réponse dans la bulle. Les étapes risquées vous demandent toujours d'abord. Tout arrêter, dans l'onglet Muse, arrête tous les ouvriers. Désactivez-le dans Paramètres > Agents du bureau > Autonomie (Découper un ordre en plusieurs parties à la fois) ; le nombre à la fois est la limite des tâches de fond.";
      de = "Um mehrere Teile eines Auftrags gleichzeitig erledigen zu lassen: sag ihn in einem Zug („such drei Restaurants, entwirf eine Einladung und blockiere meinen Freitagabend“) und klicke, während Muse in der Blase daran arbeitet, auf Aufteilen (statt Im Hintergrund erledigen, wenn der Auftrag mehrere Teile hat), oder bitte Muse, es parallel zu tun. Muse Wonder, das große Modell, schreibt einen kurzen Plan mit höchstens 4 Teilen, als Karte in der Blase; jeder Teil läuft dann als eigene Hintergrundaufgabe mit eigener Muse (Spark für die einfachen), alle gleichzeitig, und ein Teil, der das Ergebnis eines anderen braucht, wartet darauf. Jeder Arbeiter ist eine kleine Figur in der Leiste mit seinem Modell darunter: er tippt, wenn er schreibt, hält eine Lupe, wenn er im Web sucht, ein Zahnrad, wenn er ein Werkzeug benutzt, eine Sanduhr, wenn er auf dein OK wartet, er jubelt, wenn er fertig ist, und sackt zusammen, wenn es fehlschlug. Fahre über einen für seinen Teil und Schritt, klicke, um ihn im Muse-Tab der Seitenleiste zu sehen, wo der Plan eine Gruppe mit seinen Arbeitern darunter ist. Wenn alle fertig sind, führt Muse ihre Ergebnisse zu einer Antwort in der Blase zusammen. Riskante Schritte fragen dich weiterhin zuerst. Alle stoppen, im Muse-Tab, stoppt jeden Arbeiter. Ausschalten unter Einstellungen > Desktop-Agenten > Autonomie (Einen Auftrag mit mehreren Teilen auf gleichzeitige Arbeiter aufteilen); wie viele gleichzeitig laufen, ist dort die Grenze der Hintergrundaufgaben.";
      vi = "Để làm nhiều phần của một lệnh cùng lúc: nói cả lệnh một lần (\"tìm ba nhà hàng, soạn lời mời và giữ trống tối thứ Sáu của tôi\") và, khi Muse đang làm trong bong bóng, bấm Chia nhỏ (hiện thay cho Làm ở chế độ nền khi lệnh có nhiều phần), hoặc bảo Muse làm song song. Muse Wonder, mô hình lớn, viết một kế hoạch ngắn tối đa 4 phần, hiện thành thẻ trong bong bóng; mỗi phần chạy như một việc nền riêng với Muse riêng (Spark cho phần đơn giản), tất cả cùng lúc, và phần nào cần kết quả của phần khác thì chờ phần đó. Mỗi người thợ là một hình nhỏ trên thanh với tên mô hình bên dưới: gõ phím khi viết, cầm kính lúp khi tìm trên web, bánh răng khi dùng công cụ, đồng hồ cát khi chờ bạn đồng ý, ăn mừng khi xong và gục xuống khi thất bại. Di chuột lên để xem phần và bước của nó, bấm để xem trong thẻ Muse ở bảng bên, nơi kế hoạch là một nhóm với các người thợ bên dưới. Khi tất cả xong, Muse gộp kết quả thành một câu trả lời trong bong bóng. Các bước rủi ro vẫn hỏi bạn trước. Dừng tất cả, trong thẻ Muse, dừng mọi người thợ. Tắt trong Cài đặt > Tác nhân màn hình > Tự chủ (Chia lệnh nhiều phần cho nhiều người thợ cùng lúc); số việc cùng lúc là giới hạn của việc nền ở đó.";
    };
    instantTriage = {
      en = "Why Muse reacts at once to some notifications and ignores others: before any model reads it, each notification and event is scored on this computer in milliseconds (instant triage): what you muted, never act on or got twice is dropped; what is clearly worth saying (someone important to you wrote, a reminder) is said right away in the bubble; only the unclear rest goes to the model. It learns from what you act on or dismiss (only your own dismissals: an app closing its notification doesn't count; old habits fade after a month, a kind found boring after 14 days). In Full AI mode what it learned from your habits drops nothing: the model decides. Your routines and digests still see everything. Turn it off in Settings > Desktop agents > Reactivity (Instant triage before the model); the same section shows what was triaged lately.";
      fr = "Pourquoi Muse réagit tout de suite à certaines notifications et en ignore d'autres : avant qu'un modèle ne la lise, chaque notification et évènement est noté sur cet ordinateur en quelques millisecondes (tri instantané) : ce que vous avez mis en sourdine, sur quoi vous n'agissez jamais ou reçu deux fois est écarté ; ce qui mérite clairement d'être dit (quelqu'un d'important pour vous a écrit, un rappel) est dit aussitôt dans la bulle ; seul le reste incertain va au modèle. Il apprend de ce sur quoi vous agissez ou que vous écartez (seulement ce que vous écartez vous-même : une app qui ferme sa notification ne compte pas ; les vieilles habitudes s'estompent après un mois, un type jugé ennuyeux après 14 jours). En mode IA complète, ce qu'il a appris de vos habitudes n'écarte rien : le modèle décide. Vos routines et résumés voient toujours tout. Désactivez-le dans Paramètres > Agents du bureau > Réactivité (Tri instantané avant le modèle) ; la même section montre ce qui a été trié récemment.";
      de = "Warum Muse auf manche Benachrichtigungen sofort reagiert und andere übergeht: bevor ein Modell sie liest, wird jede Benachrichtigung und jedes Ereignis auf diesem Computer in Millisekunden bewertet (Sofort-Triage): was du stummgeschaltet hast, nie beachtest oder doppelt bekommst, fällt weg; was eindeutig gesagt werden sollte (jemand Wichtiges hat geschrieben, eine Erinnerung), sagt die Blase sofort; nur der unklare Rest geht ans Modell. Es lernt daraus, worauf du reagierst oder was du wegwischst (nur was du selbst wegwischst: eine App, die ihre Benachrichtigung schließt, zählt nicht; alte Gewohnheiten verblassen nach einem Monat, eine als langweilig eingestufte Art nach 14 Tagen). Im Voll-KI-Modus verwirft das aus deinen Gewohnheiten Gelernte nichts: das Modell entscheidet. Deine Routinen und Zusammenfassungen sehen weiterhin alles. Ausschalten unter Einstellungen > Desktop-Agenten > Reaktionsfähigkeit (Sofort-Triage vor dem Modell); derselbe Abschnitt zeigt, was zuletzt sortiert wurde.";
      vi = "Vì sao Muse phản ứng ngay với một số thông báo và bỏ qua số khác: trước khi mô hình nào đọc, mỗi thông báo và sự kiện được chấm điểm ngay trên máy này trong vài mili giây (phân loại tức thì): những gì bạn đã tắt tiếng, không bao giờ để ý hoặc nhận hai lần bị bỏ; những gì rõ ràng đáng nói (một người quan trọng với bạn vừa viết, một lời nhắc) được nói ngay trong bong bóng; chỉ phần còn lại chưa rõ mới đến mô hình. Nó học từ những gì bạn xử lý hoặc gạt đi (chỉ những gì chính bạn gạt đi: ứng dụng tự đóng thông báo không tính; thói quen cũ phai sau một tháng, loại bị cho là nhàm chán sau 14 ngày). Ở chế độ AI toàn phần, những gì nó học từ thói quen của bạn không bỏ gì cả: mô hình quyết định. Các thói quen và bản tóm tắt của bạn vẫn thấy mọi thứ. Tắt trong Cài đặt > Tác nhân màn hình > Phản ứng (Phân loại tức thì trước mô hình); cùng mục đó hiện những gì vừa được phân loại.";
    };
    privatePeople = {
      en = "How Muse keeps people private: names, emails, phones, addresses and the words you list (Settings > Desktop agents > Private details) are hidden before any model reads them, and come back on this computer. A person is shown to the model as a stand-in name, always the same and never one of your contacts' (Alan might be Brisa to it): it then writes that name instead of making one up, and you and the tools get the real one (searching Discord for Brisa finds Alan). Emails, phones and the rest stay placeholders like ⟦Email 1⟧. Turn off People as stand-in names for placeholders everywhere.";
      fr = "Comment Muse garde les gens privés : noms, e-mails, téléphones, adresses et les mots que vous listez (Paramètres > Agents du bureau > Détails privés) sont cachés avant qu'un modèle ne les lise, et reviennent sur cet ordinateur. Une personne est montrée au modèle sous un nom de remplacement, toujours le même et jamais celui d'un de vos contacts (Alan peut être Brisa pour lui) : il écrit alors ce nom au lieu d'en inventer un, et vous comme les outils recevez le vrai (chercher Brisa sur Discord trouve Alan). E-mails, téléphones et le reste restent des repères comme ⟦Email 1⟧. Désactivez Personnes sous un nom de remplacement pour des repères partout.";
      de = "Wie Muse Personen privat hält: Namen, E-Mails, Telefonnummern, Adressen und die Wörter, die du einträgst (Einstellungen > Desktop-Agenten > Private Angaben), werden versteckt, bevor ein Modell sie liest, und kommen auf diesem Computer zurück. Eine Person sieht das Modell unter einem Ersatznamen, immer demselben und nie dem eines deiner Kontakte (Alan ist für es vielleicht Brisa): es schreibt dann diesen Namen, statt einen zu erfinden, und du wie die Werkzeuge bekommt den echten (Brisa auf Discord suchen findet Alan). E-Mails, Telefonnummern und der Rest bleiben Platzhalter wie ⟦Email 1⟧. Schalte Personen unter Ersatznamen aus für Platzhalter überall.";
      vi = "Muse giữ riêng tư cho mọi người thế nào: tên, email, số điện thoại, địa chỉ và các từ bạn liệt kê (Cài đặt > Tác nhân màn hình > Thông tin riêng tư) được ẩn trước khi mô hình nào đọc, và trở lại trên máy này. Một người được hiện cho mô hình bằng một tên thay thế, luôn giống nhau và không bao giờ là tên của một liên hệ của bạn (Alan có thể là Brisa với nó): nó viết tên đó thay vì tự bịa ra, còn bạn và các công cụ nhận tên thật (tìm Brisa trên Discord sẽ thấy Alan). Email, số điện thoại và phần còn lại vẫn là ký hiệu như ⟦Email 1⟧. Tắt Người dưới tên thay thế để dùng ký hiệu ở mọi nơi.";
    };
    contextTriggers = {
      en = "Why Muse offers help before you ask: at moments where one concrete thing would help, it offers it in the bubble: a command that failed twice in 10 minutes, an error or stack trace you copied, a window you keep going back to (4 times in 30 minutes), a meeting with a link starting in 5 minutes, an error window still open after 20 seconds. Yes gives Muse that order in the bubble, Not now waits, Never for this stops that offer for 30 days and Muse remembers you don't want it. Each has its switch in Settings > Desktop agents > Reactivity (Offer them again restores the stopped ones); they need Talks to you on its own and an online model.";
      fr = "Pourquoi Muse propose son aide avant qu'on la demande : aux moments où une chose précise aiderait, elle la propose dans la bulle : une commande qui a échoué deux fois en 10 minutes, une erreur ou une trace copiée, une fenêtre où vous revenez sans cesse (4 fois en 30 minutes), une réunion avec un lien qui commence dans 5 minutes, une fenêtre d'erreur toujours ouverte après 20 secondes. Oui donne cet ordre à Muse dans la bulle, Pas maintenant attend, Jamais pour ça arrête cette proposition pendant 30 jours et Muse retient que vous n'en voulez pas. Chacune a son interrupteur dans Paramètres > Agents du bureau > Réactivité (Les proposer de nouveau rétablit celles arrêtées) ; il faut Vous parle d'elle-même et un modèle en ligne.";
      de = "Warum Muse Hilfe anbietet, bevor du fragst: in Momenten, in denen eine konkrete Sache helfen würde, bietet sie sie in der Blase an: ein Befehl, der zweimal in 10 Minuten fehlschlug, ein kopierter Fehler oder Stacktrace, ein Fenster, zu dem du immer wieder zurückkehrst (4-mal in 30 Minuten), ein Meeting mit Link, das in 5 Minuten beginnt, ein Fehlerfenster, das nach 20 Sekunden noch offen ist. Ja gibt Muse diesen Auftrag in der Blase, Nicht jetzt wartet, Nie dafür stoppt dieses Angebot für 30 Tage und Muse merkt sich, dass du es nicht willst. Jedes hat seinen Schalter unter Einstellungen > Desktop-Agenten > Reaktionsfähigkeit (Wieder anbieten stellt die gestoppten wieder her); sie brauchen Spricht dich von selbst an und ein Online-Modell.";
      vi = "Vì sao Muse đề nghị giúp trước khi bạn hỏi: vào những lúc một việc cụ thể sẽ có ích, nó đề nghị trong bong bóng: một lệnh thất bại hai lần trong 10 phút, một lỗi hay vết ngăn xếp bạn vừa sao chép, một cửa sổ bạn cứ quay lại (4 lần trong 30 phút), một cuộc họp có đường dẫn bắt đầu trong 5 phút, một cửa sổ báo lỗi vẫn mở sau 20 giây. Có giao lệnh đó cho Muse trong bong bóng, Để sau thì chờ, Đừng bao giờ với việc này dừng đề nghị đó 30 ngày và Muse nhớ là bạn không muốn. Mỗi loại có công tắc riêng trong Cài đặt > Tác nhân màn hình > Phản ứng (Đề nghị lại sẽ khôi phục những cái đã dừng); cần bật Tự nói chuyện với bạn và một mô hình trực tuyến.";
    };
    meetingCompanion = {
      en = "To have Muse take notes of a call (the meeting companion): say or type take notes in the bubble (Mod+C, or Mod+T to say it), click Take notes when Muse offers it (a calendar meeting with a link starting, or a call app such as Zoom, Teams, Meet, Discord or Slack taking the microphone), or Take notes now in Settings > Desktop agents > Meeting companion. While it listens, the bar shows a red icon and a small window says Listening to the call with the time: live captions of what you hear (your microphone too, labelled You; the mic button leaves it out), the lines in another language translated into yours, and the notes button opens the running notes (topics, decisions, action items with an owner, open questions), updated every minute or so. Drag the window by its top bar. Stop (or say stop taking notes; it also stops when the call app lets the microphone go, or after the meeting's end) and Muse Wonder writes the summary, decisions and action items, shown in the bubble with Add tasks, Save as note and Draft follow-up (a message to copy, or to send with Muse, which asks you first: nothing is sent by itself). Tell the others you're taking AI notes. The transcript stays on this computer for 30 days; what goes to the model is masked. Ask Muse what did we decide in the meeting? afterwards. Turn it off, stop the offers, the microphone or the translation, change how often the notes come and how long transcripts are kept in Settings > Desktop agents > Meeting companion; it needs Meta as the model provider.";
      fr = "Pour que Muse prenne des notes d'un appel (le compagnon de réunion) : dites ou tapez prends des notes dans la bulle (Mod+C, ou Mod+T pour le dire), cliquez Prendre des notes quand Muse le propose (une réunion de l'agenda avec un lien qui commence, ou une app d'appel comme Zoom, Teams, Meet, Discord ou Slack qui prend le micro), ou Prendre des notes maintenant dans Paramètres > Agents du bureau > Compagnon de réunion. Pendant l'écoute, la barre affiche une icône rouge et une petite fenêtre indique En écoute de l'appel avec la durée : les sous-titres en direct de ce que vous entendez (votre micro aussi, marqué Vous ; le bouton micro l'exclut), les phrases dans une autre langue traduites dans la vôtre, et le bouton notes ouvre les notes en cours (sujets, décisions, actions avec un responsable, questions ouvertes), mises à jour toutes les minutes environ. Déplacez la fenêtre par sa barre du haut. Arrêter (ou dites arrête les notes ; elle s'arrête aussi quand l'app d'appel libère le micro, ou après la fin de la réunion) et Muse Wonder rédige le résumé, les décisions et les actions, affichés dans la bulle avec Ajouter les tâches, Enregistrer en note et Rédiger un suivi (un message à copier, ou à envoyer avec Muse, qui vous demande d'abord : rien ne part tout seul). Prévenez les autres que vous prenez des notes avec l'IA. La transcription reste sur cet ordinateur 30 jours ; ce qui va au modèle est masqué. Demandez ensuite à Muse qu'a-t-on décidé à la réunion ?. Désactivez-le, coupez les propositions, le micro ou la traduction, réglez la fréquence des notes et la durée de conservation dans Paramètres > Agents du bureau > Compagnon de réunion ; il faut Meta comme fournisseur de modèle.";
      de = "Damit Muse Notizen zu einem Anruf macht (der Meeting-Begleiter): sag oder tippe mach Notizen in der Blase (Mod+C, oder Mod+T zum Sprechen), klicke Notizen machen, wenn Muse es anbietet (ein Kalendertermin mit Link beginnt, oder eine Anruf-App wie Zoom, Teams, Meet, Discord oder Slack nimmt das Mikrofon), oder Jetzt Notizen machen unter Einstellungen > Desktop-Agenten > Meeting-Begleiter. Während es zuhört, zeigt die Leiste ein rotes Symbol und ein kleines Fenster sagt Hört dem Anruf zu mit der Dauer: Live-Untertitel dessen, was du hörst (auch dein Mikrofon, als Du markiert; der Mikrofon-Knopf lässt es weg), Sätze in einer anderen Sprache in deine übersetzt, und der Notizen-Knopf öffnet die laufenden Notizen (Themen, Entscheidungen, Aufgaben mit Verantwortlichem, offene Fragen), etwa jede Minute aktualisiert. Zieh das Fenster an seiner oberen Leiste. Stopp (oder sag beende die Notizen; es stoppt auch, wenn die Anruf-App das Mikrofon freigibt, oder nach dem Ende des Termins), und Muse Wonder schreibt Zusammenfassung, Entscheidungen und Aufgaben, in der Blase mit Aufgaben hinzufügen, Als Notiz speichern und Nachricht entwerfen (eine Nachricht zum Kopieren oder zum Senden mit Muse, die dich vorher fragt: nichts geht von selbst raus). Sag den anderen, dass du KI-Notizen machst. Das Transkript bleibt 30 Tage auf diesem Computer; was ans Modell geht, ist maskiert. Frag Muse danach, was haben wir im Meeting entschieden?. Ausschalten, Angebote, Mikrofon oder Übersetzung abstellen, wie oft Notizen kommen und wie lange Transkripte bleiben unter Einstellungen > Desktop-Agenten > Meeting-Begleiter; es braucht Meta als Modellanbieter.";
      vi = "Để Muse ghi chép một cuộc gọi (trợ lý cuộc họp): nói hoặc gõ ghi chép cuộc họp trong bong bóng (Mod+C, hoặc Mod+T để nói), bấm Ghi chép khi Muse đề nghị (một cuộc họp trong lịch có đường dẫn bắt đầu, hoặc một ứng dụng gọi như Zoom, Teams, Meet, Discord hay Slack dùng micro), hoặc Ghi chép ngay trong Cài đặt > Tác nhân màn hình > Trợ lý cuộc họp. Trong lúc nghe, thanh hiện biểu tượng đỏ và một cửa sổ nhỏ ghi Đang nghe cuộc gọi kèm thời gian: phụ đề trực tiếp những gì bạn nghe (cả micro của bạn, ghi là Bạn; nút micro bỏ nó ra), câu nói bằng ngôn ngữ khác được dịch sang tiếng của bạn, và nút ghi chú mở ghi chú đang ghi (chủ đề, quyết định, việc cần làm kèm người phụ trách, câu hỏi còn mở), cập nhật khoảng mỗi phút. Kéo cửa sổ bằng thanh trên cùng. Dừng (hoặc nói dừng ghi chép; nó cũng dừng khi ứng dụng gọi trả micro, hoặc sau khi cuộc họp kết thúc) và Muse Wonder viết bản tóm tắt, các quyết định và việc cần làm, hiện trong bong bóng với Thêm việc cần làm, Lưu thành ghi chú và Soạn tin nhắn tiếp theo (một tin để sao chép, hoặc gửi cùng Muse, nó hỏi bạn trước: không có gì tự gửi đi). Hãy báo cho mọi người biết bạn ghi chép bằng AI. Bản ghi lời nói ở lại trên máy này 30 ngày; những gì gửi tới mô hình đều được che. Sau đó hỏi Muse chúng ta đã quyết định gì trong cuộc họp?. Tắt nó, tắt đề nghị, micro hoặc bản dịch, chỉnh tần suất ghi chú và thời gian giữ bản ghi trong Cài đặt > Tác nhân màn hình > Trợ lý cuộc họp; cần Meta làm nhà cung cấp mô hình.";
    };
    nextUp = {
      en = "What the \"Next: …\" chip beside the mascot is: Next up, Muse getting ahead of you. From what you usually do after something (an app you use, a meeting ending, a download, a pull request opened, a command failing, the start of your day, the time of day), it offers the likely next step before you ask: open or switch to an app, restore a window layout, open a link, start a timer or a focus session, run a routine, or a follow-up Muse writes for you (a meeting's recap, a pull request review, a PDF summary). It is guessed on this computer in plain code, no model, and offered only when it is likely enough and was seen often enough. Click the chip or press Super+Shift+Enter to do it; hover it to see why (\"You usually open Jira after your 09:00 standup — 14 times\"); left alone it fades after 12 seconds; right click: Not now, Never after this, Never suggest this. It learns from each answer. No chip during Do Not Disturb, a meeting, a fullscreen window or quiet hours. Turn it off or set how sure it must be and how many times it must have seen it in Settings > Desktop agents > Next up.";
      fr = "Ce qu'est la pastille « Ensuite : … » à côté de la mascotte : Ensuite, Muse qui prend les devants. D'après ce que vous faites d'habitude après quelque chose (une application utilisée, une réunion qui se termine, un téléchargement, une pull request ouverte, une commande qui échoue, le début de journée, l'heure), elle propose l'étape suivante probable avant que vous la demandiez : ouvrir ou passer à une application, restaurer une disposition de fenêtres, ouvrir un lien, lancer un minuteur ou une session de concentration, lancer une routine, ou une suite que Muse rédige pour vous (le compte rendu d'une réunion, la relecture d'une pull request, le résumé d'un PDF). C'est deviné sur cet ordinateur, en code simple, sans modèle, et proposé seulement quand c'est assez probable et déjà vu assez souvent. Cliquez la pastille ou appuyez sur Super+Maj+Entrée pour le faire ; survolez-la pour savoir pourquoi (« Ouvrir Jira : ce que tu fais d'habitude après ton standup de 09:00 (14 fois) ») ; sans réponse elle s'efface après 12 secondes ; clic droit : Pas maintenant, Jamais après ceci, Ne jamais proposer ceci. Elle apprend de chaque réponse. Pas de pastille en Ne pas déranger, en réunion, avec une fenêtre en plein écran ni aux heures calmes. Désactivez-la ou réglez la certitude et le nombre de fois nécessaires dans Paramètres > Agents du bureau > Ensuite.";
      de = "Was der Chip „Als Nächstes: …“ neben dem Maskottchen ist: Als Nächstes, Muse ist dir einen Schritt voraus. Aus dem, was du nach etwas meistens tust (eine App, die du nutzt, ein Meeting, das endet, ein Download, ein geöffneter Pull Request, ein fehlgeschlagener Befehl, der Tagesbeginn, die Uhrzeit), bietet es den wahrscheinlichen nächsten Schritt an, bevor du fragst: eine App öffnen oder zu ihr wechseln, eine Fensteranordnung wiederherstellen, einen Link öffnen, einen Timer oder eine Fokus-Sitzung starten, eine Routine ausführen, oder etwas, das Muse für dich schreibt (das Follow-up eines Meetings, die Prüfung eines Pull Requests, die Zusammenfassung eines PDFs). Es wird auf diesem Computer in einfachem Code erraten, ohne Modell, und nur angeboten, wenn es wahrscheinlich genug ist und oft genug vorkam. Klicke den Chip oder drücke Super+Umschalt+Enter, um es zu tun; fahre mit der Maus darüber, um zu sehen warum („Jira öffnen: das machst du meistens nach deinem Standup um 09:00 (14-mal)“); unbeachtet verblasst er nach 12 Sekunden; Rechtsklick: Nicht jetzt, Nie danach, Nie vorschlagen. Er lernt aus jeder Antwort. Kein Chip bei Nicht stören, in einem Meeting, bei einem Vollbildfenster oder in den Ruhezeiten. Ausschalten oder einstellen, wie sicher es sein und wie oft es das gesehen haben muss, unter Einstellungen > Desktop-Agenten > Als Nächstes.";
      vi = "Mẩu \"Tiếp theo: …\" cạnh linh vật là gì: Tiếp theo, Muse đi trước bạn một bước. Từ những gì bạn thường làm sau một việc (một ứng dụng bạn dùng, một cuộc họp kết thúc, một tệp tải xuống, một pull request vừa mở, một lệnh bị lỗi, lúc bắt đầu ngày, giờ trong ngày), nó gợi ý bước tiếp theo có khả năng nhất trước khi bạn hỏi: mở hoặc chuyển sang một ứng dụng, khôi phục bố cục cửa sổ, mở một đường dẫn, hẹn giờ hoặc bắt đầu phiên tập trung, chạy một routine, hoặc việc Muse viết giúp bạn (biên bản cuộc họp, xem lại pull request, tóm tắt PDF). Nó được đoán ngay trên máy này bằng mã đơn giản, không cần mô hình, và chỉ gợi ý khi đủ chắc và đã thấy đủ nhiều lần. Bấm vào mẩu đó hoặc nhấn Super+Shift+Enter để làm; rê chuột lên để xem lý do (\"Bạn thường mở Jira sau buổi standup lúc 09:00 — 14 lần\"); nếu để yên nó mờ đi sau 12 giây; chuột phải: Để sau, Đừng sau việc này, Đừng gợi ý việc này. Nó học từ mỗi câu trả lời. Không hiện khi bật Không làm phiền, đang họp, có cửa sổ toàn màn hình hoặc trong giờ yên tĩnh. Tắt hoặc chỉnh độ chắc chắn và số lần cần thấy trong Cài đặt > Tác nhân màn hình > Tiếp theo.";
    };
    terminalAccess = {
      en = "What Muse can do in the terminal and the editor (kitty and Neovim), to help while you code: read your kitty windows (the last command's output, the screen, the scrollback, your selection, the cwd, the git branch), put a command on your prompt for you to run (it never presses Enter), run a command itself in its own kitty tab called Muse (asked first with the command and its folder shown: Allow or No; the answer shows Ran … (exit N) with Show output and a link to Muse's tab), and in the Neovim in front read the file, the cursor, your selection and the LSP diagnostics, or open a file at a line. When kitty or Neovim is in front, what it shows goes with your question (Ask about this terminal…). Password prompts and secret tools (sudo, ssh, gpg, pass, rbw…) are never read, secrets are redacted, sudo is never run (it asks you to run it), and typing into a terminal blindly stays refused. Risky commands (rm -rf, git push, reboot…) always ask; others can be trusted after three yeses (Settings > Desktop agents > Autonomy). To turn it off: Settings > Desktop agents > Terminal & coding (read, suggest, run, run in Muse's tab, editor, send the terminal with questions).";
      fr = "Ce que Muse peut faire dans le terminal et l'éditeur (kitty et Neovim), pour aider pendant que vous codez : lire vos fenêtres kitty (la sortie de la dernière commande, l'écran, l'historique, votre sélection, le dossier courant, la branche git), mettre une commande sur votre invite pour que vous la lanciez (il n'appuie jamais sur Entrée), lancer lui-même une commande dans son propre onglet kitty nommé Muse (demandé d'abord, avec la commande et son dossier : Autoriser ou Non ; la réponse affiche A lancé … (code N) avec Afficher la sortie et un lien vers l'onglet de Muse), et dans le Neovim au premier plan lire le fichier, le curseur, votre sélection et les diagnostics LSP, ou ouvrir un fichier à une ligne. Quand kitty ou Neovim est au premier plan, ce qu'il affiche part avec votre question (Demander à propos de ce terminal…). Les invites de mot de passe et les outils de secrets (sudo, ssh, gpg, pass, rbw…) ne sont jamais lus, les secrets sont masqués, sudo n'est jamais lancé (il vous demande de le faire), et taper à l'aveugle dans un terminal reste refusé. Les commandes risquées (rm -rf, git push, reboot…) demandent toujours ; les autres peuvent devenir de confiance après trois oui (Paramètres > Agents du bureau > Autonomie). Pour le désactiver : Paramètres > Agents du bureau > Terminal et code (lire, suggérer, lancer, lancer dans l'onglet de Muse, éditeur, envoyer le terminal avec les questions).";
      de = "Was Muse im Terminal und im Editor (kitty und Neovim) tun kann, um beim Programmieren zu helfen: deine kitty-Fenster lesen (die Ausgabe des letzten Befehls, den Bildschirm, den Verlauf, deine Auswahl, das Arbeitsverzeichnis, den Git-Zweig), einen Befehl auf deine Eingabezeile legen, den du selbst ausführst (es drückt nie Enter), selbst einen Befehl in seinem eigenen kitty-Tab namens Muse ausführen (vorher gefragt, mit Befehl und Ordner: Erlauben oder Nein; die Antwort zeigt Ausgeführt … (Code N) mit Ausgabe zeigen und einem Link zu Muses Tab), und im Neovim im Vordergrund die Datei, den Cursor, deine Auswahl und die LSP-Diagnosen lesen oder eine Datei an einer Zeile öffnen. Ist kitty oder Neovim im Vordergrund, geht das Angezeigte mit deiner Frage mit (Frag zu diesem Terminal…). Passwortabfragen und Geheimnis-Werkzeuge (sudo, ssh, gpg, pass, rbw…) werden nie gelesen, Geheimnisse geschwärzt, sudo wird nie ausgeführt (es bittet dich darum), und blindes Tippen in ein Terminal bleibt verweigert. Riskante Befehle (rm -rf, git push, reboot…) fragen immer; andere können nach drei Ja vertraut werden (Einstellungen > Desktop-Agenten > Autonomie). Zum Ausschalten: Einstellungen > Desktop-Agenten > Terminal & Programmieren (lesen, vorschlagen, ausführen, in Muses Tab ausführen, Editor, das Terminal mit Fragen senden).";
      vi = "Muse làm được gì trong terminal và trình soạn thảo (kitty và Neovim) để giúp bạn khi viết code: đọc các cửa sổ kitty (kết quả lệnh vừa chạy, màn hình, lịch sử cuộn, phần bạn chọn, thư mục hiện tại, nhánh git), đặt một lệnh lên dấu nhắc để bạn tự chạy (nó không bao giờ nhấn Enter), tự chạy một lệnh trong thẻ kitty riêng tên Muse (hỏi trước, hiện lệnh và thư mục: Cho phép hoặc Không; câu trả lời ghi Đã chạy … (mã N) kèm Xem kết quả và liên kết tới thẻ của Muse), và trong Neovim đang mở phía trước thì đọc tệp, con trỏ, phần chọn và chẩn đoán LSP, hoặc mở một tệp ở một dòng. Khi kitty hoặc Neovim ở phía trước, nội dung nó hiển thị được gửi kèm câu hỏi (Hỏi về terminal này…). Dấu nhắc mật khẩu và công cụ bí mật (sudo, ssh, gpg, pass, rbw…) không bao giờ bị đọc, bí mật được che đi, sudo không bao giờ được chạy (nó nhờ bạn chạy), và gõ mù vào terminal vẫn bị từ chối. Lệnh rủi ro (rm -rf, git push, reboot…) luôn hỏi; các lệnh khác có thể được tin cậy sau ba lần đồng ý (Cài đặt > Tác nhân màn hình > Tự chủ). Để tắt: Cài đặt > Tác nhân màn hình > Terminal và lập trình (đọc, gợi ý, chạy, chạy trong thẻ của Muse, trình soạn thảo, gửi terminal kèm câu hỏi).";
    };
    desktopMascot = {
      en = "Muse lives on your desktop as a little robot (the Full AI mascot) in a corner of the screen you're on. It looks at the window you switch to, perks up at a notification and looks worried at an error, thinks while Muse works, moves its mouth while Muse talks, jumps when something is done (a task, a background task, a command that works after failing), dozes when you're away and stretches when you come back. Click it to call Muse's bubble. Now and then it says a little word about what's in front, the time or the weather (the small model, 20 to 40 minutes apart at most, never in quiet hours, Do Not Disturb, a meeting, a fullscreen app or while desktop control is paused; not with AI set to local only). It hides while the screen is locked, in front of fullscreen apps and in Full AI mode. Settings > Desktop agents > Muse on the desktop: show it or not, the corner, the little words and how many a day, when it dozes.";
      fr = "Muse vit sur votre bureau en petit robot (la mascotte du mode IA complète), dans un coin de l'écran où vous êtes. Elle regarde la fenêtre vers laquelle vous passez, se redresse à une notification et s'inquiète d'une erreur, réfléchit pendant que Muse travaille, bouge la bouche quand Muse parle, saute quand quelque chose est fait (une tâche, une tâche de fond, une commande qui marche après avoir échoué), s'assoupit quand vous êtes absent et s'étire à votre retour. Cliquez dessus pour appeler la bulle de Muse. De temps en temps elle dit un petit mot sur ce qui est devant vous, l'heure ou la météo (le petit modèle, 20 à 40 minutes d'écart au plus, jamais en heures calmes, en Ne pas déranger, en réunion, devant une app plein écran ou quand le contrôle du bureau est en pause ; pas avec l'IA en local seulement). Elle se cache quand l'écran est verrouillé, devant une app plein écran et en mode IA complète. Paramètres > Agents du bureau > Muse sur le bureau : l'afficher ou non, le coin, les petits mots et combien par jour, quand elle s'assoupit.";
      de = "Muse wohnt als kleiner Roboter (das Maskottchen des vollen KI-Modus) in einer Ecke des Bildschirms, an dem du bist. Er schaut zum Fenster, zu dem du wechselst, horcht bei einer Benachrichtigung auf und schaut bei einem Fehler besorgt, denkt nach, während Muse arbeitet, bewegt den Mund, während Muse spricht, springt, wenn etwas erledigt ist (eine Aufgabe, eine Hintergrundaufgabe, ein Befehl, der nach einem Fehler klappt), döst, wenn du weg bist, und streckt sich, wenn du zurückkommst. Klick ihn an, um Muses Blase zu rufen. Ab und zu sagt er ein kleines Wort über das, was vorne ist, die Uhrzeit oder das Wetter (das kleine Modell, höchstens alle 20 bis 40 Minuten, nie in Ruhezeiten, bei Nicht stören, in einem Termin, vor einer Vollbild-App oder wenn die Desktop-Steuerung pausiert ist; nicht mit KI nur lokal). Er versteckt sich bei gesperrtem Bildschirm, vor Vollbild-Apps und im vollen KI-Modus. Einstellungen > Desktop-Agenten > Muse auf dem Desktop: anzeigen oder nicht, die Ecke, die kleinen Worte und wie viele am Tag, wann er döst.";
      vi = "Muse sống trên màn hình của bạn như một chú robot nhỏ (linh vật của chế độ AI toàn phần) ở một góc của màn hình bạn đang dùng. Nó nhìn về cửa sổ bạn chuyển sang, ngóc lên khi có thông báo và lo lắng khi có lỗi, suy nghĩ khi Muse làm việc, mấp máy miệng khi Muse nói, nhảy lên khi việc gì đó xong (một tác vụ, một tác vụ nền, một lệnh chạy được sau khi lỗi), ngủ gật khi bạn vắng mặt và vươn vai khi bạn quay lại. Bấm vào nó để gọi bong bóng của Muse. Thỉnh thoảng nó nói một câu nhỏ về thứ đang ở phía trước, giờ giấc hay thời tiết (mô hình nhỏ, cách nhau ít nhất 20 đến 40 phút, không bao giờ trong giờ yên tĩnh, Không làm phiền, cuộc họp, ứng dụng toàn màn hình hay khi điều khiển màn hình bị tạm dừng; không khi AI chỉ chạy cục bộ). Nó ẩn đi khi màn hình bị khóa, trước ứng dụng toàn màn hình và trong chế độ AI toàn phần. Cài đặt > Tác nhân màn hình > Muse trên màn hình: hiện hay không, góc, các câu nhỏ và bao nhiêu mỗi ngày, khi nào nó ngủ gật.";
    };
    smartClipboard = {
      en = "The smart clipboard: copy something and the right action shows for about 8 seconds as chips over Muse on the desktop (beside its bubble when the mascot is off), for example \"Copied a tracking number — Track it · Not now\". Click a chip, or press Mod+Alt+V for the first one; it never takes the keyboard. What it recognizes: a tracking number (UPS, FedEx, DHL, La Poste, Colissimo, Chronopost: Track it), an address (Directions, Show on the map), a date or time like \"next Tuesday 3pm\" or \"le 12 novembre à 14h\" (Add to calendar: the Calendar's editor opens filled in, you save it), text in another language (Translate), an error or a stack trace (Explain it, Fix it), a link (Summarize the page, Open), a phone number (Call or Text from the phone, with KDE Connect), an e-mail address (Write to…), a long text (Summarize, Rewrite), code (Explain) and an amount (Convert). It is read on this computer in plain code; only the AI actions send the text to the model, with private details hidden. Never from a password manager, never passwords, one-time codes, keys or card numbers. Quiet in Do Not Disturb, meetings and fullscreen apps: the clipboard history (Mod+Q) still offers the action. A kind you ignore 5 times in a row is no longer offered, and what you use comes first. Settings > Desktop agents > Smart clipboard: the switch, one switch per kind, and Offer them again.";
      fr = "Le presse-papiers intelligent : copiez quelque chose et la bonne action s'affiche environ 8 secondes en pastilles au-dessus de Muse sur le bureau (à côté de sa bulle si la mascotte est masquée), par exemple « Numéro de suivi copié — Suivre · Pas maintenant ». Cliquez une pastille, ou appuyez sur Mod+Alt+V pour la première ; il ne prend jamais le clavier. Ce qu'il reconnaît : un numéro de suivi (UPS, FedEx, DHL, La Poste, Colissimo, Chronopost : Suivre), une adresse (Itinéraire, Voir sur la carte), une date ou une heure comme « le 12 novembre à 14h » ou « next Tuesday 3pm » (Ajouter à l'agenda : l'éditeur de l'Agenda s'ouvre rempli, vous l'enregistrez), un texte dans une autre langue (Traduire), une erreur ou une trace de pile (Expliquer, Corriger), un lien (Résumer la page, Ouvrir), un numéro de téléphone (Appeler ou Envoyer un SMS depuis le téléphone, avec KDE Connect), une adresse e-mail (Écrire à…), un long texte (Résumer, Reformuler), du code (Expliquer) et un montant (Convertir). C'est lu sur cet ordinateur, en code simple ; seules les actions IA envoient le texte au modèle, détails privés masqués. Jamais depuis un gestionnaire de mots de passe, jamais de mots de passe, codes à usage unique, clés ou numéros de carte. Silencieux en Ne pas déranger, en réunion et devant une application plein écran : l'historique du presse-papiers (Mod+Q) propose toujours l'action. Un type ignoré 5 fois de suite n'est plus proposé, et ce que vous utilisez passe en premier. Paramètres > Agents du bureau > Presse-papiers intelligent : l'interrupteur, un interrupteur par type, et Les proposer à nouveau.";
      de = "Die intelligente Zwischenablage: Kopiere etwas, und die passende Aktion erscheint etwa 8 Sekunden lang als Chips über Muse auf dem Desktop (neben der Sprechblase, wenn das Maskottchen aus ist), zum Beispiel „Sendungsnummer kopiert — Verfolgen · Nicht jetzt“. Klicke auf einen Chip oder drücke Mod+Alt+V für den ersten; sie nimmt nie die Tastatur. Was sie erkennt: eine Sendungsnummer (UPS, FedEx, DHL, La Poste, Colissimo, Chronopost: Verfolgen), eine Adresse (Route, Auf der Karte zeigen), ein Datum oder eine Uhrzeit wie „nächsten Dienstag um 15 Uhr“ oder „le 12 novembre à 14h“ (Zum Kalender hinzufügen: der Editor des Kalenders öffnet sich ausgefüllt, du speicherst), Text in einer anderen Sprache (Übersetzen), einen Fehler oder einen Stacktrace (Erklären, Beheben), einen Link (Seite zusammenfassen, Öffnen), eine Telefonnummer (Vom Handy anrufen oder eine SMS schreiben, mit KDE Connect), eine E-Mail-Adresse (Schreiben an…), einen langen Text (Zusammenfassen, Umformulieren), Code (Erklären) und einen Betrag (Umrechnen). Gelesen wird auf diesem Computer, in einfachem Code; nur die KI-Aktionen schicken den Text an das Modell, private Angaben verborgen. Nie aus einem Passwortmanager, nie Passwörter, Einmalcodes, Schlüssel oder Kartennummern. Still bei Nicht stören, in Besprechungen und vor Vollbild-Apps: der Zwischenablage-Verlauf (Mod+Q) bietet die Aktion trotzdem an. Eine Art, die du 5-mal hintereinander ignorierst, wird nicht mehr angeboten, und was du nutzt, kommt zuerst. Einstellungen > Desktop-Agenten > Intelligente Zwischenablage: der Schalter, ein Schalter pro Art und Wieder anbieten.";
      vi = "Bộ nhớ tạm thông minh: sao chép một thứ gì đó và hành động phù hợp hiện ra khoảng 8 giây dưới dạng các nút nhỏ phía trên Muse trên màn hình (cạnh bong bóng của nó khi tắt linh vật), ví dụ \"Đã sao chép mã vận đơn — Theo dõi · Để sau\". Bấm một nút, hoặc nhấn Mod+Alt+V cho nút đầu tiên; nó không bao giờ chiếm bàn phím. Những gì nó nhận ra: mã vận đơn (UPS, FedEx, DHL, La Poste, Colissimo, Chronopost: Theo dõi), địa chỉ (Chỉ đường, Xem trên bản đồ), ngày giờ như \"3 giờ chiều ngày mai\" hay \"next Tuesday 3pm\" (Thêm vào lịch: trình soạn của Lịch mở ra đã điền sẵn, bạn lưu), văn bản bằng ngôn ngữ khác (Dịch), lỗi hoặc stack trace (Giải thích, Sửa), liên kết (Tóm tắt trang, Mở), số điện thoại (Gọi hoặc Nhắn tin từ điện thoại, qua KDE Connect), địa chỉ e-mail (Viết cho…), văn bản dài (Tóm tắt, Viết lại), code (Giải thích) và số tiền (Quy đổi). Việc nhận dạng diễn ra trên máy này, bằng code đơn giản; chỉ các hành động AI mới gửi văn bản cho mô hình, thông tin riêng tư được che. Không bao giờ từ trình quản lý mật khẩu, không bao giờ mật khẩu, mã dùng một lần, khóa hay số thẻ. Im lặng khi Không làm phiền, khi họp và trước ứng dụng toàn màn hình: lịch sử bộ nhớ tạm (Mod+Q) vẫn có hành động đó. Loại bạn bỏ qua 5 lần liên tiếp sẽ không được đề xuất nữa, và thứ bạn dùng được đưa lên trước. Cài đặt > Tác nhân màn hình > Bộ nhớ tạm thông minh: công tắc, một công tắc cho mỗi loại, và Đề xuất lại.";
    };
    modelRouting = {
      en = "To choose which model does what: Settings > Desktop agents > Accuracy and models. Model for Muse in the bubble (small by default: fastest); Model for decisions made for you (big by default), used whenever the AI decides on your behalf: reading your notifications, the initiative's words, pairing, a routine's judgment, Full AI mode's reactions and what an ambiguous request means, with its own thinking level; Full AI reactions an hour at most (30 by default, 0 for no limit). The side panel keeps its own model (Muse in the side panel), the memory passes theirs.";
      fr = "Pour choisir quel modèle fait quoi : Paramètres > Agents du bureau > Précision et modèles. Modèle pour Muse dans la bulle (petit par défaut : le plus rapide) ; Modèle pour les décisions prises pour vous (grand par défaut), utilisé chaque fois que l'IA décide à votre place : lire vos notifications, les mots de l'initiative, le binôme, le jugement d'une routine, les réactions du mode IA complète et le sens d'une demande ambiguë, avec son propre niveau de réflexion ; Réactions de l'IA complète par heure au plus (30 par défaut, 0 sans limite). Le panneau latéral garde son propre modèle (Muse dans le panneau latéral), les passes de mémoire le leur.";
      de = "Um zu wählen, welches Modell was macht: Einstellungen > Desktop-Agenten > Genauigkeit und Modelle. Modell für Muse in der Blase (standardmäßig klein: am schnellsten); Modell für Entscheidungen in deinem Namen (standardmäßig groß), immer dann benutzt, wenn die KI für dich entscheidet: deine Benachrichtigungen lesen, die Worte der Initiative, das Pairing, das Urteil einer Routine, die Reaktionen des vollen KI-Modus und was eine mehrdeutige Anfrage bedeutet, mit eigener Denkstufe; Reaktionen des vollen KI-Modus pro Stunde höchstens (standardmäßig 30, 0 ohne Grenze). Die Seitenleiste behält ihr eigenes Modell (Muse in der Seitenleiste), die Gedächtnisdurchläufe ihres.";
      vi = "Để chọn mô hình nào làm việc gì: Cài đặt > Tác nhân màn hình > Độ chính xác và mô hình. Mô hình cho Muse trong bong bóng (mặc định nhỏ: nhanh nhất); Mô hình cho các quyết định thay bạn (mặc định lớn), dùng mỗi khi AI quyết định thay bạn: đọc thông báo, lời của chế độ chủ động, ghép cặp, phán đoán của một thói quen, phản ứng của chế độ AI toàn phần và ý nghĩa của một yêu cầu chưa rõ, với mức suy nghĩ riêng; Số phản ứng của AI toàn phần tối đa mỗi giờ (mặc định 30, 0 là không giới hạn). Bảng bên giữ mô hình riêng của nó (Muse ở bảng bên), các lượt ghi nhớ giữ mô hình của chúng.";
    };
    fastCommands = {
      en = "Plain commands are done at once, with no AI model and no tokens, in the speech bubble (typed or said with Mod+T), also in the middle of a conversation: the music (pause the music, play, next song, previous song), the volume (volume 30, volume up, volume down, mute the sound), the brightness, an app (open Firefox, close Firefox, switch to Firefox), workspaces (workspace 2, next workspace, move window to workspace 3), dark or light mode, Do Not Disturb on or off, night light on or off, a screenshot, lock the screen, a timer, a pomodoro, a saved layout, a task, the settings. In English, French, German or Vietnamese. The bubble says Done: … with an Undo button when it can be undone, and Muse hears of it with your next message. In a conversation only commands that name what they act on go this way: pause it, open the file I just downloaded or the other one go to Muse, who knows what you were talking about.";
      fr = "Les commandes simples sont faites tout de suite, sans modèle d'IA ni jetons, dans la bulle (tapées ou dites avec Mod+T), aussi au milieu d'une conversation : la musique (mets la musique en pause, reprends la musique, chanson suivante, chanson précédente), le volume (volume à 30, monte le son, baisse le son, coupe le son), la luminosité, une app (ouvre Firefox, ferme Firefox, passe à Firefox), les bureaux (bureau 2, bureau suivant, déplace la fenêtre sur le bureau 3), le mode sombre ou clair, Ne pas déranger, la lumière nocturne, une capture d'écran, verrouiller l'écran, un minuteur, un pomodoro, une disposition enregistrée, une tâche, les paramètres. En français, anglais, allemand ou vietnamien. La bulle dit Fait : … avec un bouton Annuler quand c'est annulable, et Muse l'apprend avec votre message suivant. Dans une conversation, seules les commandes qui nomment ce sur quoi elles agissent passent par là : mets-la en pause, ouvre le fichier que je viens de télécharger ou l'autre vont à Muse, qui sait de quoi vous parliez.";
      de = "Einfache Befehle werden sofort ausgeführt, ohne KI-Modell und ohne Tokens, in der Sprechblase (getippt oder mit Mod+T gesagt), auch mitten in einem Gespräch: die Musik (pausiere die Musik, spiel die Musik, nächstes Lied, vorheriges Lied), die Lautstärke (Lautstärke auf 30, lauter, leiser, Ton aus), die Helligkeit, eine App (öffne Firefox, schließe Firefox, wechsle zu Firefox), Arbeitsbereiche (Arbeitsbereich 2, nächster Arbeitsbereich, verschiebe das Fenster auf Arbeitsbereich 3), dunkler oder heller Modus, Nicht stören an oder aus, Nachtlicht an oder aus, ein Bildschirmfoto, Bildschirm sperren, ein Timer, ein Pomodoro, eine gespeicherte Anordnung, eine Aufgabe, die Einstellungen. Auf Deutsch, Englisch, Französisch oder Vietnamesisch. Die Blase sagt Erledigt: … mit einem Rückgängig-Knopf, wenn es rückgängig zu machen ist, und Muse erfährt es mit deiner nächsten Nachricht. In einem Gespräch gehen nur Befehle, die nennen, worauf sie wirken, diesen Weg: pausier es, öffne die Datei, die ich gerade heruntergeladen habe, oder das andere gehen an Muse, die weiß, worüber ihr gesprochen habt.";
      vi = "Các lệnh đơn giản được làm ngay, không cần mô hình AI và không tốn token, trong bong bóng (gõ hoặc nói bằng Mod+T), kể cả giữa cuộc trò chuyện: nhạc (tạm dừng nhạc, phát nhạc, bài tiếp theo, bài trước), âm lượng (âm lượng 30, tăng âm lượng, giảm âm lượng, tắt tiếng), độ sáng, ứng dụng (mở Firefox, đóng Firefox, chuyển sang Firefox), không gian làm việc (không gian làm việc 2, không gian làm việc tiếp theo, chuyển cửa sổ sang không gian làm việc 3), chế độ tối hoặc sáng, bật hoặc tắt không làm phiền, đèn ngủ, chụp màn hình, khóa màn hình, hẹn giờ, pomodoro, bố cục đã lưu, một việc cần làm, cài đặt. Bằng tiếng Việt, Anh, Pháp hoặc Đức. Bong bóng ghi Xong: … kèm nút Hoàn tác khi hoàn tác được, và Muse biết việc đó ở tin nhắn tiếp theo của bạn. Trong một cuộc trò chuyện, chỉ những lệnh nêu rõ đối tượng mới đi đường này: tạm dừng nó, mở tệp tôi vừa tải về hay cái kia sẽ do Muse làm, vì nó biết bạn đang nói về gì.";
    };
    speedSettings = {
      en = "How Muse is fast and uses few tokens: plain commands need no model at all; Muse's answer shows and is read out as it is written (the first sentence plays before the answer is over), its tools start while it is still writing, the bubble says Doing … the moment one starts, and its checks come after the answer is shown (… Checking it worked, then Checked or Couldn't confirm). Settings > Desktop agents > Accuracy and models: Model that tells whether a request is ambiguous and Model that checks the result (small by default: they run only when needed, the ambiguity check beside the answer); Speed: Minimal thinking for the checks, the reactions and the one-shot answers, Only the core desktop tools up front (the others loaded when needed), and Keep Muse's agent running after the last message (60 minutes while unlocked, so the next message doesn't wait for it to start; started again when you unlock). Its prompt carries a short summary of this machine; how-tos, packages and keymaps are looked up with its machine_help tool when a question needs them.";
      fr = "Comment Muse est rapide et consomme peu de jetons : les commandes simples n'ont besoin d'aucun modèle ; la réponse de Muse s'affiche et est lue à voix haute au fil de l'écriture (la première phrase joue avant la fin de la réponse), ses outils démarrent pendant qu'elle écrit encore, la bulle dit En train de … dès qu'un outil démarre, et ses vérifications arrivent après la réponse affichée (… Vérification, puis Vérifié ou Pas pu confirmer). Paramètres > Agents du bureau > Précision et modèles : Modèle qui juge si une demande est ambiguë et Modèle qui vérifie le résultat (petit par défaut : ils ne tournent que si besoin, le jugement d'ambiguïté à côté de la réponse) ; Vitesse : Réflexion minimale pour les vérifications, les réactions et les réponses ponctuelles, Seulement les outils de bureau essentiels d'emblée (les autres chargés au besoin), et Garder l'agent de Muse lancé après le dernier message (60 minutes session déverrouillée, pour que le message suivant n'attende pas son démarrage ; relancé au déverrouillage). Son prompt contient un court résumé de cette machine ; les modes d'emploi, paquets et raccourcis sont cherchés avec son outil machine_help quand une question en a besoin.";
      de = "Wie Muse schnell ist und wenig Tokens braucht: einfache Befehle brauchen gar kein Modell; Muses Antwort erscheint und wird vorgelesen, während sie geschrieben wird (der erste Satz klingt, bevor die Antwort fertig ist), ihre Werkzeuge starten, während sie noch schreibt, die Blase sagt Mache … sobald eines startet, und ihre Prüfungen kommen nach der angezeigten Antwort (… Prüfe, dann Geprüft oder Konnte nicht bestätigen). Einstellungen > Desktop-Agenten > Genauigkeit und Modelle: Modell, das erkennt, ob eine Anfrage mehrdeutig ist, und Modell, das das Ergebnis prüft (standardmäßig klein: sie laufen nur bei Bedarf, die Mehrdeutigkeitsprüfung neben der Antwort); Geschwindigkeit: Minimales Nachdenken für Prüfungen, Reaktionen und Einmal-Antworten, Nur die wichtigsten Desktop-Werkzeuge vorab (die anderen bei Bedarf geladen) und Muses Agent nach der letzten Nachricht laufen lassen (60 Minuten bei entsperrter Sitzung, damit die nächste Nachricht nicht auf seinen Start wartet; beim Entsperren neu gestartet). Ihr Prompt enthält eine kurze Zusammenfassung dieses Rechners; Anleitungen, Pakete und Tastenkürzel schlägt sie mit ihrem Werkzeug machine_help nach, wenn eine Frage sie braucht.";
      vi = "Vì sao Muse nhanh và ít tốn token: lệnh đơn giản không cần mô hình nào; câu trả lời của Muse hiện ra và được đọc to ngay khi đang viết (câu đầu tiên phát trước khi trả lời xong), công cụ của nó chạy ngay khi nó còn đang viết, bong bóng ghi Đang … ngay khi một công cụ bắt đầu, và bước kiểm tra đến sau khi câu trả lời đã hiện (… Đang kiểm tra, rồi Đã kiểm tra hoặc Không xác nhận được). Cài đặt > Tác nhân màn hình > Độ chính xác và mô hình: Mô hình xét yêu cầu có mơ hồ không và Mô hình kiểm tra kết quả (mặc định nhỏ: chỉ chạy khi cần, việc xét mơ hồ chạy song song với câu trả lời); Tốc độ: Suy nghĩ tối thiểu cho kiểm tra, phản ứng và câu trả lời một lần, Chỉ các công cụ màn hình chính lúc đầu (các công cụ khác tải khi cần), và Giữ tác nhân của Muse chạy sau tin nhắn cuối (60 phút khi phiên mở khóa, để tin nhắn sau không phải chờ nó khởi động; chạy lại khi mở khóa). Prompt của nó chỉ có bản tóm tắt ngắn về máy này; hướng dẫn, gói và phím tắt được tra bằng công cụ machine_help khi câu hỏi cần.";
    };
    voiceControl = {
      en = "To talk to your desktop: press Mod+T, say what you want (\"open Firefox on workspace 3\", \"pause the music\", \"what's on my calendar today?\") and stop talking: it is done. With Meta as the model provider your voice is streamed to Muse Voice Transcribe, your words show in the bubble as you speak and it knows when you've finished, so nothing heavy runs on your computer; otherwise whisper.cpp transcribes it here after a short silence (nothing leaves the computer). Mod+T again stops early, Esc cancels. Settings > Desktop agents > Talk to your desktop: Voice turns it off, Voice transcribed by picks Auto, Meta or This computer. Talk naturally: a pause in a sentence is fine, it ends after a longer one (1.8 s), up to 2 minutes. Talk back and forth (on by default): once it has answered, the mic opens again by itself; say yes or no when it asks before a step; say that's all, thanks or merci, press Esc, or stay silent 8 s to end.";
      fr = "Pour parler à votre bureau : appuyez sur Mod+T, dites ce que vous voulez (« ouvre Firefox sur l'espace 3 », « mets la musique en pause », « qu'est-ce que j'ai au calendrier aujourd'hui ? ») et arrêtez de parler : c'est fait. Avec Meta comme fournisseur de modèles, votre voix est envoyée en continu à Muse Voice Transcribe, vos mots s'affichent dans la bulle pendant que vous parlez et il sait quand vous avez fini, rien de lourd ne tourne sur votre ordinateur ; sinon whisper.cpp la transcrit ici après un court silence (rien ne sort de l'ordinateur). Mod+T de nouveau arrête plus tôt, Échap annule. Paramètres > Agents du bureau > Parler à son bureau : Voix le désactive, Voix transcrite par choisit Auto, Meta ou Cet ordinateur. Parlez naturellement : une pause dans une phrase ne coupe pas, il s'arrête après une pause plus longue (1,8 s), jusqu'à 2 minutes. Dialogue (activé par défaut) : une fois qu'il a répondu, le micro se rouvre tout seul ; dites oui ou non quand il demande avant une étape ; dites c'est tout, merci ou that's all, appuyez sur Échap ou restez 8 s sans parler pour finir.";
      de = "Um mit deinem Desktop zu sprechen: Drücke Mod+T, sag, was du willst („öffne Firefox auf Arbeitsbereich 3“, „pausiere die Musik“, „was steht heute in meinem Kalender?“) und hör auf zu sprechen: es wird erledigt. Mit Meta als Modellanbieter wird deine Stimme laufend an Muse Voice Transcribe gestreamt, deine Worte erscheinen beim Sprechen in der Blase und es erkennt, wann du fertig bist, auf deinem Computer läuft nichts Schweres; sonst transkribiert whisper.cpp hier nach einer kurzen Stille (nichts verlässt den Computer). Mod+T erneut beendet früher, Esc bricht ab. Einstellungen > Desktop-Agenten > Mit dem Desktop reden: Stimme schaltet es aus, Stimme transkribiert von wählt Auto, Meta oder Dieser Computer. Sprich natürlich: eine Pause im Satz ist kein Problem, es endet nach einer längeren (1,8 s), bis zu 2 Minuten. Hin und her reden (standardmäßig an): nach der Antwort öffnet sich das Mikro von selbst wieder; sag ja oder nein, wenn es vor einem Schritt fragt; sag das ist alles, danke oder that's all, drück Esc oder schweig 8 s, um zu enden.";
      vi = "Để nói chuyện với màn hình: nhấn Mod+T, nói điều bạn muốn (\"mở Firefox ở không gian làm việc 3\", \"tạm dừng nhạc\", \"hôm nay lịch của tôi có gì?\") rồi ngừng nói: việc sẽ được làm. Khi Meta là nhà cung cấp mô hình, giọng nói được truyền liên tục đến Muse Voice Transcribe, chữ hiện trong bong bóng ngay khi bạn nói và nó biết khi nào bạn nói xong, máy tính của bạn không phải chạy gì nặng; nếu không, whisper.cpp chuyển thành chữ ngay trên máy sau một khoảng lặng ngắn (không gì rời khỏi máy). Nhấn Mod+T lần nữa để dừng sớm, Esc để hủy. Cài đặt > Tác nhân màn hình > Nói chuyện với màn hình: Giọng nói để tắt, Chuyển giọng nói bằng để chọn Tự động, Meta hoặc Máy này. Hãy nói tự nhiên: dừng giữa câu không sao, nó kết thúc sau một khoảng dừng dài hơn (1,8 giây), tối đa 2 phút. Trò chuyện qua lại (bật mặc định): sau khi trả lời, micro tự mở lại; nói có hoặc không khi nó hỏi trước một bước; nói cảm ơn, thôi hoặc that's all, nhấn Esc hoặc im lặng 8 giây để kết thúc.";
    };
    kiroshiScan = {
      en = "Kiroshi scan (Mod+K) turns the screen into a brief: at the top, Focus (the one thing that matters now) and Doing (what you are in the middle of), from the screen plus your recent windows, notifications and next events; what matters is framed on the screen, coloured by urgency (now, soon, later, noise), the items worth acting on first. Open an item (click or its number) for its facts (who, what, when, the numbers, what is asked of you), why it matters and the next step, then up to three offers (A, B, C), each with the effort it saves; it only offers what saves real work (a reply drafted with the context, a date in a message added to your calendar, a request filed as a task with its due date, an error's fix, a long thread summed up in a note, a reminder, several notifications cleared at once), never a click you would do as fast. A one-step offer runs at once and shows its result in the card; one that sends something, like a reply, shows the draft and waits for Send; a bigger one hands its plan and editable draft to Muse in the bubble. Enter takes the best offer; Copy draft; Tell me more for a closer look. The offers you use are remembered, so the next scans offer more of that kind. Handle the routine ones does every item the AI can deal with alone at once. Esc closes. The screenshot and that context go to the model provider (Meta: Muse Spark).";
      fr = "Le scan Kiroshi (Mod+K) transforme l'écran en un point de situation : en haut, Focus (la chose qui compte maintenant) et En cours (ce que vous êtes en train de faire), à partir de l'écran, de vos fenêtres récentes, des notifications et des prochains événements ; ce qui compte est encadré à l'écran, coloré selon l'urgence (maintenant, bientôt, plus tard, bruit), les éléments où agir en premier. Ouvrez un élément (clic ou son numéro) pour ses faits (qui, quoi, quand, les chiffres, ce qu'on vous demande), pourquoi il compte et la prochaine étape, puis jusqu'à trois propositions (A, B, C), chacune avec le temps qu'elle fait gagner ; il ne propose que ce qui épargne un vrai travail (une réponse rédigée avec le contexte, une date d'un message ajoutée à l'agenda, une demande notée en tâche avec son échéance, la correction d'une erreur, un long fil résumé dans une note, un rappel, plusieurs notifications effacées d'un coup), jamais un clic que vous feriez aussi vite. Une proposition en une étape se fait tout de suite et montre son résultat dans la carte ; celle qui envoie quelque chose, comme une réponse, montre le brouillon et attend Envoyer ; une plus grande confie son plan et son brouillon modifiable à Muse dans la bulle. Entrée prend la meilleure proposition ; Copier le brouillon ; En savoir plus pour regarder de plus près. Les propositions que vous utilisez sont retenues, et les scans suivants en proposent davantage de ce genre. Gérer les tâches de routine fait d'un coup tout ce que l'IA peut faire seule. Échap ferme. La capture et ce contexte partent chez le fournisseur de modèles (Meta : Muse Spark).";
      de = "Der Kiroshi-Scan (Mod+K) macht aus dem Bildschirm eine Lagebesprechung: oben Fokus (das eine, was jetzt zählt) und Gerade dabei (woran du arbeitest), aus dem Bildschirm, deinen letzten Fenstern, Benachrichtigungen und nächsten Terminen; das Wichtige ist auf dem Bildschirm eingerahmt, nach Dringlichkeit gefärbt (jetzt, bald, später, Rauschen), was sich zu erledigen lohnt zuerst. Öffne einen Eintrag (Klick oder seine Nummer) für seine Fakten (wer, was, wann, die Zahlen, worum du gebeten wirst), warum es zählt und den nächsten Schritt, dann bis zu drei Angebote (A, B, C), jedes mit der Mühe, die es spart; angeboten wird nur, was echte Arbeit spart (eine Antwort mit dem Kontext entworfen, ein Datum aus einer Nachricht in den Kalender, eine Bitte als Aufgabe mit Fälligkeit, die Lösung eines Fehlers, ein langer Verlauf als Notiz zusammengefasst, eine Erinnerung, mehrere Benachrichtigungen auf einmal entfernt), nie ein Klick, den du genauso schnell machst. Ein Angebot in einem Schritt läuft sofort und zeigt sein Ergebnis in der Karte; eines, das etwas sendet, wie eine Antwort, zeigt den Entwurf und wartet auf Senden; ein größeres übergibt seinen Plan und den bearbeitbaren Entwurf an Muse in der Blase. Enter nimmt das beste Angebot; Entwurf kopieren; Mehr erfahren für einen genaueren Blick. Die Angebote, die du nutzt, werden gemerkt, und die nächsten Scans bieten mehr davon an. Routine erledigen macht alles, was die KI allein kann, auf einmal. Esc schließt. Der Screenshot und dieser Kontext gehen an den Modellanbieter (Meta: Muse Spark).";
      vi = "Quét Kiroshi (Mod+K) biến màn hình thành một bản tóm tắt tình hình: phía trên là Trọng tâm (việc quan trọng nhất lúc này) và Đang làm (việc bạn đang dở), dựa trên màn hình, các cửa sổ gần đây, thông báo và sự kiện sắp tới; những gì quan trọng được đóng khung trên màn hình, tô màu theo mức khẩn (ngay, sắp, sau, nhiễu), mục đáng xử lý nhất đứng đầu. Mở một mục (nhấp hoặc nhấn số của nó) để xem các dữ kiện (ai, cái gì, khi nào, con số, điều người ta nhờ bạn), vì sao nó quan trọng và bước tiếp theo, rồi tối đa ba đề xuất (A, B, C), mỗi cái kèm công sức nó tiết kiệm; nó chỉ đề xuất những gì thật sự đỡ việc (một câu trả lời soạn sẵn theo ngữ cảnh, một ngày giờ trong tin nhắn thêm vào lịch, một yêu cầu ghi thành việc cần làm có hạn chót, cách sửa một lỗi, một chuỗi dài tóm tắt vào ghi chú, một lời nhắc, xóa nhiều thông báo cùng lúc), không bao giờ là một cú nhấp bạn tự làm nhanh bằng. Đề xuất một bước chạy ngay và hiện kết quả trong thẻ; đề xuất gửi đi thứ gì, như một câu trả lời, hiện bản nháp và chờ bạn bấm Gửi; đề xuất lớn hơn giao kế hoạch và bản nháp sửa được cho Muse trong bong bóng. Enter chọn đề xuất tốt nhất; Sao chép bản nháp; Xem thêm để nhìn kỹ hơn. Những đề xuất bạn dùng được ghi nhớ, và các lần quét sau sẽ đề xuất nhiều hơn loại đó. Xử lý việc thường ngày làm cùng lúc mọi mục AI tự làm được. Esc để đóng. Ảnh chụp màn hình và ngữ cảnh đó được gửi đến nhà cung cấp mô hình (Meta: Muse Spark).";
    };
    fullAiMode = {
      en = "Full AI mode (Mod+Shift+T, or Settings > Desktop agents > Talk to your desktop > Full AI mode): the AI runs the desktop and you just talk. A cute mascot moves around the screen showing what it hears, what it is doing and its answers. You keep your keyboard and mouse: it never takes them. Mod+Shift+T again (or Esc in the bubble) leaves the mode. With Show the bubble set to Only when needed, it answers out loud and in the mascot's balloon, without the bubble; Mod+C shows or hides it. The microphone stays open, even while it works, so you can keep giving orders; Mod+T turns it off or on. Say yes or no when it asks before a step. It also reacts to what happens (notifications, downloads, low battery, a screen plugged in, you coming back): it ignores noise, tells you, asks what to do, or does it on its own when you told it to or agreed twice before; it learns from every answer and saves lasting preferences you state. Settings has Full AI reacts to what happens and Forget what Full AI learned, and Accuracy and models how many reactions an hour at most (30 by default). Its orders run in the same conversation and agent session as the bubble, so expanding the bubble goes on in the side panel. It has the same brain as Muse in the side panel: the same memories of you and of the desktop, this machine's whole reference and live settings, and it learns from its conversations and tasks the same way. Its balloon shows what it thinks or does as a dim thought cloud, what it says as a speech bubble whose words appear as they are spoken, and any question it asks you (with Yes / No to click for a yes/no question) until you answer. Say \"stop\" or \"wait\" (or just speak up while it talks, with the echo-cancelled microphone) to stop it and be heard; Mod+T also stops it. Turn that off in Settings > Desktop agents (Interrupt by speaking).";
      fr = "Le mode IA complète (Mod+Maj+T, ou Paramètres > Agents du bureau > Parler à son bureau > Mode IA complète) : l'IA pilote le bureau et vous n'avez qu'à parler. Une mascotte mignonne se déplace sur l'écran et montre ce qu'elle entend, ce qu'elle fait et ses réponses. Vous gardez votre clavier et votre souris : elle ne les prend jamais. Mod+Maj+T de nouveau (ou Échap dans la bulle) quitte le mode. Avec Afficher la bulle sur Seulement si nécessaire, elle répond à voix haute et dans la bulle de la mascotte, sans la bulle ; Mod+C l'affiche ou la cache. Le micro reste ouvert, même pendant qu'elle travaille, pour continuer à donner des ordres ; Mod+T le coupe ou le rallume. Dites oui ou non quand elle demande avant une étape. Elle réagit aussi à ce qui se passe (notifications, téléchargements, batterie faible, un écran branché, votre retour) : elle ignore le bruit, vous prévient, demande quoi faire, ou le fait seule si vous le lui avez dit ou accepté deux fois ; elle apprend de chaque réponse et retient les préférences durables que vous énoncez. Les Paramètres ont L'IA complète réagit à ce qui se passe et Oublier ce que l'IA complète a appris, et Précision et modèles le nombre de réactions par heure au plus (30 par défaut). Ses ordres passent par la même conversation et la même session de l'agent que la bulle : agrandir la bulle continue dans le panneau latéral. Elle a le même cerveau que Muse dans le panneau latéral : les mêmes souvenirs de vous et du bureau, toute la référence de cette machine et les réglages en direct, et elle apprend de ses conversations et de ses tâches de la même façon. Sa bulle montre ce qu'elle pense ou fait comme un nuage de pensée plus pâle, ce qu'elle dit comme une bulle de parole dont les mots apparaissent au fil de la voix, et toute question qu'elle vous pose (avec Oui / Non à cliquer pour une question fermée) jusqu'à votre réponse. Dites « stop » ou « attends » (ou parlez simplement pendant qu'elle parle, avec le micro à annulation d'écho) pour l'arrêter et être écouté ; Mod+T l'arrête aussi. Désactivable dans Paramètres > Agents du bureau (Interrompre en parlant).";
      de = "Der volle KI-Modus (Mod+Umschalt+T, oder Einstellungen > Desktop-Agenten > Mit dem Desktop reden > Voller KI-Modus): die KI steuert den Desktop, du sprichst nur. Ein niedliches Maskottchen bewegt sich über den Bildschirm und zeigt, was es hört, was es tut und seine Antworten. Tastatur und Maus bleiben deine: es nimmt sie nie. Erneut Mod+Umschalt+T (oder Esc in der Blase) beendet den Modus. Mit Blase anzeigen auf Nur wenn nötig antwortet es laut und in der Sprechblase des Maskottchens, ohne die Blase; Mod+C zeigt oder versteckt sie. Das Mikro bleibt offen, auch während es arbeitet, damit du weiter Aufträge geben kannst; Mod+T schaltet es aus oder ein. Sag ja oder nein, wenn es vor einem Schritt fragt. Es reagiert auch auf das, was passiert (Benachrichtigungen, Downloads, schwacher Akku, ein angeschlossener Bildschirm, deine Rückkehr): es ignoriert Unwichtiges, sagt Bescheid, fragt, was zu tun ist, oder erledigt es selbst, wenn du es ihm gesagt oder zweimal zugestimmt hast; es lernt aus jeder Antwort und merkt sich dauerhafte Vorlieben, die du nennst. In den Einstellungen: Voller KI-Modus reagiert auf Ereignisse und Gelerntes vergessen, und unter Genauigkeit und Modelle, wie viele Reaktionen pro Stunde höchstens (standardmäßig 30). Seine Befehle laufen im selben Gespräch und derselben Agenten-Sitzung wie die Blase: die Blase vergrößern macht in der Seitenleiste weiter. Er hat dasselbe Gehirn wie Muse im Seitenpanel: dieselben Erinnerungen an dich und den Desktop, die ganze Referenz dieses Rechners und die aktuellen Einstellungen, und er lernt genauso aus seinen Gesprächen und Aufgaben. Seine Blase zeigt, was es denkt oder tut, als blassere Gedankenwolke, was es sagt als Sprechblase, deren Worte beim Sprechen erscheinen, und jede Frage an dich (mit Ja / Nein zum Klicken bei einer Ja-Nein-Frage), bis du antwortest. Sag „stopp“ oder „warte“ (oder sprich einfach, während es redet, mit dem Mikrofon mit Echounterdrückung), um es anzuhalten und gehört zu werden; Mod+T hält es auch an. Abschaltbar unter Einstellungen > Desktop-Agenten (Durch Sprechen unterbrechen).";
      vi = "Chế độ AI toàn phần (Mod+Shift+T, hoặc Cài đặt > Tác nhân màn hình > Nói chuyện với màn hình > Chế độ AI toàn phần): AI điều khiển màn hình, bạn chỉ cần nói. Một linh vật dễ thương di chuyển trên màn hình, cho thấy nó nghe gì, đang làm gì và câu trả lời. Bạn vẫn dùng bàn phím và chuột: nó không bao giờ chiếm chúng. Nhấn Mod+Shift+T lần nữa (hoặc Esc trong bong bóng) để thoát. Khi Hiện bong bóng đặt là Chỉ khi cần, nó trả lời thành tiếng và trong lời thoại của linh vật, không mở bong bóng; Mod+C để hiện hoặc ẩn. Micro luôn mở, kể cả khi nó đang làm, để bạn tiếp tục ra lệnh; Mod+T tắt hoặc bật micro. Nói có hoặc không khi nó hỏi trước một bước. Nó cũng phản ứng với những gì xảy ra (thông báo, tải xuống, pin yếu, cắm màn hình, khi bạn quay lại): bỏ qua thứ không quan trọng, báo cho bạn, hỏi bạn muốn làm gì, hoặc tự làm khi bạn đã dặn hay đã đồng ý hai lần; nó học từ mỗi câu trả lời và ghi nhớ các sở thích lâu dài bạn nói ra. Trong Cài đặt có AI toàn phần phản ứng với sự kiện và Quên những gì AI toàn phần đã học, và trong Độ chính xác và mô hình là số phản ứng tối đa mỗi giờ (mặc định 30). Lệnh của nó chạy trong cùng cuộc trò chuyện và cùng phiên tác nhân với bong bóng: mở rộng bong bóng là tiếp tục ở bảng bên. Nó có cùng bộ não với Muse ở bảng bên: cùng ký ức về bạn và màn hình, toàn bộ thông tin về máy này và cài đặt hiện tại, và nó học từ các cuộc trò chuyện và việc đã làm theo cùng cách. Bong bóng của nó hiện điều nó đang nghĩ hay làm dưới dạng đám mây suy nghĩ mờ, điều nó nói dưới dạng bong bóng lời thoại với chữ hiện ra theo giọng nói, và mọi câu hỏi nó hỏi bạn (có nút Có / Không để bấm với câu hỏi có/không) cho đến khi bạn trả lời. Nói \"dừng lại\" hoặc \"chờ đã\" (hoặc chỉ cần nói khi nó đang nói, với micro khử tiếng vang) để dừng nó và được lắng nghe; Mod+T cũng dừng nó. Tắt trong Cài đặt > Tác nhân màn hình (Ngắt lời bằng giọng nói).";
    };
    agentVoice = {
      en = "The desktop agent answers out loud in a cute voice: Meta's MMS voices, on this computer, in English or French (picked from the answer's language). Settings > Desktop agents > Talk to your desktop > Read the answers out: When I talk (the answers to what you said, and Full AI mode; the default), Always or Never; Voice: Cute (higher and bouncier) or Natural. After acting it says the outcome and what needs you, before a step it asks May I…?, a plain command says what it did. The microphone never hears it (held while it talks). Mod+T or Esc cuts it short. To turn its voice off in one click: the speaker button at the top of Muse's bubble (click again to hear it again, with the mode you had), or `nixbook-shell ipc call voice toggleMute`; it's the same as Read the answers out: Never. To answer without the bubble: Settings > Desktop agents > Talk to your desktop > Show the bubble: Only when needed (the answer is said out loud; the bubble comes for replies to pick, an error, or Mod+C). Your apps' own tools (YouTube Music, Spotify, the phone…) are the agent's too.";
      fr = "L'agent du bureau répond à voix haute avec une voix mignonne : les voix MMS de Meta, sur cet ordinateur, en anglais ou en français (selon la langue de la réponse). Paramètres > Agents du bureau > Parler à son bureau > Lire les réponses : Quand je parle (les réponses à ce que vous avez dit, et le mode IA complète ; par défaut), Toujours ou Jamais ; Voix : Mignonne (plus aiguë et enjouée) ou Naturelle. Après avoir agi, il dit le résultat et ce qui vous attend, avant une étape il demande « Puis-je… ? », une commande simple dit ce qu'elle a fait. Le micro ne l'entend jamais (mis en attente pendant qu'il parle). Mod+T ou Échap le coupe. Pour couper sa voix en un clic : le bouton haut-parleur en haut de la bulle de Muse (un autre clic la rend, avec le mode d'avant), ou `nixbook-shell ipc call voice toggleMute` ; c'est la même chose que Lire les réponses : Jamais. Pour répondre sans la bulle : Paramètres > Agents du bureau > Parler à son bureau > Afficher la bulle : Seulement si nécessaire (la réponse est dite à voix haute ; la bulle vient pour des réponses à choisir, une erreur, ou Mod+C). Les outils de vos applications (YouTube Music, Spotify, le téléphone…) sont aussi les siens.";
      de = "Der Desktop-Agent antwortet laut mit einer niedlichen Stimme: Metas MMS-Stimmen, auf diesem Computer, auf Englisch oder Französisch (je nach Sprache der Antwort; Deutsch gibt es nicht). Einstellungen > Desktop-Agenten > Mit dem Desktop reden > Antworten vorlesen: Wenn ich spreche (Antworten auf Gesagtes und der volle KI-Modus; Standard), Immer oder Nie; Stimme: Niedlich (höher und munterer) oder Natürlich. Nach dem Handeln sagt er das Ergebnis und was dich braucht, vor einem Schritt fragt er „Darf ich…?“, ein einfacher Befehl sagt, was er getan hat. Das Mikro hört ihn nie (pausiert, solange er spricht). Mod+T oder Esc unterbricht ihn. Die Stimme mit einem Klick ausschalten: der Lautsprecher-Knopf oben in Muses Blase (noch ein Klick schaltet sie mit dem vorigen Modus wieder ein), oder `nixbook-shell ipc call voice toggleMute`; dasselbe wie Antworten vorlesen: Nie. Antworten ohne die Blase: Einstellungen > Desktop-Agenten > Mit dem Desktop reden > Blase anzeigen: Nur wenn nötig (die Antwort wird gesprochen; die Blase kommt für Antworten zum Auswählen, einen Fehler oder Mod+C). Die Werkzeuge deiner Apps (YouTube Music, Spotify, das Handy…) gehören auch ihm.";
      vi = "Tác nhân màn hình trả lời thành tiếng bằng một giọng dễ thương: giọng MMS của Meta, chạy trên máy này, bằng tiếng Anh hoặc tiếng Pháp (theo ngôn ngữ của câu trả lời; không có tiếng Việt). Cài đặt > Tác nhân màn hình > Nói chuyện với màn hình > Đọc câu trả lời: Khi tôi nói (câu trả lời cho điều bạn nói, và chế độ AI toàn phần; mặc định), Luôn luôn hoặc Không bao giờ; Giọng: Dễ thương (cao và vui hơn) hoặc Tự nhiên. Sau khi làm, nó nói kết quả và việc cần bạn, trước một bước nó hỏi Tôi có thể…?, lệnh đơn giản thì nói nó đã làm gì. Micro không bao giờ nghe thấy nó (tạm giữ khi nó nói). Mod+T hoặc Esc để cắt ngang. Để tắt giọng nói chỉ bằng một cú nhấp: nút loa ở trên cùng bong bóng của Muse (nhấp lần nữa để bật lại, với chế độ trước đó), hoặc `nixbook-shell ipc call voice toggleMute`; giống như Đọc câu trả lời: Không bao giờ. Để trả lời mà không mở bong bóng: Cài đặt > Tác nhân màn hình > Nói chuyện với màn hình > Hiện bong bóng: Chỉ khi cần (câu trả lời được đọc thành tiếng; bong bóng hiện khi có câu trả lời để chọn, có lỗi, hoặc Mod+C). Công cụ của các ứng dụng (YouTube Music, Spotify, điện thoại…) nó cũng dùng được.";
    };
    agentsInParallel = {
      en = "The desktop agents can work while you do, without taking your mouse or keyboard: in Zen they act in the page itself (reading pages, clicking, typing, filling forms) in any tab, in the background or in another workspace, through nixbook's Zen extension; in other apps they use the app's own controls through its accessibility tree, on any workspace; and they see a window on another workspace without moving your view (silently with nixbook's niri, from your next login). Off limits in Zen: private windows, password fields, the Banking container, password managers, your Google account, PayPal and banks. A click on Send, Pay or Order is asked first.";
      fr = "Les agents du bureau peuvent travailler pendant que vous travaillez, sans prendre votre souris ni votre clavier : dans Zen ils agissent dans la page elle-même (lire, cliquer, écrire, remplir des formulaires) dans n'importe quel onglet, en arrière-plan ou dans un autre espace, grâce à l'extension Zen de nixbook ; dans les autres applications ils passent par leurs propres commandes via l'arbre d'accessibilité, sur n'importe quel espace ; et ils voient une fenêtre d'un autre espace sans déplacer votre vue (en silence avec le niri de nixbook, dès votre prochaine connexion). Interdit dans Zen : les fenêtres privées, les champs de mot de passe, le conteneur Banking, les gestionnaires de mots de passe, votre compte Google, PayPal et les banques. Un clic sur Envoyer, Payer ou Commander est demandé avant.";
      de = "Die Desktop-Agenten können arbeiten, während du arbeitest, ohne Maus oder Tastatur zu übernehmen: in Zen handeln sie in der Seite selbst (lesen, klicken, tippen, Formulare ausfüllen) in jedem Tab, im Hintergrund oder in einem anderen Arbeitsbereich, über nixbooks Zen-Erweiterung; in anderen Apps über deren eigene Bedienelemente per Barrierefreiheitsbaum, auf jedem Arbeitsbereich; und sie sehen ein Fenster auf einem anderen Arbeitsbereich, ohne deine Ansicht zu bewegen (lautlos mit nixbooks niri, ab der nächsten Anmeldung). In Zen tabu: private Fenster, Passwortfelder, der Banking-Container, Passwortmanager, dein Google-Konto, PayPal und Banken. Ein Klick auf Senden, Bezahlen oder Bestellen wird vorher erfragt.";
      vi = "Các tác nhân màn hình có thể làm việc cùng lúc với bạn mà không chiếm chuột hay bàn phím: trong Zen chúng thao tác ngay trong trang (đọc, bấm, gõ, điền biểu mẫu) ở bất kỳ thẻ nào, chạy nền hoặc ở không gian làm việc khác, nhờ tiện ích Zen của nixbook; trong ứng dụng khác chúng dùng chính các điều khiển của ứng dụng qua cây trợ năng, ở bất kỳ không gian nào; và chúng xem được cửa sổ ở không gian khác mà không làm đổi màn hình của bạn (im lặng với niri của nixbook, từ lần đăng nhập sau). Trong Zen không được đụng: cửa sổ riêng tư, ô mật khẩu, container Banking, trình quản lý mật khẩu, tài khoản Google, PayPal và ngân hàng. Bấm Gửi, Thanh toán hay Đặt hàng thì sẽ hỏi trước.";
    };
    appsThroughThePage = {
      en = "The desktop agents also work inside Electron apps nixbook starts through its bridge (nixbook-electron-app: Discord in Vesktop, Slack, YouTube Music, Actual Budget), like Zen's tabs: they read the app's page, click, type (even in Discord's message box) and press keys in the page itself, its window in the background or on another workspace, without your mouse or keyboard (page_list, page_read, page_act). Discord also has its own tool: find a channel or a person, read the last messages, send or reply, react; every message or reaction sent is asked first, in your name. YouTube Music: playing and the queue go through its own MCP server, the page for the rest (lyrics, the library). An app that runs without the bridge (it restarted itself to update, an autostart entry or another launcher started it) is put back on it: one that has just started is restarted through it at once, otherwise (or during a call) you get a notification with Restart with bridge; it is never closed unasked. Password managers are never bridged; customHomeManagerModules.nixbookShellConfig.electronBridge turns it off or picks the apps. Automating your own account may break Discord's or Slack's terms.";
      fr = "Les agents du bureau travaillent aussi dans les applications Electron que nixbook lance par son pont (nixbook-electron-app : Discord dans Vesktop, Slack, YouTube Music, Actual Budget), comme dans les onglets de Zen : ils lisent la page de l'application, cliquent, écrivent (même dans la zone de message de Discord) et appuient sur des touches dans la page elle-même, sa fenêtre en arrière-plan ou dans un autre espace, sans votre souris ni votre clavier (page_list, page_read, page_act). Discord a aussi son propre outil : trouver un salon ou une personne, lire les derniers messages, envoyer ou répondre, réagir ; chaque message ou réaction envoyé en votre nom est demandé avant. YouTube Music : la lecture et la file passent par son propre serveur MCP, la page pour le reste (paroles, bibliothèque). Une application lancée sans le pont (elle s'est relancée pour une mise à jour, une entrée de démarrage automatique ou un autre lanceur l'a ouverte) y est remise : si elle vient de démarrer, elle est relancée par le pont aussitôt, sinon (ou pendant un appel) une notification propose Redémarrer avec le pont ; elle n'est jamais fermée sans vous demander. Les gestionnaires de mots de passe ne passent jamais par le pont ; customHomeManagerModules.nixbookShellConfig.electronBridge le désactive ou choisit les applications. Automatiser votre propre compte peut enfreindre les conditions de Discord ou de Slack.";
      de = "Die Desktop-Agenten arbeiten auch in Electron-Apps, die nixbook über seine Brücke startet (nixbook-electron-app: Discord in Vesktop, Slack, YouTube Music, Actual Budget), wie in Zens Tabs: Sie lesen die Seite der App, klicken, tippen (sogar in Discords Nachrichtenfeld) und drücken Tasten in der Seite selbst, ihr Fenster im Hintergrund oder auf einem anderen Arbeitsbereich, ohne deine Maus oder Tastatur (page_list, page_read, page_act). Discord hat auch ein eigenes Werkzeug: einen Kanal oder eine Person finden, die letzten Nachrichten lesen, senden oder antworten, reagieren; jede in deinem Namen gesendete Nachricht oder Reaktion wird vorher erfragt. YouTube Music: Wiedergabe und Warteschlange über seinen eigenen MCP-Server, die Seite für den Rest (Songtexte, Bibliothek). Eine App, die ohne die Brücke läuft (sie hat sich für ein Update neu gestartet, ein Autostart-Eintrag oder ein anderer Starter hat sie geöffnet), kommt wieder auf sie: gerade gestartet wird sie sofort über die Brücke neu gestartet, sonst (oder während eines Anrufs) fragt eine Benachrichtigung mit Mit Brücke neu starten; sie wird nie ungefragt geschlossen. Passwortmanager laufen nie über die Brücke; customHomeManagerModules.nixbookShellConfig.electronBridge schaltet sie ab oder wählt die Apps. Das eigene Konto zu automatisieren kann gegen Discords oder Slacks Bedingungen verstoßen.";
      vi = "Các tác nhân màn hình cũng làm việc trong các ứng dụng Electron mà nixbook mở qua cầu nối của nó (nixbook-electron-app: Discord trong Vesktop, Slack, YouTube Music, Actual Budget), giống như các thẻ của Zen: chúng đọc trang của ứng dụng, bấm, gõ (cả trong ô tin nhắn của Discord) và nhấn phím ngay trong trang, cửa sổ chạy nền hoặc ở không gian khác, không cần chuột hay bàn phím của bạn (page_list, page_read, page_act). Discord còn có công cụ riêng: tìm kênh hoặc người, đọc các tin nhắn mới nhất, gửi hoặc trả lời, thả cảm xúc; mỗi tin nhắn hay cảm xúc gửi đi dưới tên bạn đều được hỏi trước. YouTube Music: phát nhạc và hàng chờ qua máy chủ MCP riêng của nó, trang cho phần còn lại (lời bài hát, thư viện). Ứng dụng chạy mà không có cầu nối (nó tự khởi động lại để cập nhật, do mục tự khởi động hoặc trình mở khác mở) sẽ được đưa lại vào cầu nối: nếu vừa mới mở thì được khởi động lại qua cầu nối ngay, nếu không (hoặc đang trong cuộc gọi) bạn nhận một thông báo với nút Khởi động lại với cầu nối; nó không bao giờ bị đóng mà không hỏi bạn. Trình quản lý mật khẩu không bao giờ qua cầu nối; customHomeManagerModules.nixbookShellConfig.electronBridge để tắt hoặc chọn ứng dụng. Tự động hóa tài khoản của chính bạn có thể vi phạm điều khoản của Discord hoặc Slack.";
    };
    jellyfin = {
      en = "Jellyfin: in Settings > Desktop agents > Apps it can use, turn Jellyfin on, enter your server, then sign in with your own Jellyfin username and password (no admin or API key needed; with two-factor authentication such as the JellyfinSecurity plugin, an app password made for it). That signs in Muse and the player of this computer, each with its own login; the password isn't kept, and Sign out ends Muse's session on the server. Films and episodes then play fullscreen in mpv on this computer. Say or type \"play Edgerunners season 1 episode 2\" in Muse's bubble to start one at once; ask Muse to play on Moonfin or the TV to use those instead. Audio and subtitles: say them (\"play Edgerunners season 1 episode 2 in Japanese with English subtitles\", \"without subtitles\"; the next episodes keep them), ask Muse to switch them while it plays, or to set your defaults for every player (\"always Japanese audio with English subtitles\": Jellyfin's audio and subtitle language preferences, subtitle mode Smart). An admin's API key still works: Use an admin API key instead.";
      fr = "Jellyfin : dans Paramètres > Agents du bureau > Applications utilisables, activez Jellyfin, saisissez votre serveur, puis connectez-vous avec votre propre nom d'utilisateur et mot de passe Jellyfin (ni administrateur ni clé d'API nécessaire ; avec une authentification à deux facteurs comme le plugin JellyfinSecurity, un mot de passe d'application créé pour cela). Cela connecte Muse et le lecteur de cet ordinateur, chacun avec sa propre session ; le mot de passe n'est pas gardé, et Se déconnecter ferme la session de Muse sur le serveur. Films et épisodes se lancent alors en plein écran dans mpv sur cet ordinateur. Dites ou tapez « lance Edgerunners saison 1 épisode 2 » dans la bulle de Muse pour en lancer un tout de suite ; demandez à Muse de le lire sur Moonfin ou la télé pour les utiliser à la place. Audio et sous-titres : dites-les (« lance Edgerunners saison 1 épisode 2 en japonais sous-titré en anglais », « en VOSTFR », « en VF », « sans sous-titres » ; les épisodes suivants les gardent), demandez à Muse de les changer pendant la lecture, ou de régler vos choix par défaut pour tous les lecteurs (« toujours l'audio japonais avec les sous-titres anglais » : les préférences de langue audio et de sous-titres de Jellyfin, mode de sous-titres Intelligent). Une clé d'API d'administrateur marche toujours : Utiliser plutôt une clé d'API d'administrateur.";
      de = "Jellyfin: Unter Einstellungen > Desktop-Agenten > Nutzbare Apps Jellyfin einschalten, den Server eingeben und dich mit deinem eigenen Jellyfin-Benutzernamen und Passwort anmelden (kein Admin und kein API-Schlüssel nötig; mit Zwei-Faktor-Authentifizierung wie dem JellyfinSecurity-Plugin ein dafür erstelltes App-Passwort). Damit werden Muse und der Player dieses Computers angemeldet, jeder mit eigener Sitzung; das Passwort wird nicht gespeichert, und Abmelden beendet Muses Sitzung auf dem Server. Filme und Folgen laufen dann im Vollbild in mpv auf diesem Computer. Sag oder tippe „spiel Edgerunners Staffel 1 Folge 2“ in Muses Sprechblase, um sofort eine zu starten; bitte Muse, auf Moonfin oder dem Fernseher abzuspielen, um diese zu nutzen. Ton und Untertitel: sag sie („spiel Edgerunners Staffel 1 Folge 2 auf Japanisch mit englischen Untertiteln“, „als OmU“, „ohne Untertitel“; die nächsten Folgen behalten sie), bitte Muse, sie während der Wiedergabe zu wechseln, oder deine Standards für alle Player einzustellen („immer japanischer Ton mit englischen Untertiteln“: Jellyfins Ton- und Untertitelsprache, Untertitelmodus Smart). Ein Admin-API-Schlüssel geht weiterhin: Stattdessen einen Admin-API-Schlüssel verwenden.";
      vi = "Jellyfin: trong Cài đặt > Tác nhân màn hình > Ứng dụng có thể dùng, bật Jellyfin, nhập máy chủ, rồi đăng nhập bằng tên người dùng và mật khẩu Jellyfin của chính bạn (không cần quản trị viên hay khóa API; nếu có xác thực hai lớp như plugin JellyfinSecurity, dùng một mật khẩu ứng dụng tạo cho việc này). Việc đó đăng nhập cho Muse và trình phát của máy này, mỗi bên một phiên riêng; mật khẩu không được lưu, và Đăng xuất sẽ kết thúc phiên của Muse trên máy chủ. Phim và tập phim sẽ phát toàn màn hình trong mpv trên máy này. Nói hoặc gõ \"xem Edgerunners mùa 1 tập 2\" trong bong bóng của Muse để phát ngay; nhờ Muse phát trên Moonfin hoặc TV để dùng chúng. Âm thanh và phụ đề: hãy nói ra (\"xem Edgerunners mùa 1 tập 2 tiếng Nhật phụ đề tiếng Anh\", \"không phụ đề\"; các tập sau giữ nguyên), nhờ Muse đổi khi đang phát, hoặc đặt mặc định cho mọi trình phát (\"luôn âm thanh tiếng Nhật với phụ đề tiếng Anh\": tùy chọn ngôn ngữ âm thanh và phụ đề của Jellyfin, chế độ phụ đề Thông minh). Khóa API của quản trị viên vẫn dùng được: Dùng khóa API quản trị viên thay thế.";
    };
    seerr = {
      en = "Seerr (Overseerr / Jellyseerr): Muse requests films and series you don't have yet, and tells you how far your requests are. Set it up in Settings > Desktop agents > Apps it can use: turn Seerr on, enter its server, then sign in as yourself, no admin key: Open Seerr in my browser, sign in there as usual (OpenID Connect too) in Zen, Firefox, Chrome, Chromium or Brave, then Use my browser's login. Only Seerr's session is copied, into your keyring; Muse then acts as you, with your permissions and quota. When that login ends, do it again; Sign out forgets it here only. Or Use an admin API key instead (Seerr: Settings > General > API Key) with Request as: your Seerr user. Ask \"request Dune Part Two\", \"add season 2 of Edgerunners\", \"where are my requests?\", \"what's trending?\"; something already available is played from Jellyfin instead.";
      fr = "Seerr (Overseerr / Jellyseerr) : Muse demande les films et séries que vous n'avez pas encore, et vous dit où en sont vos demandes. À configurer dans Paramètres > Agents du bureau > Applications utilisables : activez Seerr, saisissez son serveur, puis connectez-vous en votre nom, sans clé d'administrateur : Ouvrir Seerr dans mon navigateur, connectez-vous comme d'habitude (OpenID Connect aussi) dans Zen, Firefox, Chrome, Chromium ou Brave, puis Utiliser la connexion de mon navigateur. Seule la session de Seerr est copiée, dans votre trousseau ; Muse agit alors en votre nom, avec vos droits et votre quota. Quand cette connexion expire, recommencez ; Se déconnecter l'oublie ici seulement. Ou Utiliser plutôt une clé d'API d'administrateur (Seerr : Paramètres > Général > Clé API) avec Demander en tant que : votre utilisateur Seerr. Demandez « demande Dune deuxième partie », « ajoute la saison 2 d'Edgerunners », « où en sont mes demandes ? », « qu'est-ce qui est tendance ? » ; ce qui est déjà disponible se lance depuis Jellyfin.";
      de = "Seerr (Overseerr / Jellyseerr): Muse fordert Filme und Serien an, die du noch nicht hast, und sagt dir, wie weit deine Anfragen sind. Einrichten unter Einstellungen > Desktop-Agenten > Nutzbare Apps: Seerr einschalten, den Server eingeben, dann als du selbst anmelden, ohne Admin-Schlüssel: Seerr in meinem Browser öffnen, dort wie gewohnt anmelden (auch OpenID Connect) in Zen, Firefox, Chrome, Chromium oder Brave, dann Anmeldung meines Browsers verwenden. Nur Seerrs Sitzung wird kopiert, in deinen Schlüsselbund; Muse handelt dann als du, mit deinen Rechten und deinem Kontingent. Läuft die Anmeldung ab, wiederhole es; Abmelden vergisst sie nur hier. Oder Stattdessen einen Admin-API-Schlüssel verwenden (Seerr: Einstellungen > Allgemein > API-Schlüssel) mit Anfragen als: dein Seerr-Benutzer. Frag „fordere Dune Teil zwei an“, „füge Staffel 2 von Edgerunners hinzu“, „wie weit sind meine Anfragen?“, „was ist gerade angesagt?“; Verfügbares wird stattdessen aus Jellyfin abgespielt.";
      vi = "Seerr (Overseerr / Jellyseerr): Muse yêu cầu phim và phim bộ bạn chưa có, và cho bạn biết các yêu cầu đến đâu rồi. Thiết lập trong Cài đặt > Tác nhân màn hình > Ứng dụng có thể dùng: bật Seerr, nhập máy chủ, rồi đăng nhập bằng chính bạn, không cần khóa quản trị: Mở Seerr trong trình duyệt, đăng nhập như thường lệ (cả OpenID Connect) trong Zen, Firefox, Chrome, Chromium hoặc Brave, rồi Dùng đăng nhập của trình duyệt. Chỉ phiên của Seerr được sao chép, vào chùm khóa của bạn; Muse khi đó hành động như bạn, với quyền và hạn mức của bạn. Khi phiên đăng nhập hết hạn, làm lại; Đăng xuất chỉ quên nó ở đây. Hoặc Dùng khóa API quản trị thay thế (Seerr: Settings > General > API Key) với Yêu cầu với tư cách: người dùng Seerr của bạn. Hỏi \"yêu cầu Dune phần hai\", \"thêm mùa 2 của Edgerunners\", \"yêu cầu của tôi đến đâu rồi?\", \"đang thịnh hành gì?\"; nội dung đã có sẽ phát từ Jellyfin.";
    };
    jellyfinTranscoding = {
      en = "Jellyfin playback on this computer plays files as they are (direct play): mpv plays almost anything, and nixbook lifts jellyfin-mpv-shim's 10 Mbit/s limit for servers it doesn't see on the local network (behind a public address, a reverse proxy or a VPN), which made the server transcode most 1080p and every 4K file. A limit can still come from nixbookShellConfig.jellyfinMcp.player.maxBitrateMbps or from the server: Dashboard > Users > the user > Internet streaming bitrate limit, or Dashboard > Playback > Streaming. Ask Muse \"why is it transcoding?\": it reads the server's reasons (ContainerBitrateExceedsLimit is a bitrate limit).";
      fr = "La lecture Jellyfin sur cet ordinateur lit les fichiers tels quels (lecture directe) : mpv lit presque tout, et nixbook lève la limite de 10 Mbit/s de jellyfin-mpv-shim pour les serveurs qu'il ne voit pas sur le réseau local (derrière une adresse publique, un proxy inverse ou un VPN), qui faisait transcoder au serveur la plupart des fichiers 1080p et tous les 4K. Une limite peut encore venir de nixbookShellConfig.jellyfinMcp.player.maxBitrateMbps ou du serveur : Tableau de bord > Utilisateurs > l'utilisateur > Limite de débit de streaming Internet, ou Tableau de bord > Lecture > Streaming. Demandez à Muse « pourquoi ça transcode ? » : il lit les raisons du serveur (ContainerBitrateExceedsLimit est une limite de débit).";
      de = "Jellyfin spielt auf diesem Computer Dateien so ab, wie sie sind (Direktwiedergabe): mpv spielt fast alles, und nixbook hebt jellyfin-mpv-shims Grenze von 10 Mbit/s für Server auf, die es nicht im lokalen Netz sieht (hinter einer öffentlichen Adresse, einem Reverse-Proxy oder einem VPN), wegen der der Server die meisten 1080p- und alle 4K-Dateien transkodierte. Eine Grenze kann noch von nixbookShellConfig.jellyfinMcp.player.maxBitrateMbps oder vom Server kommen: Dashboard > Benutzer > der Benutzer > Bitratenlimit für Internet-Streaming, oder Dashboard > Wiedergabe > Streaming. Frag Muse „warum wird transkodiert?“: Es liest die Gründe des Servers (ContainerBitrateExceedsLimit ist eine Bitratengrenze).";
      vi = "Jellyfin trên máy này phát tệp nguyên bản (phát trực tiếp): mpv phát được gần như mọi thứ, và nixbook bỏ giới hạn 10 Mbit/s của jellyfin-mpv-shim cho máy chủ không nằm trong mạng nội bộ (sau địa chỉ công khai, reverse proxy hay VPN), giới hạn khiến máy chủ chuyển mã phần lớn tệp 1080p và mọi tệp 4K. Giới hạn vẫn có thể đến từ nixbookShellConfig.jellyfinMcp.player.maxBitrateMbps hoặc từ máy chủ: Bảng điều khiển > Người dùng > người dùng đó > Giới hạn bitrate phát trực tuyến qua Internet, hoặc Bảng điều khiển > Phát lại > Phát trực tuyến. Hỏi Muse \"sao lại chuyển mã?\": nó đọc lý do của máy chủ (ContainerBitrateExceedsLimit là giới hạn bitrate).";
    };
    nixOnboarding = {
      en = "To set up your desktop by talking: Settings > Desktop agents > Talk to your desktop > Set up my desktop by talking. Say how you work (\"I'm a developer, I hate notifications at night, I like a minimal bar\"); it asks a few questions, writes the Nix for the shell's settings, checks it with Nix itself (a misspelt or wrong setting is fixed by the AI until Nix accepts it) and shows it with Copy, Build it for me (the desktop agent's fixer puts it in nixbook) and Apply now (live, not in your Nix files; settings set in Nix are left alone).";
      fr = "Pour configurer votre bureau en parlant : Paramètres > Agents du bureau > Parler à son bureau > Configurer mon bureau en parlant. Dites comment vous travaillez (« je suis développeur, je déteste les notifications le soir, j'aime une barre minimale ») ; il pose quelques questions, écrit le Nix des réglages du shell, le vérifie avec Nix lui-même (un réglage mal écrit ou faux est corrigé par l'IA jusqu'à ce que Nix l'accepte) et l'affiche avec Copier, Le faire pour moi (le correcteur de l'agent du bureau l'ajoute à nixbook) et Appliquer maintenant (en direct, pas dans vos fichiers Nix ; les réglages fixés dans Nix ne sont pas touchés).";
      de = "Um deinen Desktop per Gespräch einzurichten: Einstellungen > Desktop-Agenten > Mit dem Desktop reden > Desktop im Gespräch einrichten. Sag, wie du arbeitest („ich bin Entwickler, ich hasse Benachrichtigungen am Abend, ich mag eine schlichte Leiste“); es stellt ein paar Fragen, schreibt das Nix für die Shell-Einstellungen, prüft es mit Nix selbst (eine falsch geschriebene oder falsche Einstellung korrigiert die KI, bis Nix sie annimmt) und zeigt es mit Kopieren, Für mich bauen (der Fixer des Desktop-Agenten trägt es in nixbook ein) und Jetzt anwenden (live, nicht in deinen Nix-Dateien; in Nix gesetzte Einstellungen bleiben unberührt).";
      vi = "Để thiết lập màn hình bằng cách trò chuyện: Cài đặt > Tác nhân màn hình > Nói chuyện với màn hình > Thiết lập màn hình bằng trò chuyện. Hãy nói cách bạn làm việc (\"tôi là lập trình viên, tôi ghét thông báo buổi tối, tôi thích thanh trạng thái tối giản\"); nó hỏi vài câu, viết Nix cho cài đặt của shell, kiểm tra bằng chính Nix (cài đặt viết sai hoặc không hợp lệ được AI sửa đến khi Nix chấp nhận) rồi hiển thị kèm Sao chép, Làm giúp tôi (trình sửa lỗi của tác nhân màn hình đưa vào nixbook) và Áp dụng ngay (trực tiếp, không nằm trong tệp Nix; cài đặt đã đặt trong Nix được giữ nguyên).";
    };
    agentDesktopSandbox = {
      en = "The AI agents' own desktop is sandboxed: its apps see none of your files (only the folders you allow in Settings > Desktop agents), none of your windows, clipboard or screen, and can't capture, type or click into your desktop. Two switches in Settings > Desktop agents, both on, take effect when it next opens: Hide the system's services from their apps (no system daemon's socket), and Keep their apps off this computer's local services (their own network: the internet and your local network, but not a dev server on localhost or the printer pages; switch it off if the agent should open those).";
      fr = "Le bureau des agents IA est isolé (bac à sable) : ses applications ne voient aucun de vos fichiers (seulement les dossiers autorisés dans Paramètres > Agents du bureau), ni vos fenêtres, ni votre presse-papiers, ni votre écran, et ne peuvent ni capturer votre bureau ni y taper ou cliquer. Deux interrupteurs dans Paramètres > Agents du bureau, activés par défaut, s'appliquent à sa prochaine ouverture : cacher les services du système à leurs applications (aucun socket des démons du système), et tenir leurs applications à l'écart des services locaux de cet ordinateur (leur propre réseau : internet et votre réseau local, mais pas un serveur de dev sur localhost ni les pages de l'imprimante ; désactivez-le si l'agent doit les ouvrir).";
      de = "Der eigene Desktop der KI-Agenten ist abgeschottet (Sandbox): Seine Apps sehen keine deiner Dateien (nur die in Einstellungen > Desktop-Agenten erlaubten Ordner), keine deiner Fenster, deine Zwischenablage oder deinen Bildschirm, und können deinen Desktop weder aufnehmen noch hineintippen oder -klicken. Zwei Schalter unter Einstellungen > Desktop-Agenten, beide an, gelten ab dem nächsten Öffnen: Die Dienste des Systems vor ihren Apps verbergen (kein Socket der System-Daemons) und ihre Apps von den lokalen Diensten dieses Computers fernhalten (ein eigenes Netz: Internet und dein lokales Netz, aber kein Dev-Server auf localhost und keine Druckerseiten; schalte es aus, wenn der Agent diese öffnen soll).";
      vi = "Màn hình riêng của các tác nhân AI được cách ly (sandbox): ứng dụng trên đó không thấy tệp nào của bạn (chỉ các thư mục bạn cho phép trong Cài đặt > Tác nhân màn hình), không thấy cửa sổ, bộ nhớ tạm hay màn hình của bạn, và không thể chụp, gõ hay bấm vào màn hình của bạn. Hai công tắc trong Cài đặt > Tác nhân màn hình, mặc định bật, có hiệu lực từ lần mở tiếp theo: ẩn các dịch vụ hệ thống khỏi ứng dụng của chúng (không socket nào của các daemon hệ thống), và giữ ứng dụng của chúng tránh xa các dịch vụ cục bộ của máy này (mạng riêng: internet và mạng nội bộ của bạn, nhưng không có máy chủ dev trên localhost hay trang máy in; tắt đi nếu tác nhân cần mở chúng).";
    };
    desktopMemory = {
      en = "AI agents keep a memory of this desktop so repeated tasks go faster: notes they write (app shortcuts, where things are), recipes (steps that worked, run again in one call; a recipe that worked on three days becomes a macro), app names they learned and what gets used. A note gets stronger when the tasks it was given for go well and weaker when they fail; notes unused for months move to an archive, where agents find them again when needed; once a week a small model merges notes on the same app. Every agent receives the part about its task when it connects, as hints. Review, delete or clear it in Settings > Desktop agents > Desktop memory, or with nixbook-desktop-mcp memory show.";
      fr = "Les agents IA gardent une mémoire de ce bureau pour aller plus vite sur les tâches répétées : des notes qu'ils écrivent (raccourcis d'applications, où sont les choses), des recettes (les étapes qui ont marché, relancées en un appel ; une recette qui a marché trois jours devient une macro), les noms d'applications appris et ce qui est utilisé. Une note se renforce quand les tâches pour lesquelles elle a servi réussissent et s'affaiblit quand elles échouent ; les notes inutilisées depuis des mois passent dans une archive, où les agents les retrouvent au besoin ; une fois par semaine un petit modèle fusionne les notes sur la même application. Chaque agent reçoit en se connectant la partie qui concerne sa tâche, comme des indications. Consultez-la, supprimez ou effacez-la dans Paramètres > Agents du bureau > Mémoire du bureau, ou avec nixbook-desktop-mcp memory show.";
      de = "KI-Agenten führen ein Gedächtnis dieses Desktops, damit wiederholte Aufgaben schneller gehen: Notizen, die sie schreiben (App-Tastenkürzel, wo Dinge sind), Rezepte (Schritte, die funktioniert haben, mit einem Aufruf wiederholt; ein Rezept, das an drei Tagen funktioniert hat, wird ein Makro), gelernte App-Namen und was genutzt wird. Eine Notiz wird stärker, wenn die Aufgaben, für die sie gegeben wurde, gelingen, und schwächer, wenn sie scheitern; monatelang ungenutzte Notizen wandern in ein Archiv, wo Agenten sie bei Bedarf wiederfinden; einmal pro Woche führt ein kleines Modell Notizen zur selben App zusammen. Jeder Agent bekommt beim Verbinden den Teil zu seiner Aufgabe als Hinweise. Ansehen, löschen oder leeren unter Einstellungen > Desktop-Agenten > Desktop-Gedächtnis oder mit nixbook-desktop-mcp memory show.";
      vi = "Các tác nhân AI giữ một bộ nhớ về màn hình này để các việc lặp lại nhanh hơn: ghi chú chúng viết (phím tắt ứng dụng, vị trí các thứ), công thức (các bước đã chạy được, chạy lại trong một lệnh; công thức chạy được trong ba ngày thành macro), tên ứng dụng đã học và những gì được dùng. Ghi chú mạnh lên khi các việc nó được dùng cho thành công và yếu đi khi thất bại; ghi chú không dùng nhiều tháng chuyển vào kho lưu trữ, nơi tác nhân tìm lại khi cần; mỗi tuần một mô hình nhỏ gộp các ghi chú về cùng một ứng dụng. Mỗi tác nhân nhận phần liên quan đến việc của nó khi kết nối, dưới dạng gợi ý. Xem, xóa hoặc dọn sạch trong Cài đặt > Tác nhân màn hình > Bộ nhớ màn hình, hoặc bằng nixbook-desktop-mcp memory show.";
    };
    agentReminders = {
      en = "Ask Muse (or any agent) \"remind me when I open Gmail to label the invoices\", \"next time I open Discord, remind me…\" or \"remind me at 18:00…\": the reminder comes as a notification when that app or window is focused, or at that time, once (or every day if you ask). See or delete reminders in Settings > Desktop agents > Desktop memory > Reminders.";
      fr = "Demandez à Muse (ou à un agent) « rappelle-moi quand j'ouvre Gmail de trier les factures », « la prochaine fois que j'ouvre Discord, rappelle-moi… » ou « rappelle-moi à 18h00… » : le rappel arrive en notification quand cette application ou fenêtre a le focus, ou à cette heure, une fois (ou chaque jour si vous le demandez). Voyez ou supprimez les rappels dans Paramètres > Agents du bureau > Mémoire du bureau > Rappels.";
      de = "Bitte Muse (oder einen Agenten): „erinnere mich, wenn ich Gmail öffne, die Rechnungen zu sortieren“, „wenn ich Discord das nächste Mal öffne, erinnere mich…“ oder „erinnere mich um 18:00…“: Die Erinnerung kommt als Benachrichtigung, wenn diese App oder dieses Fenster den Fokus hat, oder zu dieser Zeit, einmal (oder täglich, wenn gewünscht). Erinnerungen ansehen oder löschen unter Einstellungen > Desktop-Agenten > Desktop-Gedächtnis > Erinnerungen.";
      vi = "Hãy nhờ Muse (hoặc một tác nhân) \"nhắc tôi khi mở Gmail để phân loại hóa đơn\", \"lần tới tôi mở Discord, nhắc tôi…\" hoặc \"nhắc tôi lúc 18:00…\": lời nhắc hiện thành thông báo khi ứng dụng hoặc cửa sổ đó được chọn, hoặc vào giờ đó, một lần (hoặc mỗi ngày nếu bạn muốn). Xem hoặc xóa lời nhắc trong Cài đặt > Tác nhân màn hình > Bộ nhớ màn hình > Nhắc nhở.";
    };
    agentInitiative = {
      en = "Turn on Settings > Desktop agents > Talk to me on its own and Muse speaks first when it can help: when you come back (your day, a plan coming up or just past, your usual setup), when a recipe it knows broke, when it learned something, and with Read my notifications also on, about notifications (advice or a suggestion). Time-critical things come as its own speech bubble on the left under the bar, in your theme's look (answer right in it and Muse answers there; paste an image with Ctrl+V, drop a file on the reply box or click its clip to send it along; the expand button moves the talk to the side panel; Not now, Don't tell me this; at most 8 a day, none at night or in a meeting); the rest waits as a bubble beside the robot in the bar, with a count of how many you haven't read (it goes down as you read, answer or dismiss them): click it to bring it back, right-click for not now. Don't tell me this silences only that: for a notification, the notifications like it (the same app and title, numbers aside), never the whole app; Settings > Desktop agents lists each one with Tell me again, and a button undoes them all. Now and then, at random and at most four times a day, it also says a light word in the bar: a break after a long stretch, the music on repeat, a tip for the app you're in, something it can now do in one step, a plan coming up, a question about something you care about. With Be curious also on, it watches what you do (the app and window title in front; never password managers or private windows), learns it once a day through the small model, saves it to what it knows about you and tells you what it learned in its bubble; reply to correct it. It asks only what it can't tell.";
      fr = "Activez Paramètres > Agents du bureau > Me parler de lui-même et Muse prend la parole quand il peut aider : à votre retour (votre journée, un projet proche ou passé, votre installation habituelle), quand une recette qu'il connaît est cassée, quand il a appris quelque chose, et avec Lire mes notifications activé, à propos des notifications (un conseil ou une suggestion). L'urgent arrive dans sa propre bulle, à gauche sous la barre, aux couleurs de votre thème (répondez directement dedans et Muse y répond ; collez une image avec Ctrl+V, déposez un fichier sur la zone de réponse ou cliquez son trombone pour le joindre ; le bouton agrandir passe la conversation au panneau latéral ; Pas maintenant, Ne plus me dire ça ; 8 par jour au plus, rien la nuit ni en réunion) ; le reste attend sous forme de bulle à côté du robot dans la barre, avec le nombre de messages non lus (il baisse quand vous les lisez, y répondez ou les écartez) : cliquez pour la rouvrir, clic droit pour plus tard. Ne me dis plus ça ne fait taire que cela : pour une notification, celles qui lui ressemblent (même application et même titre, chiffres à part), jamais toute l'application ; Paramètres > Agents du bureau les liste une à une avec Redis-le-moi, et un bouton les annule toutes. De temps en temps, au hasard et quatre fois par jour au plus, il glisse aussi un mot dans la barre : une pause après une longue session, la musique en boucle, une astuce pour l'application ouverte, ce qu'il sait désormais faire en une étape, un projet qui approche, une question sur ce qui vous tient à cœur. Avec Être curieux activé aussi, il observe ce que vous faites (l'application et le titre de la fenêtre au premier plan ; jamais les gestionnaires de mots de passe ni les fenêtres privées), l'apprend une fois par jour via le petit modèle, l'enregistre dans ce qu'il sait de vous et vous dit ce qu'il a appris dans sa bulle ; répondez pour le corriger. Il ne demande que ce qu'il ne peut pas deviner.";
      de = "Schalte Einstellungen > Desktop-Agenten > Von sich aus mit mir reden ein, und Muse spricht zuerst, wenn es helfen kann: wenn du zurückkommst (dein Tag, ein Plan bald oder gerade vorbei, dein übliches Setup), wenn ein Rezept, das es kennt, kaputt ist, wenn es etwas gelernt hat, und mit Meine Benachrichtigungen lesen auch zu Benachrichtigungen (ein Rat oder ein Vorschlag). Dringendes kommt als eigene Sprechblase links unter der Leiste, im Stil deines Themes (antworte direkt darin, und Muse antwortet dort; füge ein Bild mit Strg+V ein, zieh eine Datei auf das Antwortfeld oder klicke seine Büroklammer, um sie mitzuschicken; der Vergrößern-Knopf verlegt das Gespräch ins Seitenpanel; Nicht jetzt, Sag mir das nicht mehr; höchstens 8 am Tag, nachts und in Besprechungen nichts); der Rest wartet als Sprechblase neben dem Roboter in der Leiste, mit der Zahl des noch Ungelesenen (sie sinkt, wenn du liest, antwortest oder wegklickst): Klick holt sie zurück, Rechtsklick für später. Sag mir das nicht mehr bringt nur das zum Schweigen: bei einer Benachrichtigung die ähnlichen (gleiche App und gleicher Titel, Zahlen außen vor), nie die ganze App; Einstellungen > Desktop-Agenten listet jede einzeln mit Sag es mir wieder, und ein Knopf hebt alle auf. Ab und zu, zufällig und höchstens viermal am Tag, sagt es auch ein lockeres Wort in der Leiste: eine Pause nach langer Arbeit, die Musik in Dauerschleife, ein Tipp für die offene App, was es jetzt in einem Schritt kann, ein Plan, der näher rückt, eine Frage zu etwas, das dir wichtig ist. Mit Neugierig sein beobachtet es außerdem, was du tust (App und Fenstertitel im Vordergrund; nie Passwortmanager oder private Fenster), lernt es einmal am Tag über das kleine Modell, speichert es in dem, was es über dich weiß, und sagt dir in seiner Sprechblase, was es gelernt hat; antworte, um es zu korrigieren. Es fragt nur, was es nicht erraten kann.";
      vi = "Bật Cài đặt > Tác nhân màn hình > Tự nói chuyện với tôi và Muse sẽ chủ động lên tiếng khi có thể giúp: khi bạn quay lại (ngày của bạn, một kế hoạch sắp tới hoặc vừa qua, thiết lập quen thuộc), khi một công thức nó biết bị hỏng, khi nó học được điều gì, và khi bật thêm Đọc thông báo của tôi, về các thông báo (lời khuyên hoặc gợi ý). Việc gấp hiện trong bong bóng riêng ở bên trái dưới thanh, theo phong cách giao diện của bạn (trả lời ngay trong đó và Muse trả lời tại đó; dán ảnh bằng Ctrl+V, kéo thả tệp vào ô trả lời hoặc bấm biểu tượng ghim để gửi kèm; nút mở rộng chuyển cuộc trò chuyện sang bảng bên; Để sau, Đừng nói điều này nữa; tối đa 8 lần một ngày, không vào ban đêm hay khi họp); phần còn lại chờ dưới dạng bong bóng cạnh robot trên thanh, kèm số tin chưa đọc (giảm dần khi bạn đọc, trả lời hoặc bỏ qua): bấm để mở lại, chuột phải để để sau. Đừng nói điều này nữa chỉ tắt đúng điều đó: với thông báo, là các thông báo giống nó (cùng ứng dụng và tiêu đề, bỏ qua con số), không bao giờ cả ứng dụng; Cài đặt > Tác nhân màn hình liệt kê từng mục với Nói lại cho tôi, và một nút để bỏ tất cả. Thỉnh thoảng, ngẫu nhiên và tối đa bốn lần một ngày, nó cũng nói một câu nhẹ nhàng trên thanh: nghỉ một chút sau thời gian dài, bản nhạc nghe đi nghe lại, mẹo cho ứng dụng đang mở, việc nó giờ làm được trong một bước, kế hoạch sắp tới, một câu hỏi về điều bạn quan tâm. Khi bật thêm Tò mò, nó quan sát bạn làm gì (ứng dụng và tiêu đề cửa sổ đang mở; không bao giờ trình quản lý mật khẩu hay cửa sổ riêng tư), mỗi ngày một lần học điều đó qua mô hình nhỏ, lưu vào những gì nó biết về bạn và cho bạn biết nó đã học được gì trong bong bóng; trả lời để sửa lại. Nó chỉ hỏi những gì nó không tự đoán được.";
    };
    agentRoutines = {
      en = "Ask Muse for a routine: \"whenever the music ends, play something I like\", \"when my headphones connect, resume the music\", \"when a PDF lands in Downloads, open it\", \"every weekday at 9:00, restore my work layout\". It does it on its own when that happens (music, apps, window titles, notifications, coming back, the lock, a time, battery and power, Wi-Fi, VPN, audio output, monitors, Downloads, calendar events). It never fights you: music you stop stays stopped, and a routine you undo twice turns itself off. See, switch off or delete them in Settings > Desktop agents > Routines. With Learn routines from my habits (Suggest or On its own) it also finds routines by itself from what you usually do (it needs usage habits on), and asks first or just starts doing them. A routine Muse adds stays off until you answer Yes, do it to its bubble, which says what it would do. It also reacts to no music for a while, an app in front, the first time at the computer each day, a long sitting, fullscreen, Do Not Disturb, the battery charged, Bluetooth, your phone, a USB drive, a full disk, rain and screenshots; and once a day it may suggest a routine that would help you, from what it knows about you.";
      fr = "Demandez une routine à Muse : « quand la musique s'arrête, mets quelque chose que j'aime », « quand mon casque se connecte, reprends la musique », « quand un PDF arrive dans Téléchargements, ouvre-le », « en semaine à 9h, remets ma disposition de travail ». Il le fait tout seul quand cela arrive (musique, applications, titres de fenêtres, notifications, retour, verrouillage, une heure, batterie et alimentation, Wi-Fi, VPN, sortie audio, écrans, Téléchargements, événements du calendrier). Il ne vous contredit jamais : la musique que vous arrêtez reste arrêtée, et une routine annulée deux fois se désactive. Voyez, désactivez ou supprimez-les dans Paramètres > Agents du bureau > Routines. Avec Apprendre des routines de mes habitudes (Suggérer ou Tout seul), il en trouve aussi lui-même à partir de ce que vous faites d'habitude (il faut les habitudes d'utilisation activées), et demande d'abord ou s'y met directement. Une routine ajoutée par Muse reste désactivée tant que vous n'avez pas répondu Oui, fais-le à sa bulle, qui dit ce qu'elle ferait. Il réagit aussi à l'absence de musique un moment, à une application au premier plan, à la première fois devant l'ordinateur de la journée, à une longue session, au plein écran, au mode Ne pas déranger, à la batterie chargée, au Bluetooth, à votre téléphone, à une clé USB, à un disque plein, à la pluie et aux captures d'écran ; et une fois par jour il peut vous suggérer une routine utile, d'après ce qu'il sait de vous.";
      de = "Bitte Muse um eine Routine: „wenn die Musik endet, spiel etwas, das ich mag“, „wenn sich mein Kopfhörer verbindet, setz die Musik fort“, „wenn ein PDF in Downloads landet, öffne es“, „werktags um 9:00 stell mein Arbeitslayout her“. Es macht das von selbst, wenn es passiert (Musik, Apps, Fenstertitel, Benachrichtigungen, Zurückkommen, Sperre, eine Uhrzeit, Akku und Strom, WLAN, VPN, Audioausgang, Monitore, Downloads, Kalendertermine). Es arbeitet nie gegen dich: Musik, die du stoppst, bleibt aus, und eine Routine, die du zweimal rückgängig machst, schaltet sich ab. Ansehen, abschalten oder löschen unter Einstellungen > Desktop-Agenten > Routinen. Mit Routinen aus meinen Gewohnheiten lernen (Vorschlagen oder Von selbst) findet es auch selbst Routinen aus dem, was du gewöhnlich tust (Nutzungsgewohnheiten müssen an sein), und fragt zuerst oder legt einfach los. Eine Routine, die Muse hinzufügt, bleibt aus, bis du in ihrer Sprechblase Ja, mach es antwortest; sie sagt, was sie tun würde. Es reagiert auch auf eine Weile ohne Musik, eine App im Vordergrund, das erste Mal am Rechner am Tag, lange Sitzungen, Vollbild, Nicht stören, geladenen Akku, Bluetooth, dein Handy, einen USB-Stick, eine volle Festplatte, Regen und Screenshots; und einmal am Tag kann es dir eine hilfreiche Routine vorschlagen, nach dem, was es über dich weiß.";
      vi = "Hãy nhờ Muse tạo một thói quen tự động: \"khi nhạc hết, phát bài tôi thích\", \"khi tai nghe kết nối, phát tiếp nhạc\", \"khi có PDF trong Tải xuống, mở nó\", \"các ngày trong tuần lúc 9:00, khôi phục bố cục làm việc\". Nó tự làm khi điều đó xảy ra (nhạc, ứng dụng, tiêu đề cửa sổ, thông báo, khi bạn quay lại, khóa màn hình, một giờ cố định, pin và nguồn, Wi-Fi, VPN, đầu ra âm thanh, màn hình, Tải xuống, sự kiện lịch). Nó không bao giờ làm ngược ý bạn: nhạc bạn tắt sẽ không bị bật lại, và thói quen bạn hoàn tác hai lần sẽ tự tắt. Xem, tắt hoặc xóa trong Cài đặt > Tác nhân màn hình > Thói quen tự động. Với Học thói quen từ thói quen sử dụng của tôi (Gợi ý hoặc Tự làm), nó còn tự tìm thói quen từ những gì bạn thường làm (cần bật thói quen sử dụng), rồi hỏi trước hoặc tự bắt đầu làm. Thói quen do Muse thêm sẽ tắt cho đến khi bạn trả lời Có, làm đi trong bong bóng của nó, nơi ghi rõ nó sẽ làm gì. Nó cũng phản ứng khi không có nhạc một lúc, khi một ứng dụng ở phía trước, lần đầu ngồi vào máy trong ngày, ngồi lâu, toàn màn hình, chế độ Không làm phiền, pin đã sạc, Bluetooth, điện thoại của bạn, ổ USB, ổ đĩa đầy, trời mưa và ảnh chụp màn hình; và mỗi ngày một lần nó có thể gợi ý một thói quen hữu ích, dựa trên những gì nó biết về bạn.";
    };
    aiOff = {
      en = "To turn every AI feature off at once, switch off Settings > Desktop agents > AI features (the same as Settings > Panels > AI: No). Then nothing calls a model and no agent acts: no chat in the side panel, Muse never speaks on its own (Mod+C included), no routine runs, no memory pass, no fix, the equalizer agent rests, and every agent's desktop tools are refused. What agents remember stays, and each feature keeps its own switch for when you turn AI back on. AI: Local keeps only what never goes to an online model like Muse.";
      fr = "Pour désactiver toutes les fonctions d'IA d'un coup, désactivez Paramètres > Agents du bureau > Fonctions d'IA (comme Paramètres > Panneaux > IA : Non). Alors rien n'appelle de modèle et aucun agent n'agit : pas de chat dans le panneau latéral, Muse ne parle jamais de lui-même (Mod+C compris), aucune routine ne tourne, pas de passe de mémoire, pas de correction, l'agent de l'égaliseur se repose, et les outils du bureau sont refusés à tout agent. Ce que les agents ont retenu reste, et chaque fonction garde son propre interrupteur pour quand vous réactivez l'IA. IA : Local ne garde que ce qui ne passe jamais par un modèle en ligne comme Muse.";
      de = "Um alle KI-Funktionen auf einmal auszuschalten, schalte Einstellungen > Desktop-Agenten > KI-Funktionen aus (wie Einstellungen > Panels > KI: Nein). Dann ruft nichts mehr ein Modell auf und kein Agent handelt: kein Chat in der Seitenleiste, Muse spricht nie von sich aus (Mod+C eingeschlossen), keine Routine läuft, kein Gedächtnisdurchlauf, keine Korrektur, der Equalizer-Agent ruht, und die Desktop-Werkzeuge werden jedem Agenten verweigert. Was die Agenten sich gemerkt haben, bleibt, und jede Funktion behält ihren eigenen Schalter für später. KI: Lokal behält nur, was nie an ein Online-Modell wie Muse geht.";
      vi = "Để tắt mọi tính năng AI cùng lúc, tắt Cài đặt > Tác nhân màn hình > Tính năng AI (giống Cài đặt > Bảng > AI: Không). Khi đó không gì gọi mô hình và không tác nhân nào hành động: không có trò chuyện ở bảng bên, Muse không tự nói (kể cả Mod+C), không chạy thói quen tự động, không có lượt ghi nhớ, không có bản sửa, tác nhân bộ cân bằng âm nghỉ, và công cụ màn hình bị từ chối với mọi tác nhân. Những gì tác nhân đã nhớ vẫn còn, và mỗi tính năng giữ công tắc riêng cho lúc bạn bật lại AI. AI: Cục bộ chỉ giữ những gì không bao giờ gửi tới mô hình trực tuyến như Muse.";
    };
    agentFixes = {
      en = "Turn on Settings > Desktop agents > Fixes it makes itself > Make fixes on its own and Muse fixes nixbook itself: fixes and polish only (a bug, a rough edge, wording); a new feature, or a fix it finds too big, goes to Features it builds (ask how features are built). Tell an agent something is broken (\"report this\") or type it in that section; it also picks up the errors the shell prints, the desktop tools' crashes, failed services and errors in the logs of what nixbook defines, a failed update, CI failing on main and crashes of nixbook's programs (what isn't nixbook's, like another app's crash or the kernel, is only listed, never sent to Muse unless you press Fix now). Each fix is made in a clone of the repository by a session that can only edit files there, checked (its size, the tests, the shell started headless), committed with a changelog entry and opened as a pull request. Once CI passes you get a notification with Merge, Look and Drop (also in Settings). Nothing reaches main without you, unless you let fixes merge on their own once CI passes (docs-only ones, or every one: a fix touching what agents may do always waits for you). What a merged fix breaks (main's checks, the updated shell) is never reverted: it is queued as a fix of its own. One it can't do (a place off limits, credentials, hardware, or its change failing twice) is dropped with why and what would make it doable: you get a notification with Retry, As a feature and Dismiss, and it waits in the section's Dropped list with the same buttons, never tried again unless you press Retry. At most 2 a day on its own by default: set Fixes a day on its own in that section (0: no limit; Most a fix may spend still caps each one); Fix now starts one at once; pressed while another is being made (Queue then), or asked of an agent, it waits in a queue shared with the features instead: Queued, #N, with Earlier, Later and Unqueue buttons, each starting on its own once the one before it is done. It reaches GitHub only with its own token, set in that section (a fine-grained token for the repository, Contents and Pull requests), never your gh login; Muse never sees it. Only machines whose Nix configuration enables it have it.";
      fr = "Activez Paramètres > Agents du bureau > Corrections qu'il fait lui-même > Faire des corrections de lui-même et Muse corrige nixbook lui-même : corrections et finitions uniquement (un bogue, un défaut, une formulation) ; une nouvelle fonctionnalité, ou une correction trouvée trop grosse, va dans Fonctionnalités qu'il construit. Dites à un agent que quelque chose est cassé (« signale ça ») ou écrivez-le dans cette section ; il relève aussi les erreurs que le shell affiche, les plantages des outils du bureau, les services en échec et les erreurs dans les journaux de ce que nixbook définit, une mise à jour échouée, la CI en échec sur main et les plantages des programmes de nixbook (ce qui n'est pas à nixbook, comme le plantage d'une autre application ou le noyau, est seulement listé, jamais envoyé à Muse sauf si vous appuyez sur Corriger maintenant). Chaque correction est faite dans un clone du dépôt par une session qui ne peut modifier que les fichiers de ce clone, vérifiée (sa taille, les tests, le shell démarré sans écran), commitée avec une entrée de journal des modifications et ouverte en pull request. Quand la CI passe, une notification propose Fusionner, Voir et Abandonner (aussi dans les Paramètres). Rien n'arrive sur main sans vous, sauf si vous laissez les corrections fusionner seules une fois la CI passée (celles de documentation seulement, ou toutes : une correction touchant ce que les agents peuvent faire attend toujours votre accord). Ce qu'une correction fusionnée casse (les vérifications de main, le shell mis à jour) n'est jamais annulé : c'est mis en file comme une correction à part. Celle qu'il ne peut pas faire (un endroit interdit, des identifiants, du matériel, ou sa modification refusée deux fois) est abandonnée avec la raison et ce qui la rendrait faisable : une notification propose Réessayer, En fonctionnalité et Ignorer, et elle attend dans la liste Abandonnées de la section avec les mêmes boutons, jamais réessayée sauf si vous appuyez sur Réessayer. Au plus 2 par jour de lui-même par défaut : réglez Corrections par jour de lui-même dans cette section (0 : sans limite ; Dépense maximale par correction plafonne toujours chacune) ; Corriger maintenant en lance une tout de suite ; pendant qu'une autre est en cours (le bouton devient Mettre en file), ou demandée à un agent, elle attend dans une file partagée avec les fonctionnalités : En file, n° N, avec les boutons Plus tôt, Plus tard et Retirer de la file, chacune démarrant seule quand la précédente est finie. Il n'accède à GitHub qu'avec son propre jeton, défini dans cette section (un jeton à granularité fine pour le dépôt, Contents et Pull requests), jamais votre connexion gh ; Muse ne le voit jamais. Seules les machines dont la configuration Nix l'active l'ont.";
      de = "Schalte Einstellungen > Desktop-Agenten > Korrekturen, die es selbst macht > Selbst Korrekturen machen ein, und Muse korrigiert nixbook selbst: nur Fehlerbehebungen und Feinschliff (ein Fehler, eine Unebenheit, eine Formulierung); eine neue Funktion, oder eine Korrektur, die sich als zu groß erweist, kommt zu Funktionen, die es baut. Sag einem Agenten, dass etwas kaputt ist („melde das“), oder schreib es in diesen Abschnitt; es greift auch die Fehler auf, die die Shell ausgibt, Abstürze der Desktop-Werkzeuge, fehlgeschlagene Dienste und Fehler in den Logs dessen, was nixbook definiert, ein fehlgeschlagenes Update, rote CI auf main und Abstürze von nixbooks Programmen (was nicht zu nixbook gehört, etwa der Absturz einer anderen App oder der Kernel, wird nur aufgelistet, nie an Muse geschickt, außer du drückst Jetzt korrigieren). Jede Korrektur entsteht in einem Klon des Repositorys durch eine Sitzung, die nur dort Dateien bearbeiten kann, wird geprüft (ihre Größe, die Tests, die Shell ohne Bildschirm gestartet), mit einem Changelog-Eintrag committet und als Pull Request geöffnet. Sobald die CI durchläuft, bekommst du eine Benachrichtigung mit Zusammenführen, Ansehen und Verwerfen (auch in den Einstellungen). Nichts landet ohne dich auf main, außer du lässt Korrekturen nach bestandener CI von selbst zusammenführen (nur Doku-Korrekturen oder alle: eine Korrektur an dem, was Agenten dürfen, wartet immer auf dich). Was eine zusammengeführte Korrektur kaputt macht (die Prüfungen von main, die aktualisierte Shell), wird nie zurückgenommen: es kommt als eigene Korrektur in die Warteschlange. Eine, die es nicht schafft (ein gesperrter Ort, Zugangsdaten, Hardware, oder ihre Änderung zweimal abgelehnt), wird mit Grund und dem, was sie machbar machen würde, aufgegeben: eine Benachrichtigung bietet Erneut versuchen, Als Funktion und Verwerfen, und sie wartet in der Liste Aufgegeben des Abschnitts mit denselben Knöpfen, nie wieder versucht, außer du drückst Erneut versuchen. Standardmäßig höchstens 2 am Tag von selbst: stell Korrekturen pro Tag von selbst in diesem Abschnitt ein (0: keine Grenze; Höchstausgabe pro Korrektur begrenzt weiter jede); Jetzt korrigieren startet eine sofort; während eine andere läuft (der Knopf heißt dann Einreihen), oder von einem Agenten verlangt, wartet sie in einer mit den Funktionen geteilten Warteschlange: In der Warteschlange, Nr. N, mit den Knöpfen Früher, Später und Aus der Warteschlange, jede startet von selbst, sobald die vorige fertig ist. Es greift nur mit seinem eigenen Token auf GitHub zu, das in diesem Abschnitt gesetzt wird (ein Fine-grained-Token für das Repository, Contents und Pull requests), nie mit deiner gh-Anmeldung; Muse sieht es nie. Nur Rechner, deren Nix-Konfiguration es aktiviert, haben es.";
      vi = "Bật Cài đặt > Tác nhân màn hình > Tự sửa lỗi > Tự sửa lỗi và Muse sẽ tự sửa nixbook: chỉ sửa lỗi và chỉnh chu (một lỗi, một chỗ chưa mượt, câu chữ); một tính năng mới, hoặc một bản sửa quá lớn, sẽ chuyển sang Tính năng nó xây dựng. Hãy nói với một tác nhân rằng có gì đó bị hỏng (\"báo lỗi này\") hoặc gõ vào mục đó; nó cũng ghi nhận các lỗi mà shell in ra, các lần công cụ màn hình bị sập, các dịch vụ bị lỗi và lỗi trong nhật ký của những gì nixbook định nghĩa, một lần cập nhật thất bại, CI lỗi trên main và các lần chương trình của nixbook bị sập (những gì không thuộc nixbook, như một ứng dụng khác bị sập hay nhân hệ điều hành, chỉ được liệt kê, không bao giờ gửi cho Muse trừ khi bạn bấm Sửa ngay). Mỗi bản sửa được làm trong một bản sao của kho mã bởi một phiên chỉ được sửa tệp trong đó, được kiểm tra (kích thước, các bài kiểm thử, shell khởi động không màn hình), commit kèm mục nhật ký thay đổi và mở thành pull request. Khi CI qua, bạn nhận thông báo với Hợp nhất, Xem và Bỏ (cũng có trong Cài đặt). Không gì vào main mà không có bạn, trừ khi bạn cho phép các bản sửa tự hợp nhất khi CI qua (chỉ bản sửa tài liệu, hoặc tất cả: bản sửa đụng tới quyền của tác nhân luôn chờ bạn). Những gì một bản sửa đã gộp làm hỏng (kiểm tra của main, shell sau khi cập nhật) không bao giờ bị hoàn tác: nó được xếp hàng thành một bản sửa riêng. Bản sửa nó không làm được (một chỗ bị cấm, thông tin đăng nhập, phần cứng, hoặc thay đổi bị từ chối hai lần) bị bỏ kèm lý do và điều gì sẽ giúp làm được: bạn nhận thông báo với Thử lại, Thành tính năng và Bỏ qua, và nó chờ trong danh sách Đã bỏ của mục đó với cùng các nút, không bao giờ thử lại trừ khi bạn bấm Thử lại. Mặc định tối đa 2 lần mỗi ngày tự động: đặt Số bản sửa mỗi ngày trong mục đó (0: không giới hạn; Chi tối đa mỗi bản sửa vẫn giới hạn từng bản); Sửa ngay bắt đầu một bản sửa ngay lập tức; nếu đang có một cái khác chạy (nút khi đó là Xếp hàng), hoặc khi nhờ một tác nhân, nó sẽ chờ trong hàng đợi chung với các tính năng: Đang xếp hàng, số N, với các nút Sớm hơn, Muộn hơn và Bỏ khỏi hàng đợi, mỗi cái tự bắt đầu khi cái trước xong. Nó chỉ truy cập GitHub bằng token riêng, đặt trong mục đó (một fine-grained token cho kho mã, Contents và Pull requests), không bao giờ dùng đăng nhập gh của bạn; Muse không bao giờ thấy token. Chỉ những máy có cấu hình Nix bật tính năng này mới có nó.";
    };
    agentFeatures = {
      en = "Turn on Settings > Desktop agents > Features it builds > Build the features I ask for and Muse builds what you ask nixbook to do (a new widget, setting, shortcut or behaviour), apart from the fixes. Ask an agent (\"I wish the bar showed…\", \"add a way to…\": it files it with its request_feature tool) or type it in that section; a fix it finds too big for a fix comes there too, with what it found (a too-big one from before gets an As a feature button). Ask an agent \"did you file it?\" or \"how is my feature going?\" and its list_requests tool shows each fix and feature request: when and by whom it was filed, and whether it is queued, building, a pull request (its link and checks), merged, dropped or too big. With Settings > Desktop agents > Propose fixes and features on (and Talk to me on its own), the agent may also offer one itself every two days at most, from what it saw go wrong or get in your way (what failed in its memory, routines you undid, its tools' errors, the apps pairing saw you in): Yes, do it files it, Don't tell me this never proposes it again. Each feature is built like a fix (a clone of the repository, a session that can only edit files there, the same checks and off-limits places) but may be bigger (15 files and 600 lines by default, new files allowed), committed as feat(…) and opened as a pull request. It is never merged on its own: once CI passes you get Merge, Look and Drop. One it can't do (a design choice only you can make, more than it may change, a place off limits, credentials, hardware, or its change failing twice) is dropped with why and what would make it doable: you get a notification with Retry and Dismiss, and it waits in the section's Dropped list, never tried again unless you press Retry. It uses the GitHub token and model set in Fixes it makes itself; at most 1 a day on its own by default (Features a day on its own in that section, 0: no limit; Most a feature may spend caps each one), Build now starts one at once (while another is being made, it waits in the queue shared with the fixes and starts on its own after). Say \"build it now\" (or later \"start building that feature\") and the agent starts it the same way; \"fix it now\" does so for a fix, and asking how it goes gives where it stands (queued, being made, pull request open, CI passed). Only machines whose Nix configuration enables the fixer have it.";
      fr = "Activez Paramètres > Agents du bureau > Fonctionnalités qu'il construit > Construire les fonctionnalités que je demande et Muse construit ce que vous demandez à nixbook (un nouveau widget, réglage, raccourci ou comportement), à part des corrections. Demandez-le à un agent (« j'aimerais que la barre affiche… », « ajoute un moyen de… » : il le dépose avec son outil request_feature) ou écrivez-le dans cette section ; une correction qu'il trouve trop grosse y arrive aussi, avec ce qu'il a trouvé (une ancienne a un bouton En fonctionnalité). Demandez à un agent « tu l'as déposé ? » ou « où en est ma fonctionnalité ? » et son outil list_requests montre chaque correction et demande de fonctionnalité : quand et par qui elle a été déposée, et si elle est en attente, en construction, en pull request (son lien et ses vérifications), fusionnée, abandonnée ou trop grosse. Avec Paramètres > Agents du bureau > Proposer des corrections et des fonctionnalités (et Me parler de lui-même), l'agent peut aussi en proposer une lui-même, au plus tous les deux jours, d'après ce qu'il a vu échouer ou vous gêner (ce qui a échoué dans sa mémoire, les routines que vous avez annulées, les erreurs de ses outils, les applications où l'accompagnement vous a vu) : Oui, fais-le la dépose, Ne me dis plus ça ne la propose plus jamais. Chaque fonctionnalité est construite comme une correction (un clone du dépôt, une session qui ne peut modifier que les fichiers de ce clone, les mêmes vérifications et zones interdites) mais peut être plus grande (15 fichiers et 600 lignes par défaut, nouveaux fichiers permis), commitée en feat(…) et ouverte en pull request. Elle n'est jamais fusionnée seule : quand la CI passe, vous avez Fusionner, Voir et Abandonner. Celle qu'il ne peut pas faire (un choix de conception qui vous revient, plus qu'il ne peut changer, un endroit interdit, des identifiants, du matériel, ou sa modification refusée deux fois) est abandonnée avec la raison et ce qui la rendrait faisable : une notification propose Réessayer et Ignorer, et elle attend dans la liste Abandonnées de la section, jamais réessayée sauf si vous appuyez sur Réessayer. Elle utilise le jeton GitHub et le modèle de Corrections qu'il fait lui-même ; au plus 1 par jour de lui-même par défaut (Fonctionnalités par jour de lui-même dans cette section, 0 : sans limite ; Dépense maximale par fonctionnalité plafonne chacune), Construire maintenant en lance une tout de suite (pendant qu'une autre est en cours, elle attend dans la file partagée avec les corrections et démarre seule ensuite). Dites « construis-la maintenant » (ou plus tard « commence à construire cette fonctionnalité ») et l'agent la lance de même ; « corrige-le maintenant » fait pareil pour une correction, et demander où elle en est donne son état (en attente, en cours, pull request ouverte, CI réussie). Seules les machines dont la configuration Nix active le correcteur l'ont.";
      de = "Schalte Einstellungen > Desktop-Agenten > Funktionen, die es baut > Die Funktionen bauen, die ich wünsche ein, und Muse baut, was du dir von nixbook wünschst (ein neues Widget, eine Einstellung, ein Tastenkürzel oder Verhalten), getrennt von den Korrekturen. Sag es einem Agenten („ich hätte gern, dass die Leiste … zeigt“, „füg eine Möglichkeit hinzu, …“: er reicht es mit seinem Werkzeug request_feature ein) oder schreib es in diesen Abschnitt; eine Korrektur, die sich als zu groß erweist, landet auch dort, mit dem, was es gefunden hat (eine ältere bekommt einen Knopf Als Funktion). Frag einen Agenten „hast du es eingereicht?“ oder „wie steht es um meine Funktion?“, und sein Werkzeug list_requests zeigt jede Korrektur und jeden Funktionswunsch: wann und von wem eingereicht, und ob er wartet, gebaut wird, ein Pull Request ist (sein Link und seine Prüfungen), zusammengeführt, verworfen oder zu groß ist. Mit Einstellungen > Desktop-Agenten > Korrekturen und Funktionen vorschlagen (und Von selbst mit mir reden) kann der Agent auch selbst eine vorschlagen, höchstens alle zwei Tage, nach dem, was er schiefgehen oder dich stören sah (was in seinem Gedächtnis fehlschlug, Routinen, die du rückgängig gemacht hast, Fehler seiner Werkzeuge, die Apps, in denen ihn das Begleiten dich sah): Ja, mach das reicht sie ein, Sag mir das nicht mehr schlägt sie nie wieder vor. Jede Funktion wird wie eine Korrektur gebaut (ein Klon des Repositorys, eine Sitzung, die nur dort Dateien bearbeiten kann, dieselben Prüfungen und Sperrbereiche), darf aber größer sein (standardmäßig 15 Dateien und 600 Zeilen, neue Dateien erlaubt), wird als feat(…) committet und als Pull Request geöffnet. Sie wird nie von selbst zusammengeführt: sobald die CI durchläuft, bekommst du Zusammenführen, Ansehen und Verwerfen. Eine, die es nicht schafft (eine Designentscheidung, die bei dir liegt, mehr als es ändern darf, ein gesperrter Ort, Zugangsdaten, Hardware, oder ihre Änderung zweimal abgelehnt), wird mit Grund und dem, was sie machbar machen würde, aufgegeben: eine Benachrichtigung bietet Erneut versuchen und Verwerfen, und sie wartet in der Liste Aufgegeben des Abschnitts, nie wieder versucht, außer du drückst Erneut versuchen. Sie nutzt das GitHub-Token und das Modell aus Korrekturen, die es selbst macht; standardmäßig höchstens 1 am Tag von selbst (Funktionen pro Tag von selbst in diesem Abschnitt, 0: keine Grenze; Höchstausgabe pro Funktion begrenzt jede), Jetzt bauen startet eine sofort (während eine andere läuft, wartet sie in der mit den Korrekturen geteilten Warteschlange und startet danach von selbst). Sag „bau es jetzt“ (oder später „fang an, diese Funktion zu bauen“), und der Agent startet sie genauso; „korrigier das jetzt“ tut das für eine Korrektur, und auf die Frage, wie es läuft, nennt er den Stand (wartet, wird gebaut, Pull Request offen, CI bestanden). Nur Rechner, deren Nix-Konfiguration den Korrektor aktiviert, haben es.";
      vi = "Bật Cài đặt > Tác nhân màn hình > Tính năng nó xây dựng > Xây dựng các tính năng tôi yêu cầu và Muse sẽ xây dựng những gì bạn muốn nixbook làm (một widget, cài đặt, phím tắt hay hành vi mới), tách riêng với các bản sửa lỗi. Hãy nhờ một tác nhân (\"tôi muốn thanh trên cùng hiển thị…\", \"thêm cách để…\": nó ghi lại bằng công cụ request_feature) hoặc gõ vào mục đó; một bản sửa mà nó thấy quá lớn cũng chuyển sang đó, kèm điều nó tìm thấy (bản cũ có nút Thành tính năng). Hỏi một tác nhân \"bạn đã ghi lại chưa?\" hoặc \"tính năng của tôi thế nào rồi?\" và công cụ list_requests của nó cho thấy từng bản sửa và yêu cầu tính năng: được ghi lại khi nào và bởi ai, và nó đang chờ, đang xây dựng, là một pull request (đường dẫn và các bước kiểm tra), đã hợp nhất, đã bỏ hay quá lớn. Khi bật Cài đặt > Tác nhân màn hình > Đề xuất sửa lỗi và tính năng (và Tự nói chuyện với tôi), tác nhân cũng có thể tự đề xuất một cái, tối đa hai ngày một lần, từ những gì nó thấy hỏng hoặc làm phiền bạn (điều thất bại trong bộ nhớ, các thói quen tự động bạn đã hủy, lỗi của công cụ, các ứng dụng mà chế độ đồng hành thấy bạn dùng): Có, làm đi sẽ ghi lại, Đừng nói điều này nữa sẽ không bao giờ đề xuất lại. Mỗi tính năng được xây như một bản sửa (một bản sao kho mã, một phiên chỉ được sửa tệp trong đó, cùng các bước kiểm tra và vùng cấm) nhưng có thể lớn hơn (mặc định 15 tệp và 600 dòng, được thêm tệp mới), commit dạng feat(…) và mở thành pull request. Nó không bao giờ tự hợp nhất: khi CI qua, bạn có Hợp nhất, Xem và Bỏ. Tính năng nó không làm được (một lựa chọn thiết kế chỉ bạn quyết, nhiều hơn mức được phép thay đổi, một chỗ bị cấm, thông tin đăng nhập, phần cứng, hoặc thay đổi bị từ chối hai lần) bị bỏ kèm lý do và điều gì sẽ giúp làm được: bạn nhận thông báo với Thử lại và Bỏ qua, và nó chờ trong danh sách Đã bỏ của mục đó, không bao giờ thử lại trừ khi bạn bấm Thử lại. Nó dùng token GitHub và mô hình đặt ở Tự sửa lỗi; mặc định tối đa 1 lần mỗi ngày tự động (Số tính năng mỗi ngày trong mục đó, 0: không giới hạn; Chi tối đa mỗi tính năng giới hạn từng cái), Xây ngay bắt đầu một cái ngay lập tức (nếu đang có một cái khác chạy, nó chờ trong hàng đợi chung với các bản sửa và tự bắt đầu sau đó). Nói \"xây ngay đi\" (hoặc sau đó \"bắt đầu xây tính năng đó\") và tác nhân sẽ bắt đầu y như vậy; \"sửa ngay đi\" làm thế cho một bản sửa, và hỏi tiến độ sẽ cho biết trạng thái (đang chờ, đang làm, pull request đã mở, CI đã qua). Chỉ những máy có cấu hình Nix bật trình sửa lỗi mới có nó.";
    };
    personalMemory = {
      en = "Muse in the side panel remembers what you tell it about your life (events, plans, people, interests) across conversations: it keeps the meaningful parts, one entry per subject, and gets only what a conversation needs (your profile, events coming up, the entries about what you talk about). Ask it to remember or forget something; review or delete entries in Settings > Desktop agents > About you, or with nixbook-desktop-mcp personal show.";
      fr = "Muse dans le panneau latéral se souvient de ce que vous lui dites de votre vie (événements, projets, proches, centres d'intérêt) d'une conversation à l'autre : il garde l'essentiel, une entrée par sujet, et ne reçoit que ce dont une conversation a besoin (votre profil, les événements à venir, les entrées sur ce dont vous parlez). Demandez-lui de retenir ou d'oublier quelque chose ; consultez ou supprimez les entrées dans Paramètres > Agents du bureau > À propos de vous, ou avec nixbook-desktop-mcp personal show.";
      de = "Muse in der Seitenleiste merkt sich über Gespräche hinweg, was du ihm über dein Leben erzählst (Ereignisse, Pläne, Menschen, Interessen): Es behält das Wesentliche, einen Eintrag pro Thema, und bekommt nur, was ein Gespräch braucht (dein Profil, anstehende Ereignisse, die Einträge zu dem, worüber du sprichst). Bitte es, sich etwas zu merken oder zu vergessen; Einträge ansehen oder löschen unter Einstellungen > Desktop-Agenten > Über dich oder mit nixbook-desktop-mcp personal show.";
      vi = "Muse trong bảng bên ghi nhớ những gì bạn kể về cuộc sống của mình (sự kiện, kế hoạch, người thân, sở thích) qua các cuộc trò chuyện: nó giữ những phần quan trọng, mỗi chủ đề một mục, và chỉ nhận những gì cuộc trò chuyện cần (hồ sơ của bạn, sự kiện sắp tới, các mục về điều bạn đang nói). Hãy bảo nó nhớ hoặc quên điều gì đó; xem hoặc xóa các mục trong Cài đặt > Tác nhân màn hình > Về bạn, hoặc bằng nixbook-desktop-mcp personal show.";
    };
    keepSync = {
      en = "To sync your notes with Google Keep, open the Notes window and click Keep (next to New): give it your Google account's email and its master token (the button beside the field opens gpsoauth's alternative flow, which explains how to get one). The two are kept in the keyring, never in the notes nor in the settings. What you change in the shell is pushed to Keep, what changes in Keep comes back (when both changed, the newer one wins); deletions are not synced: a note deleted in one place stays in the other. The shell syncs every keep.refreshMinutes (15) when keep.enable is on, and Sync now syncs at once. Settings > General > Google Keep has the interval and the two directions (keep.push sends the shell's new notes to Keep, keep.pull brings Keep's new notes in). Google has no public Keep API, so this goes through an unofficial client (gkeepapi).";
      fr = "Pour synchroniser vos notes avec Google Keep, ouvrez la fenêtre Notes et cliquez sur Keep (à côté de Nouveau) : donnez-lui l'email de votre compte Google et son master token (le bouton à côté du champ ouvre le flux alternatif de gpsoauth, qui explique comment l'obtenir). Les deux sont gardés dans le trousseau, jamais dans les notes ni dans les réglages. Ce que vous changez dans le shell est envoyé à Keep, ce qui change dans Keep revient ici (si les deux changent, le plus récent gagne) ; les suppressions ne sont pas synchronisées : une note supprimée d'un côté reste de l'autre. Le shell synchronise toutes les keep.refreshMinutes (15) si keep.enable est actif, et Synchroniser maintenant le fait tout de suite. Paramètres > Général > Google Keep a l'intervalle et les deux sens (keep.push envoie les nouvelles notes du shell à Keep, keep.pull ramène les nouvelles notes de Keep). Google n'a pas d'API Keep publique, donc tout passe par un client non officiel (gkeepapi).";
      de = "Um deine Notizen mit Google Keep zu synchronisieren, öffne das Notizen-Fenster und klicke auf Keep (neben Neu): gib die E-Mail deines Google-Kontos und dessen Master-Token ein (der Knopf neben dem Feld öffnet gpsoauths alternativen Ablauf, der erklärt, wie man eines bekommt). Beides liegt im Schlüsselbund, nie in den Notizen und nie in den Einstellungen. Was du in der Shell änderst, wird zu Keep geschickt, was sich in Keep ändert, kommt zurück (ändern sich beide, gewinnt das neuere); Löschungen werden nicht synchronisiert: eine gelöschte Notiz bleibt an der anderen Stelle. Die Shell synchronisiert alle keep.refreshMinutes (15), wenn keep.enable an ist, und Jetzt synchronisieren macht es sofort. Einstellungen > Allgemein > Google Keep hat das Intervall und beide Richtungen (keep.push sendet die neuen Notizen der Shell an Keep, keep.pull holt Keeps neue Notizen). Google hat keine öffentliche Keep-API, das läuft also über einen inoffiziellen Client (gkeepapi).";
      vi = "Để đồng bộ ghi chú của bạn với Google Keep, mở cửa sổ Ghi chú và bấm Keep (cạnh nút Mới): nhập email tài khoản Google và master token của tài khoản (nút cạnh ô có nhập mở luồng thay thế của gpsoauth, giải thích cách lấy token này). Cả hai được giữ trong keyring, không bao giờ nằm trong ghi chú hay trong cài đặt. Những gì bạn sửa trong shell sẽ được gửi sang Keep, những gì đổi trong Keep sẽ quay lại (nếu cả hai đều đổi, bên nào mới hơn thắng); việc xóa không được đồng bộ: ghi chú bị xóa ở một nơi vẫn còn ở nơi kia. Shell đồng bộ mỗi keep.refreshMinutes (15) khi keep.enable bật, và nút Đồng bộ ngay làm ngay lập tức. Cài đặt > Chung > Google Keep có khoảng thời gian và hai chiều (keep.push gửi ghi chú mới của shell sang Keep, keep.pull lấy ghi chú mới từ Keep về). Google không có API Keep công khai, nên việc này đi qua một thư viện không chính thức (gkeepapi).";
    };
  };

  # Generic answers to "how do I …" questions; the configuration's own way
  # of doing it (a deploy tool, an update script) overrides one by name.
  defaultHowTo =
    calendarHowTo
    // shellHowTo
    // (
      if os != null then
        {
          apply = {
            en = "To apply a change to the NixOS configuration, run `sudo nixos-rebuild switch`.";
            fr = "Pour appliquer une modification de la configuration NixOS, lancez `sudo nixos-rebuild switch`.";
            de = "Um eine Änderung der NixOS-Konfiguration anzuwenden, führe `sudo nixos-rebuild switch` aus.";
            vi = "Để áp dụng thay đổi cấu hình NixOS, chạy `sudo nixos-rebuild switch`.";
          };
          update = {
            en = "To update the system, update nixpkgs (`sudo nix-channel --update`, or `nix flake update` for a flake) and run `sudo nixos-rebuild switch`.";
            fr = "Pour mettre à jour le système, mettez à jour nixpkgs (`sudo nix-channel --update`, ou `nix flake update` pour un flake) puis lancez `sudo nixos-rebuild switch`.";
            de = "Um das System zu aktualisieren, aktualisiere nixpkgs (`sudo nix-channel --update` oder `nix flake update` bei einem Flake) und führe `sudo nixos-rebuild switch` aus.";
            vi = "Để cập nhật hệ thống, cập nhật nixpkgs (`sudo nix-channel --update`, hoặc `nix flake update` với flake) rồi chạy `sudo nixos-rebuild switch`.";
          };
          rollback = {
            en = "To roll back (undo) the last system change, run `sudo nixos-rebuild switch --rollback`, or choose an older generation in the boot menu.";
            fr = "Pour revenir en arrière (annuler) la dernière modification du système, lancez `sudo nixos-rebuild switch --rollback`, ou choisissez une génération plus ancienne dans le menu de démarrage.";
            de = "Um die letzte Systemänderung zurückzusetzen (rückgängig zu machen), führe `sudo nixos-rebuild switch --rollback` aus oder wähle im Bootmenü eine ältere Generation.";
            vi = "Để quay lại (hoàn tác) thay đổi hệ thống gần nhất, chạy `sudo nixos-rebuild switch --rollback`, hoặc chọn một thế hệ (generation) cũ hơn trong menu khởi động.";
          };
          generations = {
            en = "To list the system generations (previous versions of the system), run `nixos-rebuild list-generations`.";
            fr = "Pour lister les générations du système (versions précédentes du système), lancez `nixos-rebuild list-generations`.";
            de = "Um die Systemgenerationen (frühere Versionen des Systems) aufzulisten, führe `nixos-rebuild list-generations` aus.";
            vi = "Để liệt kê các thế hệ (generation, phiên bản trước) của hệ thống, chạy `nixos-rebuild list-generations`.";
          };
          gc = {
            en = "To free disk space, delete old generations and unused packages with `sudo nix-collect-garbage -d` (garbage collection), then apply the configuration again to clean the boot menu.";
            fr = "Pour libérer de l'espace disque, supprimez les anciennes générations et les paquets inutilisés avec `sudo nix-collect-garbage -d` (ramasse-miettes), puis appliquez de nouveau la configuration pour nettoyer le menu de démarrage.";
            de = "Um Speicherplatz freizugeben, lösche alte Generationen und ungenutzte Pakete mit `sudo nix-collect-garbage -d` (Garbage Collection) und wende die Konfiguration erneut an, um das Bootmenü aufzuräumen.";
            vi = "Để giải phóng dung lượng đĩa, xóa các thế hệ cũ và gói không dùng bằng `sudo nix-collect-garbage -d` (dọn rác), rồi áp dụng lại cấu hình để dọn menu khởi động.";
          };
          search = {
            en = "To find a package, run `nix search nixpkgs <name>` or search https://search.nixos.org/packages.";
            fr = "Pour trouver un paquet, lancez `nix search nixpkgs <nom>` ou cherchez sur https://search.nixos.org/packages.";
            de = "Um ein Paket zu finden, führe `nix search nixpkgs <name>` aus oder suche auf https://search.nixos.org/packages.";
            vi = "Để tìm một gói, chạy `nix search nixpkgs <tên>` hoặc tìm trên https://search.nixos.org/packages.";
          };
          try = {
            en = "To try a program without installing it, run `nix shell nixpkgs#<name>` (or `nix run nixpkgs#<name>`).";
            fr = "Pour essayer un programme sans l'installer, lancez `nix shell nixpkgs#<nom>` (ou `nix run nixpkgs#<nom>`).";
            de = "Um ein Programm ohne Installation auszuprobieren, führe `nix shell nixpkgs#<name>` (oder `nix run nixpkgs#<name>`) aus.";
            vi = "Để dùng thử một chương trình mà không cài, chạy `nix shell nixpkgs#<tên>` (hoặc `nix run nixpkgs#<tên>`).";
          };
          install = {
            en = "To install a program for good, add it to environment.systemPackages (system) or home.packages (Home Manager) in the configuration, then apply it.";
            fr = "Pour installer un programme durablement, ajoutez-le à environment.systemPackages (système) ou home.packages (Home Manager) dans la configuration, puis appliquez-la.";
            de = "Um ein Programm dauerhaft zu installieren, füge es in der Konfiguration zu environment.systemPackages (System) oder home.packages (Home Manager) hinzu und wende sie an.";
            vi = "Để cài một chương trình lâu dài, thêm nó vào environment.systemPackages (hệ thống) hoặc home.packages (Home Manager) trong cấu hình, rồi áp dụng.";
          };
          logs = {
            en = "To see a service's logs, run `journalctl -u <service>` (`journalctl --user -u <service>` for a user service); `systemctl status <service>` shows whether it is running.";
            fr = "Pour voir les journaux (logs) d'un service, lancez `journalctl -u <service>` (`journalctl --user -u <service>` pour un service utilisateur) ; `systemctl status <service>` indique s'il tourne.";
            de = "Um die Protokolle (Logs) eines Dienstes zu sehen, führe `journalctl -u <dienst>` aus (`journalctl --user -u <dienst>` für einen Benutzerdienst); `systemctl status <dienst>` zeigt, ob er läuft.";
            vi = "Để xem nhật ký (log) của một dịch vụ, chạy `journalctl -u <dịch vụ>` (`journalctl --user -u <dịch vụ>` với dịch vụ người dùng); `systemctl status <dịch vụ>` cho biết nó có đang chạy không.";
          };
          options = {
            en = "To look up configuration options, run `man configuration.nix` (NixOS) or `man home-configuration.nix` (Home Manager), or search https://search.nixos.org/options.";
            fr = "Pour chercher des options de configuration, lancez `man configuration.nix` (NixOS) ou `man home-configuration.nix` (Home Manager), ou cherchez sur https://search.nixos.org/options.";
            de = "Um Konfigurationsoptionen nachzuschlagen, führe `man configuration.nix` (NixOS) oder `man home-configuration.nix` (Home Manager) aus oder suche auf https://search.nixos.org/options.";
            vi = "Để tra cứu tùy chọn cấu hình, chạy `man configuration.nix` (NixOS) hoặc `man home-configuration.nix` (Home Manager), hoặc tìm trên https://search.nixos.org/options.";
          };
        }
      else
        {
          apply = {
            en = "To apply a change to the Home Manager configuration, run `home-manager switch`.";
            fr = "Pour appliquer une modification de la configuration Home Manager, lancez `home-manager switch`.";
            de = "Um eine Änderung der Home-Manager-Konfiguration anzuwenden, führe `home-manager switch` aus.";
            vi = "Để áp dụng thay đổi cấu hình Home Manager, chạy `home-manager switch`.";
          };
          generations = {
            en = "To list the Home Manager generations (previous versions), run `home-manager generations`; run a generation's `activate` script to roll back to it.";
            fr = "Pour lister les générations Home Manager (versions précédentes), lancez `home-manager generations` ; lancez le script `activate` d'une génération pour y revenir.";
            de = "Um die Home-Manager-Generationen (frühere Versionen) aufzulisten, führe `home-manager generations` aus; das `activate`-Skript einer Generation setzt auf sie zurück.";
            vi = "Để liệt kê các thế hệ Home Manager (phiên bản trước), chạy `home-manager generations`; chạy script `activate` của một thế hệ để quay lại nó.";
          };
          gc = {
            en = "To free disk space, run `home-manager expire-generations '-30 days'` then `nix-collect-garbage` (garbage collection).";
            fr = "Pour libérer de l'espace disque, lancez `home-manager expire-generations '-30 days'` puis `nix-collect-garbage` (ramasse-miettes).";
            de = "Um Speicherplatz freizugeben, führe `home-manager expire-generations '-30 days'` und dann `nix-collect-garbage` (Garbage Collection) aus.";
            vi = "Để giải phóng dung lượng đĩa, chạy `home-manager expire-generations '-30 days'` rồi `nix-collect-garbage` (dọn rác).";
          };
          search = {
            en = "To find a package, run `nix search nixpkgs <name>` or search https://search.nixos.org/packages.";
            fr = "Pour trouver un paquet, lancez `nix search nixpkgs <nom>` ou cherchez sur https://search.nixos.org/packages.";
            de = "Um ein Paket zu finden, führe `nix search nixpkgs <name>` aus oder suche auf https://search.nixos.org/packages.";
            vi = "Để tìm một gói, chạy `nix search nixpkgs <tên>` hoặc tìm trên https://search.nixos.org/packages.";
          };
          try = {
            en = "To try a program without installing it, run `nix shell nixpkgs#<name>` (or `nix run nixpkgs#<name>`).";
            fr = "Pour essayer un programme sans l'installer, lancez `nix shell nixpkgs#<nom>` (ou `nix run nixpkgs#<nom>`).";
            de = "Um ein Programm ohne Installation auszuprobieren, führe `nix shell nixpkgs#<name>` (oder `nix run nixpkgs#<name>`) aus.";
            vi = "Để dùng thử một chương trình mà không cài, chạy `nix shell nixpkgs#<tên>` (hoặc `nix run nixpkgs#<tên>`).";
          };
          install = {
            en = "To install a program for good, add it to home.packages in the Home Manager configuration, then run `home-manager switch`.";
            fr = "Pour installer un programme durablement, ajoutez-le à home.packages dans la configuration Home Manager, puis lancez `home-manager switch`.";
            de = "Um ein Programm dauerhaft zu installieren, füge es in der Home-Manager-Konfiguration zu home.packages hinzu und führe `home-manager switch` aus.";
            vi = "Để cài một chương trình lâu dài, thêm nó vào home.packages trong cấu hình Home Manager, rồi chạy `home-manager switch`.";
          };
          logs = {
            en = "To see a user service's logs, run `journalctl --user -u <service>`; `systemctl --user status <service>` shows whether it is running.";
            fr = "Pour voir les journaux (logs) d'un service utilisateur, lancez `journalctl --user -u <service>` ; `systemctl --user status <service>` indique s'il tourne.";
            de = "Um die Protokolle (Logs) eines Benutzerdienstes zu sehen, führe `journalctl --user -u <dienst>` aus; `systemctl --user status <dienst>` zeigt, ob er läuft.";
            vi = "Để xem nhật ký (log) của dịch vụ người dùng, chạy `journalctl --user -u <dịch vụ>`; `systemctl --user status <dịch vụ>` cho biết nó có đang chạy không.";
          };
          options = {
            en = "To look up Home Manager options, run `man home-configuration.nix` or search https://home-manager-options.extranix.com.";
            fr = "Pour chercher des options Home Manager, lancez `man home-configuration.nix` ou cherchez sur https://home-manager-options.extranix.com.";
            de = "Um Home-Manager-Optionen nachzuschlagen, führe `man home-configuration.nix` aus oder suche auf https://home-manager-options.extranix.com.";
            vi = "Để tra cứu tùy chọn Home Manager, chạy `man home-configuration.nix` hoặc tìm trên https://home-manager-options.extranix.com.";
          };
        }
    );
  packages =
    config.home.packages ++ lib.optionals (osConfig != null) osConfig.environment.systemPackages;

  # The Neovim keymaps, for scripts/assistant-facts.py.
  nvimInfo = {
    inherit (cfg.assistant.nixvim) leader localLeader keymaps;
  };
  # What scripts/assistant-facts.py turns into facts and the AI context.
  howTo = lib.filterAttrs (_: v: v != null) cfg.assistant.howTo;
  contextInfo = {
    nvim = nvimInfo;
    os = cfg.assistant.os;
    inherit howTo;
  };

  # Machine context for the Intelligence tab's system prompt
  # (services/Ai.qml appends it while ai.includeSystemContext is on), plus the
  # niri keybinds and Neovim keymaps when there are any. No secrets: it is a
  # store path.
  systemContextFile =
    pkgs.runCommand "nixbook-shell-system-context.md"
      {
        header = cfg.assistant.context;
        niriKdl = cfg.assistant.niriConfig;
        info = builtins.toJSON contextInfo;
        passAsFile = [
          "header"
          "niriKdl"
          "info"
        ];
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        {
          printf '# About this machine (reference)\n'
          printf 'The sections below are generated from this machine'"'"'s configuration. Use them as reference together with your own knowledge: they do not limit what you can answer. Answer any question; when you are not sure, say so.\n\n'
          cat "$headerPath"
        } > "$out"
        if [ -s "$niriKdlPath" ]; then
          {
            printf '\n## Keyboard shortcuts (niri, rendered from the configuration)\n'
            printf 'The niri keybinds as configured (Mod = the Super/Windows key; a spawn of nixbook-shell ipc call <target> <fn> opens a shell panel).\n```kdl\n'
            # Store paths only add noise: /nix/store/<hash>-kitty-0.49/bin/kitty -> kitty
            ${lib.getExe pkgs.gawk} '/^binds \{/,/^\}/' "$niriKdlPath" \
              | ${lib.getExe pkgs.gnused} -E 's#/nix/store/[a-z0-9]{32}-[^/ "]*/bin/##g'
            printf '```\n'
          } >> "$out"
        fi
        python3 ${./scripts/assistant-facts.py} --markdown "$infoPath" >> "$out"
      '';

  # The short version Muse's system prompt carries (services/Ai.qml, the
  # bubble and the side panel): host, shell, enabled modules, the OS's main
  # facts and the niri binds one line each, at most 6000 characters; the
  # rest (how-tos, packages, Neovim keymaps…) is searched with the desktop
  # server's machine_help tool, in the whole file above. Deterministic, so
  # the prompt stays byte-stable for the model's prompt cache.
  systemContextSummaryFile =
    pkgs.runCommand "nixbook-shell-system-context-summary.md"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${./scripts/context-summary.py} ${systemContextFile} 6000 > "$out"
      '';

  # The same, as retrievable one-sentence facts for the chat's config
  # assistant (services/ConfigAssistant.qml, no AI: it answers from these —
  # keys, modules, installed packages, settings). Built by
  # scripts/assistant-facts.py.
  systemFactsFile =
    let
      info = {
        host = if osConfig != null then osConfig.networking.hostName else "unknown";
        user = config.home.username;
        inherit (cfg.assistant) coreFacts modules;
        pinned = lib.genAttrs pinnedPaths (
          path: lib.attrByPath (lib.splitString "." path) null pinnedSettings
        );
        packages = names packages;
        # Every setting the shell has (answers naming another are flagged).
        settingPaths = settingsLib.flattenPaths [ ] settingsLib.builtinDefaults ++ settingsLib.liveKeys;
        inherit (contextInfo) nvim os howTo;
      };
    in
    pkgs.runCommand "nixbook-shell-system-facts.json"
      {
        info = builtins.toJSON info;
        niriKdl = cfg.assistant.niriConfig;
        passAsFile = [
          "info"
          "niriKdl"
        ];
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        ${lib.getExe pkgs.gawk} '/^binds \{/,/^\}/' "$niriKdlPath" \
          | ${lib.getExe pkgs.gnused} -E 's#/nix/store/[a-z0-9]{32}-[^/ "]*/bin/##g' > binds.kdl
        python3 ${./scripts/assistant-facts.py} "$infoPath" binds.kdl > "$out"
      '';

  # Four-language sentence, as scripts/assistant-facts.py expects.
  factType = lib.types.submodule {
    options = lib.genAttrs [ "en" "fr" "de" "vi" ] (lang: lib.mkOption { type = lib.types.str; });
  };
in
{
  # The apps coloured like the shell are switched on from the Settings menu
  # now (appearance.wallpaperTheming.apps), live.
  imports =
    map
      (
        app:
        lib.mkRemovedOptionModule [ "programs" "nixbook-shell" "appTheming" app ] ''
          The apps coloured from the shell's palette are switched on and off in
          the shell: Settings > Appearance > Color generation > Apps.
        ''
      )
      [
        "vesktop"
        "youtubeMusic"
        "zen"
      ];

  options.programs.nixbook-shell = {
    enable = lib.mkEnableOption ''
      nixbook-shell, a Quickshell (QML) desktop shell (bar, dock, sidebars,
      launcher, notifications, lock screen, desktop widgets). It runs as the
      `nixbook-shell` user service, bound to `graphical-session.target`, under
      niri; bind keys to `nixbook-shell ipc call <target> <function>`
      to drive its panels'';

    package = lib.mkOption {
      type = lib.types.package;
      default =
        (import ./default.nix {
          inherit pkgs;
          inherit (vpnClients) withTailscale withNetbird;
        }).package;
      defaultText = lib.literalExpression "(import ./nixbook-shell { inherit pkgs; }).package";
      description = ''
        The `nixbook-shell` launcher. Build it with your own quickshell pin
        through `import ./nixbook-shell { inherit pkgs quickshellSrc; }`.
        Under NixOS, the tailscale / netbird CLIs are only bundled when the
        system enables `services.tailscale` / `services.netbird`
        (`withTailscale` / `withNetbird`); standalone, both are.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.submodule settingsLib.settingsModule;
      default = { };
      # ~450 generated leaves: document the option, not every leaf.
      visible = "shallow";
      example = lib.literalExpression ''
        {
          bar.bottom = true;
          background.screenList = [ "eDP-1" ];
          appearance.theme = "persona";
          appearance.persona.variant = "p3r";
        }
      '';
      description = ''
        nixbook-shell settings (the dot-paths of
        `~/.config/nixbook-shell/config.json`, as nested attributes).

        Every key set here is applied on each activation and **locked** in the
        shell's Settings menu (red lock, control disabled); every key left unset
        stays editable from the menu and persists across restarts, reboots and
        switches. Removing a key unlocks it in the running shell after the next
        switch.

        The keys are typed options generated from the shell's built-in
        defaults (`builtin-defaults.json`), so a misspelt key fails
        evaluation. `nixbook-shell config diff` prints the settings changed
        from the menu as Nix lines; `nixbook-shell config pinned` lists the
        locked keys. Runtime state (wallpaper path, accent colour, avatar,
        preset metadata) has no option: the shell and its scripts own it.
      '';
    };

    selfImprove.enable = lib.mkEnableOption ''
      the desktop agent fixing this configuration's repository itself
      (`nixbook-improve`, services/SelfImprove.qml): fixes and polish only,
      each a pull request made with its own GitHub token (set in Settings >
      Desktop agents, kept in the keyring; never the user's gh login or ssh
      key), and apart the features asked for (never merged on its own).
      Without it the Settings sections, the agents' `report_problem`,
      `request_feature` and `list_requests` tools, their improvement ideas
      and `nixbook-improve`
      are absent or refuse; with it both stay off until turned on in
      Settings (`ai.improve.enable`, `ai.improve.features.enable`)'';

    voice.echoCancel.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Give the voice (Mod+T, Full AI mode) a microphone that doesn't hear the
        computer's own sound: a PipeWire echo canceller (WebRTC, in monitor
        mode: what the default output plays is the echo reference, nothing is
        rerouted) adds the source `nixbook-echo-cancel-source`, which the
        voice records from when it exists (`nixbook-voice-stream`, the local
        recorder). Other apps keep the default microphone. Passive: it only
        processes while the voice listens. The drop-in
        (~/.config/pipewire/pipewire.conf.d/60-nixbook-echo-cancel.conf) is
        read when PipeWire starts: after the first switch, log out and in, or
        `systemctl --user restart pipewire pipewire-pulse wireplumber` (sound
        cuts out for a second, so it isn't done on activation).
      '';
    };

    cliphist.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the cliphist store daemon the shell's clipboard history (search
        `clipboardToggle`) reads from. Turn it off if something else already
        runs `cliphist store`.
      '';
    };

    splash.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Show the shell's loading screen from the moment the session starts
        (`nixbook-shell splash`, the `nixbook-shell-splash` user service),
        until the shell has loaded and its own loading screen takes over: no
        black screen or half-drawn desktop between the login screen and the
        shell.
      '';
    };

    # "The shell's palette": the one it shows, the wallpaper's or a theme
    # variant's own (Persona, Chiikawa, Cyberpunk…), light or dark. Which apps
    # follow it is chosen in the shell (Settings > Appearance > Color
    # generation > Apps); only what has to be set up outside it is here.
    appTheming = {
      qt.enable = lib.mkEnableOption ''
        Qt apps following the shell's palette when "Qt & KDE" is on in the
        shell's Settings (Appearance > Color generation > Apps): Qt goes
        through qt6ct/qt5ct with the Breeze style and a custom palette (the
        colour scheme the shell generates). KDE apps (Dolphin…) get the same
        scheme in ~/.config/kdeglobals from the shell alone. Running apps
        follow palette changes. Sets `qt.*`: turn off anything else theming Qt
        (e.g. stylix's `qt` target)
      '';
    };

    electronBridge.apps = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            app = lib.mkOption {
              type = lib.types.strMatching "[a-z0-9][a-z0-9-]{0,31}";
              description = "The name agents know it by (`discord`).";
            };
            command = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "The app's own command (not the bridged wrapper).";
            };
            markers = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Its store paths: a process naming one is the app.";
            };
            a11y = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "With its accessibility tree on.";
            };
          };
        }
      );
      default = [ ];
      description = ''
        The Electron apps started through `nixbook-electron-app`
        (`package.passthru.electronBridge`) on this machine. When it lists
        any, the `nixbook-electron-watch` user service watches them: one
        that runs without the bridge (it restarted itself, an autostart
        entry or another launcher started it) is restarted through it when
        it has just started and isn't in a call, otherwise you get a
        notification with "Restart with bridge" (never stopped unasked).
        Written to `~/.config/nixbook-shell/electron-bridge.json`. nixbook
        fills it from the apps lib/electronA11y.nix bridges.
      '';
    };

    desktopMcp = {
      settings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = (pkgs.formats.json { }).type;
          options.tools = lib.mkOption {
            type = lib.types.listOf (
              lib.types.enum [
                "observe"
                "screen"
                "windows"
                "input"
                "shell"
                "memory"
                "personal"
                "ui"
                "pages"
                # The name of `pages` before: read as it.
                "browser"
                "terminal"
              ]
            );
            default = [
              "observe"
              "screen"
              "windows"
              "input"
              "shell"
              "memory"
              "personal"
              "ui"
              "pages"
              "terminal"
            ];
            description = ''
              Tool groups AI agents get: `observe` (windows, workspaces,
              apps), `screen` (screenshots, reading the clipboard and the
              recent notifications), `windows`
              (focus, move, close, launch apps), `input` (keyboard, pointer,
              writing the clipboard), `shell` (the shell's IPC, notifications),
              `memory` (notes agents keep about this desktop, and the digest of
              it they get when they connect), `personal` (what you tell
              agents about your life, remembered across conversations: an
              entry per subject, only the relevant part sent), `ui` (any app's window as text
              through its accessibility tree, and acting on its elements;
              needs the accessibility bus, nixbook's `niri.accessibility`;
              Firefox-based and Chromium/Electron apps through
              `desktopMcp.browserAccessibility`, on by default; Electron apps
              also need `--force-renderer-accessibility`: nixbook wraps its own,
              nixbookShellConfig.electronAccessibility), `pages` (web pages
              through the page itself: Zen's tabs, with nixbook's extension, and
              the Electron apps started through `nixbook-electron-app`, e.g.
              Vesktop, Slack, YouTube Music; read, click, type, forms, in the
              background, without the pointer or keys; Discord's messages
              through its own client too (find, read, send, react: sends always
              asked); `browser.blockedSites` / `browser.blockedContainers` and
              `pages.blockedApps` are off limits, by default password managers,
              Google account and payment sites, banks and the Banking container,
              and password manager apps are never bridged; `browser`, its name
              before, means the same), `terminal` (kitty's
              windows and nvim through their own remote control: reading the
              last command's output or the screen, putting a command on the
              prompt for you to run, running a command in Muse's own kitty tab
              after asking, the editor's file, cursor, selection and
              diagnostics, opening a file at a line; password prompts and
              secret tools are never read, secrets are redacted; typing into a
              terminal with the `input` tools stays refused; each part has its
              switch in the shell's `ai.terminal`).
            '';
          };
        };
        default = { };
        example = lib.literalExpression ''
          {
            tools = [ "observe" "windows" ];
            actionsPerMinute = 60;
            inputDenyApps = [ "^org\\.gnome\\.Nautilus$" ];
          }
        '';
        description = ''
          Settings of `nixbook-desktop-mcp`, the desktop control MCP server
          AI agents (the shell's AI chat and speech bubble, opencode, any MCP
          client…) use to see
          and drive the desktop, written to
          `~/.config/nixbook-shell/desktop-mcp.json`. Other keys:
          `inputDenyApps`, `inputDenyTitles` (regexes: no keyboard or pointer
          input into those windows; set to replace the defaults, which cover
          terminals, password managers and password prompts),
          `shellIpcDenyTargets`, `allowSuperKey`, `maxTextLength` (typed text and
          tasks), `maxNoteLength` (a note),
          `actionsPerMinute`, `notifyOnControl`, `cursorLeadMs` (how long a
          click or key waits after Muse's visible cursor shows where it goes,
          300; 0: no wait), `screenshotMaxEdge`,
          `ocrLanguages` (read_screen's tesseract languages, e.g. `eng+fra`).
          `nixbook-desktop-mcp config` prints the effective settings.
        '';
      };

      http = {
        enable = lib.mkEnableOption ''
          the desktop control MCP server over HTTP, for agents that can't
          start it themselves (the `nixbook-desktop-mcp` user service). It
          listens on 127.0.0.1 only, so nothing off this machine can reach
          it and no firewall port is opened; clients need the bearer token
          from `nixbook-desktop-mcp token`, and must run as this user'';
        port = lib.mkOption {
          type = lib.types.port;
          default = 7823;
          description = "Port on 127.0.0.1 of the HTTP MCP endpoint (`/mcp`).";
        };
      };

      browserAccessibility = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          The `ui` tools in Firefox-based and Chromium/Electron apps: sets
          `GNOME_ACCESSIBILITY` and `ACCESSIBILITY_ENABLED` in the session so
          they publish their accessibility tree (GTK and Qt apps always do).
          They then keep it up to date on every page change, all session long:
          more CPU, memory and scrolling jank in heavy pages. Off, agents read
          those apps with screenshots. Apps started before need a restart.
          Electron apps' pages also need `--force-renderer-accessibility` on
          their command line (the variables alone leave them empty): nixbook
          wraps Vesktop, Slack and YouTube Music with it
          (nixbookShellConfig.electronAccessibility, which follows this).
        '';
      };

      habits.enable = lib.mkEnableOption ''
        usage habits for good (otherwise Settings > Desktop agents turns them
        on and off): the `nixbook-habits` user service counts, on this
        machine and without any model, which app has the focus and for how
        long, the windows opened, the layouts restored and the themes chosen
        (app ids and times only: never window titles, files or input, but
        the cues of learned routines keep device and network names, and the
        music taste each track's artist, title and album, a year;
        nothing while locked, while an agent acts, for password managers or
        private browser windows). The launcher ranks apps with it, a weekly
        report sums it up, a theme switched at the same hour is suggested
        then, and agents get a short summary. Tune it with the
        `desktopMcp.settings` keys `habitsKeepDays` (28), `habitsAgents`
        (`digest`, `timeline` or `off`), `habitsTheme` (`suggest`, `auto` or
        `off`), `habitsWeeklyReport`, `habitsOpenAtUsualTime` (desktop ids
        opened at their usual time), `habitsIgnoreApps` and
        `habitsIgnoreTitles`. The music every player plays (MPRIS: artist,
        title, album, played or skipped) teaches agents the user's taste:
        `habitsMusic` (true), `habitsMusicKeepDays` (365),
        `habitsMusicIgnorePlayers` (regexes; default: web browsers)'';
    };

    assistant = {
      context = lib.mkOption {
        type = lib.types.lines;
        default = ''
          ## Desktop shell: nixbook-shell
          The bar, dock, sidebars, launcher, notifications, lock screen and desktop
          widgets are nixbook-shell, a Quickshell (QML) shell configured by the Home
          Manager module `programs.nixbook-shell`. Its settings live in
          `~/.config/nixbook-shell/config.json` and are edited from its Settings
          window ("Shell settings" in the launcher). Settings set in Nix
          (`programs.nixbook-shell.settings`) are locked in that window; everything
          else is editable there. `nixbook-shell config diff` prints the settings
          changed from the menu as Nix lines, `nixbook-shell ipc call <target>
          <function>` drives panels.

          Settings set in Nix on this machine:
          ${cfg.assistant.pinnedLines}

          ## Packages installed (Home Manager${lib.optionalString (osConfig != null) " and NixOS"})
          ${lib.concatStringsSep ", " (names packages)}
        '';
        defaultText = lib.literalMD "a description of the shell, the settings set in Nix and the installed packages";
        description = ''
          Markdown appended to the AI chat's system prompt while
          `ai.includeSystemContext` is on: what the assistant should know about
          this machine and how its configuration is changed. The niri keybinds
          (`assistant.niriConfig`) and Neovim keymaps (`assistant.nixvim`) are
          appended to it.
        '';
      };

      mcpServers = lib.mkOption {
        type = lib.types.attrsOf (pkgs.formats.json { }).type;
        default = {
          nixos.command = lib.getExe pkgs.mcp-nixos;
        };
        defaultText = lib.literalExpression "{ nixos.command = lib.getExe pkgs.mcp-nixos; }";
        example = lib.literalExpression ''
          {
            nixos.command = lib.getExe pkgs.mcp-nixos;
            trek = { type = "http"; url = "https://trek.example.org/mcp"; };
          }
        '';
        description = ''
          MCP servers the AI chat's Muse model gets besides the desktop one,
          in the usual `mcpServers` format (`command`/`args`/`env`, or
          `type = "http"` with `url`/`headers`), written to
          `~/.config/nixbook-shell/assistant-mcp.json`. All their tools are
          allowed. Not given while the chat's tools are disabled. The default,
          [MCP-NixOS](https://mcp-nixos.io), answers from the real NixOS,
          Home Manager and nix-darwin package and option data instead of
          guessing. `desktop` is reserved. The file is in the Nix store,
          which every user can read: no tokens or secrets in `env` or
          `headers` (point the server at a file of its own instead).
        '';
      };

      pinnedLines = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        default = lib.concatStringsSep "\n" (
          map (
            path:
            "- `${path}` = `${builtins.toJSON (lib.attrByPath (lib.splitString "." path) null pinnedSettings)}`"
          ) pinnedPaths
        );
        description = "The settings set in Nix, one Markdown list item each (for `assistant.context`).";
      };

      coreFacts = lib.mkOption {
        type = lib.types.listOf factType;
        default = [
          {
            en = "Shell settings (bar, dock, widgets, notifications, theme) set in Nix are in programs.nixbook-shell.settings of the Home Manager configuration; the others are changed in the shell's Settings window.";
            fr = "Les réglages du shell (barre, dock, widgets, notifications, thème) définis dans Nix sont dans programs.nixbook-shell.settings de la configuration Home Manager ; les autres se changent dans la fenêtre des paramètres du shell.";
            de = "In Nix gesetzte Shell-Einstellungen (Leiste, Dock, Widgets, Benachrichtigungen, Design) stehen in programs.nixbook-shell.settings der Home-Manager-Konfiguration; die übrigen werden im Einstellungsfenster der Shell geändert.";
            vi = "Thiết lập shell (thanh, dock, widget, thông báo, giao diện) đặt trong Nix nằm ở programs.nixbook-shell.settings của cấu hình Home Manager; các thiết lập khác đổi trong cửa sổ cài đặt của shell.";
          }
        ];
        description = ''
          Core statements for the config assistant (no AI), in English, French,
          German and Vietnamese: where and how this machine's configuration is
          changed and applied.
        '';
      };

      modules = {
        all = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Configuration modules the config assistant knows of.";
        };
        enabled = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "The enabled ones among `modules.all`.";
        };
      };

      niriConfig = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = lib.literalExpression "config.programs.niri.finalConfig";
        description = ''
          The rendered niri configuration (KDL): its `binds { … }` block
          becomes keybind facts and is appended to the AI context. Empty: no
          keybinds.
        '';
      };

      os = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = osInfo;
        defaultText = lib.literalMD "read from the evaluated NixOS (`osConfig`) and Home Manager configurations";
        description = ''
          The operating system as configured (NixOS release, kernel, host, time
          zone, locale, keyboard layout, bootloader, shell, editor, Nix,
          accounts, and `toggles`: every NixOS and Home Manager option set with
          a real `enable` option, discovered from the options trees, on or off
          — the NixOS ones need nixbook-shell's NixOS module), for the
          config assistant ("which kernel?", "is bluetooth enabled?", "which
          services are enabled?") and the AI context. Built from the evaluated
          configuration; override a key to correct or hide it (null).
        '';
      };

      howTo = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr factType);
        default = { };
        description = ''
          Answers to "how do I …" questions about the system, by name: `apply`,
          `update`, `rollback`, `generations`, `gc`, `search`, `try`,
          `install`, `logs`, `options` (generic NixOS ones by default, Home
          Manager ones without NixOS), and how the calendars, contacts and
          to-do list sync through the shell's accounts: `calendarConnect`,
          `calendarOtherAccounts`, `calendarEvents`, `calendarReminders`, `calendarTasks`,
          `calendarTroubleshoot`. Set one to your configuration's own way
          (a deploy tool, an update script), or to null to drop it; the others
          keep their default.
        '';
      };

      nixvim = {
        keymaps = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                key = lib.mkOption {
                  type = lib.types.str;
                  description = "The key sequence, as in nixvim (`<leader>ff`, `<C-p>`, `gd`).";
                };
                mode = lib.mkOption {
                  type = with lib.types; either str (listOf str);
                  default = "n";
                  description = "Mode(s), as in nixvim (`\"\"` = normal, visual and operator-pending).";
                };
                action = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "The mapped keys or command (`:bnext<CR>`), or Lua code when `lua`.";
                };
                lua = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Whether `action` is Lua code.";
                };
                desc = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "What it does (else it is described from `action`).";
                };
                scope = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "filetype:markdown";
                  description = ''
                    Where it applies: null (everywhere), `event:<Event>`
                    (`event:LspAttach`: buffers with an LSP server),
                    `filetype:<ft>` or `file:<runtime file>`.
                  '';
                };
              };
            }
          );
          default = nixvimKeymaps;
          defaultText = lib.literalMD ''
            the keymaps of the evaluated `programs.nixvim` configuration when
            nixvim's Home Manager module is imported and enabled (`keymaps`,
            `keymapsOnEvents`, `lsp.keymaps`, `files.<name>.keymaps`), else `[ ]`
          '';
          description = ''
            Neovim keymaps for the config assistant (listed and looked up by key,
            "what does <leader>ff do in vim?") and the AI context. Read from the
            final nixvim configuration, so an override anywhere shows here as
            Neovim gets it. A later keymap for the same key, modes and scope
            replaces an earlier one.
          '';
        };
        leader = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = if nixvimEnabled then nixvim.globals.mapleader or null else null;
          defaultText = lib.literalExpression "config.programs.nixvim.globals.mapleader or null";
          description = "Neovim's `mapleader` (null: its default, backslash).";
        };
        localLeader = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = if nixvimEnabled then nixvim.globals.maplocalleader or null else null;
          defaultText = lib.literalExpression "config.programs.nixvim.globals.maplocalleader or null";
          description = "Neovim's `maplocalleader` (null: its default, backslash).";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        warnings =
          map (
            key:
            "programs.nixbook-shell.settings.${key} was removed (it did nothing) and is ignored: remove it."
          ) (settingsLib.removedKeysSet cfg.settings)
          ++ map (
            key:
            "programs.nixbook-shell.settings.${key} was renamed to ${settingsLib.renamedKeys.${key}}: use that."
          ) (settingsLib.renamedKeysSet cfg.settings)
          ++ lib.optional (cfg.settings.appearance.persona.enable != null) ''
            programs.nixbook-shell.settings.appearance.persona.enable is deprecated: use
            appearance.theme = "${
              if cfg.settings.appearance.persona.enable then "persona" else "material"
            }" (the themes are in nixbook-shell/src/modules/common/themes.json).
          '';

        # Defaults one by one, so setting one answer keeps the others.
        programs.nixbook-shell.assistant.howTo = lib.mapAttrs (_: lib.mkDefault) defaultHowTo;

        xdg.configFile."quickshell/${configName}".source = cfg.package.passthru.shell;

        # Terminal theming (appearance.wallpaperTheming.enableTerminal,
        # scripts/colors/applycolor.sh): kitty reads the generated theme,
        # last so it wins over stylix's colours (`include`: kitty skips it,
        # with a log line, while theming is off and the file is gone; its
        # globinclude takes no absolute path), and reloads it on SIGUSR1;
        # other terminals get the colours as escape sequences, written to the
        # open ones and replayed by each new interactive shell.
        programs.kitty.extraConfig = lib.mkIf config.programs.kitty.enable (
          lib.mkAfter "include ${terminalThemeDir}/kitty-theme.conf"
        );
        programs.zsh.initContent = lib.mkIf config.programs.zsh.enable (
          lib.mkAfter (replayTerminalColors + failedCommandZsh)
        );
        programs.bash.initExtra = lib.mkIf config.programs.bash.enable (
          lib.mkAfter (replayTerminalColors + failedCommandBash)
        );

        # The manifest the shell reads to know which settings Nix owns: every
        # pinned leaf path. Drives the red lock icon and the disabled control in
        # the Settings menu (src/modules/common/NixManaged.qml).
        xdg.configFile."nixbook-shell/nix-managed.json".source = nixManagedFile;
        # ...and their values: NixManaged.qml restores any pinned key that gets
        # changed at runtime (menu, QuickConfig, IPC, scripts); `nixbook-shell config`
        # reads them too.
        xdg.configFile."nixbook-shell/nix-pinned-values.json".source = pinnedFile;
        # Machine context for the AI assistant (see above).
        xdg.configFile."nixbook-shell/system-context.md".source = systemContextFile;
        xdg.configFile."nixbook-shell/system-context-summary.md".source = systemContextSummaryFile;
        xdg.configFile."nixbook-shell/system-facts.json".source = systemFactsFile;
        # Desktop control for AI agents (scripts/desktop-mcp.py).
        xdg.configFile."nixbook-shell/desktop-mcp.json".source =
          (pkgs.formats.json { }).generate "desktop-mcp.json"
            (
              cfg.desktopMcp.settings
              // {
                http.port = cfg.desktopMcp.http.port;
                habits = cfg.desktopMcp.habits.enable;
                # The fixer's availability: report_problem, request_feature,
                # list_requests, improvement ideas, Settings, nixbook-improve.
                improve = cfg.selfImprove.enable;
              }
            );
        # The AI chat's other MCP servers (assistant.mcpServers, services/Ai.qml).
        xdg.configFile."nixbook-shell/assistant-mcp.json".source =
          (pkgs.formats.json { }).generate "assistant-mcp.json"
            { inherit (cfg.assistant) mcpServers; };
        # The ui tools: Firefox-based and Chromium/Electron apps publish their
        # accessibility tree only when asked to (GTK and Qt apps always do).
        systemd.user.sessionVariables =
          lib.mkIf (cfg.desktopMcp.browserAccessibility && lib.elem "ui" cfg.desktopMcp.settings.tools)
            {
              GNOME_ACCESSIBILITY = "1";
              ACCESSIBILITY_ENABLED = "1";
            };

        # Launcher entry for the Settings window (nixbook-shell's own launcher, fuzzel…).
        xdg.desktopEntries.nixbook-shell-settings = {
          name = "Shell settings";
          genericName = "Desktop shell settings";
          comment = "Settings of the nixbook-shell desktop shell (bar, dock, widgets, theme…)";
          exec = "${lib.getExe cfg.package} ipc call settings open";
          icon = "preferences-desktop";
          terminal = false;
          categories = [
            "Settings"
            "DesktopSettings"
          ];
          settings.Keywords = "settings;preferences;shell;nixbook;bar;dock;theme;wallpaper;persona;";
        };

        # Launcher entry for the Tasks window (the to-do list, Google Tasks-like).
        xdg.desktopEntries.nixbook-shell-tasks = {
          name = "Tasks";
          genericName = "To-do list";
          comment = "Your tasks and their deadlines (Google Tasks once an account is connected)";
          exec = "${lib.getExe cfg.package} ipc call tasks open";
          icon = "x-office-calendar";
          terminal = false;
          categories = [
            "Office"
            "ProjectManagement"
          ];
          settings.Keywords = "tasks;todo;to-do;google tasks;deadline;checklist;";
        };

        # Launcher entry for the Notes window (the notes widget's notes).
        xdg.desktopEntries.nixbook-shell-notes = {
          name = "Notes";
          genericName = "Notes";
          comment = "Your desktop notes, searchable, pinned first";
          exec = "${lib.getExe cfg.package} ipc call notes launch";
          icon = "accessories-text-editor";
          terminal = false;
          categories = [
            "Office"
            "Utility"
          ];
          settings.Keywords = "notes;note;memo;sticky;jot;";
        };

        # Launcher entry for the Calendar window (every account's events,
        # through nixbook-accounts).
        xdg.desktopEntries.nixbook-shell-calendar = {
          name = "Calendar";
          genericName = "Calendar";
          comment = "Your calendars: the month, each day's events, new events";
          exec = "${lib.getExe cfg.package} ipc call calendar launch";
          icon = "x-office-calendar";
          terminal = false;
          categories = [
            "Office"
            "Calendar"
          ];
          settings.Keywords = "calendar;events;agenda;meeting;appointment;schedule;google calendar;icloud;";
        };

        # Launcher entry for the Contacts window (Google Contacts, through
        # nixbook-accounts).
        xdg.desktopEntries.nixbook-shell-contacts = {
          name = "Contacts";
          genericName = "Contacts";
          comment = "Your contacts: search, call, write, edit";
          exec = "${lib.getExe cfg.package} ipc call contacts launch";
          icon = "x-office-address-book";
          terminal = false;
          categories = [
            "Office"
            "ContactManagement"
          ];
          settings.Keywords = "contacts;people;address book;phone;email;google contacts;birthday;";
        };

        home.packages = [
          cfg.package
          cfg.package.passthru.quickshell
          # `nixbook-accounts status|add|remove…` from a terminal too.
          cfg.package.passthru.accounts
          # The faces appearance.fonts names (fonts.nix).
          cfg.package.passthru.fonts
          # Condensed display face used by the optional Persona theme
          # (appearance.persona.fonts) for titles and numbers.
          pkgs.oswald
          # Rounded face used by the optional Chiikawa theme
          # (appearance.chiikawa.fonts, themes.json style.fonts).
          pkgs.nunito
          # (Rajdhani, the Cyberpunk 2077 theme's condensed tech face, and
          # Zen Maru Gothic and Klee One, the Studio Ghibli theme's faces, are
          # in fonts.nix: nixpkgs doesn't ship them.)
          # `nixbook-desktop-mcp`: the desktop control MCP server, for any
          # MCP client's configuration, and its pause/resume kill switch.
          cfg.package.passthru.desktopMcp
        ];

        # The shell writes its settings, generated Material You palette and
        # wallpaper state into these; nothing creates them for us on a fresh user.
        #
        # config.json itself stays a real file (the shell rewrites it live from the
        # Settings panel, so it cannot be an xdg.configFile): every key Nix sets is
        # merged into it on each activation (Nix wins), every other key is left
        # alone. Runs after linkGeneration so the running shell, told to reload,
        # sees the new lock manifest too.
        home.activation.nixbookShellDirs = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
          run mkdir -p \
            "''${XDG_CONFIG_HOME:-$HOME/.config}/nixbook-shell" \
            "''${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/user/generated/wallpaper" \
            "''${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/user/generated"

          shell_config="''${XDG_CONFIG_HOME:-$HOME/.config}/nixbook-shell/config.json"

          shell_tmp=$(mktemp -d)
          echo '{}' > "$shell_tmp/empty.json"
          shell_live="$shell_tmp/empty.json"
          shell_ok=1
          if [ -s "$shell_config" ]; then
            if ${lib.getExe pkgs.jq} -e 'type == "object"' "$shell_config" >/dev/null 2>&1; then
              shell_live="$shell_config"
            else
              warnEcho "nixbook-shell: $shell_config is not a valid JSON object, leaving it alone"
              shell_ok=0
            fi
          fi
          if [ "$shell_ok" = 1 ]; then
            if ${lib.getExe pkgs.jq} -n \
                  --slurpfile live "$shell_live" \
                  --slurpfile pinned ${pinnedFile} \
                  '
                    # Settings of the Claude Code era, chosen from the menu:
                    # carried over to their new keys once (the shell itself
                    # no longer knows the old ones, and drops them).
                    def tier: {haiku: "small", sonnet: "main", "": "main", opus: "big", fable: "big"}[.] // .;
                    def metaOnly:
                      if (.ai.claudeCode | type) == "object" then
                        .ai.agent = (.ai.agent // {}) * (.ai.claudeCode
                          | del(.command, .connectors)
                          | if has("model") then .model |= tier else . end
                          | if has("memoryModel") then .memoryModel |= tier else . end)
                        | del(.ai.claudeCode)
                      else . end
                      | if (.ai.claudeThreadIdleMinutes | type) == "number" then
                          .ai.threadIdleMinutes = .ai.claudeThreadIdleMinutes | del(.ai.claudeThreadIdleMinutes)
                        else . end;
                    ($live[0] | metaOnly) * $pinned[0]' > "$shell_tmp/config.json"; then
              # The user's only (their location, shared folders…).
              run install -m600 "$shell_tmp/config.json" "$shell_config"
            else
              warnEcho "nixbook-shell: failed to merge settings into $shell_config"
            fi
          fi
          rm -rf "$shell_tmp"

          # A running shell doesn't notice the swapped symlinks: have it re-read
          # the lock manifest, the pinned values and config.json. No-op when the
          # shell isn't running.
          if [ -z "''${DRY_RUN:-}" ]; then
            XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
              ${lib.getExe cfg.package} ipc call nixManaged reload >/dev/null 2>&1 || true
          fi
        '';

        systemd.user.services.nixbook-shell = {
          Unit = {
            Description = "nixbook-shell Quickshell desktop shell";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = lib.getExe cfg.package;
            Restart = "on-failure";
            RestartSec = 2;
            Slice = "app.slice";
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };

        # Started before the shell (Before=): a small instance that is up well
        # before the shell's QML has loaded. It quits by itself once the shell's
        # BootSplash is on screen (the marker below), or after 20 s.
        systemd.user.services.nixbook-shell-splash = lib.mkIf cfg.splash.enable {
          Unit = {
            Description = "nixbook-shell loading screen (until the shell is up)";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
            Before = [ "nixbook-shell.service" ];
          };
          Service = {
            Type = "simple";
            # Only while the shell isn't up yet (session start), never when a
            # switch (re)starts this unit under a running shell.
            ExecCondition = "${pkgs.bash}/bin/bash -c '! ${pkgs.systemd}/bin/systemctl --user is-active --quiet nixbook-shell.service'";
            # A marker left by the previous shell start in this session.
            ExecStartPre = "${pkgs.coreutils}/bin/rm -f %t/nixbook-shell/boot-splash-shown";
            ExecStart = "${lib.getExe cfg.package} splash";
            Restart = "no";
            Slice = "app.slice";
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };

        # The Electron apps' bridge watcher (electronBridge.apps): an app
        # running without its bridge, restarted through it while it is young
        # and not in a call, otherwise the user asked (notification).
        xdg.configFile."nixbook-shell/electron-bridge.json" = lib.mkIf (cfg.electronBridge.apps != [ ]) {
          text = builtins.toJSON { inherit (cfg.electronBridge) apps; };
        };
        systemd.user.services.nixbook-electron-watch = lib.mkIf (cfg.electronBridge.apps != [ ]) {
          Unit = {
            Description = "nixbook-shell: Electron apps running without their bridge";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
            X-Restart-Triggers = [ (builtins.toJSON cfg.electronBridge.apps) ];
          };
          Service = {
            ExecStart = "${cfg.package.passthru.electronBridge}/bin/nixbook-electron-app watch";
            Restart = "on-failure";
            RestartSec = 5;
            Slice = "app.slice";
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };

        # The desktop control MCP server over HTTP (desktopMcp.http). It binds
        # 127.0.0.1 itself; the unit also keeps it off IPv6 and any socket
        # family but loopback TCP and Unix sockets (niri, Wayland, ydotoold).
        systemd.user.services.nixbook-desktop-mcp = lib.mkIf cfg.desktopMcp.http.enable {
          Unit = {
            Description = "nixbook-shell desktop control MCP server (127.0.0.1 only)";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = "${lib.getExe cfg.package.passthru.desktopMcp} serve --http --port ${toString cfg.desktopMcp.http.port}";
            Restart = "on-failure";
            RestartSec = 2;
            Slice = "app.slice";
            NoNewPrivileges = true;
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
            ];
            UMask = "0077";
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };

        # Usage habits: the recorder reads niri's event stream and writes
        # ~/.local/state/nixbook-shell/habits.* (0600). It needs no network
        # at all. On from Settings > Desktop agents (`habits on`: the flag
        # file, and the unit started), or always with desktopMcp.habits.enable.
        systemd.user.services.nixbook-habits = {
          Unit = {
            Description = "nixbook-shell usage habits (counted locally, no model)";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
            ConditionPathExists = lib.mkIf (
              !cfg.desktopMcp.habits.enable
            ) "${config.xdg.stateHome}/nixbook-shell/habits-enabled";
          };
          Service = {
            ExecStart = "${lib.getExe cfg.package.passthru.desktopMcp} habits watch";
            Restart = "on-failure";
            RestartSec = 5;
            Slice = "background.slice";
            NoNewPrivileges = true;
            # AF_UNIX only already keeps it off the network (IPAddressDeny
            # needs root's BPF firewall: a user unit only logged a warning).
            RestrictAddressFamilies = [ "AF_UNIX" ];
            UMask = "0077";
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };

        # The agents' own desktop (scripts/agent-desktop.sh): started on demand
        # by `nixbook-desktop-mcp desktop agent` and the agents' next action,
        # stopped by `desktop stop` or with the session.
        systemd.user.services.nixbook-agent-desktop = {
          Unit = {
            Description = "A desktop of their own for AI agents (nested niri)";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = lib.getExe cfg.package.passthru.agentDesktop;
            Slice = "app.slice";
            # Usable, but second to the user's own apps.
            CPUWeight = 50;
            IOWeight = 50;
          };
        };
        # The others, one per chat tab of the side panel working at once
        # (nixbook-agent-desktop@2, @3…): the same, each its own desktop.
        systemd.user.services."nixbook-agent-desktop@" = {
          Unit = {
            Description = "A desktop of their own for AI agents, number %i (nested niri)";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = lib.getExe cfg.package.passthru.agentDesktop;
            Environment = [ "NIXBOOK_AGENT_DESKTOP=%i" ];
            Slice = "app.slice";
            # Usable, but second to the user's own apps.
            CPUWeight = 50;
            IOWeight = 50;
          };
        };

        systemd.user.services.cliphist = lib.mkIf cfg.cliphist.enable {
          Unit = {
            Description = "Clipboard history store for nixbook-shell (cliphist)";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = "${cfg.package.passthru.cliphistWatch}";
            Restart = "on-failure";
            RestartSec = 2;
            Slice = "background.slice";
            # The clipboard history (passwords copied, too): kept the user's
            # only, and off the network (it only talks to the compositor).
            NoNewPrivileges = true;
            RestrictAddressFamilies = [ "AF_UNIX" ];
            UMask = "0077";
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };
      }

      # appTheming.qt: qt6ct/qt5ct pointed at the palette the shell renders.
      # The voice's echo-cancelled microphone (voice.echoCancel).
      (lib.mkIf cfg.voice.echoCancel.enable {
        xdg.configFile."pipewire/pipewire.conf.d/60-nixbook-echo-cancel.conf".text = ''
          # nixbook-shell (programs.nixbook-shell.voice.echoCancel): a microphone
          # without the computer's own sound, for the desktop agent's voice.
          # monitor.mode: the echo reference is a capture of the default output's
          # monitor (nothing rerouted). Noise suppression on: without it, bits of
          # the speakers' speech still got through (tested: 3/3 runs heard nothing
          # with it; a voice alone passes whole either way). The capture is
          # passive: it runs only while something records from the source.
          context.modules = [
            { name = libpipewire-module-echo-cancel
              args = {
                library.name = aec/libspa-aec-webrtc
                monitor.mode = true
                aec.args = {
                  webrtc.high_pass_filter = true
                  webrtc.noise_suppression = true
                  webrtc.gain_control = false
                }
                capture.props = {
                  node.name = "nixbook-echo-cancel-capture"
                  node.passive = true
                }
                sink.props = {
                  node.name = "nixbook-echo-cancel-reference"
                }
                source.props = {
                  node.name = "nixbook-echo-cancel-source"
                  node.description = "Microphone without the computer's sound (nixbook voice)"
                }
              }
            }
          ]
        '';
      })
      (lib.mkIf cfg.appTheming.qt.enable {
        qt =
          let
            appearance.Appearance = {
              custom_palette = true;
              color_scheme_path = "${appsDir}/qt-colors.conf";
              style = "Breeze";
            };
          in
          {
            enable = true;
            platformTheme.name = "qtct";
            style.name = "breeze";
            qt5ctSettings = appearance;
            qt6ctSettings = appearance;
          };
      })
    ]
  );
}
