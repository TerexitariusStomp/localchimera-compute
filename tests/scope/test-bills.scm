;;; test-bills.scm — the plan asked backwards: what would it take?
;;;
;;; Rights, needs and wants are three kinds the solver already holds apart — a
;;; floor, a held margin, a want. The bill turns the question around: with the
;;; scarce things for sale at a price in hours, hold one tier after another as
;;; a wall and read what the solve had to buy. Three tiers, three bills, and the
;;; step between them is the price of the tier.
;;;
;;; Part 1 is the reproduction-diet fixture, starved of labour: three people,
;;; hard kcal/protein floors, a held protein margin for one of them, a veg
;;; want each, land walled. Labour may be hired. Part 2 is the Berlin food
;;; chain, live, with no surplus set out and surplus for sale.
;;;
;;; Run: guile --no-auto-compile -L module tests/scope/test-bills.scm

(use-modules (playnet test harness) (playnet knowledge recipes berlin-food-seed) (playnet scope root) (playnet solve compile) (srfi srfi-1) (playnet scope live)
             (playnet solve engine) (playnet solve compile) (playnet solve solver)
             (goblins) (goblins vat)
             (srfi srfi-1) (ice-9 format))
(use-modules (playnet knowledge recipes berlin-food-seed))
;; A period here is a WEEK: the seeded chain names its weekdays, and this plan is one period over all of them.
(set-period-length! 1.0 "week")

