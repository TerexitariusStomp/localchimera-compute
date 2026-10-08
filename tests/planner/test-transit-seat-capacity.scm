;;; test-transit-seat-capacity.scm — a seat is capacity, and it runs out.
;;;
;;; The U-Bahn is a ResourceSpecification a ride `use`s, exactly as a car ride
;;; `use`s spec-car (knowledge/recipes/berlin-transit.scm). This proves the two
;;; things that follow from that and nothing else does.
;;;
;;; A column unit here is ONE KILOGRAM — see recipes/transport.scm's header for why
;;; a transport recipe's numbers are rates per unit moved per km. So the `use` rate
;;; is read per kg·km and the solved column value is kilograms moved.
;;;
;;;   1. the arc column DRAWS the network's per-period service good Svc|ubahn,
;;;      scaled by the distance travelled (column inspection, solver-free);
;;;   2. the Svc cap BINDS — starve the seat pool and the freight stops; and with
;;;      two networks available, a plan denied seats on one REROUTES onto the
;;;      other rather than failing. That is "the M10 fills up at 08:30, so the
;;;      crates go by S-Bahn", as an arithmetic fact about the solve.
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         tests/planner/test-transit-seat-capacity.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner solve solver)
             (playnet planner vf schemas)
             (playnet planner knowledge dsl shorthand))
;; transport.scm is a module now — use-modules, not primitive-load. A
;; define-module inside a primitive-loaded file switches current-module for
;; the REST of this file and never switches back.
(use-modules (playnet planner knowledge recipes transport))

(define *pass* 0) (define *fail* 0)
(define (check label ok)
  (if ok (set! *pass* (+ *pass* 1)) (set! *fail* (+ *fail* 1)))
  (format #t "  [~a] ~a~%" (if ok "✓" "✗") label))

;; ── a haul that rides the network: pickup crates, occupy seats, drop them ────
;; NETS = ((service-spec . seat-hours-per-km) …); one haul process per network,
;; so the solve chooses between them exactly as the mover chooses between modes.
(define (setup! nets caps)
  (declare-world! #:places '(("A" 52.48 13.40) ("B" 52.50 13.43))   ; ~3 km across Berlin
                  #:templates
                    (append-map
                      (lambda (n)
                        (let ((pid (string-append "haul." (car n))))
                          (compile-recipe
                           (list (rp* pid "Haul"))
                           (list (pickup-flow  (string-append pid ".pu") "freight" 25.0 "kg" pid)
                                 (use-flow     (string-append pid ".svc") (car n) 1.0 (cdr n) pid)
                                 (dropoff-flow (string-append pid ".do") "freight" 25.0 "kg" pid)))))
                      nets))
  (hash-set! *cap* (lg "freight" (cell "A" 0)) 500.0)          ; crates waiting at A
  (for-each (lambda (c) (hash-set! *cap* (lg (svc-good (car c)) (cell "A" 0)) (cdr c)))
            caps)
  (hash-set! *demand* (lg "freight" (cell "B" 0)) 400.0))      ; wanted at B

(define (moved-by nets caps)
  "Solve and return ((service-spec . kg-moved) …)."
  (setup! nets caps)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let ((x (call-with-values (lambda () (solve-osqp forms labform ncol)) (lambda (x . _) x))))
        (map (lambda (n)
               (cons (car n)
                     (hash-fold (lambda (k i a)
                                  (if (string-prefix? (string-append "p|haul." (car n) "|A@0|B@0") k)
                                      (+ a (vector-ref x i)) a))
                                0.0 idx)))
             nets)))))

