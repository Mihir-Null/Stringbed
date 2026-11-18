#lang racket/base
(require rackunit racket/file racket/runtime-path
         "../stringbed/model.rkt" "../stringbed/protocol.rkt" "../stringbed/operations.rkt")
(define-runtime-path input-lock "../flake.lock")
(test-case "builder native preview checks emitted definitions against actual pinned NixOS options"
  (define dir (make-temporary-file "builder-native-~a" 'directory))
  (dynamic-wind void
    (lambda ()
      (define path (build-path dir "system.sbd"))
      (define workspace
        (hash-set (new-workspace "builder-native" 'nixos) 'inputs
                  (hash 'nixpkgs "github:NixOS/nixpkgs/nixos-unstable")))
      (display-to-file (workspace-text workspace) path)
      (define backend (make-backend))
      (define opened (protocol-handle backend (hash 'v 1 'id 1 'method "open" 'params (hash 'path (path->string path)))))
      (check-false (hash-has-key? opened 'error))
      (define (request id method params)
        (define reply (protocol-handle backend (hash 'v 1 'id id 'method method 'params params
                                                     'session (hash-ref opened 'session) 'revision 0)))
        (check-false (hash-has-key? reply 'error) (format "~s" reply))
        (hash-ref reply 'result))
      (request 2 "context" (hash 'lockFile (path->string input-lock)))
      (define (spec value)
        (hash 'schema 1 'kind "git-native" 'description "" 'parameters '()
              'assignments (list (hash 'path "programs.git.enable" 'value (hash 'literal value)))
              'compositions '() 'note "" 'docs '() 'sources '()))
      (parameterize ([current-process-timeout 75])
        (define good (request 3 "builder/preview" (hash 'spec (spec #t) 'scope "system" 'validate #t)))
        (check-equal? (hash-ref (hash-ref good 'nativeValidation) 'state) "type-valid"
                      (format "~s" (hash-ref good 'nativeValidation)))
        (define bad (request 4 "builder/preview" (hash 'spec (spec 5) 'scope "system" 'validate #t)))
        (check-equal? (hash-ref (hash-ref bad 'nativeValidation) 'state) "invalid")
        (check-equal? (hash-ref (car (hash-ref (hash-ref bad 'nativeValidation) 'results)) 'field) "definitions.0.value"))
      (check-equal? (hash-ref (request 5 "workspace" (hash)) 'nodes) '()))
    (lambda () (delete-directory/files dir))))