;;; ─── part 1: the diet fixture, starved of hours ─────────────────────────
(define PEOPLE '(("ana" 2800 70) ("bo" 2200 55) ("cy" 1500 35)))
(define FOODS '(("grain" "Grain" 350  5 0.30 1.0) ("beans" "Beans" 340 21 0.80 1.6)))
(define VEG-WANT 3.0)
(define PROTEIN-MARGIN 20.0)          ; ana's held margin above the floor; at ease halfway up
(define WIDE-WALL  (list 30.0 34.0 0.5 80.0))   ; land tip ~32: room for every tier
(define TIGHT-WALL (list 18.0 20.0 0.5 80.0))   ; land tip ~19: below the ~21 the floors alone must draw

(define (recipes)
  (compile-recipe
    (append
      (append-map (lambda (p) (map (lambda (f) (rp (string-append (car f) "-" (car p))
                                                   (string-append (cadr f) "→" (car p)))) FOODS)) PEOPLE)
      (map (lambda (p) (rp (string-append "veg-" (car p)) (string-append "Veg→" (car p)))) PEOPLE))
    (append
      (append-map (lambda (p)
        (append-map (lambda (f)
          (let ((rid (string-append (car f) "-" (car p))) (pid (car p)))
            (list (out (string-append "k-" rid) (string-append "kcal|" pid)    (third f)  rid)
                  (out (string-append "p-" rid) (string-append "protein|" pid) (fourth f) rid)
                  (in  (string-append "l-" rid) "land" (sixth f) rid)
                  (wrk (string-append "w-" rid) (fifth f) rid)))) FOODS)) PEOPLE)
      (append-map (lambda (p)
        (let ((rid (string-append "veg-" (car p))) (pid (car p)))
          (list (out (string-append "v-" rid) (string-append "veg|" pid) 1.0 rid)
                (wrk (string-append "w-" rid) 0.5 rid)))) PEOPLE))))

;; → (hours feasible? bill)
(define (bill-of tier labour-h wall)
  (declare-world! #:places '(("town" 0.0 0.0)) #:templates (recipes)) (hash-set! *raws* "land" #t)
  (hash-set! *A* (cell "town" 0) labour-h)
  (hash-set! *frag-cap* (lg "land" (cell "town" 0)) wall)
  (for-each (lambda (p)
    (hash-set! *init* (lg (string-append "kcal|"    (car p)) (cell "town" 0)) (- (second p)))
    (hash-set! *init* (lg (string-append "protein|" (car p)) (cell "town" 0)) (- (third p)))
    (hash-set! *demand* (lg (string-append "veg|" (car p)) (cell "town" 0)) VEG-WANT))
    PEOPLE)
  ;; ana's held margin: wall at the floor, at ease halfway up PROTEIN-MARGIN
  (hash-set! *band* (lg "protein|ana" (cell "town" 0)) (make-band #:floor (list 0.0 PROTEIN-MARGIN 0.5) #:w 1.0))
  (set! *acquire* '(("labour" . 1.5)))
  (set! *promote* tier)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (call-with-values (lambda () (set! *backend* 'native-c) (solve forms labform (located-warm cols ncol idx)))
        (lambda (x t . _)
          (let ((b (acquire-bill x cols idx)) (cert (plan-verdict forms t)))
            (list (assq-ref b 'bill-hours) (assq-ref cert 'feasible?) (assq-ref b 'bill))))))))

(define rights (bill-of 'rights 2.0 WIDE-WALL))
(define needs  (bill-of 'needs  2.0 WIDE-WALL))
(define wants  (bill-of 'wants  2.0 WIDE-WALL))
(define fed    (bill-of 'wants 40.0 WIDE-WALL))     ; hours enough for everything: nothing to buy

(display "\n── the diet, two hours of labour, hours for hire ──\n")
(for-each (lambda (tag r) (format #t "  ~7a : ~6,2f h bought · feasible ~a · ~s\n" tag (first r) (second r) (third r)))
          '(rights needs wants) (list rights needs wants))
(format #t "  fed     : ~6,2f h bought (forty hours on hand)\n" (first fed))

(check-pred "rights alone already need hours nobody has — the floors buy labour"
            (> (first rights) 1.0))
(check-pred "…and the bill names the hire, at its price in hours"
            (let ((row (find (lambda (r) (string-prefix? "Lab|" (car r))) (third rights))))
              (and row (< (abs (- (caddr row) (* 1.5 (cadr row)))) 1e-6))))
(check-pred "the needs tier costs more than rights: the held margin is now a wall"
            (> (first needs) (+ (first rights) 0.05)))
(check-pred "the wants tier costs more than needs: every veg want at its ask"
            (> (first wants) (+ (first needs) 1.0)))
(check-pred "every tier is feasible inside the wide wall"
            (and (second rights) (second needs) (second wants)))
(check-pred "with hours enough on hand nothing is bought — the bill is the shortfall, not the plan"
            (< (first fed) (* 0.05 (first rights))))

;; the wall nothing sells: a land tip below what feeding three people costs.
;; Hours are for hire; land is not. The rights tier has no plan, and its
;; certificate says so — the bill cannot buy what nature bounds.
(define tight-rights (bill-of 'rights 2.0 TIGHT-WALL))
(format #t "  tight   : rights feasible ~a\n" (second tight-rights))
(check-pred "inside a wall below the floors' own draw, even the rights tier has no plan — what nature bounds, the bill cannot buy"
            (not (second tight-rights)))

;;; ─── part 2: the Berlin chain, live, with surplus for sale ───────────────
(define vat (spawn-vat))
(define PLACE "berlin")
(define (scope-with-surplus kg)
  (with-vat vat
    (let ((root (spawn-scope-root "Berlin-bill")))
      (seed-berlin-food-scope! root #:place PLACE #:ueberschuss-kg kg)
      root)))
(define root0 (scope-with-surplus 0.0))
(define want (list (cons (format #f "spec-bfs-fairteiler#~a@0" PLACE) 60.0)))

(define bought
  (with-vat vat
    (plan-scope->alist root0 #:demand want #:periods '(0) #:backend 'native-c
                       #:acquire '(("spec-bfs-ueberschuss" . 2.0)) #:promote 'wants #:allow-infeasible? #t)))
(define bills
  (with-vat vat
    (scope-bills root0 #:demand want #:periods '(0) #:backend 'native-c
                 #:acquire '(("spec-bfs-ueberschuss" . 2.0)))))

(display "\n── the Berlin chain with nothing set out, surplus for sale ──\n")
(format #t "  wants held: met ~,3f · bill ~s\n" (assq-ref bought 'met) (assq-ref bought 'bill))
(for-each (lambda (row) (format #t "  ~7a : ~7,2f h · step ~7,2f · feasible ~a · residue ~,2f h · ~s\n"
                                (car row) (assq-ref (cdr row) 'hours) (assq-ref (cdr row) 'step)
                                (assq-ref (cdr row) 'feasible) (assq-ref (cdr row) 'residue) (assq-ref (cdr row) 'bill)))
          bills)

(check-pred "the want held as a wall has a plan — by buying the surplus in"
            (eq? #t (assq-ref bought 'feasible)))
(check-pred "the bill names the surplus, at the place and day the chain starts"
            (let ((row (assoc (string-append "spec-bfs-ueberschuss#" PLACE "@0") (assq-ref bought 'bill))))
              (and row (> (cadr row) 50.0))))
(check-pred "three bills, one per tier"
            (equal? (map car bills) '(rights needs wants)))
(check-pred "rights and needs cost nothing here — the chain carries no floor, and the barrier's own margin is netted out"
            (and (< (assq-ref (cdr (first bills)) 'hours) 1e-6)
                 (< (assq-ref (cdr (second bills)) 'hours) 1e-6)))
(check-pred "…and the residue is reported beside the bill, not inside it"
            (> (assq-ref (cdr (first bills)) 'residue) 0.0))
(check-pred "the whole cost of the chain is the wants step"
            (> (assq-ref (cdr (third bills)) 'step) 10.0))

(test-summary!)
