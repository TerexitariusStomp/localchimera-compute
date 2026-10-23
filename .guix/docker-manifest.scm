;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; .guix/docker-manifest.scm — manifest for `guix pack --format=docker`
;;;
;;; Used by Radicle CI to produce a self-contained Docker image tarball
;;; containing the playnet runtime, the Reticulum bridge, and a usable
;;; shell environment (bash + coreutils) so recipients can `docker load`
;;; and `docker run -it ... bash` without needing Guix installed.

(use-modules (guix profiles)
             (gnu packages base)
             (gnu packages bash)
             (rns-bridge))

(define %playnet
  (load (string-append (dirname (current-filename)) "/../guix.scm")))

(packages->manifest
  (list %playnet
        rns-bridge
        bash
        coreutils))
