;;; stringbed-vui.el --- Controlled VUI forms for Stringbed -*- lexical-binding: t; -*-
;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1") (vui "1.4.0"))
;; URL: https://github.com/Mihir-Null/Stringbed
;;; Commentary:
;; Presentation-only controls.  Raw text is retained independently of whether it
;; parses; a malformed edit never submits an earlier valid value.  Nix remains
;; the semantic validator.  Mount one VUI root per form buffer.
;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'vui)
(require 'vui-components)
(unless (fboundp 'vui-set-props)
  (error "Stringbed needs VUI revision 004dd852746d8af838107dd7e3f44c5bbea04d79 or newer"))

(defun stringbed-vui-install-field-keys (bindings)
  "Install buffer-local BINDINGS on VUI text fields without altering VUI globally.
BINDINGS is an alist of key descriptions to commands.  VUI composes the normal
widget field map with its own field/navigation map when rendering."
  (setq-local widget-field-keymap (copy-keymap widget-field-keymap))
  (dolist (binding bindings) (define-key widget-field-keymap (kbd (car binding)) (cdr binding))))

(cl-defstruct (stringbed-vui--input (:constructor stringbed-vui--make-input))
  name control raw mode description label inner nullp)
(defun stringbed-vui--get (object key &optional default)
  (if (hash-table-p object) (gethash key object default)
    (let ((cell (or (assq key object) (assoc (symbol-name key) object)))) (if cell (cdr cell) default))))
(defun stringbed-vui--json (value)
  (let ((json-false :false) (json-null :null)) (json-encode value)))
(defun stringbed-vui--parse (text)
  (json-parse-string text :object-type 'alist :array-type 'array :null-object :null :false-object :false))
(defun stringbed-vui--display (value)
  (if (stringp value) value (stringbed-vui--json value)))
(defun stringbed-vui-input (name control value &optional description label)
  "Make controlled input NAME for CONTROL, retaining VALUE exactly.
VALUE may be :stringbed-unset for a missing default.  JSON arrays use vectors;
objects use alists, false is :false and null is :null."
  (let* ((kind (stringbed-vui--get control 'kind "advanced"))
         (mode (if (and (equal kind "string") (not (stringp value)) (not (eq value :stringbed-unset))) "advanced" kind))
         (raw (cond ((member mode '("boolean" "enum" "nullable")) value)
                    ((eq value :stringbed-unset) "")
                    ((equal mode "string") value)
                    (t (stringbed-vui--json value)))))
    (stringbed-vui--make-input
     :name name :control control :description description :label label :mode mode :raw raw
     :nullp (eq value :null)
     :inner (when (equal kind "nullable")
              (stringbed-vui-input name (stringbed-vui--get control 'element '((kind . "advanced")))
                                   (if (eq value :null) :stringbed-unset value) nil)))))
(defun stringbed-vui-input-name (input) (stringbed-vui--input-name input))
(defun stringbed-vui-input-raw (input) (stringbed-vui--input-raw input))
(defun stringbed-vui-input-control (input) (stringbed-vui--input-control input))
(defun stringbed-vui-change (input raw)
  "Return a new INPUT holding RAW without discarding malformed text."
  (let ((copy (copy-stringbed-vui--input input))) (setf (stringbed-vui--input-raw copy) raw) copy))
(defun stringbed-vui-set-null (input nullp)
  "Return nullable INPUT with NULLP, preserving its previous inner edit."
  (let ((copy (copy-stringbed-vui--input input))) (setf (stringbed-vui--input-nullp copy) nullp) copy))
(defun stringbed-vui-set-inner (input inner)
  "Return nullable INPUT with updated INNER."
  (let ((copy (copy-stringbed-vui--input input))) (setf (stringbed-vui--input-inner copy) inner) copy))
(defun stringbed-vui--type-error (value control)
  "Return basic control-shape error for VALUE, leaving Nix semantics to Racket."
  (let ((kind (stringbed-vui--get control 'kind "advanced")))
    (cond
     ((equal kind "boolean") (unless (memq value '(t :false)) (if (eq value :stringbed-unset) "Choose true or false; no default is declared" (format "Existing value %s is not a Boolean. Choose true or false" (stringbed-vui--display value)))))
     ((equal kind "enum") (unless (cl-position value (stringbed-vui--get control 'choices) :test #'equal) "Choose one of the declared values"))
     ((equal kind "integer") (unless (integerp value) "Enter an integer"))
     ((equal kind "number") (unless (and (numberp value) (= value value) (< (abs value) 1.0e+INF)) "Enter a finite number"))
     ((equal kind "string") (unless (stringp value) "Enter a string; the existing value is not a string"))
     ((equal kind "list") (unless (vectorp value) "Enter a JSON array, such as []"))
     ((equal kind "structured") (unless (or (hash-table-p value) (and (listp value) (or (null value) (consp (car value))))) "Enter a JSON object, such as {}"))
     (t nil))))
(defun stringbed-vui-input-value (input)
  "Return INPUT's current typed value, or signal a field-specific user error."
  (let* ((name (or (stringbed-vui--input-label input) (stringbed-vui--input-name input))) (mode (stringbed-vui--input-mode input))
         (raw (stringbed-vui--input-raw input))
         (value
          (cond
           ((equal mode "nullable")
            (if (stringbed-vui--input-nullp input) :null (stringbed-vui-input-value (stringbed-vui--input-inner input))))
           ((member mode '("boolean" "enum" "string")) raw)
           ((member mode '("integer" "number"))
            (unless (and (stringp raw)
                         (string-match-p (if (equal mode "integer") "\\`[-+]?[0-9]+\\'" "\\`[-+]?[0-9]+\\(?:\\.[0-9]+\\)?\\(?:[eE][-+]?[0-9]+\\)?\\'") raw))
              (user-error "%s: enter %s" name (if (equal mode "integer") "an integer" "a number")))
            (string-to-number raw))
           (t (condition-case nil (stringbed-vui--parse raw) (error (user-error "%s: enter valid JSON" name)))))))
    (when-let ((error (stringbed-vui--type-error value (stringbed-vui--input-control input))))
      (user-error "%s: %s" name error))
    value))
(defun stringbed-vui-input-error (input)
  "Return a current lexical/shape error, without losing INPUT's raw edit."
  (condition-case error (progn (stringbed-vui-input-value input) nil) (error (error-message-string error))))
(defun stringbed-vui-values (inputs)
  "Collect all INPUTS into a string-keyed hash; reject any malformed edit."
  (let ((values (make-hash-table :test #'equal)))
    (dolist (input inputs) (puthash (stringbed-vui-input-name input) (stringbed-vui-input-value input) values)) values))
(defun stringbed-vui-replace-input (inputs updated)
  "Replace one member of INPUTS by name with UPDATED, preserving order."
  (mapcar (lambda (input) (if (equal (stringbed-vui-input-name input) (stringbed-vui-input-name updated)) updated input)) inputs))

(vui-defcomponent stringbed-vui--control (input on-change error)
  :render
  (let* ((name (stringbed-vui-input-name input))
         (kind (stringbed-vui--input-mode input))
         (raw (stringbed-vui--input-raw input))
         (local-error (stringbed-vui-input-error input))
         (change (lambda (value) (funcall on-change (stringbed-vui-change input value)))))
    (vui-vstack
     (vui-text (or (stringbed-vui--input-label input) name) :face 'bold :key (concat name "/label"))
     (when-let ((description (stringbed-vui--input-description input)))
       (unless (string-empty-p description) (vui-text description :face 'shadow)))
     (cond
      ((equal kind "boolean")
       (if (memq raw '(t :false))
           (vui-checkbox :key name :checked (eq raw t) :label (if (eq raw t) "true" "false")
                         :on-change (lambda (value) (funcall change (if value t :false))))
         (vui-select :key name :value :stringbed-unset :prompt "Boolean: "
                     :options '((:stringbed-unset . "Choose true or false") (t . "true") (:false . "false")) :on-change change)))
      ((equal kind "enum")
       (vui-select :key name :value raw :prompt (concat name ": ")
                   :options (mapcar (lambda (value) (cons value (stringbed-vui--json value)))
                                    (append (stringbed-vui--get (stringbed-vui-input-control input) 'choices) nil))
                   :on-change change))
      ((equal kind "nullable")
       (vui-vstack
        (vui-checkbox :key (concat name "/null") :checked (stringbed-vui--input-nullp input) :label "Set to null"
                      :on-change (lambda (value) (funcall on-change (stringbed-vui-set-null input value))))
        (unless (stringbed-vui--input-nullp input)
          (stringbed-vui-control :input (stringbed-vui--input-inner input)
                                :on-change (lambda (value) (funcall on-change (stringbed-vui-set-inner input value)))))))
      (t
       (vui-vstack
        (when (member kind '("advanced" "structured" "list"))
          (vui-text "JSON value: preserve quotes, [] arrays, {} objects and null." :face 'shadow))
        (vui-field :key name :value raw :size (if (member kind '("integer" "number")) 24 62)
                   :on-change change))))
     (when (or error local-error) (vui-text (or error local-error) :face 'error :key (concat name "/error"))))))
(cl-defun stringbed-vui-control (&key input on-change error key)
  "Render INPUT with ON-CHANGE receiving its updated immutable input state."
  (vui-component 'stringbed-vui--control :key (or key (list 'control (stringbed-vui-input-name input)))
                 :input input :on-change on-change :error error))

(vui-defcomponent stringbed-vui--form (title subtitle initial-inputs initial-errors on-change on-submit on-close actions initial-pending)
  :state ((inputs initial-inputs) (errors initial-errors) (pending initial-pending))
  :render
  (vui-vstack :spacing 1
              (vui-text (or title "Stringbed") :face 'bold :key 'title)
              (when subtitle (vui-text subtitle :face 'shadow :key 'subtitle))
              actions
              (mapcar (lambda (input)
                        (stringbed-vui-control :input input :on-change on-change
                                              :error (cdr (assoc (stringbed-vui-input-name input) errors)))) inputs)
              (when-let ((error (cdr (assoc nil errors)))) (vui-text error :face 'error :key 'form-error))
              (vui-hstack :spacing 2
                          (vui-button (if pending "Validating…" "Validate and apply") :key 'submit :disabled pending :on-click on-submit)
                          (vui-button "Close" :key 'close :on-click on-close))
              (vui-text "C-c C-c validates and updates the draft. Save the workspace separately." :face 'shadow)))
(cl-defun stringbed-vui-form (&key title subtitle inputs errors on-change on-submit on-close actions pending)
  "Return a complete controlled form; render it in a buffer owned by VUI."
  (vui-component 'stringbed-vui--form :title title :subtitle subtitle :initial-inputs inputs :initial-errors errors
                 :on-change on-change :on-submit on-submit :on-close on-close :actions actions :initial-pending pending))
(defun stringbed-vui-update-form (inputs errors pending &optional instance)
  "Schedule controlled form state updates after active field edit hooks finish.
The caller records raw edits immediately; VUI owns the deferred repaint."
  (when-let ((root (or instance (vui-get-instance))))
    (vui-batch
     (vui-set-state :inputs inputs root)
     (vui-set-state :errors errors root)
     (vui-set-state :pending pending root))))
(provide 'stringbed-vui)
;;; stringbed-vui.el ends here
