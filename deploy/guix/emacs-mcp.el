;;; emacs-mcp.el --- xorg MCP server for Emacs/Geiser  -*- lexical-binding: t; -*-
;;;
;;; Registers xorg-specific tools in mcp-server-lib so external AI
;;; (Claude, etc.) can interact with a live Goblins vat via Geiser.
;;;
;;; Setup:
;;; 1. herd start xorg-dev-repl
;;; 2. M-x geiser-connect-local RET guile RET /var/run/xorg-dev.sock RET
;;; 3. In REPL: (use-modules (goblins))   ;; IMPORTANT: do this first!
;;; 4. M-x mcp-server-lib-start
;;;
;;; Then register with Claude:
;;; claude mcp add -s user -t stdio xorg -- emacs --batch -l ~/.emacs.d/emacs-mcp.el \
;;;   -f xorg-mcp-init

;;; Commentary:
;;
;; This file wires mcp-server-lib.el to Geiser, providing MCP tools
;; that evaluate Scheme in a live Goblins vat.  Each tool delegates
;; to Geiser's REPL connection.

;;; Code:

(require 'mcp-server-lib)
(require 'geiser-eval)

(defvar xorg-mcp-server-id "xorg"
  "Server ID for xorg MCP tools.")

(defun xorg-mcp-geiser-eval (expression)
  "Evaluate EXPRESSION string in the live Goblins REPL via Geiser.
Returns result as string."
  (let ((result (geiser-eval-string expression)))
    (if result
        (format "%s" result)
      "void")))

(defun xorg-mcp-init ()
  "Initialize xorg MCP server.  Register all tools."
  (interactive)
  (mcp-server-lib-register-tool #'xorg-tool-eval
    :id "xorg-eval"
    :description "Evaluate a Scheme expression in the live xorg Goblins vat. Returns result."
    :server-id xorg-mcp-server-id)

  (mcp-server-lib-register-tool #'xorg-tool-bindings
    :id "xorg-bindings"
    :description "List current bindings in the org. Returns an alist."
    :read-only t
    :server-id xorg-mcp-server-id)

  (mcp-server-lib-register-tool #'xorg-tool-history
    :id "xorg-history"
    :description "Show recent org history entries with version, expressor, and expression."
    :read-only t
    :server-id xorg-mcp-server-id)

  (mcp-server-lib-register-tool #'xorg-tool-verify-entry
    :id "xorg-verify-history"
    :description "Verify the cryptographic signature of a history entry."
    :read-only t
    :server-id xorg-mcp-server-id)

  (mcp-server-lib-start))

(defun xorg-mcp-stop ()
  "Stop xorg MCP server."
  (interactive)
  (mcp-server-lib-stop))

;; Tool implementations

(defun xorg-tool-eval (expression)
  "Evaluate EXPRESSION in the live xorg.

MCP Parameters:
  expression - Scheme expression to evaluate in the running org"
  (mcp-server-lib-with-error-handling
    (xorg-mcp-geiser-eval expression)))

(defun xorg-tool-bindings ()
  "List current org bindings.

MCP Parameters:"
  (mcp-server-lib-with-error-handling
    (xorg-mcp-geiser-eval
     "(map (lambda (b) (list (car b) (if (procedure? (cdr b)) '<procedure> (cdr b))))
           (org-bindings (car *orgs*)))")))

(defun xorg-tool-history (&optional count)
  "Show recent history entries.

MCP Parameters:
  count - number of recent entries to show (default 10)"
  (mcp-server-lib-with-error-handling
    (let ((n (or count 10)))
      (xorg-mcp-geiser-eval
       (format "(let ((h (org-history (car *orgs*))))
                  (map (lambda (e) (list (car e) (cadr e) (caddr e)))
                       (list-tail h (max 0 (- (length h) %d)))))"
               n)))))

(defun xorg-tool-verify-entry (version)
  "Verify signature of a history entry by version number.

MCP Parameters:
  version - version number of the history entry to verify"
  (mcp-server-lib-with-error-handling
    (xorg-mcp-geiser-eval
     (format "(let* ((h (org-history (car *orgs*)))
                     (entry (find (lambda (e) (= (car e) %d)) h)))
                (if entry
                    (let ((expressor-pk (assq-ref
                                         ($ (org-ref (car *orgs*)) 'expressor-store)
                                         (cadr entry))))
                      (if expressor-pk
                          (verify-history-entry entry (assq-ref expressor-pk 'public-key))
                          'no-public-key))
                    'not-found))"
             version))))

(provide 'emacs-mcp)
;;; emacs-mcp.el ends here
