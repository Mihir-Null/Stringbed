#lang racket/base
(require rackunit racket/file racket/runtime-path racket/path json
         "../stringbed/nix-query.rkt" "../stringbed/operations.rkt")
(define-runtime-path flake "fixtures/query-types/flake.nix")
(define-runtime-path lock "../flake.lock")
(define directory (make-temporary-file "stringbed-query-types-~a" 'directory))
(dynamic-wind void
  (lambda ()
    (copy-file flake (build-path directory "flake.nix"))
    (copy-file lock (build-path directory "flake.lock"))
    (call-with-output-file (build-path directory "target.json")
      (lambda (out) (write-json (hash 'target "home" 'name "fixture" 'system "x86_64-linux") out)))
    (parameterize ([current-process-timeout 60])
      (test-case "pinned native types expose controls and keep unavailable defaults inspectable"
        (for ([name '(boolean choice integer number nullable list structured anything)]
              [kind '("boolean" "enum" "integer" "number" "nullable" "list" "structured" "advanced")])
          (define option (option-detail directory (format "probe.~a" name)))
          (check-equal? (hash-ref (hash-ref option 'control) 'kind) kind))
        (define options (discover-options directory "probe."))
        (check-equal? (length options) 9)
        (check-equal? (hash-ref (hash-ref (option-detail directory "probe.unavailable") 'default) 'unavailable)
                      "value cannot be evaluated in this context")
        (check-equal? (hash-ref (hash-ref (option-detail directory "probe.choice") 'control) 'choices) '("one" "two")))
      (test-case "native validation rejects wrong scalar, enum and nested values"
        (for ([path '("probe.boolean" "probe.choice" "probe.list" "probe.structured")]
              [value (list 5 "three" '(1 "bad") (hash 'a 5))])
          (check-false (hash-ref (validate-option-value directory path value) 'valid)))
        (for ([path '("probe.boolean" "probe.choice" "probe.nullable" "probe.list" "probe.structured" "probe.number")]
              [value (list #t "two" 'null '(1 2) (hash 'a #t) 1.5)])
          (check-true (hash-ref (validate-option-value directory path value) 'valid)))
        (check-false (hash-ref (validate-option-value directory "invented.path" #t) 'exists))
        (check-true (hash-ref (validate-option-value directory "probe.anything" 7) 'valid))
        (check-true (hash-ref (validate-option-value directory "probe.anything" '(1 "two")) 'valid)))
      (test-case "real package lookup provides an existing absolute Nix source location"
        (define package (lookup-package directory "ripgrep"))
        (check-equal? (hash-ref package 'attribute) "ripgrep")
        (define source (regexp-replace #px":[0-9]+$" (hash-ref package 'position) ""))
        (check-true (absolute-path? source))
        (check-true (file-exists? source)))))
  (lambda () (delete-directory/files directory)))
