#lang racket/base
(require rackunit racket/file racket/system racket/runtime-path racket/port
         "../stringbed/model.rkt" "../stringbed/compiler.rkt" "../stringbed/session.rkt")
(define-runtime-path home "../examples/home.sbd")
(define-runtime-path server "../examples/server.sbd")
(define-runtime-path extension "../examples/extensions/web-service.rkt")
(define nix (find-executable-path "nix-instantiate"))
(unless nix (error 'test "nix-instantiate required; do not silently skip integration"))
(define dir (make-temporary-file "stringbed-nix-~a" 'directory))
(dynamic-wind void
 (lambda ()
   (for ([source (list home server)] [registry (list (load-registry) (load-registry (list extension)))] [name '("home" "server")])
     (define out (build-path dir name))
     (export-workspace (read-workspace source) registry out)
     (for ([p '("configuration.nix" "flake.nix")])
       (check-true (system* nix "--parse" (path->string (build-path out p)))))
     ;; Evaluate generated definitions with a small package fixture. This verifies
     ;; Nix syntax/value semantics, not the full NixOS/Home Manager module system.
     (define expr (format "let m = import ~a { pkgs.ripgrep = \"ripgrep-fixture\"; lib = {}; inputs = {}; }; in m.imports" (path->string (build-path out "configuration.nix"))))
     (check-true (system* nix "--eval" "--strict" "--json" "--expr" expr)))
   (define escaped (nix-value "quote\" slash\\ literal${x}\nλ"))
   (define output (open-output-string))
   (check-true (parameterize ([current-output-port output]) (system* nix "--eval" "--json" "--expr" escaped)))
   (check-true (regexp-match? #rx"literal" (get-output-string output))))
 (lambda () (delete-directory/files dir)))
(test-case "native null and scientific finite numbers parse in Nix"
  (define numbers (nix-value (list 'null 1e20 1e-20 -1e20 -1e-20 1.25 -2 -1.25 -0.0)))
  (define output (open-output-string))
  (check-true (parameterize ([current-output-port output])
                (system* nix "--eval" "--strict" "--json" "--expr" numbers)))
  (check-true (regexp-match? #rx"null" (get-output-string output))))
(test-case "digit-leading package and module attributes use safe quoted references"
  (define w (new-workspace "numeric"))
  (define r (load-registry))
  (define s (session #f w '() #""))
  (execute! s r '(add package "game" #hash((attribute . "0ad"))))
  (execute! s r '(add module "numeric-module" #hash((input . "home-manager") (attribute . "nixosModules.0test"))))
  (define module (compile-module (session-workspace s) r))
  (define expression
    (string-append "let m = (" module ") { pkgs.\"0ad\" = \"game-fixture\"; inputs.home-manager.nixosModules.\"0test\" = {}; lib = {}; }; in m.imports"))
  (define output (open-output-string))
  (check-true (parameterize ([current-output-port output]) (system* nix "--eval" "--strict" "--json" "--expr" expression)))
  (check-true (regexp-match? #rx"game-fixture" (get-output-string output))))
