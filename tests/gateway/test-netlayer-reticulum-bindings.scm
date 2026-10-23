;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-netlayer-reticulum-bindings.scm — the Reticulum netlayer's names are bound.
;;;
;;; ^reticulum-netlayer:setup opens the bridge's sockets itself, through `let-values`,
;;; when the caller hands it none. The module did not import srfi-11, so that path
;;; raised the first time it ran; the gateway, which hands the netlayer its sockets,
;;; never took it. The bridge needs a running Reticulum to exercise the path; what
;;; holds here is that the names it uses are bound in the module.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/gateway/test-netlayer-reticulum-bindings.scm

(use-modules (playnet test harness)
             (goblins ocapn netlayer reticulum))

(define m (resolve-module '(goblins ocapn netlayer reticulum)))
(check "let-values is bound in the netlayer module" (and (module-variable m 'let-values) #t) #t)
(check "define-values is bound in the netlayer module" (and (module-variable m 'define-values) #t) #t)

(test-summary!)
