#lang racket/base
(require json racket/file racket/list racket/match racket/math racket/path racket/port
         racket/random racket/string
         "model.rkt" "extension.rkt" "compiler.rkt" "session.rkt"
         "durability.rkt" "query-context.rkt" "module-builder.rkt")
(provide run-server make-backend protocol-handle)

;; Transport is data only. Each request captures one immutable semantic snapshot;
;; successful mutations compare-and-swap against that snapshot's session/revision.
(struct backend (session registry sources token revision readonly mutex extensions [extension-baseline #:auto])
  #:auto-value #f #:mutable)
(struct snapshot (session registry sources token revision readonly) #:transparent)
(struct exn:fail:protocol exn:fail (code field node) #:transparent)
(define (fail code message [field #f] [node #f])
  (raise (exn:fail:protocol message (current-continuation-marks) code field node)))
(define (make-backend #:extensions [extensions '()])
  (backend #f #f #f #f 0 #f (make-semaphore 1) extensions))
(define (guard b thunk) (call-with-semaphore (backend-mutex b) thunk))
(define (clone-session s)
  (define clone (session (session-path s) (session-workspace s) (session-history s) (session-baseline s)))
  (set-session-journal-baseline! clone (session-journal-baseline s)) clone)
(define (capture b request #:refresh? [refresh? #f])
  (guard b
    (lambda ()
      (unless (backend-session b) (fail "not-open" "Open a workspace first."))
      (unless (equal? (hash-ref request 'session #f) (backend-token b))
        (fail "wrong-session" "The workspace session changed; reopen or refresh."))
      (unless (or refresh? (equal? (hash-ref request 'revision #f) (backend-revision b)))
        (fail "stale-revision" "The draft changed; refresh before retrying this action."))
      (snapshot (clone-session (backend-session b)) (backend-registry b) (backend-sources b)
                (backend-token b) (backend-revision b) (backend-readonly b)))))
(define (ensure-current b snap)
  (unless (and (equal? (snapshot-token snap) (backend-token b))
               (= (snapshot-revision snap) (backend-revision b)))
    (fail "stale-revision" "The draft changed while this action ran; refresh and retry.")))
(define (writeable! snap)
  (when (snapshot-readonly snap)
    (fail "read-only" "Data-only inspection cannot edit or execute extensions. Reopen in trusted editing mode.")))
(define (json-value value)
  (cond [(void? value) 'null] [(path? value) (path->string value)]
        [(symbol? value) (if (eq? value 'null) 'null (symbol->string value))]
        [(hash? value) (for/hash ([(k v) (in-hash value)])
                         (values (if (symbol? k) k (string->symbol (format "~a" k))) (json-value v)))]
        [(list? value) (map json-value value)]
        [(or (string? value) (boolean? value) (number? value)) value]
        [else (format "~s" value)]))
(define (required p key pred label)
  (define v (hash-ref p key #f))
  (unless (pred v) (fail "invalid-params" (format "~a must be ~a." key label) (symbol->string key))) v)
(define (str p key) (required p key string? "a string"))
(define (label n)
  (define display (hash-ref n 'display-name #f))
  (if (and (string? display) (not (string=? (string-trim display) ""))) display
      (hash-ref (hash-ref n 'params) 'attribute
                (lambda () (hash-ref (hash-ref n 'params) 'path (hash-ref n 'id))))))
(define (diagnostics w r)
  (append-map
   (lambda (n)
     (with-handlers ([exn:fail? (lambda (e) (list (hash 'node (hash-ref n 'id) 'field "params" 'message (exn-message e))))])
       (validate-workspace-node w r n) '()))
   (hash-ref w 'nodes)))
(define (workspace-view snap [selected #f])
  (define s (snapshot-session snap)) (define w (session-workspace s))
  (define errors (diagnostics w (snapshot-registry snap)))
  (define result
    (hash 'path (path->string (path->complete-path (session-path s)))
          'name (hash-ref w 'name) 'target (symbol->string (hash-ref w 'target))
          'system (hash-ref w 'system)
          'dirty (not (equal? w (call-with-input-bytes (session-baseline s) read-data)))
          'undoAvailable (pair? (session-history s)) 'readOnly (snapshot-readonly snap)
          'validation (hash 'state "structural-only" 'message "Form structure checked; full Nix evaluation is a separate explicit action.")
          'scopes (if (eq? (hash-ref w 'target) 'home) '("home")
                      (cons "system" (map (lambda (u) (string-append "home:" (symbol->string u)))
                                           (sort (hash-keys (hash-ref w 'homes (hash))) symbol<?))))
          'nodes (for/list ([n (hash-ref w 'nodes)])
                   (hash 'id (hash-ref n 'id) 'kind (symbol->string (hash-ref n 'kind))
                         'displayName (label n) 'scope (hash-ref n 'scope (if (eq? (hash-ref w 'target) 'home) "home" "system"))
                         'params (json-value (hash-ref n 'params)) 'note (hash-ref n 'note) 'docs (hash-ref n 'docs)
                         'valid (not (findf (lambda (e) (equal? (hash-ref e 'node) (hash-ref n 'id))) errors))))
          'diagnostics errors 'sourceRevision (bytes-digest (string->bytes/utf-8 (workspace-text w)))))
  (if selected (hash-set result 'selectedId selected) result))
(define (forms-view snap)
  (for/list ([kind (sort (hash-keys (snapshot-registry snap)) symbol<?)])
    (define d (hash-ref (snapshot-registry snap) kind))
    (hash 'kind (symbol->string kind) 'description (form-description d)
          'fields (for/list ([f (form-fields d)])
                    (hash 'name (symbol->string (field-name f)) 'type (symbol->string (field-type f))
                          'default (json-value (field-default f)) 'description (field-description f)))
          'source (hash-ref (snapshot-sources snap) kind (hash 'path 'null 'sha256 'null))
          'locked (hash-ref (hash-ref (snapshot-sources snap) kind (hash)) 'locked #f))))
(define (snapshot-context snap [p (hash)])
  (writeable! snap)
  (prepare-query-context (session-workspace (snapshot-session snap)) (snapshot-registry snap)
                         (session-path (snapshot-session snap))
                         #:lock-file (hash-ref p 'lockFile #f) #:initialize? (hash-ref p 'initialize #f)))
(define (scope-for snap p)
  (hash-ref p 'scope (if (eq? (hash-ref (session-workspace (snapshot-session snap)) 'target) 'home) "home" "system")))
(define (fresh-id w kind display)
  (define base (regexp-replace* #px"[^a-z0-9_-]+" (string-downcase (format "~a-~a" kind display)) "-"))
  (define used (map (lambda (n) (hash-ref n 'id)) (hash-ref w 'nodes)))
  (let loop ([i 1]) (define id (format "~a-~a" base i)) (if (member id used) (loop (add1 i)) id)))
(define (validate-selection snap kind params scope)
  (case kind
    [(package) (context-lookup-package (snapshot-context snap) (str params 'attribute))]
    [(option) (unless (hash-has-key? params 'value) (fail "invalid-params" "Choose an option value." "value"))
              (context-validate-option (snapshot-context snap) (str params 'path) (hash-ref params 'value) #:scope scope)]
    [else (void)]))
(define (commit-candidate b snap candidate [selected #f])
  (guard b
    (lambda ()
      (ensure-current b snap)
      (commit-edit! (backend-session b) candidate)
      (set-backend-revision! b (add1 (backend-revision b)))
      (define new-snap (snapshot (clone-session (backend-session b)) (backend-registry b)
                                 (backend-sources b) (backend-token b) (backend-revision b) (backend-readonly b)))
      (values (workspace-view new-snap selected) new-snap))))
(define (edit-candidate snap command)
  (writeable! snap)
  (define s (clone-session (snapshot-session snap)))
  (execute! s (snapshot-registry snap) command)
  (session-workspace s))
(define (diff-view snap)
  (define s (snapshot-session snap))
  (define before (call-with-input-bytes (session-baseline s) read-data))
  (define after (session-workspace s))
  (define (index w) (for/hash ([n (hash-ref w 'nodes)]) (values (hash-ref n 'id) n)))
  (define bs (index before)) (define as (index after))
  (define changes
    (for/list ([id (sort (remove-duplicates (append (hash-keys bs) (hash-keys as))) string<?)]
               #:unless (equal? (hash-ref bs id #f) (hash-ref as id #f)))
      (define old (hash-ref bs id #f)) (define new (hash-ref as id #f))
      (hash 'id id 'label (label (or new old)) 'status (cond [(not old) "added"] [(not new) "removed"] [else "changed"])
            'before (if old (json-value old) 'null) 'after (if new (json-value new) 'null))))
  (hash 'changes changes
        'text (if (null? changes) "No unsaved node changes."
                  (string-join (for/list ([change changes])
                                 (format "~a  ~a (~a)" (string-titlecase (hash-ref change 'status))
                                         (hash-ref change 'label) (hash-ref change 'id))) "\n"))))
(define (provenance-view snap p)
  (define w (session-workspace (snapshot-session snap)))
  (define n (node-by-id w (str p 'node)))
  (define scope (node-scope w n))
  (define kind (hash-ref n 'kind))
  (define definition
    (with-handlers ([exn:fail? (lambda (e) (hash 'definitions '() 'error (exn-message e)))])
      (car (provenance w (snapshot-registry snap) #:node (hash-ref n 'id)))))
  (define evaluation-path
    (case kind
      [(option) (hash-ref (hash-ref n 'params) 'path)]
      [(package) (if (equal? scope "system") "environment.systemPackages" "home.packages")]
      [else #f]))
  (define evaluation
    (if (and (hash-ref p 'evaluated #f) evaluation-path)
        (hash 'state "evaluated" 'sourceRevision (bytes-digest (string->bytes/utf-8 (workspace-text w)))
              'subject (hash 'path evaluation-path 'scope scope
                             'kind (if (eq? kind 'package) "shared-package-collection" "option"))
              'message (if (eq? kind 'package)
                           "Evaluated package collection for this scope, shared with other definitions. This does not establish which source caused a particular member."
                           "Evaluated value and origins reported by the Nix module system.")
              'result (context-explain-option (snapshot-context snap) evaluation-path #:scope scope))
        (hash 'state "not-evaluated" 'message "Authored definitions; evaluate explicitly to inspect effective values and origins.")))
  (hash 'node (hash-ref n 'id)
        'selection (hash 'name (label n) 'kind (symbol->string kind) 'scope scope 'params (json-value (hash-ref n 'params)))
        'relationship (hash 'kind (if (eq? (hash-ref (hash-ref w 'provenance (hash)) 'kind #f) 'generated) "generated" "direct")
                            'message "Expansion can contain several definitions; it is not a complete Nix causal graph.")
        'authored (hash 'workspace (path->string (path->complete-path (session-path (snapshot-session snap))))
                        'id (hash-ref n 'id) 'note (hash-ref n 'note) 'docs (hash-ref n 'docs)
                        'generator (json-value (hash-ref w 'provenance (hash))))
        'implementation (hash-ref (snapshot-sources snap) kind (hash 'path 'null 'sha256 'null))
        'definitions (hash-ref definition 'definitions) 'evaluation evaluation 'raw (json-value n)))

(define (extension-bytes path)
  (define lock (extension-lock-path path))
  (and (file-exists? lock) (file->bytes lock)))
(define (builder-candidates snap)
  (for/list ([item (forms-view snap)])
    (define kind (string->symbol (hash-ref item 'kind)))
    (define source (hash-ref (snapshot-sources snap) kind (hash)))
    (define identity
      (cond [(memq kind '(package option module)) (hash 'kind "builtin")]
            [(hash-ref source 'locked #f)
             (hash 'kind "bundle" 'sha256 (hash-ref source 'bundleSha256)
                   'entry (hash-ref source 'entry))]
            [else #f]))
    (hash-set* item 'source (or identity 'null) 'available (and identity #t)
               'reason (if identity "" "This development form has no immutable bundle. Pin it before composing it."))))
(define (builder-dependencies snap)
  (for/hash ([source (in-hash-values (snapshot-sources snap))]
             #:when (hash-ref source 'locked #f))
    (values (hash-ref source 'bundleSha256) (hash-ref source 'bundleDirectory))))
(define (same-builder-source? a b)
  (and (hash? a) (hash? b) (equal? (hash-ref a 'kind #f) (hash-ref b 'kind #f))
       (or (equal? (hash-ref a 'kind #f) "builtin")
           (and (equal? (hash-ref a 'sha256 #f) (hash-ref b 'sha256 #f))
                (equal? (hash-ref a 'entry #f) (hash-ref b 'entry #f))))))
(define (builder-context snap value [source-directory #f])
  (define spec (validate-builder-spec value))
  (define candidates (builder-candidates snap))
  ;; Inspection only reads receipts. Explicit trusted preview/save can load an
  ;; exact captured child when its original form is not separately installed.
  ;; The generated main.rkt itself is still loaded only by explicit pin/reload.
  (define captured (if source-directory
                       (hash-ref (read-builder-bundle (path->complete-path source-directory)) 'dependencies)
                       (hash)))
  (define dependencies
    (for/fold ([all (builder-dependencies snap)]) ([(digest directory) (in-hash captured)])
      (hash-set all digest directory)))
  (define registry (snapshot-registry snap))
  (define seen (make-hash))
  (define loaded (make-hash))
  (for ([composition (hash-ref spec 'compositions)] [index (in-naturals)])
    (define kind (hash-ref composition 'kind))
    (define source (hash-ref composition 'source))
    (define previous (hash-ref seen kind #f))
    (when (and previous (not (same-builder-source? previous source)))
      (fail "ambiguous-composition" "One module cannot bind the same form name from two source revisions. Give those forms distinct names."
            (format "compositions.~a.source" index)))
    (hash-set! seen kind source)
    (define candidate (findf (lambda (item) (equal? kind (hash-ref item 'kind))) candidates))
    (cond
      [(and candidate (hash-ref candidate 'available)
            (same-builder-source? source (hash-ref candidate 'source))) (void)]
      [(and (equal? (hash-ref source 'kind) "bundle")
            (hash-has-key? captured (hash-ref source 'sha256)))
       (define digest (hash-ref source 'sha256))
       (define directory (hash-ref captured digest))
       (unless (equal? digest (hash-ref (bundle-identity directory) 'sha256))
         (fail "composition-drift" "A captured dependency changed before preview. Restore its reviewed snapshot." (format "compositions.~a.source" index)))
       (define key (cons digest (hash-ref source 'entry)))
       (define forms
         (hash-ref! loaded key
           (lambda () (load-trusted-extension (build-path directory (hash-ref source 'entry))))))
       (define available (make-registry forms))
       (unless (equal? digest (hash-ref (bundle-identity directory) 'sha256))
         (fail "composition-drift" "A captured dependency changed while loading." (format "compositions.~a.source" index)))
       (define descriptor (hash-ref available (string->symbol kind) #f))
       (unless descriptor (fail "composition-unavailable" (format "The captured bundle does not export ~a." kind) (format "compositions.~a.kind" index)))
       (set! registry (hash-set registry (string->symbol kind) descriptor))]
      [else
       (fail "composition-unavailable"
             (format "The loaded ~a form does not match this composition's immutable source. Choose its current source, or open the module's captured working derivative." kind)
             (format "compositions.~a.source" index))]))
  (values spec registry dependencies))
(define (new-builder-spec [kind "my-module"])
  (hash 'schema 1 'kind kind 'description "" 'parameters '() 'assignments '()
        'compositions '() 'note "" 'docs '() 'sources '()))
(define (resolved-builder-candidates snap spec registry)
  (for/fold ([items (builder-candidates snap)]) ([composition (hash-ref spec 'compositions)])
    (define kind (hash-ref composition 'kind))
    (define descriptor (hash-ref registry (string->symbol kind)))
    (define item
      (hash 'kind kind 'description (form-description descriptor)
            'fields (for/list ([field (form-fields descriptor)])
                      (hash 'name (symbol->string (field-name field)) 'type (symbol->string (field-type field))
                            'default (json-value (field-default field)) 'description (field-description field)))
            'source (hash-ref composition 'source) 'available #t 'reason ""))
    (append (filter (lambda (existing) (not (equal? kind (hash-ref existing 'kind)))) items) (list item))))
(define (builder-inspection snap params)
  (define kind (and (hash-has-key? params 'kind) (string->symbol (str params 'kind))))
  (define source (and kind (hash-ref (snapshot-sources snap) kind #f)))
  (when (and kind (not source)) (fail "unknown-form" "The selected form is not loaded." "kind"))
  (define directory
    (cond [(hash-has-key? params 'directory) (path->complete-path (str params 'directory))]
          [(and source (hash-ref source 'bundleDirectory #f)) (string->path (hash-ref source 'bundleDirectory))]
          [else #f]))
  (define immutable?
    (and directory (regexp-match? #px"(?:^|/)\\.stringbed/extensions(?:/|$)"
                                   (path->string (simplify-path directory)))))
  (define base (hash 'forms (builder-candidates snap) 'source (or source 'null) 'immutable (and immutable? #t)))
  (cond
    [(and directory (file-exists? (build-path directory "builder.json")))
     (define inspected (read-builder-bundle directory))
     (define result-base
       (if (and immutable? (not source))
           (hash-set base 'source
                     (hash 'path (path->string (build-path directory (hash-ref inspected 'entry "main.rkt")))
                           'sha256 (hash-ref inspected 'sourceSha256) 'locked #t
                           'bundleSha256 (hash-ref inspected 'revision)
                           'bundleDirectory (path->string directory)))
           base))
     (for/fold ([result (hash-set* result-base 'editable #t
                                'reason (if immutable? "Pinned snapshot: create a working derivative before editing or saving." "")
                                'extensionId (if source (hash-ref source 'extensionId (hash-ref (hash-ref inspected 'spec) 'kind))
                                                 (hash-ref (hash-ref inspected 'spec) 'kind)))])
               ([(key value) (in-hash inspected)])
       (hash-set result key value))]
    [else
     (hash-set* base 'editable #f 'directory (if directory (path->string directory) 'null)
                'reason "This form is handwritten Racket. Its implementation is inspectable; the visual builder cannot reconstruct arbitrary code. Create a module and compose this form instead.")]))
(define (builder-workspace snap scope)
  (define w (session-workspace (snapshot-session snap)))
  (node-scope w (hash 'scope scope))
  (if (string-prefix? scope "home:")
      (let* ([user (substring scope 5)]
             [home (hash-ref (workspace-homes w) (string->symbol user))])
        (hash-set* w 'target 'home 'user user 'home-directory (hash-ref home 'home-directory)
                   'state-version (hash-ref home 'state-version) 'homes (hash)))
      w))
(define (native-builder-validation snap spec values scope requested? registry)
  (cond
    [(not requested?) (hash 'state "not-evaluated" 'results '()
                           'message "Structural expansion only. Request native validation against a prepared input lock.")]
    [else
     (define context (snapshot-context snap))
     (cond
       [(not (equal? (hash-ref context 'state) "ready"))
        (hash 'state "needs-lock" 'results '() 'message "Prepare the workspace input lock before native validation.")]
       [else
        (define expanded (builder-expand spec values (builder-workspace snap scope) registry))
        (define (plain-value? value)
          (cond [(or (string? value) (boolean? value) (eq? value 'null) (number? value)) #t]
                [(list? value) (andmap plain-value? value)]
                [(hash? value) (andmap plain-value? (hash-values value))]
                [else #f]))
        (define results
          (for/list ([definition expanded] [index (in-naturals)])
            (define base (hash 'index index))
            (cond
              [(or (nix-import? definition) (not (plain-value? (assignment-value definition))))
               (hash-set* base 'state "not-evaluated" 'message "Imports and executable Nix values require full workspace evaluation.")]
              [else
               (define path (string-join (assignment-path definition) "."))
               (with-handlers ([exn:fail? (lambda (e)
                                          (define invalid?
                                            (and (exn:fail:query? e)
                                                 (member (exn:fail:query-code e) '("unknown-option" "invalid-option-value"))))
                                          (hash-set* base 'path path 'state (if invalid? "invalid" "error") 'message (exn-message e)
                                                     'field (format "definitions.~a.~a" index
                                                                    (if (exn:fail:query? e) (exn:fail:query-field e) "value"))))])
                 (unless (equal? (attr-path path) (assignment-path definition))
                   (fail "unsupported-path" "This quoted attribute path needs full workspace evaluation." "path"))
                 (context-validate-option context path (assignment-value definition) #:scope scope)
                 (hash-set* base 'path path 'state "type-valid"
                            'message "Nix option type checked; workspace assertions and merge conflicts are separate."))])))
        (hash 'state (cond [(ormap (lambda (item) (equal? (hash-ref item 'state) "error")) results) "error"]
                           [(ormap (lambda (item) (equal? (hash-ref item 'state) "invalid")) results) "invalid"]
                           [(ormap (lambda (item) (equal? (hash-ref item 'state) "not-evaluated")) results) "partial"]
                           [else "type-valid"])
              'results results 'context context
              'message "Native option type checks are separate from full workspace evaluation and activation.")])]))
(define (saved-builder-result result)
  (define identity (bundle-identity (hash-ref result 'directory)))
  (hash-set result 'reviewDigest (hash-ref identity 'sha256)))
(define (install-builder-registry! b snap registry sources baseline)
  (set-backend-registry! b registry)
  (set-backend-sources! b sources)
  (set-backend-extension-baseline! b baseline)
  (set-backend-revision! b (add1 (backend-revision b))))

(define (validate-envelope request)
  (unless (and (hash? request) (equal? (hash-ref request 'v #f) 1)
               (let ([id (hash-ref request 'id #f)]) (or (string? id) (exact-integer? id))))
    (fail "invalid-request" "Expected a version 1 object with a string or integer request id."))
  (str request 'method)
  (unless (hash? (hash-ref request 'params (hash)))
    (fail "invalid-params" "params must be an object.")))
(define (dispatch b request [progress void])
  (validate-envelope request)
  (define method (str request 'method))
  (define p (hash-ref request 'params (hash)))
  (cond
    [(equal? method "open")
     ;; Parsing and extension loading happen before replacing a usable session.
     (define path (path->complete-path (str p 'path)))
     (define s (open-session path))
     (define sources (make-hash))
     (define data-only? (hash-ref p 'dataOnly #f))
     (define lock-baseline (and (not data-only?) (extension-bytes path)))
     (define r (if data-only? (load-registry #:sources sources)
                   (load-registry (backend-extensions b) (path-only path) #:workspace path #:sources sources)))
     (unless (or data-only? (equal? lock-baseline (extension-bytes path)))
       (fail "extension-drift" "The extension lock changed while opening. Retry after the other writer finishes."))
     (guard b
       (lambda ()
         (set-backend-session! b s) (set-backend-registry! b r) (set-backend-sources! b sources)
         (set-backend-token! b (bytes-digest (crypto-random-bytes 32)))
         (set-backend-revision! b 0) (set-backend-readonly! b data-only?)
         (set-backend-extension-baseline! b lock-baseline)
         (define snap (snapshot (clone-session s) r sources (backend-token b) 0 data-only?))
         (values (workspace-view snap) snap)))]
    [else
     (define snap (capture b request #:refresh? (equal? method "workspace")))
     (define s (snapshot-session snap)) (define w (session-workspace s)) (define r (snapshot-registry snap))
     (define (plain result) (values result snap))
     (define (commit candidate [selected #f]) (commit-candidate b snap candidate selected))
     (match method
       ["workspace" (plain (workspace-view snap))]
       ["forms" (plain (forms-view snap))]
       ["builder/new"
        (plain (hash 'spec (validate-builder-spec (new-builder-spec (hash-ref p 'kind "my-module")))
                     'forms (builder-candidates snap) 'editable #t))]
       ["builder/inspect" (plain (builder-inspection snap p))]
       ["builder/refresh-builtins"
        (writeable! snap)
        (plain (hash 'spec (refresh-builder-builtins (required p 'spec hash? "an object"))
                     'message "Direct built-in identity refreshed in this draft. Preview, save and pin explicitly; captured child bundles retain their own identities."))]
       ["builder/preview"
        (writeable! snap)
        (define-values (spec preview-registry _dependencies)
          (builder-context snap (required p 'spec hash? "an object") (hash-ref p 'sourceDirectory #f)))
        (define vals (hash-ref p 'values (hash)))
        (unless (hash? vals) (fail "invalid-params" "values must be an object." "values"))
        (define scope (scope-for snap p))
        (define preview (preview-builder spec vals (builder-workspace snap scope) preview-registry))
        (define validation (native-builder-validation snap spec vals scope (hash-ref p 'validate #f) preview-registry))
        (plain (hash-set* preview 'nativeValidation validation
                         'forms (resolved-builder-candidates snap spec preview-registry)))]
       ["builder/save"
        (writeable! snap)
        (define destination (path->complete-path (str p 'directory)))
        (define source-directory (hash-ref p 'sourceDirectory (and (directory-exists? destination) destination)))
        (define-values (spec save-registry dependencies)
          (builder-context snap (required p 'spec hash? "an object") source-directory))
        (guard b
          (lambda ()
            (ensure-current b snap)
            (define saved
              (save-builder-bundle! spec destination
                                    #:registry save-registry
                                    #:dependencies dependencies
                                    #:source-directory source-directory
                                    #:expected-revision (hash-ref p 'expectedRevision #f)))
            (plain (saved-builder-result saved))))]
       ["builder/derive"
        (writeable! snap)
        (define inspected (builder-inspection snap (hash 'kind (str p 'kind))))
        (unless (hash-has-key? inspected 'spec)
          (fail "builder-unavailable" (hash-ref inspected 'reason) "kind"))
        (define-values (derived-spec derived-registry dependencies)
          (builder-context snap (hash-ref inspected 'spec) (hash-ref inspected 'directory)))
        (guard b
          (lambda ()
            (ensure-current b snap)
            (define saved
              (save-builder-bundle! derived-spec (path->complete-path (str p 'directory))
                                    #:registry derived-registry
                                    #:dependencies dependencies
                                    #:source-directory (hash-ref inspected 'directory)))
            (plain (hash-set (saved-builder-result saved) 'extensionId (hash-ref inspected 'extensionId)))))]
       ["builder/pin"
        (writeable! snap)
        (define directory (path->complete-path (str p 'directory)))
        (define inspected (read-builder-bundle directory))
        (define review-digest (str p 'reviewDigest))
        (unless (equal? review-digest (hash-ref (bundle-identity directory) 'sha256))
          (fail "builder-drift" "The bundle changed since review. Inspect and preview it again before pinning." "reviewDigest"))
        (define extension-id (str p 'extensionId))
        (guard b
          (lambda ()
            (ensure-current b snap)
            (unless (equal? (session-baseline s) (file->bytes (session-path s)))
              (fail "source-drift" "The workspace file changed externally. Reconcile or reopen before changing its extension pin."))
            (unless (equal? (backend-extension-baseline b) (extension-bytes (session-path s)))
              (fail "extension-drift" "Another process changed the extension lock. Reload and review the current forms before pinning."))
            (define candidate-registry #f)
            (define candidate-sources (make-hash))
            (define candidate-baseline #f)
            (define candidate-result #f)
            (define candidate-snapshot #f)
            (define record
              (pin-extension! (session-path s) extension-id directory (hash-ref inspected 'entry "main.rkt")
                #:validate
                (lambda (lock)
                  ;; Recheck after acquiring the cooperating-writer lock; another
                  ;; process may have changed source/pins since the preflight.
                  (unless (equal? (session-baseline s) (file->bytes (session-path s)))
                    (fail "source-drift" "The workspace changed before the pin lock was acquired. Reconcile or reopen first."))
                  (unless (equal? (backend-extension-baseline b) (extension-bytes (session-path s)))
                    (fail "extension-drift" "The extension lock changed before pinning. Reload and review before retrying."))
                  (unless (equal? review-digest (hash-ref (hash-ref (hash-ref lock 'extensions) extension-id) 'sha256))
                    (fail "builder-drift" "The bundle changed while pinning. Review it again." "reviewDigest"))
                  (set! candidate-registry
                        (load-registry (backend-extensions b) (path-only (session-path s))
                                       #:workspace (session-path s) #:sources candidate-sources #:lock lock))
                  (validate-workspace w candidate-registry)
                  (set! candidate-snapshot
                        (snapshot (clone-session s) candidate-registry candidate-sources
                                  (snapshot-token snap) (add1 (snapshot-revision snap)) #f))
                  (set! candidate-result (hash 'workspace (workspace-view candidate-snapshot)
                                               'forms (forms-view candidate-snapshot)))
                  ;; Force the exact response through the wire serializer before
                  ;; adoption, so malformed trusted metadata cannot fail afterward.
                  (jsexpr->string (json-value candidate-result))
                  (set! candidate-baseline
                        (call-with-output-bytes (lambda (out) (write lock out) (newline out)))))
                #:commit
                (lambda (_lock _record)
                  (install-builder-registry! b snap candidate-registry candidate-sources candidate-baseline))))
            (values (hash-set candidate-result 'bundle
                              (hash 'directory (path->string directory) 'sha256 (hash-ref record 'sha256)
                                    'entry (hash-ref record 'entry))) candidate-snapshot)))]
       ["builder/reload"
        (writeable! snap)
        (define baseline (extension-bytes (session-path s)))
        (define sources (make-hash))
        (define registry
          (load-registry (backend-extensions b) (path-only (session-path s))
                         #:workspace (session-path s) #:sources sources))
        (validate-workspace w registry)
        (guard b
          (lambda ()
            (ensure-current b snap)
            (unless (equal? baseline (extension-bytes (session-path s)))
              (fail "extension-drift" "The extension lock changed while loading. Retry after the other writer finishes."))
            (define next (snapshot (clone-session s) registry sources (snapshot-token snap) (add1 (snapshot-revision snap)) #f))
            (define result (hash 'workspace (workspace-view next) 'forms (forms-view next)))
            (jsexpr->string (json-value result))
            (parameterize-break #f (install-builder-registry! b snap registry sources baseline))
            (values result next)))]
       ["context" (progress "Preparing the workspace input lock and query snapshot…") (plain (snapshot-context snap p))]
       ["package-search"
        (progress "Searching packages from the pinned nixpkgs input…")
        (define mode (hash-ref p 'mode "search"))
        (unless (member mode '("exact" "search")) (fail "invalid-params" "mode must be exact or search." "mode"))
        (plain (context-search-packages (snapshot-context snap) (str p 'term) #:mode (string->symbol mode)))]
       ["option-search"
        (progress "Reading options for the selected scope…")
        (plain (context-discover-options (snapshot-context snap) (str p 'term) #:scope (scope-for snap p)))]
       ["option-detail" (plain (context-option-detail (snapshot-context snap) (str p 'path) #:scope (scope-for snap p)))]
       [(or "add-package" "add-option" "add")
        (writeable! snap)
        (define kind (cond [(equal? method "add-package") 'package] [(equal? method "add-option") 'option]
                           [else (string->symbol (str p 'kind))]))
        (define params (cond [(eq? kind 'package) (if (equal? method "add") (hash-ref p 'values) (hash 'attribute (str p 'attribute)))]
                             [(eq? kind 'option) (if (equal? method "add") (hash-ref p 'values) (hash 'path (str p 'path) 'value (hash-ref p 'value)))]
                             [else (required p 'values hash? "an object")]))
        (define scope (scope-for snap p))
        (define fallback (hash-ref params 'attribute (lambda () (hash-ref params 'path (symbol->string kind)))))
        (define requested-display (hash-ref p 'displayName fallback))
        (unless (string? requested-display) (fail "invalid-params" "displayName must be a string." "displayName"))
        (define display (if (string=? (string-trim requested-display) "") fallback requested-display))
        (define id (fresh-id w kind display))
        (define n (hash 'id id 'kind kind 'params params 'scope scope 'display-name display 'note "" 'docs '()))
        (define candidate (add-node w n))
        (validate-workspace candidate r)
        (validate-selection snap kind params scope)
        (commit candidate id)]
       ["edit"
        (writeable! snap)
        (define id (str p 'node)) (define old (node-by-id w id))
        (define vals (hash-ref p 'values (hash)))
        (unless (hash? vals) (fail "invalid-params" "values must be an object." "values" id))
        (define params (for/fold ([result (hash-ref old 'params)]) ([(k v) (in-hash vals)]) (hash-set result k v)))
        (define n (hash-set old 'params params))
        (when (hash-has-key? p 'displayName) (set! n (hash-set n 'display-name (str p 'displayName))))
        (when (hash-has-key? p 'scope) (set! n (hash-set n 'scope (str p 'scope))))
        (define candidate (update-node w id (lambda (_) n)))
        (validate-workspace candidate r)
        ;; Explicit value submissions must validate even when unchanged: older
        ;; workspaces may contain values never checked against their Nix type.
        (when (or (positive? (hash-count vals))
                  (not (equal? (node-scope w old) (node-scope candidate n))))
          (validate-selection snap (hash-ref old 'kind) params (node-scope candidate n)))
        (commit candidate)]
       ["note" (commit (edit-candidate snap (list 'note (str p 'node) (str p 'text))))]
       ["docs"
        (define links (required p 'links (lambda (v) (and (list? v) (andmap string? v))) "an array of strings"))
        (commit (edit-candidate snap (list 'docs (str p 'node) links)))]
       ["remove" (commit (edit-candidate snap (list 'remove (str p 'node))))]
       [(or "save" "undo")
        (writeable! snap)
        (guard b
          (lambda ()
            (ensure-current b snap)
            (execute! (backend-session b) r (list (string->symbol method)))
            (set-backend-revision! b (add1 (backend-revision b)))
            (define next (snapshot (clone-session (backend-session b)) r (snapshot-sources snap)
                                   (backend-token b) (backend-revision b) #f))
            (values (workspace-view next) next)))]
       ["nix"
        (writeable! snap)
        (define id (hash-ref p 'node #f))
        (define scope (if id (node-scope w (node-by-id w id)) (scope-for snap p)))
        (plain (hash 'text (compile-module w r #:scope scope #:node id) 'scope scope 'node (or id 'null)))]
       ["diff" (plain (diff-view snap))]
       ["provenance" (plain (provenance-view snap p))]
       ["export"
        (writeable! snap)
        (define context (snapshot-context snap))
        (unless (equal? (hash-ref context 'state) "ready")
          (fail "needs-lock" "Prepare the input lock before exporting a pinned draft." "inputs"))
        (define directory (path->complete-path (str p 'directory)))
        (export-workspace w r directory #:lock-file (build-path (hash-ref context 'directory) "flake.lock"))
        (plain (hash 'directory (path->string directory) 'workspaceSha256 (hash-ref context 'workspace-sha256)
                     'lockSha256 (hash-ref context 'lock-sha256)))]
       ["evaluate" (progress "Evaluating the pinned draft; this does not activate it…") (plain (context-evaluate (snapshot-context snap)))]
       ["build" (progress "Building the pinned draft; this does not activate it…") (plain (context-build (snapshot-context snap)))]
       [_ (fail "unknown-method" (format "Unknown protocol method: ~a" method))])]))

(define (response b request thunk)
  (define id (if (hash? request) (hash-ref request 'id 'null) 'null))
  (define (base token revision) (hash 'v 1 'id id 'session (or token 'null) 'revision revision))
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (define detail
            (cond [(exn:fail:protocol? e)
                   (define h (hash 'code (exn:fail:protocol-code e) 'message (exn-message e)))
                   (define h2 (if (exn:fail:protocol-field e) (hash-set h 'field (exn:fail:protocol-field e)) h))
                   (if (exn:fail:protocol-node e) (hash-set h2 'node (exn:fail:protocol-node e)) h2)]
                  [(exn:fail:query? e) (hash 'code (exn:fail:query-code e) 'message (exn-message e) 'field (or (exn:fail:query-field e) 'null))]
                  [(exn:fail:builder? e) (hash 'code (exn:fail:builder-code e) 'message (exn-message e) 'field (exn:fail:builder-field e))]
                  [else (hash 'code "validation" 'message (exn-message e))]))
          (hash-set (base (backend-token b) (backend-revision b)) 'error detail))])
    (define-values (result snap) (thunk))
    (hash-set (base (snapshot-token snap) (snapshot-revision snap)) 'result (json-value result))))
(define (protocol-handle b request)
  (response b request (lambda () (dispatch b request))))

(define (run-server #:extensions [extensions '()])
  (define b (make-backend #:extensions extensions))
  (define output (current-output-port))
  (define errors (current-error-port))
  (define write-lock (make-semaphore 1))
  (define jobs (make-hash))
  (define jobs-lock (make-semaphore 1))
  (define (emit obj)
    (call-with-semaphore write-lock (lambda () (write-json (json-value obj) output) (newline output) (flush-output output))))
  (define cancellable '("context" "package-search" "option-search" "option-detail" "evaluate" "build" "provenance" "builder/preview"))
  (define (metadata request)
    (hash 'v 1 'id (hash-ref request 'id 'null) 'session (hash-ref request 'session 'null)
          'revision (hash-ref request 'revision 0)))
  (define (stop-job job)
    ;; A break unwinds dynamic-wind, releasing query preparation locks and
    ;; subprocess resources. A hard kill is only a bounded fallback.
    (break-thread (hash-ref job 'thread))
    (unless (sync/timeout 2 (hash-ref job 'thread))
      (custodian-shutdown-all (hash-ref job 'custodian))))
  (let loop ()
    (define line (read-line (current-input-port) 'any))
    (unless (eof-object? line)
      (with-handlers ([exn:fail? (lambda (e) (emit (hash 'v 1 'id 'null 'session 'null 'revision 0
                                                        'error (hash 'code "invalid-json" 'message (exn-message e)))))])
        (define input (open-input-string line))
        (define request (read-json input))
        (unless (eof-object? (read-json input)) (fail "invalid-request" "One JSON object is allowed per line."))
        (unless (hash? request) (fail "invalid-request" "Requests must be JSON objects."))
        (define id (hash-ref request 'id #f))
        (define method (hash-ref request 'method ""))
        (cond
          [(equal? method "cancel")
           (define answer
             (response b request
               (lambda ()
                 (validate-envelope request)
                 (when (call-with-semaphore jobs-lock (lambda () (hash-has-key? jobs (hash-ref request 'id))))
                   (fail "duplicate-request" "A request with this id is still running."))
                 (define snap (capture b request))
                 (define target (hash-ref (hash-ref request 'params (hash)) 'request #f))
                 ;; Claim the terminal response atomically before interrupting.
                 ;; The worker cannot race this claim and emit a second result.
                 (define job
                   (call-with-semaphore jobs-lock
                     (lambda ()
                       (define found (hash-ref jobs target #f))
                       (and found (member (hash-ref found 'method) cancellable)
                            (begin (hash-remove! jobs target) found)))))
                 (when job
                   (stop-job job)
                   (emit (hash-set (hash-ref job 'metadata) 'error
                                   (hash 'code "cancelled" 'message "Request cancelled; no activation was performed."))))
                 (values (hash 'cancelled (and job #t)) snap))))
           (emit answer)]
          [else
           (define duplicate? (call-with-semaphore jobs-lock (lambda () (hash-has-key? jobs id))))
           (if duplicate?
               (emit (hash-set (metadata request) 'error (hash 'code "duplicate-request" 'message "A request with this id is still running.")))
               (let* ([custodian (make-custodian)] [start (make-semaphore 0)])
                 (define worker
                   (parameterize ([current-custodian custodian] [current-output-port errors])
                     (thread
                      (lambda ()
                        (with-handlers ([exn:break? (lambda (_) (void))])
                          (semaphore-wait start)
                          (define reply
                            (response b request
                              (lambda () (dispatch b request (lambda (message)
                                (emit (hash-set* (metadata request) 'event "progress" 'message message)))))))
                          (call-with-semaphore jobs-lock
                            (lambda ()
                              (when (hash-has-key? jobs id)
                                (hash-remove! jobs id) (emit reply)))))))))
                 (call-with-semaphore jobs-lock
                   (lambda () (hash-set! jobs id (hash 'custodian custodian 'thread worker
                                                      'method method 'metadata (metadata request)))))
                 (semaphore-post start)))]))
      (loop)))
  ;; EOF from Emacs also unwinds in-flight resource cleanup.
  (define pending
    (call-with-semaphore jobs-lock
      (lambda () (define remaining (hash-values jobs)) (hash-clear! jobs) remaining)))
  (for ([job pending]) (stop-job job)))
