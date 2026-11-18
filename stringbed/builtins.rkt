#lang racket/base
(require racket/string "extension.rkt")
(provide forms)
;; Dotted selections are data. Quote digit-leading or reserved attribute tokens
;; while retaining familiar spelling for ordinary identifiers.
(define (reference-path path)
  (string-join
   (for/list ([part (attr-path path)])
     (if (and (regexp-match? #px"^[A-Za-z_][A-Za-z0-9_-]*$" part)
              (not (member part '("if" "then" "else" "assert" "with" "let" "in" "rec" "inherit" "or"))))
         part (format "~s" part))) "."))
(define forms
  (list
   (form 'package "Add a package to this target"
         (list (field 'attribute 'attribute #f "nixpkgs attribute"))
         (lambda (p w)
           (list (assignment (if (eq? (hash-ref w 'target) 'home) '("home" "packages") '("environment" "systemPackages"))
                             (list (nix-expr (string-append "pkgs." (reference-path (hash-ref p 'attribute)))))))))
   (form 'option "Define a Nix module option"
         (list (field 'path 'attribute #f "Option path")
               (field 'value 'value #f "String, boolean, number, null, list or attribute set"))
         (lambda (p w) (list (assignment (attr-path (hash-ref p 'path)) (hash-ref p 'value)))))
   (form 'module "Import a module from a named flake input"
         (list (field 'input 'attribute "home-manager" "Input name declared in workspace")
               (field 'attribute 'attribute "nixosModules.home-manager" "Exported module path"))
         (lambda (p w)
           (unless (hash-has-key? (hash-ref w 'inputs) (string->symbol (hash-ref p 'input)))
             (error 'module "undeclared input ~a" (hash-ref p 'input)))
           (list (nix-import (string-append "inputs." (reference-path (hash-ref p 'input)) "." (reference-path (hash-ref p 'attribute)))))))))
