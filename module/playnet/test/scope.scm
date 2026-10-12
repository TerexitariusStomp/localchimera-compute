;;; scope.scm — a live scope, mocked once for every planner test that needs one.
;;;
;;; plan-scope reads four stores off a scope-root actor — observer, agent-store,
;;; spatial-thing-store, recipe-store — and twenty-odd suites had each spelled the
;;; same ^mock and the same four tables by hand, beside the same shorthands for a
;;; recipe process, a produce flow, a work flow, a held resource, a working week.
;;; This is that rig, once: `mock-scope` gives back the scope-root a test hands to
;;; plan-scope / plan-scope->alist, and the shorthands build the records the way
;;; those suites already do. Nothing here is a real store; a real scope-root is
;;; scope-root.scm.
;;;
;;;   (with-vat vat
;;;     (plan-scope->alist (mock-scope #:resources rs #:agents as #:spatials sp
;;;                                    #:recipes recipes #:flows flows #:chain chain)
;;;                        #:demand …))

(define-module (playnet test scope)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet knowledge dsl world)
  #:use-module (playnet knowledge dsl shorthand)
  #:use-module ((playnet test harness) #:select (^mock))
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:re-export (^mock
               rp* out* wk* use* consume* spec* er holding person* org* place*
               weekday-window all-week-window hours-of)
  #:use-module ((playnet vf facts parts) #:select (part->string))
  #:use-module ((playnet observation account) #:select (claim-commitment))
  #:use-module ((playnet vf formulas flows) #:select (make-work-intent))
  #:export (mock-scope mock-scope-root mock-world record-work! push-on plan-claim! account!))

;; ── the plan's claim, stated by a fixture ───────────────────────────────────
;; A claim event fulfils a commitment the plan minted (service.scm plan-claims!,
;; account.scm claim-commitment); a suite with no solve stands the row up
;; itself, the way declare-claimable! stands in for the rail. Returns the
;; commitment id the ledger's `claim` takes as its `fulfills`.
(define* (plan-claim! obs spec claimant qty #:key (scope "s1") place when-iso)
  (let ((c (claim-commitment spec claimant qty scope #:place place #:when-iso when-iso)))
    ($ obs 'register-commitment c)
    (commitment-id c)))

;; ── validated hours, stated by their terms ───────────────────────────────────
;; The one fixture behind every suite that records hours: a recipient-side
;; work intent and the 'work event that satisfies it in full (the validation
;; gate, observer.scm validated-effort, anchors on intent satisfaction), with
;; the terms the fold of hours by part reads — process, place, skill, window,
;; scope — as keywords. PLAN-ID sets the intent's planned-within, which the
;; observer joins through for level-stratified credits.
(define* (record-work! obs aid hours event-id intent-id
                       #:key (skill "spec-labor") process place scope plan-id
                             (when "2026-03-01T08:00:00Z") (unit "hour"))
  ($ obs 'register-intent
     (make-work-intent #:id intent-id #:skill skill #:hours hours #:unit unit
                       #:provider aid #:planned-within plan-id))
  ($ obs 'record-event
     (make-economic-event
       #:id event-id #:action 'work #:input-of process #:resource-conforms-to skill
       #:provider aid #:effort-quantity (make-measure hours unit)
       #:has-beginning when #:has-point-in-time when #:at-location place
       #:satisfies intent-id #:in-scope-of (and scope (list scope)))))

;; the push a fold or the arithmetic reports on one part, 0 when it names none
(define (push-on pushes π)
  (or (assoc-ref (map (lambda (pp) (cons (part->string (car pp)) (cdr pp))) pushes) (part->string π))
      0.0))

;; the message-table actor is the harness's ((^mock bcom `((msg . proc) …)));
;; the record shorthands are (playnet knowledge dsl shorthand)'s — both
;; re-exported here so a suite importing this module reads ONE binding each

;; the stores a <world> answers from — every read plan-scope makes, nothing
;; more, so a solve over a mocked world and over the same world seeded into a
;; real scope-root read the same tables. Returns the scope-root.
(define* (mock-world w #:key (plan-store #f) (alert-store #f) (legal-registry #f)
                           (skill-hours (lambda (aid) '()))
                           (record-event (lambda (e) (economic-event-id e))))
  (let* ((obs (spawn ^mock `((all-resources . ,(lambda () (world-resources w)))
                             (get-resource   . ,(lambda (id) (find (lambda (r) (equal? (economic-resource-id r) id))
                                                                   (world-resources w))))
                             (skill-hours-of . ,skill-hours)
                             (record-event   . ,record-event))))
         (as  (spawn ^mock `((all-agents . ,(lambda () (world-agents w))))))
         (sts (spawn ^mock `((all-locations . ,(lambda () (world-spatials w))))))
         (rs  (spawn ^mock `((all-recipes        . ,(lambda () (world-recipes w)))
                             (all-resource-specs . ,(lambda () (world-specs w)))
                             (get-process-chain  . ,(lambda (rid) (world-chain w rid)))
                             ;; (inputs . outputs), as the real store answers: what a recipe derives of
                             ;; its product (live.scm recipe-derived-contains) reads the two sides
                             (flows-for-process  . ,(lambda (pid)
                                                      (let ((fl (world-flows-for w pid)))
                                                        (cons (filter (lambda (f) (equal? pid (recipe-flow-recipe-input-of f))) fl)
                                                              (filter (lambda (f) (equal? pid (recipe-flow-recipe-output-of f))) fl)))))))))
    (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs
                     #:plan-store plan-store #:alert-store alert-store #:legal-registry legal-registry)))

;; the scope-root plan-scope reads. CHAIN maps recipe-id → the recipe's process
;; (one process per recipe, the common test shape); flows-for-process answers with
;; every flow that names the process as input or output. SKILL-HOURS answers the
;; observer's skill-hours-of; SPECS the recipe-store's resource specs.
(define* (mock-scope #:key (resources '()) (agents '()) (spatials '())
                           (recipes '()) (flows '()) (chain '()) (specs '())
                           (skill-hours (lambda (aid) '())))
  (let* ((obs (spawn ^mock `((all-resources . ,(lambda () resources))
                             (skill-hours-of . ,skill-hours)
                             (record-event   . ,(lambda (e) "ok")))))
         (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
         (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
         (rs  (spawn ^mock `((all-recipes        . ,(lambda () recipes))
                             (all-resource-specs . ,(lambda () specs))
                             (get-process-chain  . ,(lambda (rid)
                                                      (let ((p (assoc rid chain)))
                                                        (if p (list (cadr p)) '()))))
                             (flows-for-process
                              . ,(lambda (pid)
                                   (cons (filter (lambda (f)
                                                   (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                       (equal? (recipe-flow-recipe-output-of f) pid)))
                                                 flows)
                                         '())))))))
    (mock-scope-root #:observer obs #:agent-store as
                     #:spatial-thing-store sts #:recipe-store rs)))

;; the ROOT over stores a test has already built its own way — the one table
;; every suite used to spell by hand. A slot left #f is absent from the root, so
;; a reader that guards its part (accepts.scm `scope-part`, compliance.scm
;; `scope-legal-decorate`) sees the empty case; a reader that does not guard
;; gets the mock's "no method" loudly. A mocked root stands under no law unless
;; a test hands it a registry.
(define* (mock-scope-root #:key observer agent-store spatial-thing-store recipe-store
                                (plan-store #f) (alert-store #f) (legal-registry #f)
                                ;; the credit ledger plan-scope wires its labour fold to: an empty one
                                (account-store (spawn ^mock `((credit-cells . ,(lambda () '()))
                                                              (add-change-listener . ,(lambda (f) #t)))))
                                (name "mock"))
  (spawn ^mock
         `((name . ,(lambda () name))
           ,@(filter-map
              (lambda (slot)
                (and (cdr slot)
                     (let ((v (cdr slot))) (cons (car slot) (lambda () v)))))
              `((observer . ,observer) (agent-store . ,agent-store)
                (spatial-thing-store . ,spatial-thing-store) (recipe-store . ,recipe-store)
                (plan-store . ,plan-store) (alert-store . ,alert-store)
                (account-store . ,account-store)
                (legal-registry . ,legal-registry))))))

;; ── a roster a fixture states ───────────────────────────────────────────────
;; Who holds an account and a person's contribution-capacity factor are
;; readings of a commune's credentials (observation/account.scm
;; `account-holders`, `set-standing`); a suite with no credential store
;; states them here, one call per fact, the way a commune's admit-member and
;; set-ccf would have the store read them: (account! store aid [ccf]).
(define %stated (make-hash-table))   ; store → (members . ((aid . ccf) …))
(define* (account! store aid #:optional (ccf #f))
  (let* ((row (or (hashq-ref %stated store) (cons '() '())))
         (members (if (member aid (car row)) (car row) (cons aid (car row))))
         (ccfs (if ccf (cons (cons aid ccf) (alist-delete aid (cdr row))) (cdr row)))
         (row* (cons members ccfs)))
    (hashq-set! %stated store row*)
    ($ store 'set-standing
       (lambda () (car (hashq-ref %stated store)))
       (lambda (a) (let ((p (assoc a (cdr (hashq-ref %stated store))))) (if p (cdr p) 1))))
    aid))
