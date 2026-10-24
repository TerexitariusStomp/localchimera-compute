;;; localchimera Emacs daemon configuration -*- lexical-binding: t; -*-
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Deployed to /home/localchimera/.emacs.d/init.el via guix activation.
;;; Source of truth: deploy/scripts/init.el (referenced from
;;; deploy/guix/machines.scm).  Local devs can copy the live-reload
;;; section into their own ~/.emacs.d/init.el to get the same hook.

;;; ── Project root discovery ───────────────────────────────────────────────────
;;;
;;; Three-tier so the same file works in both contexts:
;;;
;;;   1. LOCALCHIMERA_PROJECT_ROOT env var — explicit, for unusual setups.
;;;   2. Auto-detect from load-file-name when init.el is loaded directly
;;;      out of the repo (the local-dev case: drop a `(load "…/init.el")`
;;;      into ~/.emacs.d/init.el and it Just Works).
;;;   3. /home/localchimera/localchimera-repo — the path the Guix activation
;;;      service deploys this file to on the bootstrap VPS provider VM.

(defvar localchimera-project-root
  (or (getenv "LOCALCHIMERA_PROJECT_ROOT")
      (and load-file-name
           (let ((dir (file-name-directory load-file-name)))
             (and (string-match-p "/deploy/scripts/?$" (directory-file-name dir))
                  (file-truename (concat dir "../..")))))
      "/home/localchimera/localchimera-repo")
  "Absolute path to the localchimera repo root.  Used to set Geiser's load
path and the live-reload watch roots.")

;;; ── Geiser ───────────────────────────────────────────────────────────────────

(require 'geiser)
(require 'geiser-guile)
(require 'geiser-hoot)         ; Hoot flavour — M-x connect-to-hoot for live wasm REPL
(require 'geiser-eval)
(require 'geiser-connection)
(require 'geiser-doc)
(require 'geiser-xref)
(require 'geiser-edit)
(require 'geiser-completion)
(require 'smartparens-config)
(require 'rainbow-delimiters)

(setq geiser-guile-binary "guile")
(setq geiser-active-implementations '(guile hoot))
(setq geiser-guile-load-path
      (list (expand-file-name "module" localchimera-project-root)))

(smartparens-global-mode 1)
(show-paren-mode 1)
(add-hook 'scheme-mode-hook #'rainbow-delimiters-mode)

;;; ── Headless server ──────────────────────────────────────────────────────────

(require 'server)
(setq server-use-tcp t)
(setq server-host "127.0.0.1")
(setq server-port 9999)

;; (localchimera-project-root is now defined above with fallback discovery.)

(defun localchimera-repl-output ()
  "Return recent output from the Geiser REPL buffer."
  (when-let ((buf (get-buffer "*Geiser Guile REPL*")))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-max))
        (forward-line -20)
        (buffer-substring-no-properties (point) (point-max))))))

;;; ── Live reload on save ──────────────────────────────────────────────────────
;;;
;;; When you save a Scheme file under module/ in any subtree of the
;;; localchimera repo, push the new definitions into the running browser tab
;;; via the REPL relay (port 37146 by default).  No page reload, no
;;; rebuild.  Pairs with `make serve-dev` and the
;;; live-watch shepherd service on the VM.
;;;
;;; Two implementations are bundled and you can pick whichever fits:
;;;
;;;   localchimera/live-reload-via-script  — shells out to
;;;     tools/dev/live-reload.scm. Works for any editor; no Geiser
;;;     connection required from Emacs.
;;;
;;;   localchimera/live-reload-via-geiser  — uses the active Geiser-Hoot
;;;     connection if there is one. Faster (one round trip instead of
;;;     forking guile), and shows the result in your Emacs REPL buffer.
;;;
;;; The default hook prefers the Geiser path when a connection is up
;;; and falls back to the script otherwise.  This way C-x C-s "just
;;; works" whether you're attached or not.

(defcustom localchimera-live-reload-enabled t
  "Non-nil to enable auto-reload of Scheme buffers on save."
  :type 'boolean
  :group 'localchimera)

(defcustom localchimera-live-reload-roots
  '("module/")
  "Repo-relative path prefixes whose Scheme files should be live-reloaded."
  :type '(repeat string)
  :group 'localchimera)

(defun localchimera--repo-root-for-buffer ()
  "Walk upward from the current buffer's file looking for a sentinel that
identifies the localchimera repo root.  Returns the root path with a trailing
slash, or nil."
  (when buffer-file-name
    (let ((root (locate-dominating-file buffer-file-name "Makefile")))
      (and root (file-name-as-directory (expand-file-name root))))))

(defun localchimera--rel-path-from-root (root path)
  "Return PATH relative to ROOT, or nil if PATH is not under ROOT."
  (when (and root path (string-prefix-p root path))
    (substring path (length root))))

(defun localchimera--reloadable-buffer-p ()
  "Non-nil if the current buffer is a Scheme file under one of the
configured live-reload roots."
  (and buffer-file-name
       (string-suffix-p ".scm" buffer-file-name)
       (let* ((root (localchimera--repo-root-for-buffer))
              (rel  (localchimera--rel-path-from-root root buffer-file-name)))
         (and rel
              (cl-some (lambda (prefix) (string-prefix-p prefix rel))
                       localchimera-live-reload-roots)))))

(defun localchimera/live-reload-via-script ()
  "Shell out to tools/dev/live-reload.scm with the current buffer's file."
  (let* ((root (localchimera--repo-root-for-buffer))
         (rel  (localchimera--rel-path-from-root root buffer-file-name))
         (script (expand-file-name "tools/dev/live-reload.scm" root)))
    (when (and root rel (file-executable-p script))
      ;; Run async so saving never blocks the editor.
      (let ((default-directory root))
        (start-process "localchimera-live-reload" nil script rel)))))

(defun localchimera/live-reload-via-geiser ()
  "Use the active Geiser-Hoot connection to eval the buffer and call
(refresh!).  Returns t if a Geiser REPL was reachable, nil otherwise."
  (when (and (boundp 'geiser-impl--implementation)
             geiser-impl--implementation
             (fboundp 'geiser-eval-buffer))
    (condition-case _err
        (progn
          (geiser-eval-buffer)
          (when (fboundp 'geiser-eval--send/wait)
            (geiser-eval--send/wait
             "(catch #t (lambda () (refresh!)) (lambda _ #f))"))
          t)
      (error nil))))

(defun localchimera/live-reload-on-save ()
  "after-save-hook entry point.  Lives in `after-save-hook` for any
scheme-mode buffer; bails out unless the buffer is in a configured
live-reload root."
  (when (and localchimera-live-reload-enabled
             (derived-mode-p 'scheme-mode)
             (localchimera--reloadable-buffer-p))
    (or (localchimera/live-reload-via-geiser)
        (localchimera/live-reload-via-script))))

(add-hook 'after-save-hook #'localchimera/live-reload-on-save)

(message "localchimera Emacs daemon ready")
