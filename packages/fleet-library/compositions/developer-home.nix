{ lib, ... }: {
  imports = [ ../home/default.nix ];
  fleet.home.shells = lib.mkDefault true;
  fleet.home.developer = lib.mkDefault true;
}
