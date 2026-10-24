;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/manifests/dev-manifest.scm — development environment for localchimera hacking
;;;
;;; Usage: guix shell -m deploy/manifests/dev-manifest.scm
;;;
;;; Provides Guile + Goblins + Emacs/Geiser for local development
;;; that mirrors the server's live-hacking setup.  The Emacs package set
;;; tracks the one the server gets from deploy/os.scm, so the shared
;;; deploy/scripts/init.el loads with every `require` satisfied.
(specifications->manifest
 '("guile"
   "guile-goblins"
   "guile-gcrypt"
   "emacs-no-x"
   "emacs-geiser"
   "emacs-geiser-guile"
   "emacs-geiser-hoot"          ; M-x connect-to-hoot for the in-wasm REPL
   "emacs-smartparens"
   "emacs-rainbow-delimiters"
   "git"
   "make"
   ;; age — encryption for deploy/secrets.scm. The pre-commit hook
   ;; calls `age` directly; without this any operator working outside
   ;; a fresh guix shell needs `guix install age` manually.
   "age"))
