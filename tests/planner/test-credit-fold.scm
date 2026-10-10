;;; test-credit-fold.scm — universal credit as a standing fold.
;;;
;;; The elastic math account.scm computes by polling a flat scope-root list
;;; is a read of the credit fold's standing total. PARITY is the claim: for
;;; the same world, every fold read equals the walk — on one scope, and on
;;; two scopes with a citizen active in both (today's semantics, verbatim:
;;; that citizen sums N cells, the Phase-2 multi-counting the fold makes a
;;; deliberate per-kind combine decision rather than an accident). Then the
;;; fold's own dividends: a write refolds without any list being threaded,
;;; and move-scope! carries credit like every other aggregate.
;;;
;;; Run:  guile -L module -L tests tests/planner/test-credit-fold.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness) (playnet planner observation account) (playnet planner pools credit-fold) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1) (playnet planner doors service)
             ((playnet planner observation account)
              #:select (set-person-substrate! household-consumer-voice household-social-free-time))
             (playnet planner pools credit-fold)
             (goblins) (goblins utils hashmap) (srfi srfi-1))


(use-modules ((playnet planner observation account) #:select (declare-claimable!)))
(use-modules ((playnet test scope) #:select (record-work!)))
;; the rail is read off the recipes: this fixture stands in for the plan and
;; declares that a claim recipe stands for spec-bread (account.scm spec-claimable?)
(declare-claimable! "spec-bread")

(define (approx= a b) (< (abs (- a b)) 1e-6))

(define* (work! obs aid hours eid iid #:optional plan-id)
  (record-work! obs aid hours eid iid #:plan-id plan-id))

(define (bread-pool! root n)
  (let ((rs ($ root 'recipe-store)) (obs ($ root 'observer)))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake"
                            #:has-duration (make-duration 3 %effort-unit)))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-w" #:action 'work #:resource-conforms-to "spec-labor" #:effort-quantity (make-measure 3 %effort-unit)
                         #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-o" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-bake"))
    ($ rs 'add-recipe (make-recipe #:id "recipe-bread" #:name "Bread" #:primary-output "spec-bread"
                                   #:recipe-processes (list "rp-bake")))
    ($ obs 'record-event
       (make-economic-event
        #:id (string-append "ev-bread-" ($ root 'name)) #:action 'produce
        #:resource-inventoried-as (string-append "r-bread-" ($ root 'name)) #:resource-conforms-to "spec-bread"
        #:resource-classified-as (list "individually-claimable") #:provider "commune" #:receiver "commune"
        #:resource-quantity (make-measure n %count-unit) #:has-point-in-time "2026-03-02T12:00:00Z"))))

(define vat (spawn-vat))
(define %svc #f) (define %uc #f) (define %a #f) (define %pending #f) (define b-root #f)
(with-vat vat
  (let* ((a (spawn-scope-root "A")) (b (spawn-scope-root "B"))
         (svc (spawn ^planner-service (hashmap)))
         (oa ($ a 'observer)) (ob ($ b 'observer))
         (asa ($ a 'account-store)) (asb ($ b 'account-store)))
    ;; A: alice 10h, bob 30h, pool 10 loaves (30h)  — test-account's world
    (work! oa "alice" 10 "ea1" "ia1") (work! oa "bob" 30 "eb1" "ib1")
    ($ asa 'credit-from-event ($ oa 'get-event "ea1"))
    ($ asa 'credit-from-event ($ oa 'get-event "eb1"))
    (bread-pool! a 10)
    ;; B: alice again 20h, cy 20h, pool 4 loaves (12h); cy's CCF 0.5
    (work! ob "alice" 20 "ea2" "ia2") (work! ob "cy" 20 "ec1" "ic1")
    ($ asb 'credit-from-event ($ ob 'get-event "ea2"))
    ($ asb 'credit-from-event ($ ob 'get-event "ec1"))
    (bread-pool! b 4)
    ($ asb 'set-ccf "cy" 1/2)

    ($ svc 'add-scope! "A" a)
    ($ svc 'add-scope! "B" b)
    (define uc ($ svc 'credit-uc))

    (display "\n── parity, one scope: the fold's node = the walk over (list A) ──\n")
    (let ((na ($ svc 'credit "A")))
      (check "alice gross" ($ na 'citizen-gross "alice")
             (global-citizen-gross "alice" (list a)))
      (check "context (pool ability-norm) agrees with the walk's (pool svc norm)"
             (list (car ($ na 'context)) (cadr ($ na 'context)))
             (let ((g (global-elastic-context (list a)))) (list (car g) (caddr g))))
      (check "alice effective balance"
             (approx= ($ na 'effective-balance "alice")
                      (global-effective-balance "alice" (list a) #f 0)) #t)
      (check "voice share" ($ na 'voice-share "bob") (voice-share "bob" (list a))))

    (display "\n── two scopes: what ADDS agrees with the walk ──\n")
    (check "alice gross sums across scopes (30) — labour anywhere"
           ($ uc 'citizen-gross "alice") (global-citizen-gross "alice" (list a b)))
    (check "total social svc sums (80)"
           ($ uc 'total-social-svc) (global-total-social-svc (list a b)))
    (check "the pool sums (42)"
           (list-ref ($ uc 'context) 0) (global-embodied-labor-in-pool (list a b)))
    (check "cy's unmet (1−ccf), one assessment, agrees" ($ uc 'citizen-unmet "cy")
           (global-citizen-unmet "cy" (list a b)))
    (check "citizen count agrees (distinct: 3)"
           ($ uc 'citizen-count) (global-citizen-count (list a b)))

    (display "\n── two scopes: a person's need is ONE fact — the decided combine ──\n")
    ;; alice holds an account in A and in B, CCF 1 in both. The fold counts
    ;; her once (met 1+1+½ = 2.5), and the walk IS the fold (credit-cells
    ;; folds each store's cells by the same monoid), so it counts her once too.
    (check "the walk counts alice once, as the fold does: met = 1+1+½ = 2.5"
           (global-sum-met-capacity (list a b)) 5/2)
    ;; the fold counts her once: alice's 30 h at capacity 1, bob's 30 at 1,
    ;; cy's 20 at ½ read as 40 — contribution BY ABILITY, Σ r = 100 (the
    ;; walk, folding the same cells, agrees; a per-scope sum would read
    ;; alice twice)
    (let ((ctx ($ uc 'context)))                 ; (pool ability-norm)
      (check "Σ r = 30 + 30 + 20/½ = 100 — the once-counted person's ability"
             (approx= (list-ref ctx 1) 100) #t)
      (check "cy's 20 h at half capacity read as a full 40"
             (approx= ($ uc 'citizen-ability "cy") 40) #t)
      (check "and the walk's norm is the node's: 100"
             (approx= (list-ref (global-elastic-context (list a b)) 2) 100) #t))
    (check "conservation still holds: Σ claim capacity = pool (42) at f=0.5"
           (approx= (fold + 0 (map (lambda (aid) ($ uc 'total-claim-capacity aid 0.5))
                                   '("alice" "bob" "cy")))
                    (list-ref ($ uc 'context) 0))
           #t)

    (display "\n── the fold hears its writers: no list threaded ──\n")
    ;; the refold is an eventual send (it must see the store AFTER its
    ;; turn), so the writes land here and the reads take the next turn
    ($ asb 'set-ccf "cy" 1/4)
    (work! ob "cy" 5 "ec2" "ic2")
    (set! %svc svc) (set! %uc uc) (set! %a a) (set! b-root b)))

(with-vat vat
  (check "a CCF change climbed: cy's unmet is 3/4 at the UC"
         ($ %uc 'citizen-unmet "cy") 3/4)
  (check "a work event climbed: cy's gross is 25"
         ($ %uc 'citizen-gross "cy") 25)

  (display "\n── the walk's API accepts the node: one call site, either end ──\n")
  (check "global-total-social-svc reads the node" (global-total-social-svc %uc) 85)
  (check "voice-share through the node = the node's own read"
         (voice-share "alice" %uc) ($ %uc 'voice-share "alice"))
  (check "global-effective-balance through the node = the node's own read"
         (global-effective-balance "cy" %uc #f 0.5) ($ %uc 'effective-balance "cy" 0.5))
  (check "consumer-voice through the node: shares over the node's citizens sum to 1"
         (approx= (fold + 0 (map (lambda (aid) (consumer-voice aid %uc)) '("alice" "bob" "cy"))) 1) #t)
  ;; a LEVEL is a recognizing scope-id: the node answers it from its
  ;; stratified cells exactly as the walk does from the gates
  (check "an unknown level reads as 0 on node and walk alike"
         (list (global-total-social-svc %uc "E_nobody")
               (global-total-social-svc (list %a) "E_nobody"))
         '(0 0))

  (display "\n── a LEVEL: the node's stratified cells answer as the walk's gates do ──\n")
  ;; bob works 6h under plan P-reg; the plan is confirmed at level "Regional"
  ;; in A's observer. The stratified read is the credit the gate admits at
  ;; that level — 6 for bob, nothing for alice — on node and walk alike.
  (let ((oa ($ %a 'observer)))
    (work! oa "bob" 6 "eb-reg" "ib-reg" "P-reg")
    ($ oa 'confirm-plan "P-reg" "Regional"))
  (set! %pending 'level))

(with-vat vat
  (check "bob's gross at Regional: 6, node and walk"
         (list (global-citizen-gross "bob" %uc "Regional")
               (global-citizen-gross "bob" (list %a) "Regional"))
         '(6 6))
  (check "alice's gross at Regional: 0 on both"
         (list (global-citizen-gross "alice" %uc "Regional")
               (global-citizen-gross "alice" (list %a) "Regional"))
         '(0 0))
  (check "voice-share at Regional through the node = bob's whole voice there"
         (voice-share "bob" %uc "Regional") 1)
  (check "the universal read still sums everything (bob 36)"
         (global-citizen-gross "bob" %uc) 36)

  (display "\n── refederation carries credit ──\n")
  ($ %svc 'move-scope! "B" "A")
  (check "A's subtree now holds alice's 30 (its own 10 + B's 20)"
         ($ ($ %svc 'credit "A") 'citizen-gross "alice") 30)
  (check "the UC total stands" ($ %uc 'citizen-gross "alice") 30))


;; ── one person, one dividend: a citizen is a witnessed person ────────────
;; The citizenship dividend and N count persons (account.scm person-aid?).
;; With a substrate that knows alice and bob but not cy, cy keeps every credit
;; his work earned and draws no dividend; the node and the walk agree; and a
;; second account of alice's adds no share — the condition `split_no_gain`
;; (Incentives.lean) rests on.
(display "\n── one person, one dividend ──\n")
(with-vat vat
  (let* ((a %a) (uc %uc) (svc %svc))
    (set-person-substrate! (lambda (aid) (member aid '("alice" "bob"))))
    ;; refold BOTH scopes' own cells under the substrate — B is A's child
    ;; here, and a citizen cell combines by max, so a stale child keeps a name
    ($ ($ svc 'credit "A") 'credit-changed a)
    ($ ($ svc 'credit "B") 'credit-changed b-root)
    (check "N counts persons: the walk says 2" (global-citizen-count (list a)) 2)
    (check "…and the node, refolded, agrees" ($ ($ svc 'credit "A") 'citizen-count) 2)
    (check "cy's own credit is untouched (gross 0 here — his work was in B)"
           (global-citizen-gross "cy" (list a)) 0)
    (check "cy draws no dividend at f = 1/2"
           (global-citizenship-share "cy" (list a) 1/2) 0)
    (check "alice's dividend is the fund over TWO persons, not three"
           (approx= (global-citizenship-share "alice" (list a) 1/2)
                    (/ (* (global-embodied-labor-in-pool (list a)) 1/2) 2)) #t)
    (set-person-substrate! #f)
    (check "no substrate wired: every account holder is a person again"
           (global-citizen-count (list a b-root)) 3)))

;; ── household-consumer-voice: the SAME law, no scope tree ────────────────
;; A family reads playnet.typ §The credit identity directly (family.scm
;; family-voice-of, this module's household-consumer-voice): no credit-node,
;; no observer, no priced pool — capacity + hours declared by the household
;; itself. A child who works no hours and holds low capacity to labour still
;; carries real voice through solidarity + citizenship (playnet.typ
;; §Governance: "Everyone — workers, children, the elderly, the unable —
;; carries weight"); it never reads as zero, and two equal members read as
;; equal.
(display "\n── household-consumer-voice: the credit identity, no scope tree ──\n")
(let* ((members (list (list "adult" 1.0 20.0) (list "child" 0.15 0.0)))
       (voices  (household-consumer-voice members #:per-citizen-hours 40.0))
       (v       (lambda (p) (cdr (assoc p voices)))))
  (check "shares sum to one" (approx= (fold + 0 (map cdr voices)) 1) #t)
  (check "the child's voice is real, never zero" (> (v "child") 0) #t)
  (check "the child's voice is a real fraction of the whole (solidarity + citizenship, not a token)"
         (> (v "child") 0.3) #t)
  (check "the contributing adult still carries more" (> (v "adult") (v "child")) #t))

(let* ((equal-members (list (list "ada" 1.0 10.0) (list "ben" 1.0 10.0)))
       (voices (household-consumer-voice equal-members #:per-citizen-hours 40.0)))
  (check "two equal members read as equal voice"
         (approx= (cdr (assoc "ada" voices)) (cdr (assoc "ben" voices))) #t))

(let ((zero-hours-equal-capacity (list (list "ada" 1.0 0.0) (list "ben" 1.0 0.0))))
  (check "nobody worked, same capacity: social free time is full"
         (approx= (household-social-free-time zero-hours-equal-capacity #:per-citizen-hours 40.0) 1) #t)
  (check "…and voice still splits evenly, all through the citizenship dividend"
         (let ((voices (household-consumer-voice zero-hours-equal-capacity #:per-citizen-hours 40.0)))
           (approx= (cdr (assoc "ada" voices)) 1/2))
         #t))

;; ── a citizen's voice is the federation's, not their subtree's ──────────────
;; The demand fold weighs a need by its citizen's voice. Read against the
;; federation's credit node it is one number for the citizen wherever the need
;; sits; read against the subtree the need happens to be in it is a share of
;; that subtree, so the same citizen speaks twice as loudly or half as loudly
;; by where they are asked.
(display "\n── voice: the same citizen, the same voice, wherever the need sits ──\n")
(use-modules ((playnet governance demand-fold) #:select (federation-voice-of)))
(with-vat vat
  (let ((at-a (federation-voice-of %a %uc))
        (at-b (federation-voice-of b-root %uc))
        (local-a (federation-voice-of %a))
        (local-b (federation-voice-of b-root)))
    (check "alice has a voice off the federation's node" (number? (at-a "alice")) #t)
    (check "asked through A or through B, alice's voice is one number"
           (approx= (at-a "alice") (at-b "alice")) #t)
    (check "so is bob's, who works in A alone"
           (approx= (at-a "bob") (at-b "bob")) #t)
    (check "read against the subtree, it is a share of that subtree and differs by scope"
           (approx= (local-a "alice") (local-b "alice")) #f)))

;; ── ONE law: consumer voice is the share of claim capacity ────────────────
;; `consumer-voices-of` (elastic.scm) is read by a federation scope's credit
;; fold and by a household's own members alike. Its properties hold by
;; construction: the voices sum to one, a draw (`claimed`) leaves them where
;; they were, and an empty pool leaves the share undefined.
(display "\n── consumer voice: one law over cells, drawdown outside it ──\n")
(use-modules ((playnet planner algorithms elastic) #:select (consumer-voices-of effective-balance)))
(let* ((member-cells (lambda (m) (list (cons (cons 'gross (car m)) (cadr m))
                                       (cons (cons 'ccf (car m)) (caddr m))
                                       (cons (cons 'citizen (car m)) 1))))
       (cells (lambda (pool claimed . ms)
                (append (list (cons '(pool . *) pool))
                        (append-map member-cells ms)
                        (map (lambda (c) (cons (cons 'claimed (car c)) (cdr c))) claimed))))
       (ada '("ada" 10 1)) (ben '("ben" 30 1))
       (undrawn (consumer-voices-of (cells 40 '() ada ben) 0))
       (drawn   (consumer-voices-of (cells 40 '(("ada" . 7)) ada ben) 0)))
  (check "the voices sum to one"
         (approx= (fold + 0 (map cdr undrawn)) 1) #t)
  (check "contribution by ability: ada 10 h of 40, ben 30 of 40"
         (and (approx= (assoc-ref undrawn "ada") 1/4) (approx= (assoc-ref undrawn "ben") 3/4)) #t)
  (check "a draw leaves every voice where it was"
         (and (approx= (assoc-ref drawn "ada") (assoc-ref undrawn "ada"))
              (approx= (assoc-ref drawn "ben") (assoc-ref undrawn "ben")))
         #t)
  (check "Σ drawable credit = the pool as it stands, claims or none (conservation)"
         (and (approx= (fold + 0 (map (lambda (a) (effective-balance (cells 40 '() ada ben) a 0)) '("ada" "ben"))) 40)
              (approx= (fold + 0 (map (lambda (a) (effective-balance (cells 40 '(("ada" . 7)) ada ben) a 0)) '("ada" "ben"))) 40))
         #t)
  (check "an empty pool leaves the share undefined: '()"
         (consumer-voices-of (cells 0 '() ada ben) 0) '())
  (check "a household where nobody has worked still sums to one under f = 1/2"
         (approx= (fold + 0 (map cdr (household-consumer-voice (list (list "ada" 1.0 0.0) (list "ben" 1.0 0.0))
                                                                 #:per-citizen-hours 40.0 #:f 0.5)))
                  1)
         #t))

(test-summary!)
