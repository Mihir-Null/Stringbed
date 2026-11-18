#lang racket/base
(require racket/file racket/string racket/list racket/format json "compiler.rkt" "extension.rkt" "operations.rkt")
(provide search-packages lookup-package discover-options option-detail validate-option-value explain-option query-context)
;; Every query is rooted in a materialized flake with an existing lock. No ambient
;; nixpkgs registry or channel supplies package/option metadata.
(define flags '("--extra-experimental-features" "nix-command flakes"))
(define (query-context directory)
  (define dir (path->complete-path directory))
  (unless (and (file-exists? (build-path dir "flake.nix")) (file-exists? (build-path dir "flake.lock")))
    (error 'query "exported flake and flake.lock required; lock the workspace first"))
  (values (string-append "path:" (path->string dir))
          (if (file-exists? (build-path dir "target.json"))
              (call-with-input-file (build-path dir "target.json") read-json)
              (error 'query "target.json missing; re-export with current Stringbed"))))
(define (decode-json output)
  (with-handlers ([exn:fail? (lambda (e) (error 'query "Nix did not return valid JSON: ~a" (exn-message e)))])
    (read-json (open-input-string output))))
(define (eval-json expr)
  (decode-json ((current-runner) "nix" (append flags (list "eval" "--json" "--no-update-lock-file" "--impure" "--expr" expr)))))
(define (lookup-package directory attribute)
  (define-values (ref meta) (query-context directory))
  (define parts (attr-path attribute))
  (eval-json
   (format "let f = builtins.getFlake ~a; lib = f.inputs.nixpkgs.lib; p = lib.attrByPath ~a null f.inputs.nixpkgs.legacyPackages.~a; in if p == null || !(lib.isDerivation p) then null else { attribute = ~a; pname = p.pname or p.name; version = p.version or \"\"; description = p.meta.description or \"\"; homepage = let h = p.meta.homepage or []; in if builtins.isList h then h else [ h ]; position = let location = p.meta.position or \"\"; in if location == \"\" || lib.hasPrefix \"/\" location then location else toString f.inputs.nixpkgs.outPath + \"/\" + location; }"
           (nix-string ref) (nix-value parts) (nix-string (hash-ref meta 'system)) (nix-string attribute))))
(define (search-packages directory term #:regex? [regex? #f])
  (define-values (ref meta) (query-context directory))
  (unless (and (string? term) (positive? (string-length term))) (error 'search "nonempty search term required"))
  ;; Existing CLI exact lookup remains fast. The workbench explicitly selects
  ;; search mode for names/descriptions and exact mode for a chosen attribute.
  (define parts (and (not regex?) (with-handlers ([exn:fail? (lambda (_) #f)]) (attr-path term))))
  (define exact (and parts (lookup-package directory term)))
  (if (and exact (not (eq? exact 'null)))
      (hash (string->symbol (string-append "legacyPackages." (hash-ref meta 'system) "." term)) exact)
      (decode-json ((current-runner) "nix"
        (append flags (list "search" "--json" "--no-update-lock-file" "--inputs-from" ref
                            "--system" (hash-ref meta 'system) "--" "nixpkgs" term))))))
(define (selection ref meta scope)
  (define target (hash-ref meta 'target))
  (define name (hash-ref meta 'name))
  (define home? (equal? target "home"))
  (define selected-scope (or scope (if home? "home" "system")))
  (define target-expr (format "f.~a.~a" (if home? "homeConfigurations" "nixosConfigurations") (nix-string name)))
  (cond
    [(or (and home? (equal? selected-scope "home"))
         (and (not home?) (equal? selected-scope "system")))
     (values (format "f = builtins.getFlake ~a; target = ~a; opts = target.options; cfg = target.config; optionPath = o: o.loc;" (nix-string ref) target-expr)
             #t)]
    [(and (not home?) (string-prefix? selected-scope "home:"))
     (define user (substring selected-scope 5))
     (unless (member user (hash-ref meta 'homes '())) (error 'query "unknown home ~a" user))
     (values
      (format "f = builtins.getFlake ~a; target = ~a; opts = target.options.home-manager.users.type.getSubOptions [ \"home-manager\" \"users\" ~a ]; cfg = target.config.home-manager.users.~a; optionPath = o: lib.drop 4 o.loc;"
              (nix-string ref) target-expr (nix-string user) (nix-string user))
      #f)]
    [else (error 'query "scope incompatible with target: ~a" selected-scope)]))
(define helpers
  #<<NIX
  lib = f.inputs.nixpkgs.lib;
  project = depth: value:
    if depth > 8 then { unavailable = "projection depth limit"; }
    else if builtins.isFunction value then { unavailable = "function"; }
    else if lib.isDerivation value then toString value
    else if builtins.isAttrs value then lib.mapAttrs (_: project (depth + 1)) value
    else if builtins.isList value then map (project (depth + 1)) value
    else value;
  safe = value:
    let projected = project 0 value;
        attempt = builtins.tryEval (builtins.deepSeq projected projected);
    in if attempt.success then attempt.value else { unavailable = "value cannot be evaluated in this context"; };
  text = value: if builtins.isString value then value else if builtins.isAttrs value && value ? text then value.text else "";
  # Controls are hints from the pinned type, not a second Nix type system.
  control = depth: t:
    let name = t.name or "unknown";
        nested = t.nestedTypes.elemType or (t.functor.payload.elemType or (t.functor.wrapped or null));
        payload = t.functor.payload or null;
        choices = if builtins.isList payload then payload else if builtins.isAttrs payload then payload.values or [] else [];
        numericEither = name == "either"
          && builtins.elem (t.nestedTypes.left.name or "") [ "int" "float" ]
          && builtins.elem (t.nestedTypes.right.name or "") [ "int" "float" ];
    in if depth > 5 then { kind = "advanced"; }
       else if builtins.elem name [ "bool" "boolByOr" ] then { kind = "boolean"; }
       else if name == "enum" then { kind = "enum"; choices = safe choices; }
       else if name == "nullOr" && nested != null then { kind = "nullable"; element = control (depth + 1) nested; }
       else if name == "listOf" && nested != null then { kind = "list"; element = control (depth + 1) nested; }
       else if builtins.elem name [ "int" "intBetween" "unsignedInt" "positiveInt" ] then { kind = "integer"; }
       else if numericEither || builtins.elem name [ "float" "number" "numberBetween" "numberNonnegative" "numberPositive" ] then { kind = "number"; }
       else if lib.hasPrefix "strMatching " name || builtins.elem name [ "str" "lines" "singleLineStr" "nonEmptyStr" "string" "separatedString" ] then { kind = "string"; }
       else if builtins.elem name [ "attrs" "attrsOf" "lazyAttrsOf" "submodule" "submoduleWith" "anything" ] then { kind = "structured"; }
       else { kind = "advanced"; };
  describe = option: {
    path = lib.concatStringsSep "." (optionPath option);
    type = option.type.description or "unknown";
    control = control 0 option.type;
    description = text (option.description or "");
    declarations = map toString (option.declarations or []);
    default = if option ? default then safe option.default else { unavailable = "no declared default"; };
  };
NIX
)
(define (discover-options directory [term ""] #:scope [scope #f])
  (define-values (ref meta) (query-context directory))
  (define-values (select exact?) (selection ref meta scope))
  (unless (string? term) (error 'query "search term must be a string"))
  ;; Match path or upstream description without forcing unrelated defaults.
  (eval-json
   (format "let ~a ~a matches = builtins.filter (o: lib.hasInfix (lib.toLower ~a) (lib.toLower ((lib.concatStringsSep \".\" (optionPath o)) + \" \" + text (o.description or \"\")))) (lib.collect lib.isOption opts); in map describe (lib.take 200 matches)"
           select helpers (nix-string term))))
(define (option-detail directory path #:scope [scope #f])
  (define-values (ref meta) (query-context directory))
  (define-values (select exact?) (selection ref meta scope))
  (define parts (attr-path path))
  (eval-json
   (format "let ~a ~a option = lib.attrByPath ~a null opts; in if option == null || !(lib.isOption option) then null else describe option"
           select helpers (nix-value parts))))
(define (validate-option-value directory path value #:scope [scope #f])
  (define-values (ref meta) (query-context directory))
  (define-values (select exact?) (selection ref meta scope))
  (define parts (attr-path path))
  ;; type.check intentionally checks only a container's outer shape. A miniature
  ;; native module evaluation forces the type's merge and nested validation too.
  ;; Workspace assertions, cross-option conflicts and activation are separate.
  (eval-json
   (format "let ~a ~a path = ~a; option = lib.attrByPath path null opts; candidate = ~a; checked = lib.evalModules { modules = [{ options.probe = lib.mkOption { type = option.type; }; config.probe = candidate; }]; }; attempt = builtins.tryEval (builtins.deepSeq checked.config.probe true); in if option == null || !(lib.isOption option) then { exists = false; valid = false; } else { exists = true; valid = attempt.success; type = option.type.description or \"unknown\"; }"
           select helpers (nix-value parts) (nix-value value))))
(define (explain-option directory path #:scope [scope #f])
  (define-values (ref meta) (query-context directory))
  (define-values (select exact?) (selection ref meta scope))
  ;; List paths support quoted/non-identifier option components without allowing
  ;; arbitrary expression injection. String paths use the default dotted syntax.
  (define parts (if (string? path) (attr-path path) path))
  (unless (and (pair? parts) (andmap string? parts)) (error 'query "nonempty option path required"))
  (eval-json
   (format "let ~a ~a path = ~a; option = lib.attrByPath path (throw \"unknown option\") opts; in (describe option) // { value = safe (lib.attrByPath path (throw \"no evaluated value\") cfg); definitions = ~a; definitionsComplete = ~a; provenanceNote = ~a; }"
           select helpers (nix-value parts)
           (if exact? "map (d: { file = toString d.file; value = safe d.value; }) (option.definitionsWithLocations or [])" "[]")
           (if exact? "true" "false")
           (nix-string (if exact?
             "Evaluated definitions supplied by the Nix module system; not a complete causal dependency trace."
             "Integrated home: effective value comes from NixOS, metadata from the Home Manager submodule schema; definition origins are not exposed by that schema.")))))
