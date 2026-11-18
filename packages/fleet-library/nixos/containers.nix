{ config, lib, pkgs, ... }:
let cfg = config.fleet.containers; in {
  options.fleet.containers = {
    enable = lib.mkEnableOption "Podman containers";
    cockpit = lib.mkOption { type = lib.types.bool; default = false; description = "Enable Cockpit and its Podman plugin."; };
    autoPrune = lib.mkOption { type = lib.types.bool; default = false; description = "Prune unused containers/images weekly."; };
  };
  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.backend = "podman";
    virtualisation.podman = { enable = true; autoPrune = { enable = cfg.autoPrune; dates = "weekly"; }; };
    services.cockpit = lib.mkIf cfg.cockpit { enable = true; openFirewall = false; plugins = [ pkgs.cockpit-podman ]; };
  };
}
