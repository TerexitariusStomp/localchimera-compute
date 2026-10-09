;;; test-willingness-service.scm — the solver-offers-first loop over the OCapN service.
;;;
;;; Proves the service surface of the willingness loop (the engine core is proven by
;;; tests/planner/test-willingness.scm). Against a live scope-root reached the
;;; same way the real one is (synchronous near-calls in a vat):
;;;
;;;   (1) FIELD     — `plan` (no opt) exposes the candidate field: ada AND bob both
;;;                   offered for skill-bake (the solver offers first, over all reachable).
;;;   (2) OPT-IN    — `express-willingness` stamps status=willing on the deterministic
;;;                   offer-intent id; it persists on the plan-store across re-solves.
;;;   (3) GATE      — `plan` with (willing-only . #t) materializes ONLY the willing:
;;;                   bob bakes (he opted in), ada does NOT (she didn't) — yet demand
;;;                   is still met, and every materialized provider is in the willing set.
;;;   (4) WITHDRAW  — `express-willingness … #f` (decline) drops bob; a fresh willing-only
;;;                   plan now routes baking to ada (the remaining willing baker).
;;;
;;; Back-compat: with NO willingness expressed, willing-only is inert (predicate #f ⇒
;;; engine default *willing?* ≡ #t) and the gated plan equals the field — the FIELD test
;;; below also confirms the default `plan` path is unchanged.
;;;
;;; Run:  guile -L module tests/planner/test-willingness-service.scm

(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet planner vf schemas) (srfi srfi-1)
             (playnet planner scope live)
             (playnet test planner bread)
             (playnet planner doors service)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

;; A minimal plan-store: just the signal-metadata surface the willingness loop uses
;; (set-meta / get-meta / all-meta), backed by a local hash. The real ^plan-store
;; persists the same way; here we only need the meta channel.
(define (^meta-store bcom)
  (let ((tbl (make-hash-table)))
    (lambda (msg . args)
      (case msg
        ((set-meta) (hash-set! tbl (car args) (cadr args)) "ok")
        ((get-meta) (hash-ref tbl (car args) #f))
        ((all-meta) (hash-map->list cons tbl))
        ((all-commitments) '())  ; no persisted commitments in this fixture (position predicate reads this)
        ((all-intents) '())      ; nor intents
        ((add-intent-listener) #t)   ; the demand fold registers its listener when the scope is wired
        (else (error "meta-store: no method" msg))))))

;; ── VF records: bread chain; ada and bob can BOTH bake (the field has two candidates) ──
(define procs bread-procs) (define flows bread-flows) (define recipes bread-recipes)
(define resources bread-resources) (define win bread-window)
(define agents bread-agents) (define spatials bread-spatials)

(define vat (spawn-vat #:name "willing-test"))
(define out
  (with-vat vat
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () resources)) (record-event . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (ps  (spawn ^meta-store))
           (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes))
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid)
                                  (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                                (equal? (recipe-flow-recipe-output-of f) pid))) flows) '()))))))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" scope)))
           ;; a DAY's bread: the world stands on one day, 8 h a person
           (demand '(("bread" "town" 0 8.0))))
      ;; (1) FIELD: plan with no opt — the candidate field over all reachable workers
      (let* ((field ($ svc 'plan "s1" demand '()))
             ;; (2) OPT-IN: the willing set that fully covers the chain, with BOB baking
             (_w1 ($ svc 'express-willingness "s1" "farmer" "skill-farm" "town@0" #t))
             (_w2 ($ svc 'express-willingness "s1" "farmer" "skill-mill" "town@0" #t))
             (_w3 ($ svc 'express-willingness "s1" "bob"    "skill-bake" "town@0" #t))
             ;; (3) GATE: willing-only — only the willing materialize
             (gated ($ svc 'plan "s1" demand '((willing-only . #t))))
             ;; (4) WITHDRAW bob, opt ada in instead → re-gate
             (_d  ($ svc 'express-willingness "s1" "bob" "skill-bake" "town@0" #f))
             (_w4 ($ svc 'express-willingness "s1" "ada" "skill-bake" "town@0" #t))
             (regated ($ svc 'plan "s1" demand '((willing-only . #t)))))
        (list field gated regated ps svc)))))

(define field   (cdr (list-ref out 0)))
(define gated   (cdr (list-ref out 1)))
(define regated (cdr (list-ref out 2)))
(define ps      (list-ref out 3))
(define svc     (list-ref out 4))
(define (bakers alist) (filter-map (lambda (w) (and (equal? (assq-ref w 'conforms-to) "skill-bake")
                                                    (assq-ref w 'provider))) (assq-ref alist 'work)))
(define (providers alist) (delete-duplicates (filter-map (lambda (w) (assq-ref w 'provider)) (assq-ref alist 'work))))
(define (field-bakers alist)   ; candidates: ((need-id . ((worker share oid)…))…)
  (delete-duplicates (append-map (lambda (kv) (if (string-contains (car kv) "skill-bake") (map car (cdr kv)) '()))
                                 (or (assq-ref alist 'candidates) '()))))

(display "\n── (playnet planner doors service): the solver-offers-first willingness loop ──\n")

(display "\n  (1) FIELD — `plan` offers a candidate field over all reachable workers\n")
(check "field substantially meets demand"     (> (assq-ref field 'met) 0.9))
(check "field offers BOTH ada and bob for baking (the offer, not a single pick)"
       (let ((fb (field-bakers field))) (and (member "ada" fb) (member "bob" fb))))

(display "\n  (2)+(3) OPT-IN + GATE — willing-only materializes ONLY the willing\n")
(check "gated plan still substantially meets demand" (> (assq-ref gated 'met) 0.9))
(check "bob (opted in) bakes"                  (member "bob" (bakers gated)))
(check "ada (did NOT opt in) does not bake"    (not (member "ada" (bakers gated))))
(check "every materialized provider is in the willing set (gate honoured)"
       (every (lambda (p) (member p '("farmer" "bob"))) (providers gated)))

(display "\n  (4) WITHDRAW — declining bob reroutes baking to the remaining willing baker\n")
(check "regated plan still meets demand"       (> (assq-ref regated 'met) 0.9))
(check "ada (newly willing) now bakes"         (member "ada" (bakers regated)))
(check "bob (withdrew) no longer bakes"        (not (member "bob" (bakers regated))))

(display "\n  HOURS — the optional last argument (was a bare `. hours` tail), forwarded and persisted\n")
(with-vat vat ($ svc 'express-willingness "s1" "farmer" "skill-farm" "town@0" #t 6))
(check "willing-hours lands in the persisted meta when supplied"
       (assq-ref (with-vat vat ($ ps 'get-meta "oi|farmer|skill-farm|town@0")) 'willing-hours)
       6)
(check "omitting hours leaves no willing-hours field at all — never a stray #f"
       (assq (quote willing-hours)
             (begin (with-vat vat ($ svc 'express-willingness "s1" "ada" "skill-bake" "town@0" #t))
                    (with-vat vat ($ ps 'get-meta "oi|ada|skill-bake|town@0"))))
       #f)

(test-summary!)
