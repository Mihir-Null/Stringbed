#lang racket/base
(require "../stringbed/dsl.rkt")
(provide configuration)
;; Racket-generated composition. Edit this source to change the generator;
;; materialized workspace edits are independent and never reverse-engineered.
(define tools
  (for/list ([name '("ripgrep" "fd" "jq")])
    (package name name #:note "My small command-line toolkit.")))
(define configuration
  (workspace "generated-home" (compose tools (list (option "git" "programs.git.enable" #t)))))
