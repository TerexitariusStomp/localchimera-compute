;;; demo.scm — the engine's self-test, worked scenarios and scale benchmarks.
;;;
;;; §9 of planner.scm, which is a SCRIPT and was living inside a library. The
;;; separation is what `PLANNER_LIB=1` was standing in for: every one of the
;;; ~137 files that load the engine set that variable, for no reason other than
;;; to say "I am not the demo". Loading a library should not need announcing.
;;;
;;; Run:  guile -L module module/playnet/deprecated/planner/attic/demo.scm
;;;
;;; It also holds the synthetic-world fixture the scale benches share
;;; (`build-world` / `timed` / `solve*`) and the §9e store mock. Those are demo
;;; apparatus too — `(define store (mock-store))` at the engine's top level meant
;;; every module that primitive-load'ed the engine silently acquired a `store`
;;; bound to a mock, and a `$` shim beside it.

(use-modules (playnet solve engine) (playnet test planner worked-example) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (srfi srfi-1)
             (ice-9 format))
;; …and now run it. *demos?* is this file's own business — it used to live in
;; solver.scm, deriving from PLANNER_LIB, which is how a library came to have an
;; opinion about whether it was being run as a program.
(define *demos?* #t)

;; the scale-bench world generator, shared with bench/bench-scale.scm
(primitive-load
  (or (and=> (current-filename) (lambda (f) (string-append (dirname f) "/bench/world.scm")))
      (%search-load-path "playnet/bench/world.scm")
      (string-append (getcwd) "/module/playnet/bench/world.scm")))

;; ════════════════════════════════════════════════════════════════════════════
;; §9 — run the self-test + scenarios
;; ════════════════════════════════════════════════════════════════════════════
(when *demos?*
  (self-test)
  (format #t "~%==== §6 VF RECORDS → SPACETIME OPTIMUM (compiled, one solve) ====~%")
  (format #t "compiled ~a templates: ~a~%" (length *templates*) (map proc-id *base-templates*))
  (for-each (lambda (be)
    (set! *backend* be)
    (format #t "~%-- [~a] SPACE: cheap transport --~%" be)  (setup-space 0.002) (report-located)
    (format #t "~%-- [~a] SPACE: dear transport --~%" be)   (setup-space 0.04)  (report-located)
    (format #t "~%-- [~a] TIME: deep valley (t1=40), storable --~%" be) (setup-time 40.0 0.01 #t) (report-located)
    (format #t "~%-- [~a] RECIPE: soil SCARCE (60) → mix in cassava --~%" be) (setup-recipe 60.0) (report-located))
    '(native osqp))
  (parity-assert 0.02))
(set! *backend* 'native)
(when *demos?*
  (format #t "~%==== §7 DISCRETE: minimum-batch (run ≥80 or not at all) ====~%")
  (format #t "~%-- BATCH: HIGH demand (100) → big mill worth turning ON --~%") (setup-batch 100.0) (report-discrete)
  (format #t "~%-- BATCH: LOW demand (40) → a batch would overproduce; OFF --~%") (setup-batch 40.0) (report-discrete))

;; reserve tranche: bread demand 100 + reserve 40 (low weight); ample vs scarce labour
(when *demos?*
(format #t "~%==== §8a RESERVE: the lowest-priority desire tranche ====~%")
(format #t "   bread: consume 100 (w=1000) + reserve 40 (w=80)~%")
(for-each (lambda (lab tag)
  (setup-reserve lab)
  (call-with-values solve-located (lambda (x forms labform cols goods raws idx)
    (let* ((g (lg "bread" "town@0"))
           (dlv (fold (lambda (c a) (let ((fc (assoc g (col-flows c)))) (if fc (+ a (* (cdr fc) (vector-ref x (hash-ref idx (col-key c))))) a))) 0.0 cols)))
      (format #t "   labour ~a (~a): bread ~,1f  → consume ~,1f/100, reserve ~,1f/40~%"
              lab tag dlv (min 100.0 dlv) (max 0.0 (- dlv 100.0)))))))
  (list 400.0 135.0) (list "ample" "scarce")))

;; ── §9c SCALE: near-linear on BLOCK-SPARSE spacetime structure ───────────────
;; P places × T periods; each cell a chain of K goods, per-cell labour & eco
;; (block-sparse), storage (time) + transport (space) moves, every cell wants g0.
;; n ≈ 3·P·T·K activities. Same forms, same solver — now measured at scale.
(when *demos?*
(format #t "~%==== §9c SCALE: near-linear on BLOCK-SPARSE spacetime (native) ====~%")
(format #t "    P    T   K       n      nnz   newton   cg     ms    µs/n   met~%")
(set! *backend* 'native)
(for-each (lambda (cfg)
  (let ((P (car cfg)) (T (cadr cfg)) (K (caddr cfg)))
    (call-with-values (lambda () (build-world P T K))
      (lambda (forms labform n nnz x0)
        (let* ((C (flatten forms)) (res (timed (lambda () (solve-native forms labform x0))))
               (ms (car res)) (x (cadr res)) (cgtot (cadddr res)) (ntot (list-ref res 4)))
          (format #t "  ~3a  ~3a  ~2a  ~6a  ~7a   ~4a  ~5a  ~6,0f  ~6,1f  ~4,0f%~%"
                  P T K n nnz ntot cgtot ms (/ (* 1000.0 ms) (max 1 n)) (* 100.0 (mean-fill C x))))))))
  '((4 4 4) (8 8 4) (12 12 4) (16 16 5) (22 22 5))))

;; ── §9d METABOLISM: warm re-solve on an event vs cold from scratch ───────────


(when *demos?*
(format #t "~%==== §9d METABOLISM: re-solve on an event (warm from the standing plan) ====~%")
(call-with-values (lambda () (build-world 8 8 4))
  (lambda (forms lf n nnz x0)
    (let* ((C (flatten forms)) (base (solve* forms lf x0)) (x1 (car base)))
      (format #t "  base plan:                          ~a Newton steps, ~,1f% met~%" (list-ref base 3) (* 100 (mean-fill C x1)))
      (call-with-values (lambda () (build-world 8 8 4 (lambda (p t) (if (= p 0) 150.0 100.0))))
        (lambda (f2 lf2 n2 z2 x02)
          (let* ((C2 (flatten f2)) (warm (solve* f2 lf2 x1 0.03)) (cold (solve* f2 lf2 x02 1.0)))
            (format #t "  --- event: demand surges ×1.5 across place 0 ---~%")
            (format #t "  WARM (from standing plan): ~a Newton steps, ~,1f% met~%" (list-ref warm 3) (* 100 (mean-fill C2 (car warm))))
            (format #t "  COLD (from scratch):       ~a Newton steps, ~,1f% met~%" (list-ref cold 3) (* 100 (mean-fill C2 (car cold)))))))) )))

;; ── §9e REAL DATA: plan over the codebase's actual recipe knowledge ──────────
;; Load knowledge/recipes/federation.scm (the real VF records) by mocking the
;; store, compile them, and route through the SAME located pipeline (one cell).
(define *fed-procs* '()) (define *fed-flows* '()) (define *fed-specs* '())
(define (mock-store) (lambda (msg . args)
  (case msg ((add-recipe-process) (set! *fed-procs* (cons (car args) *fed-procs*)))
            ((add-recipe-flow)    (set! *fed-flows* (cons (car args) *fed-flows*)))
            ((add-resource-spec)  (set! *fed-specs* (cons (car args) *fed-specs*)))
            (else #t))))
;; mock near-call for the standalone §9e federation demo (federation.scm calls
;; ($ store …)). When this engine is loaded into a Goblins module the real $ is
;; already imported — do NOT shadow it, or live.scm's actor near-calls break.
(unless (module-defined? (current-module) '$)
  (module-define! (current-module) '$ (lambda (obj msg . args) (apply obj msg args))))
(define store (mock-store))
(when *demos?*
(let ((fed (string-append (dirname (or (current-filename) (string-append (getcwd) "/module/playnet/planner/x"))) "/knowledge/recipes/federation.scm")))
  (when (file-exists? fed)
    (primitive-load fed) (seed-federation-specs store) (seed-federation-recipes store)
    (let ((specname (make-hash-table)))
      (for-each (lambda (s) (hash-set! specname (resource-specification-id s) (resource-specification-name s))) *fed-specs*)
      (set! *backend* 'native) (declare-world! #:places '(("fed" 0.0 0.0))
                                               #:templates (compile-recipe (reverse *fed-procs*) *fed-flows*))
      (hash-set! *demand* (lg "spec-bread" "fed@0") 100.0) (hash-set! *demand* (lg "spec-cheese" "fed@0") 40.0)
      (format #t "~%==== §9e REAL DATA: plan over federation.scm recipes (~a processes) ====~%" (length *templates*))
      (call-with-values solve-located (lambda (x forms labform cols goods raws idx)
        (for-each (lambda (c) (when (and (string-prefix? "p|" (col-key c)) (> (vector-ref x (hash-ref idx (col-key c))) 0.05))
            (let ((tpl (find (lambda (t) (equal? (string-append "p|" (proc-id t) "|fed@0") (col-key c))) *templates*)))
              (format #t "   ~12a ~6,1f runs~a~%" (proc-id tpl) (vector-ref x (hash-ref idx (col-key c)))
                      (string-concatenate (map (lambda (oq) (format #f "  ~a ~,1f" (hash-ref specname (car oq) (car oq)) (* (vector-ref x (hash-ref idx (col-key c))) (cdr oq)))) (proc-outputs tpl)))))))
          cols)
        (for-each (lambda (gd)
          (let* ((g (car gd)) (D (cdr gd))
                 (dlv (fold (lambda (c a) (let ((fc (assoc g (col-flows c)))) (if fc (+ a (* (cdr fc) (vector-ref x (hash-ref idx (col-key c))))) a))) 0.0 cols)))
            (format #t "   demand ~a: ~,1f/~a  (~,0f% met)~%" g dlv D (* 100.0 (min 1.0 (/ dlv D))))))
          (list (cons (lg "spec-bread" "fed@0") 100.0) (cons (lg "spec-cheese" "fed@0") 40.0)))))))))
(newline)
