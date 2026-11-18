{ config, lib, pkgs, ... }:
let cfg = config.fleet.remoteDesktop; in {
  options.fleet.remoteDesktop = {
    enable = lib.mkEnableOption "remote desktop over xrdp";
    sessionCommand = lib.mkOption { type = lib.types.str; default = ""; description = "Explicit session command; supplied by desktop composition."; };
    openFirewall = lib.mkOption { type = lib.types.bool; default = false; description = "Open xrdp through host firewall."; };
    certificate = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Runtime certificate path; no certificate contents are read at evaluation."; };
    privateKey = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Runtime key path."; };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = cfg.sessionCommand != ""; message = "fleet.remoteDesktop.sessionCommand is required"; }
      { assertion = (cfg.certificate == null) == (cfg.privateKey == null); message = "fleet.remoteDesktop requires both certificate and privateKey or neither"; }
    ];
    services.xrdp = { enable = true; inherit (cfg) openFirewall; defaultWindowManager = cfg.sessionCommand; }
      // lib.optionalAttrs (cfg.certificate != null) { sslCert = cfg.certificate; sslKey = cfg.privateKey; };
  };
}
