#lang racket/base
(require racket/system racket/port racket/file racket/string json)
(provide nix-operation inspect-machine current-runner current-process-timeout current-output-limit
         validate-ssh-target shell-quote target-command)
(define current-process-timeout (make-parameter 900))
(define current-output-limit (make-parameter (* 8 1024 1024)))
;; All commands use argv locally. Remote SSH necessarily uses a shell; every
;; dynamic word is single-quoted by target-command. No command output is logged.
(define (bounded-run program args)
  (define exe (find-executable-path program))
  (unless exe (error 'process "~a is not installed" program))
  (define custodian (make-custodian))
  (dynamic-wind void
    (lambda ()
      (parameterize ([current-custodian custodian]
                     [current-subprocess-custodian-mode 'kill]
                     [subprocess-group-enabled #t])
        (define-values (proc out in err) (apply subprocess #f #f #f exe args))
        (close-output-port in)
        (define (capture port)
          (define dest (open-output-bytes))
          (define size 0)
          (define overflow? #f)
          (define t
            (thread (lambda ()
              (let loop ()
                (define b (read-bytes 8192 port))
                (unless (eof-object? b)
                  (set! size (+ size (bytes-length b)))
                  (if (<= size (current-output-limit)) (write-bytes b dest) (set! overflow? #t))
                  (loop))))))
          (values t (lambda () (values (get-output-bytes dest) overflow?))))
        (define-values (stdout-thread stdout-result) (capture out))
        (define-values (stderr-thread stderr-result) (capture err))
        (unless (sync/timeout (current-process-timeout) proc)
          (subprocess-kill proc #t)
          (error 'process "~a timed out; execution outcome may be unknown" program))
        ;; A descendant retaining the pipe must not make collection unbounded.
        (unless (and (sync/timeout 5 stdout-thread) (sync/timeout 5 stderr-thread))
          (error 'process "~a output collection timed out" program))
        (define-values (stdout too-large?) (stdout-result))
        (unless (zero? (subprocess-status proc))
          (error 'process "~a exited with status ~a (output withheld; may contain secrets)" program (subprocess-status proc)))
        (when too-large? (error 'process "~a output exceeded limit" program))
        (bytes->string/utf-8 stdout #\?)))
    (lambda () (custodian-shutdown-all custodian))))
(define current-runner (make-parameter bounded-run))
(define (validate-ssh-target target)
  (unless (and (string? target) (regexp-match? #px"^(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9_.-]*$" target))
    (error 'ssh "expected user@hostname or hostname")) target)
(define (shell-quote s)
  (unless (and (string? s) (not (regexp-match? #rx"\u0000" s))) (error 'shell "invalid argument"))
  (string-append "'" (string-replace s "'" "'\"'\"'") "'"))
(define (target-command target program args)
  (if target
      ((current-runner) "ssh"
       (list "-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "--" (validate-ssh-target target)
             (string-join (map shell-quote (cons program args)) " ")))
      ((current-runner) program args)))
(define (nix-operation operation directory)
  (define dir (path->string (path->complete-path directory)))
  (unless (file-exists? (build-path dir "flake.nix")) (error 'nix "no exported flake in ~a" dir))
  (unless (or (eq? operation 'lock) (file-exists? (build-path dir "flake.lock")))
    (error 'nix "run lock first; check/build require an existing flake.lock"))
  (define ref (string-append "path:" dir))
  ((current-runner) "nix"
   (append '("--extra-experimental-features" "nix-command flakes")
    (case operation
      [(lock) (list "flake" "lock" ref)]
      [(check) (list "flake" "check" "--no-build" "--all-systems" "--no-update-lock-file" ref)]
      [(build)
       (define metadata (call-with-input-file (build-path dir "target.json") read-json))
       (define system (hash-ref metadata 'system #f))
       (unless (member system '("x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin")) (error 'nix "unsupported export target system"))
       (list "build" "--no-link" "--no-update-lock-file" (string-append ref "#packages." system ".default"))]
      [else (error 'nix "unknown operation")]))))
(define inspection-script
  "printf 'host='; hostname; printf 'kernel='; uname -sr; printf 'active-system='; readlink /run/current-system 2>/dev/null || true; printf 'booted-system='; readlink /run/booted-system 2>/dev/null || true")
(define (inspect-machine [target #f])
  (target-command target "sh" (list "-c" inspection-script)))
