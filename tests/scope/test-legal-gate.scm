;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-legal-gate.scm — THE VERTICAL SLICE (§6 of legal-crossings.md).
;;;
;;; Proves the whole chain gels with the planner, with REAL code at every link:
;;;
;;;   real <recipe-flow> records
;;;     → crossings DERIVED by legal/crossings.scm  (recipe-crossings)
;;;     → demands FOLDED by legal/registry.scm (legal-demands)
;;;     → a `forbid` PRUNES the activity's column in the live planner
;;;       (the SAME mechanism that prunes a recipe with no skilled worker).
;;;
;;; One recipe — recover produce, share a meal — runs in two places. The only
;;; difference is the law: "banland" forbids public food-sharing. With the legal
;;; gate off, both places fill; with it on, banland's column never enters the
;;; solve and its demand goes unmet. Pure solver ⇒ no blake3.
;;;
;;; Run: guile -L module tests/scope/test-legal-gate.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness) (playnet legal crossings) (playnet vf schemas) (srfi srfi-1) (playnet scope live)
             (goblins) (goblins vat) (srfi srfi-1) (ice-9 string-fun))

(define here (dirname (current-filename)))
(define root (dirname (dirname here)))
(use-modules (playnet legal crossings))                                  ; recipe → crossings
(use-modules (playnet legal registry)) ; crossings → demands

