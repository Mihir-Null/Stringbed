#lang racket/base
(require "model.rkt" "extension.rkt")
(provide workspace node package option compose (all-from-out "extension.rkt"))
;; Optional programmable authoring vocabulary. Arbitrary Racket can create these
;; values; materialization is explicit, and generated data does not round-trip.
(define (node kind id params #:note [note ""] #:docs [docs '()] #:scope [scope #f])
  (define n (hash 'id id 'kind kind 'params params 'note note 'docs docs))
  (if scope (hash-set n 'scope scope) n))
(define (package id attribute #:note [note ""])
  (node 'package id (hash 'attribute attribute) #:note note))
(define (option id path value #:note [note ""])
  (node 'option id (hash 'path path 'value value) #:note note))
(define (compose . groups) (apply append groups))
(define (workspace name nodes #:target [target 'home] #:user [user "demo"] #:system [system "x86_64-linux"] #:homes [homes (hash)])
  (workspace-valid! (hash-set* (new-workspace name target) 'nodes nodes 'user user 'system system 'homes homes
                             'home-directory (string-append "/home/" user))))
