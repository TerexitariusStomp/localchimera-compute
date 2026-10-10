;;; test-legal-tension.scm — an uncertain prohibition BOUNDS a plan; it neither
;;; forbids it nor merely prices it.
;;;
;;; A prohibition the law is sure of removes the column: an impossibility. One a
;;; pack is only UNCERTAIN of used to be a flat 1000.0 added to the column's cost
;;; — an engineering constant sitting where `tension-registry.scm` says a
;;; "political-economic choice, made by stewardship scopes and ratified at the UC
;;; level" belongs. A flat price is also the wrong model: legal exposure is
;;; convex, and a per-unit charge says the hundredth unpermitted structure is no
;;; worse than the first.
;;;
;;; So it is a `frag` — the log barrier that diverges at a tip never crossed and
;;; PERSISTS at the optimum, carrying a fixed governance weight. The plan eases
;;; off before the limit instead of paying its way through.
;;;
;;; What this suite shows is that the tip is a DIAL: raise how much
;;; legally-uncertain activity the federation will carry, and the plan does more.
;;; That is what makes it a political parameter rather than a constant.
;;;
;;; Run: guile -L module tests/planner/test-legal-tension.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope))
(use-modules (playnet test harness) (playnet planner knowledge recipes store) (playnet planner scope spatial-things) (playnet planner scope root) (playnet planner vf schemas) (playnet planner scope live)
             (playnet planner legal gate)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (srfi srfi-13) (ice-9 format))

