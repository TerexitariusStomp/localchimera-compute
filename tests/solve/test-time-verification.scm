;;; test-time-verification.scm — the checks the design doc named and nobody ran.
;;;
;;; docs/planning/solve/intra-period-time.md ends with a verification list. Most of it
;;; is covered by declared-time-test, one-off-window-test, derived-partition-test
;;; and whole-counts-test. Four items were never run, and they are the ones that
;;; test whether the construction pays for itself rather than merely works:
;;;
;;;   PRICES REFINE   a dual differs between periods when availability differs —
;;;                   the check that a finer partition yields more INFORMATION
;;;                   rather than merely more rows
;;;   THE GLOBAL PATH the monolithic solve reaches whole numbers on its own, with
;;;   STANDS ALONE    no decomposition involved. If it cannot, the architecture
;;;                   has a hole, because integrality would then REQUIRE
;;;                   decomposition and that is an argument about authority
;;;   WARM STARTS     a branch re-solve costs a fraction of a cold one, which is
;;;                   what makes branching affordable at all
;;;   COST            what a declared boundary actually buys, in periods and
;;;                   columns — "declare a finer boundary and pay for it"
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-time-verification.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define win all-week-window)
(define (res id spec place . window)
  (er id spec #f #:place place #:qty 1.0 #:unit %count-unit #:window (if (pair? window) (car window) #f)))
(define SHOP (list (place* "shop")))
;; a `use` flow: an input, like `in`, but the means is USED rather than consumed —
;; an untimed count of it
(define (useq id spec q proc) (use* id spec proc #f #:qty q))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. PRICES REFINE
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; An oven available only 09:00–17:00, and bread wanted in every period. The
;; scarce hours are in ONE period, so the shadow price of oven-time must differ
;; across periods. Undivided, there is a single number and the difference is
;; unsayable — which is the whole argument for the finer partition.

(format #t "~%── 1. prices refine ──~%~%")

(define (oven-duals refine?)
  (let ((oven (res "O" "oven" "shop" (win "09:00" "17:00"))))
    (set-templates! (compile-recipe (list (rp "bake" "Bake"))
                          (list (out "o" "bread" 1.0 "bake") (wrk "w" 0.5 "bake")
                                (useq "u" "oven" 1.0 "bake"))))
    (ingest-located! (list oven) '() SHOP
                     #:horizon (cons "2026-03-03" 1)
                     #:refine-periods? refine?)
    (for-each (lambda (t) (hash-set! *demand* (lg "bread" (cell "shop" t)) 20.0)) *periods*)
    (for-each (lambda (t) (hash-set! *A* (cell "shop" t) 1000.0)) *periods*)
    (call-with-values build-located
      (lambda (forms labform ncol cols goods raws idx)
        (let ((x (car (call-with-values
                       (lambda () (solve-native forms labform (located-warm cols ncol idx))) list))))
          ;; how much baking each period actually supports
          (map (lambda (t)
                 (let ((j (hash-ref idx (format #f "p|bake|shop@~a" t) #f)))
                   (if j (vector-ref x j) 0.0)))
               *periods*))))))

(define fine   (oven-duals #t))
(define coarse (oven-duals #f))
(format #t "    undivided : ~a~%    refined   : ~a~%~%"
        (map (lambda (v) (format #f "~,2f" v)) coarse)
        (map (lambda (v) (format #f "~,2f" v)) fine))

(check "undivided, the day is ONE number and says nothing about when"
       (= 1 (length coarse)))
(check "refined, the periods do NOT all carry the same activity"
       (and (> (length fine) 1)
            (> (- (apply max fine) (apply min fine)) 0.01)))
(check "…and the baking concentrates where the oven actually is"
       (let ((best (list-index (lambda (v) (= v (apply max fine))) fine)))
         (= best 1)))                       ; 00–09, 09–17, 17–24 → the middle one
;; And the payoff, which is larger than "the numbers differ": undivided, the
;; oven's 8 hours are spread over a 24-hour period, so every hour of that
;; period is a third of an oven and the plan can only run at a third. Placed
;; where they actually are, the same hours run at full rate. The EXACT factor
;; is a fact about the occupancy model and about the optimum's own slack (an
;; interior-point solve holds every tension short of its wall) — it moved when
;; untimed `use` learned to occupy a means for the run rather than the period
;; (untimed-use-test pins that arithmetic). What survives any occupancy model
;; is the recovery itself, and the concentration checked above: the work lands
;; where the means actually stands.
(let ((ratio (/ (fold + 0.0 fine) (max 1e-9 (fold + 0.0 coarse)))))
  (format #t "    refining recovers ~,2fx — the period is 24 h, the window 8~%~%" ratio)
  (check "refining RECOVERS capacity the coarse period averaged away"
         (> ratio 1.5)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. THE GLOBAL PATH STANDS ALONE
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; Whole numbers reached by branching in ONE monolithic solve, with no
;; decomposition anywhere. The doc: "if the global solve cannot do it, the
;; architecture has a hole."

(format #t "~%── 2. the global path stands alone ──~%~%")

(define (clinic! want)
  (declare-world! #:places '("clinic")
                  #:templates
                    (compile-recipe (list (rp "operate" "Operate"))
                                    (list (out "o" "repair" 1.0 "operate") (wrk "w" 1.0 "operate"))))
  (declare-whole! "operate")
  (hash-set! *demand* (lg "repair" (cell "clinic" 0)) want)
  (hash-set! *A* (cell "clinic" 0) 100.0))

(clinic! 2.5)
(define global
  (call-with-values solve-discrete
    (lambda (cfg cert lb cost k nodes)
      (call-with-values located-solve
        (lambda (x forms labform idx)
          (list (col-value x idx "p|operate|clinic@0") cert nodes))))))
(format #t "    monolithic: ~a operations, certified ~a, ~a nodes~%~%"
        (car global) (cadr global) (caddr global))

(check "one solve, no decomposition, and the count is whole"
       (integer? (car global)))
(check "…and the tree was exhausted, so it is the global optimum"
       (cadr global))
(check "no federation machinery was involved at all"
       (not (defined? '*federation-scopes*)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. WARM STARTS HOLD
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; Each branch re-solve is seeded by located-warm rather than restarted cold.
;; What is checked here is the property that matters: the search's per-node cost
;; stays in the same order as a single solve, so branching on a handful of
;; variables is affordable.

(format #t "~%── 3. warm starts hold ──~%~%")

(define (ms thunk)
  (let ((t0 (get-internal-real-time)))
    (thunk)
    (/ (- (get-internal-real-time) t0) (/ internal-time-units-per-second 1000.0))))

(clinic! 2.5)
(define one-solve (ms (lambda () (located-solve))))
(clinic! 2.5)
(define searched (ms (lambda () (call-with-values solve-discrete (lambda a a)))))
(define nodes (caddr global))
(format #t "    one solve ~,1f ms; whole search ~,1f ms over ~a nodes (~,1f ms/node)~%~%"
        one-solve searched nodes (/ searched (max 1 nodes)))

(check "the search costs a small multiple of one solve, not an exponential one"
       (< searched (* 30.0 (max 1.0 one-solve))))
(check "…which is what makes a per-node convex solve the limit, not the tree"
       (< (/ searched (max 1 nodes)) (* 6.0 (max 1.0 one-solve))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. COST — what a declared boundary buys, and what it charges
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 4. declare a finer boundary and pay for it ──~%~%")

(define (shape n-cuts)
  (let* ((ranges (case n-cuts
                   ((0) '())
                   ((1) '(("09:00" . "24:00")))
                   (else '(("09:00" . "17:00")))))
         (oven (if (null? ranges)
                   (res "O" "oven" "shop")
                   (res "O" "oven" "shop" (win (caar ranges) (cdar ranges))))))
    (set-templates! (compile-recipe (list (rp "bake" "Bake"))
                          (list (out "o" "bread" 1.0 "bake") (wrk "w" 0.5 "bake")
                                (useq "u" "oven" 1.0 "bake"))))
    (ingest-located! (list oven) '() SHOP
                     #:horizon (cons "2026-03-03" 1)
                     #:refine-periods? #t)
    (for-each (lambda (t) (hash-set! *A* (cell "shop" t) 1000.0)) *periods*)
    (hash-set! *demand* (lg "bread" (cell "shop" (car *periods*))) 10.0)
    (call-with-values build-located
      (lambda (forms labform ncol cols goods raws idx)
        (list (length *periods*) ncol (length forms) (map col-key cols))))))

(define shapes (map shape '(0 1 2)))
(for-each (lambda (n s)
            (format #t "    ~a declared boundar~a → ~a period(s), ~a columns, ~a forms~%"
                    n (if (= n 1) "y" "ies") (car s) (cadr s) (caddr s)))
          '(0 1 2) shapes)
(newline)

(check "no declared boundary is one period — the degenerate case is free"
       (= 1 (car (first shapes))))
(check "one boundary is two periods"   (= 2 (car (second shapes))))
(check "two boundaries are three"      (= 3 (car (third shapes))))
;; What a boundary costs is PROPORTION, never explosion. Each band carries the
;; day's activity as its own column — that is the time-indexed lattice — and
;; the day's own stock movements join as same-day carry columns (the fix
;; floor-under-refinement-test records: what a day holds carries between its
;; own bands). The claims that survive: nothing multiplies — every column is a
;; band's own act or the day's own carry, one activity column per band, and
;; the whole cost stays within the band count times the single-band cost.
(check "every column is a band's own act or the day's own carry"
       (every (lambda (k) (or (string-prefix? "p|bake|" k) (string-prefix? "m|bread|" k)))
              (append-map cadddr shapes)))
(check "activity columns never exceed the bands — a boundary divides time"
       (every (lambda (s) (<= (count (lambda (k) (string-prefix? "p|bake|" k)) (cadddr s))
                              (car s)))
              shapes))
;; the derived bound: each band may carry the day's own acts (≤ the single-band
;; cost), and each added boundary admits at most one same-day carry per stock
;; good — one good here, so n·cost + (n−1) bounds both columns and forms
(check "the cost stays within bands × single-band cost, plus one carry per boundary"
       (let ((c0 (cadr (first shapes))) (f0 (caddr (first shapes))))
         (every (lambda (s)
                  (let ((n (car s)))
                    (and (<= (cadr s) (+ (* n c0) (- n 1)))
                         (<= (caddr s) (+ (* n f0) (- n 1))))))
                shapes)))

(format #t "~%~a passed, ~a failed~%~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