(define UBAHN '("ubahn" . 0.050))
(define SBAHN '("sbahn" . 0.042))

;; ── 1. the column draws the service good, scaled by distance ────────────────
(format #t "~%── the haul DRAWS the U-Bahn's service good ──~%")
(setup! (list UBAHN) '(("ubahn" . 200.0)))
(define cols (build-columns))
(define arc  (find (lambda (c) (equal? (col-key c) "p|haul.ubahn|A@0|B@0")) cols))
(define svc  (and arc (assoc (lg (svc-good "ubahn") (cell "A" 0)) (col-flows arc))))
(define d    (km (cell "A" 0) (cell "B" 0)))
(format #t "  arc ~~~,1f km · Svc|ubahn@A coefficient = ~,3f  (0.050 h/km × ~,1f km)~%"
        d (and svc (cdr svc)) d)
(check "the arc column exists and consumes the network's service good" (and svc (< (cdr svc) 0.0)))
(check "the draw is the per-km rate × the distance travelled"
       (and svc (< (abs (- (- (cdr svc)) (* 0.050 d))) 1e-6)))

;; ── 2. the cap binds ────────────────────────────────────────────────────────
(format #t "~%── starve the seat pool and the hauls stop ──~%")
(define kg200 (assoc-ref (moved-by (list UBAHN) '(("ubahn" . 200.0))) "ubahn"))
(define kg2   (assoc-ref (moved-by (list UBAHN) '(("ubahn" .   2.0))) "ubahn"))
(define kg1   (assoc-ref (moved-by (list UBAHN) '(("ubahn" .   1.0))) "ubahn"))
(define kg0   (assoc-ref (moved-by (list UBAHN) '(("ubahn" .   0.0))) "ubahn"))
(define (drawn kg) (* kg 0.050 d))     ; seat-hours that moving KG consumes
(format #t "  200 seat-hours → ~,3f kg  (draws ~,2f — the pool is ample, demand binds)~%    2 seat-hours → ~,3f kg  (draws ~,2f — the pool binds)~%    1 seat-hour  → ~,3f kg  (draws ~,2f)~%    0 seat-hours → ~,3f kg~%"
        kg200 (drawn kg200) kg2 (drawn kg2) kg1 (drawn kg1) kg0)
(check "an ample seat pool lets the freight move"            (> kg200 1.0))
(check "a scarce pool RATIONS it — less freight, not free" (< kg1 (* 0.5 kg200)))
;; a barrier optimum sits AT or inside its constraint, so the honest claims are
;; that the draw does not overrun the pool and that halving the pool halves the
;; traffic. Read against the pool's OWN magnitude rather than absolute zero: an
;; active constraint is where a barrier method leaves its residual, and a draw
;; one part in ten thousand over 2.0 seat-hours is that residual, not a seat
;; nobody paid for. This is `bar-slacks-feasible?`'s rule (planner.scm) applied
;; to a claim about the answer rather than about feasibility — the two must not
;; drift apart.
(define (within-pool? draw pool) (<= draw (* pool (+ 1.0 1e-3))))
(check "the draw never overruns the seats on offer"
       (and (within-pool? (drawn kg1) 1.0) (within-pool? (drawn kg2) 2.0)))
(check "…and the traffic scales with the pool — halve the seats, halve the freight"
       (< (abs (- (/ kg2 kg1) 2.0)) 0.15))
(check "no seats ⇒ nothing moves by that network"        (< kg0 0.05))

;; ── 3. the reroute ──────────────────────────────────────────────────────────
(format #t "~%── the M10 fills up at 08:30, so the crates go by S-Bahn ──~%")
(define both (moved-by (list UBAHN SBAHN) '(("ubahn" . 200.0) ("sbahn" . 200.0))))
(define u-starved (moved-by (list UBAHN SBAHN) '(("ubahn" . 0.0) ("sbahn" . 200.0))))
(format #t "  both open:      ubahn ~,3f · sbahn ~,3f~%" (assoc-ref both "ubahn") (assoc-ref both "sbahn"))
(format #t "  ubahn starved:  ubahn ~,3f · sbahn ~,3f~%"
        (assoc-ref u-starved "ubahn") (assoc-ref u-starved "sbahn"))
(check "with the U-Bahn closed, nothing rides it"
       (< (assoc-ref u-starved "ubahn") 0.05))
(check "…and the S-Bahn takes up the slack — it carries far more than it did"
       (> (assoc-ref u-starved "sbahn") (* 1.2 (assoc-ref both "sbahn"))))
(check "the plan REROUTES rather than failing: most of the freight still moves"
       (> (assoc-ref u-starved "sbahn")
          (* 0.6 (+ (assoc-ref both "ubahn") (assoc-ref both "sbahn")))))
;; …but rerouting is not free: one network cannot fully replace two.
(check "losing a line still COSTS throughput — the reroute is a second-best"
       (< (assoc-ref u-starved "sbahn")
          (+ (assoc-ref both "ubahn") (assoc-ref both "sbahn"))))

(format #t "~%  ~a a seat is capacity: the network is `use`d like any vehicle, its Svc pool~%    rations the plan, and a closed line reroutes rather than teleports.~%~%"
        (if (= *fail* 0) "✓" "✗"))
(when (> *fail* 0) (exit 1))
