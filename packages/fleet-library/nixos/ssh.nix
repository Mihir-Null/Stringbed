{ config, lib, ... }:
let cfg = config.fleet.ssh; in {
  options.fleet.ssh = {
    enable = lib.mkEnableOption "SSH access";
    openFirewall = lib.mkOption { type = lib.types.bool; default = false; description = "Expose SSH through the host firewall."; };
    ports = lib.mkOption { type = lib.types.listOf lib.types.port; default = [ 22 ]; description = "SSH listener ports."; };
    passwordAuthentication = lib.mkOption { type = lib.types.bool; default = false; description = "Allow password authentication explicitly."; };
    permitRootLogin = lib.mkOption { type = lib.types.enum [ "yes" "no" "prohibit-password" "forced-commands-only" ]; default = "no"; description = "Root access policy."; };
    authorizedKeys = lib.mkOption { type = lib.types.attrsOf (lib.types.listOf lib.types.str); default = { }; description = "Public keys keyed by existing account name; no accounts are created."; };
  };
  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (name: _: { assertion = config.users.users.${name}.isNormalUser || config.users.users.${name}.isSystemUser || name == "root"; message = "fleet.ssh: account ${name} must be declared by the consumer"; }) cfg.authorizedKeys;
    services.openssh = { enable = true; inherit (cfg) ports openFirewall; settings = { PasswordAuthentication = cfg.passwordAuthentication; PermitRootLogin = cfg.permitRootLogin; }; };
    users.users = lib.mapAttrs (_: keys: { openssh.authorizedKeys.keys = keys; }) cfg.authorizedKeys;
  };
}
