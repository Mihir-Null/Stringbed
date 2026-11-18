{
  description = "Stringbed: programmable Nix configuration authoring";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }: let
    systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
    eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    emacsFor = pkgs: pkgs.emacsPackagesFor pkgs.emacs-nox;
    packageFor = pkgs: (emacsFor pkgs).trivialBuild {
      pname = "stringbed";
      version = "0.3.0";
      src = ./emacs;
      packageRequires = with (emacsFor pkgs); [ magit-section transient ];
    };
    terminalFor = pkgs: (emacsFor pkgs).emacsWithPackages (_: [ (packageFor pkgs) ]);
    launcherFor = pkgs: pkgs.writeShellApplication {
      name = "stringbed-emacs";
      runtimeInputs = [ (terminalFor pkgs) pkgs.racket pkgs.nix pkgs.openssh ];
      text = ''
        export STRINGBED_EMACS=${terminalFor pkgs}/bin/emacs
        export STRINGBED_RACKET=${pkgs.racket}/bin/racket
        exec ${pkgs.bash}/bin/bash ${self}/scripts/stringbed-emacs "$@"
      '';
    };
  in {
    packages = eachSystem (pkgs: {
      default = pkgs.writeShellApplication {
        name = "stringbed";
        runtimeInputs = [ pkgs.racket pkgs.nix pkgs.openssh (launcherFor pkgs) ];
        text = ''
          export PLTCOLLECTS="${self}:''${PLTCOLLECTS:-}"
          export STRINGBED_EMACS_LAUNCHER=${launcherFor pkgs}/bin/stringbed-emacs
          exec racket ${self}/stringbed/main.rkt "$@"
        '';
      };
      emacs-package = packageFor pkgs;
      emacs = launcherFor pkgs;
    });
    apps = eachSystem (pkgs: {
      default = { type = "app"; program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/stringbed"; };
      emacs = { type = "app"; program = "${launcherFor pkgs}/bin/stringbed-emacs"; };
    });
    devShells = eachSystem (pkgs: {
      default = pkgs.mkShell {
        packages = [ pkgs.racket pkgs.nix pkgs.git pkgs.openssh (terminalFor pkgs) (launcherFor pkgs) ];
        shellHook = ''export PLTCOLLECTS="$PWD:''${PLTCOLLECTS:-}"'';
      };
    });
    checks = eachSystem (pkgs: {
      core = pkgs.runCommand "stringbed-core-tests" { nativeBuildInputs = [ pkgs.racket ]; } ''
        export HOME="$TMPDIR"
        cp -r ${self} source
        chmod -R u+w source
        cd source
        for suite in core durability nix-query query-context protocol lifecycle ui-extension tui workbench; do
          raco test "tests/$suite.rkt"
        done
        touch "$out"
      '';
      emacs = pkgs.runCommand "stringbed-emacs-tests" {
        nativeBuildInputs = [ (terminalFor pkgs) pkgs.racket ];
      } ''
        export HOME="$TMPDIR"
        cp -r ${self} source
        chmod -R u+w source
        cd source
        emacs --batch -Q -L emacs -l tests/emacs-test.el -f ert-run-tests-batch-and-exit
        touch "$out"
      '';
    });
  };
}
