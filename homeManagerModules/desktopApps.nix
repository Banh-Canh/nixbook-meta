{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.customHomeManagerModules;
  # Readable and usable by the desktop agents where nixbook-shell runs
  # (lib/electronA11y.nix: its accessibility tree, and its pages through
  # nixbook-electron-app when nixbookShellConfig.electronBridge lists it).
  a11y = import ../lib/electronA11y.nix { inherit pkgs config; };
in
{
  options.customHomeManagerModules.desktopApps = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable a curated set of GUI desktop applications.

        Installs and configures:
          Documents / media viewers:
            - zathura   — lightweight keyboard-driven PDF viewer
            - imv       — minimal Wayland image viewer (set as default for images)

          Communication & entertainment:
            - vesktop    — custom Discord client (Vencord-patched)
            - spotify    — music streaming client

          Creation & recording:
            - obs-studio — screen/audio recording and streaming
            - pinta      — simple Paint-like image editor

          Display management:
            - wdisplays  — Wayland display arrangement GUI (arandr equivalent)

          Browser:
            - firefox    — set as default for http/https/text/html MIME types

          File management (dolphinConfig.nix, active when this is enabled):
            - dolphin + dolphin-plugins, ark, kio-admin, ffmpegthumbs,
              kpeople, kservice, ntfs3g, gparted

          Media playback (mpvConfig.nix, active when this is enabled):
            - mpv with thumbfast, mpris, and modernx scripts
            - yt-dlp (YouTube/media downloader)
            - ytui (YouTube TUI), jtui (JSON viewer TUI)
      '';
    };
  };
  config = lib.mkMerge [
    # The bridged Electron apps installed (lib/electronA11y.nix, here or in
    # a profile), watched by nixbook-shell's nixbook-electron-watch: one
    # running without its bridge is restarted through it or you are asked.
    (lib.mkIf cfg.nixbookShellConfig.enable {
      programs.nixbook-shell.electronBridge.apps = map (p: p.nixbookElectronBridge) (
        lib.filter (p: p ? nixbookElectronBridge) config.home.packages
      );
    })
    (lib.mkIf cfg.desktopApps.enable {
      programs = {
        zathura.enable = true;
        imv.enable = true;
      };
      home.packages =
        with pkgs;
        [
          # apps
          darktable
          ansel
          spotify
          obs-studio
          wdisplays # display manager
          (a11y vesktop "vesktop") # discord
          pinta # paint
          wifi-qr
        ]
        ++ lib.optionals (!cfg.zenBrowserConfig.enable) [
          firefox
        ];
    })
  ];
}
