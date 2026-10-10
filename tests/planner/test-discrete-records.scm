;;; test-discrete-records.scm — the discrete layer, reached through the records.
;;;
;;; §7 (planner.scm) searches minimum-batch and whole-count columns with a
;;; branch-and-bound whose pruning the convex certificate licenses. This proves
;;; the two doors a RECIPE states them through, and that a plan made from
;;; records honours what it read:
;;;
;;;   · minimumBatchQuantity (a <measure> on the RecipeProcess) compiles into
;;;     the template as a floor in RUNS, read against the recipe's own outputs
;;;   · processClassifiedAs "whole-count" compiles into the template as whole
;;;   · plan-from-records opens the search when either is present, commits
;;;     whole counts, and says so in the certificate's `discrete` block
;;;   · with neither declared, the plan is the relaxation to the digit and no
;;;     search is opened — the degenerate case is free
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-discrete-records.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet knowledge dsl shorthand))
(use-modules ((playnet knowledge recipes transport) #:select (mode-recipe)))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet vf schemas) (playnet vf beyond scenario))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b tol) (< (abs (- a b)) tol))
(define (whole? v) (< (abs (- v (round v))) 1e-4))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. What a recipe states, the template carries — in RUNS
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 1. a minimum batch, read against the recipe's outputs ──~%~%")

;; a recipe process with a stated minimum batch and an optional classification
(define (rp/batch id name mbq tags)
  (make-recipe-process #:id id #:name name #:process-classified-as tags #:minimum-batch-quantity mbq))
(define (tpl-of id procs flows) (find (lambda (t) (equal? id (proc-id t))) (compile-recipe procs flows)))

;; 20 loaves a run, batch stated as 80 loaves ⇒ 4 runs
(clear-batch-unit-gaps!)
(define t-loaves
  (tpl-of "mill" (list (rp/batch "mill" "Mill" (make-measure 80.0 "loaf") '()))
          (list (out/u "o" "bread" 20.0 "loaf" "mill") (wrk "w" 1.0 "mill"))))
(check "stated in the output's unit, the floor is that quantity over the per-run output (80 loaves / 20 a run = 4 runs)"
       (and (proc-batch t-loaves) (near? (proc-batch t-loaves) 4.0 1e-9)))
(check "…and no unit gap is recorded" (null? (batch-unit-gaps)))

;; the same, with the unit spelt convertibly: 2 kg a run, batch 4000 g ⇒ 2 runs
(define t-grams
  (tpl-of "mill" (list (rp/batch "mill" "Mill" (make-measure 4000.0 "g") '()))
          (list (out "o" "flour" 2.0 "mill") (wrk "w" 1.0 "mill"))))
(check "a convertible spelling of the same substance converts (4000 g over 2 kg a run = 2 runs)"
       (and (proc-batch t-grams) (near? (proc-batch t-grams) 2.0 1e-9)))

;; no unit ⇒ counts runs directly
(define t-runs
  (tpl-of "mill" (list (rp/batch "mill" "Mill" (make-measure 3.0 #f) '()))
          (list (out "o" "flour" 2.0 "mill") (wrk "w" 1.0 "mill"))))
(check "stated in no unit, it counts runs" (and (proc-batch t-runs) (near? (proc-batch t-runs) 3.0 1e-9)))

;; a unit none of the outputs is measured in ⇒ read as runs, RECORDED
(clear-batch-unit-gaps!)
(define t-gap
  (tpl-of "mill" (list (rp/batch "mill" "Mill" (make-measure 80.0 "kg") '()))
          (list (out/u "o" "bread" 20.0 "loaf" "mill") (wrk "w" 1.0 "mill"))))
(check "a unit matching no output is read as runs…" (and (proc-batch t-gap) (near? (proc-batch t-gap) 80.0 1e-9)))
(check "…and lands in the batch-unit register, a gap one can query"
       (and (= 1 (length (batch-unit-gaps)))
            (equal? "mill" (car (car (batch-unit-gaps))))
            (equal? "kg" (cadr (car (batch-unit-gaps))))))
(clear-batch-unit-gaps!)

;; a fractional floor is a floor: 80 loaves over 30 a run
(define t-frac
  (tpl-of "mill" (list (rp/batch "mill" "Mill" (make-measure 80.0 "loaf") '()))
          (list (out/u "o" "bread" 30.0 "loaf" "mill") (wrk "w" 1.0 "mill"))))
(check "a fractional floor stays fractional (80/30 runs) — the search splits there, nothing rounds"
       (near? (proc-batch t-frac) (/ 80.0 30.0) 1e-9))

(check "no minimum batch stated ⇒ divisible"
       (not (proc-batch (tpl-of "mill" (list (rp "mill" "Mill")) (list (out "o" "flour" 2.0 "mill"))))))

(format #t "~%── 2. a whole count, classified ──~%~%")

(define t-whole
  (tpl-of "operate" (list (rp/batch "operate" "Operate" #f '("surgery" "whole-count")))
          (list (out "o" "repair" 1.0 "operate") (wrk "w" 1.0 "operate"))))
(check "processClassifiedAs \"whole-count\" compiles as whole" (eq? #t (proc-whole? t-whole)))
(check "…other tags do not"
       (not (proc-whole? (tpl-of "operate" (list (rp/batch "operate" "Operate" #f '("surgery")))
                                 (list (out "o" "repair" 1.0 "operate"))))))
(check "…and an untagged process is a rate"
       (not (proc-whole? (tpl-of "operate" (list (rp "operate" "Operate")) (list (out "o" "repair" 1.0 "operate"))))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Through plan-from-records: the theatre from whole-counts-test, as records
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 3. a plan from records honours the recipe ──~%~%")

(define win (all-week-window))
(define agents (list (person* "ada" #:name "Ada" #:place "clinic" #:window win)))
(define spatials (list (place* "clinic")))
(define resources (list (er "sk-ada" "surgery" "ada" #:place "clinic" #:qty 1.0 #:unit "kg")))
(define (theatre-procs whole?)
  (list (rp* "operate" "Operate" #:tags (if whole? '("whole-count") '()))))
(define flows (list (out* "f1" "repair" 1.0 "operate" %count-unit)
                    (wk* "f2" "surgery" 1.0 "operate")))
(define demand (list (cons "repair#clinic@0" 2.5)))     ; the relaxation wants two and a half operations

(define (operations-of material)                        ; the produce commitment for `repair`
  (fold (lambda (c a) (if (and (eq? (commitment-action c) 'produce)
                               (equal? "repair" (commitment-resource-conforms-to c)))
                          (+ a (measure-has-numerical-value (commitment-resource-quantity c))) a))
        0.0 material))
(define* (plan whole? #:key (decided #f) (node-budget #f))
  (call-with-values
      (lambda () (plan-from-records resources agents spatials (theatre-procs whole?) flows
                                    #:demand demand #:backend 'native-c #:decided decided #:node-budget node-budget))
    (lambda (ints coms material fill cols x idx ntot report)
      (list (operations-of material) (assq-ref report 'certificate) coms (assq-ref report 'decided)))))

(set! *emp-rho* 0.0001)
(define relaxed (plan #f))
(define whole   (plan #t))
(format #t "    relaxed operations ~,3f   whole operations ~,3f~%" (car relaxed) (car whole))
(format #t "    discrete block: ~a~%~%" (assq-ref (cadr whole) 'discrete))

(check "undeclared, the relaxation commits a fractional number of operations"
       (and (> (car relaxed) 2.0) (< (car relaxed) 3.0) (not (whole? (car relaxed)))))
(check "…and its certificate carries no discrete block — nothing was searched"
       (not (assq 'discrete (cadr relaxed))))
(check "declared whole-count on the recipe, the plan commits a whole number of operations"
       (whole? (car whole)))
(check "…two or three, the two integers around the relaxation"
       (or (near? (car whole) 2.0 1e-4) (near? (car whole) 3.0 1e-4)))
(let ((d (assq-ref (cadr whole) 'discrete)))
  (check "…and the certificate says what the search did"
         (and d (assq 'nodes d) (assq 'certified? d) (assq 'gap d) (assq 'keys d)))
  (check "…exhausting the tree: certified, gap 0"
         (and d (eq? #t (assq-ref d 'certified?)) (near? (assq-ref d 'gap) 0.0 1e-12)))
  (check "…over more than one node — a whole count opens a tree with no batch key"
         (and d (= 0 (assq-ref d 'keys)) (> (assq-ref d 'nodes) 1))))
(check "the convex certificate still rides underneath — feasible"
       (eq? #t (assq-ref (cadr whole) 'feasible?)))
;; the labour balance is an INEQUALITY (supply ≥ need, held off the wall by the
;; barrier), so the work commitment covers the whole count rather than equalling
;; it; the material commitment is where the count is exact
(check "the work commitments cover the whole count of surgeon-hours"
       (let ((h (fold (lambda (c a) (if (eq? (commitment-action c) 'work)
                                        (+ a (measure-has-numerical-value (commitment-effort-quantity c))) a))
                      0.0 (caddr whole))))
         (and (>= h (- (car whole) 1e-3)) (< h (+ (car whole) 0.5)))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. A minimum batch through the records: run at ≥ L or not at all
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 4. a minimum batch from the records ──~%~%")

;; two mills for one flour demand: a hand mill (dear) and a big mill that only
;; runs at ≥ 4 runs (80 kg over 20 a run). Demand 30 kg: the relaxation would
;; run 1.5 runs of the big mill; the search must choose 0 or ≥ 4.
(define mill-agents (list (person* "bo" #:name "Bo" #:window win)))
(define mill-spatials (list (place* "town")))
(define mill-resources (list (er "sk-bo" "milling" "bo" #:qty 1.0 #:unit "kg")))
(define mill-procs (list (rp* "hand" "Hand mill" #:tags '())
                         (rp* "big"  "Big mill"  #:tags '() #:mbq 80.0)))
(define mill-flows (list (out* "h1" "flour" 1.0 "hand")
                         (wk* "h2" "milling" 1.0 "hand")
                         (out* "b1" "flour" 20.0 "big")
                         (wk* "b2" "milling" 2.0 "big")))
(define (mill-plan demand)
  (call-with-values
      (lambda () (plan-from-records mill-resources mill-agents mill-spatials mill-procs mill-flows
                                    #:demand (list (cons "flour#town@0" demand)) #:backend 'native-c))
    (lambda (ints coms material fill cols x idx ntot report)
      (list (col-value x idx "p|big|town@0") (col-value x idx "p|hand|town@0")
            (assq-ref report 'certificate)))))
(define m30 (mill-plan 30.0))
(format #t "    demand 30 kg: big mill ~,3f runs, hand mill ~,3f runs~%" (car m30) (cadr m30))
(format #t "    discrete block: ~a~%~%" (assq-ref (caddr m30) 'discrete))
(check "the recipe's minimumBatchQuantity reached the engine (one batch key)"
       (let ((d (assq-ref (caddr m30) 'discrete))) (and d (= 1 (assq-ref d 'keys)))))
(check "the big mill runs at ≥ 4 runs or not at all — never at the relaxation's 1.5"
       (or (< (car m30) 1e-3) (>= (car m30) (- 4.0 1e-3))))
(check "…and the search certified its choice"
       (eq? #t (assq-ref (assq-ref (caddr m30) 'discrete) 'certified?)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 4b. The plan IS the certified config, and the floor's face is a fact
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 4b. the batch runs where its certificate says it runs ──~%~%")

;; ONE mill, no alternative: demand past the relaxation's split, so the ON
;; config is the certified optimum — and the solve that follows must build
;; THAT config's program, whichever leaf the search happened to price last.
(define (solo-plan mbq-kg per-run-kg demand seed-kg)
  (let ((procs (list (rp* "big" "Big mill" #:tags '() #:mbq mbq-kg)))
        (flows (list (out* "b1" "flour" per-run-kg "big")
                     (consume* "b2" "seed" 10.0 "big")
                     (wk* "b3" "milling" 2.0 "big")))
        (res (list (er "sk-bo" "milling" "bo" #:qty 1.0 #:unit "kg")
                   (er "st-seed" "seed" "bo" #:qty seed-kg #:unit "kg"))))
    (call-with-values
        (lambda () (plan-from-records res mill-agents mill-spatials procs flows
                                      #:demand (list (cons "flour#town@0" demand)) #:backend 'native-c))
      (lambda (ints coms material fill cols x idx ntot report)
        (list (col-value x idx "p|big|town@0") fill
              (assq-ref (assq-ref report 'certificate) 'discrete))))))
;; seed plentiful: the ON child keeps its interior, and the handed-back plan
;; carries the certified config's runs
(define solo (solo-plan 80.0 20.0 48.0 1e6))
(format #t "    plentiful seed: ~,3f runs, fill ~,3f~%" (car solo) (cadr solo))
(check "the certified ON config is the plan handed back — the batch RUNS"
       (>= (car solo) (- 4.0 1e-3)))
(check "…and the demand is served whole" (> (cadr solo) 0.999))
;; seed of exactly the floor's draw: the ON floor meets the stock wall, and
;; x = L is a FACT a fixing substitutes out — never a cut a barrier holds
(define solo-face (solo-plan 80.0 20.0 48.0 40.0))
(format #t "    seed = the floor's draw: ~,3f runs~%" (car solo-face))
(check "a stock of exactly the floor's draw is served AT the floor"
       (< (abs (- (car solo-face) 4.0)) 1e-3))
(check "…certified, at a finite cost"
       (let ((d (caddr solo-face)))
         (and (eq? #t (assq-ref d 'certified?)) (< (assq-ref d 'cost) 1e6))))
;; a fractional floor's face is the same fact: 80 kg over 30 a run = 8/3 runs
(define solo-frac (solo-plan 80.0 30.0 48.0 (* 10.0 (/ 80.0 30.0))))
(format #t "    fractional L = 8/3: ~,3f runs~%" (car solo-frac))
(check "a FRACTIONAL floor's face serves at exactly L"
       (< (abs (- (car solo-frac) (/ 80.0 30.0))) 1e-3))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Nothing declared, nothing changed
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 5. warm decisions: the standing plan seeds the next search ──~%~%")

;; the theatre again, handing back what the first search decided — as a live
;; re-solve does through #:decided beside #:warm-x
(define d1 (cadddr whole))
(check "a searched plan reports its decided state (config, cuts, fixings)"
       (and d1 (assq 'config d1) (assq 'cuts d1) (assq 'fixed d1)
            (pair? (assq-ref d1 'fixed))))
(check "…and an unsearched plan reports none" (not (cadddr relaxed)))
(define whole2 (plan #t #:decided d1))
(let ((n1 (assq-ref (assq-ref (cadr whole) 'discrete) 'nodes))
      (n2 (assq-ref (assq-ref (cadr whole2) 'discrete) 'nodes)))
  (format #t "    cold search ~a node(s); seeded with its decision ~a node(s)~%~%" n1 n2)
  (check "seeded, the search reaches the same whole plan" (near? (car whole2) (car whole) 1e-6))
  (check "…still certified" (eq? #t (assq-ref (assq-ref (cadr whole2) 'discrete) 'certified?)))
  (check "…in no more nodes than the cold search — the incumbent prunes from the root" (<= n2 n1)))
(check "a seed naming columns this world lacks is harmless"
       (let ((foreign '((config . all) (cuts . (("p|nowhere|x@9" . (2 . 3)))) (fixed . (("p|nowhere|x@9" . 2))))))
         (near? (car (plan #t #:decided foreign)) (car whole) 1e-6)))

(format #t "~%── 5b. the node budget is the scope's to set, and the certificate says when it bound ──~%~%")

;; the same theatre under a budget of one node: the root is solved and the tree
;; stops there — the certificate reports the budget beside the nodes, uncertified,
;; with the gap it left; the default budget stands for every other solve
(define tight (plan #t #:node-budget 1))
(let ((d (assq-ref (cadr tight) 'discrete)) (d0 (assq-ref (cadr whole) 'discrete)))
  (format #t "    budget 1: ~a~%" d)
  (check "a solve carries the budget it ran under" (and (eqv? 1 (assq-ref d 'budget)) (eqv? (*bnb-nodes*) (assq-ref d0 'budget))))
  (check "…and stops at it: one node, uncertified" (and (eqv? 1 (assq-ref d 'nodes)) (not (assq-ref d 'certified?))))
  (check "…leaving a gap it states" (> (assq-ref d 'gap) 0.0))
  (check "the default budget is untouched by a scope's own" (= 400 (*bnb-nodes*))))

(format #t "~%── 6. under uncertainty: integer first stage, continuous recourse ──~%~%")

;; the mills again, in two futures. The big mill's batch is decided BEFORE the
;; weather resolves (first stage, shared by every future); the hand mill is
;; recourse, and it is declared whole — so its whole count stays relaxed, and
;; the certificate names it.
(define mill-procs/robust
  (list (rp* "hand" "Hand mill" #:tags '("whole-count"))
        (rp* "big"  "Big mill"  #:tags '() #:mbq 80.0)))
(define futures
  (list (make-planning-scenario "normal"  "sc-normal"  0.7 '(("big" . 1.0) ("hand" . 1.0)) "normal")
        (make-planning-scenario "drought" "sc-drought" 0.3 '(("big" . 0.6) ("hand" . 0.9)) "drought")))
(define (robust-mill demand)
  (call-with-values
      (lambda () (plan-from-records mill-resources mill-agents mill-spatials mill-procs/robust mill-flows
                                    #:demand (list (cons "flour#town@0" demand)) #:backend 'native-c
                                    #:scenarios futures #:first-stage-procs '("big")))
    (lambda (ints coms material fill cols x idx ntot report)
      (list (assq-ref (assq-ref report 'first-stage-plan) "big")
            (assq-ref report 'certificate)
            (assq-ref report 'decided)
            report))))
(define rm (robust-mill 30.0))
(format #t "    first-stage big mill ~,3f runs~%" (or (car rm) 0.0))
(format #t "    discrete block: ~a~%~%" (and (cadr rm) (assq-ref (cadr rm) 'discrete)))
(check "a robust plan with declared discreteness carries a certificate with a discrete block"
       (and (cadr rm) (assq 'discrete (cadr rm))))
(let ((d (and (cadr rm) (assq-ref (cadr rm) 'discrete))))
  (check "…searching exactly the first-stage batch key (one key, 2 configs)"
         (and d (= 1 (assq-ref d 'keys))))
  (check "…certified" (and d (eq? #t (assq-ref d 'certified?))))
  (check "…and naming the recourse columns it left relaxed — the hand mill's whole count"
         (and d (pair? (assq-ref d 'recourse-relaxed))
              (every (lambda (k) (string-prefix? "p|hand|" k)) (assq-ref d 'recourse-relaxed)))))
(check "the first-stage batch is honoured in every future: 0 or ≥ 4 runs, never the relaxation's between"
       (let ((b (or (car rm) 0.0))) (or (< b 1e-3) (>= b (- 4.0 1e-3)))))
(check "…and the plan reports its decided state for the next solve" (and (caddr rm) (assq 'config (caddr rm))))
(check "the deterministic reading (a robust report without declarations) is unchanged in shape"
       (call-with-values
           (lambda () (plan-from-records mill-resources mill-agents mill-spatials
                                         (list (rp* "hand" "Hand mill" #:tags '())
                                               (rp* "big"  "Big mill"  #:tags '()))
                                         mill-flows
                                         #:demand (list (cons "flour#town@0" 30.0)) #:backend 'native-c
                                         #:scenarios futures #:first-stage-procs '("big")))
         (lambda (ints coms material fill cols x idx ntot report)
           ;; every solve certifies now — the plan-invariants contract reads the
           ;; certificate on every path — so "unchanged" means: robust, and no
           ;; discrete block anywhere, never "no certificate"
           (and (assq-ref report 'robust)
                (let ((c (assq-ref report 'certificate)))
                  (and (list? c) (not (assq 'discrete c))))
                (not (assq 'discrete report))))))

(format #t "~%── 7. the means is a mover: a machine stands in one place ──~%~%")

;; two fields, one tractor. Farmers stand at both fields; only the tractor is
;; scarce, and it TRAVELS: classified "mobile" and "self-propelled", it takes the
;; "drive" mode (needs "self-propelled"; no vehicle, no driver). Its service —
;; Svc|tractor, eight hours a period — follows its presence, and its rides are
;; whole: the plan decides where the machine stands, one field per period.
(define field-spatials (list (place* "north" #:lat 52.50 #:lon 13.40)
                             (place* "south" #:lat 52.46 #:lon 13.40)))   ; ~4.5 km apart
(define farm-win (all-week-window "08:00" "16:00"))   ; 8 h
(define field-agents (list (person* "north-farmer" #:name "N" #:place "north" #:window farm-win)
                           (person* "south-farmer" #:name "S" #:place "south" #:window farm-win)))
(define (tractor tags)
  (make-economic-resource #:id "tractor-7" #:tracking-identifier "tractor" #:conforms-to "tractor" #:classified-as tags
    #:accounting-quantity (make-measure 1.0 %count-unit) #:onhand-quantity (make-measure 1.0 %count-unit) #:current-location "north"))
(define (field-resources tags)
  (list (tractor tags)
        (er "sk-n" "farming" "north-farmer" #:place "north" #:qty 1.0 #:unit "kg")
        (er "sk-s" "farming" "south-farmer" #:place "south" #:qty 1.0 #:unit "kg")))
;; plough one field-unit: one tractor for one hour, one farmer-hour
(define field-procs (list (rp* "plough" "Plough" #:tags '())))
(define field-flows
  (list (out* "p1" "ploughed" 1.0 "plough" %count-unit)
        (use* "p2" "tractor" "plough" 1.0 #:qty 1.0)
        (wk* "p3" "farming" 1.0 "plough")))
(define drive-mode (mode-recipe "drive" #:skill "self-propelled" #:pace 0.1))   ; the mover bears "self-propelled": own power, 0.1 h/km
(define* (field-plan demand tags #:key (periods '(0)) (spans #f) (spatials field-spatials) (agents field-agents))
  (call-with-values
      (lambda () (plan-from-records (field-resources tags) agents spatials (cons (car drive-mode) field-procs) (append (cadr drive-mode) field-flows)
                                    #:demand demand #:periods periods #:period-spans spans #:backend 'native-c))
    (lambda (ints coms material fill cols x idx ntot report)
      (list report fill x idx cols))))
(define (ploughed-at material-report place t)         ; the plough runs at a cell, from the report's plan
  (let* ((x (caddr material-report)) (idx (cadddr material-report)))
    (col-value x idx (format #f "p|plough|~a@~a" place t))))
(define (placement-of r) (assoc-ref (or (assq-ref (car r) 'placement) '()) "tractor-7"))

;; (a) demand at the far field only: the tractor rides there, whole, and serves
(define far (field-plan '(("ploughed#south@0" . 3.0)) '("mobile" "self-propelled")))
(format #t "    far field only: ploughed south ~,3f; placement ~a~%" (ploughed-at far "south" 0) (placement-of far))
(check "a mobile means is a mover — the report places it"
       (pair? (placement-of far)))
(check "…it rides to the field that needs it (presence at south ≈ 1)"
       (let ((p (assoc-ref (placement-of far) "south@0"))) (and p (near? p 1.0 1e-3))))
(check "…and its service is rendered there: the far field is ploughed"
       (> (ploughed-at far "south" 0) 2.9))
(check "the ride is a whole act — the tree ran"
       (let ((d (assq-ref (assq-ref (car far) 'certificate) 'discrete))) (and d (eq? #t (assq-ref d 'certified?)))))

;; (b) demand at BOTH fields in one period: the relaxation would halve the
;; machine; the plan stands it in ONE field, and the other waits
(define both (field-plan '(("ploughed#north@0" . 3.0) ("ploughed#south@0" . 3.0)) '("mobile" "self-propelled")))
(format #t "    both fields, one period: north ~,3f south ~,3f; placement ~a~%"
        (ploughed-at both "north" 0) (ploughed-at both "south" 0) (placement-of both))
(check "one machine, one place: presence is whole in every cell"
       (every (lambda (cp) (whole? (cdr cp))) (placement-of both)))
(check "…so one field is ploughed and the other is not — the indivisibility is respected, not smoothed"
       (let ((n (ploughed-at both "north" 0)) (s (ploughed-at both "south" 0)))
         (and (> (max n s) 2.9) (< (min n s) 0.1))))

;; (c) two periods: it ploughs one field, then rides to the other
(define two (field-plan '(("ploughed#north@0" . 3.0) ("ploughed#south@1" . 3.0)) '("mobile" "self-propelled") #:periods '(0 1)))
(format #t "    two periods: north@0 ~,3f south@1 ~,3f; placement ~a~%"
        (ploughed-at two "north" 0) (ploughed-at two "south" 1) (placement-of two))
(check "over two periods it serves both: north first, then south — a placement through time"
       (and (> (ploughed-at two "north" 0) 2.9) (> (ploughed-at two "south" 1) 2.9)))

;; (d) the same tractor NOT classified mobile serves where it stands, and nothing else moves
(define fixed (field-plan '(("ploughed#south@0" . 3.0)) '()))
(check "an ordinary (immobile) means serves its own cell only — the far field goes unploughed"
       (< (ploughed-at fixed "south" 0) 0.1))
(check "…and no placement, no tree: nothing was declared"
       (and (not (assq 'placement (car fixed))) (not (assq 'discrete (assq-ref (car fixed) 'certificate)))))

(format #t "~%── 7b. a two-hop day: bands finer than a day, hours read band by band ──~%~%")

;; three fields in a line, one day cut into three BANDS (08–11, 11–13, 13–16;
;; the band dial, declared through #:period-spans). The tractor ploughs north in
;; the morning, rides to the middle field for the short midday band, and on to
;; the south field for the afternoon: two hops in one day, each a whole ride
;; decided on the tree, each departure from where the band found the machine.
;; Its hours are the band's own — 3 h, 2 h, 3 h — read through rider-hours, so
;; the midday band can only carry what two hours less the ride allow.
(define row-spatials (list (place* "north" #:lat 52.50 #:lon 13.40)
                           (place* "mid"   #:lat 52.48 #:lon 13.40)
                           (place* "south" #:lat 52.46 #:lon 13.40)))   ; ~2.2 km hops
(define row-agents (cons (person* "mid-farmer" #:name "M" #:place "mid" #:window farm-win) field-agents))
(define (row-resources) (cons (er "sk-m" "farming" "mid-farmer" #:place "mid" #:qty 1.0 #:unit "kg")
                              (field-resources '("mobile" "self-propelled"))))
(define three-bands '(("2026-08-17T08:00" . "2026-08-17T11:00")
                      ("2026-08-17T11:00" . "2026-08-17T13:00")
                      ("2026-08-17T13:00" . "2026-08-17T16:00")))
(define (row-plan demand)
  (call-with-values
      (lambda () (plan-from-records (row-resources) row-agents row-spatials (cons (car drive-mode) field-procs) (append (cadr drive-mode) field-flows)
                                    #:demand demand #:periods '(0 1 2) #:period-spans three-bands #:backend 'native-c))
    (lambda (ints coms material fill cols x idx ntot report)
      (list report fill x idx cols))))
(define hop (row-plan '(("ploughed#north@0" . 2.0) ("ploughed#mid@1" . 1.0) ("ploughed#south@2" . 2.0))))
(format #t "    two-hop day: north@0 ~,3f mid@1 ~,3f south@2 ~,3f; placement ~a~%"
        (ploughed-at hop "north" 0) (ploughed-at hop "mid" 1) (ploughed-at hop "south" 2) (placement-of hop))
(check "the day is three bands: the mover's hours are each band's own (3 h, 2 h, 3 h)"
       (let ((rd (assoc "tractor-7" *riders*)))
         (and rd (equal? (map (lambda (t) (cons t (rider-hours rd t))) '(0 1 2)) '((0 . 3.0) (1 . 2.0) (2 . 3.0))))))
(check "two hops in one day: north in the morning, mid at midday, south in the afternoon"
       (let ((p (placement-of hop)))
         (and p (every (lambda (ct) (let ((v (assoc-ref p (car ct)))) (and v (near? v 1.0 1e-3))))
                       '(("north@0") ("mid@1") ("south@2"))))))
(check "…and each field is ploughed in its band"
       (and (> (ploughed-at hop "north" 0) 1.9) (> (ploughed-at hop "mid" 1) 0.9) (> (ploughed-at hop "south" 2) 1.9)))
(check "…every ride whole, the tree certified"
       (let ((d (assq-ref (assq-ref (car hop) 'certificate) 'discrete))) (and d (eq? #t (assq-ref d 'certified?)))))
;; the midday band is two hours: with the ride in, less than that is left to
;; plough — a want of three there is met by what the band holds, not by the
;; morning's three hours read at the day's opening
(define midday (row-plan '(("ploughed#north@0" . 2.0) ("ploughed#mid@1" . 3.0) ("ploughed#south@2" . 2.0))))
(format #t "    midday want 3: mid@1 ~,3f~%" (ploughed-at midday "mid" 1))
(check "a short band carries only its own hours: the midday field gets under two units, not three"
       (let ((m (ploughed-at midday "mid" 1))) (and (> m 1.0) (< m 1.9))))

(format #t "~%── 8. the degenerate case is free ──~%~%")

(check "a scope with no declaration opens no search"
       (begin (plan #f) (not (discrete-declared?))))
(check "…and the tables it would search are empty after ingest"
       (and (= 0 (hash-count (const #t) *mbq-procs*)) (= 0 (hash-count (const #t) *whole-procs*))))

(format #t "~%~a passed, ~a failed~%" *pass* *fail*)
(exit (if (= *fail* 0) 0 1))
