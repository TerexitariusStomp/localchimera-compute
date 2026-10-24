;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/fleet/test-rotor.scm — round-robin provider rotor
;;;
;;; Run:
;;;   guile -L module -L tests tests/fleet/test-rotor.scm

(use-modules (srfi srfi-1)
             (localchimera test harness)
             (localchimera fleet reconciler))

(define registry
  (list (cons "sporestack" 'fake-prov-1)
        (cons "vpsbg"      'fake-prov-2)))

;; ── Round-robin across all healthy ─────────────────────────────────────
(let ((picks (map (lambda _ (next-healthy-provider-name! registry '()))
                  (iota 4))))
  (check "two distinct providers picked"
         (not (equal? (list-ref picks 0) (list-ref picks 1))))
  (check "alternation: 0 == 2"
         (list-ref picks 0) (list-ref picks 2))
  (check "alternation: 1 == 3"
         (list-ref picks 1) (list-ref picks 3)))

;; ── Skips unhealthy ────────────────────────────────────────────────────
(let ((picks (map (lambda _
                    (next-healthy-provider-name! registry '("vpsbg")))
                  (iota 5))))
  (check "vpsbg never picked when unhealthy"
         (not (any (lambda (p) (equal? p "vpsbg")) picks)))
  (check "every pick is sporestack"
         (every (lambda (p) (equal? p "sporestack")) picks)))

;; ── All unhealthy → fallback ───────────────────────────────────────────
(let ((p (next-healthy-provider-name! registry '("sporestack" "vpsbg"))))
  (check "fallback returns a registered name"
         (not (not (member p '("sporestack" "vpsbg"))))))

;; ── Empty registry errors ──────────────────────────────────────────────
(check-error "empty registry errors"
             (lambda () (next-healthy-provider-name! '() '())))

(test-summary!)
