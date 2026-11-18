{ pkgs, ... }: {
  boot.isContainer = true;
  system.stateVersion = "25.05";
  networking.hostName = "fleet-fixture";
  users.users.fixture = { isNormalUser = true; group = "fixture"; };
  users.groups.fixture = {};
  fleet.base.enable = true;
  fleet.ssh.enable = true;
  fleet.containers.enable = true;
  fleet.runtimeServices.demo = {
    package = pkgs.hello;
    user = "fixture";
    arguments = [ "--greeting=fixture" ];
  };
}
