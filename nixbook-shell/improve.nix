{
  pkgs,
  modelProvider,
  # nixbook-meta-agent (scripts/meta-agent.py): the session's engine.
  metaAgent ? null,
}:
# nixbook-improve (improve/): the desktop agent's fixes to nixbook, fixes and
# polish only (services/SelfImprove.qml, Settings > Desktop agents). Its
# inbox, the confined nixbook-meta-agent session (Meta's Muse), the checks
# (tests/shell-loads.sh: the shell on a headless sway), the PR, CI and the
# user's answer.
pkgs.buildGoModule {
  pname = "nixbook-improve";
  version = "0.1.0";
  src = ./improve;
  vendorHash = null;
  env.CGO_ENABLED = 0;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postInstall = ''
    mv $out/bin/improve $out/bin/nixbook-improve
    # nix and devenv are the user's, from their PATH; these come after it
    # (the user's own gh and git first).
    wrapProgram $out/bin/nixbook-improve --suffix PATH : ${
      pkgs.lib.makeBinPath (
        with pkgs;
        [
          gitMinimal
          openssh
          gh # the PRs, with its own token only
          libsecret # secret-tool: the token in the keyring
          modelProvider # nixbook-model-provider run: the provider the agent talks to
          libnotify # notify-send: Merge, Look, Drop
          xdg-utils # xdg-open: Look
          systemd # journalctl, systemctl: the shell's log
          sway # tests/shell-loads.sh: the shell started headless
          grim
          util-linux # setsid
          bash
          coreutils
          findutils
          gnused
        ]
        ++ pkgs.lib.optional (metaAgent != null) metaAgent # nixbook-meta-agent: the fixing session
      )
    }
  '';
  meta.mainProgram = "nixbook-improve";
}
