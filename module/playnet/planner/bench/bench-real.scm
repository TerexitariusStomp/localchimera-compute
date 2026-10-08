;;; bench-real.scm — the convex planner on a REAL national input-output table.
;;;
;;; Reads a preprocessed I-O table (default: docs/data/wiod/wiod2014.sexp, emitted
;;; by docs/_scripts/wiod_preprocess.py from the WIOD 2016 release, year 2014 —
;;; 44 regions × 56 ISIC sectors = 2464 sectors, a CLOSED world model so imports
;;; are internal flows). Unlike bench-io.scm (which SYNTHESISES a shallow, well-
;;; conditioned table) this feeds the real direct-requirements matrix A=Z/x with
;;; all of its dense feedback loops.
;;;
;;; Each sector j is ONE production activity (column): output good j at +1, each
;;; input good i at −a_ij. The goods balance for g is row g of (I−A)x ≥ 0; final
;;; demand becomes a desire-tension (`des`) toward DEMAND_g; primary factors
;;; (labour hours, CO₂) are possibility-tensions — aggregate `bar` caps. No engine
;;; change; this is bench-io's assembly with the generator swapped for a reader.
;;;
;;; THREE things make it self-sufficient on real data (no external solver crutch):
;;;
;;;   1. SELF-SEEDING START (recipe-backtrace). The plan seeds itself by propagating
;;;      final demand UPSTREAM through the recipe graph — final demand, plus the
;;;      inputs to make it, plus the inputs to make those, … (the doc's "loud gaps
;;;      propagate upstream; derived demands are pulled exactly as hard as what they
;;;      hold up"). The sum x=Σ_k A^k·d converges because ρ(A)<1, and gives a plan
;;;      whose books balance everywhere by construction — so the solver starts
;;;      strictly inside every possibility-tension and never enters a stuck Phase-I.
;;;
;;;   2. INVENTORY CUSHION. A few sectors net-CONSUMED that year (drew stock down):
;;;      their net final demand is negative. We split each into a DEMAND (positive
;;;      part) and an on-hand STOCK cushion (|negative part|) that sits as the
;;;      balance's constant term — so the warehouse sectors balance honestly instead
;;;      of being clamped to zero.
;;;
;;;   3. GRADUAL TIGHTENING (homotopy). A binding cap ("10% less labour") is reached
;;;      by easing the screw down a step at a time, re-settling the plan from the
;;;      previous rung (scaled to fit the new cap) — never restarting from a plan
;;;      that violates the new rule. This is what makes rationing sensible instead
;;;      of a panic-collapse.
;;;
;;; Run: guile --no-auto-compile -q -L module module/playnet/planner/bench-real.scm [path.sexp]

(use-modules (srfi srfi-1) (ice-9 format) (ice-9 match))
(use-modules (playnet planner solve compile)
             (playnet planner solve solver))
(define (secs th) (let ((t0 (get-internal-run-time)))
  (call-with-values th (lambda a (cons (/ (- (get-internal-run-time) t0) (* 1.0 internal-time-units-per-second)) a)))))

;; ── load the preprocessed I-O table ─────────────────────────────────────────
(define DATA (let ((a (cdr (command-line)))) (if (pair? a) (car a) "docs/data/wiod/wiod2014.sexp")))
;; The WIOD table is DELIBERATELY not in the repo — ~880 MB of downloads plus
;; derived files, gitignored in docs/data/wiod/ and reproducible in two curls and
;; one script. That is a fair choice for a dataset this size, but it means this
;; benchmark is the one piece of evidence behind §7.12's "180,000 activities,
;; beats OSQP" that a fresh checkout cannot run. Say so, rather than dying in
;; `open-file` with a bare ENOENT that reads like a broken benchmark.
(unless (file-exists? DATA)
  (format (current-error-port)
          "~%bench-real: no I-O table at ~a~%~%~
           This benchmark runs on the real WIOD 2014 table, which is not committed~%~
           (~~880 MB of source downloads + derived files; see docs/data/wiod/.gitignore).~%~
           Regenerate it — the procedure is two downloads and one script:~%~%~
           ~4tsee docs/planning/solve/wiod-planner.md §Reproducing~%~
           ~4tcurl -L -o docs/data/wiod/SEA.xlsx       <dataverse SEA>~%~
           ~4tcurl -L -o docs/data/wiod/WIOT_excel.zip <dataverse WIOT>~%~
           ~4tpython3 docs/_scripts/wiod_preprocess.py~%~%~
           Or point this bench at another preprocessed table:~%~
           ~4tguile ... bench-real.scm /path/to/table.sexp~%~%"
          DATA)
  (exit 2))

(define IO   (call-with-input-file DATA read))
(define (fld k) (cdr (or (assq k (cdr IO)) (error "missing field" k))))
(define N      (car  (fld 'n)))
(define LABELS (car  (fld 'labels)))
(define GO     (car  (fld 'gross-output)))
(define FDR    (car  (fld 'final-demand-raw)))   ; net final demand, WITH negatives
(define HOURS  (car  (fld 'hours)))
(define CO2    (car  (fld 'co2)))
(define ATRIP  (fld 'a-triples))                 ; list of (i j a)
(define NNZ    (length ATRIP))

;; split net final demand into a positive DEMAND and an on-hand STOCK cushion
(define DEMAND (make-vector N 0.0))
(define STOCK  (make-vector N 0.0))
(do ((g 0 (+ g 1))) ((= g N))
  (let ((f (vector-ref FDR g)))
    (vector-set! DEMAND g (max 0.0 f))
    (vector-set! STOCK  g (max 0.0 (- f)))))

(define (vsum v) (let loop ((j 0) (s 0.0)) (if (= j N) s (loop (+ j 1) (+ s (vector-ref v j))))))
(define TOT-HOURS (vsum HOURS))
(define TOT-CO2   (vsum CO2))
(define TOT-DEM   (vsum DEMAND))
;; Desire weight per good. `des` pays w·((D−s)/D)² for a shortfall, so with a uniform
;; w every sector's WHOLE final demand is worth the same w — and against the free-time
;; thrift κ·ℓ·x, a large or labour-intensive sector (D·ℓ ≫ w/κ) is cheaper to abandon
;; than to serve. Weighting w = D makes a unit of shortfall cost the same everywhere
;; (marginal reward 2(1−f) per unit vs κℓ ≤ 0.011), which is what "does the solver
;; land on the Leontief point" needs. WIOD_DES_W=<number> sets a uniform weight instead
;; (1000 was the driver's constant until the 2026-09 re-measurement; see the doc).
(define des-weight
  (let ((u (and=> (getenv "WIOD_DES_W") string->number)))
    (if u (lambda (d) u) (lambda (d) d))))

;; ── recipe graph: one hop upstream  (A·v)_i = Σ_j a_ij v_j ───────────────────
(define (A-apply v)
  (let ((out (make-vector N 0.0)))
    (for-each (match-lambda ((i j a)
                (vector-set! out i (+ (vector-ref out i) (* a (vector-ref v j)))))) ATRIP)
    out))

;; ── SELF-SEEDING START: propagate demand upstream through the recipe graph ───
;; x = Σ_{k≥0} A^k·(DEMAND+ε): final demand + its inputs + inputs-of-inputs + …
;; Converges geometrically (ρ(A)<1). Delivered(x)=(I−A)x ≈ DEMAND+ε > 0 ⇒ with the
;; STOCK cushion every balance slack is strictly positive: a feasible first draft.
(define (recipe-backtrace eps maxit tol)
  (let ((x (make-vector N 0.0)) (term (make-vector N 0.0)))
    (do ((g 0 (+ g 1))) ((= g N)) (vector-set! term g (+ (vector-ref DEMAND g) eps)))
    (let loop ((k 0))
      (do ((g 0 (+ g 1))) ((= g N)) (vector-set! x g (+ (vector-ref x g) (vector-ref term g))))
      (let ((nt (A-apply term)) (m 0.0))
        (do ((g 0 (+ g 1))) ((= g N)) (set! m (max m (abs (vector-ref nt g)))))
        (if (or (>= k maxit) (< m tol)) (cons x (+ k 1))
            (begin (set! term nt) (loop (+ k 1))))))))

;; ── build the program at a given labour / CO₂ cap ───────────────────────────
;; flowsby[g] = list of (activity . coeff): own output +1 and −a_gj per consumer.
;; Balance const = STOCK[g] (inventory cushion). labform carries h_j/x_j (κ term).
(define (build-forms Lcap CO2cap)
  (let ((flowsby (make-vector N '())) (labform '()))
    (do ((j 0 (+ j 1))) ((= j N))
      (vector-set! flowsby j (cons (cons j 1.0) (vector-ref flowsby j))))
    (for-each (match-lambda ((i j a)
                (vector-set! flowsby i (cons (cons j (- a)) (vector-ref flowsby i))))) ATRIP)
    (let ((forms '()))
      ;; Every good keeps its balance: delivered + stock ≥ 0 is a wall (`bar`), the
      ;; same one the engine emits for every good (engine.scm, "delivered ≥ 0"). A
      ;; demanded good ADDS a desire toward D on top of it. Substituting the desire
      ;; for the wall — as this driver did until 2026-09 — left a demanded good's
      ;; balance unenforced: `des` carries no barrier, so a plan could "deliver"
      ;; less than nothing and only pay w for it. The old constant path floor hid
      ;; that by overproducing everywhere; the derived floor (t = g/m) does not.
      (do ((g 0 (+ g 1))) ((= g N))
        (let ((bar (mk-bar (vector-ref STOCK g) (vector-ref flowsby g))) (d (vector-ref DEMAND g)))
          (set! forms (cons bar forms))
          (when (> d 0.0) (set! forms (cons (mk-des bar d (des-weight d)) forms)))))
      (let ((coeffs '()))                 ; labour cap
        (do ((j 0 (+ j 1))) ((= j N))
          (let ((go (vector-ref GO j)) (h (vector-ref HOURS j)))
            (when (and (> go 0.0) (> h 0.0))
              (let ((ell (/ h go)))
                (set! coeffs (cons (cons j (- ell)) coeffs))
                (set! labform (cons (cons j ell) labform))))))
        (set! forms (cons (mk-bar Lcap coeffs) forms)))
      (let ((coeffs '()))                 ; CO₂ cap — ONLY when there is CO₂ data,
        (do ((j 0 (+ j 1))) ((= j N))     ; else mk-bar(0,'()) is a degenerate
          (let ((go (vector-ref GO j)) (e (vector-ref CO2 j)))   ; zero-slack barrier
            (when (and (> go 0.0) (> e 0.0))                     ; that wrecks the solve.
              (set! coeffs (cons (cons j (- (/ e go))) coeffs)))))
        (unless (null? coeffs) (set! forms (cons (mk-bar CO2cap coeffs) forms))))
      (do ((j 0 (+ j 1))) ((= j N)) (set! forms (cons (mk-bar 0.0 (list (cons j 1.0))) forms)))
      ;; A COSTLESS column — no inputs and no hours — is unbounded in this program:
      ;; nothing charges for its output and the barrier's −t·log x rewards more of
      ;; it without limit, so the objective has no floor along it (measured 2026-09
      ;; on the relative-ridge kernel: ROW|T ran to 9.6e14 against a published
      ;; 2.0e4 while the certificate accepted the plan). 138 columns are costless:
      ;; the 137 region×sector cells with no output at all, and ROW|T, with output
      ;; but neither recorded inputs nor hours. Each is held under its published
      ;; output (one unit where there is none) — the data's own statement of what
      ;; that sector did — and the Leontief comparison is read over the rest.
      (let ((has-input (make-vector N #f)))
        (for-each (match-lambda ((i j a) (vector-set! has-input j #t))) ATRIP)
        (do ((j 0 (+ j 1))) ((= j N))
          (when (and (not (vector-ref has-input j)) (<= (vector-ref HOURS j) 0.0))
            (set! forms (cons (mk-bar (max (vector-ref GO j) 1.0) (list (cons j -1.0))) forms)))))
      (values forms labform))))

(define (labour-used labform x)
  (fold (lambda (jl acc) (+ acc (* (cdr jl) (vector-ref x (car jl))))) 0.0 labform))
(define (scale-vec x f) (let ((y (make-vector N 0.0)))
  (do ((j 0 (+ j 1))) ((= j N)) (vector-set! y j (* f (vector-ref x j)))) y))

;; ── min goods-balance slack (feasibility readout) ───────────────────────────
(define (min-balance C x)
  (let ((sv (term-values C x)) (kindv (ckind C)) (m +inf.0))
    (do ((t 0 (+ t 1))) ((= t (cnt C)) m)
      (when (= 0 (vector-ref kindv t)) (set! m (min m (vector-ref sv t)))))))
(define (dump-x path x)
  (call-with-output-file path
    (lambda (p) (do ((j 0 (+ j 1))) ((= j N)) (format p "~a~%" (vector-ref x j))))))

;; ── one solve from an explicit start ────────────────────────────────────────
;; The ladder's OSQP rung is off for this program: measured 2026-09-03 on the
;; 2464-sector table it ran 2646 s and returned a plan meeting 1.57% of demand
;; (bench-real-diag.scm), which the certificate then rejects — 44 minutes per
;; solve for nothing. libosqp now links from the user's profile, so the rung
;; would otherwise fire on every solve the native path does not certify.
(set! *osqp-fallback* #f)
(define (solve-from label Lcap CO2cap x0 outfile)
  (call-with-values (lambda () (build-forms Lcap CO2cap))
    (lambda (forms labform)
      (let* ((C  (flatten forms))
             (xf (ensure-feasible forms labform x0 solve-native-c-core))
             (r  (secs (lambda () (solve-native-c forms labform xf)))))
        (match r
          ((t x _tt cg nt . _)
           (when outfile (dump-x outfile x))
           (format #t "  ~12a  newton ~2a cg ~3a ~6,1fs   met ~5,1f%  minbal ~9,3g  labour ~4,1f%~%"
                   label nt cg t (* 100.0 (mean-fill C x)) (min-balance C x)
                   (* 100.0 (/ (labour-used labform x) (max 1.0 TOT-HOURS))))
           (force-output)
           x))))))

;; ── homotopy: ease the cap down, re-settling from the previous rung ─────────
(define (homotopy label caps CO2cap x-init outfile)
  (format #t "  ~a — tightening labour cap stepwise from a working plan:~%" label)
  (let loop ((cs caps) (xprev x-init))
    (if (null? cs) xprev
        (let ((cap (* (car cs) TOT-HOURS)) (last? (null? (cdr cs))))
          ;; scale the previous plan so its labour fits strictly under the new cap
          (call-with-values (lambda () (build-forms cap CO2cap))
            (lambda (forms labform)
              (let* ((used (labour-used labform xprev))
                     (f (if (> used cap) (* 0.999 (/ cap used)) 1.0))
                     (x0 (if (< f 1.0) (scale-vec xprev f) xprev)))
                (let ((x (solve-from (format #f "  ×~,3f" (car cs)) cap CO2cap x0
                                     (and last? outfile))))
                  (loop (cdr cs) x)))))))))

(format #t "~%==== convex planner on REAL I-O (~a) ====~%" DATA)
(format #t "  sectors=~a  nnz(A)=~a  Σdemand=~,3g  Σstock=~,3g  Σhours=~,3g~%"
        N NNZ TOT-DEM (vsum STOCK) TOT-HOURS)
(define SEED* (recipe-backtrace 1.0 200 1e-3))
(define SEED  (car SEED*))
(format #t "  self-seed: ~a upstream passes through the recipe graph (ρ-geometric)~%~%" (cdr SEED*))

;; Run A — reproduce: generous caps, started from the self-seed. ≈100% met, feasible.
(define RUNA (solve-from "A:reproduce" (* 1.05 TOT-HOURS) (* 1.05 TOT-CO2) SEED "docs/data/wiod/runA.x"))
(newline)
;; Run B — bind labour to 90% of published, reached by gradual tightening from RUNA.
(homotopy "B:labour→0.90" '(1.0 0.975 0.95 0.925 0.90) (* 1e9 TOT-CO2) RUNA "docs/data/wiod/runB.x")
(newline)
;; Cold-start contrast: the lazy "half of GO" start that stalls (no self-seed).
(solve-from "cold-0.5·GO" (* 1.05 TOT-HOURS) (* 1.05 TOT-CO2) (scale-vec GO 0.5) #f)
(newline)
