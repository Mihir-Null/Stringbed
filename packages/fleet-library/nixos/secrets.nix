{ config, lib, ... }:
let cfg = config.fleet.secrets; in {
  options.fleet.secrets = {
    enable = lib.mkEnableOption "sops runtime secret references";
    ageKeyFile = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Runtime age private-key path; never a Nix path containing key bytes."; };
    sshKeyPaths = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; description = "Explicit runtime SSH keys used for decryption."; };
    files = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule {
      options = {
        encryptedFile = lib.mkOption { type = lib.types.path; description = "Encrypted SOPS input file only."; };
        format = lib.mkOption { type = lib.types.enum [ "yaml" "json" "binary" "dotenv" "ini" ]; default = "yaml"; description = "Encrypted document format."; };
        key = lib.mkOption { type = lib.types.str; default = ""; description = "Key inside structured secret, empty selects entire document."; };
        owner = lib.mkOption { type = lib.types.str; default = "root"; description = "Runtime owner."; };
        group = lib.mkOption { type = lib.types.str; default = "root"; description = "Runtime group."; };
        mode = lib.mkOption { type = lib.types.str; default = "0400"; description = "Runtime permission mode."; };
        restartUnits = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; description = "Units restarted when materialization changes."; };
      };
    }); default = { }; description = "Named encrypted-file references."; };
  };
  config = lib.mkIf cfg.enable {
    assertions = [ { assertion = cfg.ageKeyFile != null || cfg.sshKeyPaths != [ ]; message = "fleet.secrets requires an explicit runtime decryption key source"; } ];
    sops.age = { keyFile = cfg.ageKeyFile; sshKeyPaths = cfg.sshKeyPaths; };
    sops.secrets = lib.mapAttrs (_: secret: { sopsFile = secret.encryptedFile; inherit (secret) format key owner group mode restartUnits; }) cfg.files;
  };
}
