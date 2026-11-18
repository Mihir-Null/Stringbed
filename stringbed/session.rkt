#lang racket/base
(require racket/match racket/list racket/string racket/path racket/file racket/runtime-path "model.rkt" "extension.rkt" "compiler.rkt" "nix-query.rkt" "durability.rkt"
         (prefix-in builtin: "builtins.rkt"))
(provide load-registry execute! describe-workspace)
(define-runtime-path builtin-source "builtins.rkt")
(define (load-registry [extensions '()] [base (current-directory)] #:workspace [workspace #f]
                       #:sources [sources #f])
  (define (record path forms #:locked? [locked? #f])
    (when sources
      (for ([d forms])
        (hash-set! sources (form-kind d)
                   (hash 'path (path->string (simplify-path (path->complete-path path)))
                         'sha256 (bytes-digest (file->bytes path)) 'locked locked?)))))
  (record builtin-source builtin:forms)
  (make-registry
   (append builtin:forms
           (if workspace (load-locked-extensions workspace #:on-load (lambda (path forms) (record path forms #:locked? #t))) '())
           (append-map
            (lambda (p)
              (define path (simplify-path (path->complete-path p base)))
              (define forms (load-trusted-extension path))
              (record path forms) forms)
            extensions))))
(define (describe-workspace w)
  (string-append (format "~a | ~a | ~a\n" (hash-ref w 'name) (hash-ref w 'target) (hash-ref w 'system))
    (string-join (for/list ([n (hash-ref w 'nodes)])
      (format "~a  ~a  ~s  ~a" (hash-ref n 'id) (hash-ref n 'kind) (hash-ref n 'params) (hash-ref n 'note))) "\n")))
(define (execute! s r command)
  (define w (session-workspace s))
  (define (edit w*) (validate-workspace w* r) (commit-edit! s w*) "Updated draft; save to persist.")
  (define (change id f) (edit (update-node w id f)))
  (match-command s r command w edit change))
(define (match-command s r command w edit change)
  (match command
    [(list 'list) (describe-workspace w)]
    [(list 'kinds) (string-join (for/list ([k (sort (hash-keys r) symbol<?)]) (format "~a: ~a" k (form-description (hash-ref r k)))) "\n")]
    [(list 'add kind id)
     (when (memq kind '(package option))
       (error 'add "~a requires an explicit selection and parameters" kind))
     (define d (hash-ref r kind (lambda () (error 'add "unknown kind ~a" kind))))
     (edit (add-node w (hash 'id id 'kind kind 'params (defaults d) 'note "" 'docs '())))]
    [(list 'add kind id (? hash? params))
     (hash-ref r kind (lambda () (error 'add "unknown kind ~a" kind)))
     (edit (add-node w (hash 'id id 'kind kind 'params params 'note "" 'docs '())))]
    [(list 'set id key value)
     (change id (lambda (n) (hash-set n 'params (hash-set (hash-ref n 'params) key value))))]
    [(list 'note id text) (change id (lambda (n) (hash-set n 'note text)))]
    [(list 'docs id (? list? links)) (change id (lambda (n) (hash-set n 'docs links)))]
    [(list 'scope id scope) (change id (lambda (n) (hash-set n 'scope scope)))]
    [(list 'home (? symbol? user) (? string? directory) (? string? state-version))
     (unless (eq? (hash-ref w 'target) 'nixos) (error 'home "named homes require a NixOS workspace"))
     (edit (hash-set w 'homes (hash-set (hash-ref w 'homes (hash)) user
                                      (hash 'home-directory directory 'state-version state-version))))]
    [(list 'package-search dir term) (format "~s" (search-packages dir term))]
    [(list 'option-search dir term) (format "~s" (discover-options dir term))]
    [(list 'option-search dir term scope) (format "~s" (discover-options dir term #:scope scope))]
    [(list 'evaluated-why dir path) (format "~s" (explain-option dir path))]
    [(list 'evaluated-why dir path scope) (format "~s" (explain-option dir path #:scope scope))]
    [(list 'remove id) (edit (remove-node w id))]
    [(list 'meta key value)
     (unless (memq key '(name target system user home-directory state-version)) (error 'meta "unsupported metadata key"))
     (edit (hash-set w key value))]
    [(list 'input key url) (edit (hash-set w 'inputs (hash-set (hash-ref w 'inputs) key url)))]
    [(list 'why id)
     (node-by-id w id)
     (format "~s" (findf (lambda (p) (equal? id (hash-ref p 'id))) (provenance w r)))]
    [(list 'source) (workspace-text w)]
    [(list 'nix) (compile-module w r)]
    [(list 'validate) (validate-workspace w r) "Workspace and extensions are valid (Nix evaluation is separate)."]
    [(list 'undo) (undo! s) "Undid last draft edit."]
    [(list 'save) (save-session! s) "Saved."]
    [(list 'export dir lock) (export-workspace w r dir #:lock-file lock) (format "Exported to ~a" dir)]
    [(list 'export dir) (export-workspace w r dir) (format "Exported to ~a" dir)]
    [_ (error 'command "unknown command or arguments: ~s" command)]))
