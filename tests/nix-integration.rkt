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
