;;; test-contrary-observation.scm — a worker's witnessed reading against a
;;; mapped figure, and what the solve makes of it.
;;;
;;; docs/planning/voice/feasibility-follows-the-map.md: "this won't work" is a
;;; map act, never a stance. A contrary observation names one figure (a
;;; process's action on a spec), states the reading a run of it gave, and is
;;; signed by the worker whose work event witnessed it. Pinned as properties:
;;;   • only the witness speaks: the event named is in the scope's record,
;;;     it is the speaker's own, and it is a run of the very process;
;;;   • one live statement per (observer, scope, process, action): a
;;;     restatement supersedes;
;;;   • the law (planner/solve/engine/robust.scm observed-shocks) moves the read in the
;;;     cautious direction only — an output falls to the reading, an input
;;;     rises to it, a flattering reading leaves the map where it stands;
;;;   • witnesses are equal: two readings of one figure read as their mean,
;;;     whatever the hours behind them;
;;;   • the scope's standing carries the rows to the solve (recipe-standing
;;;     scope-standing #:observed → `observed`), anonymous.
;;;
;;; Run:  guile -q -L module tests/governance/test-contrary-observation.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas) (playnet vf beyond scenario) (srfi srfi-1))
(use-modules (playnet doors service))
(use-modules ((playnet solve engine) #:select (observed-shocks scenario-with-shocks)))
(use-modules (playnet economy recipe-standing) (playnet boot scope) (playnet governance service) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri said-portable))
(use-modules ((playnet economy recipe-standing) #:select (scope-standing)))
(use-modules ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid sign-said))
             (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (approx= a b) (< (abs (- a b)) 1e-9))
(define (intent! obs aid skill hours iid)
  ($ obs 'register-intent
     (make-intent #:id iid #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours %effort-unit) #:provider aid)))
(define (work! obs aid skill hours eid iid pid)
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'work #:input-of pid #:resource-conforms-to skill
                          #:provider aid #:effort-quantity (make-measure hours %effort-unit)
                          #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies iid)))
(define (preimage-fields pre) (lambda (k) (let ((p (assq k pre))) (and p (cdr p)))))
(define (said-of ar) (compute-said (ar 'issuer) (ar 'holder) (ar 'schema) (ar 'claims) (or (ar 'edges) '())))
(define (factor-of shocks action process)
  (let ((s (find (lambda (sh) (and (eq? (car sh) action) (equal? (cadr sh) process))) shocks)))
    (and s (caddr s))))

(display "\n── the law: the cautious direction only, witnesses equal ──\n")
(let ((sh (observed-shocks '(("bake" produce 80.0 40.0)      ; the oven does forty, the map says eighty
                             ("bake" consume 1.0 1.5)        ; and eats half again the flour
                             ("mill" produce 1.0 2.0)        ; a mill that flatters its map
                             ("mill" work 0.3 0.1)))))       ; and lighter labour than mapped
  (check-pred "an output figure falls to the reading: ×0.5" (approx= (factor-of sh 'produce "bake") 0.5))
  (check-pred "an input figure rises to the reading: ×1.5" (approx= (factor-of sh 'consume "bake") 1.5))
  (check-pred "a flattering output reading leaves the map where it stands" (approx= (factor-of sh 'produce "mill") 1.0))
  (check-pred "a flattering input reading too" (approx= (factor-of sh 'work "mill") 1.0)))
(let ((sh (observed-shocks '(("bake" produce 80.0 40.0) ("bake" produce 80.0 60.0)))))
  (check-pred "two witnesses of one figure read as their mean: (0.5 + 0.75)/2"
              (approx= (factor-of sh 'produce "bake") 0.625)))
(check "a malformed row is dropped, never a crash"
       (observed-shocks '(("bake" produce 0.0 40.0) (bake produce 80.0 40.0) ("bake" "produce" 80 40))) '())
(let* ((s0 (make-planning-scenario "dry" #f 0.4 '((produce "grow" 0.7)) #f))
       (s1 (scenario-with-shocks s0 (observed-shocks '(("bake" produce 80.0 40.0))))))
  (check-pred "laid over a future: its own shocks stay, the observed one joins"
              (and (equal? (planning-scenario-id s1) "dry")
                   (approx= (planning-scenario-probability s1) 0.4)
                   (= 2 (length (planning-scenario-yield-multipliers s1)))))
  (check "no observation: the future is the same object" (eq? s0 (scenario-with-shocks s0 '())) #t))

(display "\n── the doors: who may speak, and what stands ──\n")
(define vat (spawn-vat))
(with-vat vat
  (let* ((commune-id (make-keri-identity)) (commune-aid (keri-identity-aid commune-id))
         (root  (spawn-scope-root "Bakery"))
         (store (spawn-acdc-store))
         (scope (spawn-scope "Bakery" #:kind 'commune #:scope-root-ref root
                             #:scope-aid commune-aid #:keypair (keri-identity-keypair commune-id)
                             #:acdc-store store))
         (ada (make-keri-identity)) (ada-aid (keri-identity-aid ada))   ; ran the oven
         (bo  (make-keri-identity)) (bo-aid  (keri-identity-aid bo))    ; ran the oven too
         (di  (make-keri-identity)) (di-aid  (keri-identity-aid di))    ; milled, never baked
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope
                                        #:scope-root-of (lambda (sid) (and (equal? sid "Bakery") root))))
         (obs ($ root 'observer)))
    (for-each (lambda (aid name)
                ($ ($ root 'agent-store) 'add-agent (make-agent #:id aid #:type 'person #:name name
                                                                #:note "" #:image ""
                                                                #:classified-as '())))
              (list ada-aid bo-aid di-aid) '("Ada" "Bo" "Di"))
    (intent! obs ada-aid "skill-bake" 4 "in-a") (work! obs ada-aid "skill-bake" 4 "ev-a" "in-a" "bake")
    (intent! obs bo-aid  "skill-bake" 4 "in-b") (work! obs bo-aid  "skill-bake" 4 "ev-b" "in-b" "bake")
    (intent! obs di-aid  "skill-mill" 4 "in-d") (work! obs di-aid  "skill-mill" 4 "ev-d" "in-d" "mill")

    (check "a witness nobody recorded is refused"
           (car ($ svc 'observe-contrary ada-aid "Bakery" "bake" 'produce "bread" 80 40 "ev-none")) 'error)
    (check "another worker's event is no witness of mine"
           (car ($ svc 'observe-contrary ada-aid "Bakery" "bake" 'produce "bread" 80 40 "ev-b")) 'error)
    (check "a run of another process witnesses nothing about this figure"
           (car ($ svc 'observe-contrary di-aid "Bakery" "bake" 'produce "bread" 80 40 "ev-d")) 'error)
    (check "an action off the map is refused"
           (car ($ svc 'observe-contrary ada-aid "Bakery" "bake" 'sell "bread" 80 40 "ev-a")) 'error)
    (check "a figure of zero is no figure"
           (car ($ svc 'observe-contrary ada-aid "Bakery" "bake" 'produce "bread" 0 40 "ev-a")) 'error)
    (check "ada, who ran the oven, observes: forty where the map says eighty"
           (car ($ svc 'observe-contrary ada-aid "Bakery" "bake" 'produce "bread" 80 40 "ev-a")) 'ok)
    (check "the scope's map carries it, anonymous, as the solve takes it"
           (contrary-observations-of store "Bakery") '(("bake" produce 80 40)))
    (check "the read names the observer, the witness and the reading"
           (let ((r (cdr ($ svc 'contrary-observations ada-aid "Bakery"))))
             (and (= 1 (length r)) (equal? (car (car r)) ada-aid) (equal? (list-ref (car r) 6) "ev-a")))
           #t)
    (check "a restatement supersedes: one live statement per observer, process and action"
           (begin ($ svc 'observe-contrary ada-aid "Bakery" "bake" 'produce "bread" 80 50 "ev-a")
                  (contrary-observations-of store "Bakery"))
           '(("bake" produce 80 50)))
    (check "a second witness stands beside the first"
           (begin ($ svc 'observe-contrary bo-aid "Bakery" "bake" 'produce "bread" 80 30 "ev-b")
                  (length (contrary-observations-of store "Bakery")))
           2)
    (check-pred "…and the solve reads their mean: (50 + 30)/2 over 80"
                (approx= (factor-of (observed-shocks (contrary-observations-of store "Bakery")) 'produce "bake") 0.5))
    (check "the scope's standing carries the rows to the solve"
           (assq-ref (scope-standing root #:observed (contrary-observations-of store "Bakery")) 'observed)
           (contrary-observations-of store "Bakery"))
    (check "another scope's map is untouched" (contrary-observations-of store "Mill") '())
    ;; the client-signed path: preimage → sign → land
    (let* ((at  "2026-09-23T10:00:00Z")
           (pre ($ svc 'observe-contrary-preimage ada-aid "Bakery" "bake" 'consume "flour" 1.0 1.5 "ev-a" at))
           (ar  (preimage-fields (cadr pre)))
           (sig (sign-said (said-of ar) (keri-identity-keypair ada))))
      (check "ada's preimage is hers to sign" (car pre) 'ok)
      (check "a stranger's signature is refused"
             (car ($ svc 'observe-contrary-signed ada-aid "Bakery" "bake" 'consume "flour" 1.0 1.5 "ev-a" at
                     (sign-said (said-of ar) (keri-identity-keypair di))))
             'error)
      (check "her own lands it" (car ($ svc 'observe-contrary-signed ada-aid "Bakery" "bake" 'consume "flour" 1.0 1.5 "ev-a" at sig)) 'ok)
      (check-pred "an observation on another action of the same process stands beside, not instead"
                  (let ((sh (observed-shocks (contrary-observations-of store "Bakery"))))
                    (and (approx= (factor-of sh 'consume "bake") 1.5)
                         (approx= (factor-of sh 'produce "bake") 0.5)))))))

(test-summary!)
