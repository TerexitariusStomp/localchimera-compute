;;; test-inspection-live.scm — inspection SCHEDULED in a live scope's plan, and
;;; the recert schedule read off both kinds of edge.
;;;
;;; docs/legal/inspection-in-plan.md proved the mechanism in tests (slices 1–2:
;;; a Verif| freshness stock worn by reliance, restored by an inspect recipe costing
;;; a verifier's hours) and closed the credential loop for SKILLS off a live plan
;;; (test-conformance-recert-live). This is the live seam for the rest:
;;;
;;;   plan-scope #:inspect  every conformance edge the scope's recipes lean on
;;;                         (skills by `work`, means by `use`) becomes a Verif|
;;;                         stock the plan must keep — so the verifier's hours are
;;;                         SCHEDULED in the solve, on the one budget, sited and
;;;                         qualified (solve/inspection.scm scope-inspection);
;;;   conformance-recert    now folds means too: a durable's Svc| draw is its load
;;;                         (solve/inspection.scm commitment-loads).
;;;
;;;   S1  #:inspect #t: the auditor's hours appear as `work` on inspect~<edge> procs
;;;   S2  reliance is endogenous: the heavily-leaned edge draws more inspection
;;;   S3  #:inspect #f: the same scope, the plan it had — no inspect work at all
;;;   S4  no auditor in the crew: the credential AS IT STANDS (fresh runs on hand) is
;;;       spent, and then production stops — nothing unverified is relied on
;;;   S5  conformance-recert names the MEANS edge (the oven) beside the skills
;;; Pure solver (no ACDCs) ⇒ no blake3.
;;; Run: guile -L module tests/planner/test-inspection-live.scm

(use-modules (playnet test harness) (playnet test scope)
             (playnet planner vf schemas) (srfi srfi-1)
             (playnet planner scope live)
             (goblins) (goblins vat) (srfi srfi-1))

;; A period here is a WEEK: the roster's window is read over its seven days, so
;; `weekday-window` is a working week of the auditor's hours, on any date.
(use-modules ((playnet planner solve engine) #:select (set-period-length!)))
(set-period-length! 1.0 "week")
(define win (weekday-window))

;; bake leans hard on `baker` and on the oven; tend leans lightly on `gardener`
(define procs (list (rp* "bake" "Bake") (rp* "tend" "Tend")))
(define flows (list (out* "o1" "bread"  1.0 "bake") (wk* "w1" "baker"    1.0 "bake") (use* "u1" "oven" "bake")
                    (out* "o2" "tended" 1.0 "tend") (wk* "w2" "gardener" 0.2 "tend")))
(define recipes (list (make-recipe #:id "bake-r" #:name "Bake" #:primary-output "bread" 
                                   #:recipe-processes '() #:recipe-exchanges '())
                      (make-recipe #:id "tend-r" #:name "Tend" #:primary-output "tended"
                                   #:recipe-processes '() #:recipe-exchanges '())))
(define chain `(("bake-r" ,(list-ref procs 0)) ("tend-r" ,(list-ref procs 1))))
(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))

(define oven (holding "r-oven" "oven" "commune" #:qty 20.0))    ; the oven the commune holds — bake `use`s it
(define (crew . who)                                   ; ((id skill) …) → resources + agents
  (values (cons oven (map (lambda (w) (er (string-append "r-" (car w)) (cadr w) (car w))) who))
          (map (lambda (w) (make-agent #:id (car w) #:type 'person #:primary-location "town"
                                       #:classified-as '() #:availability-window win)) who)))

(define vat (spawn-vat #:name "inspection-live"))
(define (solve crew-spec . opts)
  (call-with-values (lambda () (apply crew crew-spec))
    (lambda (resources agents)
      (with-vat vat
        (let ((scope (mock-scope #:resources resources #:agents agents #:spatials spatials
                             #:recipes recipes #:flows flows #:chain chain)))
          (apply plan-scope->alist scope
                 #:demand '(("bread#town@0" . 6.0) ("tended#town@0" . 2.0))
                 ;; inspection is the subject; the town's table is not — bread
                 ;; alone feeds no body under its energy ceiling
                 #:reproduce? #f
                 #:backend 'native-c opts))))))

(define full '(("bkr" "baker") ("grd" "gardener") ("aud" "auditor")))
(define (inspect-hours plan edge)                      ; auditor hours scheduled on inspect~<edge>
  (fold (lambda (w a) (if (equal? (assq-ref w 'input-of) (string-append "inspect~" edge))
                          (+ a (assq-ref w 'effort)) a))
        0.0 (assq-ref plan 'work)))
(define (bread-of plan)
  (fold (lambda (m a) (if (and (eq? (assq-ref m 'action) 'produce) (equal? (assq-ref m 'conforms-to) "bread"))
                          (+ a (assq-ref m 'quantity)) a))
        0.0 (assq-ref plan 'material)))
(define (any-inspect? plan)
  (any (lambda (w) (string-prefix? "inspect~" (or (assq-ref w 'input-of) ""))) (assq-ref plan 'work)))

(define off (solve full))
(define on  (solve full #:inspect #t))
(define no-auditor (solve '(("bkr" "baker") ("grd" "gardener")) #:inspect '((fresh . 2.0))))   ; 2 runs of freshness on hand, nobody to renew it

(display "\n── inspection scheduled in a live plan ──\n")
(format #t "  inspect #f: met ~,2f, inspect work? ~a\n" (assq-ref off 'met) (any-inspect? off))
(format #t "  inspect #t: met ~,2f, auditor hours on baker ~,2f · oven ~,2f · gardener ~,2f\n"
        (assq-ref on 'met) (inspect-hours on "baker") (inspect-hours on "oven") (inspect-hours on "gardener"))
(format #t "  no auditor, 2 runs of freshness on hand: bread ~,2f of 6 wanted\n" (bread-of no-auditor))
(format #t "  recert (on):  ~a\n" (assq-ref on 'conformance-recert))

(check-pred "S1 the auditor's hours are scheduled as work on the inspect~<edge> processes"
            (and (> (assq-ref on 'met) 0.9) (> (inspect-hours on "baker") 0.0) (> (inspect-hours on "gardener") 0.0)))
(check-pred "S2 reliance is endogenous: the heavily-leaned edge draws more inspection than the light one"
            (> (inspect-hours on "baker") (inspect-hours on "gardener")))
(check-pred "S2' the means edge (the oven bake uses) is inspected too"
            (> (inspect-hours on "oven") 0.0))
(check-pred "S3 inspect #f: no inspect work, the plan the scope had"
            (and (not (any-inspect? off)) (> (assq-ref off 'met) 0.9)))
(check-pred "S4 no auditor: the standing freshness (2 runs) is spent on 2 breads, then production stops"
            (< (abs (- (bread-of no-auditor) 2.0)) 0.05))
(check-pred "S5 conformance-recert names the means edge beside the skills"
            (and (assoc "oven" (assq-ref on 'conformance-recert))
                 (assoc "baker" (assq-ref on 'conformance-recert))))
(test-summary!)
