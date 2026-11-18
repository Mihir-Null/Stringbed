#lang racket/base
(require racket/port racket/string racket/list racket/system
         "model.rkt" "session.rkt" "extension.rkt" "ui-extension.rkt")
(provide run-tui run-menu run-screen render-screen read-key)
(define (datum text) (call-with-input-string text read-data))
(define (prompt text)
  (display text) (display ": ") (flush-output)
  (define answer (read-line))
  (when (eof-object? answer) (error 'input "end of input")) answer)
(define (configure s r p id ask execute)
  (define n (node-by-id (session-workspace s) id))
  (define custom (hash-ref (plugin-tui-editors p) (hash-ref n 'kind) #f))
  (if custom (custom s r id ask execute)
      (let* ([d (hash-ref r (hash-ref n 'kind) (lambda () (error 'edit "load the missing extension first")))])
        (for ([f (form-fields d)]) (printf "  ~a (~a): ~a\n" (field-name f) (field-type f) (field-description f)))
        (define key (string->symbol (ask (format "Field (~a)" (string-join (map (lambda (f) (symbol->string (field-name f))) (form-fields d)) ", ")))))
        (define f (findf (lambda (f) (eq? key (field-name f))) (form-fields d)))
        (unless f (error 'edit "unknown field"))
        (define value (ask "Value"))
        (execute (list 'set id key (if (memq (field-type f) '(string attribute)) value (datum value)))))))
(define (run-menu s r [p empty-plugin] [reload #f])
  (define (execute command) (dispatch-ui! s r p command))
  (define (choice line)
    (when (equal? line "reload")
      (unless reload (error 'reload "No reload callback supplied"))
      (define-values (next-r next-p) (reload))
      (set! r next-r) (set! p next-p))
    (case (string->number line)
      [(1) (execute '(list))]
      [(2) (displayln (execute '(kinds))) (execute (list 'add (string->symbol (prompt "Form kind")) (prompt "Stable ID")))]
      [(3) (configure s r p (prompt "Node ID") prompt execute)]
      [(4) (execute (list 'note (prompt "Node ID") (prompt "Note")))]
      [(5) (execute (list 'why (prompt "Node ID")))]
      [(6) (execute '(undo))] [(7) (execute '(save))] [(8) (execute (list 'export (prompt "New output directory")))]
      [(9) (execute '(nix))] [(0) (execute (list 'remove (prompt "Node ID")))]
      [else (if (equal? line "diff") (draft-diff s) (if (equal? line "reload") "Extensions reloaded." (execute (datum line))))]))
  (displayln "Stringbed terminal editor — changes are drafts until saved. Commands and plugin commands are accepted as s-expressions.")
  (let loop ()
    (displayln (describe-workspace (session-workspace s)))
    (displayln "1 List  2 Add  3 Configure  4 Note  5 Why  6 Undo  7 Save  8 Export  9 Nix  0 Remove  diff  q Quit")
    (display "stringbed> ") (flush-output)
    (define line (read-line))
    (unless (or (eof-object? line) (member line '("q" "quit")))
      (with-handlers ([exn:fail? (lambda (e) (eprintf "~a\n" (exn-message e)))]) (displayln (choice line)))
      (loop))))
;; ANSI screen renderer is pure and strips control sequences from workspace text.
(define (visible text) (regexp-replace* #px"[\u0000-\u001f\u007f]" text " "))
(define (fit text width) (define s (visible text)) (substring s 0 (min (string-length s) (max 1 width))))
(define (render-screen s selected query detail status [width 100] [height 28])
  (define nodes (matching-nodes (session-workspace s) query))
  (define rows (max 3 (quotient (- height 9) 2)))
  (define start (max 0 (- selected (sub1 rows))))
  (define listing (take (drop nodes (min start (length nodes))) (min rows (- (length nodes) (min start (length nodes))))))
  (define lines
    (append
     (list (format "Stringbed | ~a | ~a | filter: ~a" (hash-ref (session-workspace s) 'name) (hash-ref (session-workspace s) 'target) query)
           "↑/↓ or j/k navigate | a add | e configure | n note | x remove | / search"
           "J/K detail scroll | w why | d diff | p Nix | g source | s save | u undo | o export | R reload | : command | q quit"
           (make-string (min width 100) #\─))
     (for/list ([n listing] [i (in-naturals start)])
       (format "~a ~a  [~a] ~a" (if (= i selected) ">" " ") (hash-ref n 'id) (hash-ref n 'kind) (hash-ref n 'note)))
     (list (make-string (min width 100) #\─))
     (take (string-split detail "\n" #:trim? #f) (min (max 1 (- height (+ 7 (length listing)))) (length (string-split detail "\n" #:trim? #f))))
     (list (string-append "Status: " status)) ))
  (string-append "\u001b[H\u001b[2J" (string-join (map (lambda (line) (fit line width)) lines) "\r\n")))
(define (read-key [in (current-input-port)])
  (define c (read-char in))
  (cond [(eof-object? c) 'quit] [(equal? c #\u0004) 'quit]
        [(equal? c #\u001b)
         (if (and (sync/timeout 0.05 in) (equal? (read-char in) #\[))
             (if (sync/timeout 0.05 in)
                 (case (read-char in) [(#\A) 'up] [(#\B) 'down] [else 'ignore]) 'ignore)
             'ignore)]
        [(equal? c #\k) 'up] [(equal? c #\j) 'down]
        [else c]))
(define (run-screen s r [p empty-plugin] [reload #f])
  (define stty (find-executable-path "stty"))
  (unless stty (error 'terminal "stty unavailable; use the menu fallback"))
  (define (terminal . args)
    (define out (open-output-string))
    (unless (parameterize ([current-output-port out]) (apply system* stty args)) (error 'terminal "stty failed"))
    (string-trim (get-output-string out)))
  (define saved (terminal "-g"))
  (define (raw!) (terminal "-icanon" "-echo" "min" "1" "time" "0"))
  (define (restore!) (terminal saved))
  (define selected 0) (define query "") (define detail "Select a node and press w to inspect its origin.")
  (define status "Draft edits are not active system changes.")
  (define detail-offset 0)
  (define (ask label)
    (dynamic-wind restore!
      (lambda () (display "\u001b[H\u001b[2J\u001b[?25h") (prompt label))
      (lambda () (raw!) (display "\u001b[?25l"))))
  (define (execute command) (dispatch-ui! s r p command))
  (define (id)
    (define ns (matching-nodes (session-workspace s) query))
    (when (null? ns) (error 'selection "no selected node"))
    (hash-ref (list-ref ns (min selected (sub1 (length ns)))) 'id))
  (dynamic-wind
   (lambda () (raw!) (display "\u001b[?1049h\u001b[?25l"))
   (lambda ()
     (let loop ()
       (define ns (matching-nodes (session-workspace s) query))
       (set! selected (max 0 (min selected (sub1 (length ns)))))
       (define dims (with-handlers ([exn:fail? (lambda (_) '(28 100))])
                      (define vals (map string->number (string-split (terminal "size"))))
                      (if (and (= (length vals) 2) (andmap exact-positive-integer? vals)) vals '(28 100))))
       (define detail-lines (string-split detail "\n" #:trim? #f))
       (set! detail-offset (min detail-offset (max 0 (sub1 (length detail-lines)))))
       (display (render-screen s selected query (string-join (drop detail-lines detail-offset) "\n") status (cadr dims) (car dims))) (flush-output)
       (define key (read-key))
       (unless (or (eq? key 'quit) (equal? key #\q))
         (with-handlers ([exn:fail? (lambda (e) (set! status (exn-message e)))])
           (unless (memq key '(#\J #\K up down)) (set! detail-offset 0))
           (case key
             [(#\J) (set! detail-offset (add1 detail-offset))]
             [(#\K) (set! detail-offset (max 0 (sub1 detail-offset)))]
             [(up) (set! selected (max 0 (sub1 selected)))] [(down) (set! selected (min (max 0 (sub1 (length ns))) (add1 selected)))]
             [(#\R) (unless reload (error 'reload "No reload callback supplied"))
                      (define-values (next-r next-p) (reload))
                      (set! r next-r) (set! p next-p) (set! status "Extensions reloaded.")]
             [(#\/) (set! query (ask "Search nodes")) (set! selected 0)]
             [(#\a) (set! status (execute (list 'add (string->symbol (ask (string-append "Kind (" (string-join (map symbol->string (sort (hash-keys r) symbol<?)) ", ") ")"))) (ask "Stable ID"))))]
             [(#\e) (set! status (format "~a" (configure s r p (id) ask execute)))]
             [(#\n) (set! status (execute (list 'note (id) (ask "Your note"))))]
             [(#\x) (when (equal? (ask (format "Remove ~a? Type yes" (id))) "yes") (set! status (execute (list 'remove (id)))))]
             [(#\w) (set! detail (execute (list 'why (id))))] [(#\d) (set! detail (draft-diff s))]
             [(#\p) (set! detail (execute '(nix)))] [(#\g) (set! detail (format "Source: ~a\n~s" (session-path s) (node-by-id (session-workspace s) (id))))]
             [(#\s) (set! status (execute '(save)))] [(#\u) (set! status (execute '(undo)))]
             [(#\o) (set! status (execute (list 'export (ask "New export directory"))))]
             [(#\:) (set! detail (format "~a" (execute (datum (ask "Command datum")))))]
             [else (void)]))
         (loop))))
   (lambda ()
     (with-handlers ([exn:fail? void]) (restore!))
     (display "\u001b[?25h\u001b[?1049l") (flush-output))))
(define (run-tui s r [p empty-plugin] [reload #f])
  (if (and (terminal-port? (current-input-port)) (terminal-port? (current-output-port))
           (find-executable-path "stty") (not (equal? (getenv "TERM") "dumb")))
      (run-screen s r p reload) (run-menu s r p reload)))
