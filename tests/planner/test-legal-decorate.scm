;;; test-legal-decorate.scm — the WHOLE bill fed through the planner's organs.
;;;
;;; The elegant unification (legal-crossings.md §6, §2.6): a legal bill is not a
;;; bespoke gate but three NATIVE planner inputs —
;;;   forbid (verified/reported) → a possibility-tension (column PRUNED)
;;;   forbid (uncertain)         → a SOFT cost, not a hard gate (confidence, §7)
;;;   pay                        → a labour-hour rent on the column (routes around)
;;;   obtain (person)            → a required SKILL, gated by the SAME satisfied-by
;;;                                closure as any skill (a licence IS a skill)
;;;
;;; PART 1 proves the bill→decoration mapping; PART 2 proves the live planner
;;; consumes prune / soft-cost / skill-requirement. Pure solver ⇒ no blake3.
;;;
;;; Run: guile -L module tests/planner/test-legal-decorate.scm

(use-modules (goblins utils hashmap))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness) (playnet planner knowledge recipes store) (playnet planner scope spatial-things) (playnet planner vf schemas) (playnet planner scope live)
             (goblins) (goblins vat) (srfi srfi-1) (ice-9 format))

(use-modules (playnet planner legal crossings))
(use-modules (playnet planner legal registry))
(use-modules (playnet planner legal registry-actor)) (use-modules (playnet planner legal gate))
(use-modules ((playnet planner solve engine) #:select (set-period-length!)))
;; A period here is a WEEK: the roster's Monday–Friday window is a working week of hours, on any date.
(set-period-length! 1.0 "week")

;;; ─── PART 1 : the bill → (prune? cost skills) mapping ─────────────────────
(define (parent-of id) (if (member id '("p")) "world" #f))
(define (decoration-at rules crossings)
  (call-with-values
      (lambda () (legal-demands (legal-context #:crossings crossings
                                               #:place-path (jurisdiction-path "p" parent-of)
                                               #:act 'a) #:rules rules))
    (lambda (bill hits) (call-with-values (lambda () (legal-bill->decoration bill hits)) list))))

(define R-pay     (list (rule (on-crossing 'x) (list (pay #:name "Duty"))
                              #:label "pay" #:confidence 'verified)))
(define R-licence (list (rule (on-crossing 'x)
                              (list (obtain #:rides 'person #:name "Handler Card" #:spec '(hygiene)))
                              #:label "lic" #:confidence 'verified)))
(define R-ban-v   (list (rule (on-crossing 'x) (list (forbid #:reason "ban"))
                              #:label "banv" #:confidence 'verified)))
(define R-ban-u   (list (rule (on-crossing 'x) (list (forbid #:reason "maybe-ban"))
                              #:label "banu" #:confidence 'uncertain)))

(display "\n── PART 1 · the bill → planner decoration (prune? cost skills) ──\n")
(let ((d (decoration-at R-pay '(x))))
  (format #t "  pay      → prune=~a cost=~a skills=~a\n" (car d) (cadr d) (caddr d))
  (check-pred "pay → a cost, no prune, no skill" (and (not (car d)) (> (cadr d) 0) (null? (caddr d)))))
(let ((d (decoration-at R-licence '(x))))
  (check-pred "person-obtain → a skill requirement" (and (not (car d)) (member "Handler Card" (caddr d)))))
(let ((d (decoration-at R-ban-v '(x))))
  (check-pred "verified forbid → a hard PRUNE" (car d)))
(let ((d (decoration-at R-ban-u '(x))))
  ;; …and it is no longer a line of COST either: it leaves as a tension profile
  ;; on this column (engine `*legal-frag*`), a convex barrier carrying a
  ;; governance weight rather than a flat per-unit price.
  (check-pred "UNCERTAIN forbid → not a prune, and no flat cost"
              (and (not (car d)) (= 0.0 (cadr d))))
  (check-pred "…it leaves as a TENSION profile instead"
              (equal? (list-ref d 3) %uncertain-forbid-profile)))

;;; ─── PART 2 : the live planner consumes the decoration ───────────────────
(define procs (list (make-recipe-process #:id "cook" #:name "Cook")))
(define flows (list (make-recipe-flow #:id "f-out" #:action 'produce #:resource-conforms-to "meal"
                                      #:resource-quantity (make-measure 1.0 "kg")
                                      #:recipe-output-of "cook" #:is-primary #t)
                    (make-recipe-flow #:id "f-in"  #:action 'consume
                                      #:resource-conforms-to "produce"
                                      #:resource-quantity (make-measure 1.0 "kg")
                                      #:recipe-input-of "cook")
                    (make-recipe-flow #:id "f-wk"  #:action 'work
                                      #:resource-conforms-to "cook-skill"
                                      #:effort-quantity (make-measure 0.5 "hours")
                                      #:recipe-input-of "cook")))
(define recipes (list (make-recipe #:id "r" #:name "Cook" #:primary-output "meal"
                                   #:recipe-processes '() #:recipe-exchanges '())))
(define specs (list (make-resource-specification #:id "cook-skill" #:name "Cook"
                                                 #:resource-classified-as '()
                                                 #:default-unit-of-effort "hours")
                    (make-resource-specification #:id "Handler Card" #:name "Food Handler Card"
                                                 #:resource-classified-as '()
                                                 #:default-unit-of-effort "hours")))
(define win (all-week-window "00:00" "23:59"))
;; five places. each has produce + a "cook"-skilled worker; cityA's worker ALSO
;; holds the Handler Card. demand a meal at each.
(define cells '("freeland" "banland" "softland" "cityA" "cityB"))
(define resources
  (append (map (lambda (p) (er (string-append "pr-" p) "produce" (string-append "a-" p) #:place p #:qty 100.0)) cells)
          (map (lambda (p) (er (string-append "ck-" p) "cook-skill" (string-append "w-" p) #:place p #:qty 1.0)) cells)
          (list (er "card-A" "Handler Card" "w-cityA" #:place "cityA" #:qty 1.0))))     ; only cityA is licensed
(define agents (map (lambda (p) (make-agent #:id (string-append "w-" p) #:type 'person
                                            #:primary-location p #:classified-as '()
                                            #:availability-window win)) cells))
;; distinct, far-apart coordinates so a licensed worker can't "reach" (commute
;; into) another cell and leak the licence — each cell stands on its own law.
(define spatials (map (lambda (p i) (make-spatial-thing #:id p #:lat (+ 25.0 (* 5.0 i))
                                                        #:long (- -70.0 (* 10.0 i))))
                      cells (iota (length cells))))

;; the decoration: by place — a hard ban, a soft (uncertain) cost, a licence req.
(define (cell-place cell) (let ((i (string-index cell #\@))) (if i (substring cell 0 i) cell)))
(define (decorate proc cell)
  (let ((p (cell-place cell)))
    (cond ((string=? p "banland")  (values #t 0.0 '()))           ; forbid → prune
          ((string=? p "softland") (values #f 1000.0 '()))        ; uncertain → soft cost (still runs)
          ((or (string=? p "cityA") (string=? p "cityB"))
           (values #f 0.0 (list "Handler Card")))                 ; obtain → licence skill required
          (else (values #f 0.0 '())))))

(define (solve dec)
  (define vat (spawn-vat))
  (with-vat vat
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () resources))
                               (skill-hours-of . ,(lambda (a) '())) (record-event . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes)) (all-resource-specs . ,(lambda () specs))
                               (get-process-chain . ,(lambda (r) procs))
                               (flows-for-process . ,(lambda (pid)
                                 (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                               (equal? (recipe-flow-recipe-output-of f) pid))) flows) '()))))))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
      (call-with-values
        (lambda () (plan-scope scope #:demand (map (lambda (p) (cons (string-append "meal#" p "@0") 10.0)) cells)
                               #:backend 'native-c #:legal-decorate dec))
        (lambda (i c m fill x n r) fill)))))

(display "\n── PART 2 · the live planner consumes the decoration ──\n")
(define fill-none (solve #f))
(define fill-dec  (solve decorate))
(format #t "  fill  no-law: ~,3f   with-decoration: ~,3f  (banland + cityB pruned ⇒ 3/5)\n" fill-none fill-dec)
(check-pred "all five run with no law"                       (> fill-none 0.95))
(check-pred "decoration prunes banland (forbid) + cityB (no licence) ⇒ 3/5"
            (and (> fill-dec 0.55) (< fill-dec 0.65)))

;;; ─── one law, two doors, one answer ──────────────────────────────────────
;;; `#:legal-forbids?` and `#:legal-decorate` are the same wire: engine.scm
;;; lowers a bare predicate into the decorate slot. So they must read the same
;;; law the same way — and on CONFIDENCE they did not. The decoration prices a
;;; forbid the pack is only `uncertain` about as a strong soft cost
;;; (legal-crossings.md §7); the predicate pruned on it outright. A scope's plan
;;; then depended on which keyword its caller happened to pass.
;;;
;;; The predicate is now the decoration's first value, so they agree by
;;; construction rather than by both being kept correct.
(define (confidence-pair conf)
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let* ((rs  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                         (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
             (sts (spawn ^spatial-thing-store (hashmap)))
             (reg (spawn ^legal-registry
                         (list (rule (all-of (in-jurisdiction "ici") (on-crossing 'public-sale))
                                     (list (forbid #:reason "interdit"))
                                     #:label "t/forbid" #:confidence conf
                                     #:steward "scope:test")))))
        ($ rs 'add-resource-spec
           (make-resource-specification #:id "spec-x" #:name "X"
             #:resource-classified-as '("crossing:public-sale") #:default-unit-of-resource "kg"))
        ($ rs 'add-recipe-process (make-recipe-process #:id "rp-x" #:name "X"))
        ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-x" #:action 'produce #:resource-conforms-to "spec-x"
                                  #:resource-quantity (make-measure 1 "kg") #:recipe-output-of "rp-x" #:is-primary #t))
        ($ sts 'add-location (make-spatial-thing #:id "ici" #:name "Ici"))
        (let ((gate (make-legal-gate #:recipe-store rs #:spatial-thing-store sts
                                     #:registry reg))
              (dec  (make-legal-decorate #:recipe-store rs #:spatial-thing-store sts
                                         #:registry reg)))
          (cons (gate "rp-x" "ici@0")
                (call-with-values (lambda () (dec "rp-x" "ici@0")) list)))))))

(display "\n── one law, two doors, one answer ──\n")
(define sure    (confidence-pair 'verified))
(define unsure  (confidence-pair 'uncertain))
(format #t "  verified  → gate ~a · decorate prune ~a · tension ~a\n"
        (car sure) (car (cdr sure)) (list-ref (cdr sure) 3))
(format #t "  uncertain → gate ~a · decorate prune ~a · tension ~a\n"
        (car unsure) (car (cdr unsure)) (list-ref (cdr unsure) 3))
(check-pred "a VERIFIED forbid prunes through both doors, and raises no tension"
            (and (car sure) (car (cdr sure)) (not (list-ref (cdr sure) 3))))
(check-pred "an UNCERTAIN forbid gates through NEITHER door, and raises a tension"
            (and (not (car unsure)) (not (car (cdr unsure)))
                 (equal? (list-ref (cdr unsure) 3) %uncertain-forbid-profile)))

(display "\n")
(test-summary!)
