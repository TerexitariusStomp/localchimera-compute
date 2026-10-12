;;; test-clock-horizon.scm — band width is the dial, and it turns.
;;;
;;; The lattice is the time-indexed formulation of scheduling, so sub-band
;;; precision is not a new mechanism — it is FINER BANDS, and everything that
;;; reads a declared span (capacity, windows, lead pruning, run-spanning
;;; arrivals, emitted clock moments) works at the finer grain unchanged.
;;; `set-clock-horizon!` lays out N bands of H hours; these checks turn the
;;; dial to six-hour bands and watch each mechanism keep its meaning:
;;;
;;;   · a 4 h + 4 h dependent chain no longer fits ONE band — the lead prunes
;;;     at the 6 h grain exactly as it pruned at 24 h
;;;   · a 10 h run spans two six-hour bands and lands in the second, and does
;;;     not land at all from the last band — arrival at the finer grain
;;;   · a spanning run's LABOUR is worked across the bands it covers, pro rata
;;;     by the hours it covers there — the same coverage a use'd means's
;;;     occupancy already spreads by
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-clock-horizon.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet knowledge dsl shorthand))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet vf schemas))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b) (< (abs (- a b)) 0.001))

(define PLACE "shop")


(define* (setup! procs flows storables #:key (worker #f))   ; worker: (name skills hours), present every band
  (declare-world! #:places (list PLACE)
                  #:clock '("2026-03-03" 8 6.0)   ; two days in six-hour bands
                  #:templates (compile-recipe procs flows)
                  #:storable (cons "raw" storables)
                  #:workers (if worker
                                (map (lambda (t) (list (car worker) (cadr worker) (cell PLACE t) (caddr worker))) (iota 8))
                                '()))
  (hash-set! *cap* (lg "raw" (cell PLACE 0)) 100.0))

(define (col-keys) (map col-key (build-columns)))
(define (col-flows-of key)
  (let ((c (find (lambda (c) (equal? (col-key c) key)) (build-columns))))
    (and c (col-flows c))))

(format #t "~%── §1 the dial: eight six-hour bands, each a clock interval ──~%")
(reset-world!)
(let ((ps (set-clock-horizon! "2026-03-03" 8 6.0)))
  (check "eight bands laid out" (equal? ps '(0 1 2 3 4 5 6 7)))
  (check "a band is six hours long" (near? (period-hours 0) 6.0))
  (check "band zero is the first quarter of the day"
         (equal? (period-span 0) (cons "2026-03-03T00:00" "2026-03-03T06:00")))
  (check "band four begins the second day at midnight"
         (equal? (car (period-span 4)) "2026-03-04T00:00"))
  (check "the span carries its clock, so the band is TIMED" (span-timed? 0)))

(format #t "~%── §2 lead pruning holds its meaning at the six-hour grain ──~%")
(setup! (list (rp* "A" "Step A" 4) (rp* "B" "Step B" 4))
        (list (consume* "a-in" "raw" 1.0 "A") (out* "a-out" "mid" 1.0 "A")
              (consume* "b-in" "mid" 1.0 "B") (out* "b-out" "fin" 1.0 "B"))
        '("mid" "fin"))
(let ((keys (col-keys)))
  (check "the first step fits its band and gets a column"
         (member "p|A|shop@0" keys))
  (check "4 h + 4 h does not fit one six-hour band: no same-band chain column"
         (not (member "p|B|shop@0" keys)))
  (check "the chain lands in the NEXT band, through storage"
         (member "p|B|shop@1" keys)))

(format #t "~%── §3 a 10 h run spans two six-hour bands ──~%")
(setup! (list (rp* "F" "Long run" 10))
        (list (consume* "f-in" "raw" 1.0 "F") (out* "f-out" "long" 1.0 "F"))
        '("long"))
(let ((keys (col-keys)))
  (check "the run starting at band zero exists" (member "p|F|shop@0" keys))
  (check "…and its output lands in band ONE, six hours in"
         (let ((fl (col-flows-of "p|F|shop@0")))
           (and fl (assoc (lg "long" (cell PLACE 1)) fl))))
  (check "a run starting in the LAST band cannot finish: no column"
         (not (member "p|F|shop@7" keys))))

(format #t "~%── §4 a spanning run's labour is worked across its coverage ──~%")
(setup! (list (rp* "G" "Turned run" 10))
        (list (consume* "g-in" "raw" 1.0 "G") (out* "g-out" "gg" 1.0 "G")
              (wk* "g-w" "skill-g" 5.0 "G"))
        '("gg")
        #:worker '("fio" ("skill-g") 24.0))
(let ((fl (col-flows-of "p|G|shop@0")))
  (check "the run's column exists under skilled labour" (and fl #t))
  (check "six of ten hours fall in band zero: 3 h of the 5 h worked there"
         (and fl (near? -3.0 (or (assoc-ref fl (lab-good "skill-g" (cell PLACE 0))) 0))))
  (check "the remaining four hours fall in band one: 2 h worked there"
         (and fl (near? -2.0 (or (assoc-ref fl (lab-good "skill-g" (cell PLACE 1))) 0))))
  (check "nothing is worked in a band the run does not cover"
         (and fl (not (assoc-ref fl (lab-good "skill-g" (cell PLACE 2)))))))

(format #t "~%── §5 a chain THROUGH A HAUL can no longer compress into one band ──~%")
;; grow (6 h) at the farm, haul to town, bake (2 h) in town — 8+ h of dependent
;; work that used to claim a single six-hour band because the arc reset the
;; lead (§3.4's hole). The lead now travels with the cargo: origin's own lead
;; plus the trip.
(define (pick id spec q proc) (make-recipe-flow #:id id #:action 'pickup #:resource-conforms-to spec
                                                #:resource-quantity (make-measure q "kg")
                                                #:recipe-input-of proc))
(define (dropf id spec q proc) (make-recipe-flow #:id id #:action 'dropoff
                                                 #:resource-conforms-to spec
                                                 #:resource-quantity (make-measure q "kg")
                                                 #:recipe-output-of proc #:is-primary #t))
(declare-world! #:places (list (list "farm" 52.45 13.30) (list "town" 52.50 13.40))
                #:clock '("2026-03-03" 8 6.0)
                #:templates
                  (compile-recipe
                    (list (rp* "grow" "Grow" 6) (rp* "haulg" "Haul" #f) (rp* "bake" "Bake" 2))
                    (list (consume* "gl" "land" 1.0 "grow") (out* "go" "grain" 20.0 "grow")
                          (pick "hi" "grain" 1.0 "haulg") (dropf "ho" "grain" 1.0 "haulg")
                          (consume* "bi" "grain" 2.0 "bake") (out* "bo" "bread" 3.0 "bake")))
                #:storable '("grain" "bread"))
(hash-set! *cap* (lg "land" (cell "farm" 0)) 100.0)
(let ((keys (col-keys)))
  (check "grow fills its six-hour band at the farm" (member "p|grow|farm@0" keys))
  (check "grow + trip + 2 h bake exceeds the band: no same-band bake in town"
         (not (member "p|bake|town@0" keys)))
  (check "the bake lands in the NEXT band, fed by stored deliveries"
         (member "p|bake|town@1" keys)))
;; …and STOCK at the origin resets the chain: only the trip + the bake remain
(hash-set! *init* (lg "grain" (cell "farm" 0)) 50.0)
(let ((keys (col-keys)))
  (check "with grain stocked at the farm, trip + bake fits and the band-0 bake returns"
         (member "p|bake|town@0" keys)))

(format #t "~%── §6 containment: a HOLD carries the chain through TIME, never through space ──~%")
;; grain persisted by a HOLD recipe (pickup/dropoff through a keep-in-place
;; silo) — deliberately NOT in *storable*: the good persists via the recipe,
;; paying the silo's service. The chain must reset at later bands exactly as a
;; storable does, and the hold must never read as a route between places.

(declare-world! #:places (list "shop")
                #:clock '("2026-03-03" 8 6.0)
                #:templates
                  (compile-recipe
                    (list (rp* "grow" "Grow" 6) (rp* "hold" "Silo hold" #f) (rp* "bake" "Bake" 2))
                    (list (consume* "gl" "land" 1.0 "grow") (out* "go" "grain" 20.0 "grow")
                          (pick "si" "grain" 1.0 "hold") (dropf "so" "grain" 1.0 "hold")
                          (use* "sb" "silo" "hold" 0.02)
                          (consume* "bi" "grain" 2.0 "bake") (out* "bo" "bread" 3.0 "bake")))
                #:storable '()   ; grain is NOT declared storable
                #:stationary '("silo"))   ; the silo keeps things in place
(hash-set! *cap* (lg "land" (cell "shop" 0)) 100.0)
(hash-set! *cap* (lg (svc-good "silo") (cell "shop" 0)) 24.0)
(let ((keys (col-keys)))
  (check "grow (6 h) + bake (2 h) still cannot share band zero"
         (not (member "p|bake|shop@0" keys)))
  (check "the silo-held grain resets the chain: the bake runs in band ONE"
         (member "p|bake|shop@1" keys))
  (check "the hold tiles the TIME arc, not a road"
         (member "p|hold|shop@0|shop@1" keys)))

(format #t "~%~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
