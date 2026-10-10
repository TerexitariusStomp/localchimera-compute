;;; test-floor-wall-live.scm — the floor-vs-wall dilemma, priced unasked on a LIVE scope.
;;;
;;; test-floor-wall-dilemma proves plan-dilemma at the records level. This is the
;;; live seam: a real plan-scope->alist solve whose only food crosses the only
;;; ecological limit — a subsistence floor (people eat) against a fragility on the
;;; reef the food is fished from, tip below what feeding costs. The program has no
;;; answer, and the plan carries `floor-wall-dilemma` beside its INFEASIBLE verdict:
;;; hold the floor past the tip, or hold the wall short of bare need — priced on the
;;; scope's own world, the limit given the way a live scope gives it (a (spec .
;;; profile) pair through #:eco-spec-frag), each horn with its own `feasible`.
;;;
;;;   W1  the two cannot hold together — the plan is INFEASIBLE and says so
;;;   W2  …and carries the dilemma: horn A holds the floor (a real plan) and reports
;;;       the overshoot past the tip; horn B holds the wall and reports the shortfall
;;;   W3  with reef enough for both, no dilemma rides along
;;; Pure solver (no ACDCs) ⇒ no blake3.
;;; Run: guile -L module tests/scope/test-floor-wall-live.scm

(use-modules (playnet test harness) (playnet test scope)
             (playnet vf schemas) (playnet scope live)
             (goblins) (goblins vat) (srfi srfi-1))

(define win (all-week-window "00:00" "23:00"))
;; 1 reef unit + 0.1 h → 10 kcal-food; a 300 floor costs 30 reef
(define procs (list (rp* "fish" "Fish")))
(define flows (list (out* "f1" "food" 10.0 "fish") (consume* "f2" "reef" 1.0 "fish")
                    (wk* "f3" "fishing" 0.1 "fish")))
(define recipes (list (make-recipe #:id "fish-r" #:name "Fish" #:primary-output "food"
                                   #:recipe-processes '() #:recipe-exchanges '())))
(define chain `(("fish-r" ,(car procs))))
(define resources (list (er "r-sk" "fishing" "ada")))
(define agents (list (make-agent #:id "ada" #:type 'person #:name "Ada" #:primary-location "town"
                                 #:classified-as '() #:availability-window win)))
(define spatials (list (make-spatial-thing #:id "town" #:lat 0.0 #:long 0.0)))

(define vat (spawn-vat #:name "floor-wall-live"))
(define (solve reef-tip)
  (with-vat vat
    (plan-scope->alist (mock-scope #:resources resources #:agents agents #:spatials spatials
                                   #:recipes recipes #:flows flows #:chain chain)
                       #:demand '() #:backend 'native-c #:allow-infeasible? #t
                       #:repro-floors '(("food#town@0" . 300.0))
                       #:eco-spec-frag `(("reef" . (,reef-tip ,reef-tip 0.0 50.0)))   ; alpha 0 ⇒ tip = lo
                       #:raws '("reef"))))

(define tight (solve 20.0))       ; 20 reef of headroom, feeding costs 30
(define ample (solve 100.0))
(define d (assq-ref tight 'floor-wall-dilemma))

(format #t "~%── the only food crosses the only wall, live ──~%")
(format #t "  tight: feasible ~a  dilemma? ~a~%" (assq-ref tight 'feasible) (and d #t))
(when d
  (format #t "  HORN A hold the floor: feasible ~a  overshoot ~a~%"
          (assq-ref (assq-ref d 'horn-a) 'feasible) (assq-ref (assq-ref d 'horn-a) 'overshoot))
  (format #t "  HORN B hold the wall:  feasible ~a  shortfall ~a~%"
          (assq-ref (assq-ref d 'horn-b) 'feasible) (assq-ref (assq-ref d 'horn-b) 'shortfall)))

(check-pred "W1 the two cannot hold together — INFEASIBLE, said out loud"
            (eq? (assq-ref tight 'feasible) #f))
(check-pred "W2 the plan carries the dilemma with two priced horns"
            (and d (eq? #f (assq-ref d 'feasible-together?))
                 (assq-ref d 'horn-a) (assq-ref d 'horn-b)))
(check-pred "W2' horn A holds the floor (a real plan) and overshoots the tip by ≈ 10 reef"
            (and (eq? #t (assq-ref (assq-ref d 'horn-a) 'feasible))
                 (let ((o (assoc-ref (assq-ref (assq-ref d 'horn-a) 'overshoot) "reef")))
                   (and o (> o 5.0)))))
(check-pred "W2'' horn B holds the wall (a real plan) and leaves the household short by ≈ 100"
            (and (eq? #t (assq-ref (assq-ref d 'horn-b) 'feasible))
                 (let ((sf (assoc-ref (assq-ref (assq-ref d 'horn-b) 'shortfall) "food#town@0")))
                   (and sf (> sf 50.0)))))
(check-pred "W3 with reef enough for both, no dilemma rides along"
            (and (eq? (assq-ref ample 'feasible) #t) (not (assq-ref ample 'floor-wall-dilemma))))
(test-summary!)
