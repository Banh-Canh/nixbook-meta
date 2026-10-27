{
  pkgs,
  quickshellSrc,
  # The Google Keep client for the notes' sync with Keep (an npins pin).
  gkeepapiSrc,
  # The VPN CLIs behind the VpnStatus bar widget (services/VpnState.qml probes
  # them with `command -v`, so the widget only shows the ones it finds). Off
  # where they are on the PATH anyway or not used, to keep them out of the
  # closure.
  withTailscale ? true,
  withNetbird ? true,
}:
# The `nixbook-shell` launcher: `nixbook-shell` starts the shell,
# `nixbook-shell ipc call <target> <fn>` drives it, `nixbook-shell splash` shows
# the loading screen until it is up, `nixbook-shell config …` relates the
# live settings to Nix. `passthru` carries the pieces the Home Manager module
# (hm-module.nix) needs. See README.md for the layout of this directory.
let
  inherit (pkgs) lib;

  shell = import ./qml.nix { inherit pkgs; };
  quickshell = import ./quickshell.nix { inherit pkgs quickshellSrc; };
  accounts = import ./accounts.nix { inherit pkgs; };
  # The desktop agent's fixes to nixbook (`nixbook-improve`, services/SelfImprove.qml).
  improve = import ./improve.nix { inherit pkgs modelProvider metaAgent; };
  # The notes' sync with Google Keep (`nixbook-keep`, services/KeepSync.qml).
  keep = import ./keep.nix { inherit pkgs gkeepapiSrc; };
  settingsLib = import ./lib.nix { inherit lib; };
  fonts = import ./fonts.nix { inherit pkgs; };
  inherit (shell.passthru) configName;

  # The update check (scripts/update-check.sh), run by the updates widget
  # through systemd-run: a user unit doesn't get the shell's PATH.
  updateCheck = pkgs.writeShellScriptBin "nixbook-update-check" ''
    export PATH=${
      lib.makeBinPath (
        with pkgs;
        [
          coreutils
          gawk
          gitMinimal
          openssh
          jq
          curl
        ]
      )
    }:$PATH
    exec ${pkgs.bash}/bin/bash ${./scripts/update-check.sh} "$@"
  '';

  # The model provider the shell's AI talks to (scripts/model-provider.sh):
  # every agent the shell, desktop-mcp and nixbook-improve start, and Quick
  # AI, go through `nixbook-model-provider run`, which hands them Meta's
  # Model API (or another server with a Messages API) and its key from the
  # keyring in NIXBOOK_AI_*.
  modelProvider = pkgs.writeShellScriptBin "nixbook-model-provider" ''
    export PATH=${
      lib.makeBinPath (
        with pkgs;
        [
          coreutils
          gnused
          jq
          curl
          libsecret # secret-tool: the API key
        ]
      )
    }:$PATH
    ${builtins.readFile ./scripts/model-provider.sh}
  '';

  # The scripts that call the model, next to the client they share
  # (scripts/nixbook_ai.py: each puts its own directory on sys.path, -I
  # leaves PYTHONPATH out), the client precompiled for its imports.
  aiScripts = pkgs.runCommand "nixbook-ai-scripts" { } ''
    mkdir -p $out
    cp ${./scripts/nixbook_ai.py} $out/nixbook_ai.py
    cp ${./scripts/meta-agent.py} $out/meta-agent.py
    cp ${./scripts/quick-ai.py} $out/quick-ai.py
    cp ${./scripts/nix-onboard.py} $out/nix-onboard.py
    cp ${./scripts/muse-task.py} $out/muse-task.py
    ${pkgs.python3}/bin/python3 -c 'import importlib.util, py_compile, sys; py_compile.compile(sys.argv[1], cfile=importlib.util.cache_from_source(sys.argv[1]), doraise=True, invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)' $out/nixbook_ai.py
  '';

  # The headless agent on Meta's Model API (scripts/meta-agent.py,
  # `nixbook-meta-agent`): a print-mode command line and stream-json
  # events, built-in tools (files, Bash, the web) and MCP servers. Every
  # agent the shell starts runs it (the side panel's Muse, the equalizer
  # agent, desktop-mcp's passes and routines, nixbook-improve); it re-runs
  # itself through nixbook-model-provider for the key.
  metaAgent = pkgs.writeShellScriptBin "nixbook-meta-agent" ''
    export PATH=${
      lib.makeBinPath [
        modelProvider
        pkgs.bubblewrap # the Bash sandbox (--sandbox)
        pkgs.bash
        pkgs.coreutils
      ]
    }:$PATH
    exec ${pkgs.python3}/bin/python3 -I ${aiScripts}/meta-agent.py "$@"
  '';

  # Muse's background tasks (scripts/muse-task.py, `nixbook-muse-task`):
  # the agent run out of the way (a transient systemd user unit, the
  # caller's PATH passed on), its state for the shell, its questions and
  # approvals over a socket and notifications. nixbook-desktop-mcp (the
  # agent's desktop server) comes from the caller's PATH: it calls this one
  # (background_task), so neither can name the other.
  museTask = pkgs.writeShellScriptBin "nixbook-muse-task" ''
    export PATH=${
      lib.makeBinPath [
        metaAgent
        pkgs.libnotify # notify-send: "Muse needs you", "Muse is done"
      ]
    }:$PATH:/run/current-system/sw/bin
    export NIXBOOK_META_AGENT=${metaAgent}/bin/nixbook-meta-agent
    exec ${pkgs.python3}/bin/python3 -I ${aiScripts}/muse-task.py "$@"
  '';

  # Quick AI's answers (scripts/quick-ai.py, services/QuickAi.qml): the
  # provider's Messages API called directly with its small model, run
  # through nixbook-model-provider for the key.
  quickAi = pkgs.writeShellScriptBin "nixbook-quick-ai" ''
    # `do`: handed to nixbook-meta-agent.
    export PATH=$PATH:${metaAgent}/bin
    exec ${pkgs.python3}/bin/python3 -I ${aiScripts}/quick-ai.py "$@"
  '';

  # Quick AI's voice (scripts/voice-transcribe.sh, services/Voice.qml):
  # speech to text on this computer with whisper.cpp (Vulkan: ~0.6 s for 5 s
  # of speech with base on a Radeon 680M, ~1.2 s with small) and its
  # multilingual models, fetched once from the whisper.cpp model repository.
  whisperModels = pkgs.linkFarm "nixbook-whisper-models" [
    {
      name = "ggml-small.bin";
      path = pkgs.fetchurl {
        url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin";
        hash = "sha256-G+OpsgY4Z7k35k4ux0gzZKeZF+FX+pjF2UtcH//qmHs=";
      };
    }
    {
      name = "ggml-base.bin";
      path = pkgs.fetchurl {
        url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin";
        hash = "sha256-YO1bw90U7qhWST0zQ0m0BXgt3K8AKNS130CINF+6Lv4=";
      };
    }
    # Silero VAD (~0.9 MB): only the parts that are speech go to whisper,
    # which otherwise makes words up from a room's noise ("That's Jason
    # Bourne.").
    {
      name = "ggml-silero-vad.bin";
      path = pkgs.fetchurl {
        url = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin";
        hash = "sha256-KZQNmNQrkfvQXOSJ8+z3xy8KQvAn5IdZGaKPtMBOos8=";
      };
    }
  ];
  # Quick AI's voice through Meta (scripts/voice-stream.py): the microphone
  # streamed to Muse Voice Transcribe (ai.voice.engine meta/auto), run
  # through nixbook-model-provider for the key.
  voiceStream = pkgs.writeShellScriptBin "nixbook-voice-stream" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.ffmpeg
        pkgs.util-linux
        pkgs.pulseaudio # pactl: the echo-cancelled microphone, when there is one
      ]
    }:$PATH
    exec ${pkgs.python3}/bin/python3 -I ${./scripts/voice-stream.py} "$@"
  '';

  # The desktop agent's voice (scripts/voice-speak.py, ai.voice.speak):
  # Meta's MMS-TTS (facebook/mms-tts, English and French) in sherpa-onnx's
  # ONNX conversion, on this computer (Meta's Model API has no speech
  # synthesis), made cute with ffmpeg + Rubber Band. The MMS weights are
  # CC-BY-NC 4.0: personal use.
  mmsVoices = pkgs.linkFarm "nixbook-mms-voices" [
    {
      name = "en";
      path = pkgs.fetchzip {
        url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-mms-eng.tar.bz2";
        hash = "sha256-8qoNvG9mkbqSn768fOVCfho7f/E9DqAVQ9hfURkAvxk=";
      };
    }
    {
      name = "fr";
      path = pkgs.fetchzip {
        url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-mms-fra.tar.bz2";
        hash = "sha256-+ASA8wP2orIZAl5HNrQ3YtNJZ98QYFk9qDWBKpHAf64=";
      };
    }
  ];
  voiceSpeak = pkgs.writeShellScriptBin "nixbook-voice-speak" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.sherpa-onnx
        pkgs.rubberband
        pkgs.ffmpeg
        pkgs.pipewire # pw-play
      ]
    }:$PATH
    # Its own libraries only (a leaked LD_LIBRARY_PATH broke ffmpeg's).
    unset LD_LIBRARY_PATH
    export NIXBOOK_MMS_VOICES=''${NIXBOOK_MMS_VOICES:-${mmsVoices}}
    exec ${pkgs.python3}/bin/python3 -I ${./scripts/voice-speak.py} "$@"
  '';

  # The desktop agents in Zen (nixbook-desktop-mcp's browser_* tools): the
  # extension (zen/, unsigned: Zen doesn't require signing, the profile
  # turns the check off) force-installed by the browser's policies, and its
  # native messaging host, a bridge to a private Unix socket
  # ($XDG_RUNTIME_DIR/nixbook-zen/bridge.sock). nixbook's zenBrowserConfig
  # installs both (`passthru.zenAgent`).
  zenExtensionId = "desktop-agent@nixbook-shell";
  zenExtension = pkgs.runCommand "nixbook-zen-extension.xpi" { nativeBuildInputs = [ pkgs.zip ]; } ''
    cp ${./zen}/manifest.json ${./zen}/background.js .
    zip -q -X -9 $out manifest.json background.js
  '';
  zenBridge = pkgs.writeShellScriptBin "nixbook-zen-bridge" ''
    exec ${pkgs.python3}/bin/python3 -I ${./scripts/zen-bridge.py} "$@"
  '';
  zenBridgeHost = pkgs.runCommand "nixbook-zen-bridge-host" { } ''
    mkdir -p $out/lib/mozilla/native-messaging-hosts
    cat > $out/lib/mozilla/native-messaging-hosts/nixbook_zen.json <<EOF
    {
      "name": "nixbook_zen",
      "description": "nixbook's desktop agents in the browser (nixbook-desktop-mcp)",
      "path": "${zenBridge}/bin/nixbook-zen-bridge",
      "type": "stdio",
      "allowed_extensions": ["${zenExtensionId}"]
    }
    EOF
  '';

  voiceTranscribe = pkgs.writeShellScriptBin "nixbook-voice-transcribe" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.whisper-cpp-vulkan
        pkgs.coreutils
        pkgs.gnused
      ]
    }:$PATH
    export NIXBOOK_WHISPER_MODELS=''${NIXBOOK_WHISPER_MODELS:-${whisperModels}}
    ${builtins.readFile ./scripts/voice-transcribe.sh}
  '';

  # Setting up the desktop by talking (scripts/nix-onboard.py,
  # services/NixOnboarding.qml): the model's configuration is checked with
  # Nix itself, the shell's settings against their typed options (lib.nix +
  # its JSON inputs, nixpkgs' lib copied alone: not the whole source).
  nixOnboardInputs = pkgs.runCommand "nixbook-nix-onboard-inputs" { } ''
    mkdir -p $out/settings/src/modules/common
    cp ${./lib.nix} $out/settings/lib.nix
    cp ${./builtin-defaults.json} $out/settings/builtin-defaults.json
    cp ${./src/modules/common/themes.json} $out/settings/src/modules/common/themes.json
    cp -r ${pkgs.path + "/lib"} $out/nixpkgs-lib
  '';
  nixOnboard = pkgs.writeShellScriptBin "nixbook-nix-onboard" ''
    export NIXBOOK_SETTINGS_LIB=${nixOnboardInputs}/settings
    export NIXBOOK_NIXPKGS_LIB=${nixOnboardInputs}/nixpkgs-lib
    # nix-instantiate: the system's (the shell's PATH may not carry it).
    export PATH=$PATH:/run/current-system/sw/bin
    exec ${pkgs.python3}/bin/python3 -I ${aiScripts}/nix-onboard.py "$@"
  '';

  # Desktop control for AI agents (scripts/desktop-mcp.py): an MCP server
  # (`nixbook-desktop-mcp`, also `nixbook-shell mcp`) and the command line
  # the shell's AI chat calls, with the tools it drives on its PATH.
  desktopMcp = pkgs.writeShellScriptBin "nixbook-desktop-mcp" ''
    export PATH="${
      lib.makeBinPath (
        with pkgs;
        [
          niri
          grim
          wtype
          ydotool
          wl-clipboard
          libnotify
          imagemagick # scales window captures down
          tesseract # read_screen
          systemd # systemctl: starts the agent desktop (agentDesktop)
          pciutils # lspci: GPU names (system_info)
          playerctl # the music every player plays (usage habits: music taste)
          accounts # nixbook-accounts: the contacts tool
          improve # nixbook-improve: report_problem
          modelProvider # nixbook-model-provider: the provider's key for the passes
          metaAgent # nixbook-meta-agent: the memory/news passes and routine runs
          museTask # nixbook-muse-task: background_task, tasks
          libarchive # bsdtar: `extract`, a download extracted from its bubble
          procps # pgrep: a watched process
        ]
      )
    }:$PATH"
    export NIXBOOK_DESKTOP_MCP_QS="${quickshell}/bin/qs"
    export NIXBOOK_DESKTOP_MCP_QS_CONFIG="${configName}"
    # The ui tools read apps' accessibility trees through at-spi2-core's
    # GObject bindings.
    export GI_TYPELIB_PATH="${
      lib.makeSearchPath "lib/girepository-1.0" (
        map (p: p.out) [
          pkgs.at-spi2-core
          pkgs.glib
          pkgs.gobject-introspection
        ]
      )
    }''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
    # -P: not the script's directory on sys.path. That is /nix/store, which
    # the first import would list whole (tens of thousands of entries:
    # ~70 ms of each run, the shell's commands and every MCP server start).
    exec ${desktopMcpPython}/bin/python3 -P ${desktopMcpPyc}/desktop-mcp.pyc "$@"
  '';
  desktopMcpPython = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
  # Precompiled: the shell runs it on every habit cue, memory lookup and agent
  # tool call, and a script run as __main__ is never cached (compiling its
  # 12k lines was ~160 ms of CPU per run). Tracebacks still show the source.
  # The model client it imports (scripts/nixbook_ai.py, its passes calling
  # the API in-process) next to it, precompiled too: the script's directory
  # is what it puts on sys.path.
  desktopMcpPyc = pkgs.runCommand "desktop-mcp-pyc" { } ''
    mkdir -p $out
    cp ${./scripts/nixbook_ai.py} $out/nixbook_ai.py
    ${desktopMcpPython}/bin/python3 -c 'import importlib.util, py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], dfile=sys.argv[1], doraise=True, invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH); py_compile.compile(sys.argv[3], cfile=importlib.util.cache_from_source(sys.argv[3]), doraise=True, invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)' ${./scripts/desktop-mcp.py} $out/desktop-mcp.pyc $out/nixbook_ai.py
  '';

  # A desktop of their own for AI agents (scripts/agent-desktop.sh): a nested
  # niri that `nixbook-desktop-mcp desktop agent` points the agents' tools
  # at, run by the `nixbook-agent-desktop` user service.
  # Its niri (niri-winit-agent-window.patch) drops the input of its window
  # (NIRI_WINIT_IGNORE_INPUT): the user can move, resize and close the window
  # but not click or type into it; and names it (NIRI_WINIT_TITLE,
  # NIRI_WINIT_APP_ID) like an app; and keeps the windows its rules open
  # fullscreen so, whatever the app asks (NIRI_KEEP_FULLSCREEN). The agent's
  # only: the user's niri stays the cached nixpkgs one, this one builds
  # locally (tests off).
  agentNiri = pkgs.niri.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./niri-winit-agent-window.patch ];
    doCheck = false;
  });
  # A restricted socket on the user's compositor (security-context-v1) for the
  # agent desktop's niri: no screen capture, input or window list of the
  # user's desktop through it (scripts/wayland-security-context.py).
  securityContext = pkgs.writeShellScriptBin "nixbook-wayland-security-context" ''
    exec ${pkgs.python3}/bin/python3 -P ${./scripts/wayland-security-context.py} "$@"
  '';
  agentDesktop = pkgs.writeShellScriptBin "nixbook-agent-desktop" ''
    export PATH="${
      lib.makeBinPath (
        with pkgs;
        [
          agentNiri
          dbus # dbus-run-session: the agent apps' own session bus
          xwayland-satellite # X11 apps on the agent desktop, not the user's
          bubblewrap # the sandbox: none of the user's files, sockets or processes
          passt # pasta: the sandbox's own network (ai.agentDesktop.privateNetwork)
          securityContext # its restricted connection to the user's desktop
          libnotify # notify-send: why it didn't start
          jq # the folders the user lets agents read (shell config)
          findutils
          coreutils
        ]
      )
    }:$PATH"
    exec ${pkgs.bash}/bin/bash ${./scripts/agent-desktop.sh} "$@"
  '';

  # Upstream probes ~40 tools with `command -v` and shells out to them from QML
  # `Process` blocks. Rather than patching every call site we inject them into
  # the shell's PATH; children inherit it.
  runtimeDeps =
    (with pkgs; [
      bash
      coreutils
      findutils
      gawk
      gnugrep
      gnused
      procps # pgrep
      psmisc # killall
      sysvtools # pidof

      jq
      curl
      wget
      libnotify # notify-send
      glib # gsettings
      xdg-utils # xdg-open
      util-linux

      imagemagick # magick / convert / identify
      matugen
      ffmpeg # ffplay: sounds pw-play can't decode
      pipewire # pw-play: sounds
      mpvpaper

      wl-clipboard
      cliphist
      grim
      slurp
      wf-recorder
      ydotool
      wtype # desktop-mcp keyboard input (virtual keyboard, no uinput)
      tesseract # region OCR

      playerctl
      pulseaudio # pactl
      wireplumber # wpctl
      brightnessctl
      cava
      ddcutil
      networkmanager # nmcli
      translate-shell # trans
      kdePackages.kdialog

      songrec # Shazam CLI behind scripts/musicRecognition + its quick toggle
      easyeffects # EasyEffects quick toggle and the shell's EQ panel
      lm_sensors # `sensors` — temperatures in ResourceUsage
      file # MIME sniffing for chat attachments and directory icons
      zip # settings preset export/import (scripts/presets.sh)

      niri
      btop # task manager (Config.options.apps.taskManager)
    ])
    ++ lib.optional withTailscale pkgs.tailscale # VpnStatus bar widget — `tailscale status/switch/set`
    ++ lib.optional withNetbird pkgs.netbird # VpnStatus bar widget — `netbird status/up/down/profile`
    ++ [
      quickshell # `qs` — the shell re-invokes itself for sub-windows
      accounts # `nixbook-accounts` — the accounts, contacts and tasks (services/Accounts.qml)
      keep # `nixbook-keep` — the notes' sync with Google Keep (services/KeepSync.qml)
      shell.passthru.pythonEnv
      modelProvider # `nixbook-model-provider` — the model provider the shell's AI talks to
      metaAgent # `nixbook-meta-agent` — the side panel's Muse and every other agent (Meta's Model API)
      museTask # `nixbook-muse-task` — Muse's background tasks (services: the Tasks list)
      quickAi # `nixbook-quick-ai` — Quick AI's instant answers (services/QuickAi.qml)
      nixOnboard # `nixbook-nix-onboard` — setting up the desktop by talking (services/NixOnboarding.qml)
      voiceTranscribe # `nixbook-voice-transcribe` — Quick AI's voice, whisper.cpp (services/Voice.qml)
      voiceStream # `nixbook-voice-stream` — Quick AI's voice through Meta's Muse Voice Transcribe
      voiceSpeak # `nixbook-voice-speak` — the agent's answers read out loud (Meta MMS, cute)
      desktopMcp # `nixbook-desktop-mcp` — desktop tools of the AI chat
      updateCheck # `nixbook-update-check` — the update check (services/UpdateState.qml)
      improve # `nixbook-improve` — the desktop agent's fixes to nixbook (services/SelfImprove.qml)
    ];

  # QML modules the shell imports that quickshell itself is not built against,
  # so they are absent from its wrapper's QML import path. Without these the
  # shell dies at startup with "module <x> is not installed":
  #   Qt5Compat.GraphicalEffects -> qt5compat          (ReloadPopup and friends)
  #   QtPositioning              -> qtpositioning      (weather / auto-location)
  #   org.kde.syntaxhighlighting -> syntax-highlighting (AI chat code blocks)
  #   org.kde.kirigami           -> kirigami           (common/widgets/AppIcon)
  # Everything else it imports (QtQuick.*, QtQml.*, Qt.labs.*, QtCore) already
  # comes from qtdeclarative via quickshell.
  #
  # nixpkgs' Qt6 uses a patched qtbase that reads NIXPKGS_QT6_QML_IMPORT_PATH,
  # and quickshell's wrapper extends it with `--prefix`, so exporting it here
  # is additive rather than destructive.
  qmlImportPath = lib.makeSearchPath "lib/qt-6/qml" [
    pkgs.qt6.qt5compat
    pkgs.qt6.qtpositioning
    pkgs.kdePackages.syntax-highlighting
    # `kdePackages.kirigami` is a Qt app wrapper with no lib/ output; the QML
    # module only exists in the unwrapped derivation.
    pkgs.kdePackages.kirigami.unwrapped
  ];

  # `nixbook-shell config …` (scripts/config-tool.sh). Reads the settings set in Nix
  # from ~/.config/nixbook-shell/nix-pinned-values.json at run time, so the
  # CLI doesn't depend on the module's configuration.
  # jq resolves `include "config-merge"` by file name in the -L directory.
  mergeLib = pkgs.writeTextDir "lib/config-merge.jq" (builtins.readFile ./scripts/config-merge.jq);
  configTool = pkgs.writeShellScript "nixbook-shell-config" ''
    export PATH="${
      lib.makeBinPath [
        pkgs.jq
        pkgs.coreutils
      ]
    }:$PATH"
    export NIXBOOK_SHELL_MERGE_JQ="${mergeLib}/lib/config-merge.jq"
    export NIXBOOK_SHELL_BUILTIN="${./builtin-defaults.json}"
    export NIXBOOK_SHELL_LIVE_KEYS="${pkgs.writeText "nixbook-shell-live-keys.json" (builtins.toJSON settingsLib.skippedKeys)}"
    # `config builtin`: run the shell's Config singleton alone against an empty
    # config dir to get its built-in defaults.
    export NIXBOOK_SHELL_SHELL="${shell}"
    export NIXBOOK_SHELL_QS="${quickshell}/bin/qs"
    export NIXBOOK_SHELL_QML_PATH="${qmlImportPath}"
    exec ${pkgs.bash}/bin/bash ${./scripts/config-tool.sh} "$@"
  '';

  # cliphist store daemon. Nothing else in this config runs one, so without it
  # the shell's clipboard history (Mod+Q) is permanently empty. If either
  # watcher dies, exit non-zero so the unit's Restart=on-failure brings both
  # back (systemd kills the surviving one with the rest of the cgroup).
  cliphistWatch = pkgs.writeShellScript "nixbook-shell-cliphist-watch" ''
    ${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store &
    ${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.cliphist}/bin/cliphist store &
    wait -n
    exit 1
  '';

  # Single entry point: keybinds and the systemd unit both go through this so
  # the runtime PATH and QML import path are always correct.
  launcher = pkgs.writeShellScriptBin "nixbook-shell" ''
    # `nixbook-shell config …`: how the live settings relate to the Nix module.
    if [ "''${1:-}" = "config" ]; then
      shift
      exec ${configTool} "$@"
    fi
    # `nixbook-shell mcp …`: the desktop control MCP server (desktopMcp).
    if [ "''${1:-}" = "mcp" ]; then
      shift
      exec ${lib.getExe desktopMcp} "$@"
    fi
    export PATH="${lib.makeBinPath runtimeDeps}:$PATH"
    export NIXPKGS_QT6_QML_IMPORT_PATH="${qmlImportPath}''${NIXPKGS_QT6_QML_IMPORT_PATH:+:$NIXPKGS_QT6_QML_IMPORT_PATH}"
    # Quickshell resolves `image://icon/...` against this rather than the GTK
    # settings; without it half the tray/launcher icons fail to load. Override
    # it in the environment for another theme. Set here rather than in home.sessionVariables
    # so it also applies to the systemd unit without needing a re-login.
    export QS_ICON_THEME="''${QS_ICON_THEME:-Papirus-Dark}"
    # Sounds (Audio.playSystemSound: the timers' ringtones, battery) are
    # looked up in XDG_DATA_DIRS; NixOS has no /usr/share/sounds, so the
    # freedesktop theme is always there as the fallback.
    export XDG_DATA_DIRS="''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:${pkgs.sound-theme-freedesktop}/share"
    # `nixbook-shell splash`: the loading screen shown while the shell starts
    # (src/earlySplash.qml, its own instance: quits once the shell's is up).
    if [ "''${1:-}" = "splash" ]; then
      shift
      exec ${quickshell}/bin/qs -p ${shell}/earlySplash.qml "$@"
    fi
    # `nixbook-shell greeter`: the login screen (src/greeter.qml), run by
    # greetd through the nixbook-shell.greeter NixOS module.
    if [ "''${1:-}" = "greeter" ]; then
      shift
      exec ${quickshell}/bin/qs -p ${shell}/greeter.qml "$@"
    fi
    # The directories services/DesktopControl.qml and SelfImprove.qml watch: a file watch needs
    # its directory to exist when the shell starts (desktop-mcp.py creates
    # them the same way, 0700, on first use).
    if [ "''${1:-}" != "ipc" ]; then
      for dir in "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/nixbook-desktop-mcp" \
        "''${XDG_STATE_HOME:-$HOME/.local/state}/nixbook-shell" \
        "''${XDG_STATE_HOME:-$HOME/.local/state}/nixbook-shell/improve"; do
        [ -d "$dir" ] || mkdir -p -m 700 "$dir"
      done
    fi
    exec ${quickshell}/bin/qs -c ${configName} "$@"
  '';
in
launcher.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit
      shell
      quickshell
      accounts
      improve
      modelProvider
      metaAgent
      museTask
      quickAi
      voiceTranscribe
      voiceStream
      voiceSpeak
      nixOnboard
      configName
      settingsLib
      cliphistWatch
      desktopMcp
      agentDesktop
      securityContext
      fonts
      keep
      ;
    zenAgent = {
      extension = zenExtension;
      extensionId = zenExtensionId;
      host = zenBridgeHost;
      bridge = zenBridge;
    };
  };
  meta = shell.meta // {
    mainProgram = "nixbook-shell";
  };
})
