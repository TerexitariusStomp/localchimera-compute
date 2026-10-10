;;; test-account.scm — Commune labor-credit accounting (universal model)
;;;
;;; Verifies:
;;;   - Labor crediting from 'work events (cached in account record)
;;;   - Credit balance DERIVED from observer event log
;;;   - Claim as VF 'transfer event (rights + custody move to citizen)
;;;   - CCF mutation via set-ccf
;;;   - Pool as derived query over observer resources
;;;   - Universal credit balance across multiple scopes
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l planner/load-all.scm -l tests/planner/test-account.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet planner algorithms elastic) (playnet planner pools credit-fold) (playnet planner scope root) (playnet planner vf schemas) (playnet planner observation states))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))


(use-modules ((playnet planner observation account) #:select (declare-claimable!)))
(use-modules ((playnet test scope) #:select (plan-claim!)))   ; the plan's row, stood by the fixture
(use-modules ((playnet test scope) #:select (record-work!)))
;; the rail is read off the recipes: this fixture stands in for the plan and
;; declares that a claim recipe stands for spec-bread (account.scm spec-claimable?)
(declare-claimable! "spec-bread")

(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))

;;; Helper: register a recipient-side intent for `hours` of labor and
;;; record a work event that fully satisfies it. Validation Gate
;;; (§III.1) anchors on intent-satisfaction — the recipient declares
;;; the need, the event meets it. These tests exercise the elastic
;;; math on the assumption of full satisfaction (fraction=1.0).
;;; Optional PLAN-ID sets the intent's planned-within field, which
;;; the observer mirrors onto satisfaction-state and joins through
;;; for federation-stratified credits (§14).
(define* (record-satisfying-work! obs aid hours event-id intent-id
                                  #:optional plan-id)
  (record-work! obs aid hours event-id intent-id #:plan-id plan-id))

;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define mem-store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Account Test"))
    mem-store))

(with-vat vat
  (check-pred "setup ok" #t))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Default initialization
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Default initialization ──\n")

(with-vat vat
  (let ((as ($ scope 'account-store)))
    (check "ability norm = 0 (no accounts)" ($ as 'ability-norm) 0)
    (check "all-accounts empty" (length ($ as 'all-accounts)) 0)
    (check "pool-resources empty" (length ($ as 'pool-resources)) 0)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Account creation (CCF defaults to 1)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Account CRUD ──\n")

(with-vat vat
  (let ((as ($ scope 'account-store)))
    ($ as 'ensure-account "alice")
    ($ as 'ensure-account "bob")
    (check "all-accounts = 2" (length ($ as 'all-accounts)) 2)
    (let ((alice ($ as 'get-account "alice")))
      (check-pred "alice exists" (account? alice))
      (check "alice agent-id" (account-agent-id alice) "alice")
      (check "alice claimed = 0" (account-claimed-capacity alice) 0)
      (check "alice CCF = 1" (account-contribution-capacity-factor alice) 1))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. set-ccf: governance-mutable capacity factor
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── set-ccf ──\n")

(with-vat vat
  (let ((as ($ scope 'account-store)))
    ($ as 'set-ccf "alice" 0.5)
    (check "alice CCF = 0.5"
           (account-contribution-capacity-factor ($ as 'get-account "alice"))
           0.5)
    ;; Restore to 1 for downstream tests
    ($ as 'set-ccf "alice" 1)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Credit balance DERIVED from observer events
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Credit balance from events ──\n")

(define mem-store-2 (make-memory-store))
(define-values (vat2 scope2)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Credit Test"))
    mem-store-2))

(with-vat vat2
  (let ((obs ($ scope2 'observer))
        (as  ($ scope2 'account-store)))

    ;; Each work event fulfills a committed plan (§III.1 Validation Gate).
    (record-satisfying-work! obs "alice" 10 "ev-alice-work-1" "int-alice-10h")
    (record-satisfying-work! obs "bob"   30 "ev-bob-work-1"   "int-bob-30h")

    ;; credit-from-event no longer writes a cache; still fires the
    ;; on-work callback. Ensures account rows exist for CCF tracking.
    ($ as 'credit-from-event ($ obs 'get-event "ev-alice-work-1"))
    ($ as 'credit-from-event ($ obs 'get-event "ev-bob-work-1"))

    (check "alice balance = 10 (derived)" ($ as 'credit-balance "alice") 10)
    (check "bob balance = 30 (derived)"   ($ as 'credit-balance "bob")   30)
    (check "total social svc cache = 40"  ($ as 'total-social-svc)       40)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Claim as VF transfer event
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Claim as transfer event ──\n")

(with-vat vat2
  (let ((obs ($ scope2 'observer))
        (rs  ($ scope2 'recipe-store))
        (as  ($ scope2 'account-store)))

    ;; Seed a bread recipe so SNLT can be computed.
    ;; 3 work-hours per loaf = SNLT of 3.
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake"
                            #:has-duration (make-duration 3 %effort-unit)))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-work" #:action 'work #:resource-conforms-to "spec-labor"
                         #:effort-quantity (make-measure 3 %effort-unit) #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-out" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-bake"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-bread" #:name "Bread Recipe" #:primary-output "spec-bread"
                    #:recipe-processes (list "rp-bake")))

    ;; Produce bread: individually-claimable, accountable to the commune.
    ;; Pool (embodied labor) = 10 loaves × 3hr SNLT = 30hr.
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-bread-produced" #:action 'produce
         #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
         #:resource-classified-as (list "individually-claimable")
         #:provider "commune" #:receiver "commune"
         #:resource-quantity (make-measure 10 %count-unit) #:has-point-in-time "2026-03-02T12:00:00Z"))

    (check "pool has bread" (= 1 (length ($ as 'pool-resources))))
    (check-pred "embodied labor = 30 hr" (= 30 ($ as 'embodied-labor-in-pool)))

    ;; With alice=10hr, bob=30hr, total=40hr, pool=30hr, CCF=1 for all:
    ;;   welfare_rate = 0, available = 30
    ;;   alice's contribution_claim = (10/40) × 30 = 7.5hr
    ;;   alice effective-balance = 7.5 (claimed=0 so far)
    (check-pred "alice effective balance = 7.5"
                (= 15/2 ($ as 'effective-balance "alice")))

    ;; ── Citizenship dividend: social free time f folds an equal share into
    ;; drawable credit (playnet.typ §The credit identity). pool=30, N=2 →
    ;; citizenship = pool·f/N = 15f; contribution scales by (1−f):
    ;;   alice = (1−f)·7.5 + 15f ;  bob = (1−f)·22.5 + 15f
    (check-pred "f=0: alice drawable = 7.5 (no free time → no dividend)"
                (approx= (global-effective-balance "alice" (list scope2) #f 0) 7.5))
    (check-pred "f=0.5: alice drawable = 11.25 (contribution + citizenship blend)"
                (approx= (global-effective-balance "alice" (list scope2) #f 0.5) 11.25))
    (check-pred "f=1: alice drawable = 15 (fully equal, pool/N)"
                (approx= (global-effective-balance "alice" (list scope2) #f 1) 15))
    (check-pred "f=1: bob drawable = 15 too — converged to an equal share"
                (approx= (global-effective-balance "bob" (list scope2) #f 1) 15))
    (check-pred "conservation: Σ drawable = pool (30) at f=0.5"
                (approx= (+ (global-effective-balance "alice" (list scope2) #f 0.5)
                            (global-effective-balance "bob"   (list scope2) #f 0.5)) 30))
    (check-pred "social free time f = 1 − L/(N·T): L=40 N=2 T=1000 → 0.98"
                (approx= (global-social-free-time (list scope2) 1000) 0.98))
    (check-pred "consumer-voice with a horizon folds citizenship toward equal"
                ;; high f → alice's share pulled toward 1/N = 0.5 (from 0.25 labour)
                (let ((cv (consumer-voice "alice" (list scope2) #f 1000)))
                  (and cv (approx= cv 0.495 0.02))))

    ;; ── Enabled by default: the live plan solve publishes f (set-social-free-
    ;; time!), so drawable credit folds in citizenship with NO explicit arg.
    (set-social-free-time! 0.5)
    (check-pred "published f=0.5 → default drawable folds in citizenship (11.25)"
                (approx= (global-effective-balance "alice" (list scope2)) 11.25))
    (check-pred "current-social-free-time reflects the published value"
                (approx= (current-social-free-time) 0.5))
    (set-social-free-time! 0)   ; reset so the base-model claim below is unaffected

    ;; The ledger admits a transfer only against the plan's own claim row for
    ;; THIS good and THIS citizen (account.scm claim): a commitment of another
    ;; kind, however ample, and a claim row for another good are both refused,
    ;; and the citizen is read off the row, so a row minted for bob admits
    ;; nothing when alice presents it.
    (let ((bogus (make-commitment #:id "wc~bogus-alice" #:action 'transfer #:resource-conforms-to "spec-bread"
                                  #:resource-quantity (make-measure 10 %count-unit) #:receiver "alice" #:in-scope-of (list "scope2"))))
      ($ obs 'register-commitment bogus)
      (check "a non-claim commitment admits no claim, however ample"
             (catch #t
               (lambda () ($ as 'claim "r-bread" 1 "alice" 3 (list scope2) #f #f #f "wc~bogus-alice") 'admitted)
               (lambda (k . args) 'refused))
             'refused)
      (check "a claim row for another good admits no claim of this one"
             (catch #t
               (lambda () ($ as 'claim "r-bread" 1 "alice" 3 (list scope2) #f #f #f
                             (plan-claim! obs "spec-cake" "alice" 1))
                          'admitted)
               (lambda (k . args) 'refused))
             'refused)
      (check "a claim row minted for another citizen admits nothing when presented by this one"
             (catch #t
               (lambda () ($ as 'claim "r-bread" 1 "alice" 3 (list scope2) #f #f #f
                             (plan-claim! obs "spec-bread" "bob" 1))
                          'admitted)
               (lambda (k . args) 'refused))
             'refused))

    ;; Alice claims 2 loaves at 3hr SNLT each = 6hr labor cost.
    ;; Her elastic share (7.5) covers it.
    (let ((result ($ as 'claim "r-bread" 2 "alice" 6 (list scope2)
                      #f #f #f (plan-claim! obs "spec-bread" "alice" 2))))   ; the plan's row
      (check "claim succeeds" result #t))

    (let ((bread ($ obs 'get-resource "r-bread"))
          (alice-bread ($ obs 'get-resource "r-bread-alice")))
      (check "source bread accounting = 8"
             (measure-has-numerical-value
               (economic-resource-accounting-quantity bread))
             8)
      (check "source bread still commune-accountable"
             (economic-resource-primary-accountable bread) "commune")
      (check "alice-bread accounting = 2"
             (measure-has-numerical-value
               (economic-resource-accounting-quantity alice-bread))
             2)
      (check "alice-bread accountable = alice"
             (economic-resource-primary-accountable alice-bread) "alice"))

    ;; Raw credit-balance (from observer event log): work hours minus
    ;; claimed labor-cost. Used for governance voice.
    (check "alice raw balance = 4 (10 - 6)" ($ as 'credit-balance "alice") 4)
    (check "bob raw balance = 30 (unchanged)" ($ as 'credit-balance "bob") 30)

    ;; A claim moves goods out of the pool and leaves the whole the shares are
    ;; shares of where it was (entitlement pool = pool as it stands + claimed):
    ;;   pool = 8 loaves × 3hr = 24hr after the claim, 6hr claimed → whole = 30hr
    ;;   alice: (10/40) × 30 = 7.5 entitled, 6 claimed → 1.5 left
    ;;   bob:   (30/40) × 30 = 22.5 entitled, 0 claimed → 22.5
    (check-pred "alice effective balance = 1.5 after claim (7.5 entitled − 6 drawn)"
                (approx= 1.5 ($ as 'effective-balance "alice")))
    (check-pred "bob effective balance = 22.5 after alice's claim: his share is untouched"
                (approx= 22.5 ($ as 'effective-balance "bob")))
    ;; and the credit left is exactly the goods left: Σ drawable = the pool
    (check-pred "Σ drawable credit = the pool as it stands (24hr)"
                (approx= 24 (+ ($ as 'effective-balance "alice") ($ as 'effective-balance "bob"))))

    ;; Drawdown is the balance's, never the voice's (§The credit identity,
    ;; glossary Drawdown): alice drew down to 0 and her consumer voice stays
    ;; her contribution share, 10/40, as bob's stays 30/40 — the shares are
    ;; the claim capacities over their total, with `claimed` kept out of them.
    (check-pred "alice's consumer voice is unchanged by her draw: 10/40 of the pool"
                (approx= (consumer-voice "alice" (list scope2)) 1/4))
    (check-pred "bob's consumer voice is unchanged too: 30/40"
                (approx= (consumer-voice "bob" (list scope2)) 3/4))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Claim fails: insufficient balance
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Claim fails if balance insufficient ──\n")

(define mem-store-3 (make-memory-store))
(define-values (vat3 scope3)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Insufficient Test"))
    mem-store-3))

(with-vat vat3
  (let ((obs ($ scope3 'observer))
        (rs  ($ scope3 'recipe-store))
        (as  ($ scope3 'account-store)))

    ;; Recipe: 1hr work per loaf, SNLT = 1.
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake"
                            #:has-duration (make-duration 1 %effort-unit)))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-work" #:action 'work #:resource-conforms-to "spec-labor"
                         #:effort-quantity (make-measure 1 %effort-unit) #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-out" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-bake"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-bread" #:name "Bread" #:primary-output "spec-bread"
                    #:recipe-processes (list "rp-bake")))

    ;; Alice works 2 hours; Bob works 6 hours. Pool = 5 loaves × 1hr = 5hr.
    ;; Alice's elastic share = (2/8) × 5 = 1.25hr. Claiming 5hr must fail.
    (record-satisfying-work! obs "alice" 2 "ev-w-alice" "int-alice-2h")
    (record-satisfying-work! obs "bob"   6 "ev-w-bob"   "int-bob-6h")

    ($ obs 'record-event
       (make-economic-event
         #:id "ev-b" #:action 'produce
         #:resource-inventoried-as "r-bread-2" #:resource-conforms-to "spec-bread"
         #:resource-classified-as (list "individually-claimable")
         #:provider "commune" #:receiver "commune"
         #:resource-quantity (make-measure 5 %count-unit) #:has-point-in-time "2026-03-02T12:00:00Z"))

    ;; Alice's effective = 1.25. Claiming 5hr must raise.
    (check "elastic share catches shortfall"
           (catch #t
             (lambda () ($ as 'claim "r-bread-2" 5 "alice" 5 (list scope3)
                           #f #f #f (plan-claim! obs "spec-bread" "alice" 5)) 'no-error)
             (lambda _ 'insufficient))
           'insufficient)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Claim fails: resource not individually-claimable
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Claim fails if resource not individually-claimable ──\n")

(with-vat vat3
  (let ((obs ($ scope3 'observer))
        (as  ($ scope3 'account-store)))

    ;; Untagged infrastructure resource (no classified-as)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-infra" #:action 'produce
         #:resource-inventoried-as "r-sensor" #:resource-conforms-to "spec-sensor"
         #:provider "commune" #:receiver "commune"
         #:resource-quantity (make-measure 1 %count-unit) #:has-point-in-time "2026-03-02T12:00:00Z"))

    (check "infra not in pool" (= 1 (length ($ as 'pool-resources))))

    (check "claim on non-claimable raises"
           (catch #t
             (lambda () ($ as 'claim "r-sensor" 1 "alice" 1 (list scope3)) 'no-error)
             (lambda _ 'rejected))
           'rejected)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Universal credit balance across scopes
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Universal credit balance across scopes ──\n")

(define mem-u1 (make-memory-store))
(define mem-u2 (make-memory-store))
(define-values (vat-u1 scope-u1)
  (spawn-persistent-vat scope-root-env
    (lambda () (spawn-scope-root "Watershed")) mem-u1))
(define-values (vat-u2 scope-u2)
  (spawn-persistent-vat scope-root-env
    (lambda () (spawn-scope-root "Tech Coop")) mem-u2))

;; Alice works 10h in watershed
(with-vat vat-u1
  (record-satisfying-work! ($ scope-u1 'observer) "alice" 10 "ev-u1" "int-u1"))

;; Alice works 5h in tech coop
(with-vat vat-u2
  (record-satisfying-work! ($ scope-u2 'observer) "alice" 5 "ev-u2" "int-u2"))

;; Per-scope balances
(with-vat vat-u1
  (check "watershed balance = 10"
         ($ ($ scope-u1 'account-store) 'credit-balance "alice") 10))
(with-vat vat-u2
  (check "tech-coop balance = 5"
         ($ ($ scope-u2 'account-store) 'credit-balance "alice") 5))

;; Universal: sum across scopes (same-process, so call in each vat)
;; For cross-vat aggregation in production, the caller invokes
;; universal-credit-balance in a context that can resolve each ref.
(with-vat vat-u1
  (check "universal balance contains watershed slice"
         ($ ($ scope-u1 'account-store) 'credit-balance "alice") 10))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. Welfare allocation rate with mixed CCFs
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Welfare rate with mixed CCFs ──\n")

(define mem-w (make-memory-store))
(define-values (vat-w scope-w)
  (spawn-persistent-vat scope-root-env
    (lambda () (spawn-scope-root "Welfare Test")) mem-w))

(with-vat vat-w
  (let ((as ($ scope-w 'account-store)))
    ($ as 'ensure-account "alice")
    ($ as 'ensure-account "bob")
    ;; contribution BY ABILITY: nobody has worked, so every r is 0
    (check "all CCF=1, no hours → ability norm 0" ($ as 'ability-norm) 0)

    ;; Bob fully incapacitated: he has given all he could — the standard, the
    ;; mean of those who can (alice: 0 h) — so still 0
    ($ as 'set-ccf "bob" 0)
    (check "bob at CCF 0 reads as the standard: alice's 0" ($ as 'citizen-ability "bob") 0)

    ;; Both fully incapacitated: nobody can, so each is one — an equal share
    ($ as 'set-ccf "alice" 0)
    (check "all CCF=0 → each reads 1, norm 2" ($ as 'ability-norm) 2)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 10. Solidarity supplement: CCF=0 citizen draws welfare-funded share
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Solidarity supplement with mixed CCFs ──\n")

(define mem-sol (make-memory-store))
(define-values (vat-sol scope-sol)
  (spawn-persistent-vat scope-root-env
    (lambda () (spawn-scope-root "Solidarity Test")) mem-sol))

(with-vat vat-sol
  (let ((obs ($ scope-sol 'observer))
        (rs  ($ scope-sol 'recipe-store))
        (as  ($ scope-sol 'account-store)))

    ;; Same recipe as before: SNLT = 3 hr/loaf.
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake"
                            #:has-duration (make-duration 3 %effort-unit)))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-work" #:action 'work #:resource-conforms-to "spec-labor"
                         #:effort-quantity (make-measure 3 %effort-unit) #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-out" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-bake"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-bread" #:name "Bread" #:primary-output "spec-bread"
                    #:recipe-processes (list "rp-bake")))

    ;; Alice works 10hr, CCF=1 (fully capable).
    ;; Grandma has CCF=0 (cannot work), 0 raw hours.
    (record-satisfying-work! obs "alice" 10 "ev-alice-work" "int-alice-10h")
    ($ as 'credit-from-event ($ obs 'get-event "ev-alice-work"))
    ($ as 'ensure-account "grandma")
    ($ as 'set-ccf "grandma" 0)

    ;; Pool: 4 loaves × 3 = 12 hr embodied labor.
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-bread" #:action 'produce
         #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
         #:resource-classified-as (list "individually-claimable")
         #:provider "commune" #:receiver "commune"
         #:resource-quantity (make-measure 4 %count-unit) #:has-point-in-time "2026-03-02"))

    ;; Derivations:
    ;;   total-svc = 10 (alice only)
    ;;   contribution BY ABILITY: alice r = 10/1 = 10; grandma (CCF 0) has
    ;;   given all she could — the standard, the mean r of those who can = 10
    ;;   Σ r = 20, pool = 12 → each 12 × 10/20 = 6
    (check-pred "grandma's ability reads as the standard, 10" (= 10 ($ as 'citizen-ability "grandma")))
    (check-pred "embodied labor = 12"   (= 12  ($ as 'embodied-labor-in-pool)))
    (check-pred "alice effective = 6"   (= 6   ($ as 'effective-balance "alice")))
    (check-pred "grandma effective = 6" (= 6   ($ as 'effective-balance "grandma")))

    ;; Grandma, despite never working, can claim 2 loaves (6 hr SNLT cost).
    (let ((result ($ as 'claim "r-bread" 2 "grandma" 6 (list scope-sol)
                      #f #f #f (plan-claim! obs "spec-bread" "grandma" 2))))   ; the plan's row
      (check "grandma's solidarity-funded claim succeeds" result #t))
    (check-pred "grandma effective = 0 after claim"
                (= 0 ($ as 'effective-balance "grandma")))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 11. effective-price inflates under pool scarcity (Option B display)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Effective price (Option B display) ──\n")

(define mem-p (make-memory-store))
(define-values (vat-p scope-p)
  (spawn-persistent-vat scope-root-env
    (lambda () (spawn-scope-root "Price Test")) mem-p))

(with-vat vat-p
  (let ((obs ($ scope-p 'observer))
        (rs  ($ scope-p 'recipe-store))
        (as  ($ scope-p 'account-store)))

    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake"
                            #:has-duration (make-duration 2 %effort-unit)))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-work" #:action 'work #:resource-conforms-to "spec-labor"
                         #:effort-quantity (make-measure 2 %effort-unit) #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-out" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-bake"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-bread" #:name "Bread" #:primary-output "spec-bread"
                    #:recipe-processes (list "rp-bake")))

    ;; Total labor = 20hr, pool = 5 loaves × 2 = 10hr. k = 10/20 = 0.5.
    ;; SNLT = 2hr/loaf. Effective price inflated by 1/k = 2×:
    ;;   effective-price(bread, 1) = 1 × 2 × (20/10) = 4hr
    (record-satisfying-work! obs "worker" 20 "ev-w" "int-w-20h")
    ($ as 'credit-from-event ($ obs 'get-event "ev-w"))
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-b" #:action 'produce
         #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
         #:resource-classified-as (list "individually-claimable")
         #:provider "commune" #:receiver "commune"
         #:resource-quantity (make-measure 5 %count-unit) #:has-point-in-time "2026-03-02"))

    (check-pred "embodied labor = 10" (= 10 ($ as 'embodied-labor-in-pool)))
    ;; Raw SNLT for 1 loaf = 2. Elastic price = 2 × (20/10) = 4.
    (check-pred "effective-price of 1 loaf = 4 (2× inflated)"
                (= 4 ($ as 'effective-price "spec-bread" 1)))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 12. Voice-share: pure labor proportion, CCF-independent
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Voice-share (pure labor proportion) ──\n")

(define mem-v (make-memory-store))
(define-values (vat-v scope-v)
  (spawn-persistent-vat scope-root-env
    (lambda () (spawn-scope-root "Voice Test")) mem-v))

(with-vat vat-v
  (let ((obs ($ scope-v 'observer))
        (as  ($ scope-v 'account-store)))

    ;; Alice works 10hr (CCF=1), Bob works 30hr (CCF=1),
    ;; Grandma CCF=0 with 0 hours.
    (record-satisfying-work! obs "alice" 10 "ev-a" "int-a-10h")
    ($ as 'credit-from-event ($ obs 'get-event "ev-a"))
    (record-satisfying-work! obs "bob"   30 "ev-b" "int-b-30h")
    ($ as 'credit-from-event ($ obs 'get-event "ev-b"))
    ($ as 'ensure-account "grandma")
    ($ as 'set-ccf "grandma" 0)

    (let ((scopes (list scope-v)))
      ;; voice-share = gross / total_svc, nothing else
      (check-pred "alice voice-share = 10/40 = 1/4"
                  (= 1/4 (voice-share "alice" scopes)))
      (check-pred "bob voice-share = 30/40 = 3/4"
                  (= 3/4 (voice-share "bob" scopes)))
      ;; Grandma has CCF=0 and zero gross → zero voice.
      ;; Solidarity supplement does NOT give her political voice.
      (check-pred "grandma voice-share = 0 (despite CCF=0)"
                  (= 0 (voice-share "grandma" scopes)))

      ;; Shares sum to 1 across all workers (grandma contributes 0).
      (check-pred "voice-shares sum to 1"
                  (= 1 (+ (voice-share "alice" scopes)
                          (voice-share "bob" scopes)
                          (voice-share "grandma" scopes)))))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 13. Multi-scope global elastic: work in A, claim from B
;;; ════════════════════════════════════════════════════════════════════════════
;;;
;;; Both scopes in the SAME vat: global-* functions use synchronous $ which
;;; requires the scopes be near-referenced. Cross-vat federation would use
;;; `<-` (async) and return promises; that's a later architectural pass.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Multi-scope global: work in A, claim from B ──\n")

;; Use a plain vat — persistent-vat requires a single actor as root.
(define vat-fed (spawn-vat))
(define-values (scope-a scope-b)
  (with-vat vat-fed
    (values (spawn-scope-root "Watershed")
            (spawn-scope-root "Bakery"))))

;; Alice works 10hr in scope-a (no bread there).
;; Scope-B gets a bread recipe + 5 loaves (no work done there by alice).
(with-vat vat-fed
  (let ((obs-a ($ scope-a 'observer))
        (as-a  ($ scope-a 'account-store))
        (obs-b ($ scope-b 'observer))
        (rs-b  ($ scope-b 'recipe-store)))
    (record-satisfying-work! obs-a "alice" 10 "ev-w" "int-w-10h")
    ($ as-a 'credit-from-event ($ obs-a 'get-event "ev-w"))

    ($ rs-b 'add-recipe-process
       (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake"
                            #:has-duration (make-duration 3 %effort-unit)))
    ($ rs-b 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-work" #:action 'work #:resource-conforms-to "spec-labor"
                         #:effort-quantity (make-measure 3 %effort-unit) #:recipe-input-of "rp-bake"))
    ($ rs-b 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-out" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-bake"))
    ($ rs-b 'add-recipe
       (make-recipe #:id "recipe-bread" #:name "Bread" #:primary-output "spec-bread"
                    #:recipe-processes (list "rp-bake")))
    ($ obs-b 'record-event
       (make-economic-event
         #:id "ev-bread" #:action 'produce
         #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread" #:resource-classified-as (list "individually-claimable")
         #:provider "commune" #:receiver "commune"
         #:resource-quantity (make-measure 5 %count-unit) #:has-point-in-time "2026"))))

;; Globally:
;;   total-svc = 10 (alice, from scope-a)
;;   pool      = 15hr (5 loaves × 3hr SNLT, in scope-b)
;;   welfare   = 0 (no CCF<1)
;;   alice contribution_claim = (10/10) × 15 = 15
;;   alice effective-balance  = 15
(with-vat vat-fed
  (let ((scopes (list scope-a scope-b)))
    (check-pred "global total-svc = 10"
                (= 10 (global-total-social-svc scopes)))
    (check-pred "global pool = 15"
                (= 15 (global-embodied-labor-in-pool scopes)))
    (check-pred "alice global effective-balance = 15"
                (= 15 (global-effective-balance "alice" scopes)))

    ;; Alice claims 1 loaf (3hr) from scope-b. Validates against GLOBAL balance.
    (let ((as-b ($ scope-b 'account-store)))
      (let ((result ($ as-b 'claim "r-bread" 1 "alice" 3 scopes
                        #f #f #f (plan-claim! ($ scope-b 'observer) "spec-bread" "alice" 1))))   ; the plan's row
        (check "alice claims scope-B bread using scope-A labor" result #t))
      (let ((bread ($ ($ scope-b 'observer) 'get-resource "r-bread")))
        (check "scope-B bread = 4 after claim"
               (= 4 (measure-has-numerical-value
                      (economic-resource-accounting-quantity bread))))))

    ;; Global effective-balance: alice's whole share was 15, she spent 3 → 12 left,
    ;; exactly the loaves that remain. Entitlement pool = 12 (pool) + 3 (claimed) = 15;
    ;; her share (10/10) × 15 = 15, claimed = 3 (in scope-b); effective = 15 - 3 = 12.
    (check-pred "alice global effective = 12 after claim (15 − 3): the pool that remains"
                (approx= 12 (global-effective-balance "alice" scopes)))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 14. Federation stratification: plan-confirmation universalizes credits
;;; ════════════════════════════════════════════════════════════════════════════
;;;
;;; Only leaves are real scopes; internal federation nodes are planning
;;; aggregators. Credits are born at the leaf where the satisfied intent
;;; lives. A plan carries the validation set: scope-ids that have
;;; confirmed it. An intent inherits its plan's validation. Voice/credit
;;; at federation level L counts only credits whose satisfied intent is
;;; in a plan confirmed at L.
;;;
;;; Setup: alice satisfies a Bakery-local intent registered under plan
;;; "P-spring", which starts validated-at ("Bakery"). At Regional voice
;;; should be 0; after Regional confirms the plan, Regional voice
;;; matches Bakery voice.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Plan-confirmation universalizes credits ──\n")

(define vat-strat (spawn-vat))
(define-values (bakery watershed regional)
  (with-vat vat-strat
    (values (spawn-scope-root "Bakery")
            (spawn-scope-root "Watershed")
            (spawn-scope-root "Regional"))))

(with-vat vat-strat
  (let ((obs-bakery ($ bakery 'observer))
        (as-bakery  ($ bakery 'account-store))
        (obs-water  ($ watershed 'observer))
        (as-water   ($ watershed 'account-store)))

    ;; Alice satisfies a Bakery intent for 10hr (intent.planned-within =
    ;; "P-spring"); bob satisfies a Watershed intent for 30hr (.planned-within =
    ;; "P-flow"). Each leaf explicitly confirms its own plan; neither has
    ;; been lifted to Regional yet.
    (record-satisfying-work! obs-bakery "alice" 10 "ev-a" "I-bread" "P-spring")
    ($ as-bakery 'credit-from-event ($ obs-bakery 'get-event "ev-a"))
    ($ obs-bakery 'confirm-plan "P-spring" "Bakery")

    (record-satisfying-work! obs-water "bob" 30 "ev-b" "I-water" "P-flow")
    ($ as-water 'credit-from-event ($ obs-water 'get-event "ev-b"))
    ($ obs-water 'confirm-plan "P-flow" "Watershed")

    (let ((scopes (list bakery watershed regional)))

      ;; Unfiltered: alice has 10/40 = 1/4 voice (existing semantics).
      (check-pred "unfiltered: alice voice = 1/4"
                  (= 1/4 (voice-share "alice" scopes)))
      (check-pred "unfiltered: alice global gross = 10"
                  (= 10 (global-citizen-gross "alice" scopes)))

      ;; At Bakery: P-spring is validated-at Bakery, so alice's credit
      ;; counts here. Bob's plan is Watershed-only, so his credit is 0
      ;; at Bakery — total-svc = 10, alice voice = 1.
      (check-pred "Bakery: alice voice = 1 (only her credit counts)"
                  (= 1 (voice-share "alice" scopes "Bakery")))
      (check-pred "Bakery: bob voice = 0 (his plan unconfirmed here)"
                  (= 0 (voice-share "bob" scopes "Bakery")))

      ;; At Regional: no plan has been confirmed there yet — total-svc
      ;; is 0, voice is 0 by the (= 0 total) guard.
      (check-pred "Regional: alice voice = 0 pre-confirmation"
                  (= 0 (voice-share "alice" scopes "Regional")))
      (check-pred "Regional: total-svc = 0 pre-confirmation"
                  (= 0 (global-total-social-svc scopes "Regional")))

      ;; Regional confirms P-spring — alice's credit is now lifted up.
      ($ obs-bakery 'confirm-plan "P-spring" "Regional")

      (check-pred "Regional: alice voice = 1 post-confirmation"
                  (= 1 (voice-share "alice" scopes "Regional")))
      (check-pred "Regional: alice global gross = 10 post-confirmation"
                  (= 10 (global-citizen-gross "alice" scopes "Regional")))
      (check-pred "Regional: bob voice still 0 (P-flow not confirmed)"
                  (= 0 (voice-share "bob" scopes "Regional")))

      ;; Confirm bob's plan too — both voices share Regional now.
      ($ obs-water 'confirm-plan "P-flow" "Regional")
      (check-pred "Regional: alice voice = 10/40 after both confirmed"
                  (= 1/4 (voice-share "alice" scopes "Regional")))
      (check-pred "Regional: bob voice = 30/40 after both confirmed"
                  (= 3/4 (voice-share "bob" scopes "Regional")))
      (check-pred "Regional: voices sum to 1 across confirmed plans"
                  (= 1 (+ (voice-share "alice" scopes "Regional")
                          (voice-share "bob" scopes "Regional")))))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 15. Federation universality: intent-rail recognises loose work
;;; ════════════════════════════════════════════════════════════════════════════
;;;
;;; The plan rail (§14) covers coordinated contribution via plan-
;;; confirmation. The intent rail handles the loose-intent case —
;;; uncoordinated work that the planner never bound to a plan.
;;; Both rails feed `intent-counts-at?` through the same chokepoint
;;; (validated-gross), so weighting and Credit validity share a
;;; single universality measure: the union of plan- and intent-
;;; recognitions by the federation level.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Intent-recognition universalizes loose work ──\n")

(define vat-loose (spawn-vat))
(define-values (mutual regional-2)
  (with-vat vat-loose
    (values (spawn-scope-root "MutualAid")
            (spawn-scope-root "Region2"))))

(with-vat vat-loose
  (let ((obs-mut ($ mutual 'observer))
        (as-mut  ($ mutual 'account-store)))

    ;; Carla logs 12hr satisfying a LOOSE intent (no plan-id) — the
    ;; kind of work that real solidarity systems struggle to weigh
    ;; because it never sat inside a plan. The leaf still
    ;; participates: it self-recognises the intent.
    (record-satisfying-work! obs-mut "carla" 12 "ev-c" "I-loose-care")
    ($ as-mut 'credit-from-event ($ obs-mut 'get-event "ev-c"))
    ($ obs-mut 'recognize-intent "I-loose-care" "MutualAid")

    (let ((scopes (list mutual regional-2)))

      ;; Universal baseline (level=#f): loose work still counts.
      (check-pred "loose: unfiltered carla voice = 1"
                  (= 1 (voice-share "carla" scopes)))
      (check-pred "loose: unfiltered carla gross = 12"
                  (= 12 (global-citizen-gross "carla" scopes)))

      ;; At MutualAid: the leaf recognised the intent directly.
      (check-pred "MutualAid: carla voice = 1 via intent-rail"
                  (= 1 (voice-share "carla" scopes "MutualAid")))
      (check-pred "MutualAid: carla gross = 12 via intent-rail"
                  (= 12 (global-citizen-gross "carla" scopes "MutualAid")))

      ;; At Region2: no recognition yet — intent rail empty.
      (check-pred "Region2: carla voice = 0 pre-recognition"
                  (= 0 (voice-share "carla" scopes "Region2")))

      ;; Region2 ratifies the loose contribution: same predicate
      ;; gates voice and Credit, so both flow at once.
      ($ obs-mut 'recognize-intent "I-loose-care" "Region2")
      (check-pred "Region2: carla voice = 1 post-recognition"
                  (= 1 (voice-share "carla" scopes "Region2")))
      (check-pred "Region2: carla gross = 12 post-recognition"
                  (= 12 (global-citizen-gross "carla" scopes "Region2")))

      ;; Withdrawal is symmetric and immediate (no cache).
      ($ obs-mut 'unrecognize-intent "I-loose-care" "Region2")
      (check-pred "Region2: carla voice = 0 after withdrawal"
                  (= 0 (voice-share "carla" scopes "Region2"))))))

;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
