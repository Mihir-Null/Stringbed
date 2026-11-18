#lang racket/base
(require rackunit racket/file racket/port "../stringbed/model.rkt" "../stringbed/session.rkt" "../stringbed/tui.rkt" "../stringbed/ui-extension.rkt")
(module+ test
 (check-equal? (read-key (open-input-string "\u001b[A")) 'up)
 (check-equal? (read-key (open-input-string "j")) 'down)
 (check-equal? (read-key (open-input-string "")) 'quit)
 (define dir (make-temporary-file "tui~a" 'directory))
 (dynamic-wind void
  (lambda ()
   (define path (build-path dir "workspace.rktd"))
   (call-with-output-file path (lambda (o) (write (new-workspace "tui-test") o)))
   (define s (open-session path)) (define r (load-registry))
   (parameterize ([current-input-port (open-input-string "2\npackage\nfinder\nripgrep\n3\nfinder\nattribute\nfd\n4\nfinder\nshort note\n7\nq\n")]
                  [current-output-port (open-output-string)]) (run-tui s r))
   (check-equal? (hash-ref (hash-ref (node-by-id (session-workspace s) "finder") 'params) 'attribute) "fd")
   (check-equal? (hash-ref (node-by-id (session-workspace (open-session path)) "finder") 'note) "short note")
   (parameterize ([current-input-port (open-input-string "2\noption\ngit-setting\nprograms.git.enable\n#f\nq\n")]
                 [current-output-port (open-output-string)]) (run-menu s r))
   (check-equal? (hash-ref (node-by-id (session-workspace s) "git-setting") 'params)
                 (hash 'path "programs.git.enable" 'value #f))
   (check-true (regexp-match? #rx"> finder" (render-screen s 0 "" "detail" "ok")))
   (define p (plugin (hash) (hash) (hash 'package (lambda (s r id ask execute) (execute (list 'note id "custom editor"))))))
   (parameterize ([current-input-port (open-input-string "3\nfinder\nq\n")]
                  [current-output-port (open-output-string)]) (run-menu s r p))
   (check-equal? (hash-ref (node-by-id (session-workspace s) "finder") 'note) "custom editor"))
  (lambda () (delete-directory/files dir))))
