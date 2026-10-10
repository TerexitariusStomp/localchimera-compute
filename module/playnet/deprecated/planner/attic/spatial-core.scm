;;; spatial-core.scm — the SPACETIME-equilibrium planner (one field).
;;;
;;; Spec: docs/playnet.typ §"Desire, possibility, and the resolving chord".
;;; Single-cell special case: relaxation.scm. Convexity proof: spatial-proto.scm.
;;;
;;; Recipes are placeless AND timeless (ValueFlows: RecipeFlow/RecipeProcess carry
;;; no location and no date), so WHERE and WHEN to instantiate each one is a free,
;;; continuous variable q(spec, cell) — where a CELL is a point in SPACETIME, a
;;; (place, period) pair. Location/time live on instances via SpatialThing and the
;;; event calendar; everything scarce is one located, dated pull λ(spec, cell).
;;;
;;; SPACE AND TIME ARE SYMMETRIC COORDINATES, and a MOVE carries a good between
;;; adjacent cells — one abstraction with two faces:
;;;   • TRANSPORT — a spatial move (same period, neighbouring places): the haulage
;;;     is living labour, by DIRECT haversine distance; bidirectional; lossless.
;;;   • STORAGE  — a temporal move (same place, period t→t+1): inventory carried
;;;     forward; FORWARD-ONLY (time has an arrow); costs holding labour and may
;;;     lose a fraction to decay (retention). A non-storable good (a perishable —
;;;     fresh fish) simply has NO temporal edge: it must be produced in-period.
;;; So storage is transport through time. Site selection (where to grow/mill/bake)
;;; and its twin, TIMING selection (build-ahead vs just-in-time), both fall out of
;;; the convex optimum; the metabolic rift surfaces on its own as a located pull
;;; climbs when a place — or a period — is drained.
;;;
;;; THE SOLVER, and why it is what it is (three attempts, each forced by the last):
;;;   1. a MONOLITHIC primal gradient over {q, moves} STALLS — relocating a stage
;;;      needs three vars to move together (q-here↓, q-there↑, move↑) and each
;;;      partial is individually unfavourable, so a coordinate-wise step can't
;;;      start the joint move. ⇒ decompose.
;;;   2. a naive PULL TÂTONNEMENT bang-bangs — linear production cost makes each
;;;      cell's best-response a step function, so pulls/quantities oscillate. ⇒
;;;      add a proximal term.
;;;   3. HIERARCHICAL ADMM over the spacetime lattice CONVERGES (this file). Space
;;;      is a tree (contained-in), time a chain (period→period); the same proximal
;;;      consensus meters every cell's net flow to demand. This is at once the
;;;      spatial-equilibrium solver, the scheduler, and the federation engine.
;;;
;;; Run:  guile -L module module/playnet/planner/spatial-core.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet vf schemas))

