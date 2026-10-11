;;; test-arc-time-parity.scm — STRICT PARITY of the arc-hours rewrite.
;;;
;;; The arc-time table must be invisible when empty: every rewritten call site
;;; (reachability, hrs-coeff, material move, rider transit) falls back to its
;;; original rate×haversine closure, so the geometric planner's numbers are
;;; reproduced EXACTLY — structurally, not approximately. Three locks:
;;;
;;;   1. hrs-coeff in the worker bundle == 1 + τ·km(home,c), closed form;
;;;   2. solving with an EMPTY table == solving with a table that ENCODES the
;;;      same τ·km values (the fallback and the table agree bit-for-bit);
;;;   3. the commute scenario's (direct transport care) ledger is unchanged
;;;      between two identical runs (determinism guard for 2's comparison).
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-arc-time-parity.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve world))

(define (setup!)
  (declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.9))   ; ~100 km east
                  #:templates (list (list "treat" (list (cons "care" 1.0)) '() 1.0 (list (cons "doctor" 1.0))))
                  #:workers (list (list "W" '("doctor") (cell "A" 0) 40.0))
                  #:commute-km 200.0
                  #:tau-commute 0.002)
  (hash-set! *demand* (lg "care" (cell "B" 0)) 60.0))

(define (run-ledger)
  (call-with-values solve-located
    (lambda (x forms labform cols goods raws idx)
      (let ((ldg (worker-ledger x idx))
            (care (let ((i (hash-ref idx "p|treat|B@0" #f))) (if i (vector-ref x i) 0.0))))
        (append ldg (list care))))))

;; ── 1. hrs-coeff closed form with the empty table ────────────────────────────
(setup!)
(define d-km (km (cell "A" 0) (cell "B" 0)))
(define ledger-empty (run-ledger))
;; *worker-bundles* was generalized to *supplier-bundles* (workers AND means
;; suppliers share one bundle shape, distinguished by the trailing labour? flag);
;; a worker bundle's entries are still at the same position (cadddr).
(define coeff-B
  (let* ((bundle (find (lambda (b) (equal? (car b) "W")) *supplier-bundles*))
         (entry  (find (lambda (e) (equal? (cadr e) "B@0")) (cadddr bundle))))
    (and entry (caddr entry))))
(define c1 (and coeff-B (= coeff-B (+ 1.0 (* *tau-commute* d-km)))))   ; exact, not ~=

;; ── 2. empty table == table encoding the very same τ·km values ──────────────
(setup!)
(hash-set! *arc-hours* "A|B|pedestrian" (* 0.002 d-km))   ; what the fallback computes
(hash-set! *arc-hours* "B|A|pedestrian" (* 0.002 d-km))
(define ledger-encoded (run-ledger))
(define c2 (equal? ledger-empty ledger-encoded))

;; ── 3. determinism guard (re-run reproduces itself) ─────────────────────────
(setup!)
(define c3 (equal? ledger-empty (run-ledger)))

(for-each (lambda (ok label) (format #t "  [~a] ~a~%" (if ok "✓" "✗") label))
          (list c1 c2 c3)
          (list (format #f "hrs-coeff == 1 + τ·km exactly (~,4f @ ~,1f km)" (or coeff-B 0) d-km)
                "empty table ≡ table encoding τ·km (bit-identical ledgers)"
                "identical runs reproduce identical ledgers"))
(let ((ok (and c1 c2 c3)))
  (format #t "~%  ~a strict parity: the arc-time table is invisible when empty~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
