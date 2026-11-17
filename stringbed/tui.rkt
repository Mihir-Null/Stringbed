#lang racket/base
(require racket/port racket/string racket/list "model.rkt" "session.rkt" "extension.rkt")
(provide run-tui)
(define (run-tui s r)
  (define (ask text)
    (display text) (display ": ") (flush-output)
    (define answer (read-line))
    (when (eof-object? answer) (error 'input "end of input")) answer)
  (define (datum text) (call-with-input-string text read-data))
  (define (choice line)
    (case (string->number line)
      [(1) '(list)]
      [(2)
       (displayln (execute! s r '(kinds)))
       (list 'add (string->symbol (ask "Form kind")) (ask "Stable ID"))]
      [(3)
       (define id (ask "Node ID"))
       (define n (node-by-id (session-workspace s) id))
       (define d (hash-ref r (hash-ref n 'kind) (lambda () (error 'edit "load the missing extension first"))))
       (for ([f (form-fields d)]) (printf "  ~a (~a): ~a\n" (field-name f) (field-type f) (field-description f)))
       (define key (string->symbol (ask "Field")))
       (define f (findf (lambda (f) (eq? key (field-name f))) (form-fields d)))
       (unless f (error 'edit "unknown field"))
       (define value (ask "Value"))
       (list 'set id key (if (memq (field-type f) '(string attribute)) value (datum value)))]
      [(4) (list 'note (ask "Node ID") (ask "Note"))]
      [(5) (list 'why (ask "Node ID"))]
      [(6) '(undo)] [(7) '(save)] [(8) (list 'export (ask "New output directory"))]
      [(9) '(nix)] [(0) (list 'remove (ask "Node ID"))]
      [else (datum line)]))
  (displayln "Stringbed terminal editor — changes are drafts until saved.\nAny shared command is also accepted as an s-expression, e.g. (docs \"id\" (\"https://example.org\")).")
  (let loop ()
    (displayln (describe-workspace (session-workspace s)))
    (displayln "1 List  2 Add  3 Configure  4 Note  5 Why  6 Undo  7 Save  8 Export  9 Nix  0 Remove  q Quit")
    (display "stringbed> ") (flush-output)
    (define line (read-line))
    (unless (or (eof-object? line) (member line '("q" "quit")))
      (with-handlers ([exn:fail? (lambda (e) (eprintf "~a\n" (exn-message e)))])
        (displayln (execute! s r (choice line))))
      (loop))))
