;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-element-closure.scm — conservation as a constraint, not a reading.
;;;
;;; docs/social-material.typ: "a balanced chemical reaction is a recipe … the convex
;;; optimiser solves a reaction network with no new machinery". For a recipe authored
;;; AS a reaction that already held — its elements are specs and the solver balances
;;; them like any good. This is the other half: an ordinary PRODUCT recipe's element
;;; accounting, which reached the plan as a post-solve reading (`plan->material`)
;;; rather than as something the plan had to satisfy.
;;;
;;; One row per element per cell, and it is the residual `check-conservation` already
;;; computes, promoted from a check to a good:
;;;
;;;     El|e  supplied by  Σ_consumed q·frac(s,e)  −  Σ_produced q·frac(s,e)
;;;
;;; with the ordinary `≥ 0` balance every good gets. The element entering a process
;;; must cover the element leaving in its products.
;;;
;;; THE INEQUALITY IS THE DESIGN. Equality would forbid loss as well, and one lossy
;;; recipe would make a plan infeasible with nothing to point at. `≥ 0` forbids
;;; exactly the impossible half:
;;;
;;;   CREATION  producing more of an element than was drawn drives the balance
;;;             negative, so the column cannot run. Matter is not conjured.
;;;   LOSS      drawing more than is embodied leaves a SURPLUS — which is the sink,
;;;             and which is the rift made visible instead of vanishing.
;;;
;;; And it costs nothing where the knowledge is honest: a conserving recipe has net
;;; zero, so it gets no row at all. The constraint is invisible until a recipe is
;;; wrong, which is when it is wanted.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-element-closure.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve compile))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b) (< (abs (- a b)) 0.001))

