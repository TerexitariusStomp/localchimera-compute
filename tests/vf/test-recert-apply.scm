;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-recert-apply.scm — the plan's recert schedule flows onto the credentials.
;;;
;;; The natural consumer of plan-scope's `conformance-recert` field: `apply-recert-
;;; schedule` stamps each skill credential with the `valid-until` its schedule entry
;;; implies, at the ISSUER's clock (the schedule is unit-free — an interval in periods,
;;; now = 0 — so the issuer supplies now + period-span). This is the last hop of the
;;; loop: solve → edge load → recert interval → CREDENTIAL, gated thereafter by the
;;; same `custody-cred-live?` the planner reads.
;;;
;;; Run:  guile -L module/localchimera/planner tests/vf/test-recert-apply.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera vf facts validity))

;; a schedule exactly as plan-scope->alist emits it: (skill . interval-in-periods | #f).
(define schedule '(("electrician" . 1.5) ("baker" . 4.0) ("gardener" . #f)))
(define (skill-of c) (cred-claim-of c 'skill))
(define (cred skill) `((said . ,(string-append "E-" skill)) (revoked? . #f)
                       (claims . ((skill . ,skill) (holder . "did:key:z6Mk...")))))
(define creds (list (cred "electrician") (cred "baker") (cred "gardener") (cred "unlisted")))

(define NOW 1000000) (define DAY 86400.0)
(define stamped (apply-recert-schedule schedule creds skill-of #:now NOW #:period-span DAY))
(define (by-skill sk) (find (lambda (c) (equal? (cred-claim-of c 'skill) sk)) stamped))
(define (vu-of sk) (cred-claim-of (by-skill sk) 'valid-until))

(format #t "~%── the plan's recert schedule, stamped onto the credentials the issuer signs ──~%")
(for-each (lambda (sk)
            (let ((vu (vu-of sk)))
              (format #t "  ~12a → valid-until ~a~%" sk
                      (if vu (format #f "~a (+~,1f d)" vu (/ (- vu NOW) DAY)) "OPEN"))))
          '("electrician" "baker" "gardener" "unlisted"))

;; T1 — a scheduled skill gets NOW + interval·span, in the issuer's clock.
(define t1 (and (vu-of "electrician")
                (< (abs (- (vu-of "electrician") (+ NOW (* 1.5 DAY)))) 1.0e-6)
                (< (abs (- (vu-of "baker")       (+ NOW (* 4.0 DAY)))) 1.0e-6)))
(format #t "  [~a] T1 a scheduled skill's expiry = now + interval·period-span (the issuer clocks the interval)~%" (if t1 "✓" "✗"))

;; T2 — heavier reliance (shorter interval) ⇒ sooner expiry.
(define t2 (< (vu-of "electrician") (vu-of "baker")))
(format #t "  [~a] T2 the more-relied skill expires sooner (electrician 1.5 < baker 4.0)~%" (if t2 "✓" "✗"))

;; T3 — an OPEN schedule entry (#f) ⇒ an open credential (no valid-until).
(define t3 (not (vu-of "gardener")))
(format #t "  [~a] T3 a below-floor skill (#f in the schedule) yields an OPEN credential~%" (if t3 "✓" "✗"))

;; T4 — a skill absent from the schedule ⇒ open (untouched by the plan).
(define t4 (not (vu-of "unlisted")))
(format #t "  [~a] T4 a skill the plan never leaned on stays open (absent ⇒ no expiry)~%" (if t4 "✓" "✗"))

;; T5 — the loop closes on custody-cred-live?: live now, dead past the stamped expiry;
;; the open ones live at any future time.
(define t5 (and (custody-cred-live? (by-skill "electrician") NOW)
                (not (custody-cred-live? (by-skill "electrician") (+ (vu-of "electrician") 1)))
                (custody-cred-live? (by-skill "gardener") (+ NOW (* 3650 DAY)))
                (custody-cred-live? (by-skill "unlisted") (+ NOW (* 3650 DAY)))))
(format #t "  [~a] T5 custody-cred-live? enforces it: dated ones lapse at expiry, open ones never~%" (if t5 "✓" "✗"))

(define ok (and t1 t2 t3 t4 t5))
(format #t "~%  ~a the last hop closes: the plan's reliance → recert interval → the credential's valid-until,~%" (if ok "✓" "✗"))
(format #t "    stamped at the issuer's clock and gated by the very predicate the planner consults~%~%")
(exit (if ok 0 1))