(define procs (list (make-recipe-process #:id "make" #:name "Make")))
(define flows
  (list (make-recipe-flow #:id "f-out" #:action 'produce #:resource-conforms-to "good"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-output-of "make"
                          #:is-primary #t)
        (make-recipe-flow #:id "f-in"  #:action 'consume #:resource-conforms-to "raw"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "make")
        (make-recipe-flow #:id "f-wk"  #:action 'work #:resource-conforms-to "skill"
                          #:effort-quantity (make-measure 0.5 %effort-unit) #:recipe-input-of "make")))
(define recipes (list (make-recipe #:id "r" #:name "Make" #:primary-output "good"
                                   #:recipe-processes '() #:recipe-exchanges '())))
(define specs (list (make-resource-specification #:id "skill" #:name "Skill"
                                                 #:resource-classified-as '()
                                                 #:default-unit-of-effort %effort-unit)))
(define win (all-week-window "00:00" "23:59"))
(define resources (list (er "raw-ici" "raw" "a-ici" #:place "ici" #:qty 100.0)
                        (er "sk-ici" "skill" "w-ici" #:place "ici" #:qty 1.0)))
(define agents (list (make-agent #:id "w-ici" #:type 'person #:primary-location "ici"
                                 #:classified-as '() #:availability-window win)))
(define spatials (list (make-spatial-thing #:id "ici" #:lat 40.0 #:long -74.0)))

;; DEMAND five, so a tip of one run is a real bound and not a formality
(define %demand 5.0)

(define (solve dec)
  (define vat (spawn-vat))
  (with-vat vat
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () resources))
                               (skill-hours-of . ,(lambda (a) '()))
                               (record-event . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes))
                               (all-resource-specs . ,(lambda () specs))
                               (get-process-chain . ,(lambda (r) procs))
                               (flows-for-process
                                . ,(lambda (pid)
                                     (cons (filter (lambda (f)
                                                     (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                         (equal? (recipe-flow-recipe-output-of f) pid)))
                                                   flows) '()))))))
           (scope (spawn ^mock `((observer . ,(lambda () obs)) (agent-store . ,(lambda () as))
                                 (spatial-thing-store . ,(lambda () sts))
                                 (recipe-store . ,(lambda () rs))
                                 (legal-registry . ,(lambda () #f))))))
      (call-with-values
          (lambda () (plan-scope scope #:demand (list (cons "good#ici@0" %demand))
                                 #:backend 'native-c #:legal-decorate dec))
        (lambda (i c m fill x n r) (cons fill r))))))
(define (met r) (car r))

;; the three readings of one prohibition
(define (no-law   p c) (values #f 0.0 '()))                    ; a 3-value producer still works
(define (forbidden p c) (values #t 0.0 '() #f))                ; the law is SURE
(define %w 100.0)                                              ; the governance weight under test
(define (uncertain-at tip)                                     ; the law is UNSURE, to this tip
  (lambda (p c) (values #f 0.0 '() (list 0.0 tip 1.0 %w))))

(define free-r (solve no-law))   (define free   (met free-r))
(define banned-r (solve forbidden)) (define banned (met banned-r))
(define t1-r   (solve (uncertain-at 1.0))) (define t1 (met t1-r))
(define t3-r   (solve (uncertain-at 3.0))) (define t3 (met t3-r))

(display "\n── one prohibition, three readings ──\n")
(format #t "  no law                        met ~,3f\n" free)
(format #t "  the law is SURE  (a prune)    met ~,3f\n" banned)
(format #t "  UNSURE, tip 1 of 5 demanded   met ~,3f\n" t1)
(format #t "  UNSURE, tip 3 of 5 demanded   met ~,3f\n" t3)

(check-pred "with no law the demand is met" (> free 0.95))
(check-pred "a prohibition the law is SURE of removes the column outright" (< banned 0.05))
(check-pred "an UNCERTAIN one neither forbids — the plan does a real share of what is tolerated"
            (> t1 (* 0.5 (/ 1.0 %demand))))
(check-pred "…nor lets the plan pay its way through — it stays inside the tolerated level"
            (< t1 (/ 1.0 %demand)))

(display "\n── the tip is a dial, not a constant ──\n")
;;; This is the whole argument for moving it. How much legally-uncertain activity
;;; a federation will carry is a choice it makes, and the plan answers to it.
(format #t "  raising the tip from 1 to 3 moves met ~,3f → ~,3f\n" t1 t3)
(check-pred "raising the tolerated level raises what the plan will do" (> t3 t1))
(check-pred "…and it still eases off before the tip rather than reaching it"
            (< t3 (/ 3.0 %demand)))

(display "\n── the weight means what it says ──\n")
;;; The intent, pinned as a PROPERTY rather than as a number: "ease off before
;;; the limit". Too light and the plan runs flat to the tip, which is a cap and
;;; not a tension; too heavy and it does nothing, which is a prune in disguise.
;;; A federation re-weighting this sees here whether it still means either.
(define (share met tip) (/ (* met %demand) tip))
(format #t "  of what is tolerated, the plan does ~,0f% (tip 1) and ~,0f% (tip 3)\n"
        (* 100 (share t1 1.0)) (* 100 (share t3 3.0)))
(check-pred "at this weight the plan eases off — well inside the tip, but far from nothing"
            (and (< 0.6 (share t1 1.0) 0.95)
                 (< 0.6 (share t3 3.0) 0.95)))

;;; ─── the dial reaches the scope's own door ───────────────────────────────
;;; A parameter nothing can set is still a constant. `scope-legal-decorate` and
;;; `make-legal-decorate` both take `#:soft-profile`, so the tolerance arrives at
;;; the solve by the same door the law does. Its eventual home is the tension
;;; catalogue a federation ratifies; this is the wire it comes in on.
(use-modules (playnet planner legal registry) (playnet planner legal registry-actor)
             (playnet planner legal crossings))
(define (scope-tolerance-of profile)
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let* ((rs2  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                          (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
             (sts2 (spawn ^spatial-thing-store (hashmap)))
             (reg  (spawn ^legal-registry
                          (list (rule (all-of (in-jurisdiction "ici") (on-crossing 'public-sale))
                                      (list (forbid #:reason "peut-être"))
                                      #:label "t/unsure" #:confidence 'uncertain)))))
        ($ rs2 'add-resource-spec
           (make-resource-specification #:id "spec-y" #:name "Y" #:resource-classified-as '("crossing:public-sale")
                                        #:default-unit-of-resource "kg"))
        ($ rs2 'add-recipe-process (make-recipe-process #:id "rp-y" #:name "Y"))
        ($ rs2 'add-recipe-flow (make-recipe-flow #:id "rf-y" #:action 'produce #:resource-conforms-to "spec-y"
                                   #:resource-quantity (make-measure 1 "kg") #:recipe-output-of "rp-y" #:is-primary #t))
        ($ sts2 'add-location (make-spatial-thing #:id "ici" #:name "Ici"))
        (let ((dec (make-legal-decorate #:recipe-store rs2 #:spatial-thing-store sts2
                                        #:registry reg #:soft-profile profile)))
          (call-with-values (lambda () (dec "rp-y" "ici@0"))
            (lambda (p c s frag . _) frag)))))))

(display "\n── the dial reaches the scope's own door ──\n")
(define strict (scope-tolerance-of '(0.0 0.5 1.0 100.0)))
(define loose  (scope-tolerance-of '(0.0 9.0 1.0 100.0)))
(format #t "  a strict scope carries ~a · a permissive one ~a\n" strict loose)
(check-pred "the profile a scope names is the profile its uncertain prohibitions ride"
            (and (equal? strict '(0.0 0.5 1.0 100.0))
                 (equal? loose  '(0.0 9.0 1.0 100.0))))
(check-pred "…and with none named, the documented placeholder stands"
            (equal? (scope-tolerance-of %uncertain-forbid-profile)
                    %uncertain-forbid-profile))

;;; ─── the commune's own row governs it ────────────────────────────────────
;;; The tolerance is not this module's constant. It is a governed datum on the
;;; plan-store's meta rail, read through one door: a caller's explicit
;;; keyword wins over the commune's row, and the row wins
;;; over the default. Nobody edits code to move a line the commune is entitled
;;; to move.
(use-modules (playnet planner legal policy) (playnet planner legal compliance)
             (playnet planner legal registry-actor))

(define governed
  (with-vat (spawn-vat)
    (let* ((root (spawn-scope-root "Policy Scope"))
           (ps   ($ root 'plan-store))
           (reg  ($ root 'legal-registry)))
      ($ reg 'register! (rule (all-of (in-jurisdiction "ici") (on-crossing 'public-sale))
                              (list (forbid #:reason "peut-être"))
                              #:label "t/unsure" #:confidence 'uncertain))
      ($ ($ root 'spatial-thing-store) 'add-location
         (make-spatial-thing #:id "ici" #:name "Ici"))
      ($ ($ root 'recipe-store) 'add-resource-spec
         (make-resource-specification #:id "spec-z" #:name "Z" #:resource-classified-as '("crossing:public-sale")
                                      #:default-unit-of-resource "kg"))
      ($ ($ root 'recipe-store) 'add-recipe-process
         (make-recipe-process #:id "rp-z" #:name "Z"))
      ($ ($ root 'recipe-store) 'add-recipe-flow
         (make-recipe-flow #:id "rf-z" #:action 'produce #:resource-conforms-to "spec-z"
                           #:resource-quantity (make-measure 1 "kg") #:recipe-output-of "rp-z"
                           #:is-primary #t))
      (define (frag-of)
        (call-with-values (lambda () ((scope-legal-decorate root) "rp-z" "ici@0"))
          (lambda (p c s frag . _) frag)))
      (let ((before (frag-of)))
        ;; the commune moves its own line
        ($ ps 'set-meta "legal-policy" '((uncertain-forbid . (0.0 7.0 1.0 25.0))))
        (list before (frag-of)
              ;; …and a caller may still override the commune, for one solve
              (call-with-values
                  (lambda () ((scope-legal-decorate root #:soft-profile '(0.0 2.0 1.0 5.0))
                              "rp-z" "ici@0"))
                (lambda (p c s frag . _) frag)))))))

(display "\n── the exposure is readable off the plan ──\n")
;;; A frag form is anonymous, and rightly: the solver has no business knowing WHY
;;; a limit is there. Identity lives with the declaration, so the report reads the
;;; legal tensions back against the solution. Without it the tension is real in
;;; the objective and invisible in the answer — a plan that quietly took a legal
;;; risk would look exactly like one that had none to take.
(define lx (assq-ref (cdr t1-r) 'legal))
(format #t "  ~a\n" lx)
(check-pred "the plan names the acts it ran under an uncertain prohibition"
            (and (pair? lx) (string-prefix? "p|make|ici" (car (car lx)))))
(check-pred "…with the level it chose, the tip it was given, and the share of it used"
            (let ((e (cdr (car lx))))
              (and (> (assq-ref e 'level) 0.0)
                   (= (assq-ref e 'tip) 1.0)
                   (< 0.6 (assq-ref e 'share) 0.95))))
(check-pred "a plan with no uncertain prohibition reports no legal exposure at all"
            (not (assq-ref (cdr free-r) 'legal)))
(check-pred "…and neither does one whose prohibition was certain — that column is simply gone"
            (not (assq-ref (cdr banned-r) 'legal)))

(display "\n── the commune's own row governs it ──\n")
(format #t "  default ~a\n  after the commune sets its row ~a\n  a caller overriding for one solve ~a\n"
        (car governed) (cadr governed) (caddr governed))
(check-pred "with no row, the documented default stands"
            (equal? (car governed) (assq-ref *legal-policy-defaults* 'uncertain-forbid)))
(check-pred "the commune's governed row moves the line"
            (equal? (cadr governed) '(0.0 7.0 1.0 25.0)))
(check-pred "…and an explicit keyword still wins over the row"
            (equal? (caddr governed) '(0.0 2.0 1.0 5.0)))

(display "\n── the barrier persists at the optimum ──\n")
;;; A swept `bar` would vanish as the central path converges; `frag` carries a
;;; fixed governance weight, so the federation is still leaning away from the
;;; limit at the answer it ships — which is why the level lands strictly inside
;;; the tip rather than on it.
(check-pred "the plan lands strictly inside the tolerated level, at both tips"
            (and (< (* t1 %demand) 1.0) (< (* t3 %demand) 3.0)))
(test-summary!)