(define PLACE "farm")
;; soil-n IS nitrogen (the definitional identity); food declares 2.6% N.
(define COMP '(("soil-n" ("N" . 1.0)) ("food" ("N" . 0.026))))

(define (setup! draw comp)
  "One recipe: draw DRAW kg of soil nitrogen, make 100 kg of food (2.6 kg of N)."
  (declare-world! #:places (list PLACE)
                  #:templates
                    (list (list "bake" (list (cons "food" 100.0)) (list (cons "soil-n" draw))
                               0.0 '() '() '() '() '())))
  (for-each (lambda (c) (hash-set! *composition* (car c) (cdr c))) comp)
  (close-elements!)
  (hash-set! *cap* (lg "soil-n" (cell PLACE 0)) 1000.0))

(define (element-flow draw comp)
  (setup! draw comp)
  (let* ((cols (build-columns))
         (c (find (lambda (c) (string-prefix? "p|bake" (col-key c))) cols)))
    (and c (assoc-ref (col-flows c) (lg "El|N" (cell PLACE 0))))))

(format #t "~%── 1. a conserving recipe is not constrained at all ──~%~%")

;; 100 kg of food at 2.6% N embodies exactly the 2.6 kg drawn.
(check "a recipe that conserves gets no element row"
       (not (element-flow 2.6 COMP)))
(check "…and its template carries no El| output either"
       (begin (setup! 2.6 COMP)
              (not (any (lambda (oq) (string-prefix? "El|" (car oq)))
                        (proc-outputs (car *templates*))))))

(format #t "~%── 2. a LOSS leaves a surplus — the rift, visible ──~%~%")

;; drawing 5.0 to embody 2.6 loses 2.4 kg of nitrogen somewhere unnamed
(let ((f (element-flow 5.0 COMP)))
  (format #t "    draw 5.00, embody 2.60 → El|N coefficient ~,3f~%" (or f 0))
  (check "an unaccounted loss appears as element nobody claimed" (and f (near? 2.4 f)))
  (check "…which is a SUPPLY, so it never makes the plan infeasible" (and f (> f 0))))

(format #t "~%── 3. CREATION is refused ──~%~%")

;; drawing 1.0 to embody 2.6 would conjure 1.6 kg of nitrogen. A run's net is linear
;; in the run, so the verdict is the TEMPLATE's: it is refused before any column is
;; laid, and the plan names the reason by the process
(begin
  (setup! 1.0 COMP)
  (let ((why (why-not "bake")))
    (format #t "    draw 1.00, embody 2.60 → why-not ~s~%" why)
    (check "conjuring matter refuses the template: it is gone from the world"
           (not (find (lambda (t) (equal? (proc-id t) "bake")) *templates*)))
    (check "…and the plan says why, by the process: creates N, −1.6"
           (and why (eq? 'creates (car why)) (near? -1.6 (assoc-ref (cdr why) "N")))))
  (check "…so the recipe cannot run: no column is laid for it"
         (not (any (lambda (c) (string-prefix? "p|bake" (col-key c))) (build-columns))))
  (check "…and the element good is balanced, not a free structural pool"
         (not (spec-skips-balance? "El|N" #f))))

;; how good a figure is belongs to the figure: a row carries its bar on a leaf under
;; the leaf's name behind the sign, and a run's allowed shortfall is each flow's
;; quantity times its row's bar. Food stated at 2.6% ± 0.1% of N may hold 2.5 kg in
;; a hundred, so a draw of 2.52 kg is explained and one of 2.48 is a creation
(define COMP± '(("soil-n" ("N" . 1.0)) ("food" ("N" . 0.026) ("±N" . 0.001))))
(begin
  (setup! 2.52 COMP±)
  (check "a shortfall the rows' bars explain is no creation"
         (and (find (lambda (t) (equal? (proc-id t) "bake")) *templates*) (not (why-not "bake"))))
  (check "…and lays no El| row for it either"
         (not (assoc-ref (proc-outputs (car *templates*)) "El|N")))
  (check "…and a bar is no leaf: no row is laid for it"
         (not (any (lambda (oq) (string-prefix? "El|±" (car oq))) (proc-outputs (car *templates*)))))
  (setup! 2.48 COMP±)
  (check "a shortfall past the bars is a creation, refused"
         (let ((why (why-not "bake"))) (and why (near? -0.12 (assoc-ref (cdr why) "N")))))
  (setup! 2.5999 COMP)
  (check "a row stating no bar is taken at its word: the last hundred milligrams are a creation"
         (and (why-not "bake") #t)))

(format #t "~%── 3b. a neighbour's loss pays for nothing ──~%~%")

;; a second recipe in the same cell that LOSES 10 kg of nitrogen: its surplus is the
;; rift, visible, and no supply — the conjurer beside it is refused all the same
(begin
  (declare-world! #:places (list PLACE)
                  #:templates
                    (list (list "bake" (list (cons "food" 100.0)) (list (cons "soil-n" 1.0)) 0.0 '() '() '() '() '())
                          (list "waste" (list (cons "ash" 1.0)) (list (cons "soil-n" 10.0)) 0.0 '() '() '() '() '())))
  (for-each (lambda (c) (hash-set! *composition* (car c) (cdr c))) (cons '("ash" ("N" . 0.0)) COMP))
  (close-elements!)
  (hash-set! *cap* (lg "soil-n" (cell PLACE 0)) 1000.0)
  (let ((keys (map col-key (build-columns))))
    (format #t "    columns laid: ~s~%" keys)
    (check "the conjurer is refused with a waster beside it"
           (not (any (lambda (k) (string-prefix? "p|bake" k)) keys)))
    (check "…while the waster runs, its loss a positive El|N output"
           (and (any (lambda (k) (string-prefix? "p|waste" k)) keys)
                (let ((t (find (lambda (t) (equal? (proc-id t) "waste")) *templates*)))
                  (and t (near? 10.0 (assoc-ref (proc-outputs t) "El|N"))))))))

(format #t "~%── 3c. a harvest at the edge is the author's word ──~%~%")

;; a process drawing nothing of any leaf has substance on one side only: it stands
;; at the system's edge, and no balance it was never inside judges it
(begin
  (declare-world! #:places (list PLACE)
                  #:templates (list (list "gather" (list (cons "food" 100.0)) (list (cons "Lab|gathering" 1.0)) 0.0 '() '() '() '() '())))
  (for-each (lambda (c) (hash-set! *composition* (car c) (cdr c))) COMP)
  (close-elements!)
  (check "a template drawing no leaf is at the edge, unjudged"
         (and (template-at-edge? (car *templates*)) (not (why-not "gather"))))
  (check "…and carries no element row: the edge is where the books begin"
         (not (any (lambda (oq) (string-prefix? "El|" (car oq))) (proc-outputs (car *templates*))))))

(format #t "~%── 3d. what returns to the sky by name is named ──~%~%")

;; a body breathing its food's carbon out as carbon dioxide names where it went: the
;; row a loss lays is the loss NOBODY named, so the breath lays none
(begin
  (declare-world! #:places (list PLACE)
                  #:templates (list (list "eat" (list (cons "co2" 4.0)) (list (cons "bread" 1.0)) 0.0 '() '() '() '() '())
                                    (list "burn" '() (list (cons "bread" 1.0)) 0.0 '() '() '() '() '())))
  (for-each (lambda (c) (hash-set! *composition* (car c) (cdr c)))
            '(("bread" ("C" . 1.0)) ("co2" ("C" . 0.25))))   ; round figures: four kilograms of the gas carry the loaf's one of carbon
  (close-elements!)
  (let ((row (lambda (pid) (assoc-ref (proc-outputs (find (lambda (t) (equal? (proc-id t) pid)) *templates*)) "El|C"))))
    (check "carbon breathed out as carbon dioxide lays no row" (not (row "eat")))
    (check "…and carbon that leaves with no name lays its kilogram" (near? 1.0 (row "burn")))))

(format #t "~%── 3e. what a loss takes with it ──~%~%")

;; heat is read in the formation frame, where matter holds less than nothing: a
;; recipe that lets half its wood go unnamed would read as heat made. The lost
;; carbon left in SOME form; a row keyed by the leaf says what it carried at the
;; most, and the loss is credited with it
(begin
  (declare-world! #:places (list PLACE)
                  #:templates (list (list "char" (list (cons "charcoal" 1.0)) (list (cons "wood" 2.0)) 0.0 '() '() '() '() '())))
  (for-each (lambda (c) (hash-set! *composition* (car c) (cdr c)))
            '(("wood" ("C" . 0.5) ("heat" . -1.5)) ("charcoal" ("C" . 0.5) ("heat" . -0.5)) ("C" ("heat" . -9.1))))
  (close-elements!)
  (check "a lossy recipe has made no heat: the carbon it lost took its own with it"
         (and (find (lambda (t) (equal? (proc-id t) "char")) *templates*) (not (why-not "char"))))
  (hash-remove! *composition* "C")
  (declare-world! #:places (list PLACE)
                  #:templates (list (list "char" (list (cons "charcoal" 1.0)) (list (cons "wood" 2.0)) 0.0 '() '() '() '() '())))
  (for-each (lambda (c) (hash-set! *composition* (car c) (cdr c)))
            '(("wood" ("C" . 0.5) ("heat" . -1.5)) ("charcoal" ("C" . 0.5) ("heat" . -0.5))))
  (close-elements!)
  (check "…and where no row says what a leaf leaves as, the loss is granted nothing"
         (let ((why (why-not "char"))) (and why (near? -2.5 (assoc-ref (cdr why) "heat"))))))

(format #t "~%── 3f. a process may say it is the edge ──~%~%")

;; the shine that lays a hectare's rain in the field's water draws the sky's rain
;; and makes the light besides: it is the sky speaking and says so by its
;; classification, the thirteenth field of a template (compile.scm proc-tags)
(begin
  (declare-world! #:places (list PLACE)
                  #:templates (list (list "shine" (list (cons "sunlight" 50.0) (cons "water" 100.0)) (list (cons "rain" 100.0))
                                          0.0 '() '() '() '() '() #f #f #f '("boundary"))
                                    (list "lamp" (list (cons "sunlight" 50.0) (cons "water" 100.0)) (list (cons "rain" 100.0))
                                          0.0 '() '() '() '() '())))
  (for-each (lambda (c) (hash-set! *composition* (car c) (cdr c)))
            '(("rain" ("H" . 0.112) ("O" . 0.888)) ("water" ("H" . 0.112) ("O" . 0.888)) ("sunlight" ("heat" . 1.0))))
  (close-elements!)
  (check "a process that says it is the boundary is judged by no balance"
         (and (find (lambda (t) (equal? (proc-id t) "shine")) *templates*) (not (why-not "shine"))))
  (check "…and the same flows with no such word are a creation of heat, refused"
         (let ((why (why-not "lamp"))) (and why (near? -50.0 (assoc-ref (cdr why) "heat"))))))

(format #t "~%── 4. off by default, and byte-identical when off ──~%~%")

(check "no composition passed ⇒ no element rows anywhere"
       (not (element-flow 1.0 '())))
(check "…and the closure reports itself off"
       (begin (setup! 1.0 '()) (not (element-closure-on?))))
(check "…while passing composition turns it on"
       (begin (setup! 1.0 COMP) (element-closure-on?)))

(format #t "~%── 5. services and labour carry no substance ──~%~%")

;; `Svc|oven` and `Lab|baking` are structural pools the planner generates. They are
;; not made of anything, and reading them as composed would invent element flows out
;; of a machine's availability.
(check "a Svc| draw contributes nothing to an element row"
       (begin
         (declare-world! #:places (list PLACE)
                         #:templates
                           (list (list "bake" (list (cons "food" 100.0))
                                       (list (cons "soil-n" 2.6) (cons "Svc|oven" 1.0))
                                       0.0 '() '() '() '() '())))
         (for-each (lambda (c) (hash-set! *composition* (car c) (cdr c))) COMP)
         (close-elements!)
         (not (any (lambda (oq) (string-prefix? "El|" (car oq)))
                   (proc-outputs (car *templates*))))))

(format #t "~%── 6. closing twice is closing once ──~%~%")

;; ingest may run more than once in a session; the rows are replaced, not stacked.
(check "re-closing does not double the element row"
       (begin (setup! 5.0 COMP) (close-elements!) (close-elements!)
              (= 1 (length (filter (lambda (oq) (string-prefix? "El|" (car oq)))
                                   (proc-outputs (car *templates*)))))))
(check "…and the coefficient is still the single residual"
       (near? 2.4 (assoc-ref (proc-outputs (car *templates*)) "El|N")))


;;; ── 7. composition per RECIPE ────────────────────────────────────────────────
;;; social-material.typ: "Two ways of growing the same crop are two recipes, hence two
;;; compositions." A spec-level row is the default; a row keyed (proc . spec) is what
;;; THAT recipe makes. The asymmetry is the mixture policy: a process's own OUTPUTS
;;; read its own row, its INPUTS read the spec's — because a consumer draws from a
;;; pool whose per-unit content is a ratio of the plan's own levels (bilinear, the
;;; pooling problem, not convex). Reading inputs at the spec level is the sound
;;; relaxation: totals still balance, so matter is never conjured; per-unit exactness
;;; about a mixture is what is given up, and separating the batches buys it back.
(format #t "~%── 7. two recipes, two compositions ──~%~%")

(define (two-recipe-net rich-frac)
  "Two ways of making `food` from the same 5 kg draw. RICH-FRAC is what the second
   recipe's own output carries; the first reads the spec default (2.6%)."
  (declare-world! #:places (list PLACE)
                  #:templates
                    (list (list "bake-plain" (list (cons "food" 100.0)) (list (cons "soil-n" 5.0))
                                0.0 '() '() '() '() '())
                          (list "bake-rich"  (list (cons "food" 100.0)) (list (cons "soil-n" 5.0))
                                0.0 '() '() '() '() '())))
  (for-each (lambda (c) (hash-set! *composition* (car c) (cdr c))) COMP)
  ;; the per-recipe row: food, as `bake-rich` makes it
  (hash-set! *composition* (cons "bake-rich" "food") (list (cons "N" rich-frac)))
  (close-elements!)
  (map (lambda (tpl) (cons (proc-id tpl) (assoc-ref (proc-outputs tpl) "El|N")))
       *templates*))

;; the same draw and the same output SPEC, read two ways: 2.6% by default, 5% here.
(let ((nets (two-recipe-net 0.05)))
  (format #t "    bake-plain (food at the spec's 2.6%): residual ~a~%" (assoc-ref nets "bake-plain"))
  (format #t "    bake-rich  (food at its own    5.0%): residual ~a~%" (assoc-ref nets "bake-rich"))
  (check "the default row governs the recipe that states nothing"
         (near? 2.4 (assoc-ref nets "bake-plain")))       ; 5.0 − 100×0.026
  (check "…and a recipe's OWN row governs its own output"
         (not (assoc-ref nets "bake-rich"))))             ; 5.0 − 100×0.05 = 0, conserves

;; a per-recipe row that conjures matter is refused exactly as a spec-level one is —
;; per-recipe composition is a second place to state the truth, not a way around it.
(let ((nets (two-recipe-net 0.08)) (why (why-not "bake-rich")))
  (check "a per-recipe composition cannot conjure matter either: the recipe is refused, N −3.0"
         (and (not (assoc "bake-rich" nets)) why (near? -3.0 (assoc-ref (cdr why) "N")))))   ; 5.0 − 100×0.08

;; and the per-recipe row is scoped: it must not leak to the other recipe's output
(let ((nets (two-recipe-net 0.05)))
  (check "one recipe's composition does not govern another's output"
         (near? 2.4 (assoc-ref nets "bake-plain"))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — matter cannot be conjured, an unnamed loss shows~%  as element nobody claimed, and each recipe says what IT makes.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
