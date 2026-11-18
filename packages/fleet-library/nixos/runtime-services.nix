{ config, lib, utils, ... }:
let
  cfg = config.fleet.runtimeServices;
  serviceType = lib.types.submodule {
    options = {
      enable = lib.mkOption { type = lib.types.bool; default = true; description = "Enable this explicitly declared service instance."; };
      package = lib.mkOption { type = lib.types.package; description = "Independently built producer package."; };
      executable = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Binary name in package/bin; null uses package mainProgram."; };
      arguments = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; description = "Service arguments."; };
      user = lib.mkOption { type = lib.types.str; description = "Existing service account, explicitly supplied by consumer."; };
      environmentFiles = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; description = "Runtime environment paths, typically sops materializations."; };
      after = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ "network.target" ]; description = "Explicit ordering dependencies."; };
    };
  };
in {
  options.fleet.runtimeServices = lib.mkOption { type = lib.types.attrsOf serviceType; default = { }; description = "Generic producer-package adapters, with no harness/provider assumptions."; };
  config = {
    assertions = lib.mapAttrsToList (name: svc: { assertion = !svc.enable || builtins.hasAttr svc.user config.users.users; message = "fleet.runtimeServices.${name}: user must be declared by consumer"; }) cfg;
    systemd.services = lib.mapAttrs' (name: svc: lib.nameValuePair "fleet-${name}" (lib.mkIf svc.enable {
      wantedBy = [ "multi-user.target" ]; inherit (svc) after;
      serviceConfig = { User = svc.user; ExecStart = "${if svc.executable == null then lib.getExe svc.package else lib.getExe' svc.package svc.executable} ${utils.escapeSystemdExecArgs svc.arguments}";
        EnvironmentFile = svc.environmentFiles; Restart = "on-failure"; NoNewPrivileges = true; };
    })) cfg;
  };
}
