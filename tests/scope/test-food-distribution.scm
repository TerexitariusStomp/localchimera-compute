;;; test-food-distribution.scm — free food distribution across jurisdictions.
;;;
;;; The whole layer, in one scenario. People need to be fed in three
;;; jurisdictions, and there are TWO ways to do it, tripping DIFFERENT crossings:
;;;   SHARE — member-to-member (share-food)  → licenceless everywhere
;;;   VEND  — public sale       (food-vending) → a permit where demanded,
;;;                                              forbidden where banned, free
;;;                                              where there is no rule.
;;; So the SAME recipe carries different legal requirements by place:
;;;   freeville — no food-vending rule        → VEND runs free
;;;   foodville — food-vending needs a permit → VEND gated on custody
;;;   banville  — food-vending is forbidden   → VEND pruned, always
;;;
;;; PART 1 reads that geography straight off the real legal decorate. PART 2
;;; drives the LIVE planner and shows demand met along it — and the "register"
;;; step (granting the permit) unlocking the foodville public table. PART 3 is
;;; the plan asking us to register: reconcile names the missing permit, and the
;;; compliance-processes catalogue gives the obtain-permit recipe as the work.
;;; Pure solver / pure data ⇒ no blake3.
;;;
;;; Run: guile -L module tests/scope/test-food-distribution.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness) (playnet knowledge recipes store) (playnet scope spatial-things) (playnet observation observer) (playnet vf schemas) (srfi srfi-1) (playnet scope live)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1) (ice-9 format))

(define here (dirname (current-filename)))
(define root (dirname (dirname here)))
(define (pl p) (load (string-append root "/module/playnet/planner/" p)))
(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet legal registry-actor))
(use-modules (playnet legal gate)) (use-modules (playnet legal compliance))
(use-modules (playnet knowledge recipes compliance-food))
(use-modules (playnet knowledge recipes compliance-processes))

