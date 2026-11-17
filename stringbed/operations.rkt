#lang racket/base
(require racket/system racket/port racket/file racket/string)
(provide nix-operation inspect-machine current-runner)
;; Injectable argv runner; never construct a local shell command.
(define current-runner
  (make-parameter
   (lambda (program args)
     (define exe (find-executable-path program))
     (unless exe (error 'process "~a is not installed" program))
     (define output (open-output-string))
     (define ok? (parameterize ([current-output-port output] [current-error-port output])
                   (apply system* exe args)))
     (unless ok? (error 'process "~a failed:\n~a" program (get-output-string output)))
     (get-output-string output))))
(define (nix-operation operation directory)
  (define dir (path->string (path->complete-path directory)))
  (unless (file-exists? (build-path dir "flake.nix")) (error 'nix "no exported flake in ~a" dir))
  (unless (or (eq? operation 'lock) (file-exists? (build-path dir "flake.lock")))
    (error 'nix "run lock first; check/build require an existing flake.lock"))
  (define ref (string-append "path:" dir))
  (define flags '("--extra-experimental-features" "nix-command flakes"))
  ((current-runner) "nix"
   (append flags
    (case operation
      [(lock) (list "flake" "lock" ref)]
      [(check) (list "flake" "check" "--no-build" "--all-systems" "--no-update-lock-file" ref)]
      [(build) (list "build" "--no-link" "--no-update-lock-file" (string-append ref "#default"))]
      [else (error 'nix "unknown operation")]))))
(define inspection-script
  "printf 'host='; hostname; printf 'kernel='; uname -sr; printf 'active-system='; readlink /run/current-system 2>/dev/null || true; printf 'booted-system='; readlink /run/booted-system 2>/dev/null || true")
(define (inspect-machine [target #f])
  (if target
      (begin
        (unless (regexp-match? #px"^(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9_.-]*$" target)
          (error 'ssh "expected user@hostname or hostname"))
        ((current-runner) "ssh" (list "-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "--" target inspection-script)))
      ((current-runner) "sh" (list "-c" inspection-script))))
