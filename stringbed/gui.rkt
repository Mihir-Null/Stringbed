#lang racket/gui
(require racket/class racket/list racket/port racket/string
         "model.rkt" "session.rkt"
         (only-in "extension.rkt" form-fields form-description field-name field-type field-default)
         "compiler.rkt" "ui-extension.rkt")
(provide create-editor run-gui)

;; The view owns widgets only. The session API owns semantic changes.
(define (create-editor s r [p empty-plugin] [reload #f])
  (define frame (new frame% [label "Stringbed — configuration workspace"]
                     [width 1100] [height 760]))
  (define root (new vertical-panel% [parent frame] [alignment '(left top)]))
  (define status (new message% [parent root] [label "Draft edits are not active system changes."]
                      [auto-resize #t]))
  (define toolbar (new horizontal-panel% [parent root] [stretchable-height #f]))
  (define body (new horizontal-panel% [parent root]))
  (define left (new vertical-panel% [parent body] [min-width 250] [stretchable-width #f]))
  (define right (new vertical-panel% [parent body] [alignment '(left top)]))
  (define selected #f)
  (define ids '())
  (define (report text) (send status set-label (format "~a" text)))
  (define (guard thunk)
    (with-handlers ([exn:fail? (lambda (e)
                               (report (exn-message e))
                               (set-editor! output (string-append "Diagnostic\n" (exn-message e)))
                               (message-box "Stringbed" (exn-message e) frame '(ok stop)))])
      (thunk)))
  (define search-field
    (new text-field% [parent left] [label "Search nodes"]
         [callback (lambda (_ event) (refresh!))]))
  (define node-list
    (new list-box% [parent left] [label "Configuration nodes"] [choices '()]
         [callback (lambda (widget event)
                     (define i (send widget get-selection))
                     (set! selected (and i (list-ref ids i)))
                     (show-node!))]))
  (define kinds (sort (hash-keys r) symbol<?))
  (define kind-choice (new choice% [parent left] [label "Form"]
                           [choices (map symbol->string kinds)]))
  (define id-field (new text-field% [parent left] [label "New stable ID"] [init-value "new-node"]))
  (define (creation-command kind id)
    (case kind
      [(package)
       (define attribute (get-text-from-user "Select package" "Actual nixpkgs attribute" frame))
       (and attribute (list 'add kind id (hash 'attribute attribute)))]
      [(option)
       (define path (get-text-from-user "Select option" "Actual Nix option path" frame))
       (define value (and path (get-text-from-user "Set option" "Value as Racket data (e.g. #t or a quoted string)" frame)))
       (and value (list 'add kind id (hash 'path path 'value (call-with-input-string value read-data))))]
      [else (list 'add kind id)]))
  (new button% [parent left] [label "Add node"]
       [callback (lambda (_ event)
                   (guard (lambda ()
                            (define i (send kind-choice get-selection))
                            (unless i (error 'add "no extension forms are loaded"))
                            (define id (send id-field get-value))
                            (define command (creation-command (list-ref kinds i) id))
                            (when command
                              (define result (dispatch-ui! s r p command))
                              (set! selected id)
                              (refresh!)
                              (report result)))))])
  (define fields-panel (new vertical-panel% [parent right] [alignment '(left top)]
                            [stretchable-height #f]))
  (define tabs (new tab-panel% [parent right] [choices '("Nix / provenance" "Workspace source")]
                    [callback (lambda (widget event)
                                (send output-panel show (= (send widget get-selection) 0))
                                (send source-panel show (= (send widget get-selection) 1)))]))
  (define output-panel (new vertical-panel% [parent tabs]))
  (new message% [parent output-panel] [label "Generated preview; edit fields or workspace source."])
  (define output (new text%))
  (new editor-canvas% [parent output-panel] [editor output] [style '(auto-hscroll auto-vscroll)]
       [min-height 200])
  (define source-panel (new vertical-panel% [parent tabs]))
  (define source (new text%))
  (new message% [parent source-panel]
       [label "Editable workspace data. Apply validates a single transaction; it does not execute Racket."])
  (define source-canvas
    (new editor-canvas% [parent source-panel] [editor source] [style '(auto-hscroll auto-vscroll)]
         [min-height 200]))
  (new button% [parent source-panel] [label "Apply workspace source"]
       [callback (lambda (_ event)
                   (guard (lambda ()
                            (define w (call-with-input-string (send source get-text) read-data))
                            (workspace-valid! w)
                            (validate-workspace w r)
                            (commit-edit! s w)
                            (refresh!)
                            (report "Applied source to draft; save to persist."))))])
  (send source-panel show #f)
  (define (set-editor! editor text)
    (when (eq? editor output) (send editor lock #f))
    (send editor begin-edit-sequence)
    (send editor erase)
    (send editor insert text)
    (send editor end-edit-sequence)
    (when (eq? editor output) (send editor lock #t)))
  (define (command! command)
    (guard (lambda ()
             (define result (dispatch-ui! s r p command))
             (refresh!)
             (report result))))
  (define (display-command! command)
    (guard (lambda ()
             (set-editor! output (format "~a" (dispatch-ui! s r p command)))
             (send tabs set-selection 0)
             (send source-panel show #f)
             (send output-panel show #t))))
  (define (show-node!)
    (send fields-panel change-children (lambda (_) '()))
    (when selected
      (define n (node-by-id (session-workspace s) selected))
      (define d (hash-ref r (hash-ref n 'kind) #f))
      (new message% [parent fields-panel]
           [label (format "~a · ~a" selected (hash-ref n 'kind))])
      (cond
        [d
         (new message% [parent fields-panel] [label (form-description d)])
         (define custom (hash-ref (plugin-gui-editors p) (hash-ref n 'kind) #f))
         (when custom (custom fields-panel s r selected command!))
         (for ([f (if custom '() (form-fields d))])
           (define row (new horizontal-panel% [parent fields-panel] [stretchable-height #f]))
           (define value (hash-ref (hash-ref n 'params) (field-name f) (field-default f)))
           (define plain? (memq (field-type f) '(string attribute)))
           (define input
             (new text-field% [parent row]
                  [label (format "~a (~a)" (field-name f) (field-type f))]
                  [init-value (if (and plain? (string? value)) value (format "~s" value))]))
           (new button% [parent row] [label "Set"]
                [callback (lambda (_ event)
                            (guard (lambda ()
                                     (define text (send input get-value))
                                     (define v (if plain? text (call-with-input-string text read-data)))
                                     (command! (list 'set selected (field-name f) v)))))]))
         (define note (new text-field% [parent fields-panel] [label "Your note"]
                           [init-value (hash-ref n 'note)] [style '(multiple)]))
         (new button% [parent fields-panel] [label "Update note"]
              [callback (lambda (_ event) (command! (list 'note selected (send note get-value))))])
         (define docs (new text-field% [parent fields-panel] [label "Documentation URLs (one per line)"]
                           [init-value (string-join (hash-ref n 'docs) "\n")] [style '(multiple)]))
         (new button% [parent fields-panel] [label "Update links"]
              [callback (lambda (_ event)
                          (command! (list 'docs selected
                                          (filter non-empty-string?
                                                  (map string-trim (string-split (send docs get-value) "\n"))))))])
         (define actions (new horizontal-panel% [parent fields-panel] [stretchable-height #f]))
         (new button% [parent actions] [label "Why / expansion"]
              [callback (lambda (_ event) (display-command! (list 'why selected)))])
         (new button% [parent actions] [label "Go to source"]
              [callback (lambda (_ event)
                          (send tabs set-selection 1)
                          (send output-panel show #f)
                          (send source-panel show #t)
                          (define hit (regexp-match-positions (regexp (regexp-quote (format "~s" selected)))
                                                              (send source get-text)))
                          (when hit (send source set-position (caar hit) (cdar hit)))
                          (send source-canvas focus))])
         (new button% [parent actions] [label "Remove node"]
              [callback (lambda (_ event)
                          (when (= 1 (message-box/custom "Remove node" (format "Remove ~a from this draft?" selected)
                                                        "Remove" "Cancel" #f frame '(caution default=2)))
                            (command! (list 'remove selected))
                            (set-editor! output (draft-diff s))))])]
        [else
         (new message% [parent fields-panel]
              [label "Extension missing: node preserved. Load its extension to edit or compile."])
         (set-editor! output (format "~s" n))])))
  (define (refresh!)
    (define w (session-workspace s))
    (define nodes (matching-nodes w (send search-field get-value)))
    (set! ids (map (lambda (n) (hash-ref n 'id)) nodes))
    (send node-list set (for/list ([n nodes])
                         (format "~a · ~a" (hash-ref n 'id) (hash-ref n 'kind))))
    (unless (member selected ids) (set! selected (and (pair? ids) (car ids))))
    (when selected (send node-list set-selection (index-of ids selected)))
    (set-editor! source (workspace-text w))
    (set-editor! output (with-handlers ([exn:fail? exn-message]) (compile-module w r)))
    (show-node!))
  (for ([label '("Save" "Undo" "Validate" "Nix preview")]
        [command '((save) (undo) (validate) (nix))])
    (new button% [parent toolbar] [label label]
         [callback (lambda (_ event)
                     (if (equal? command '(nix)) (display-command! command) (command! command)))]))
  (new button% [parent toolbar] [label "Export Nix…"]
       [callback (lambda (_ event)
                   (define dir (get-text-from-user "Export" "New output directory (must not exist)" frame))
                   (when dir (command! (list 'export dir))))])
  (new button% [parent toolbar] [label "Draft diff"]
       [callback (lambda (_ event)
                   (set-editor! output (draft-diff s))
                   (send tabs set-selection 0)
                   (send source-panel show #f)
                   (send output-panel show #t))])
  (when reload
    (new button% [parent toolbar] [label "Reload extensions"]
         [callback (lambda (_ event)
                     (guard (lambda ()
                              (define-values (next-r next-p) (reload))
                              (set! r next-r) (set! p next-p)
                              (set! kinds (sort (hash-keys r) symbol<?))
                              (send kind-choice clear)
                              (for ([kind kinds]) (send kind-choice append (symbol->string kind)))
                              (refresh!) (report "Extensions reloaded."))))]))
  (define command-field
    (new text-field% [parent left] [label "Command (Racket data)"] [init-value "(validate)"]))
  (new button% [parent left] [label "Run command"]
       [callback (lambda (_ event)
                   (guard (lambda ()
                            (command! (call-with-input-string (send command-field get-value) read-data)))))])
  (new message% [parent left]
       [label (format "Plugin commands: ~a" (string-join (map symbol->string (sort (hash-keys (plugin-commands p)) symbol<?)) ", "))])
  (refresh!)
  frame)

(define (run-gui s r [p empty-plugin] [reload #f])
  (define frame (create-editor s r p reload))
  (send frame show #t)
  (void))
