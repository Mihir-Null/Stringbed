#lang racket/base
(require racket/file racket/list racket/path racket/port racket/runtime-path
         "model.rkt" "extension.rkt")
(provide pin-extension! read-extension-lock verify-extension-lock! load-locked-extensions load-trusted-extension locked-extension-paths extension-lock-path)
(define-runtime-path api-path "extension.rkt")
(define-namespace-anchor anchor)
(define (workspace-root path) (path-only (path->complete-path path)))
(define (extension-lock-path path)
  (build-path (workspace-root path) ".stringbed" "locks"
              (string-append (path->string (file-name-from-path path)) ".rktd")))
(define (store-root path) (build-path (workspace-root path) ".stringbed" "extensions"))
(define (safe-relative value)
  (unless (and (string? value) (positive? (string-length value))
               (relative-path? value)
               (for/and ([part (explode-path value)]) (path? part)))
    (error 'extension "expected a relative path without traversal: ~e" value)) value)
;; A bundle is a complete directory, including non-Racket resources. No implicit
;; exclusions: users declare a small portable bundle, not a repository checkout.
(define (reject-symlink-ancestors path)
  (for/fold ([prefix #f]) ([part (explode-path (path->complete-path path))])
    (define next (if prefix (build-path prefix part) part))
    (when (link-exists? next) (error 'extension "symlink path is forbidden: ~a" next)) next))
(define (bundle-files root)
  (reject-symlink-ancestors root)
  (when (link-exists? root) (error 'extension "symlink bundle root is forbidden"))
  (unless (directory-exists? root) (error 'extension "missing bundle ~a" root))
  (define (walk dir)
    (append-map
     (lambda (p)
       (cond [(link-exists? p) (error 'extension "symlink in bundle: ~a" p)]
             [(directory-exists? p) (walk p)]
             [(file-exists? p) (list (cons (path->string (find-relative-path root p)) (file->bytes p)))]
             [else (error 'extension "unsupported bundle entry: ~a" p)]))
     (directory-list dir #:build? #t)))
  (sort (walk root) string<? #:key car))
(define (manifest files)
  (for/list ([f files]) (list (car f) (bytes-length (cdr f)) (bytes-digest (cdr f)))))
(define (datum-bytes datum) (call-with-output-bytes (lambda (out) (write datum out) (newline out))))
(define (bundle-digest files) (bytes-digest (datum-bytes (manifest files))))
(define (empty-lock) (hash 'schema 1 'racket-version (version) 'api-sha256 (bytes-digest (file->bytes api-path)) 'extensions (hash)))
(define (read-extension-lock path)
  (define file (extension-lock-path path))
  (reject-symlink-ancestors file)
  (define lock (if (file-exists? file) (call-with-input-file file read-data) (empty-lock)))
  (unless (and (hash? lock) (equal? (hash-ref lock 'schema #f) 1)
               (hash? (hash-ref lock 'extensions #f)))
    (error 'extension "unsupported or malformed extension lock"))
  (for ([(id record) (in-hash (hash-ref lock 'extensions))])
    (unless (and (string? id) (hash? record)
                 (string? (hash-ref record 'sha256 #f))
                 (regexp-match? #px"^[a-f0-9]{64}$" (hash-ref record 'sha256)))
      (error 'extension "malformed extension lock entry"))
    (safe-relative (hash-ref record 'entry #f))) lock)
(define (pin-extension! path id bundle-root entry)
  (unless (and (string? id) (regexp-match? #px"^[A-Za-z0-9_-]+$" id))
    (error 'extension "extension id must contain letters, numbers, _ or -"))
  (safe-relative entry)
  (define root (simplify-path (path->complete-path bundle-root) #f))
  (define files (bundle-files root))
  (unless (assoc entry files) (error 'extension "entry is not a bundle file: ~a" entry))
  (define digest (bundle-digest files))
  (call-with-workspace-lock
   path
   (lambda ()
     (define store (store-root path))
     (reject-symlink-ancestors store)
     (reject-symlink-ancestors (extension-lock-path path))
     (make-directory* store)
     (define snapshot (build-path store digest))
     (cond [(directory-exists? snapshot)
            (unless (equal? digest (bundle-digest (bundle-files snapshot)))
              (error 'extension "existing snapshot was modified"))]
           [else
            (define temp (make-temporary-file "snapshot~a" 'directory store))
            (dynamic-wind
              void
              (lambda ()
                (for ([file files])
                  (define dest (build-path temp (car file)))
                  (make-directory* (path-only dest))
                  (call-with-output-file dest (lambda (out) (write-bytes (cdr file) out))))
                (unless (equal? digest (bundle-digest (bundle-files root)))
                  (error 'extension "bundle changed while snapshotting; retry"))
                (rename-file-or-directory temp snapshot))
              (lambda () (when (directory-exists? temp) (delete-directory/files temp))))])
     (define old (read-extension-lock path))
     (define record (hash 'sha256 digest 'entry entry 'source (path->string root)
                          'files (manifest files)))
     (define lock (hash-set (empty-lock) 'extensions
                            (hash-set (hash-ref old 'extensions) id record)))
     (make-directory* (path-only (extension-lock-path path)))
     (atomic-write-bytes (extension-lock-path path) (datum-bytes lock))
     record)))
;; This digest names the pre-Emacs API. The struct ABI and existing validation
;; semantics are unchanged; JSON null/finite numbers and safe digit-leading
;; attribute segments only widen accepted input.
;; Do not accept arbitrary historical digests or silently rewrite an old lock.
(define compatible-api-sha256 '("35f0a8fcec9fbddffa65b39896a373b53354d985952ddc892b3deb5738a4ea32"))
(define (verify-extension-lock! path)
  (define lock (read-extension-lock path))
  (unless (or (equal? (hash-ref lock 'api-sha256 #f) (bytes-digest (file->bytes api-path)))
              (member (hash-ref lock 'api-sha256 #f) compatible-api-sha256))
    (error 'extension "Stringbed extension API changed; explicitly re-pin extensions"))
  (unless (equal? (hash-ref lock 'racket-version #f) (version))
    (error 'extension "Racket version changed; explicitly re-pin extensions"))
  (for ([(id record) (in-hash (hash-ref lock 'extensions))])
    (define snapshot (build-path (store-root path) (hash-ref record 'sha256)))
    (define files (bundle-files snapshot))
    (unless (and (equal? (hash-ref record 'sha256) (bundle-digest files))
                 (equal? (hash-ref record 'files #f) (manifest files))
                 (assoc (hash-ref record 'entry) files))
      (error 'extension "snapshot integrity failure: ~a" id))) lock)
;; This is trusted Racket code, NOT a sandbox. Every load gets fresh module
;; instances; the public API instance is shared so form predicates still work.
(define (load-locked-extensions path #:export [export 'forms] #:on-load [on-load (lambda (_path _forms) (void))])
  (define lock (verify-extension-lock! path))
  (define ns (make-base-namespace))
  (namespace-attach-module (namespace-anchor->namespace anchor) api-path ns)
  (parameterize ([current-namespace ns]
                 [current-library-collection-paths
                  (cons (simplify-path (build-path (path-only api-path) 'up)) (current-library-collection-paths))])
    (append-map
     (lambda (id)
       (define record (hash-ref (hash-ref lock 'extensions) id))
       (define result (dynamic-require
                       (build-path (store-root path) (hash-ref record 'sha256) (hash-ref record 'entry)) export))
       (unless (list? result) (error 'extension "~a export must be a list" export))
       (on-load (build-path (store-root path) (hash-ref record 'sha256) (hash-ref record 'entry)) result)
       result)
     (sort (hash-keys (hash-ref lock 'extensions)) string<?))))

(define (load-trusted-extension path #:export [export 'forms])
  (define ns (make-base-namespace))
  (namespace-attach-module (namespace-anchor->namespace anchor) api-path ns)
  (parameterize ([current-namespace ns]
                 [current-library-collection-paths
                  (cons (simplify-path (build-path (path-only api-path) 'up)) (current-library-collection-paths))])
    (dynamic-require (path->complete-path path) export)))

;; Paths are returned only after verifying every locked bundle, sorted by id.
(define (locked-extension-paths path)
  (define lock (verify-extension-lock! path))
  (for/list ([id (sort (hash-keys (hash-ref lock 'extensions)) string<?)])
    (define record (hash-ref (hash-ref lock 'extensions) id))
    (build-path (store-root path) (hash-ref record 'sha256) (hash-ref record 'entry))))
