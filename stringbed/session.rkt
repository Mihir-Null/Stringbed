#lang racket/base
(require racket/match racket/list racket/string racket/path "model.rkt" "extension.rkt" "compiler.rkt"
         (prefix-in builtin: "builtins.rkt"))
(provide load-registry execute! describe-workspace)
(define (load-registry [extensions '()] [base (current-directory)])
  (make-registry (append builtin:forms
     (append-map (lambda (p) (dynamic-require (simplify-path (path->complete-path p base)) 'forms)) extensions))))
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
     (define d (hash-ref r kind (lambda () (error 'add "unknown kind ~a" kind))))
     (edit (add-node w (hash 'id id 'kind kind 'params (defaults d) 'note "" 'docs '())))]
    [(list 'set id key value)
     (change id (lambda (n) (hash-set n 'params (hash-set (hash-ref n 'params) key value))))]
    [(list 'note id text) (change id (lambda (n) (hash-set n 'note text)))]
    [(list 'docs id (? list? links)) (change id (lambda (n) (hash-set n 'docs links)))]
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
    [(list 'export dir) (export-workspace w r dir) (format "Exported to ~a" dir)]
    [_ (error 'command "unknown command or arguments: ~s" command)]))