;; ── helpers (hash-backed) ────────────────────────────────────────────────────
(define (href h k . d) (hash-ref h k (if (pair? d) (car d) #f)))
(define (hadd! h k dv) (hash-set! h k (+ (hash-ref h k 0.0) dv)))
;; log-barrier inside the envelope; a steep RESTORING quadratic past it — so an
;; infeasible warm-start (everything piled onto a labour-walled period) still has
;; a gradient pushing production back under the wall, rather than a flat 1e9 cliff.
(define (barrier used cap)
  (let ((u (min used (* 0.999 cap))) (over (max 0.0 (- used cap))))
    (+ (* 4.0 (- (log (/ (- cap u) cap))))
       (* 5e4 (+ over (* over over))))))                ; steep linear+quadratic past the wall
(define (hinge x)          (if (>= x 0.0) 0.0 (* 3000.0 x x)))  ; penalise negative slack (keep the chain consistent)
(define (k2 a b)   (string-append a "|" b))
(define (k3 a b c) (string-append a "|" b "|" c))
(define (tk s a b) (string-append "t|" s "|" a "|" b))   ; move flow of s: cell a -> cell b

;; maximise `objective` (a thunk that reads `table`) over the variables `keys`
;; (entries of `table`, projected ≥ 0) by finite-difference projected-gradient
;; ascent with a backtracking line search. Mutates and returns `table`. This is
;; the one local optimiser — separating HOW we climb from WHAT each cell wants.
;; [First-order: fine for the FEASIBLE cells this file couples. A single-cell
;;  INFEASIBILITY (demand a cell cannot meet) is a stiff corner where first-order
;;  ascent traps — see the World B note; it belongs to relaxation.scm's Newton.]
(define (ascend! table keys objective iters precond)
  (let ((eps 1e-4))
    (let loop ((i 0))
      (if (>= i iters) table
          (let* ((h0 (objective))
                 (grad (map (lambda (s)
                              (let ((old (hash-ref table s 0.0)))
                                (hash-set! table s (+ old eps))
                                (let ((g (/ (- (objective) h0) eps)))
                                  (hash-set! table s old) (cons s (/ g precond)))))
                            keys)))
            (let ls ((eta 1.0))
              (let ((snap (map (lambda (kv) (cons (car kv) (hash-ref table (car kv) 0.0))) grad)))
                (for-each (lambda (kv) (hash-set! table (car kv)
                                                  (max 0.0 (+ (hash-ref table (car kv) 0.0) (* eta (cdr kv)))))) grad)
                (cond ((> (objective) (+ h0 1e-9)) (loop (+ i 1)))
                      ((< eta 1e-6) (for-each (lambda (kv) (hash-set! table (car kv) (cdr kv))) snap) table)
                      (else (for-each (lambda (kv) (hash-set! table (car kv) (cdr kv))) snap)
                            (ls (* eta 0.5)))))))))))

;; ── the spacetime lattice: cells = places × periods ─────────────────────────
;; A place is a SpatialThing (lat/long, contained-in). A period is an integer on
;; the time axis. A cell id is "place@period". Space gives the tree; time, the chain.
(define *places*  '())                      ; place-ids (SpatialThings)
(define *periods* '(0))                      ; time axis (integers, set per world)
(define *cells*   '())                       ; cell-ids "place@period"
(define *st*      (make-hash-table))         ; place-id -> SpatialThing
(define (def-place! st) (set! *places* (append *places* (list (spatial-thing-id st))))
  (hash-set! *st* (spatial-thing-id st) st))
(define (mk-cell p t)   (format #f "~a@~a" p t))
(define (place-of  c)   (car (string-split c #\@)))
(define (period-of c)   (string->number (cadr (string-split c #\@))))
(define (build-cells!)
  (set! *cells* (append-map (lambda (p) (map (lambda (t) (mk-cell p t)) *periods*)) *places*)))
(define (km a b)                             ; great-circle km between two cells' PLACES
  (let* ((A (href *st* (place-of a))) (B (href *st* (place-of b))) (d2r (/ 3.141592653589793 180.0)))
    (if (or (not A) (not B)) 0.0
        (let* ((la1 (* d2r (spatial-thing-lat A))) (la2 (* d2r (spatial-thing-lat B)))
               (dla (* d2r (- (spatial-thing-lat B) (spatial-thing-lat A))))
               (dlo (* d2r (- (spatial-thing-long B) (spatial-thing-long A))))
               (h (+ (expt (sin (/ dla 2)) 2)
                     (* (cos la1) (cos la2) (expt (sin (/ dlo 2)) 2)))))
          (* 6371.0 2.0 (atan (sqrt h) (sqrt (- 1.0 h))))))))

;; ── moves: one abstraction, two faces (transport in space, storage in time) ──
(define *tau*  0.0)                 ; transport tension per unit per km (spatial)
(define *hold* 0.0)                 ; holding tension per unit per period (temporal)
(define *storable* '())            ; goods that can cross time (have a temporal edge)
(define *decay*  (make-hash-table)) ; spec -> fraction lost per period stored (0 = lossless)
(define (spatial-step? a b)  (and (= (period-of a) (period-of b)) (not (equal? (place-of a) (place-of b)))))
(define (temporal-step? a b) (and (equal? (place-of a) (place-of b)) (= (period-of b) (+ 1 (period-of a)))))
(define (allowed? s a b)           ; may good s move a -> b in one hop?
  (or (spatial-step? a b)
      (and (temporal-step? a b) (member s *storable*))))        ; time has an arrow
(define (move-cost a b)            ; per-unit cost of the move (assumes allowed)
  (if (= (period-of a) (period-of b)) (* *tau* (km a b)) *hold*))
(define (retention s a b)          ; fraction surviving the move (decay only bites in time)
  (if (= (period-of a) (period-of b)) 1.0 (- 1.0 (href *decay* s 0.0))))
(define (out-cost s c)             ; cheapest channel out of c for s (spatial OR temporal)
  (let ((os (filter (lambda (o) (and (not (equal? o c)) (allowed? s c o))) *cells*)))
    (if (null? os) 0.0 (apply min (map (lambda (o) (move-cost c o)) os)))))

;; ── the placeless recipe graph + located facts ─────────────────────────────
(define *produced*  '())  ; specs with a recipe (finals ∪ intermediates)
(define *raws*      '())  ; drawn, not produced (located by *eco*)
(define *movable*   '())  ; goods that can move at all (between cells)
(define *bom*  (make-hash-table))   ; out-spec -> alist (input-spec . qty)
(define *ell*  (make-hash-table))   ; out-spec -> work-hours per unit
(define *consumers* (make-hash-table)) ; in-spec -> alist (out-spec . qty)  [reverse BOM]
(define *target* (make-hash-table)) ; "spec|cell" -> located, dated demand
(define *prio*   (make-hash-table)) ; spec -> desire weight
(define *eco*    (make-hash-table)) ; "raw|cell" -> draw cap (located, dated envelope)
(define *labour* (make-hash-table)) ; cell -> work-hours available (located, dated labour)
(define *init*   (make-hash-table)) ; "spec|cell" -> exogenous initial on-hand

(define (consumers s) (href *consumers* s '()))
(define (derive-consumers!)
  (hash-clear! *consumers*)
  (hash-for-each (lambda (out inputs)
                   (for-each (lambda (io)
                               (hash-set! *consumers* (car io) (acons out (cdr io) (consumers (car io)))))
                             inputs))
                 *bom*))

;; ── located accounting (ONE definition each, used everywhere) ───────────────
;; `prod` is a production lookup (spec cell -> quantity); pass a vars-hash view
;; or a single cell's local plan. This single source of truth is deliberate —
;; the net-export formula was once triplicated, and that is what let the demanded
;; bread be mistaken for an exportable surplus (the collapse bug).
(define (qv vars s c) (if (member s *raws*) 0.0 (href vars (k3 "q" s c) 0.0)))
(define (vprod vars) (lambda (s c) (qv vars s c)))          ; production lookup over a plan
(define (consumed prod s c)                                  ; recipe consumption of s at c
  (fold (lambda (oc a) (+ a (* (cdr oc) (prod (car oc) c)))) 0.0 (consumers s)))
(define (net-export prod s c)                                ; made − recipe-consumed − DEMAND
  (- (+ (href *init* (k2 s c) 0.0) (prod s c))               ; (located demand is a consumption
     (consumed prod s c) (href *target* (k2 s c) 0.0)))      ;  SINK, not a surplus to move)
(define (imports vars s c)                                   ; arrivals (spatial + storage-in), net of decay
  (fold (lambda (o a) (if (allowed? s o c)
                          (+ a (* (href vars (tk s o c) 0.0) (retention s o c))) a)) 0.0 *cells*))
(define (exports vars s c)                                   ; departures (shipped out + stored forward)
  (fold (lambda (o a) (if (allowed? s c o) (+ a (href vars (tk s c o) 0.0)) a)) 0.0 *cells*))
(define (labour-used vars c)
  (fold (lambda (s a) (+ a (* (qv vars s c) (href *ell* s 0.0)))) 0.0 *produced*))
(define (gap supply target) (if (<= target 0.0) 0.0 (max 0.0 (/ (- target supply) target))))

;; ── feasible warm start (the spacetime cascade) ──────────────────────────────
;; Explode each located demand through the BOM to total production per spec, and
;; place it at the demand cell — except a spec that draws a raw, placed where that
;; raw exists. The solver then only POLISHES (rebalance labour, reroute/reschedule
;; moves), which is smooth.
(define (cascade-totals)
  (let ((R (make-hash-table)))
    (define (need spec qty)
      (unless (member spec *raws*)
        (hadd! R spec qty)
        (for-each (lambda (io) (need (car io) (* qty (cdr io)))) (href *bom* spec '()))))
    (hash-for-each (lambda (key tgt) (need (car (string-split key #\|)) tgt)) *target*)
    R))
(define (warm-start! vars)
  (let* ((R (cascade-totals))
         (dcell (cadr (string-split (caar (hash-map->list cons *target*)) #\|))))
    (hash-for-each
     (lambda (spec total)
       (let* ((raw-in (find (lambda (io) (member (car io) *raws*)) (href *bom* spec '())))
              (pcell  (if raw-in
                          (or (find (lambda (c) (href *eco* (k2 (car raw-in) c) #f)) *cells*) dcell)
                          dcell)))
         (hash-set! vars (k3 "q" spec pcell) total)
         (unless (equal? pcell dcell)
           (when (allowed? spec pcell dcell) (hash-set! vars (tk spec pcell dcell) total)))))
     R)))

;; ── realise moves: ship/store local surplus to local deficit, cheapest channel
;; first (spatial haversine OR temporal hand-off; contained-in/the calendar are
;; the coordination topology, the moves take the direct edge).
(define (route! s vars)
  (let ((bal (vprod vars)))
    (define (localbal c) (net-export bal s c))               ; surplus(+) / deficit(−)
    (for-each (lambda (a) (for-each (lambda (b)
                (when (allowed? s a b) (hash-set! vars (tk s a b) 0.0))) *cells*)) *cells*)
    (let ((rem (make-hash-table)))
      (for-each (lambda (c) (hash-set! rem c (max 0.0 (localbal c)))) *cells*)
      (for-each (lambda (c)
                  (let pull ((srcs (sort (filter (lambda (o) (and (not (equal? o c)) (allowed? s o c))) *cells*)
                                         (lambda (a b) (< (move-cost a c) (move-cost b c)))))
                             (need (max 0.0 (- (localbal c)))))
                    (when (and (pair? srcs) (> need 1e-9))
                      (let* ((src (car srcs)) (ret (retention s src c)) (av (href rem src 0.0))
                             (draw (min av (/ need ret)))      ; draw extra to cover decay in transit
                             (deliver (* draw ret)))
                        (when (> draw 1e-9)
                          (hash-set! rem src (- av draw))
                          (hash-set! vars (tk s src c) draw))
                        (pull (cdr srcs) (- need deliver))))))
                *cells*))))

;; ════════════════════════════════════════════════════════════════════════════
;; HIERARCHICAL ADMM — the convergent spacetime-equilibrium = federation engine
;; ════════════════════════════════════════════════════════════════════════════
;; Exchange-ADMM over the spacetime lattice:
;;   • leaf cell: maximise local harmony − (ρ/2)(net-flow − target)² per good. The
;;     proximal term is the bang-bang killer: it makes the best-response single-
;;     valued, so production meters to demand instead of slamming the wall.
;;   • each good balances over its REACHABILITY COMPONENT — the cells its moves
;;     actually connect (a spatial subtree within a period, chained across periods
;;     for a storable good). Consensus x̄ = mean net-flow over the component; scaled
;;     dual u += x̄ drives the net-flows to balance (what one cell ships/stores out,
;;     another takes in); a cell's target = its own x − x̄ − u. A perishable good's
;;     periods are SEPARATE components, so it cannot be credited with delivery it
;;     cannot make — no stranded build-ahead.
(define (components s)              ; connected components of *cells* under (undirected) allowed?(s)
  (let ((seen (make-hash-table)) (comps '()))
    (for-each
     (lambda (start)
       (unless (hash-ref seen start #f)
         (let ((comp '()))
           (let bfs ((stack (list start)))
             (when (pair? stack)
               (let ((c (car stack)))
                 (if (hash-ref seen c #f) (bfs (cdr stack))
                     (begin (hash-set! seen c #t) (set! comp (cons c comp))
                            (bfs (append (filter (lambda (o) (and (not (hash-ref seen o #f))
                                                                  (or (allowed? s c o) (allowed? s o c))))
                                                 *cells*)
                                         (cdr stack))))))))
           (set! comps (cons comp comps)))))
     *cells*)
    comps))

;; one cell's ADMM step: maximise local harmony with the proximal pull toward its
;; consensus target. A negative target is a planned arrival to consume against.
(define (admm-cell c tgt rho inner warmq)
  (let* ((q (make-hash-table))
         (prod (lambda (s _c) (hash-ref q s 0.0)))          ; this cell's local plan
         (precond (+ rho (/ (* 2.0 (apply max 1.0 (map cdr (hash-map->list cons *prio*))))
                            (expt (apply max 1.0 (map cdr (hash-map->list cons *target*))) 2)))))
    (for-each (lambda (s) (hash-set! q s (href warmq s 0.0))) *produced*)
    (define (arrive s) (max 0.0 (- (href tgt (k2 s c) 0.0))))   ; planned arrivals (consensus target<0)
    (define (have   s) (+ (href *init* (k2 s c) 0.0) (hash-ref q s 0.0) (arrive s)))  ; on-hand+made+arrived
    (define (G)
      (- 0.0
         (fold (lambda (f a)                        ; desire for finals demanded here-and-now
                 (let ((td (href *target* (k2 f c) #f)))
                   (if td (+ a (* (href *prio* f 0.0)
                                  (expt (gap (- (have f) (consumed prod f c)) td) 2)))
                       a)))
               0.0 *produced*)
         (barrier (fold (lambda (s a) (+ a (* (prod s c) (href *ell* s 0.0)))) 0.0 *produced*)
                  (href *labour* c 1e9))                       ; local labour wall (this cell, this period)
         (fold (lambda (r a) (let ((cap (href *eco* (k2 r c) 0.0)) (d (consumed prod r c)))
                               (cond ((<= d 1e-12) a) ((>= d cap) (+ a 1e9)) (else (+ a (barrier d cap))))))
               0.0 *raws*)
         (fold (lambda (s a)                        ; hard balance: here+arrivals ≥ recipes + demand
                 (+ a (hinge (+ (net-export prod s c) (arrive s)))))
               0.0 *movable*)
         (fold (lambda (s a)                        ; ADMM proximal — the bang-bang killer
                 (+ a (* (/ rho 2.0) (expt (- (net-export prod s c) (href tgt (k2 s c) 0.0)) 2))))
               0.0 *movable*)
         (fold (lambda (s a)                        ; move cost: the sender bears it (ship OR store, cheapest channel)
                 (+ a (* (out-cost s c) (max 0.0 (net-export prod s c)))))
               0.0 *movable*)))
    (ascend! q *produced* G inner precond)))

(define (solve-admm rounds inner rho)
  (let ((vars (make-hash-table)) (tgt (make-hash-table))
        (u (make-hash-table)) (xbar (make-hash-table)) (xprev (make-hash-table))
        ;; one coupling per (good, reachability component) — the balance constraints
        (couplings (append-map (lambda (s) (map (lambda (comp) (cons s comp)) (components s))) *movable*)))
    (warm-start! vars)
    (define dcap (* 1.5 (apply max 1.0 (map cdr (hash-map->list cons *target*)))))  ; dual clamp
    (define (netx s c) (net-export (vprod vars) s c))
    (define (ckey s cells) (k2 s (car (sort cells string<?))))           ; stable component id
    (define (consensus! cp)                         ; x-bar = mean net-flow over the component
      (let* ((s (car cp)) (cells (cdr cp)) (key (ckey s cells)))
        (hash-set! xbar key (/ (fold (lambda (c a) (+ a (netx s c))) 0.0 cells) (length cells)))
        (for-each (lambda (c) (hash-set! xprev (k2 s c) (netx s c))) cells)))
    (for-each (lambda (cp) (consensus! cp) (hash-set! u (ckey (car cp) (cdr cp)) 0.0)) couplings)
    (let loop ((r 0))
      (if (>= r rounds) vars
          (begin
            ;; 1. targets from the consensus: x_c − x̄_parent − u_parent
            (for-each (lambda (cp)
                        (let* ((s (car cp)) (cells (cdr cp)) (key (ckey s cells)))
                          (for-each (lambda (c)
                                      (hash-set! tgt (k2 s c)
                                                 (- (href xprev (k2 s c) 0.0) (href xbar key 0.0) (href u key 0.0))))
                                    cells)))
                      couplings)
            ;; 2. each leaf solves its proximal subproblem
            (for-each (lambda (c)
                        (let* ((warmq (let ((h (make-hash-table)))
                                        (for-each (lambda (s) (hash-set! h s (href vars (k3 "q" s c) 0.0))) *produced*)
                                        h))
                               (q (admm-cell c tgt rho inner warmq)))
                          (for-each (lambda (s) (hash-set! vars (k3 "q" s c) (hash-ref q s 0.0))) *produced*)))
                      *cells*)
            ;; 3. reconcile each component (consensus + scaled-dual update)
            (for-each (lambda (cp)
                        (let ((key (ckey (car cp) (cdr cp))))
                          (consensus! cp)                         ; clamp the dual so an INFEASIBLE
                          (hash-set! u key (max (- dcap)            ; component cannot diverge it and
                                                (min dcap (+ (href u key 0.0) (href xbar key 0.0)))))))  ; force overproduction
                      couplings)
            ;; 4. realise moves (spatial ship + temporal store, surplus → deficit)
            (for-each (lambda (s) (route! s vars)) *movable*)
            (loop (+ r 1)))))))

;; ── reporting ───────────────────────────────────────────────────────────────
(define (report vars)
  (let ((sup (vprod vars)))
    (format #t "~%   production q(spec, cell):~%")
    (for-each (lambda (s)
                (format #t "     ~8a ~a~%" s
                        (string-concatenate
                         (map (lambda (c) (format #f "  ~a ~5,1f" c (qv vars s c))) *cells*))))
              *produced*)
    (format #t "   moves  (ship = spatial, store = temporal):~%")
    (for-each (lambda (s)
                (for-each (lambda (from)
                            (for-each (lambda (to)
                                        (let ((f (href vars (tk s from to) 0.0)))
                                          (when (> f 0.05)
                                            (format #t "     ~a  ~a -> ~a  ~5,1f  (~a)~%"
                                                    s from to f (if (spatial-step? from to) "ship" "store")))))
                                      *cells*))
                          *cells*))
              *movable*)
    (format #t "   located pulls  λ(spec, cell):~%")
    (for-each (lambda (cell)
                (for-each (lambda (r)
                            (let ((cap (href *eco* (k2 r cell) #f)))
                              (when cap
                                (let ((d (consumed sup r cell)))
                                  (format #t "     ~a@~a draw ~5,1f/~a  pull ~5,2f~%"
                                          r cell d cap (if (>= d cap) 1e6 (/ 4.0 (- cap d))))))))
                          *raws*)
                (let ((u (labour-used vars cell)) (a (href *labour* cell 1e9)))
                  (when (< a 1e8)
                    (format #t "     labour@~a  ~5,1f/~a  pull ~5,2f~%"
                            cell u a (if (>= u a) 1e6 (/ 4.0 (- a u)))))))
              *cells*)
    (for-each (lambda (key)
                (let* ((parts (string-split key #\|)) (spec (car parts)) (cell (cadr parts))
                       (tgt (hash-ref *target* key 0.0))
                       ;; supply toward demand = on-hand + made + arrived − departed − recipes
                       (supply (- (+ (href *init* key 0.0) (qv vars spec cell)
                                     (imports vars spec cell)) (exports vars spec cell)
                                  (consumed sup spec cell))))
                  (format #t "   demand ~a@~a delivered ~5,1f/~a  (gap ~,2f)~%"
                          spec cell supply tgt (gap supply tgt))))
              (sort (map car (hash-map->list cons *target*)) string<?))))

;; ── world setup (clears the globals so independent worlds can run) ───────────
(define (reset-world!)
  (set! *places* '()) (set! *cells* '()) (set! *periods* '(0))
  (set! *raws* '()) (set! *produced* '()) (set! *movable* '()) (set! *storable* '())
  (for-each hash-clear! (list *st* *bom* *ell* *consumers* *target* *prio* *eco* *labour* *init* *decay*)))

;; ═══ WORLD A — SPACE: bread wanted in the CITY; soil only in the COUNTRY ═════
;; bread <- flour <- grain <- soil. One period. The plan must place growing in the
;; country and decide WHERE to mill and bake, and WHAT to ship — all emergent.
(define (setup-space!)
  (reset-world!)
  (def-place! (make-spatial-thing #:id "city"    #:name "City" #:lat 40.00 #:long -74.00
                                  #:contained-in "earth"))
  (def-place! (make-spatial-thing #:id "country" #:name "Country" #:lat 41.00 #:long -74.00
                                  #:contained-in "earth"))  ; ~111 km
  (set! *periods* '(0)) (build-cells!)
  (set! *raws* '("soil")) (set! *produced* '("bread" "flour" "grain"))
  (set! *movable* '("bread" "flour" "grain")) (set! *storable* '())
  (hash-set! *bom* "bread" '(("flour" . 1.0)))  (hash-set! *ell* "bread" 0.5)
  (hash-set! *bom* "flour" '(("grain" . 1.2)))  (hash-set! *ell* "flour" 0.3)
  (hash-set! *bom* "grain" '(("soil"  . 1.0)))  (hash-set! *ell* "grain" 0.5)
  (derive-consumers!)
  (hash-set! *prio* "bread" 1000.0)
  (hash-set! *target* (k2 "bread" "city@0") 100.0)
  (hash-set! *eco* (k2 "soil" "country@0") 200.0))

(define (run-space label tau city-labour country-labour)
  (set! *tau* tau) (set! *hold* 0.0)
  (hash-set! *labour* "city@0" city-labour) (hash-set! *labour* "country@0" country-labour)
  (format #t "~%-- ~a  (transport ~a/unit-km, labour city ~a / country ~a)~%"
          label tau city-labour country-labour)
  (report (solve-admm 400 50 0.4)))

;; ═══ WORLD B — TIME: a demand SPIKE meets a labour valley ════════════════════
;; One place (town), two periods. Bread is demanded only at t1, where labour sits in
;; a VALLEY; t0 has slack. Because bread is STORABLE, the plan bakes ahead in the
;; cheap t0 and stores forward — TIMING selection, the twin of site selection, and
;; storage is just transport through time. The DEEPER the t1 valley, the MORE is
;; built ahead: the located time-pull λ(labour, t1) drives exactly the right split.
;; Perishability is the time-analogue of non-transportability — a good not in
;; *storable* has no temporal edge and must be baked in-period; the model supports
;; it (allowed? gates the temporal move on *storable*).
;;
;; KNOWN LIMITATION (diagnosed, deferred — NOT solved here): a perishable spike that
;; OUTRUNS its own period's labour is a single-cell INFEASIBILITY. There the cell's
;; first-order coordinate ascent hits a genuine STATIONARY TRAP — empirically the
;; same inconsistent point at 150 and at 10 000 inner iterations — so it neither
;; converges to the consistent feasible max nor reports a clean gap. This is the
;; degenerate single-cell case the CERTIFIED full-Newton solver in relaxation.scm is
;; built for; the honest fix is to route infeasible single-cell components there (or
;; give ascend! a second-order step), and is left as follow-up. spatial-core couples
;; FEASIBLE multi-cell components, which it does converge (every scenario below).
(define* (setup-time! t1-labour #:optional (storable? #t))
  (reset-world!)
  (def-place! (make-spatial-thing #:id "town" #:name "Town" #:lat 40.00 #:long -74.00
                                  #:contained-in "earth"))
  (set! *periods* '(0 1)) (build-cells!)
  (set! *raws* '("soil")) (set! *produced* '("bread" "flour" "grain"))
  (set! *movable* '("bread" "flour" "grain"))
  (set! *storable* (if storable? '("bread" "flour" "grain") '()))
  (hash-set! *bom* "bread" '(("flour" . 1.0)))  (hash-set! *ell* "bread" 0.5)
  (hash-set! *bom* "flour" '(("grain" . 1.2)))  (hash-set! *ell* "flour" 0.3)
  (hash-set! *bom* "grain" '(("soil"  . 1.0)))  (hash-set! *ell* "grain" 0.5)
  (derive-consumers!)
  (hash-set! *prio* "bread" 1000.0)
  (hash-set! *target* (k2 "bread" "town@1") 100.0)     ; the spike: wanted at t1, not t0
  (hash-set! *eco* (k2 "soil" "town@0") 400.0)          ; soil regenerates each period
  (hash-set! *eco* (k2 "soil" "town@1") 400.0)
  (hash-set! *labour* "town@0" 250.0)                   ; t0: abundant and slack
  (hash-set! *labour* "town@1" t1-labour))              ; t1: the valley (set per scenario)

(define* (run-time label t1-labour hold #:optional (storable? #t))
  (setup-time! t1-labour storable?) (set! *tau* 0.0) (set! *hold* hold)
  (format #t "~%-- ~a  (t1 labour ~a, holding ~a/unit-period)~%" label t1-labour hold)
  (report (solve-admm 250 30 0.4)))

;; ── run both worlds ─────────────────────────────────────────────────────────
(format #t "~%==== WORLD A — SPACE: where to grow, mill, bake (bread<-flour<-grain<-soil) ====~%")
(setup-space!)
(run-space "cheap transport"     0.002 120.0 70.0)   ; grow country, mill+bake CITY
(run-space "dear transport"      0.04  120.0 70.0)   ; processing pulls to country
(run-space "country labour-rich" 0.01   60.0 160.0)  ; milling RELOCATES to country

(format #t "~%==== WORLD B — TIME: when to bake (demand spike at t1 over a labour valley) ====~%")
(run-time "deep valley   (t1=40)  -> most of the bake built ahead at t0, stored forward"  40.0 0.01)
(run-time "shallow valley (t1=100) -> only the excess built ahead; t1 carries the rest"  100.0 0.01)
(newline)


