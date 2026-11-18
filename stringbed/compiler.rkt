#lang racket/base
(require racket/list racket/string racket/math racket/file racket/format racket/path json "extension.rkt" "model.rkt")
(provide nix-value nix-string (struct-out nix-path) compile-module compile-flake provenance
         validate-workspace validate-workspace-node export-workspace node-scope workspace-homes)
;; Paths are explicit values supplied by trusted extensions, never guessed from strings.
(define (nix-string s)
  (string-append "\"" (string-replace (string-replace (string-replace (string-replace (string-replace s "\\" "\\\\") "\"" "\\\"") "${" "\\${") "\n" "\\n") "\r" "\\r") "\""))
(define (nix-value v)
  (cond [(nix-expr? v) (nix-expr-text v)]
        [(nix-path? v)
         (unless (and (string? (nix-path-value v)) (absolute-path? (nix-path-value v)))
           (error 'nix-path "explicit path must be absolute; use a flake input for portable modules"))
         (format "(builtins.toPath ~a)" (nix-string (nix-path-value v)))]
        [(string? v) (nix-string v)] [(boolean? v) (if v "true" "false")]
        [(eq? v 'null) "null"]
        [(and (real? v) (not (nan? v)) (not (infinite? v))
              (or (exact-integer? v) (inexact? v)))
         ;; Nix requires a decimal mantissa for exponents and parentheses
         ;; around unary negation when the value appears in a list.
         (define text (regexp-replace #px"^(-?[0-9]+)([eE])" (number->string v) "\\1.0\\2"))
         (if (string-prefix? text "-") (string-append "(" text ")") text)]
        [(list? v) (format "[ ~a ]" (string-join (map nix-value v) " "))]
        [(hash? v)
         (format "{ ~a }" (string-join
           (for/list ([key (sort (hash-keys v) string<? #:key (lambda (k) (if (symbol? k) (symbol->string k) k)))])
             (unless (or (symbol? key) (string? key)) (error 'nix "attribute-set keys must be strings or symbols"))
             (format "~a = ~a;" (nix-string (if (symbol? key) (symbol->string key) key)) (nix-value (hash-ref v key)))) " "))]
        [else (error 'nix "unsupported value ~s" v)]))
(define (workspace-homes w)
  (define homes (hash-ref w 'homes (hash)))
  (unless (hash? homes) (error 'homes "homes must be a hash of username symbols to metadata"))
  (when (and (positive? (hash-count homes)) (not (eq? (hash-ref w 'target) 'nixos)))
    (error 'homes "integrated homes require a NixOS target"))
  (when (and (positive? (hash-count homes)) (not (hash-has-key? (hash-ref w 'inputs) 'home-manager)))
    (error 'homes "integrated homes require a home-manager input"))
  (for ([(user data) (in-hash homes)])
    (unless (and (symbol? user) (regexp-match? #px"^[A-Za-z_][A-Za-z0-9_-]*$" (symbol->string user))
                 (hash? data) (string? (hash-ref data 'home-directory #f))
                 (string? (hash-ref data 'state-version #f)))
      (error 'homes "each home needs a safe username, home-directory and state-version")))
  homes)
(define (node-scope w n)
  (define scope (hash-ref n 'scope (if (eq? (hash-ref w 'target) 'home) "home" "system")))
  (unless (string? scope) (error 'scope "scope must be a string"))
  (cond
    [(eq? (hash-ref w 'target) 'home)
     (unless (equal? scope "home") (error 'scope "standalone home nodes use scope home"))]
    [(equal? scope "system") (void)]
    [(string-prefix? scope "home:")
     (unless (hash-has-key? (workspace-homes w) (string->symbol (substring scope 5)))
       (error 'scope "undeclared integrated home: ~a" scope))]
    [else (error 'scope "expected system or home:USERNAME")])
  scope)
(define (scope-context w scope)
  (if (string-prefix? scope "home:")
      (let* ([user (substring scope 5)] [meta (hash-ref (workspace-homes w) (string->symbol user))])
        (hash-set* w 'target 'home 'user user 'home-directory (hash-ref meta 'home-directory)
                   'state-version (hash-ref meta 'state-version) 'homes (hash)))
      w))
(define (expand-node w r n)
  (define scope (node-scope w n))
  (define d (validate-node n r))
  (define result ((form-expand d) (hash-ref n 'params) (scope-context w scope)))
  (unless (and (list? result) (andmap (lambda (v) (or (assignment? v) (nix-import? v))) result))
    (error 'extension "~a returned invalid expansion" (form-kind d)))
  (cons n result))
(define (validate-workspace-node w r n)
  ;; Keep the complete workspace available to programmable forms.
  (expand-node w r n) (void))
(define (expanded w r)
  (workspace-valid! w)
  (workspace-homes w)
  (for/list ([n (hash-ref w 'nodes)]) (expand-node w r n)))
(define (selected-entries w r id)
  (when id (node-by-id w id))
  (define entries (expanded w r))
  (if id (filter (lambda (entry) (equal? (hash-ref (car entry) 'id) id)) entries) entries))
(define (validate-workspace w r) (expanded w r) (void))
(define (definition-text v)
  (cond [(nix-import? v) (format "imports = [ ~a ];" (nix-import-expression v))]
        [else
         (unless (and (pair? (assignment-path v)) (andmap string? (assignment-path v)))
           (error 'assignment "option paths must be nonempty lists of literal strings"))
         (format "~a = ~a;" (string-join (map nix-string (assignment-path v)) ".") (nix-value (assignment-value v)))]))
(define (compile-module w r #:scope [scope #f] #:node [id #f])
  (render-module w (selected-entries w r id) (or scope (if (eq? (hash-ref w 'target) 'home) "home" "system"))))
(define (origin w n) (string-append "stringbed:" (hash-ref w 'name) "/" (hash-ref n 'id)))
(define (render-module w entries scope)
  (string-append
   "# Generated by Stringbed. Edit the workspace or its extensions.\n{ pkgs, lib, inputs, ... }: {\n  imports = [\n"
   (string-join
    (for/list ([entry entries] #:when (equal? scope (node-scope w (car entry))))
      (define n (car entry))
      (string-join (for/list ([v (cdr entry)])
        (format "    { _file = ~a; ~a }" (nix-string (origin w n)) (definition-text v))) "\n")) "\n")
   "\n  ];\n}\n"))
(define (home-definitions user meta [module-path #f])
  (string-append
   (if module-path (format "imports = [ ~a ]; " module-path) "")
   (format "home.username = ~a; home.homeDirectory = ~a; home.stateVersion = ~a;"
           (nix-string user) (nix-string (hash-ref meta 'home-directory)) (nix-string (hash-ref meta 'state-version)))))
(define (compile-flake w)
  (workspace-valid! w)
  (define homes (workspace-homes w))
  (define home? (eq? (hash-ref w 'target) 'home))
  (define name (nix-string (hash-ref w 'name)))
  (define system (nix-string (hash-ref w 'system)))
  (define integrated
    (if (zero? (hash-count homes)) ""
      (string-append
       " inputs.home-manager.nixosModules.home-manager { home-manager.useGlobalPkgs = true; home-manager.useUserPackages = true; home-manager.extraSpecialArgs = { inherit inputs; }; "
       (string-join (for/list ([user (sort (hash-keys homes) symbol<?)])
         (format "home-manager.users.~a = { ~a };"
                 (nix-string (symbol->string user))
                 (home-definitions (symbol->string user) (hash-ref homes user)
                                   (string-append "./homes/" (symbol->string user) ".nix")))) " ") " }")))
  (string-append
   "# Generated by Stringbed. Commit flake.lock after locking.\n{\n  inputs = {\n"
   (string-join (for/list ([k (sort (hash-keys (hash-ref w 'inputs)) symbol<?)])
     (format "    ~a.url = ~a;" (nix-string (symbol->string k)) (nix-string (hash-ref (hash-ref w 'inputs) k)))) "\n")
   (if (hash-has-key? (hash-ref w 'inputs) 'home-manager) "\n    home-manager.inputs.nixpkgs.follows = \"nixpkgs\";" "")
   "\n  };\n  outputs = inputs@{ self, nixpkgs, ... }: let\n"
   (if home?
       (format "    target = inputs.home-manager.lib.homeManagerConfiguration {\n      pkgs = nixpkgs.legacyPackages.${~a};\n      extraSpecialArgs = { inherit inputs; };\n      modules = [ ./configuration.nix { ~a } ];\n    };\n"
               system (home-definitions (hash-ref w 'user) w))
       (format "    target = nixpkgs.lib.nixosSystem {\n      system = ~a; specialArgs = { inherit inputs; };\n      modules = [ ./configuration.nix { networking.hostName = ~a; system.stateVersion = ~a; }~a ];\n    };\n"
               system name (nix-string (hash-ref w 'state-version)) integrated))
   "  in {\n"
   (format "    ~a.${~a} = target;\n" (if home? "homeConfigurations" "nixosConfigurations") name)
   (format "    packages.${~a}.default = target.~a;\n" system (if home? "activationPackage" "config.system.build.toplevel"))
   "  };\n}\n"))
(define (provenance w r #:node [id #f]) (render-provenance w (selected-entries w r id)))
(define (render-provenance w entries)
  (for/list ([entry entries])
    (define n (car entry))
    (hash 'id (hash-ref n 'id) 'kind (symbol->string (hash-ref n 'kind))
          'origin (origin w n) 'scope (node-scope w n)
          'note (hash-ref n 'note) 'docs (hash-ref n 'docs)
          'definitions (map definition-text (cdr entry)))))
(define (export-workspace w r dir #:lock-file [lock-file #f])
  (define entries (expanded w r))
  (define module (render-module w entries (if (eq? (hash-ref w 'target) 'home) "home" "system")))
  (define flake (compile-flake w))
  (define prov (render-provenance w entries))
  (define homes (workspace-homes w))
  (define lock-bytes
    (and lock-file
         (let ([bytes (file->bytes lock-file)])
           (define parsed (read-json (open-input-bytes bytes)))
           (unless (and (hash? parsed) (hash-has-key? parsed 'nodes) (hash-has-key? parsed 'version))
             (error 'export "invalid flake lock")) bytes)))
  (when (or (directory-exists? dir) (file-exists? dir)) (error 'export "destination already exists; use a new directory"))
  (make-directory dir)
  (with-handlers ([exn:fail? (lambda (e) (delete-directory/files dir) (raise e))])
    (for ([name '("configuration.nix" "flake.nix")] [text (list module flake)])
      (call-with-output-file (build-path dir name) (lambda (o) (display text o))))
    (when (positive? (hash-count homes))
      (make-directory (build-path dir "homes"))
      (for ([user (sort (hash-keys homes) symbol<?)])
        (call-with-output-file (build-path dir "homes" (string-append (symbol->string user) ".nix"))
          (lambda (o) (display (render-module w entries (string-append "home:" (symbol->string user))) o)))))
    (when lock-bytes (call-with-output-file (build-path dir "flake.lock") (lambda (o) (write-bytes lock-bytes o))))
    (call-with-output-file (build-path dir "provenance.json") (lambda (o) (write-json prov o)))
    (call-with-output-file (build-path dir "target.json")
      (lambda (o) (write-json (hash 'schema 1 'workspace-sha256 (bytes-digest (string->bytes/utf-8 (workspace-text w))) 'name (hash-ref w 'name) 'target (symbol->string (hash-ref w 'target))
                                   'system (hash-ref w 'system) 'user (hash-ref w 'user)
                                   'homes (map symbol->string (sort (hash-keys homes) symbol<?))) o))))
  dir)
