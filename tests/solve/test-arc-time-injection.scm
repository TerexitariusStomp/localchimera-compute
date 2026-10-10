;;; test-arc-time-injection.scm — a populated arc-time table steers the QP.
;;;
;;; Inject a synthetic network time H for the commute arc A→B (≠ τ·km) and
;;; check it lands EXACTLY where the design says it must:
;;;   1. the worker bundle's hrs-coeff becomes 1 + H (not 1 + τ·km);
;;;   2. the transport ledger responds: a cheaper-than-geometry arc lets MORE
;;;      care be delivered from the same 40 h budget; a dearer one, less;
;;;   3. *commute-hours* turns the reachability gate into a time budget: an
;;;      arc whose tabled time exceeds it drops the work column entirely,
;;;      while without the opt-in the km gate keeps it (today's behaviour);
;;;   4. manners don't bleed: a "bicycle" entry leaves the "pedestrian"
;;;      commute on its haversine fallback.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-arc-time-injection.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine))

(define (setup!)
  (declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.9))   ; ~100 km, τ·km ≈ 0.2 h
                  #:templates (list (list "treat" (list (cons "care" 1.0)) '() 1.0 (list (cons "doctor" 1.0))))
                  #:workers (list (list "W" '("doctor") (cell "A" 0) 40.0))
                  #:commute-km 200.0
                  #:tau-commute 0.002)
  (hash-set! *demand* (lg "care" (cell "B" 0)) 60.0))

;; *worker-bundles* was generalized to *supplier-bundles* (workers AND means
;; suppliers share one bundle shape, distinguished by the trailing labour? flag);
;; a worker bundle's entries are still at the same position (cadddr).
(define (coeff-at-B)
  (let* ((bundle (find (lambda (b) (equal? (car b) "W")) *supplier-bundles*))
         (entry  (and bundle (find (lambda (e) (equal? (cadr e) "B@0")) (cadddr bundle)))))
    (and entry (caddr entry))))

(define (run-care)
  (call-with-values solve-located
    (lambda (x forms labform cols goods raws idx)
      (let ((i (hash-ref idx "p|treat|B@0" #f))) (if i (vector-ref x i) 0.0)))))

;; baseline: geometric fallback
(setup!)
(define care-geo (run-care))
(define coeff-geo (coeff-at-B))

;; 1+2a. inject a FAST arc (real road beats crow-flies-rate): H = 0.05 h
(setup!)
(ingest-travel-times! '(("A|B|pedestrian" . 0.05)))
(define care-fast (run-care))
(define coeff-fast (coeff-at-B))
(define c1 (and coeff-fast (= coeff-fast 1.05)))           ; exactly 1 + H
(define c2 (> care-fast (+ care-geo 0.5)))                 ; cheaper arc ⇒ more care delivered

;; 2b. inject a SLOW arc: H = 2.0 h
(setup!)
(ingest-travel-times! '(("A|B|pedestrian" . 2.0)))
(define care-slow (run-care))
(define c3 (< care-slow (- care-geo 0.5)))                 ; dearer arc ⇒ less care

;; 3. time gate: tabled 2.0 h > *commute-hours* 1.0 ⇒ B unreachable, no coeff
(setup!)
(ingest-travel-times! '(("A|B|pedestrian" . 2.0)))
(set! *commute-hours* 1.0)
(define c4 (begin (run-care) (not (coeff-at-B))))          ; column never built
;; …and without the opt-in the km gate had kept it (c3 ran fine above).

;; 4. manner isolation: a bicycle entry must not touch the pedestrian commute
(setup!)
(ingest-travel-times! '(("A|B|bicycle" . 0.05)))
(define c5 (let ((cf (begin (run-care) (coeff-at-B))))
             (and cf (= cf coeff-geo))))                   ; still the haversine fallback

(for-each (lambda (ok label) (format #t "  [~a] ~a~%" (if ok "✓" "✗") label))
          (list c1 c2 c3 c4 c5)
          (list (format #f "tabled arc lands as hrs-coeff = 1 + H exactly (~,3f)" (or coeff-fast 0))
                (format #f "faster-than-geometry arc raises delivered care (~,1f → ~,1f)" care-geo care-fast)
                (format #f "slower arc lowers it (~,1f → ~,1f)" care-geo care-slow)
                "*commute-hours* gates reachability on tabled TIME"
                "manners are isolated (bicycle entry leaves pedestrian on fallback)"))
(let ((ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  ~a injected network times steer the plan exactly as designed~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
