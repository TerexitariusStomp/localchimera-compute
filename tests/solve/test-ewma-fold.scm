;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-ewma-fold.scm — the arc-time table's pure folds, no solver, no network.
;;;
;;; ewma-fold: sₙ = α·xₙ + (1−α)·sₙ₋₁ seeded at x₀, per arc key, so the
;;; federation's observed travel times age recent-trips-heavy. Checked against
;;; the closed form. arc-table-merge: observed wins per key, priors fill the
;;; rest. Persistence: save/load roundtrip of the sexp prior file.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-ewma-fold.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve routing))

(define (~= a b) (< (abs (- a b)) 1e-9))

;; ── EWMA closed form, two interleaved keys ───────────────────────────────────
;; key A|B|pedestrian: x = 1.0, 2.0, 0.5 @ α=0.3 → 1.0 → 1.3 → 1.06
;; key B|C|bicycle:    x = 4.0           → 4.0 (seed only)
(define folded
  (ewma-fold (list (list "A" "B" "pedestrian" 1.0)
                   (list "B" "C" "bicycle"    4.0)
                   (list "A" "B" "pedestrian" 2.0)
                   (list "A" "B" "pedestrian" 0.5))
             #:alpha 0.3))
(define ab (assoc-ref folded "A|B|pedestrian"))
(define bc (assoc-ref folded "B|C|bicycle"))
(define c1 (and ab (~= ab (+ (* 0.3 0.5) (* 0.7 (+ (* 0.3 2.0) (* 0.7 1.0)))))))
(define c2 (and bc (~= bc 4.0)))

;; ── merge: observed wins per key, priors fill the rest ──────────────────────
(define merged (arc-table-merge '(("A|B|pedestrian" . 9.0) ("C|D|auto" . 0.2))
                                folded))
(define c3 (~= (assoc-ref merged "A|B|pedestrian") ab))   ; observed shadows prior
(define c4 (~= (assoc-ref merged "C|D|auto") 0.2))        ; prior survives
(define c5 (~= (assoc-ref merged "B|C|bicycle") 4.0))

;; ── canonical period-classes: the one vocabulary, TZ-pinned ──────────────────
(setenv "TZ" "UTC")
;; 2026-06-12 is a Friday (09:00/14:00/02:00 UTC) + Saturday Jun 13 noon
(define cls-am    (epoch->period-class 1781254800))   ; Fri 09:00
(define cls-pm    (epoch->period-class 1781272800))   ; Fri 14:00
(define cls-night (epoch->period-class 1781229600))   ; Fri 02:00
(define cls-we    (epoch->period-class 1781352000))   ; Sat 12:00
(define c9  (equal? (list cls-am cls-pm cls-night cls-we)
                    '("wd-am" "wd-pm" "wd-night" "we")))
(define c10 (let ((dts (period-class-date-times)))
              (and (= 4 (length dts))
                   (every (lambda (pc) (assoc pc dts)) %period-classes)
                   ;; values are date-stamped clock strings, computed not rotted
                   (string=? (substring (assoc-ref dts "wd-am") 10) "T08:30"))))

;; ── prior file roundtrip ─────────────────────────────────────────────────────
(define tmp (string-append (or (getenv "TMPDIR") "/tmp") "/priors-test.sexp"))
(routing-save-priors! tmp 1234567 '(("A|B|pedestrian" . 0.42) ("B|A|pedestrian" . 0.40)))
(define loaded (routing-load-priors tmp))
(define c6 (and (= 2 (length loaded)) (~= (assoc-ref loaded "A|B|pedestrian") 0.42)))
(define c7 (equal? (routing-priors-stamp tmp) 1234567))
(define c8 (null? (routing-load-priors "/nonexistent/priors.sexp")))  ; absent → '()
(delete-file tmp)

(for-each (lambda (ok label) (format #t "  [~a] ~a~%" (if ok "✓" "✗") label))
          (list c1 c2 c3 c4 c5 c6 c7 c8 c9 c10)
          '("EWMA matches closed form (3 samples, α=0.3)"
            "single sample seeds at its own value"
            "merge: observed shadows the prior"
            "merge: un-observed prior survives"
            "merge: observed-only key survives"
            "prior file roundtrips entries"
            "prior file roundtrips the tileset stamp"
            "missing prior file reads as empty table"
            "epoch->period-class: am/pm/night/weekend, TZ-pinned"
            "period-class date_times: 4 classes, computed dates, fixed clocks"))
(let ((ok (and c1 c2 c3 c4 c5 c6 c7 c8 c9 c10)))
  (format #t "~%  ~a arc-time pure folds~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
