#lang racket/base
(require rackunit racket/file racket/path "../stringbed/model.rkt" "../stringbed/durability.rkt" "../stringbed/extension.rkt")
(define (put path text) (call-with-output-file path (lambda (out) (display text out)) #:exists 'truncate))
(define (with-workspace proc)
  (define dir (make-temporary-file "durable~a" 'directory))
  (dynamic-wind void (lambda () (define p (build-path dir "machine.sbd"))
                       (put p (workspace-text (new-workspace))) (proc dir p))
                (lambda () (delete-directory/files dir))))
(test-case "explicit migration retains exact original bytes"
 (with-workspace
  (lambda (dir p)
    (define old (hash-remove (hash-set (new-workspace) 'schema 1) 'provenance))
    (put p (string-append "; original note\n" (workspace-text old)))
    (define bytes (file->bytes p))
    (check-equal? (hash-ref (read-workspace p) 'schema) 1)
    (define backup (migrate-workspace! p))
    (check-equal? (file->bytes backup) bytes)
    (check-equal? (hash-ref (read-workspace p) 'schema) 2)
    (check-equal? (migrate-workspace! p) p))))
(test-case "undo persists across reopening and detects concurrent history writes"
 (with-workspace
  (lambda (dir p)
    (define s (open-session p))
    (commit-edit! s (hash-set (session-workspace s) 'name "second")) (save-session! s)
    (define reopened (open-session p))
    (check-equal? (length (session-history reopened)) 1)
    (undo! reopened) (save-session! reopened)
    (check-equal? (hash-ref (read-workspace p) 'name) "workstation")
    (check-equal? (session-history (open-session p)) '())
    (define stale (open-session p))
    (put (history-path p) "changed")
    (check-exn #rx"history changed" (lambda () (save-session! stale))))))
(test-case "external source edits drop incompatible undo history"
 (with-workspace
  (lambda (dir p)
    (define s (open-session p))
    (commit-edit! s (hash-set (session-workspace s) 'name "second")) (save-session! s)
    (put p (workspace-text (hash-set (new-workspace) 'name "external")))
    (check-equal? (session-history (open-session p)) '())
    (check-exn #rx"file changed" (lambda () (save-session! s))))))
(test-case "whole extension bundle snapshots, integrity checks and fresh module instances"
 (with-workspace
  (lambda (dir p)
    (define bundle (build-path dir "bundle")) (make-directory bundle)
    (put (build-path bundle "helper.rkt") "#lang racket/base\n(provide label)\n(define label \"original\")\n")
    (put (build-path bundle "main.rkt")
         "#lang racket/base\n(require stringbed/extension \"helper.rkt\")\n(provide forms)\n(define forms (list (form 'demo label '() (lambda (p) '()))))\n")
    (define record (pin-extension! p "demo" bundle "main.rkt"))
    (check-true (absolute-path? (car (locked-extension-paths p))))
    (check-true (file-exists? (car (locked-extension-paths p))))
    (define first (car (load-locked-extensions p)))
    (check-true (form? first))
    (check-equal? (form-description first) "original")
    (check-false (eq? first (car (load-locked-extensions p))))
    (put (build-path bundle "helper.rkt") "#lang racket/base\n(provide label)\n(define label \"changed\")\n")
    (check-equal? (form-description (car (load-locked-extensions p))) "original")
    (check-exn exn:fail? (lambda () (pin-extension! p "bad" bundle "../main.rkt")))
    (define snap (build-path dir ".stringbed" "extensions" (hash-ref record 'sha256)))
    (put (build-path snap "helper.rkt") "tampered")
    (check-exn #rx"integrity" (lambda () (locked-extension-paths p)))
    (check-exn #rx"integrity" (lambda () (load-locked-extensions p))))))
(test-case "bundle symlinks rejected"
 (with-workspace
  (lambda (dir p)
    (define bundle (build-path dir "bundle")) (make-directory bundle)
    (make-file-or-directory-link p (build-path bundle "main.rkt"))
    (check-exn #rx"symlink" (lambda () (pin-extension! p "bad" bundle "main.rkt"))))))
(test-case "canonical edits retain recoverable exact source including comments"
 (with-workspace
  (lambda (dir p)
    (put p (string-append "; personal raw comment\n" (workspace-text (new-workspace))))
    (define original (file->bytes p))
    (define s (open-session p))
    (commit-edit! s (hash-set (session-workspace s) 'name "edited")) (save-session! s)
    (check-equal? (file->bytes (source-backup-path p (bytes-digest original))) original))))
(test-case "generator provenance identifies exact source bytes"
 (with-workspace
  (lambda (dir p)
    (define source (build-path dir "generate.rkt")) (put source "#lang racket/base\n")
    (define provenance (hash-ref (attach-generator-provenance (new-workspace) source) 'provenance))
    (check-equal? (hash-ref provenance 'kind) 'generated)
    (check-equal? (hash-ref provenance 'source-sha256) (bytes-digest (file->bytes source))))))
(test-case "snapshot adds and symlinked bundle ancestors cannot bypass verification"
 (with-workspace
  (lambda (dir p)
    (define bundle (build-path dir "bundle")) (make-directory bundle)
    (put (build-path bundle "main.rkt") "#lang racket/base\n(provide forms)\n(define forms '())\n")
    (define record (pin-extension! p "demo" bundle "main.rkt"))
    (define snap (build-path dir ".stringbed" "extensions" (hash-ref record 'sha256)))
    (put (build-path snap "extra.rkt") "additional dependency")
    (check-exn #rx"integrity" (lambda () (verify-extension-lock! p)))
    (make-file-or-directory-link bundle (build-path dir "alias"))
    (check-exn #rx"symlink" (lambda () (pin-extension! p "bad" (build-path dir "alias") "main.rkt"))))))
(test-case "workspace and lock move together without original extension source"
 (with-workspace
  (lambda (dir p)
    (define bundle (build-path dir "bundle")) (make-directory bundle)
    (put (build-path bundle "main.rkt") "#lang racket/base\n(provide forms)\n(define forms '(portable))\n")
    (pin-extension! p "demo" bundle "main.rkt")
    (delete-directory/files bundle)
    (define moved (make-temporary-file "moved~a" 'directory))
    (dynamic-wind
     void
     (lambda ()
       (copy-file p (build-path moved "machine.sbd"))
       (copy-directory/files (build-path dir ".stringbed") (build-path moved ".stringbed"))
       (check-equal? (load-locked-extensions (build-path moved "machine.sbd")) '(portable)))
     (lambda () (delete-directory/files moved))))))
