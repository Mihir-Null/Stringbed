;;; stringbed-builder.el --- Visual Racket module authoring -*- lexical-binding: t; -*-

;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1") (vui "1.4.0"))

;;; Commentary:
;; A separate, uncommitted module draft.  Racket validates and generates bundles;
;; only an explicit reviewed pin changes a workspace's loaded implementation.

;;; Code:
(require 'cl-lib)
(require 'stringbed)
(require 'stringbed-vui)
(require 'vui)
(require 'vui-components)

(defvar-local stringbed-builder--spec nil)
(defvar-local stringbed-builder--forms nil)
(defvar-local stringbed-builder--inputs nil)
(defvar-local stringbed-builder--errors nil)
(defvar-local stringbed-builder--instance nil)
(defvar-local stringbed-builder--generation 0)
(defvar-local stringbed-builder--preview nil)
(defvar-local stringbed-builder--preview-generation nil)
(defvar-local stringbed-builder--preview-revision nil)
(defvar-local stringbed-builder--saved nil)
(defvar-local stringbed-builder--saved-generation nil)
(defvar-local stringbed-builder--source-directory nil)
(defvar-local stringbed-builder--source-revision nil)
(defvar-local stringbed-builder--source nil)
(defvar-local stringbed-builder--immutable nil)
(defvar-local stringbed-builder--editable t)
(defvar-local stringbed-builder--reason nil)
(defvar-local stringbed-builder--scope nil)
(defvar-local stringbed-builder--message "A module draft is separate from your workspace.")
(defvar-local stringbed-builder--counter 0)
(defvar-local stringbed-builder--busy nil)
(defvar-local stringbed-builder--pinned nil)

(defvar stringbed-builder-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    (define-key map (kbd "C-c C-c") #'stringbed-builder-preview)
    (define-key map (kbd "C-c C-s") #'stringbed-builder-save)
    (define-key map (kbd "C-c C-p") #'stringbed-builder-pin)
    (define-key map (kbd "C-c C-u") #'stringbed-builder-use)
    (define-key map (kbd "C-c C-q") #'quit-window)
    map))
(define-derived-mode stringbed-builder-mode vui-mode "Stringbed Builder"
  "Visual module draft.  TAB moves through controls; C-c C-c previews."
  (setq-local truncate-lines nil)
  (stringbed-vui-install-field-keys
   '(("C-c C-c" . stringbed-builder-preview) ("C-c C-s" . stringbed-builder-save)
     ("C-c C-p" . stringbed-builder-pin) ("C-c C-u" . stringbed-builder-use)
     ("C-c C-q" . quit-window))))

(defun stringbed-builder--get (object field &optional fallback)
  (cond ((or (null object) (eq object :null)) fallback)
        ((hash-table-p object)
         (gethash field object (if (symbolp field) (gethash (symbol-name field) object fallback) fallback)))
        (t (stringbed--get object field fallback))))
(defun stringbed-builder--optional (value)
  (unless (eq value :null) value))
(defun stringbed-builder--put (object field value)
  (if-let ((cell (assq field object))) (setcdr cell value)
    (nconc object (list (cons field value))))
  object)
(defun stringbed-builder--new-key (prefix)
  (format "%s-%d" prefix (cl-incf stringbed-builder--counter)))
(defun stringbed-builder--rows (field)
  (append (stringbed-builder--get stringbed-builder--spec field) nil))
(defun stringbed-builder--set-rows (field rows)
  (setf (alist-get field stringbed-builder--spec) (vconcat rows)))
(defun stringbed-builder--initialize-spec (spec)
  (setq stringbed-builder--spec (copy-tree spec t))
  (dolist (field '(parameters assignments compositions))
    (stringbed-builder--set-rows
     field (mapcar (lambda (row)
                     (cons (cons 'uiKey (stringbed-builder--new-key (symbol-name field))) row))
                   (stringbed-builder--rows field)))))
(defun stringbed-builder--clean (value)
  "Remove presentation metadata only from known rows in builder spec VALUE.
Literal JSON objects and parameter defaults retain every user key."
  (let ((spec (copy-tree value t)))
    (dolist (field '(parameters assignments compositions))
      (setf (alist-get field spec)
            (vconcat (mapcar (lambda (row)
                              (cl-remove-if (lambda (pair) (memq (car pair) '(uiKey uiControl))) row))
                            (append (stringbed-builder--get spec field) nil)))))
    spec))
(defun stringbed-builder--snapshot ()
  (maphash (lambda (_ input) (stringbed-vui-input-value input)) stringbed-builder--inputs)
  (stringbed-builder--clean stringbed-builder--spec))
(defun stringbed-builder--refresh ()
  (when stringbed-builder--instance
    (vui-set-state :refresh-tick (1+ (or (vui-get-state stringbed-builder--instance :refresh-tick) 0))
                   stringbed-builder--instance)))
(defun stringbed-builder--changed ()
  (cl-incf stringbed-builder--generation)
  (setq stringbed-builder--pinned nil stringbed--form-dirty t)
  (stringbed-builder--refresh)
  (set-buffer-modified-p t))
(defun stringbed-builder--forget (prefix)
  (dolist (key (hash-table-keys stringbed-builder--inputs))
    (when (or (equal prefix key) (string-prefix-p (concat prefix "-") key))
      (remhash key stringbed-builder--inputs)
      (remhash key stringbed-builder--errors))))
(defun stringbed-builder--field (key label control value setter &optional description)
  (let ((input (or (gethash key stringbed-builder--inputs)
                   (puthash key (stringbed-vui-input key control value description label)
                            stringbed-builder--inputs))))
    (stringbed-vui-control
     :key key :input input :error (gethash key stringbed-builder--errors)
     :on-change
     (lambda (next)
       (puthash key next stringbed-builder--inputs)
       (condition-case error
           (progn (funcall setter (stringbed-vui-input-value next))
                  (remhash key stringbed-builder--errors))
         (error (puthash key (error-message-string error) stringbed-builder--errors)))
       (stringbed-builder--changed)))))
(defun stringbed-builder--text-field (key label value setter &optional description)
  (stringbed-builder--field key label '((kind . "string")) value setter description))
(defun stringbed-builder--type-control (type)
  `((kind . ,(cond ((member type '("string" "attribute")) "string")
                   ((member type '("integer" "port")) "integer")
                   ((equal type "boolean") "boolean") (t "advanced")))))
(defun stringbed-builder--type-default (type)
  (cond ((equal type "boolean") t) ((member type '("integer" "port")) 1)
        ((equal type "attribute") "attribute") ((equal type "string") "") (t :null)))
(defun stringbed-builder--guard (thunk)
  (condition-case error (funcall thunk)
    (error (setq stringbed-builder--message (error-message-string error))
           (stringbed-builder--refresh))))
(defun stringbed-builder--rpc (method params callback &optional mutation)
  (when stringbed-builder--busy (user-error "Wait for the current builder request to finish"))
  (let ((buffer (current-buffer)) (connection (stringbed--conn)))
    (setq stringbed-builder--busy t stringbed-builder--message (concat method "…"))
    (stringbed-builder--refresh)
    (condition-case failure
      (stringbed--request
     connection method params
     (lambda (result response)
       ;; A completed pin/reload belongs to the workspace even if this view closed.
       (when (stringbed--get result 'workspace)
         (setf (stringbed--connection-forms connection) (stringbed--get result 'forms))
         (stringbed--accept-view connection (stringbed--get result 'workspace)))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq stringbed-builder--busy nil)
           (funcall callback result response)
           (stringbed-builder--refresh))))
     mutation
     (lambda (error)
       (setq stringbed-builder--busy nil
             stringbed-builder--message
             (concat (when-let ((field (stringbed--get error 'field))) (concat field ": "))
                     (stringbed--get error 'message "Builder request failed")))
       (stringbed-builder--refresh)) t)
      (error
       (setq stringbed-builder--busy nil stringbed-builder--message (error-message-string failure))
       (stringbed-builder--refresh)
       (signal (car failure) (cdr failure))))))

(defun stringbed-builder--move (field key offset)
  (let* ((rows (stringbed-builder--rows field))
         (index (cl-position key rows :key (lambda (row) (stringbed-builder--get row 'uiKey)) :test #'equal))
         (target (+ index offset)))
    (when (and (>= target 0) (< target (length rows)))
      (cl-rotatef (nth index rows) (nth target rows))
      (stringbed-builder--set-rows field rows)
      (stringbed-builder--changed))))
(defun stringbed-builder--remove (field key)
  (stringbed-builder--set-rows field (cl-remove key (stringbed-builder--rows field)
                                               :key (lambda (row) (stringbed-builder--get row 'uiKey)) :test #'equal))
  (stringbed-builder--forget key)
  (stringbed-builder--changed))
(defun stringbed-builder--row-actions (field row)
  (let ((key (stringbed-builder--get row 'uiKey)))
    (vui-hstack
     (vui-button "Move up" :key (concat key "-up") :on-click (lambda () (stringbed-builder--move field key -1)))
     (vui-button "Move down" :key (concat key "-down") :on-click (lambda () (stringbed-builder--move field key 1)))
     (vui-button "Remove" :key (concat key "-remove") :on-click (lambda () (stringbed-builder--remove field key))))))
(defun stringbed-builder-add-parameter ()
  (interactive)
  (let ((row `((uiKey . ,(stringbed-builder--new-key "parameter"))
               (name . ,(format "parameter%d" (1+ (length (stringbed-builder--rows 'parameters)))))
               (type . "boolean") (default . t) (description . ""))))
    (stringbed-builder--set-rows 'parameters (append (stringbed-builder--rows 'parameters) (list row)))
    (stringbed-builder--changed)))
(defun stringbed-builder--parameter (row)
  (let* ((key (stringbed-builder--get row 'uiKey)) (type (stringbed-builder--get row 'type)))
    (vui-vstack :key key :spacing 0
      (stringbed-builder--text-field (concat key "-name") "Parameter name" (stringbed-builder--get row 'name)
                                    (lambda (v) (stringbed-builder--put row 'name v)))
      (vui-hstack
       (vui-text "Type")
       (vui-select :key (concat key "-type") :value type
                   :options '("boolean" "string" "integer" "port" "attribute" "value")
                   :prompt "Parameter type: "
                   :on-change (lambda (value)
                                (stringbed-builder--put row 'type value)
                                (stringbed-builder--put row 'default (stringbed-builder--type-default value))
                                (stringbed-builder--forget (concat key "-default"))
                                (stringbed-builder--changed))))
      (stringbed-builder--field (concat key "-default") "Default value"
                                (stringbed-builder--type-control type) (stringbed-builder--get row 'default)
                                (lambda (v) (stringbed-builder--put row 'default v)))
      (stringbed-builder--text-field (concat key "-description") "Parameter description" (stringbed-builder--get row 'description "")
                                    (lambda (v) (stringbed-builder--put row 'description v)))
      (stringbed-builder--row-actions 'parameters row))))

(defun stringbed-builder--binding (key binding setter &optional control)
  (let* ((parameter (stringbed-builder--get binding 'parameter))
         (choice (if parameter (concat "parameter:" parameter) "literal"))
         (parameters (mapcar (lambda (row) (stringbed-builder--get row 'name)) (stringbed-builder--rows 'parameters)))
         (options (append '(("literal" . "Literal value"))
                          (mapcar (lambda (name) (cons (concat "parameter:" name) (concat "Parameter: " name))) parameters))))
    (vui-vstack :key key
      (vui-select :key (concat key "-source") :value choice :options options :prompt "Value source: "
                  :on-change (lambda (value)
                               (stringbed-builder--forget key)
                               (funcall setter (if (equal value "literal") '((literal . :null))
                                                 `((parameter . ,(substring value (length "parameter:"))))))
                               (stringbed-builder--changed)))
      (if parameter
          (vui-text (if (member parameter parameters) (concat "Bound to " parameter)
                      (concat "Missing parameter: " parameter))
                    :face (unless (member parameter parameters) 'error))
        (stringbed-builder--field (concat key "-literal") "Literal value" (or control '((kind . "advanced")))
                                  (stringbed-builder--get binding 'literal :null)
                                  (lambda (value) (funcall setter `((literal . ,value)))))))))
(defun stringbed-builder-add-assignment ()
  (interactive)
  (let* ((parameter (car (stringbed-builder--rows 'parameters)))
         (row `((uiKey . ,(stringbed-builder--new-key "assignment")) (path . "")
                (value . ,(if parameter `((parameter . ,(stringbed-builder--get parameter 'name))) '((literal . :null)))))))
    (stringbed-builder--set-rows 'assignments (append (stringbed-builder--rows 'assignments) (list row)))
    (stringbed-builder--changed)))
(defun stringbed-builder--find-option (row)
  (let ((term (read-string "Find Nix option by name or description: ")))
    (stringbed-builder--rpc
     "option-search" `((term . ,term) (scope . ,stringbed-builder--scope))
     (lambda (result _)
       (let* ((items (append (stringbed--get result 'items) nil))
              (choices (mapcar (lambda (item) (cons (stringbed--get item 'path) item)) items))
              (name (and choices (completing-read "Map to Nix option: " choices nil t)))
              (option (cdr (assoc name choices))))
         (unless option (user-error "No applicable options found; prepare the workspace input lock first"))
         (stringbed-builder--put row 'path name)
         (stringbed-builder--put row 'uiControl (stringbed--get option 'control))
         (stringbed-builder--forget (concat (stringbed-builder--get row 'uiKey) "-path"))
         (stringbed-builder--forget (concat (stringbed-builder--get row 'uiKey) "-value"))
         (setq stringbed-builder--message "Selected an option from the pinned scope.")
         (stringbed-builder--changed))))))
(defun stringbed-builder--assignment (row)
  (let* ((key (stringbed-builder--get row 'uiKey))
         (path (stringbed-builder--get row 'path "")))
    (vui-vstack :key key
      (stringbed-builder--text-field (concat key "-path") "Nix option path"
                                    (if (stringp path) path (mapconcat #'identity path "."))
                                    (lambda (value) (stringbed-builder--put row 'path value)))
      (vui-button "Find applicable option" :key (concat key "-find")
                  :on-click (lambda () (stringbed-builder--guard (lambda () (stringbed-builder--find-option row)))))
      (stringbed-builder--binding (concat key "-value") (stringbed-builder--get row 'value)
                                 (lambda (value) (stringbed-builder--put row 'value value))
                                 (stringbed-builder--get row 'uiControl))
      (stringbed-builder--row-actions 'assignments row))))

(defun stringbed-builder--candidate (kind &optional source)
  (cl-find-if (lambda (form)
                (and (equal kind (stringbed--get form 'kind))
                     (or (not source) (equal source (stringbed--get form 'source)))))
              stringbed-builder--forms))
(defun stringbed-builder-add-composition ()
  (interactive)
  (let* ((available (cl-remove-if-not (lambda (form) (stringbed--true-p (stringbed--get form 'available t)))
                                    stringbed-builder--forms))
         (choices (mapcar (lambda (form) (cons (stringbed--get form 'kind) form)) available))
         (kind (completing-read "Compose loaded form: " choices nil t))
         (form (cdr (assoc kind choices)))
         (bindings (make-hash-table :test #'equal)))
    (unless form (user-error "Select an available loaded form"))
    (dolist (field (append (stringbed--get form 'fields) nil))
      (let ((default (stringbed--get field 'default :null)))
        ;; Required selectors intentionally have no valid default.  Present a
        ;; blank string control for a new selection, never the sentinel false.
        (when (and (member (stringbed--get field 'type) '("attribute" "string"))
                   (not (stringp default)))
          (setq default ""))
        (puthash (stringbed--get field 'name) `((literal . ,default)) bindings)))
    (stringbed-builder--set-rows
     'compositions
     (append (stringbed-builder--rows 'compositions)
             (list `((uiKey . ,(stringbed-builder--new-key "composition"))
                     (id . ,(format "%s-%d" kind (1+ (length (stringbed-builder--rows 'compositions)))))
                     (kind . ,kind) (source . ,(stringbed--get form 'source)) (bindings . ,bindings)))))
    (stringbed-builder--changed)))
(defun stringbed-builder--composition (row)
  (let* ((key (stringbed-builder--get row 'uiKey)) (kind (stringbed-builder--get row 'kind))
         (form (stringbed-builder--candidate kind (stringbed-builder--get row 'source)))
         (bindings (stringbed-builder--get row 'bindings))
         (fields (or (append (stringbed--get form 'fields) nil)
                     (mapcar (lambda (name) `((name . ,(if (symbolp name) (symbol-name name) name))
                                              (type . "value") (description . "Captured binding; preview to load its exact descriptor.")))
                             (if (hash-table-p bindings) (hash-table-keys bindings) (mapcar #'car bindings))))))
    (vui-vstack :key key
      (vui-text (concat "Includes " kind) :face 'bold)
      (vui-text (stringbed--get form 'description "Form not loaded; backend will validate its captured source."))
      (stringbed-builder--text-field (concat key "-id") "Composition label" (stringbed-builder--get row 'id)
                                    (lambda (value) (stringbed-builder--put row 'id value)))
      (mapcar
       (lambda (field)
         (let* ((name (stringbed--get field 'name))
                (binding (stringbed-builder--get bindings (intern name) '((literal . :null)))))
           (vui-vstack
            (vui-text (concat name " — " (stringbed--get field 'description "")) :face 'bold)
            (stringbed-builder--binding
             (concat key "-binding-" name) binding
             (lambda (value)
               (if (hash-table-p bindings) (puthash name value bindings)
                 (setf (alist-get (intern name) bindings) value)
                 (stringbed-builder--put row 'bindings bindings)))
             (stringbed-builder--type-control (stringbed--get field 'type))))))
       fields)
      (stringbed-builder--row-actions 'compositions row))))

(defun stringbed-builder--preview-view ()
  (when stringbed-builder--preview
    (vui-vstack
     (vui-text (if (stringbed-builder--preview-current-p)
                   "Preview matches this draft" "Preview is stale — preview again before pinning")
               :face (if (stringbed-builder--preview-current-p) 'success 'warning))
     (vui-collapsible :title "Generated Nix definitions" :initially-expanded t :key "preview-definitions"
                     (vui-text (mapconcat (lambda (definition)
                                            (if (stringp definition) definition
                                              (stringbed--get definition 'text "")))
                                          (append (stringbed--get stringbed-builder--preview 'definitions) nil) "\n")))
     (vui-collapsible :title "Generated Racket" :key "preview-racket"
                     (vui-text (stringbed--get stringbed-builder--preview 'racket "")))
     (vui-collapsible :title "Validation result" :initially-expanded t :key "preview-validation"
                     (let ((native (stringbed--get stringbed-builder--preview 'nativeValidation)))
                       (vui-vstack
                        (vui-text (concat "Expansion: " (stringbed--get stringbed-builder--preview 'validation "structural-only")))
                        (vui-text (concat "Native Nix: " (stringbed-builder--get native 'state "not-evaluated")))
                        (vui-text (stringbed-builder--get native 'message ""))
                        (mapcar (lambda (result)
                                  (vui-text (format "%s — %s\n%s"
                                                    (stringbed--get result 'path "Generated import or executable value")
                                                    (stringbed--get result 'state "not-evaluated")
                                                    (stringbed--get result 'message ""))))
                                (append (stringbed-builder--get native 'results) nil))))))))
(defun stringbed-builder--preview-current-p ()
  (and (equal stringbed-builder--generation stringbed-builder--preview-generation)
       (equal stringbed-builder--preview-revision (stringbed--connection-revision (stringbed--conn)))))
(vui-defcomponent stringbed-builder--view (generation message)
  :state ((refresh-tick 0))
  :render
  (vui-vstack :spacing 1
    (vui-text "Visual module builder" :face 'stringbed-title)
    (vui-text "Define typed parameters, map Nix definitions, and compose loaded forms. Nothing is pinned automatically.")
    (vui-text (or stringbed-builder--message "") :face (if stringbed-builder--busy 'shadow 'font-lock-doc-face))
    (if (not stringbed-builder--editable)
        (vui-vstack
         (vui-text (or stringbed-builder--reason "This source has no reversible visual definition.") :face 'warning)
         (vui-button "Inspect Racket source" :on-click #'stringbed-builder-source))
      (vui-vstack :spacing 1
       (stringbed-builder--text-field "kind" "Form name" (stringbed-builder--get stringbed-builder--spec 'kind "")
                                     (lambda (value) (stringbed-builder--put stringbed-builder--spec 'kind value)))
       (stringbed-builder--text-field "description" "Description" (stringbed-builder--get stringbed-builder--spec 'description "")
                                     (lambda (value) (stringbed-builder--put stringbed-builder--spec 'description value)))
       (vui-hstack (vui-text "Scope for preview")
                   (vui-select :key "scope" :value stringbed-builder--scope
                               :options (append (stringbed--get (stringbed--connection-workspace (stringbed--conn)) 'scopes) nil)
                               :on-change (lambda (value) (setq stringbed-builder--scope value) (stringbed-builder--changed))))
       (apply #'vui-collapsible :title (format "Parameters (%d)" (length (stringbed-builder--rows 'parameters)))
              :key "parameters" :initially-expanded t
              (append (mapcar #'stringbed-builder--parameter (stringbed-builder--rows 'parameters))
                      (list (vui-button "Add parameter" :key "add-parameter" :on-click #'stringbed-builder-add-parameter))))
       (apply #'vui-collapsible :title (format "Nix assignments (%d)" (length (stringbed-builder--rows 'assignments)))
              :key "assignments" :initially-expanded t
              (append (mapcar #'stringbed-builder--assignment (stringbed-builder--rows 'assignments))
                      (list (vui-button "Add assignment" :key "add-assignment" :on-click #'stringbed-builder-add-assignment))))
       (apply #'vui-collapsible :title (format "Composed forms (%d)" (length (stringbed-builder--rows 'compositions)))
              :key "compositions" :initially-expanded t
              (append (mapcar #'stringbed-builder--composition (stringbed-builder--rows 'compositions))
                      (list (vui-button "Compose loaded form" :key "add-composition"
                                        :on-click (lambda () (stringbed-builder--guard #'stringbed-builder-add-composition))))))
       (vui-collapsible :title "Annotations and upstream sources" :key "annotations" :initially-expanded t
        (stringbed-builder--text-field "note" "Personal module note" (stringbed-builder--get stringbed-builder--spec 'note "")
                                      (lambda (value) (stringbed-builder--put stringbed-builder--spec 'note value)))
        (stringbed-builder--text-field "docs" "Documentation URLs (one per line)" (mapconcat #'identity (stringbed-builder--get stringbed-builder--spec 'docs []) "\n")
                                      (lambda (value) (stringbed-builder--put stringbed-builder--spec 'docs (vconcat (split-string value "[\n\r]+" t "[ \t]+")))))
        (stringbed-builder--text-field "sources" "Upstream source URLs (one per line)" (mapconcat #'identity (stringbed-builder--get stringbed-builder--spec 'sources []) "\n")
                                      (lambda (value) (stringbed-builder--put stringbed-builder--spec 'sources (vconcat (split-string value "[\n\r]+" t "[ \t]+"))))))
       (vui-hstack
        (vui-button "Preview expansion" :key "preview" :disabled stringbed-builder--busy :on-click #'stringbed-builder-preview)
        (vui-button "Validate with Nix" :key "validate" :disabled stringbed-builder--busy
                    :on-click (lambda () (stringbed-builder-preview t)))
        (vui-button "Save working bundle" :key "save" :disabled stringbed-builder--busy :on-click #'stringbed-builder-save)
        (vui-button "Save new derivative" :key "save-as" :disabled stringbed-builder--busy
                    :on-click (lambda () (stringbed-builder-save (read-directory-name "New derivative directory: ")))))
       (vui-hstack
        (vui-button "Open editable Racket" :key "source" :disabled (not stringbed-builder--source-directory) :on-click #'stringbed-builder-source)
        (vui-button "Pin reviewed bundle" :key "pin" :disabled (or stringbed-builder--busy (not stringbed-builder--saved)) :on-click #'stringbed-builder-pin)
        (vui-button "Use this form" :key "use" :disabled (not stringbed-builder--pinned) :on-click #'stringbed-builder-use))
       (vui-button "Refresh built-in identity" :key "refresh-builtins" :disabled stringbed-builder--busy
                   :on-click #'stringbed-builder-refresh-builtins)
       (stringbed-builder--preview-view)))
    (vui-text "C-c C-c preview · C-c C-s save derivative · C-c C-p pin · C-c C-u use · C-c C-q close" :face 'shadow)))

(defun stringbed-builder--open-result (connection result)
  (let ((buffer (generate-new-buffer "*Stringbed module builder*")))
    (with-current-buffer buffer
      (stringbed-builder-mode)
      (stringbed--attach connection)
      (setq stringbed-builder--inputs (make-hash-table :test #'equal)
            stringbed-builder--errors (make-hash-table :test #'equal)
            stringbed-builder--forms (append (stringbed--get result 'forms) nil)
            stringbed-builder--editable (stringbed--true-p (stringbed--get result 'editable t))
            stringbed-builder--reason (stringbed-builder--optional (stringbed--get result 'reason))
            stringbed-builder--source-directory (stringbed-builder--optional (stringbed--get result 'directory))
            stringbed-builder--source-revision (stringbed-builder--optional (stringbed--get result 'revision))
            stringbed-builder--source (stringbed-builder--optional (stringbed--get result 'source))
            stringbed-builder--immutable (stringbed--true-p (stringbed--get result 'immutable))
            stringbed-builder--scope (car (append (stringbed--get (stringbed--connection-workspace connection) 'scopes) nil)))
      (when-let ((spec (stringbed-builder--optional (stringbed--get result 'spec))))
        (stringbed-builder--initialize-spec spec))
      (setq stringbed-builder--instance (vui-mount (vui-component 'stringbed-builder--view :generation 0 :message stringbed-builder--message) buffer t))
      (add-hook 'kill-buffer-query-functions #'stringbed-builder--confirm-close nil t)
      (set-buffer-modified-p nil))
    (pop-to-buffer buffer) buffer))
(defun stringbed-builder--confirm-close ()
  (or (not stringbed--form-dirty) (y-or-n-p "Discard the unsaved visual module draft? ")))
;;;###autoload
(defun stringbed-builder ()
  "Create a visual module draft using the current workspace's loaded forms."
  (interactive)
  (let ((connection (stringbed--conn)))
    (stringbed--request connection "builder/new" nil
                        (lambda (result _) (stringbed-builder--open-result connection result)))))
;;;###autoload
(defun stringbed-builder-open (&optional directory)
  "Open a generated working bundle DIRECTORY without modifying its source."
  (interactive)
  (let ((connection (stringbed--conn))
        (directory (or directory (read-directory-name "Existing module working bundle: "))))
    (stringbed--request connection "builder/inspect" `((directory . ,(expand-file-name directory)))
                        (lambda (result _) (stringbed-builder--open-result connection result)))))
;;;###autoload
(defun stringbed-builder-derive (kind &optional directory)
  "Create a working derivative of loaded KIND in a new DIRECTORY."
  (interactive (list (completing-read "Loaded form: " (mapcar (lambda (form) (stringbed--get form 'kind))
                                                             (append (stringbed--connection-forms (stringbed--conn)) nil)) nil t)))
  (let ((connection (stringbed--conn))
        (directory (or directory (read-directory-name "New derivative directory (must not exist): "))))
    (stringbed--request
     connection "builder/derive" `((kind . ,kind) (directory . ,(expand-file-name directory)))
     (lambda (result _)
       (stringbed--request connection "builder/inspect" `((directory . ,(stringbed--get result 'directory)))
                           (lambda (inspected _) (stringbed-builder--open-result connection inspected)))))))
(defun stringbed-builder-preview (&optional native)
  "Preview the draft through Racket.  With NATIVE also ask Nix to validate."
  (interactive "P")
  (stringbed-builder--guard
   (lambda ()
     (let ((generation stringbed-builder--generation) (spec (stringbed-builder--snapshot)))
       (stringbed-builder--rpc
        "builder/preview" (append `((spec . ,spec) (values . ,(make-hash-table :test #'equal))
                                    (scope . ,stringbed-builder--scope) (validate . ,(if native t :false)))
                                  (when stringbed-builder--source-directory
                                    `((sourceDirectory . ,stringbed-builder--source-directory))))
        (lambda (result response)
          (setq stringbed-builder--preview result stringbed-builder--preview-generation generation
                stringbed-builder--preview-revision (stringbed--get response 'revision)
                stringbed-builder--message "Expansion preview received; check definitions before saving and pinning.")
          (when (equal generation stringbed-builder--generation)
            (when-let ((forms (stringbed--get result 'forms)))
              (setq stringbed-builder--forms (append forms nil))
              (dolist (row (stringbed-builder--rows 'compositions))
                (stringbed-builder--forget (concat (stringbed-builder--get row 'uiKey) "-binding")))))))))))
(defun stringbed-builder-refresh-builtins ()
  "Explicitly refresh direct built-in source identities in this visual draft."
  (interactive)
  (stringbed-builder--guard
   (lambda ()
     (let ((generation stringbed-builder--generation))
       (stringbed-builder--rpc
        "builder/refresh-builtins" `((spec . ,(stringbed-builder--snapshot)))
        (lambda (result _)
          (if (not (equal generation stringbed-builder--generation))
              (setq stringbed-builder--message "The draft changed while identities were refreshing. Your edits are preserved; refresh again.")
            (clrhash stringbed-builder--inputs) (clrhash stringbed-builder--errors)
            (stringbed-builder--initialize-spec (stringbed--get result 'spec))
            (setq stringbed-builder--message (stringbed--get result 'message "Built-in identities refreshed; preview, save and pin explicitly."))
            (stringbed-builder--changed))))))))
(defun stringbed-builder-save (&optional directory)
  "Save a working bundle with its recorded revision, or a new DIRECTORY.
Existing generated source is updated only through backend revision checks."
  (interactive)
  (stringbed-builder--guard
   (lambda ()
     (let* ((directory (expand-file-name (or directory (unless stringbed-builder--immutable stringbed-builder--source-directory)
                                            (read-directory-name "New working bundle directory (must not exist): "))))
           (same-directory (and stringbed-builder--source-directory
                                (equal (directory-file-name directory)
                                       (directory-file-name (expand-file-name stringbed-builder--source-directory)))))
           (generation stringbed-builder--generation)
           (spec (stringbed-builder--snapshot)))
       (stringbed-builder--rpc
        "builder/save"
        (append `((spec . ,spec) (directory . ,directory))
                (when stringbed-builder--source-directory `((sourceDirectory . ,stringbed-builder--source-directory)))
                (when same-directory `((expectedRevision . ,stringbed-builder--source-revision))))
        (lambda (result _)
          (setq stringbed-builder--saved result stringbed-builder--saved-generation generation
                stringbed-builder--source-directory (stringbed--get result 'directory)
                stringbed-builder--source-revision (stringbed--get result 'revision)
                stringbed-builder--source nil stringbed-builder--immutable nil
                stringbed-builder--message "Saved the editable working bundle. Pin it explicitly after reviewing the preview.")
          (when (= generation stringbed-builder--generation)
            (setq stringbed--form-dirty nil)
            (set-buffer-modified-p nil))))))))
(defun stringbed-builder-source ()
  "Open a working derivative for editing; inspect immutable sources read-only."
  (interactive)
  (if (and stringbed-builder--editable stringbed-builder--source-directory
           (not stringbed-builder--immutable)
           (not (string-match-p "/\\.stringbed/extensions/" (concat (file-truename stringbed-builder--source-directory) "/")))
           (not (stringbed--true-p (stringbed--get stringbed-builder--source 'locked))))
      (find-file-other-window (expand-file-name "main.rkt" stringbed-builder--source-directory))
    (stringbed--visit-source (or (stringbed--get stringbed-builder--source 'path)
                                (and stringbed-builder--source-directory
                                     (expand-file-name "main.rkt" stringbed-builder--source-directory))))))
(defun stringbed-builder-pin (&optional extension-id)
  "Explicitly pin the saved, reviewed derivative and replace the loaded registry."
  (interactive)
  (stringbed-builder--guard
   (lambda ()
     (unless (and stringbed-builder--saved
                  (equal stringbed-builder--saved-generation stringbed-builder--generation)
                  (stringbed-builder--preview-current-p))
       (user-error "Preview and save the current module draft before pinning"))
     (let ((generation stringbed-builder--generation)
           (extension-id (or extension-id
                             (read-string "Extension identity to pin: " (stringbed-builder--get stringbed-builder--spec 'kind)))))
       (stringbed-builder--rpc
        "builder/pin" `((directory . ,(stringbed--get stringbed-builder--saved 'directory))
                        (extensionId . ,extension-id) (reviewDigest . ,(stringbed--get stringbed-builder--saved 'reviewDigest)))
        (lambda (_result response)
          (setq stringbed-builder--pinned (= generation stringbed-builder--generation)
                stringbed-builder--message
                (if stringbed-builder--pinned
                    "Pinned reviewed bundle. Use this form to configure an instance in your workspace."
                  "The reviewed bundle was pinned; your newer builder edits still need preview, save and pin."))
          (when stringbed-builder--pinned
            (setq stringbed-builder--preview-revision (stringbed--get response 'revision)))) t)))))
(defun stringbed-builder-use ()
  "Configure an instance of the explicitly pinned form in the workspace draft."
  (interactive)
  (unless stringbed-builder--pinned (user-error "Pin the reviewed working bundle first"))
  (let* ((connection (stringbed--conn)) (kind (stringbed-builder--get stringbed-builder--spec 'kind))
         (form (cl-find kind (stringbed--connection-forms connection) :key (lambda (item) (stringbed--get item 'kind)) :test #'equal)))
    (unless form (user-error "The pinned form is not loaded; reload the workspace registry"))
    (stringbed--generic-form connection form stringbed-builder--scope)))

(defun stringbed-builder--workspace-updated (connection _view)
  "Refresh review freshness when CONNECTION changes outside the builder."
  (dolist (buffer (stringbed--connection-buffers connection))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'stringbed-builder-mode)
          (stringbed-builder--refresh))))))
(add-hook 'stringbed-workspace-update-hook #'stringbed-builder--workspace-updated)

(provide 'stringbed-builder)
;;; stringbed-builder.el ends here
