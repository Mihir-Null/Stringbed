#lang racket/base
(require "extension.rkt")
(provide forms)
(define forms
  (list
   (form 'package "Add a package to this target"
         (list (field 'attribute 'attribute "ripgrep" "nixpkgs attribute"))
         (lambda (p w)
           (list (assignment (if (eq? (hash-ref w 'target) 'home) '("home" "packages") '("environment" "systemPackages"))
                             (list (nix-expr (string-append "pkgs." (hash-ref p 'attribute))))))))
   (form 'option "Define a Nix module option"
         (list (field 'path 'attribute "programs.git.enable" "Option path")
               (field 'value 'value #t "String, boolean, integer, list or attribute set"))
         (lambda (p w) (list (assignment (attr-path (hash-ref p 'path)) (hash-ref p 'value)))))
   (form 'module "Import a module from a named flake input"
         (list (field 'input 'attribute "home-manager" "Input name declared in workspace")
               (field 'attribute 'attribute "nixosModules.home-manager" "Exported module path"))
         (lambda (p w)
           (unless (hash-has-key? (hash-ref w 'inputs) (string->symbol (hash-ref p 'input)))
             (error 'module "undeclared input ~a" (hash-ref p 'input)))
           (list (nix-import (string-append "inputs." (hash-ref p 'input) "." (hash-ref p 'attribute))))))))
