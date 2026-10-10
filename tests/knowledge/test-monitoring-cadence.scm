;;; test-monitoring-cadence.scm — survey labour narrows a boundary, and buys α
;;; back off the precautionary floor.
;;;
;;; `vf/formulas/cadence.scm` already derives a recert cadence from the load a
;;; plan routes through a skill edge: edge-reliance(throughput, harm) → a* → an
;;; interval. Nothing in that chain is skill-specific — LOADS is `((edge . hours)
;;; …)`, read off a live solve. An ecological boundary's DRAW is the same shape,
;;; so `limit-monitoring-cadence` derives a SURVEY cadence for a limit with no new
;;; engine machinery: a second adapter over the fold that already exists, the same
;;; move `mean-shocks` makes between forecast and Observer calibration.
;;;
;;; What IS new is `monitored-alpha`: today α is a static governance choice
;;; (eco-catalogue.scm's own words, "political-economic choices, NOT engineering
;;; constants"). A federation that surveys a boundary — commits the labour a*
;;; prices — has bought down its uncertainty about where s_tip sits, and [lo,hi]
;;; is exactly that uncertainty. monitored-alpha reads the same a* the cadence
;;; produces and lets α rise from the catalogue's precautionary floor toward
;;; central (0.5), never past it, never below the governed floor. Confidence is
;;; earned, not spent into recklessness — and it costs real hours, priced by the
;;; same inspection-intensity every skill edge already pays.
;;;
;;; Run: guile --no-auto-compile -L module/playnet/planner \
;;;        tests/knowledge/test-monitoring-cadence.scm

(use-modules (srfi srfi-1) (ice-9 format))
;; edge-reliance / inspection-intensity / reliance->valid-until — the generic
;; inspection chain (formulas/cadence), which the catalogue below imports.
(use-modules (playnet knowledge catalogues eco))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(format #t "~%── survey labour, and where α moves ──~%~%")
(format #t "  ~10a ~a~%" "draw" "α (warming, floor 0.0)")
(format #t "  ~10a ~a~%" "────" "───────────────────────")
(define draws '(0.0 0.01 0.05 0.1 0.2 1.0))
(define alphas (map (lambda (d) (monitored-alpha "warming" d)) draws))
(for-each (lambda (d a) (format #t "  ~10,3f ~,3f~%" d a)) draws alphas)

(format #t "~%")
(check "with no survey, α stays exactly at the catalogue's precautionary floor"
       (= 0.0 (first alphas)))
;; NON-decreasing throughout (the reliance floor holds α flat at the catalogue's
;; own floor for a while — the same "barely used, never worth checking" shape the
;; skill-edge cadence already has), and strictly higher by the far end.
(check "α rises with survey labour committed, once past the reliance floor"
       (and (apply <= alphas) (> (last alphas) (first alphas))))
(check "α never exceeds the CENTRAL reading — confidence does not license recklessness"
       (every (lambda (a) (<= a 0.5)) alphas))
(check "at the shortest cadence the plan will pay for (a*→1), α reaches central"
       (> (last alphas) 0.499))
;; a barely-drawn boundary is not worth surveying — the same reliance FLOOR the
;; skill-edge cadence already has (a* = 0 below D ≤ λℓ/κ)
(check "a boundary drawn below the reliance floor gets no boost at all"
       (= 0.0 (monitored-alpha "warming" 0.001)))

;; phosphorus's governed floor is CENTRAL already (0.5) — monitoring can buy it
;; nothing further, and must not push it PAST central either
(check "a limit whose floor is already central gains nothing from monitoring"
       (let ((base (list-ref (assoc "phosphorus" *planetary-catalogue*) 4)))
         (= base (monitored-alpha "phosphorus" 1.0))))

;; ── the cadence itself: the same fold conformance-recert-schedule runs ───────
;; THE SAME draw on both, so the only difference is each limit's own governance
;; weight — warming's harm is 10, nitrogen's 5 (*planetary-catalogue*) — chosen
;; small enough that neither saturates a* to 1 (both intervals stay informative).
(define cadence (limit-monitoring-cadence '(("warming" . 0.25) ("nitrogen" . 0.25))
                                          #:period-span 1.0))
(format #t "~%── survey cadence, SAME draw, different governance weight ──~%")
(for-each (lambda (kv) (format #t "  ~a → ~a~%" (car kv) (cdr kv))) cadence)

(check "every drawn limit gets a cadence entry"
       (= 2 (length cadence)))
(check "at equal draw, the HEAVIER-weighted limit (warming, w=10) is surveyed more often"
       (let ((n (assoc-ref cadence "nitrogen")) (w (assoc-ref cadence "warming")))
         (and n w (< w n))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a boundary a federation surveys is a boundary it~%  can afford to trust further, and the price is the same labour every~%  conformance edge already pays to stay known.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
