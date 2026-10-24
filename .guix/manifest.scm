;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; .guix/manifest.scm — CI build manifest
;;;
;;; Declares every package this channel provides.  CI runs:
;;;
;;;   guix build -m .guix/manifest.scm
;;;
;;; This is the Cookbook §7.6 pattern: a single manifest that replaces
;;; ad-hoc build commands.  Cuirass (or Radicle CI) builds everything
;;; listed here on every push.

(use-modules (guix profiles)
             (rns-bridge))

;; The main localchimera package (Guile modules, planner, server wrappers).
;; Its build phase runs tests, so this doubles as a test step.
(define %localchimera
  (load (string-append (dirname (current-filename)) "/../guix.scm")))

(packages->manifest
  (list %localchimera       ;; main package — includes test suite
        rns-bridge))   ;; Rust Reticulum bridge
