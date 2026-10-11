;;; test-bearing.scm — a mover renders what it bears, where it stands.
;;;
;;; A means is in the plan as the capacity it renders at the place it stands. A
;;; means that TRAVELS is a mover (engine.scm means->movers!): by its own word
;;; ("mobile"), or because a mode of the scope names it as its mover — a toolbox
;;; carried by somebody's errand. And a mover bears what stands in it: the saw
;;; in the toolbox, stating no place of its own, saws where the toolbox stands,
;;; out of its own hours. The books say the same of a container that moved
;;; (observer relocate-contents); this is the plan saying it before the move.
;;;
;;; Two places ~4.5 km apart. The toolbox rests north with a carrier beside it;
;;; the sawyer and the wood are south.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/solve/test-bearing.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet knowledge dsl shorthand)
             ((playnet knowledge recipes transport) #:select (mode-recipe))
             (playnet solve engine) (playnet solve plan)
             (playnet vf schemas))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define spatials (list (place* "north" #:lat 52.50 #:lon 13.40)
                       (place* "south" #:lat 52.46 #:lon 13.40)))
(define day (all-week-window "08:00" "16:00"))   ; 8 h
(define agents (list (person* "carrier" #:place "north" #:window day)
                     (person* "sawyer"  #:place "south" #:window day)))

;; a plank is an hour of the saw and an hour of the sawyer; a jig is an hour at
;; the toolbox's own bench and an hour of the sawyer
(define procs (list (rp* "cut" "Cut a plank") (rp* "jig" "Build a jig")))
(define flows
  (list (out* "c1" "plank" 1.0 "cut" %count-unit) (use* "c2" "saw" "cut" 1.0 #:qty 1.0) (wk* "c3" "sawing" 1.0 "cut")
        (out* "j1" "jig" 1.0 "jig" %count-unit) (use* "j2" "toolbox" "jig" 1.0 #:qty 1.0) (wk* "j3" "sawing" 1.0 "jig")))
;; the toolbox travels in somebody's hands: a mode whose mover is the toolbox
(define carry (mode-recipe "carry the toolbox" #:good "toolbox" #:skill "carried" #:pace 0.2
                           #:work '("errand" . 0.2)))

(define (thing id spec place in)
  (make-economic-resource #:id id #:conforms-to spec #:classified-as '()
    #:accounting-quantity (make-measure 1.0 %count-unit) #:onhand-quantity (make-measure 1.0 %count-unit) #:current-location place #:contained-in in))
(define skills (list (er "sk-c" "errand" "carrier" #:place "north" #:qty 1.0 #:unit %effort-unit)
                     (er "sk-s" "sawing" "sawyer" #:place "south" #:qty 1.0 #:unit %effort-unit)))

(define* (plan things demand #:key (carried? #t))
  (call-with-values
      (lambda ()
        (plan-from-records (append things skills) agents spatials
                           (if carried? (cons (car carry) procs) procs)
                           (if carried? (append (cadr carry) flows) flows)
                           #:demand demand #:backend 'native-c))
    (lambda (ints coms material fill cols x idx ntot report)
      (list report x idx material))))
(define (ran r proc place) (col-value (cadr r) (caddr r) (format #f "p|~a|~a@0" proc place)))
(define (placement r id) (assoc-ref (or (assq-ref (car r) 'placement) '()) id))
(define (rows r action) (filter (lambda (m) (eq? action (commitment-action m))) (cadddr r)))

(define WANT '(("plank#south@0" . 3.0)))
(define boxed (list (thing "toolbox-1" "toolbox" "north" #f) (thing "saw-1" "saw" #f "toolbox-1")))

(format #t "~%── 1. the saw in a carried toolbox saws where the toolbox stands ──~%~%")
(define r1 (plan boxed WANT))
(format #t "    planks south ~,3f; toolbox ~a~%" (ran r1 "cut" "south") (placement r1 "toolbox-1"))
(check "the planks are cut at the far place" (> (ran r1 "cut" "south") 2.9))
(check "the toolbox stands there, whole"
       (let ((p (assoc-ref (placement r1 "toolbox-1") "south@0"))) (and p (< (abs (- p 1.0)) 1e-3))))
(check "the plan carries the toolbox — the one thing picked up, the one dropped off"
       (and (equal? (map commitment-resource-conforms-to (rows r1 'pickup)) '("toolbox"))
            (equal? (map commitment-resource-conforms-to (rows r1 'dropoff)) '("toolbox"))))

(format #t "~%── 2. at any depth: the saw in its case in the toolbox ──~%~%")
(define r2 (plan (list (thing "toolbox-1" "toolbox" "north" #f)
                       (thing "case-1" "saw-case" #f "toolbox-1")
                       (thing "saw-1" "saw" #f "case-1"))
                 WANT))
(check "the planks are cut at the far place" (> (ran r2 "cut" "south") 2.9))

(format #t "~%── 3. what states its own place keeps it ──~%~%")
;; the saw is logged in the toolbox and hangs on the north wall
(define r3 (plan (list (thing "toolbox-1" "toolbox" "north" #f) (thing "saw-1" "saw" "north" "toolbox-1")) WANT))
(check "a saw with a place of its own stays there: nothing is cut south" (< (ran r3 "cut" "south") 0.1))

(format #t "~%── 4. a container nobody carries leaves its contents where they are ──~%~%")
(define r4 (plan boxed WANT #:carried? #f))
(check "no mode for the toolbox: nothing is cut south" (< (ran r4 "cut" "south") 0.1))
(check "…and nothing is placed: there is no mover" (not (placement r4 "toolbox-1")))

(format #t "~%── 5. what a mover bears works its own hours ──~%~%")
;; six hours at the saw and six at the toolbox's bench, in one eight-hour day:
;; twelve hours of two means, each within its own eight. Two sawyers do it.
(define r5
  (call-with-values
      (lambda ()
        (plan-from-records (append boxed skills
                                   (list (er "sk-s2" "sawing" "sawyer-2" #:place "south" #:qty 1.0 #:unit %effort-unit)))
                           (cons (person* "sawyer-2" #:place "south" #:window day) agents) spatials
                           (cons (car carry) procs) (append (cadr carry) flows)
                           #:demand '(("plank#south@0" . 6.0) ("jig#south@0" . 6.0)) #:backend 'native-c))
    (lambda (ints coms material fill cols x idx ntot report) (list report x idx material))))
(format #t "    planks ~,3f, jigs ~,3f~%" (ran r5 "cut" "south") (ran r5 "jig" "south"))
(check "the saw's six hours and the bench's six are both worked"
       (and (> (ran r5 "cut" "south") 5.8) (> (ran r5 "jig" "south") 5.8)))

(format #t "~%~a passed, ~a failed~%" *pass* *fail*)
(exit (if (= *fail* 0) 0 1))
