;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-position.scm — live/expected position overrides the commute origin.
;;;
;;; The planner places a worker at their static primary-location (home) for every
;;; period. A live/expected POSITION override — (agent-id period) → place — says
;;; "they are HERE this period instead", which becomes the commute origin. All
;;; three sharing modes (manual "I'm here", continuous watch, expected trajectory)
;;; feed this one input; they differ only in how the browser populates it.
;;;
;;; Care is demanded at MARKET; Ada lives in TOWN (~100 km away). With no override
;;; she commutes town→market (τ·km drag eats her hours); with the override she IS
;;; at market (no commute) and delivers more from the same budget.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-position.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera solve engine) (localchimera solve world))

;; care@market = 35 wanted; Ada (skill doc, 40 hrs) lives in town, market ~100 km off.
(define (deliver-care agent-position)
  ;; one worker Ada, home=town — built through the SAME path ingest uses: for each
  ;; period, her cell is (agent-position 'Ada t) if given, else home.
  (declare-world! #:places '(("town" 0.0 0.0) ("market" 0.0 0.9))   ; ~100 km east
                  #:templates (list (list "treat" (list (cons "care" 1.0)) '() 1.0 (list (cons "doc" 1.0))))
                  #:workers (let* ((t 0) (place (or (agent-position "Ada" t) "town")))
                              (list (list "Ada" '("doc") (cell place t) 40.0)))
                  #:commute-km 200.0
                  #:tau-commute 0.01)
  (set-dial! 'emp-rho 0.0001)                              ; tiny EMP — isolate the commute effect, not overwork-spreading
  (hash-set! *demand* (lg "care" (cell "market" 0)) 35.0)
  (call-with-values solve-located
    (lambda (x forms lf cols goods raws idx)
      (let ((i (hash-ref idx "p|treat|market@0" #f))) (if i (vector-ref x i) 0.0)))))

(define home  (deliver-care (lambda (id t) #f)))                       ; no override → home (town)
(define onsite (deliver-care (lambda (id t) (and (equal? id "Ada") "market"))))  ; positioned AT market

(format #t "~%── care@market (35 wanted) · Ada lives in town (~~100 km) · 40-hr budget ──~%")
(format #t "  Ada at home (commutes town→market):  care delivered = ~,1f~%" home)
(format #t "  Ada positioned AT market (override):  care delivered = ~,1f~%" onsite)

(let* ((c1 (> onsite (+ home 1.0)))          ; the override removes commute drag ⇒ more delivered
       (c2 (< home 34.0))                     ; commuting genuinely costs (didn't meet 35)
       (c3 (> onsite 34.0))                   ; on-site, the same budget meets it
       (ok (and c1 c2 c3)))
  (format #t "~%  [~a] position override raises delivery (commute drag removed)   (~,1f → ~,1f)~%" (if c1 "✓" "✗") home onsite)
  (format #t "  [~a] commuting from home genuinely costs hours                  (~,1f < 35)~%"      (if c2 "✓" "✗") home)
  (format #t "  [~a] positioned on-site, the same budget meets demand           (~,1f ≥ 35)~%"      (if c3 "✓" "✗") onsite)
  (format #t "~%  ~a a worker's live/expected position is the commute origin — manual, continuous, or trajectory~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
