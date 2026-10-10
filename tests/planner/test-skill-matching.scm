;;; test-skill-matching.scm — who may do a piece of work, and what "may" means.
;;;
;;; Two questions live at two levels, and conflating them is easy:
;;;
;;;   1. WHAT A PROCESS DEMANDS.  Its labour is `skill-labours` — one line per
;;;      skill, each with its own hours, each compiling to its own located good
;;;      `Lab|<skill>@<cell>`.  ALL of them must be covered or the process does
;;;      not run.  What is free is WHO covers each line: nothing anywhere asks
;;;      one worker to hold a process's whole skill set, and two people with one
;;;      skill each bake the loaf between them.
;;;
;;;   2. WHETHER A PERSON MAY SUPPLY ONE LINE.  Not "is it in their list" — the
;;;      list handed to the engine is already a CLOSURE.  `satisfied-by` is a
;;;      DNF: a person conforms to a spec if they hold it directly, or hold
;;;      EVERY component of SOME clause at ≥ its minimum practised hours.
;;;      Conjunction where a competence genuinely decomposes, disjunction where
;;;      there are several honest routes to having it, and transitive, so a
;;;      derived competence composes further.
;;;
;;; Both are load-bearing and neither was pinned. The closure had unit tests in
;;; test-skill-compose; what it did NOT have was a proof that it reaches a real
;;; solve — which is the third part here, with the catalogue removed as its
;;; control, because a closure nobody consults is indistinguishable from none.
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module -L . tests/planner/test-skill-matching.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness) (playnet planner formulas skill-law) (playnet planner vf schemas) (srfi srfi-1) (playnet planner scope live) (playnet test scope)
             ((playnet planner solve engine) #:select (plan-from-records))
             ((playnet planner formulas skill-law) #:select (effective-skills))
             (goblins) (goblins vat) (srfi srfi-1) (ice-9 format))

(define vat (spawn-vat #:name "skill-matching"))

;; ── 1. a process demands ALL its lines; anyone may cover each one ────────────

(define win (all-week-window "00:00" "23:59"))
(define (person id) (make-agent #:id id #:type 'person #:name id #:primary-location "shop"
                                #:classified-as '() #:availability-window win))
(define (skill-of id acct spec)
  (make-economic-resource #:id id #:conforms-to spec #:classified-as '() #:accounting-quantity (make-measure 8.0 %effort-unit)
    #:onhand-quantity (make-measure 8.0 %effort-unit) #:current-location "shop" #:primary-accountable acct #:custodian-scope acct))
(define shop (list (make-spatial-thing #:id "shop" #:name "Shop" #:lat 0.0 #:long 0.0)))
(define bake-proc (list (make-recipe-process #:id "bake" #:name "Bake" #:process-conforms-to "pspec"
                                             #:has-duration (make-duration 1.0 %effort-unit))))
;; ONE process, TWO skill lines
(define bake-flows
  (list (wk*  "w-mix"  "skill-mix"  1.0 "bake")
        (wk*  "w-oven" "skill-oven" 1.0 "bake")
        (out* "out"    "loaf" 10 "bake")))

(define (solve agents resources)
  "→ (fill . ((provider . skill) …)) for one loaf-demanding solve."
  (call-with-values
      (lambda () (plan-from-records resources agents shop bake-proc bake-flows
                                    #:periods '(0) #:backend 'native-c
                                    #:demand (list (cons "loaf#shop@0" 10.0))))
    (lambda args
      (let ((coms (list-ref args 1)) (fill (list-ref args 3)))
        (cons fill
              (map (lambda (c) (cons (commitment-provider c)
                                     (commitment-resource-conforms-to c)))
                   (filter (lambda (c) (eq? 'work (commitment-action c))) coms)))))))

(define split (solve (list (person "ada") (person "bo"))
                     (list (skill-of "r1" "ada" "skill-mix")
                           (skill-of "r2" "bo"  "skill-oven"))))
(define both  (solve (list (person "cy"))
                     (list (skill-of "r3" "cy" "skill-mix")
                           (skill-of "r4" "cy" "skill-oven"))))
(define gap   (solve (list (person "ada") (person "bo"))
                     (list (skill-of "r5" "ada" "skill-mix")
                           (skill-of "r6" "bo"  "skill-mix"))))

(format #t "\n── one act, two skill lines ──\n")
(format #t "  ada=mix, bo=oven : fill ~,3f  ~a\n" (car split) (cdr split))
(format #t "  cy holds both    : fill ~,3f  ~a\n" (car both)  (cdr both))
(format #t "  nobody holds oven: fill ~,3f  ~a\n" (car gap)   (cdr gap))

(check-pred "two workers holding ONE skill each cover an act that asks for two"
            (> (car split) 0.99))
(check-pred "…and each is committed to the line they hold, not to both"
            (lset= equal? '(("ada" . "skill-mix") ("bo" . "skill-oven")) (cdr split)))
(check-pred "one worker holding BOTH covers it alone"
            (and (> (car both) 0.99)
                 (lset= equal? '("cy") (delete-duplicates (map car (cdr both))))))
(check-pred "a line NOBODY holds stops the act — every line must be covered"
            (< (car gap) 1e-6))

;; ── 2. ALTERNATIVE ROUTES — the disjunction half of the DNF ─────────────────
;; test-skill-compose.scm already proves the closure's conjunction, its hours
;; thresholds, its transitivity and its identity case, and this does not repeat
;; them. What its catalogue does not have is a spec with MORE THAN ONE clause,
;; so the ∨ in "any-of (all-of)" is untested there: two honest routes to one
;; competence, neither needing anything from the other.
(define two-routes
  (list (cons "skill-drive" (list (list (cons "licence-B" 20))     ; licence-B AND 20 practised hours
                                  (list (cons "licence-C" 0))))))  ; OR licence-C, on its own
(define (route held . hours)
  (lset-difference equal?
                   (effective-skills held two-routes
                                     (lambda (s) (or (assoc-ref (if (pair? hours) (car hours) '()) s) 0)))
                   held))

(format #t "\n── two routes to one competence ──\n")
(format #t "  licence-B,  5h practised => ~a\n" (route '("licence-B") '(("licence-B" . 5))))
(format #t "  licence-B, 25h practised => ~a\n" (route '("licence-B") '(("licence-B" . 25))))
(format #t "  licence-C, no hours      => ~a\n" (route '("licence-C")))

(check-pred "the first route confers once its hours floor is met"
            (equal? '("skill-drive") (route '("licence-B") '(("licence-B" . 25)))))
(check-pred "…and withholds below it"
            (null? (route '("licence-B") '(("licence-B" . 5)))))
(check-pred "ANY clause suffices — the second route needs nothing from the first"
            (equal? '("skill-drive") (route '("licence-C"))))

;; ── 3. the closure reaches a real solve ─────────────────────────────────────
;; A worker holding the COMPONENTS and never the composite, against a process
;; that asks for the composite. With the catalogue the act runs; with the same
;; world minus `satisfied-by` it cannot — which is the control, because a
;; closure nothing consults looks exactly like a closure that is not there.
(define (composite-world satisfied?)
  (with-vat vat
    (let* ((spec (make-resource-specification #:id "skill-bake" #:name "Bake" #:resource-classified-as '() #:default-unit-of-resource %effort-unit
                   #:satisfied-by (if satisfied?
                                      (list (list (cons "skill-mix" 0) (cons "skill-oven" 0)))
                                      '())))
           (root (mock-scope
                  #:resources (list (er "s1" "skill-mix"  "ada" #:place "shop" #:qty 8.0 #:unit %effort-unit)
                                    (er "s2" "skill-oven" "ada" #:place "shop" #:qty 8.0 #:unit %effort-unit))
                  #:agents  (list (make-agent #:id "ada" #:type 'person #:name "Ada"
                                              #:primary-location "shop" #:classified-as '()
                                              #:availability-window win))
                  #:spatials (list (make-spatial-thing #:id "shop" #:name "Shop" #:lat 0.0
                                                       #:long 0.0))
                  #:recipes (list (make-recipe #:id "r-bake" #:name "Bake" #:primary-output "loaf"
                                               #:recipe-processes (quote ())
                                               #:recipe-exchanges (quote ())))
                  #:chain   (list (list "r-bake" (make-recipe-process #:id "bake" #:name "Bake" #:process-conforms-to "pspec"
                                                                      #:has-duration (make-duration 1.0 %effort-unit))))
                  #:flows   (list (wk* "w-comp" "skill-bake" 1.0 "bake")
                                  (out* "out" "loaf" 10 "bake"))
                  #:specs   (list spec))))
      (call-with-values
          (lambda () (plan-scope root #:demand (list (cons "loaf#shop@0" 10.0))
                                 #:periods '(0) #:backend 'native-c))
        (lambda args (list-ref args 3))))))

(define with-closure    (composite-world #t))
(define without-closure (composite-world #f))
(format #t "\n── a composite competence, held only in parts ──\n")
(format #t "  satisfied-by declared : fill ~,3f\n" with-closure)
(format #t "  satisfied-by removed  : fill ~,3f\n" without-closure)

(check-pred "a worker holding the PARTS supplies the composite in a live solve"
            (> with-closure 0.99))
(check-pred "…and without the satisfied-by declaration they cannot — the closure is what did it"
            (< without-closure 1e-6))

(test-summary!)