;; ── the recipe: recover produce → cook → share a meal. Crossings are DECLARED
;;    as `crossing:<x>` classification tags on the specs (per §11) — derived, not
;;    hand-listed. ───────────────────────────────────────────────────────────
(define procs (list (make-recipe-process #:id "share" #:name "Share a meal")))
(define flows
  (list (make-recipe-flow #:id "f-out"  #:action 'produce #:resource-conforms-to "meal"
                          #:resource-quantity (make-measure 1.0 "meal") #:recipe-output-of "share"
                          #:is-primary #t)
        (make-recipe-flow #:id "f-in"   #:action 'consume #:resource-conforms-to "produce"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "share")
        (make-recipe-flow #:id "f-work" #:action 'work    #:resource-conforms-to "cook"
                          #:effort-quantity (make-measure 0.5 %effort-unit) #:recipe-input-of "share")))
(define recipes (list (make-recipe #:id "share-recipe" #:name "Share a meal" #:primary-output "meal"
                                   #:recipe-processes '() #:recipe-exchanges '())))
(define specs
  (list (make-resource-specification #:id "meal"    #:name "Shared Meal"
                                     #:resource-classified-as '("food" "crossing:share-food")     
                                     #:default-unit-of-resource "meal")
        (make-resource-specification #:id "produce" #:name "Produce"
                                     #:resource-classified-as '("food" "crossing:recover-surplus")
                                     #:default-unit-of-resource "kg")
        (make-resource-specification #:id "cook"    #:name "Cook"
                                     #:resource-classified-as '()                                 
                                     #:default-unit-of-resource %effort-unit)))
(define (resolve-spec id) (find (lambda (s) (equal? (resource-specification-id s) id)) specs))

;; ── LINK 1+2 proven directly: derive crossings, fold at a forbidding place ──
(define proc-flows
  (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) "share")
                          (equal? (recipe-flow-recipe-output-of f) "share"))) flows))
(define derived (recipe-crossings proc-flows resolve-spec))
(define (place-of-cell cell) (car (string-split cell #\@)))      ; "banland@0" → "banland"
(define (parent-of id) (if (member id '("banland" "freeland")) "world" #f))
(define *legal-rules*
  (list (rule (all-of (in-jurisdiction "banland") (on-crossing 'share-food))
              (list (forbid #:reason "public food-sharing ordinance"))
              #:label "banland/no-sharing" #:source "(test ordinance)"
              #:confidence 'verified #:steward "scope:test")))
(define (bill-at place)
  (legal-demands (legal-context #:crossings derived
                                #:place-path (jurisdiction-path place parent-of)
                                #:act 'activity)
                 #:rules *legal-rules*))

;; ── the GATE the planner consults: (proc-id, cell) → forbidden? — the full
;;    chain inside one predicate. ──────────────────────────────────────────
(define (legal-gate proc-id cell)
  (call-with-values (lambda () (bill-at (place-of-cell cell)))
    (lambda (bill hits) (pair? (assq-ref bill 'forbid)))))

;; ── the live world: produce stock + a cook at BOTH places; demand a meal at
;;    each. The ONLY difference between the places is the law. ──────────────
(define win (all-week-window "00:00" "23:59"))
(define resources
  (list (er "p-f" "produce" "acc-f" #:place "freeland" #:qty 100.0) (er "c-f" "cook" "wf" #:place "freeland" #:qty 1.0)
        (er "p-b" "produce" "acc-b" #:place "banland" #:qty 100.0) (er "c-b" "cook" "wb" #:place "banland" #:qty 1.0)))
(define agents
  (list (make-agent #:id "wf" #:type 'person #:primary-location "freeland" #:classified-as '()
                    #:availability-window win)
        (make-agent #:id "wb" #:type 'person #:primary-location "banland"  #:classified-as '()
                    #:availability-window win)))
(define spatials
  (list (make-spatial-thing #:id "freeland" #:lat 40.0 #:long -74.0)
        (make-spatial-thing #:id "banland" #:lat 41.0 #:long -75.0)))

(define (solve-with gate)
  (define vat (spawn-vat))
  (with-vat vat
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () resources))
                               (skill-hours-of . ,(lambda (aid) '()))
                               (record-event . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs (mock-recipe-store #:recipes recipes #:specs specs #:procs procs #:flows flows))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
      (call-with-values
        (lambda () (plan-scope scope #:demand '(("meal#freeland@0" . 10.0) ("meal#banland@0" . 10.0))
                               #:backend 'native-c #:legal-forbids? gate))
        (lambda (intents commitments material fill x ntot report) (list fill material))))))

(display "\n── The vertical slice: recipe → crossings → demands → planner gate ──\n")
(format #t "LINK 1  derived crossings: ~a\n"
        (sort derived (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))
(check-pred "LINK 1 — crossings derived from the recipe (share-food)" (memq 'share-food derived))
(check-pred "LINK 1 — recover-surplus derived too"                    (memq 'recover-surplus derived))

(call-with-values (lambda () (bill-at "banland")) (lambda (b h)
  (check-pred "LINK 2 — banland FOLDS to a forbid"        (pair? (assq-ref b 'forbid)))
  (check-pred "LINK 2 — forbid ⇒ bill-weight is +inf.0"   (inf? (bill-weight b)))))
(call-with-values (lambda () (bill-at "freeland")) (lambda (b h)
  (check-pred "LINK 2 — freeland folds to NO forbid"      (not (pair? (assq-ref b 'forbid))))))

(check-pred "GATE — forbidden at banland"     (legal-gate "share" "banland@0"))
(check-pred "GATE — permitted at freeland"    (not (legal-gate "share" "freeland@0")))

;; LINK 3 — the gate prunes the column in the LIVE solve. Demand is symmetric
;; (10 at freeland + 10 at banland); freeland fills, banland's column never
;; enters the solve, so overall fill lands at exactly one half.
(define fill-off (car (solve-with #f)))           ; no legal gate
(define fill-on  (car (solve-with legal-gate)))   ; legal gate on
(format #t "LINK 3  fill  no-law: ~,3f   with-law: ~,3f  (banland pruned ⇒ ½)\n" fill-off fill-on)
(check-pred "LINK 3 — both places fill when no law"  (> fill-off 0.9))
(check-pred "LINK 3 — the forbid prunes banland (fill ≈ ½)"
            (and (> fill-on 0.45) (< fill-on 0.55)))

(display "\n")
(test-summary!)
