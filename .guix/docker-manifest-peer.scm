;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; .guix/docker-manifest-peer.scm — manifest for the self-updating
;;; "peer" Docker image.
;;;
;;; Contains everything from the sealed manifest plus:
;;;   - radicle           : the in-container P2P node + git remote
;;;   - tor               : optional onion transport for radicle gossip
;;;   - shepherd          : PID 1 / supervisor with crash-loop policy
;;;   - git               : used by the in-container updater to fetch
;;;
;;; A container started from this image becomes a Radicle peer that
;;; follows the localchimera project, atomically switches generations on
;;; signed pushes from a pinned delegate set, and rolls back on
;;; crash-loops. See deploy/peer/README.md for the runtime contract.

(use-modules (guix profiles)
             (gnu packages base)
             (gnu packages bash)
             (gnu packages version-control)
             (gnu packages admin)        ;; shepherd
             (gnu packages tor)
             (gnu packages rust-apps)    ;; radicle
             (rns-bridge))

(define %localchimera
  (load (string-append (dirname (current-filename)) "/../guix.scm")))

(packages->manifest
  (list %localchimera
        rns-bridge
        bash
        coreutils
        git
        shepherd
        tor
        radicle))
