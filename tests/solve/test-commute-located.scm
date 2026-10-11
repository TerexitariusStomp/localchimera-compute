;;; test-commute-located.scm — commute is real budget-time (faux frais), not a free pass.
;;;
;;; Commute is the spatial transport of a person's own time: hours that leave home
;;; and don't arrive as work. With *tau-commute* > 0, a worked hour at a distant
;;; cell draws hrs-coeff = 1 + τ·km from the person's ONE time budget — so commuting
;;; eats into productive capacity and free time, exactly like any other claim on the
;;; day. (The convex core carries the LINEAR amortisation of this; the sharp per-trip
;;; fixed charge — pay the round-trip iff you go at all — is a §B8 discrete refinement.)
;;;
;;; One worker W lives at A; all care is demanded at B, ~100 km away (within commute
;;; range). With τ=0, work is free to happen at B. With τ>0, each B-hour also spends
;;; commute hours: productive output drops, faux frais appears in the ledger, and the
;;; free-time accounting nets it (it is neither value-creating labour nor leisure).
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-commute-located.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve world))

(define (run tau)
  (declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.9))   ; ~100 km east of A
                  #:templates (list (list "treat" (list (cons "care" 1.0)) '() 1.0 (list (cons "doctor" 1.0))))
                  #:workers (list (list "W" '("doctor") (cell "A" 0) 40.0))   ; lives at A, 40 hrs
                  #:commute-km 200.0   ; can reach B
                  #:tau-commute tau)
  (hash-set! *demand* (lg "care" (cell "B" 0)) 60.0) ; all care demanded at B
  (call-with-values solve-located
    (lambda (x forms labform cols goods raws idx)
      (let ((ldg (worker-ledger x idx))              ; (direct transport training)
            (care (let ((i (hash-ref idx "p|treat|B@0" #f))) (if i (vector-ref x i) 0.0)))
            (km (km (cell "A" 0) (cell "B" 0))))
        (list (first ldg) (second ldg) care km)))))  ; (prod faux care km)

(define free (run 0.0))      ; commute is free
(define real (run 0.002))    ; commute costs τ·km budget-hours per worked hour
(define (prod r) (first r)) (define (faux r) (second r)) (define (care r) (third r)) (define (km-of r) (fourth r))

(format #t "~%── one worker at A, all demand at B (~~~,0f km, budget 40 hrs) ──~%" (km-of free))
(format #t "  ~12a  ~10a  ~10a  ~10a~%" "τ·km" "productive" "faux frais" "care@B")
(format #t "  ~12a  ~10,1f  ~10,1f  ~10,1f~%" "0 (free)"  (prod free) (faux free) (care free))
(format #t "  ~12,3f  ~10,1f  ~10,1f  ~10,1f~%" (* 0.002 (km-of real)) (prod real) (faux real) (care real))

(let* ((c1 (< (faux free) 0.01))                       ; τ=0: no faux frais
       (c2 (> (faux real) 1.0))                         ; τ>0: commute is real budget time
       (c3 (< (care real) (- (care free) 1.0)))         ; commute eats productive output
       (c4 (< (prod real) (- (prod free) 1.0)))         ; fewer productive hours when commuting costs time
       (ok (and c1 c2 c3 c4)))
  (format #t "~%  [~a] τ=0 spends no commute hours                 (faux = ~,2f)~%"            (if c1 "✓" "✗") (faux free))
  (format #t "  [~a] τ>0: commute draws real budget hours          (faux = ~,1f)~%"            (if c2 "✓" "✗") (faux real))
  (format #t "  [~a] commute reduces productive care delivered     (care ~,1f → ~,1f)~%"       (if c3 "✓" "✗") (care free) (care real))
  (format #t "  [~a] commute reduces productive labour hours       (prod ~,1f → ~,1f)~%"       (if c4 "✓" "✗") (prod free) (prod real))
  (format #t "~%  ~a commute is faux frais: real time off the one budget, value nowhere — not a free pass~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
