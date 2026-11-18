{ config, lib, pkgs, ... }:
let cfg = config.fleet.home; in {
  options.fleet.home = {
    shells = lib.mkEnableOption "Fish and Zsh shells";
    developer = lib.mkEnableOption "development shell tools";
    editor = lib.mkOption { type = lib.types.nullOr lib.types.package; default = null; description = "Consumer-owned editor package."; };
    packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = []; description = "Explicit home packages."; };
    aliases = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; description = "Shared shell aliases."; };
  };
  config = lib.mkMerge [
    { home.packages = cfg.packages ++ lib.optional (cfg.editor != null) cfg.editor; }
    (lib.mkIf cfg.shells {
      programs.fish.enable = true;
      programs.zsh.enable = true;
      programs.fish.shellAliases = cfg.aliases;
      programs.zsh.shellAliases = cfg.aliases;
    })
    (lib.mkIf cfg.developer {
      programs.git.enable = true;
      programs.direnv = { enable = true; nix-direnv.enable = true; };
      home.packages = with pkgs; [ ripgrep fd jq ];
    })
  ];
}
