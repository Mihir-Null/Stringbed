{ config, lib, pkgs, ... }:
let cfg = config.fleet.base; in {
  options.fleet.base = {
    enable = lib.mkEnableOption "portable NixOS baseline";
    packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; description = "Explicit additional baseline packages."; };
    collectGarbage = lib.mkOption { type = lib.types.bool; default = false; description = "Enable periodic garbage collection."; };
    retention = lib.mkOption { type = lib.types.str; default = "30d"; description = "Generation retention when collection is enabled."; };
  };
  config = lib.mkIf cfg.enable {
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    environment.systemPackages = cfg.packages;
    nix.gc = lib.mkIf cfg.collectGarbage { automatic = true; dates = "weekly"; options = "--delete-older-than ${cfg.retention}"; };
  };
}
