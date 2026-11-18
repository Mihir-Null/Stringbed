#lang racket/base
(require rackunit racket/file racket/port
         "../stringbed/durability.rkt" "../stringbed/ui-extension.rkt" "../stringbed/model.rkt" "../stringbed/session.rkt" "../stringbed/compiler.rkt")
(define registry (load-registry))
(test-case "named home scopes and recursive option data use shared editing commands"
  (define w (new-workspace "generic" 'nixos))
  (define s (session #f w '() #""))
  (execute! s registry '(home alice "/home/alice" "24.11"))
  (execute! s registry '(add package "search" #hash((attribute . "ripgrep"))))
  (execute! s registry '(scope "search" "home:alice"))
  (execute! s registry '(add option "data" #hash((path . "environment.variables") (value . #hash()))))
  (execute! s registry '(set "data" value #hash((EDITOR . "vi") (NESTED . ("one" 2 #t)))))
  (check-true (regexp-match? #rx"home.*packages" (compile-module (session-workspace s) registry #:scope "home:alice")))
  (check-true (regexp-match? #rx"EDITOR" (compile-module (session-workspace s) registry)))
  (define before (session-workspace s))
  (check-exn exn:fail? (lambda () (execute! s registry '(scope "search" "home:missing"))))
  (check-equal? (session-workspace s) before))
(test-case "persistent undo does not make inspection dirty"
  (define dir (make-temporary-file "workbench~a" 'directory))
  (dynamic-wind void
    (lambda ()
      (define path (build-path dir "home.sbd"))
      (display-to-file (workspace-text (new-workspace)) path)
      (define s (open-session path))
      (execute! s registry '(add package "first" #hash((attribute . "ripgrep")))) (save-session! s)
      (define reopened (open-session path))
      (check-equal? (length (session-history reopened)) 1)
      (define before (file->bytes path))
      (execute! reopened registry '(why "first"))
      (check-equal? (file->bytes path) before)
      (execute! reopened registry '(undo)) (save-session! reopened)
      (check-equal? (hash-ref (read-workspace path) 'nodes) '()))
    (lambda () (delete-directory/files dir))))

(test-case "pinned bundle supplies shared form and UI identities"
  (define dir (make-temporary-file "pinned-ui~a" 'directory))
  (dynamic-wind void
    (lambda ()
      (define path (build-path dir "home.sbd"))
      (display-to-file (workspace-text (new-workspace)) path)
      (define bundle (build-path dir "bundle")) (make-directory bundle)
      (display-to-file
       "#lang racket/base\n(require stringbed/extension stringbed/ui-extension)\n(provide forms ui-plugin)\n(define forms '())\n(define ui-plugin (plugin (hash 'hello (lambda (s r args) \"hello\")) (hash) (hash)))\n"
       (build-path bundle "main.rkt"))
      (pin-extension! path "custom" bundle "main.rkt")
      (define registry (load-registry '() dir #:workspace path))
      (define plugin (load-ui-plugins (locked-extension-paths path) #:optional? #t))
      (check-equal? (dispatch-ui! (open-session path) registry plugin '(hello)) "hello")
      (display-to-file "#lang racket/base\n(provide forms)\n(define forms '())\n" (build-path bundle "main.rkt") #:exists 'truncate)
      (pin-extension! path "custom" bundle "main.rkt")
      (check-equal? (plugin-commands (load-ui-plugins (locked-extension-paths path) #:optional? #t)) (hash)))
    (lambda () (delete-directory/files dir))))
