;;; deploy/guix/dev-manifest.scm — development environment for playnet hacking
;;;
;;; Usage: guix shell -m deploy/guix/dev-manifest.scm
;;;
;;; Provides Guile + Goblins + Emacs/Geiser for local development
;;; that mirrors the server's live-hacking setup.
(specifications->manifest
 '("guile"
   "guile-goblins"
   "guile-gcrypt"
   "emacs-no-x"
   "emacs-geiser"
   "emacs-geiser-guile"
   "emacs-smartparens"
   "emacs-rainbow-delimiters"
   "git"
   "make"))
