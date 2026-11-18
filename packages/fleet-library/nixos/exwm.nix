{ config, lib, pkgs, ... }:
let
  cfg = config.fleet.exwm;
  session = pkgs.writeShellApplication {
    name = "fleet-exwm-session";
    runtimeInputs = [ cfg.package ];
    text = ''
      if [ "$USER" != ${lib.escapeShellArg cfg.user} ]; then
        echo "This desktop session belongs to a different account" >&2
        exit 1
      fi
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") cfg.environment)}
      exec ${lib.getExe cfg.package} ${lib.escapeShellArgs cfg.arguments}
    '';
  };
in {
  imports = [ ./remote-desktop.nix ];
  options.fleet.exwm = {
    enable = lib.mkEnableOption "an explicit EXWM desktop session";
    user = lib.mkOption { type = lib.types.str; default = ""; description = "Account owning the editor configuration."; };
    package = lib.mkOption { type = lib.types.package; default = pkgs.emacs; description = "Emacs package with an EXWM-capable user configuration."; };
    arguments = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; description = "Arguments selecting the consumer's Emacs initialization."; };
    environment = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; description = "Explicit environment exported to the session."; };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = cfg.user != "" && builtins.hasAttr cfg.user config.users.users; message = "fleet.exwm.user must identify a declared account"; }
      { assertion = lib.all (name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null) (builtins.attrNames cfg.environment); message = "fleet.exwm.environment contains an invalid variable name"; }
    ];
    fleet.remoteDesktop = { enable = true; sessionCommand = lib.mkDefault (lib.getExe session); };
    environment.systemPackages = [ session ];
  };
}
