;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-multiperiod-binding.scm — record-path multi-period via #:periods (no horizon).
;;;
;;; REGRESSION GUARD for the ingest-located! periods-binding: the agent-supply
;;; loop must iterate the `periods` it was handed, so a worker supplies labour in
;;; EVERY period — not just period 0. This is the exact case that would silently
;;; break if the loop ever read *periods* (or a stale binding) instead of the
;;; periods it was called with. No horizon here — plain #:periods '(0 1), the way
;;; the engine has always supported multi-period through the record path.
;;;
;;; Bread wanted at town in period 0 (3) and period 1 (3); Ada bakes (labour-only,
;;; 8h available any day). If the binding holds, work happens in BOTH periods.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-multiperiod-binding.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve plan) (playnet solve world)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define win (all-week-window "09:00" "17:00"))
(define agents (list (person* "ada" #:name "Ada" #:window win)))
(define spatials (list (place* "town")))
(define resources (list (er "sk-ada" "skill-bake" "ada" #:unit "kg")))
(define procs (list (rp* "bake" "Bake")))
(define flows (list (out* "f1" "bread" 1.0 "bake")
                    (wk* "f3" "skill-bake" 1.0 "bake")))
(define demand (list (cons "bread#town@0" 3.0) (cons "bread#town@1" 3.0)))   ; period 0 AND period 1

(set! *emp-rho* 0.0001)
(define-values (intents coms material fill cols x idx ntot report)
  (plan-from-records resources agents spatials procs flows
    #:demand demand #:periods '(0 1) #:backend 'native-c))   ; explicit multi-period, NO horizon

(define (bake-at c) (let ((i (hash-ref idx (string-append "p|bake|town@" (number->string c)) #f)))
                      (if i (vector-ref x i) 0.0)))
(define worker-cells
  (filter (lambda (k) (and (>= (string-length k) 2) (string=? (substring k 0 2) "w|")))
          (hash-map->list (lambda (k v) k) idx)))

(format #t "~%── record-path multi-period · #:periods '(0 1) · no horizon · bread 3@p0 + 3@p1 ──~%")
(format #t "  periods=~s   demand met: ~,1f%~%" *periods* (* 100 fill))
(format #t "  bake @period 0 = ~,1f , @period 1 = ~,1f~%" (bake-at 0) (bake-at 1))
(format #t "  worker columns: ~s~%" worker-cells)

(let* ((c1 (equal? *periods* '(0 1)))
       (c2 (> fill 0.95))                                    ; both periods' demand met
       (c3 (and (> (bake-at 0) 2.0) (> (bake-at 1) 2.0)))    ; production in BOTH periods
       (c4 (and (member "w|ada|skill-bake|town@0" worker-cells)   ; Ada supplies labour in BOTH
                (member "w|ada|skill-bake|town@1" worker-cells)))
       (ok (and c1 c2 c3 c4)))
  (format #t "~%  [~a] two periods planned                              (~s)~%" (if c1 "✓" "✗") *periods*)
  (format #t "  [~a] demand met in BOTH periods                       (~,1f%)~%" (if c2 "✓" "✗") (* 100 fill))
  (format #t "  [~a] production happens in both periods, not just 0    (~,1f , ~,1f)~%" (if c3 "✓" "✗") (bake-at 0) (bake-at 1))
  (format #t "  [~a] Ada has a worker column in BOTH periods           (the binding)~%" (if c4 "✓" "✗"))
  (format #t "~%  ~a record-path #:periods multi-period works — the agent-supply binding holds~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
