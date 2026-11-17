#lang racket/base
(require racket/cmdline racket/file racket/path racket/port racket/pretty racket/runtime-path
         "model.rkt" "session.rkt" "operations.rkt")
(provide main)
(define-runtime-path tui-module "tui.rkt")
(define-runtime-path gui-module "gui.rkt")
(define (main)
  (define extensions '())
  (define args
    (command-line #:program "stringbed"
      #:multi [("--extension" "-e") path "Load trusted extension, relative to workspace" (set! extensions (append extensions (list path)))]
      #:args args args))
  (with-handlers ([exn:fail? (lambda (e) (eprintf "stringbed: ~a\n" (exn-message e)) (exit 1))])
    (cond
      [(and (= (length args) 3) (equal? (car args) "generate"))
       (define w (workspace-valid! (dynamic-require (path->complete-path (cadr args)) 'configuration)))
       (call-with-output-file (caddr args) (lambda (o) (display (workspace-text w) o)))
       (displayln "Materialized trusted Racket generator; edit its source to regenerate.")]
      [(and (pair? args) (equal? (car args) "init"))
       (unless (= (length args) 2) (error 'usage "init FILE"))
       (call-with-output-file (cadr args) (lambda (o) (pretty-write (new-workspace) o)))
       (displayln "Created home workspace. Edit metadata with (meta key value).")]
      [(and (pair? args) (equal? (car args) "inspect"))
       (unless (<= 1 (length args) 2) (error 'usage "inspect [USER@HOST]"))
       (display (inspect-machine (and (= (length args) 2) (cadr args))))]
      [(and (= (length args) 2) (member (car args) '("lock" "check" "build")))
       (display (nix-operation (string->symbol (car args)) (cadr args)))]
      [(and (>= (length args) 2) (member (car args) '("edit" "tui" "gui")))
       (unless (= (length args) (if (equal? (car args) "edit") 3 2))
         (error 'usage "wrong number of arguments"))
       (define path (path->complete-path (cadr args)))
       (define s (open-session path))
       (define r (load-registry extensions (path-only path)))
       (case (string->symbol (car args))
         [(edit)
          (unless (= (length args) 3) (error 'usage "edit FILE '(command ...)'"))
          (displayln (execute! s r (call-with-input-string (caddr args) read-data)))
          ;; CLI edits persist as a transaction; read-only commands do not rewrite.
          (unless (null? (session-history s)) (save-session! s) (displayln "Saved CLI edit."))]
         [(tui) ((dynamic-require tui-module 'run-tui) s r)]
         [(gui) ((dynamic-require gui-module 'run-gui) s r)])]
      [else
       (unless (null? args) (error 'usage "unknown command or invalid arguments: ~s" args))
       (displayln "Stringbed — editable Nix configuration\n  init FILE\n  edit FILE '(add package \"search\")'\n  edit FILE '(set \"search\" attribute \"ripgrep\")'\n  edit FILE '(why \"search\")'\n  tui FILE | gui FILE\n  edit FILE '(export \"new-directory\")'\n  lock DIR | check DIR | build DIR\n  inspect [USER@HOST]\nUse --extension FILE before the command to load trusted Racket code.")])) )
(module+ main (main))
