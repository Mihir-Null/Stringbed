#lang racket/base
(require racket/file racket/path racket/list racket/string racket/format json
         "model.rkt" "compiler.rkt" "nix-query.rkt" "operations.rkt")
(provide prepare-query-context context-search-packages context-lookup-package
         context-discover-options context-option-detail context-validate-option
         context-explain-option context-evaluate context-build
         (struct-out exn:fail:query))
(struct exn:fail:query exn:fail (code field) #:transparent)
(define (query-error code field fmt . values)
  (raise (exn:fail:query (apply format fmt values) (current-continuation-marks) code field)))
(define (json-bytes value) (string->bytes/utf-8 (jsexpr->string value)))
(define (json-file path)
  (define (normalize value)
    (cond [(hash? value) (for/hash ([(key item) (in-hash value)]) (values key (normalize item)))]
          [(list? value) (map normalize value)]
          [else value]))
  (normalize (call-with-input-file path read-json)))
(define (digest-text text) (bytes-digest (string->bytes/utf-8 text)))
(define (directory-digest directory)
  (digest-text
   (apply string-append
    (for/list ([path (sort (filter file-exists? (find-files (lambda (_) #t) directory))
                          string<? #:key path->string)])
      (format "~a\n~a\n" (find-relative-path directory path) (bytes-digest (file->bytes path)))))))
(define (context-root path)
  (define p (path->complete-path path))
  (build-path (path-only p) ".stringbed" "query" (path->string (file-name-from-path p))))
(define prepare-semaphore (make-semaphore 1))
(define (prepare-query-context workspace registry workspace-path
                               #:lock-file [supplied-lock #f] #:initialize? [initialize? #f])
  ;; Async clients can request several catalogues at once. Serialize projection
  ;; preparation inside the process; expensive queries themselves stay parallel.
  (call-with-semaphore prepare-semaphore
    (lambda ()
      (prepare-query-context/locked workspace registry workspace-path
                                    #:lock-file supplied-lock #:initialize? initialize?))))
(define (prepare-query-context/locked workspace registry workspace-path
                                      #:lock-file supplied-lock #:initialize? initialize?)
  ;; The input identity survives node/note edits. A new input declaration gets a
  ;; new pin; an existing identity is never silently updated or replaced.
  (define input-id (digest-text (workspace-text (hash-ref workspace 'inputs))))
  (define source-id (digest-text (workspace-text workspace)))
  (define projection-id
    (digest-text
     (string-append (compile-flake workspace)
                    (compile-module workspace registry)
                    (apply string-append
                     (for/list ([user (sort (hash-keys (workspace-homes workspace)) symbol<?)])
                       (compile-module workspace registry #:scope (string-append "home:" (symbol->string user))))))))
  (define root (context-root workspace-path))
  (define pin-dir (build-path root "pins" input-id))
  (define pinned-lock (build-path pin-dir "flake.lock"))
  (define previous-pin (build-path root "pins" "current.json"))
  (define base (hash 'state "needs-lock" 'workspace-sha256 source-id 'input-sha256 input-id
                     'system (hash-ref workspace 'system)
                     'package-catalogue "pinned-upstream-nixpkgs"
                     'projection-sha256 projection-id 'directory 'null 'lock-sha256 'null))
  (cond
    [(and (not initialize?) (not supplied-lock) (not (file-exists? pinned-lock))) base]
    [else
     (make-directory* root)
     (call-with-workspace-lock (build-path root "prepare")
       (lambda ()
         (when (and supplied-lock (file-exists? pinned-lock)
                    (not (equal? (file->bytes supplied-lock) (file->bytes pinned-lock))))
           (query-error "pin-conflict" "lock-file" "These inputs already have a different pin. Existing pins are never overwritten; change inputs explicitly to create a new context."))
         (unless (file-exists? pinned-lock)
           ;; Seed changed declarations from the previous lock. Nix then resolves
           ;; only changed/new inputs instead of advancing unrelated inputs.
           (define inherited-lock
             (and (not supplied-lock) (file-exists? previous-pin)
                  (let ([previous-id (hash-ref (json-file previous-pin) 'input-sha256 #f)])
                    (unless (and (string? previous-id) (regexp-match? #px"^[0-9a-f]{64}$" previous-id))
                      (query-error "invalid-pin" "inputs" "The prior pin record is invalid; preserve it for inspection."))
                    (define path (build-path root "pins" previous-id "flake.lock"))
                    (and (file-exists? path) path))))
           (define temp (make-temporary-file "prepare-~a" 'directory root))
           (dynamic-wind void
             (lambda ()
               (define export (build-path temp "export"))
               (export-workspace workspace registry export #:lock-file (or supplied-lock inherited-lock))
               (unless supplied-lock (nix-operation 'lock export))
               (unless (file-exists? (build-path export "flake.lock"))
                 (query-error "lock-failed" "inputs" "Nix did not create a flake.lock."))
               (define lock-data (json-file (build-path export "flake.lock")))
               (unless (and (hash? lock-data) (hash-has-key? lock-data 'nodes) (hash-has-key? lock-data 'version))
                 (query-error "invalid-lock" "inputs" "The selected lock is not a Nix flake.lock."))
               (make-directory* pin-dir)
               (atomic-write-bytes pinned-lock (file->bytes (build-path export "flake.lock"))))
             (lambda () (when (directory-exists? temp) (delete-directory/files temp)))))
         (define lock-id (bytes-digest (file->bytes pinned-lock)))
         (atomic-write-bytes previous-pin (json-bytes (hash 'input-sha256 input-id)))
         (define key (digest-text (string-append source-id projection-id lock-id)))
         (define context-dir (build-path root "contexts" key))
         (define export-dir (build-path context-dir "export"))
         (define receipt (build-path context-dir "context.json"))
         (cond
           [(file-exists? receipt)
            (define previous (json-file receipt))
            (unless (equal? (hash-ref previous 'export-sha256 #f) (directory-digest export-dir))
              (query-error "context-modified" "context" "The cached Nix export changed externally; preserve and remove the affected query context before retrying."))
            previous]
           [else
            (make-directory* (build-path root "contexts"))
            (define temp (make-temporary-file "context-~a" 'directory (build-path root "contexts")))
            (dynamic-wind void
              (lambda ()
                (define temp-export (build-path temp "export"))
                (export-workspace workspace registry temp-export #:lock-file pinned-lock)
                (define ready
                  (hash-set* base 'state "ready" 'directory (path->string export-dir)
                             'lock-sha256 lock-id 'export-sha256 (directory-digest temp-export)))
                (atomic-write-bytes (build-path temp "context.json") (json-bytes ready))
                (rename-file-or-directory temp context-dir)
                ready)
              (lambda () (when (directory-exists? temp) (delete-directory/files temp))))])))]))
(define (ready-directory context)
  (unless (equal? (hash-ref context 'state #f) "ready")
    (query-error "needs-lock" "inputs" "Prepare the discovery context to pin the workspace's inputs first."))
  (define directory (hash-ref context 'directory))
  (unless (and (directory-exists? directory)
               (equal? (hash-ref context 'export-sha256 #f) (directory-digest directory)))
    (query-error "context-modified" "context" "The query export is missing or changed; prepare a fresh context."))
  directory)
(define (cached context key thunk #:package? [package? #f])
  (define directory (ready-directory context))
  ;; Package queries use the pinned input's legacyPackages, not configured
  ;; overlays. Their cache survives notes/selections while remaining separated
  ;; by exact input lock and platform. Option schemas remain projection-bound.
  (define cache-directory
    (if package?
        (simplify-path (build-path directory 'up 'up 'up "package-cache-v2"
                                  (hash-ref context 'lock-sha256) (digest-text (hash-ref context 'system))))
        (build-path (path-only (string->path directory)) "cache-v2")))
  (define cache-file (build-path cache-directory (string-append (digest-text (format "~s" key)) ".json")))
  (cond [(file-exists? cache-file) (values (json-file cache-file) #t)]
        [else
         (define result (parameterize ([current-process-timeout (min 120 (current-process-timeout))]) (thunk directory)))
         (make-directory* cache-directory)
         (atomic-write-bytes cache-file (json-bytes result))
         (values result #f)]))
(define (context-lookup-package context attribute)
  (define-values (item hit?) (cached context (list 'package attribute)
    (lambda (dir) (lookup-package dir attribute)) #:package? #t))
  (when (eq? item 'null)
    (query-error "unknown-package" "attribute" "No package named ~a exists in this pinned package set." attribute))
  (hash-set* item 'context context 'cached hit?))
(define (context-search-packages context term #:mode [mode 'search])
  (unless (member mode '(search exact)) (query-error "invalid-search-mode" "mode" "Expected search or exact."))
  (unless (and (string? term) (positive? (string-length (string-trim term))))
    (query-error "empty-search" "term" "Enter a package name or description."))
  (cond
    [(eq? mode 'exact)
     (define item (context-lookup-package context term))
     (hash 'items (list (hash-remove (hash-remove item 'context) 'cached))
           'context context 'cached (hash-ref item 'cached))]
    [else
     (define-values (items hit?)
       (cached context (list 'packages term)
         (lambda (directory)
           ;; Nix searches attribute, package name and description. Escape user
           ;; text as a literal regular expression; advanced regex stays CLI-only.
           (define found (search-packages directory (regexp-quote term) #:regex? #t))
           (unless (hash? found) (query-error "invalid-result" "term" "Nix package search returned an invalid result."))
           (for/list ([key (take (sort (hash-keys found) symbol<?) (min 200 (hash-count found)))])
             (define item (hash-ref found key))
             (define attribute (regexp-replace #px"^legacyPackages\\.[^.]+\\." (symbol->string key) ""))
             (hash-set* item 'attribute attribute 'homepage (hash-ref item 'homepage '())
                        'position (hash-ref item 'position "")))) #:package? #t))
     (hash 'items items 'context context 'cached hit? 'limit 200)]))
(define (context-discover-options context term #:scope [scope #f])
  (define-values (items hit?)
    (cached context (list 'options scope term) (lambda (dir) (discover-options dir term #:scope scope))))
  (hash 'items items 'context context 'cached hit? 'limit 200))
(define (context-option-detail context path #:scope [scope #f])
  (define-values (item hit?)
    (cached context (list 'option scope path) (lambda (dir) (option-detail dir path #:scope scope))))
  (when (eq? item 'null)
    (query-error "unknown-option" "path" "~a is not a declared option in scope ~a. Search options for this scope." path (or scope "default")))
  (hash-set* item 'context context 'cached hit?))
(define (context-validate-option context path value #:scope [scope #f])
  (define item (context-option-detail context path #:scope scope))
  (define directory (ready-directory context))
  (define result (validate-option-value directory path value #:scope scope))
  (unless (hash-ref result 'exists #f)
    (query-error "unknown-option" "path" "~a is not a declared option in this scope." path))
  (unless (hash-ref result 'valid #f)
    (query-error "invalid-option-value" "value" "~a expects ~a. Correct the value; the draft has not changed." path (hash-ref item 'type "the declared Nix type")))
  (hash 'valid #t 'option item 'context context
        'validation "Nix option type merge; full workspace evaluation is separate."))
(define (context-explain-option context path #:scope [scope #f])
  (define-values (item hit?)
    (cached context (list 'evaluated scope path) (lambda (dir) (explain-option dir path #:scope scope))))
  (hash-set* item 'context context 'cached hit? 'freshness "evaluated-for-context"))
(define (context-evaluate context)
  (nix-operation 'check (ready-directory context))
  (hash 'state "evaluated" 'context context 'activation #f))
(define (context-build context)
  (nix-operation 'build (ready-directory context))
  (hash 'state "built" 'context context 'activation #f))
