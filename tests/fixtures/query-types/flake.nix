{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { nixpkgs, ... }: let
    inherit (nixpkgs) lib;
    target = lib.evalModules {
      modules = [{
        options.probe = {
          boolean = lib.mkOption { type = lib.types.bool; default = false; description = "Boolean control"; };
          choice = lib.mkOption { type = lib.types.enum [ "one" "two" ]; default = "one"; };
          integer = lib.mkOption { type = lib.types.int; default = 0; };
          number = lib.mkOption { type = lib.types.number; default = 0.5; };
          nullable = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          list = lib.mkOption { type = lib.types.listOf lib.types.int; default = []; };
          structured = lib.mkOption { type = lib.types.attrsOf lib.types.bool; default = {}; };
          unavailable = lib.mkOption { type = lib.types.str; default = throw "unavailable fixture default"; };
        };
      }];
    };
  in { homeConfigurations.fixture = target; };
}
