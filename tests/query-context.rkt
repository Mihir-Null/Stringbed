#lang racket/base
(require rackunit racket/file racket/path racket/list racket/string json
         "../stringbed/query-context.rkt" "../stringbed/operations.rkt"
         "../stringbed/model.rkt" "../stringbed/session.rkt")
(define r (load-registry))
(define (fixture proc)
  (define dir (make-temporary-file "stringbed-context-~a" 'directory))
  (dynamic-wind void
    (lambda ()
      (define source (build-path dir "review.sbd"))
      (define w (new-workspace "review"))
      (display-to-file (workspace-text w) source)
      (define lock (build-path dir "flake.lock"))
      (display-to-file "{\"version\":7,\"nodes\":{}}" lock)
      (proc dir source w lock))
    (lambda () (delete-directory/files dir))))
(test-case "context preparation does not rewrite source or silently initialize/update inputs"
  (fixture
   (lambda (dir source w lock)
     (define original (file->bytes source))
     (define called? #f)
     (parameterize ([current-runner (lambda args (set! called? #t) (error 'unexpected "Nix should not run"))])
       (check-equal? (hash-ref (prepare-query-context w r source) 'state) "needs-lock")
       (define context (prepare-query-context w r source #:lock-file lock))
       (check-equal? (hash-ref context 'state) "ready")
       (check-equal? (file->bytes source) original)
       (check-equal? (file->bytes (build-path (hash-ref context 'directory) "flake.lock")) (file->bytes lock))
       (define new-context (prepare-query-context (hash-set w 'name "renamed") r source))
       (check-not-equal? (hash-ref context 'directory) (hash-ref new-context 'directory))
       (check-equal? (hash-ref context 'lock-sha256) (hash-ref new-context 'lock-sha256))
       (check-false called?)
       (check-equal? context (prepare-query-context w r source))
       (display-to-file "{\"version\":7,\"nodes\":{\"changed\":{}}}" lock #:exists 'truncate)
       (check-exn (lambda (e) (and (exn:fail:query? e) (equal? (exn:fail:query-code e) "pin-conflict")))
                  (lambda () (prepare-query-context w r source #:lock-file lock)))))))
(test-case "initial lock is explicit and saved once; changing declared input requires a fresh context"
  (fixture
   (lambda (dir source w lock)
     (define count 0)
     (parameterize ([current-runner
                    (lambda (program args)
                      (set! count (add1 count))
                      (check-equal? (take-right args 3) (list "flake" "lock" (last args)))
                      (define export (substring (last args) 5))
                      (copy-file lock (build-path export "flake.lock")) "")])
       (define context (prepare-query-context w r source #:initialize? #t))
       (check-equal? (hash-ref context 'state) "ready")
       (prepare-query-context w r source #:initialize? #t)
       (check-equal? count 1)
       (define changed (hash-set w 'inputs (hash-set (hash-ref w 'inputs) 'nixpkgs "github:NixOS/nixpkgs/other")))
       (check-equal? (hash-ref (prepare-query-context changed r source) 'state) "needs-lock")
       (parameterize ([current-runner
                       (lambda (program args)
                         (define inherited (build-path (substring (last args) 5) "flake.lock"))
                         (check-true (file-exists? inherited))
                         (check-equal? (file->bytes inherited) (file->bytes lock))
                         "")])
         (check-equal? (hash-ref (prepare-query-context changed r source #:initialize? #t) 'state) "ready"))))))
(test-case "literal name/description package searches cache upstream metadata and preserve canonical attribute"
  (fixture
   (lambda (dir source w lock)
     (define context (prepare-query-context w r source #:lock-file lock))
     (define calls 0)
     (parameterize ([current-runner
                    (lambda (program args)
                      (set! calls (add1 calls))
                      (check-not-false (member "--no-update-lock-file" args))
                      (check-not-false (member "search" args))
                      (check-equal? (last args) "fast text search")
                      "{\"legacyPackages.x86_64-linux.ripgrep\":{\"pname\":\"ripgrep\",\"description\":\"fast text search\",\"version\":\"15\"}}")])
       (define result (context-search-packages context "fast text search"))
       (check-false (hash-ref result 'cached))
       (check-equal? (hash-ref (car (hash-ref result 'items)) 'attribute) "ripgrep")
       (check-true (hash-ref (context-search-packages context "fast text search") 'cached))
       (define changed (prepare-query-context (hash-set w 'name "newname") r source))
       (check-true (hash-ref (context-search-packages changed "fast text search") 'cached))
       (check-equal? calls 1))
     (parameterize ([current-runner (lambda (program args) "null")])
       (check-exn (lambda (e) (and (exn:fail:query? e) (equal? (exn:fail:query-field e) "attribute")))
                  (lambda () (context-search-packages context "missing" #:mode 'exact)))))))
(test-case "option errors identify path/value; native merge validates containers beyond outer type"
  (fixture
   (lambda (dir source w lock)
     (define context (prepare-query-context w r source #:lock-file lock))
     (parameterize ([current-runner
                    (lambda (program args)
                      (define expr (last args))
                      (cond [(string-contains? expr "candidate =")
                             (check-true (string-contains? expr "lib.evalModules"))
                             (check-true (string-contains? expr "builtins.deepSeq"))
                             "{\"exists\":true,\"valid\":false,\"type\":\"boolean\"}"]
                            [(string-contains? expr "programs")
                             "{\"path\":\"programs.git.enable\",\"type\":\"boolean\",\"control\":{\"kind\":\"boolean\"},\"description\":\"Enable git\",\"default\":false,\"declarations\":[]}"]
                            [else "null"]))])
       (check-exn (lambda (e) (and (exn:fail:query? e) (equal? (exn:fail:query-code e) "unknown-option")
                                 (equal? (exn:fail:query-field e) "path")))
                  (lambda () (context-option-detail context "invented.option")))
       (check-exn (lambda (e) (and (exn:fail:query? e) (equal? (exn:fail:query-code e) "invalid-option-value")
                                 (equal? (exn:fail:query-field e) "value")))
                  (lambda () (context-validate-option context "programs.git.enable" 5)))))))
(test-case "query snapshots detect external mutation before serving cached metadata"
  (fixture
   (lambda (dir source w lock)
     (define context (prepare-query-context w r source #:lock-file lock))
     (display-to-file "# changed" (build-path (hash-ref context 'directory) "configuration.nix") #:exists 'truncate)
     (check-exn (lambda (e) (and (exn:fail:query? e) (equal? (exn:fail:query-code e) "context-modified")))
                (lambda () (context-discover-options context "git")))
     (check-exn exn:fail:query? (lambda () (prepare-query-context w r source))))))
(test-case "evaluate and build issue no activation and retain locked context"
  (fixture
   (lambda (dir source w lock)
     (define context (prepare-query-context w r source #:lock-file lock))
     (define seen '())
     (parameterize ([current-runner (lambda (program args) (set! seen (cons args seen)) "")])
       (check-equal? (hash-ref (context-evaluate context) 'state) "evaluated")
       (check-equal? (hash-ref (context-build context) 'state) "built"))
     (check-true (andmap (lambda (args) (not (not (member "--no-update-lock-file" args)))) seen))
     (check-not-false (member "--no-link" (car seen)))
     (check-false (ormap (lambda (args) (member "switch" args)) seen)))))

(test-case "cooperative cancellation releases first-pin lock and temporary export"
  (fixture
   (lambda (dir source w lock)
     (define started (make-semaphore))
     (define worker
       (thread
        (lambda ()
          (with-handlers ([exn:break? void])
            (parameterize ([current-runner (lambda args (semaphore-post started) (sync never-evt))])
              (prepare-query-context w r source #:initialize? #t))))))
     (semaphore-wait started)
     (break-thread worker)
     (check-not-false (sync/timeout 5 worker))
     (check-false (directory-exists? (build-path dir ".stringbed" "query" "review.sbd" "prepare.lock")))
     (check-equal? (hash-ref (prepare-query-context w r source #:lock-file lock) 'state) "ready"))))

(test-case "concurrent catalogue requests share one preparation without lock races"
  (fixture
   (lambda (dir source w lock)
     (define started (make-semaphore))
     (define release (make-semaphore))
     (define results (make-channel))
     (define calls 0)
     (define (prepare)
       (channel-put results
         (with-handlers ([exn:fail? values])
           (parameterize ([current-runner
                           (lambda (program args)
                             (set! calls (add1 calls))
                             (semaphore-post started)
                             (semaphore-wait release)
                             (copy-file lock (build-path (substring (last args) 5) "flake.lock"))
                             "")])
             (prepare-query-context w r source #:initialize? #t)))))
     (thread prepare)
     (semaphore-wait started)
     (thread prepare)
     (semaphore-post release)
     (define a (channel-get results))
     (define b (channel-get results))
     (check-true (hash? a))
     (check-true (hash? b))
     (check-equal? a b)
     (check-equal? calls 1))))