(define (empty-rs)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
(define (held-permit id spec holder)
  (make-economic-resource #:id id #:name spec #:conforms-to spec #:classified-as '("credential")
    #:onhand-quantity (make-measure 1 "cert") #:primary-accountable holder #:state "active"))
;; ── the planner's productive view (mock stores — the proven harness) ──
(define cells '("freeville" "foodville" "banville"))
(define fd-procs
  (list (make-recipe-process #:id "rp-fd-share" #:name "Share")
        (make-recipe-process #:id "rp-fd-vend"  #:name "Vend")))
(define fd-flows
  (list (make-recipe-flow #:id "sf-out" #:action 'produce #:resource-conforms-to "member-meal"
                          #:resource-quantity (make-measure 1.0 "kg")
                          #:recipe-output-of "rp-fd-share" #:is-primary #t)
        (make-recipe-flow #:id "sf-in"  #:action 'consume #:resource-conforms-to "produce"
                          #:resource-quantity (make-measure 1.0 "kg")
                          #:recipe-input-of "rp-fd-share")
        (make-recipe-flow #:id "sf-wk"  #:action 'work #:resource-conforms-to "fd-cook"
                          #:effort-quantity (make-measure 0.5 %effort-unit)
                          #:recipe-input-of "rp-fd-share")
        (make-recipe-flow #:id "vf-out" #:action 'produce #:resource-conforms-to "public-meal"
                          #:resource-quantity (make-measure 1.0 "kg")
                          #:recipe-output-of "rp-fd-vend" #:is-primary #t)
        (make-recipe-flow #:id "vf-in"  #:action 'consume #:resource-conforms-to "produce"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "rp-fd-vend")
        (make-recipe-flow #:id "vf-wk"  #:action 'work #:resource-conforms-to "fd-cook"
                          #:effort-quantity (make-measure 0.5 %effort-unit)
                          #:recipe-input-of "rp-fd-vend")))
(define fd-recipes (list (make-recipe #:id "recipe-fd-share" #:name "Share"
                                      #:primary-output "member-meal" #:recipe-processes '()
                                      #:recipe-exchanges '())
                         (make-recipe #:id "recipe-fd-vend"  #:name "Vend"
                                      #:primary-output "public-meal" #:recipe-processes '()
                                      #:recipe-exchanges '())))
(define fd-specs (list (make-resource-specification #:id "fd-cook" #:name "Cook"
                                                    #:resource-classified-as '()
                                                    #:default-unit-of-effort %effort-unit)))
(define win (all-week-window "00:00" "23:59"))
;; each cell has produce, a fd-cook worker, and that cook holds a Food Handler
;; Card (the person competence the foodville rule also demands — so the ENTITY
;; establishment permit is the one thing left to register) and the administration
;; skill the register work (obtain-permit's `work` flow) asks for — a skill is a
;; worked spec someone holds; a card or a crate of produce is not one.
(define fd-resources
  (append (map (lambda (p) (er (string-append "pr-" p) "produce" (string-append "a-" p) #:place p #:qty 100.0)) cells)
          (map (lambda (p) (er (string-append "ck-" p) "fd-cook" (string-append "w-" p) #:place p #:qty 1.0)) cells)
          (map (lambda (p) (er (string-append "adm-" p) (resource-specification-id compliance-admin-skill-spec) (string-append "w-" p) #:place p #:qty 1.0)) cells)
          ;; the card is a CREDENTIAL (the record says so, as held-permit does): a
          ;; licence is a skill the law asks of the person (legal/gate.scm)
          (map (lambda (p) (er (string-append "card-" p) "Food Handler Card" (string-append "w-" p) #:place p #:qty 1.0 #:tags '("credential"))) cells)))
(define fd-agents (map (lambda (p) (make-agent #:id (string-append "w-" p) #:type 'person
                                               #:primary-location p #:classified-as '()
                                               #:availability-window win)) cells))
(define fd-spatials (map (lambda (p i) (make-spatial-thing #:id p #:lat (+ 20.0 (* 8.0 i))
                                                           #:long (- -70.0 (* 12.0 i))))
                         cells (iota (length cells))))
(define (chain-for r) (cond ((equal? r "recipe-fd-share") (list (first fd-procs)))
                            ((equal? r "recipe-fd-vend")  (list (second fd-procs)))
                            (else '())))
(define fd-demand
  (append (map (lambda (p) (cons (string-append "member-meal#" p "@0") 10.0)) cells)
          (map (lambda (p) (cons (string-append "public-meal#" p "@0") 10.0)) cells)))

;; one self-contained scenario in its OWN vat (fresh planner state per solve,
;; like test-legal-decorate) → (list geo fill recon obtain-recipe-id). `permit?`
;; decides whether foodville's establishment permit has been GRANTED yet.
(define (run permit?)
  (define v (spawn-vat))
  (with-vat v
    (let* ((lrs  (empty-rs))
           (lsts (spawn ^spatial-thing-store (hashmap)))
           (reg  (spawn ^legal-registry (list (compliance-food-rule) (banville-food-ban-rule))))
           (cobs (spawn ^observer (empty-observer-state) '())))
      (seed-food-distribution-recipes lrs)
      ($ lsts 'add-location (make-spatial-thing #:id "world"))
      (for-each (lambda (p ll) ($ lsts 'add-location
                                  (make-spatial-thing #:id p #:lat (car ll) #:long (cdr ll)
                                                      #:contained-in "world")))
                cells '((20.0 . -70.0) (28.0 . -82.0) (36.0 . -94.0)))
      ;; the "register" work is a real obtain-permit recipe (the catalogue).
      (define orp (seed-obtain-permit-recipe lrs #:permit-spec "Food Establishment Permit"
                                             #:authority "auth:foodville-health" #:fee 50))
      (when permit?
        ($ cobs 'seed-resource (held-permit "res:permit" "Food Establishment Permit" "scope:foodco")))
      (let* ((dec  (make-legal-decorate/observer
                    #:recipe-store lrs #:spatial-thing-store lsts
                    #:registry reg #:observer cobs #:act 'food #:as-of "2026-07-14"
                    #:subject-at (lambda (p c) "scope:foodco")))
             (prune? (lambda (proc cell)
                       (call-with-values (lambda () (dec proc cell)) (lambda (p c s . _) p))))
             (obs (spawn ^mock `((all-resources . ,(lambda () fd-resources))
                                 (skill-hours-of . ,(lambda (a) '())) (record-event . ,(lambda (e) "ok")))))
             (as  (spawn ^mock `((all-agents . ,(lambda () fd-agents)))))
             (mst (spawn ^mock `((all-locations . ,(lambda () fd-spatials)))))
             (rs  (spawn ^mock `((all-recipes . ,(lambda () fd-recipes)) (all-resource-specs . ,(lambda () fd-specs))
                                 (get-process-chain . ,chain-for)
                                 (flows-for-process . ,(lambda (pid)
                                   (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                                 (equal? (recipe-flow-recipe-output-of f) pid))) fd-flows) '()))))))
             (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store mst #:recipe-store rs)))
        (list
         (list (prune? "rp-fd-share" "freeville@0") (prune? "rp-fd-vend" "freeville@0")
               (prune? "rp-fd-vend" "foodville@0")  (prune? "rp-fd-vend" "banville@0"))
         (call-with-values
           (lambda () (plan-scope scope #:demand fd-demand #:backend 'native-c #:legal-decorate dec))
           (lambda (i c m fill x n r) fill))
         (call-with-values
           (lambda () (legal-demands (legal-context #:crossings '(food-vending)
                                                    #:place-path '("foodville" "world") #:act 'food)
                                     #:rules (list (compliance-food-rule))))
           (lambda (bill hits)
             (reconcile bill hits cobs "2026-07-14"
                        #:subject-of (lambda (d k) (if (eq? k 'obtain-person) "person:ada" "scope:foodco")))))
         orp)))))

(define before (run #f))
(define after  (run #t))
(define geo-before  (list-ref before 0))
(define fill-before (list-ref before 1))
(define recon       (list-ref before 2))
(define orp         (list-ref before 3))
(define geo-after   (list (list-ref (list-ref after 0) 2) (list-ref (list-ref after 0) 3)))
(define fill-after  (list-ref after 1))

(display "\n── PART 1 · the legal geography of feeding people (per recipe × jurisdiction) ──\n")
(format #t "  SHARE@freeville prune=~a  VEND@freeville=~a  VEND@foodville=~a  VEND@banville=~a\n"
        (first geo-before) (second geo-before) (third geo-before) (fourth geo-before))
(check-pred "SHARE (member-to-member) is licenceless — never pruned" (not (first geo-before)))
(check-pred "VEND is FREE in freeville (no food-vending rule)"       (not (second geo-before)))
(check-pred "VEND is GATED in foodville (permit not yet held) — pruned" (third geo-before))
(check-pred "VEND is FORBIDDEN in banville — pruned"                 (fourth geo-before))

(display "\n── PART 2 · the live planner feeds people along that geography ──\n")
(format #t "  fill before registering: ~,3f  (member×3 everywhere + public@freeville = 4/6)\n" fill-before)
(check-pred "member meals + freeville's public table are met (≈4/6)"
            (and (> fill-before 0.6) (< fill-before 0.72)))

(display "\n── PART 3 · the plan asks us to register ──\n")
(let ((perm (find (lambda (e) (equal? (caddr e) "Food Establishment Permit")) recon)))
  (check-pred "reconcile names the foodville permit as required" (and perm #t))
  (check "…and its status is MISSING — the gap to close" (entry-status perm) 'missing))
(check "the 'register' work is a real obtain-permit recipe" orp "rp-obtain:Food Establishment Permit")

(display "\n── after registering (permit granted): the foodville table opens ──\n")
(format #t "  VEND@foodville prune=~a  VEND@banville=~a   fill after: ~,3f  (now 5/6)\n"
        (first geo-after) (second geo-after) fill-after)
(check-pred "granting the permit UN-gates foodville's public table" (not (first geo-after)))
(check-pred "banville stays forbidden — you cannot register past a ban" (second geo-after))
(check-pred "the plan now feeds one more table (≈5/6)"
            (and (> fill-after 0.79) (< fill-after 0.9)))
(check-pred "…strictly more people fed than before registering" (> fill-after fill-before))

(display "\n")
(test-summary!)
