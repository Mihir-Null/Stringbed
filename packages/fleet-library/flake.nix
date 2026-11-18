{
  description = "Independent, opt-in NixOS and Home Manager fleet building blocks";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/d5cc6833999746cffdfe0598f7bc801a57b887a9";
    home-manager.url = "github:nix-community/home-manager/5b76c5b8eec25fdbce4f43309b3ee10584374a26";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = inputs@{ self, nixpkgs, home-manager, sops-nix, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      each = nixpkgs.lib.genAttrs systems;
      fixture = system: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ self.nixosModules.default ./fixtures/system.nix ];
      };
      homeFixture = system: home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        modules = [ self.homeManagerModules.developer ./fixtures/home.nix ];
      };
    in {
      nixosModules = {
        default.imports = [ ./nixos/default.nix self.nixosModules.secrets ];
        base = ./nixos/base.nix;
        ssh = ./nixos/ssh.nix;
        containers = ./nixos/containers.nix;
        remote-desktop = ./nixos/remote-desktop.nix;
        exwm = ./nixos/exwm.nix;
        runtime-services = ./nixos/runtime-services.nix;
        secrets.imports = [ sops-nix.nixosModules.sops ./nixos/secrets.nix ];
      };
      homeManagerModules = {
        default = ./home/default.nix;
        developer = ./compositions/developer-home.nix;
        secrets = sops-nix.homeManagerModules.sops;
      };
      checks = each (system:
        let pkgs = nixpkgs.legacyPackages.${system};
            c = (fixture system).config;
            h = (homeFixture system).config;
            extra = ((fixture system).extendModules { modules = [{
              fleet.exwm = { enable = true; user = "fixture"; package = pkgs.emacs; };
              fleet.secrets = { enable = true; ageKeyFile = "/var/lib/sops/age/keys.txt"; };
            }]; }).config;
            disabled = (nixpkgs.lib.nixosSystem { inherit system; modules = [ self.nixosModules.default ]; }).config;
            valid = builtins.all (a: a.assertion) c.assertions;
        in {
          module-contract = assert valid;
            assert c.services.openssh.enable;
            assert !c.services.openssh.openFirewall;
            assert c.virtualisation.podman.enable;
            assert c.systemd.services.fleet-demo.serviceConfig.User == "fixture";
            assert h.programs.fish.enable && h.programs.direnv.enable;
            assert extra.services.xrdp.enable && !extra.services.xrdp.openFirewall;
            assert extra.sops.age.keyFile == "/var/lib/sops/age/keys.txt";
            assert !disabled.fleet.base.enable && !disabled.fleet.ssh.enable && !disabled.fleet.containers.enable && !disabled.fleet.remoteDesktop.enable && !disabled.fleet.secrets.enable;
            assert disabled.fleet.runtimeServices == {};
            pkgs.runCommand "fleet-module-contract" {} ''
              mkdir -p $out
              echo '${builtins.toJSON { inherit system; nixos = true; home = true; }}' > $out/result.json
            '';
        });
      packages = each (system: {
        fixture-system = (fixture system).config.system.build.toplevel;
        fixture-home = (homeFixture system).activationPackage;
      });
    };
}
