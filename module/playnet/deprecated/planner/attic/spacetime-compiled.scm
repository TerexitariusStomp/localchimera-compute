;;; spacetime-compiled.scm — VF RECORDS → SPACETIME OPTIMUM, end to end.
;;;
;;; Steps (1)+(2) of the merge: the LOCATED compiler feeding the interior-point
;;; Newton. The model is no longer hand-built — it is COMPILED from ValueFlows
;;; RecipeProcess/RecipeFlow records (the action table gives each flow its sign),
;;; tiled over the spacetime lattice, and solved as ONE convex program.
;;;
;;; The unifying move: a TRANSPORT/STORAGE step is just another process — it
;;; consumes good@from and produces good@to (×retention) for a haulage/holding
;;; labour cost. So production AND moves are columns of ONE activity matrix over
;;; located goods (resource-spec × cell); site/timing-selection is the optimum
;;; choosing column levels. We reproduce spacetime-newton's space+time demos to
;;; confirm: same records, same optimum.
;;;
;;; Run:  guile -L module module/playnet/planner/spacetime-compiled.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner vf schemas))

;; ════════════════════════════════════════════════════════════════════════════
;; PART A — THE COMPILER  (RecipeProcess + RecipeFlows → an activity column)
;; ════════════════════════════════════════════════════════════════════════════
(define (mqty m) (if m (measure-has-numerical-value m) 0.0))
(define (action-def a) (let ((p (assq a *action-definitions*))) (and p (cdr p))))
(define (compile-process rp-id flows)               ; → (id outputs inputs labour uses)
  (let ((outputs '()) (inputs '()) (uses '()) (labour 0.0))
    (for-each
     (lambda (rf)
       (let ((action (recipe-flow-action rf)) (spec (recipe-flow-resource-conforms-to rf))
             (rq (mqty (recipe-flow-resource-quantity rf))) (eff (mqty (recipe-flow-effort-quantity rf)))
             (ad (action-def (recipe-flow-action rf))))
         (cond ((eq? action 'work) (set! labour (+ labour eff)))
               ((eq? action 'use)  (set! uses (acons spec rq uses)))
               ((and ad (eq? (action-definition-onhand-effect ad) 'increment)) (set! outputs (acons spec rq outputs)))
               ((and ad (eq? (action-definition-onhand-effect ad) 'decrement)) (set! inputs (acons spec rq inputs)))
               (else #t))))
     flows)
    (list rp-id outputs inputs labour uses)))
(define (proc-id c) (car c)) (define (proc-outputs c) (cadr c))
(define (proc-inputs c) (caddr c)) (define (proc-labour c) (cadddr c))
(define (compile-recipe procs flows)
  (map (lambda (rp)
         (let ((pid (recipe-process-id rp)))
           (compile-process pid (filter (lambda (rf) (or (equal? (recipe-flow-recipe-input-of rf) pid)
                                                         (equal? (recipe-flow-recipe-output-of rf) pid))) flows))))
       procs))

;; ── the bread chain as REAL VF records ──────────────────────────────────────
(define (rp id name) (make-recipe-process #:id id #:name name))
(define (out id spec q proc) (make-recipe-flow #:id id #:action 'produce #:resource-conforms-to spec
                                               #:resource-quantity (make-measure q "kg")
                                               #:recipe-output-of proc #:is-primary #t))
(define (in  id spec q proc) (make-recipe-flow #:id id #:action 'consume #:resource-conforms-to spec
                                               #:resource-quantity (make-measure q "kg")
                                               #:recipe-input-of proc))
(define (wrk id hrs proc)    (make-recipe-flow #:id id #:action 'work
                                               #:effort-quantity (make-measure hrs "hours")
                                               #:recipe-input-of proc))
(define *procs* (list (rp "grow" "Grow") (rp "mill" "Mill") (rp "bake" "Bake")))
(define *flows*
  (list (out "f1" "grain" 1.0 "grow") (in "f2" "soil"  1.0 "grow") (wrk "f3" 0.5 "grow")
        (out "f4" "flour" 1.0 "mill") (in "f5" "grain" 1.2 "mill") (wrk "f6" 0.3 "mill")
        (out "f7" "bread" 1.0 "bake") (in "f8" "flour" 1.0 "bake") (wrk "f9" 0.5 "bake")))
(define *base-templates* (compile-recipe *procs* *flows*))
;; an ALTERNATIVE recipe for flour: mill cassava instead of grain (a different raw,
;; slightly dearer labour). Now TWO columns output flour ⇒ the matrix is rectangular
;; ⇒ recipe choice. The optimiser mixes them when the cheaper one's raw binds.
(define *millc-template*
  (car (compile-recipe (list (rp "millc" "Mill cassava"))
         (list (out "g1" "flour" 1.0 "millc") (in "g2" "cassava" 1.0 "millc") (wrk "g3" 1.0 "millc")))))
(define *templates* *base-templates*)            ; default; set per scenario

;; ════════════════════════════════════════════════════════════════════════════
;; PART B — THE LOCATED PROGRAM  (tile templates over cells; moves are columns)
;; ════════════════════════════════════════════════════════════════════════════
(define *places* '()) (define *periods* '(0)) (define *cells* '())
(define *movable* '()) (define *storable* '()) (define *tau* 0.0) (define *hold* 0.0)
(define *demand* (make-hash-table)) (define *A* (make-hash-table))
(define *cap* (make-hash-table)) (define *init* (make-hash-table)) (define *latlon* (make-hash-table))
(define (lg good cell) (string-append good "#" cell))         ; located-good key
(define (cell place t) (string-append place "@" (number->string t)))
(define (place-of c) (car (string-split c #\@)))
(define (period-of c) (string->number (cadr (string-split c #\@))))
(define (km a b)
  (let ((A (hash-ref *latlon* (place-of a))) (B (hash-ref *latlon* (place-of b))) (d2r (/ 3.141592653589793 180.0)))
    (if (or (not A) (not B) (equal? (place-of a) (place-of b))) 0.0
        (let* ((la1 (* d2r (car A))) (la2 (* d2r (car B)))
               (dla (* d2r (- (car B) (car A)))) (dlo (* d2r (- (cdr B) (cdr A))))
               (h (+ (expt (sin (/ dla 2)) 2) (* (cos la1) (cos la2) (expt (sin (/ dlo 2)) 2)))))
          (* 6371.0 2.0 (atan (sqrt h) (sqrt (- 1.0 h))))))))

;; ── the DISCRETE layer: minimum-batch processes (run at ≥MBQ or not at all) ──
;; The convex core RELAXES the batch (level ∈ [0,∞)); an outer loop enumerates the
;; on/off config of each batch column, convex-solves each (ON ⇒ level ≥ MBQ, a
;; convex lower bound; OFF ⇒ column removed), and keeps the best — a CERTIFIED
;; global optimum over the configs, exactly relaxation.scm's enumerate-when-small.
(define *mbq-procs* (make-hash-table))   ; process-id -> minimum batch quantity (VF minimum-batch-quantity)
(define *config* 'all)                    ; 'all, or a list of the ON batch-column keys
(define (mbq-of key) (and (string-prefix? "p|" key) (hash-ref *mbq-procs* (cadr (string-split key #\|)) #f)))
(define (col-on? key) (or (eq? *config* 'all) (not (mbq-of key)) (member key *config*)))
(define (all-subsets lst) (if (null? lst) '(()) (let ((r (all-subsets (cdr lst)))) (append r (map (lambda (s) (cons (car lst) s)) r)))))

;; a COLUMN = (key flows labour labour-cell), flows = alist (located-good . coeff)
(define (col-key c) (car c)) (define (col-flows c) (cadr c))
(define (col-labour c) (caddr c)) (define (col-cell c) (cadddr c))
(define (build-columns)
  (let ((cols '()))
    ;; production: each template tiled per cell
    (for-each (lambda (tpl)
      (for-each (lambda (c)
        (let ((key (string-append "p|" (proc-id tpl) "|" c)))
          (when (col-on? key)                              ; OFF batch columns are removed entirely
            (let ((flows (append (map (lambda (oq) (cons (lg (car oq) c) (cdr oq))) (proc-outputs tpl))
                                 (map (lambda (iq) (cons (lg (car iq) c) (- (cdr iq)))) (proc-inputs tpl)))))
              (set! cols (cons (list key flows (proc-labour tpl) c) cols))))))
        *cells*))
      *templates*)
    ;; moves: a transport/storage process consuming good@from, producing good@to×ret
    (for-each (lambda (g)
      (for-each (lambda (a) (for-each (lambda (b)
        (let ((spatial? (and (= (period-of a) (period-of b)) (not (equal? (place-of a) (place-of b)))))
              (temporal? (and (equal? (place-of a) (place-of b)) (= (period-of b) (+ 1 (period-of a))))))
          (when (or spatial? (and temporal? (member g *storable*)))
            (let ((cost (if spatial? (* *tau* (km a b)) *hold*)) (ret 1.0))
              (set! cols (cons (list (string-append "m|" g "|" a "|" b)
                                     (list (cons (lg g a) -1.0) (cons (lg g b) ret)) cost a) cols))))))
        *cells*)) *cells*))
      *movable*)
    (reverse cols)))

;; located-good partition: a good is PRODUCED if some column has a + coeff on it
(define (good-keys cols)
  (let ((made (make-hash-table)) (all (make-hash-table)))
    (for-each (lambda (c) (for-each (lambda (fc)
                (hash-set! all (car fc) #t) (when (> (cdr fc) 0.0) (hash-set! made (car fc) #t)))
                (col-flows c))) cols)
    (values (filter (lambda (k) (hash-ref made k #f)) (hash-map->list (lambda (k v) k) all))
            (filter (lambda (k) (not (hash-ref made k #f))) (hash-map->list (lambda (k v) k) all)))))

;; ════════════════════════════════════════════════════════════════════════════
;; PART C — interior-point Newton over the column-level vector (analytic)
;; ════════════════════════════════════════════════════════════════════════════
(define (gauss-solve A b n)
  (let ((M (make-vector n)) (x (make-vector n 0.0)))
    (do ((i 0 (+ i 1))) ((= i n))
      (let ((row (make-vector (+ n 1) 0.0)))
        (do ((j 0 (+ j 1))) ((= j n)) (vector-set! row j (vector-ref (vector-ref A i) j)))
        (vector-set! row n (vector-ref b i)) (vector-set! M i row)))
    (do ((c 0 (+ c 1))) ((= c n))
      (let ((piv c) (best (abs (vector-ref (vector-ref M c) c))))
        (do ((r (+ c 1) (+ r 1))) ((= r n)) (let ((v (abs (vector-ref (vector-ref M r) c)))) (when (> v best) (set! best v) (set! piv r))))
        (let ((tmp (vector-ref M c))) (vector-set! M c (vector-ref M piv)) (vector-set! M piv tmp))
        (let ((d (vector-ref (vector-ref M c) c)))
          (when (> (abs d) 1e-14)
            (do ((r (+ c 1) (+ r 1))) ((= r n))
              (let ((f (/ (vector-ref (vector-ref M r) c) d)))
                (do ((j c (+ j 1))) ((> j n))
                  (vector-set! (vector-ref M r) j (- (vector-ref (vector-ref M r) j) (* f (vector-ref (vector-ref M c) j)))))))))))
    (do ((i (- n 1) (- i 1))) ((< i 0))
      (let ((s (vector-ref (vector-ref M i) n)))
        (do ((j (+ i 1) (+ j 1))) ((= j n)) (set! s (- s (* (vector-ref (vector-ref M i) j) (vector-ref x j)))))
        (let ((d (vector-ref (vector-ref M i) i))) (vector-set! x i (if (> (abs d) 1e-14) (/ s d) 0.0)))))
    x))
(define (fval f x) (+ (car f) (fold (lambda (ic a) (+ a (* (cdr ic) (vector-ref x (car ic))))) 0.0 (cdr f))))

;; build the program from the columns: linear slack forms + desires + free time
(define *idx* (make-hash-table)) (define *ncol* 0)
(define *bforms* '()) (define *dforms* '()) (define *labform* '()) (define *kappa* 0.02)
(define (build-program cols)
  (call-with-values (lambda () (good-keys cols))
    (lambda (goods raws)
      (set! *ncol* (length cols)) (hash-clear! *idx*)
      (let ((i 0)) (for-each (lambda (c) (hash-set! *idx* (col-key c) i) (set! i (+ i 1))) cols))
      ;; per located-good g: delivered(g) = init + Σ_col flow(col,g)·level   (slack ≥ 0)
      (define (good-form g)
        (cons (hash-ref *init* g 0.0)
              (filter-map (lambda (c) (let ((fc (assoc g (col-flows c))))
                                        (and fc (cons (hash-ref *idx* (col-key c)) (cdr fc))))) cols)))
      (set! *bforms* '()) (set! *dforms* '()) (set! *labform* '())
      ;; balance on goods, eco on raws
      (for-each (lambda (g) (set! *bforms* (cons (good-form g) *bforms*))) goods)
      (for-each (lambda (r) (let ((cap (hash-ref *cap* r #f)))
                  (when cap                                       ; slack = cap + Σ flow·level (flow ≤ 0)
                    (set! *bforms* (cons (cons cap (cdr (good-form r))) *bforms*))))) raws)
      ;; labour per cell: slack = A − Σ_{col@cell} labour·level
      (for-each (lambda (cl) (let ((A (hash-ref *A* cl #f)))
                  (when A (set! *bforms* (cons (cons A (filter-map (lambda (c)
                              (and (equal? (col-cell c) cl) (> (col-labour c) 0.0)
                                   (cons (hash-ref *idx* (col-key c)) (- (col-labour c))))) cols)) *bforms*)))))
                *cells*)
      ;; activity levels ≥ 0  — except an ON batch column, which is ≥ its MBQ (a convex lower bound)
      (for-each (lambda (c) (let ((mbq (or (mbq-of (col-key c)) 0.0)))
                  (set! *bforms* (cons (cons (- mbq) (list (cons (hash-ref *idx* (col-key c)) 1.0))) *bforms*)))) cols)
      ;; desires on demand points; free time = Σ all labour
      (hash-for-each (lambda (g D) (set! *dforms* (cons (list (good-form g) D 1000.0) *dforms*))) *demand*)
      (set! *labform* (cons 0.0 (append-map (lambda (c) (if (> (col-labour c) 0.0)
                          (list (cons (hash-ref *idx* (col-key c)) (col-labour c))) '())) cols)))
      (values goods raws))))

(define (obj-value x t)
  (+ (* *kappa* (fval *labform* x))
     (fold (lambda (d a) (let ((s (fval (car d) x)) (D (cadr d)) (w (caddr d)))
                           (if (< s D) (+ a (* w (expt (/ (- D s) D) 2))) a))) 0.0 *dforms*)
     (fold (lambda (f a) (let ((v (fval f x))) (if (<= v 1e-12) (+ a 1e12) (+ a (* (- t) (log v)))))) 0.0 *bforms*)))
(define (obj-grad-hess x t)
  (let* ((n (vector-length x)) (g (make-vector n 0.0)) (H (make-vector n)))
    (do ((i 0 (+ i 1))) ((= i n)) (vector-set! H i (make-vector n 0.0)))
    (for-each (lambda (f) (let ((v (fval f x)))
        (when (> v 1e-12) (let ((tv (/ t v)) (tv2 (/ t (* v v))))
          (for-each (lambda (ic) (let ((i (car ic)) (ai (cdr ic)))
              (vector-set! g i (- (vector-ref g i) (* tv ai)))
              (for-each (lambda (jc) (let ((row (vector-ref H i)))
                  (vector-set! row (car jc) (+ (vector-ref row (car jc)) (* tv2 ai (cdr jc)))))) (cdr f))))
            (cdr f))))))
      *bforms*)
    (for-each (lambda (d) (let* ((f (car d)) (D (cadr d)) (w (caddr d)) (s (fval f x)))
        (when (< s D) (let ((gc (/ (* -2.0 w (- D s)) (* D D))) (hc (/ (* 2.0 w) (* D D))))
          (for-each (lambda (ic) (let ((i (car ic)) (ai (cdr ic)))
              (vector-set! g i (+ (vector-ref g i) (* gc ai)))
              (for-each (lambda (jc) (let ((row (vector-ref H i)))
                  (vector-set! row (car jc) (+ (vector-ref row (car jc)) (* hc ai (cdr jc)))))) (cdr f))))
            (cdr f))))))
      *dforms*)
    (for-each (lambda (ic) (vector-set! g (car ic) (+ (vector-ref g (car ic)) (* *kappa* (cdr ic))))) (cdr *labform*))
    (do ((i 0 (+ i 1))) ((= i n)) (vector-set! (vector-ref H i) i (+ (vector-ref (vector-ref H i) i) 1e-7)))
    (values g H)))
;; ── matrix-free sparse Newton (Newton-CG): never form H ──────────────────────
;; H = Σ_barriers (t/v²)·aaᵀ + Σ_desires (2w/D²)·aaᵀ + ridge·I — a sum of rank-1
;; outer products of the SPARSE constraint forms a (the recipe incidence). So
;; H·v = Σ coeff·a·(aᵀv) costs O(total nonzeros), and conjugate gradient solves
;; Hd=−g using only H·v: the sparse Newton scales with the recipe graph, not n³.
(define (vdot a b) (let ((s 0.0) (n (vector-length a))) (do ((i 0 (+ i 1))) ((= i n) s) (set! s (+ s (* (vector-ref a i) (vector-ref b i)))))))
(define (vcopy a) (let* ((n (vector-length a)) (r (make-vector n))) (do ((i 0 (+ i 1))) ((= i n) r) (vector-set! r i (vector-ref a i)))))
(define (obj-grad x t)
  (let ((g (make-vector (vector-length x) 0.0)))
    (for-each (lambda (f) (let ((v (fval f x))) (when (> v 1e-12) (let ((tv (/ t v)))
        (for-each (lambda (ic) (vector-set! g (car ic) (- (vector-ref g (car ic)) (* tv (cdr ic))))) (cdr f)))))) *bforms*)
    (for-each (lambda (d) (let* ((f (car d)) (D (cadr d)) (w (caddr d)) (s (fval f x)))
        (when (< s D) (let ((gc (/ (* -2.0 w (- D s)) (* D D))))
          (for-each (lambda (ic) (vector-set! g (car ic) (+ (vector-ref g (car ic)) (* gc (cdr ic))))) (cdr f)))))) *dforms*)
    (for-each (lambda (ic) (vector-set! g (car ic) (+ (vector-ref g (car ic)) (* *kappa* (cdr ic))))) (cdr *labform*))
    g))
(define (newton-terms x t)             ; the rank-1 generators of H: (coeff . sparse-coeffs)
  (append
   (filter-map (lambda (f) (let ((v (fval f x))) (and (> v 1e-12) (cons (/ t (* v v)) (cdr f))))) *bforms*)
   (filter-map (lambda (d) (let ((s (fval (car d) x)) (D (cadr d)) (w (caddr d)))
                             (and (< s D) (cons (/ (* 2.0 w) (* D D)) (cdr (car d)))))) *dforms*)))
(define (hv terms v n)                  ; H·v, matrix-free, + ridge
  (let ((r (make-vector n 0.0)))
    (for-each (lambda (term) (let ((c (car term)))
        (let ((dot (fold (lambda (ic a) (+ a (* (cdr ic) (vector-ref v (car ic))))) 0.0 (cdr term))))
          (for-each (lambda (ic) (vector-set! r (car ic) (+ (vector-ref r (car ic)) (* c (cdr ic) dot)))) (cdr term)))))
      terms)
    (do ((i 0 (+ i 1))) ((= i n)) (vector-set! r i (+ (vector-ref r i) (* 1e-7 (vector-ref v i)))))
    r))
(define (cg hvf b n)                    ; conjugate gradient: solve H x = b (H spd)
  (let ((x (make-vector n 0.0)) (r (vcopy b)) (p (vcopy b)))
    (let loop ((k 0) (rs (vdot b b)))
      (if (or (>= k (+ n 5)) (< rs 1e-18)) x
          (let* ((Hp (hvf p)) (al (/ rs (max 1e-30 (vdot p Hp)))))
            (do ((i 0 (+ i 1))) ((= i n))
              (vector-set! x i (+ (vector-ref x i) (* al (vector-ref p i))))
              (vector-set! r i (- (vector-ref r i) (* al (vector-ref Hp i)))))
            (let ((rs2 (vdot r r)))
              (do ((i 0 (+ i 1))) ((= i n)) (vector-set! p i (+ (vector-ref r i) (* (/ rs2 rs) (vector-ref p i)))))
              (loop (+ k 1) rs2)))))))
(define (hdiag terms n)                 ; diag(H), for Jacobi preconditioning
  (let ((d (make-vector n 1e-7)))
    (for-each (lambda (term) (let ((c (car term)))
        (for-each (lambda (ic) (vector-set! d (car ic) (+ (vector-ref d (car ic)) (* c (cdr ic) (cdr ic))))) (cdr term)))) terms)
    d))
(define (pcg hvf b diag n)              ; diagonal-preconditioned CG
  (let* ((x (make-vector n 0.0)) (r (vcopy b))
         (z (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n) v) (vector-set! v i (/ (vector-ref r i) (vector-ref diag i))))))
         (p (vcopy z)))
    (let loop ((k 0) (rz (vdot r z)))
      (if (or (>= k (+ n 5)) (< (vdot r r) 1e-18)) x
          (let* ((Hp (hvf p)) (al (/ rz (max 1e-30 (vdot p Hp)))))
            (do ((i 0 (+ i 1))) ((= i n))
              (vector-set! x i (+ (vector-ref x i) (* al (vector-ref p i))))
              (vector-set! r i (- (vector-ref r i) (* al (vector-ref Hp i)))))
            (let* ((z2 (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n) v) (vector-set! v i (/ (vector-ref r i) (vector-ref diag i))))))
                   (rz2 (vdot r z2)))
              (do ((i 0 (+ i 1))) ((= i n)) (vector-set! p i (+ (vector-ref z2 i) (* (/ rz2 rz) (vector-ref p i)))))
              (loop (+ k 1) rz2)))))))
(define *use-cg* #t)                    ; sparse path by default; #f selects the dense Gauss solve
(define (newton x t iters)
  (let loop ((k 0) (x x))
    (if (>= k iters) x
        (let* ((n (vector-length x)) (g (obj-grad x t)) (gn (sqrt (vdot g g))))
          (if (< gn 1e-7) x
              (let* ((negg (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n)) (vector-set! v i (- (vector-ref g i)))) v))
                     (d (if *use-cg*
                            (let ((terms (newton-terms x t))) (pcg (lambda (v) (hv terms v n)) negg (hdiag terms n) n))
                            (call-with-values (lambda () (obj-grad-hess x t)) (lambda (g2 H) (gauss-solve H negg n)))))
                     (f0 (obj-value x t)))
                (let ls ((eta 1.0))
                  (let* ((y (let ((v (make-vector n))) (do ((i 0 (+ i 1))) ((= i n)) (vector-set! v i (+ (vector-ref x i) (* eta (vector-ref d i))))) v))
                         (fy (obj-value y t)))
                    (cond ((and (< fy 1e11) (< fy (- f0 1e-12))) (loop (+ k 1) y))
                          ((< eta 1e-9) x)
                          (else (ls (* eta 0.5))))))))))))

(define (solve)
  (let* ((cols (build-columns)))
    (call-with-values (lambda () (build-program cols))
      (lambda (goods raws)
        (let* ((n *ncol*) (x (make-vector n 0.05)))
          ;; feasible warm start: chain-consistent production levels, moves tiny
          (let ((need (make-hash-table))
                (pgoods (delete-duplicates (map (lambda (tpl) (caar (proc-outputs tpl))) *templates*))))
            (do ((pass 0 (+ pass 1))) ((> pass (length pgoods)))   ; fixpoint (order-independent):
              (for-each (lambda (g)                                ; finals stabilise, need propagates upstream
                (let ((nd 0.5))
                  (for-each (lambda (tpl) (let ((og (caar (proc-outputs tpl))) (ig (assoc g (proc-inputs tpl))))
                              (when ig (set! nd (+ nd (* (cdr ig) (hash-ref need og 0.0))))))) *templates*)
                  (hash-set! need g nd)))
                pgoods))
            (for-each (lambda (c)
              (let ((parts (string-split (col-key c) #\|)))
                (when (equal? (car parts) "p")
                  (let* ((tpl (find (lambda (t) (equal? (proc-id t) (cadr parts))) *templates*))
                         (og (caar (proc-outputs tpl))) (mbq (mbq-of (col-key c))))
                    (vector-set! x (hash-ref *idx* (col-key c))
                                 (if mbq (max (+ mbq 1.0) (hash-ref need og 0.5)) (hash-ref need og 0.5))))))) cols)
            ;; batch-aware feasibility pass (only when a batch is forced): size each good's
            ;; non-batch producer to cover consumption + demand − what the pinned batch makes,
            ;; so the cascade feeds the ≥MBQ column. (Gated, to leave the spatial warm tiny.)
            (when (pair? (hash-map->list cons *mbq-procs*))
              (let ((ix (lambda (c) (hash-ref *idx* (col-key c)))))
                (do ((pass 0 (+ pass 1))) ((= pass 6))
                  (for-each (lambda (g)
                    (let* ((consum (fold (lambda (c a) (let ((fc (assoc g (col-flows c)))) (if (and fc (< (cdr fc) 0.0)) (- a (* (cdr fc) (vector-ref x (ix c)))) a))) 0.0 cols))
                           (dem (hash-ref *demand* g 0.0))
                           (bprod (fold (lambda (c a) (let ((fc (assoc g (col-flows c)))) (if (and fc (> (cdr fc) 0.0) (mbq-of (col-key c))) (+ a (* (cdr fc) (vector-ref x (ix c)))) a))) 0.0 cols))
                           (nb (find (lambda (c) (let ((fc (assoc g (col-flows c)))) (and fc (> (cdr fc) 0.0) (not (mbq-of (col-key c)))))) cols)))
                      (when nb (vector-set! x (ix nb) (max 0.5 (/ (- (+ consum dem 0.5) bprod) (cdr (assoc g (col-flows nb)))))))))
                    goods)))))
          (let loop ((t 1.0) (xx x))
            (let ((x* (newton xx t 60)))
              (if (<= t 0.02) (values x* t cols goods raws) (loop (max 0.02 (* t 0.5)) x*)))))))))

;; ── reporting ────────────────────────────────────────────────────────────────
(define (lref x c) (vector-ref x (hash-ref *idx* (col-key c))))
(define (report)
  (call-with-values solve
    (lambda (x t cols goods raws)
      (format #t "   activity levels (process @ cell):~%")
      (for-each (lambda (c) (when (and (string-prefix? "p|" (col-key c)) (> (lref x c) 0.05))
                  (format #t "     ~22a ~6,1f~%" (col-key c) (lref x c)))) cols)
      (let ((any #f))
        (for-each (lambda (c) (when (and (string-prefix? "m|" (col-key c)) (> (lref x c) 0.5))
                    (unless any (format #t "   moves (process columns):~%") (set! any #t))
                    (let ((p (string-split (col-key c) #\|)))
                      (format #t "     ~6a ~a -> ~a  ~6,1f  (~a)~%" (cadr p) (caddr p) (cadddr p) (lref x c)
                              (if (string=? (substring (caddr p) (1+ (string-index (caddr p) #\@)))
                                            (substring (cadddr p) (1+ (string-index (cadddr p) #\@)))) "ship" "store")))))
                  cols))
      (for-each (lambda (cl) (let ((A (hash-ref *A* cl #f)))
                  (when A (let ((u (fold (lambda (c a) (if (equal? (col-cell c) cl) (+ a (* (col-labour c) (lref x c))) a)) 0.0 cols)))
                            (format #t "     labour@~a  ~6,1f/~a  pull ~6,3f~%" cl u A (if (>= u A) 1e6 (/ t (- A u)))))))) *cells*)
      (hash-for-each (lambda (rk cap)               ; ecological pulls (why the recipe mix happens)
        (let* ((parts (string-split rk #\#))
               (draw (- (fold (lambda (c a) (let ((fc (assoc rk (col-flows c)))) (if fc (+ a (* (cdr fc) (lref x c))) a))) 0.0 cols))))
          (format #t "     ~a@~a draw ~6,1f/~a  pull ~6,3f~%" (car parts) (cadr parts) draw cap
                  (if (>= draw cap) 1e6 (/ t (- cap draw)))))) *cap*)
      (hash-for-each (lambda (g D)
        (let ((dlv (fval (cons (hash-ref *init* g 0.0)
                               (filter-map (lambda (c) (let ((fc (assoc g (col-flows c))))
                                                         (and fc (cons (hash-ref *idx* (col-key c)) (cdr fc))))) cols)) x)))
          (format #t "   demand ~a delivered ~6,1f/~a  (gap ~,2f)~%" g dlv D (max 0.0 (/ (- D dlv) D)))))
        *demand*)
      ;; duality-gap certificate (Boyd&V): at the central point λ_i·slack_i = t for each of the
      ;; m log-barriers, so the gap to the true optimum is bounded by m·t — same certificate
      ;; relaxation.scm prints. This makes the compiled engine CERTIFIED, not just convergent.
      (format #t "   [interior-point: t=~,3f, ~a columns, ~a constraints; CERTIFIED gap <= m·t = ~,2f]~%"
              t *ncol* (length *bforms*) (* (length *bforms*) t)))))

;; ── discrete layer: enumerate the on/off config of the batch columns ─────────
(define (solution-cost x)               ; true −harmony at the optimum (desire + free time; barriers→0)
  (+ (* *kappa* (fval *labform* x))
     (fold (lambda (d a) (let ((s (fval (car d) x)) (D (cadr d)))
                           (if (< s D) (+ a (* (caddr d) (expt (/ (- D s) D) 2))) a))) 0.0 *dforms*)))
(define (solve-discrete)
  (set! *config* 'all)
  (let ((mbq-keys (filter-map (lambda (c) (and (mbq-of (col-key c)) (col-key c))) (build-columns)))
        (best-cost 1e30) (best-cfg 'all) (nmbq 0))
    (set! nmbq (length mbq-keys))
    (for-each (lambda (cfg)
                (set! *config* cfg)
                (call-with-values solve (lambda (x t . _)
                  (let ((cost (solution-cost x)))
                    (when (< cost best-cost) (set! best-cost cost) (set! best-cfg cfg))))))
              (all-subsets mbq-keys))
    (values best-cfg nmbq)))
(define (report-discrete)
  (call-with-values solve-discrete (lambda (cfg nmbq)
    (set! *config* cfg)
    (format #t "   DISCRETE: ~a batch process(es); chose ~a ON~%" nmbq (if (null? cfg) "0 (all batches OFF)" (length cfg)))
    (report)
    (format #t "   [discrete: CERTIFIED global over ~a on/off configs]~%" (expt 2 nmbq)))))

;; ── world setup ──────────────────────────────────────────────────────────────
(define (reset!) (set! *places* '()) (set! *periods* '(0)) (set! *cells* '())
  (set! *movable* '()) (set! *storable* '()) (set! *tau* 0.0) (set! *hold* 0.0)
  (set! *config* 'all) (hash-clear! *mbq-procs*)
  (for-each hash-clear! (list *demand* *A* *cap* *init* *latlon*)))
(define (mkcells!) (set! *cells* (append-map (lambda (p) (map (lambda (t) (cell p t)) *periods*)) *places*)))
(define (setup-space tau)
  (reset!) (set! *templates* *base-templates*)
  (set! *places* '("city" "country")) (set! *periods* '(0)) (mkcells!)
  (hash-set! *latlon* "city" (cons 40.0 -74.0)) (hash-set! *latlon* "country" (cons 41.0 -74.0))
  (set! *movable* '("bread" "flour" "grain")) (set! *storable* '()) (set! *tau* tau)
  (hash-set! *demand* (lg "bread" "city@0") 100.0)
  (hash-set! *cap* (lg "soil" "city@0") 20.0) (hash-set! *cap* (lg "soil" "country@0") 200.0)
  (hash-set! *A* "city@0" 120.0) (hash-set! *A* "country@0" 70.0))
(define (setup-time t1-labour hold storable?)
  (reset!) (set! *templates* *base-templates*)
  (set! *places* '("town")) (set! *periods* '(0 1)) (mkcells!)
  (hash-set! *latlon* "town" (cons 40.0 -74.0))
  (set! *movable* '("bread" "flour" "grain")) (set! *storable* (if storable? '("bread" "flour" "grain") '()))
  (set! *hold* hold)
  (hash-set! *demand* (lg "bread" "town@1") 100.0)
  (hash-set! *cap* (lg "soil" "town@0") 400.0) (hash-set! *cap* (lg "soil" "town@1") 400.0)
  (hash-set! *A* "town@0" 250.0) (hash-set! *A* "town@1" t1-labour))
;; RECIPE CHOICE: one cell, bread wanted; flour can be milled from grain OR cassava.
;; When soil is plentiful the cheaper grain route does it all; when soil binds, the
;; optimiser MIXES IN the cassava route — recipe selection from the same convex solve.
(define (setup-recipe soil-cap)
  (reset!) (set! *templates* (append *base-templates* (list *millc-template*)))
  (set! *places* '("town")) (set! *periods* '(0)) (mkcells!)
  (hash-set! *latlon* "town" (cons 40.0 -74.0))
  (set! *movable* '()) (set! *storable* '())
  (hash-set! *demand* (lg "bread" "town@0") 100.0)
  (hash-set! *cap* (lg "soil" "town@0") soil-cap)
  (hash-set! *cap* (lg "cassava" "town@0") 80.0)
  (hash-set! *A* "town@0" 300.0))
;; DISCRETE / MINIMUM BATCH: a big mill makes flour at half the labour, but only in
;; batches ≥ 80 (VF minimum-batch-quantity) — run ≥80 or not at all. The discrete
;; layer enumerates {big mill OFF, ON} and certifies the better.
(define *millb-template*
  (car (compile-recipe (list (rp "millb" "Big mill (batch ≥80)"))
         (list (out "h1" "flour" 1.0 "millb") (in "h2" "grain" 1.2 "millb") (wrk "h3" 0.15 "millb")))))
(define (setup-batch demand)
  (reset!) (set! *templates* (append *base-templates* (list *millb-template*)))
  (hash-set! *mbq-procs* "millb" 80.0)
  (set! *places* '("town")) (set! *periods* '(0)) (mkcells!) (hash-set! *latlon* "town" (cons 40.0 -74.0))
  (set! *movable* '()) (set! *storable* '())
  (hash-set! *demand* (lg "bread" "town@0") demand)
  (hash-set! *cap* (lg "soil" "town@0") 400.0) (hash-set! *A* "town@0" 400.0))

;; ── scaling benchmark: dense Gauss vs matrix-free Newton-CG ──────────────────
;; A chain of N goods (g0 ← g1 ← … ← g_{N-1} ← raw) in one cell — n = N activity
;; columns. Dense forms+factors an N×N Hessian each step (O(N³)); Newton-CG never
;; forms it and rides the chain's near-tridiagonal sparsity.
(define (chain-templates N)
  (map (lambda (i) (list (string-append "p" (number->string i))
                         (list (cons (string-append "g" (number->string i)) 1.0))
                         (list (cons (if (= i (- N 1)) "raw" (string-append "g" (number->string (+ i 1)))) 1.0))
                         0.3 '())) (iota N)))
(define (bench-setup N)
  (reset!) (set! *templates* (chain-templates N))
  (set! *places* '("z")) (set! *periods* '(0)) (mkcells!) (hash-set! *latlon* "z" (cons 0.0 0.0))
  (set! *movable* '()) (set! *storable* '())
  (hash-set! *demand* (lg "g0" "z@0") 100.0) (hash-set! *cap* (lg "raw" "z@0") 1e9) (hash-set! *A* "z@0" 1e9))
(define (timed thunk) (let ((t0 (get-internal-run-time))) (thunk)
  (/ (* 1000.0 (- (get-internal-run-time) t0)) internal-time-units-per-second)))
(define (bench)
  (format #t "~%==== SCALING: dense Gauss (O(N³)) vs matrix-free Newton-CG ====~%")
  (format #t "     N   cols   dense(ms)    cg(ms)~%")
  (for-each (lambda (N)
    (bench-setup N)
    (let* ((dense (begin (set! *use-cg* #f) (timed (lambda () (call-with-values solve (lambda a #t))))))
           (cgms  (begin (set! *use-cg* #t)  (timed (lambda () (call-with-values solve (lambda a #t)))))))
      (format #t "  ~4a   ~4a   ~9,1f  ~9,1f~%" N N dense cgms)))
    '(10 30 60 100 150))
  (set! *use-cg* #t))

;; ── run ──────────────────────────────────────────────────────────────────────
(format #t "~%==== VF RECORDS → SPACETIME OPTIMUM (compiled, one Newton) ====~%")
(format #t "compiled ~a process templates from VF RecipeFlows: ~a~%~%"
        (length *templates*) (map proc-id *templates*))
(format #t "-- SPACE: cheap transport~%")  (setup-space 0.002) (report)
(format #t "~%-- SPACE: dear transport~%")  (setup-space 0.04)  (report)
(format #t "~%-- TIME: deep valley (t1=40), storable~%")    (setup-time 40.0 0.01 #t) (report)
(format #t "~%-- TIME: shallow valley (t1=100), storable~%") (setup-time 100.0 0.01 #t) (report)
(format #t "~%-- RECIPE CHOICE: soil PLENTIFUL (cap 200) -> all grain-flour, cassava idle~%")
(setup-recipe 200.0) (report)
(format #t "~%-- RECIPE CHOICE: soil SCARCE (cap 60) -> grain route to the wall, MIX IN cassava~%")
(setup-recipe 60.0) (report)
(format #t "~%-- BATCH: HIGH demand (100) -> big mill (≥80) worth turning ON~%")
(setup-batch 100.0) (report-discrete)
(format #t "~%-- BATCH: LOW demand (40) -> a batch would overproduce; big mill OFF~%")
(setup-batch 40.0) (report-discrete)
(bench)
(newline)
