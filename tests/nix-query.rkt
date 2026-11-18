#lang racket/base
(require rackunit racket/list racket/file racket/runtime-path racket/string json
         "../stringbed/compiler.rkt" "../stringbed/nix-query.rkt"
         "../stringbed/model.rkt" "../stringbed/session.rkt" "../stringbed/operations.rkt")
(define-runtime-path integrated "../examples/integrated.sbd")
(define r (load-registry))
(define w (read-workspace integrated))
(test-case "integrated homes route definitions and package contexts separately"
  (define system-module (compile-module w r))
  (define home-module (compile-module w r #:scope "home:demo"))
  (check-true (string-contains? system-module "systemPackages"))
  (check-false (string-contains? system-module "pkgs.fd"))
  (check-true (string-contains? home-module "\"home\".\"packages\""))
  (check-true (string-contains? home-module "pkgs.fd"))
  (check-false (string-contains? home-module "pkgs.ripgrep"))
  (check-true (string-contains? (compile-flake w) "home-manager.nixosModules.home-manager")))
(test-case "unknown scope and missing home-manager input are rejected"
  (check-exn exn:fail? (lambda () (compile-module (hash-set w 'inputs (hash 'nixpkgs "github:NixOS/nixpkgs")) r)))
  (check-exn exn:fail? (lambda () (compile-module (hash-set w 'nodes (list (hash-set (car (hash-ref w 'nodes)) 'scope "home:missing"))) r))))
(test-case "structured extension values preserve literal paths and attribute names"
  (check-equal? (nix-value (hash '"quoted.name" "${literal}")) "{ \"quoted.name\" = \"\\${literal}\"; }")
  (check-equal? (nix-value (nix-path "/tmp/example")) "(builtins.toPath \"/tmp/example\")")
  (check-exn exn:fail? (lambda () (nix-value (nix-path "relative")))))
(test-case "export includes homes, metadata and optional exact prior lock"
  (define parent (make-temporary-file "stringbed-query-~a" 'directory))
  (dynamic-wind void
    (lambda ()
      (define lock (build-path parent "prior.lock"))
      (display-to-file "{\"version\":7,\"nodes\":{}}" lock)
      (define out (build-path parent "export"))
      (export-workspace w r out #:lock-file lock)
      (check-true (file-exists? (build-path out "homes" "demo.nix")))
      (check-equal? (file->bytes (build-path out "flake.lock")) (file->bytes lock))
      (define meta (call-with-input-file (build-path out "target.json") read-json))
      (check-equal? (hash-ref meta 'homes) '("demo"))
      (check-equal? (hash-ref meta 'workspace-sha256) (bytes-digest (string->bytes/utf-8 (workspace-text w))))
      (define seen '())
      (parameterize ([current-runner (lambda (program args) (set! seen args) "[]")])
        (check-equal? (search-packages out "-literal" #:regex? #t) '())
        (check-not-false (member "--inputs-from" seen))
        (check-not-false (member "--no-update-lock-file" seen))
        (check-equal? (take-right seen 3) '("--" "nixpkgs" "-literal"))
        (check-equal? (discover-options out "services.openssh") '())
        (check-true (string-contains? (last seen) "lib.collect lib.isOption"))
        (explain-option out "programs.git.enable" #:scope "home:demo")
        (check-true (string-contains? (last seen) "definitionsComplete = false"))
        (check-exn exn:fail? (lambda () (explain-option out "x; bad")))))
    (lambda () (delete-directory/files parent))))
;; Optional real fixture: a locked export of examples/integrated.sbd. This checks
;; Nix module semantics without forcing a complete operating-system build.
(define integration-flake (getenv "STRINGBED_INTEGRATION_FLAKE"))
(when integration-flake
  (test-case "locked Nix integration preserves canonical home paths and effective values"
    (define why (explain-option integration-flake "programs.git.enable" #:scope "home:demo"))
    (check-equal? (hash-ref why 'path) "programs.git.enable")
    (check-true (hash-ref why 'value))
    (check-false (hash-ref why 'definitionsComplete))
    (define options (discover-options integration-flake "programs.git.enable" #:scope "home:demo"))
    (check-not-false (member "programs.git.enable" (map (lambda (o) (hash-ref o 'path)) options)))
    (define packages (search-packages integration-flake "ripgrep"))
    (check-equal? (hash-ref (hash-ref packages 'legacyPackages.x86_64-linux.ripgrep) 'pname) "ripgrep")
    (define system-why (explain-option integration-flake "networking.hostName"))
    (check-equal? (hash-ref system-why 'value) "generic-workstation")
    (check-true (hash-ref system-why 'definitionsComplete))))
(define-runtime-path extension-api "../stringbed/extension.rkt")
(test-case "fresh external extension shares explicit Nix path values with compiler"
  (define dir (make-temporary-file "stringbed-path-extension~a" 'directory))
  (dynamic-wind void
    (lambda ()
      (define extension (build-path dir "path.rkt"))
      (call-with-output-file extension
        (lambda (o)
          (fprintf o "#lang racket/base\n(require (file ~s))\n(provide forms)\n(define forms (list (form 'path-example \"Explicit file path\" '() (lambda (params workspace) (list (assignment '(\"environment\" \"etc\" \"example\" \"source\") (nix-path \"/tmp/example\")))))))\n" (path->string extension-api))))
      (define registry (load-registry (list extension)))
      (define workspace (hash-set (new-workspace "path-test") 'nodes
        (list (hash 'id "path" 'kind 'path-example 'params (hash) 'note "" 'docs '()))))
      (check-true (string-contains? (compile-module workspace registry) "(builtins.toPath \"/tmp/example\")")))
    (lambda () (delete-directory/files dir))))
