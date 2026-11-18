#lang racket/base
(require racket/cmdline racket/file racket/path racket/port racket/pretty racket/runtime-path racket/system
         "model.rkt" "session.rkt" "operations.rkt" "durability.rkt" "lifecycle.rkt"
         "ui-extension.rkt" "nix-query.rkt")
(provide main)
(define-runtime-path tui-module "tui.rkt")
(define-runtime-path gui-module "gui.rkt")
(define-runtime-path protocol-module "protocol.rkt")
(define-runtime-path emacs-launcher "../scripts/stringbed-emacs")
(define (main)
  (define extensions '()) (define plugins '())
  (define target #f) (define builder #f) (define kind 'nixos) (define profile #f)
  (define args
    (command-line #:program "stringbed"
      #:once-each
      [("--target") host "Activation/inspection SSH target" (set! target host)]
      [("--builder") host "SSH Nix builder (separate from target)" (set! builder host)]
      [("--kind") value "Lifecycle adapter: nixos or home" (set! kind (string->symbol value))]
      [("--home-profile") path "Explicit absolute Home Manager profile" (set! profile path)]
      #:multi
      [("--extension" "-e") path "Load trusted development extension" (set! extensions (append extensions (list path)))]
      [("--plugin") path "Load trusted UI/command plugin" (set! plugins (append plugins (list path)))]
      #:args args args))
  (with-handlers ([exn:fail? (lambda (e) (eprintf "stringbed: ~a\n" (exn-message e)) (exit 1))])
    (cond
      [(equal? args '("serve"))
       (unless (and (null? extensions) (null? plugins))
         (error 'serve "pin trusted extensions in the workspace before opening the Emacs frontend"))
       ((dynamic-require protocol-module 'run-server))]
      [(and (= (length args) 2) (member (car args) '("edit" "emacs")))
       (unless (and (null? extensions) (null? plugins))
         (error 'edit "pin trusted extensions in the workspace before opening the Emacs frontend"))
       (define launcher
         (or (getenv "STRINGBED_EMACS_LAUNCHER")
             (find-executable-path "stringbed-emacs") emacs-launcher))
       (exit (system*/exit-code launcher (path->complete-path (cadr args))))]
      [(and (= (length args) 3) (equal? (car args) "generate"))
       (define source (path->complete-path (cadr args)))
       (define w (attach-generator-provenance (workspace-valid! (dynamic-require source 'configuration)) source))
       (call-with-output-file (caddr args) (lambda (o) (display (workspace-text w) o)))
       (displayln "Materialized trusted generator with source provenance.")]
      [(and (= (length args) 2) (equal? (car args) "init"))
       (call-with-output-file (cadr args) (lambda (o) (pretty-write (new-workspace) o)))
       (displayln "Created home workspace. Edit metadata with (meta key value).")]
      [(and (= (length args) 2) (equal? (car args) "show"))
       (display (workspace-text (read-workspace (cadr args))))]
      [(and (= (length args) 2) (equal? (car args) "secret-metadata"))
       (pretty-write (encrypted-secret-metadata (cadr args)))]
      [(and (= (length args) 2) (equal? (car args) "migrate"))
       (displayln (migrate-workspace! (cadr args)))]
      [(and (= (length args) 5) (equal? (car args) "pin"))
       (pretty-write (pin-extension! (cadr args) (caddr args) (cadddr args) (list-ref args 4)))]
      [(and (= (length args) 2) (equal? (car args) "verify"))
       (verify-extension-lock! (cadr args)) (displayln "Extension snapshots verified.")]
      [(and (pair? args) (equal? (car args) "inspect") (<= (length args) 2))
       (display (inspect-machine (if (= (length args) 2) (cadr args) target)))]
      [(equal? args '("observe"))
       (pretty-write (inspect-lifecycle #:target target #:kind kind #:home-profile profile))]
      [(and (= (length args) 4) (equal? (car args) "plan"))
       (pretty-write (prepare-plan (cadr args) (caddr args) (cadddr args)
                                  #:target target #:build-host builder #:kind kind #:home-profile profile))]
      [(and (= (length args) 2) (member (car args) '("apply" "rollback" "status")))
       (pretty-write ((case (string->symbol (car args)) [(apply) apply-plan] [(rollback) rollback-plan] [else lifecycle-status]) (cadr args)))]
      [(and (= (length args) 2) (member (car args) '("lock" "check" "build")))
       (display (nix-operation (string->symbol (car args)) (cadr args)))]
      [(and (= (length args) 3) (equal? (car args) "search"))
       (pretty-write (search-packages (cadr args) (caddr args)))]
      [(and (<= 3 (length args) 4) (member (car args) '("options" "explain")))
       (pretty-write ((if (equal? (car args) "options") discover-options explain-option)
                      (cadr args) (caddr args) #:scope (and (= (length args) 4) (cadddr args))))]
      [(and (>= (length args) 2) (member (car args) '("edit" "tui" "gui")))
       (unless (= (length args) (if (equal? (car args) "edit") 3 2))
         (error 'usage "wrong number of arguments"))
       (define path (path->complete-path (cadr args)))
       (define s (open-session path))
       (define r (load-registry extensions (path-only path) #:workspace path))
       (define (read-plugins)
         (merge-plugins
          (list (load-ui-plugins (locked-extension-paths path) #:optional? #t)
                (load-ui-plugins plugins (path-only path)))))
       (define p (read-plugins))
       (define (reload)
         (define next-r (load-registry extensions (path-only path) #:workspace path))
         (define next-p (read-plugins))
         (values next-r next-p))
       (case (string->symbol (car args))
         [(edit)
          (define before (session-workspace s))
          (displayln (dispatch-ui! s r p (call-with-input-string (caddr args) read-data)))
          ;; A restored undo history is not an unsaved edit.
          (unless (equal? before (session-workspace s)) (save-session! s) (displayln "Saved CLI edit."))]
         [(tui) ((dynamic-require tui-module 'run-tui) s r p reload)]
         [(gui) ((dynamic-require gui-module 'run-gui) s r p reload)])]
      [else
       (unless (null? args) (error 'usage "unknown command or invalid arguments: ~s" args))
       (displayln #<<HELP
Stringbed — editable Nix configuration
  init FILE | migrate FILE | show FILE
  secret-metadata ENCRYPTED-SOPS-FILE
  generate TRUSTED-RACKET-MODULE FILE
  pin FILE ID BUNDLE-DIR ENTRY | verify FILE
  edit FILE | emacs FILE         Open the Emacs workbench
  serve                         Structured frontend protocol on stdin/stdout
  edit FILE '(add package "search" #hash((attribute . "ripgrep")))'
  edit FILE '(home alice "/home/alice" "24.11")'
  edit FILE '(scope "search" "home:alice")'
  tui FILE | gui FILE
  edit FILE '(export "new-directory")'
  lock DIR | check DIR | build DIR
  search DIR TERM | options DIR TERM [SCOPE] | explain DIR OPTION [SCOPE]
  inspect [USER@HOST] | observe
  plan FILE LOCKED-EXPORT NEW-PLAN.json
  apply PLAN.json | rollback PLAN.json | status PLAN.json
Options precede commands: --extension FILE, --plugin FILE, --target USER@HOST,
--builder USER@HOST, --kind nixos|home, --home-profile ABSOLUTE-PATH.
Plan builds and observes. Apply/rollback explicitly activate the recorded target.
HELP
)])))
(module+ main (main))
