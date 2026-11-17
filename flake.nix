{
  description = "Stringbed: programmable Nix configuration authoring";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }: let
    systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
    eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    packages = eachSystem (pkgs: {
      default = pkgs.writeShellApplication {
        name = "stringbed";
        runtimeInputs = [ pkgs.racket pkgs.nix pkgs.openssh ];
        text = ''exec racket ${self}/stringbed/main.rkt "$@"'';
      };
    });
    devShells = eachSystem (pkgs: {
      default = pkgs.mkShell { packages = [ pkgs.racket pkgs.nix pkgs.git ]; };
    });
    checks = eachSystem (pkgs: {
      core = pkgs.runCommand "stringbed-core-tests" { nativeBuildInputs = [ pkgs.racket ]; } ''
        export HOME="$TMPDIR"
        cp -r ${self} source
        chmod -R u+w source
        cd source
        raco test tests/core.rkt
        touch "$out"
      '';
    });
  };
}
