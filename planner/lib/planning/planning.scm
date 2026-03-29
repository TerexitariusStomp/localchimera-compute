;;; planning.scm — Goblins actor for the VF planning layer
;;;
;;; Translated from src/lib/planning/planning.ts (PlanStore)
;;; State: 10 hashmaps (plans, commitments, intents, claims, agreements,
;;;        agreement-bundles, proposals, proposal-lists, scenarios,
;;;        scenario-definitions) + signal metadata + secondary indexes.

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (srfi srfi-1)
             (srfi srfi-9)
             (ice-9 match))

;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Plan store state record (bundles all maps for clean bcom)
;; =========================================================================

(define-record-type <plan-store-state>
  (make-plan-store-state plans commitments intents claims
                         agreements agreement-bundles
                         proposals proposal-lists
                         scenarios scenario-definitions
                         meta
                         ;; secondary indexes (hashmap of key -> list of IDs)
                         tag-index intents-by-spec commitments-by-spec
                         intents-by-plan commitments-by-plan
                         commitments-by-process)
  plan-store-state?
  (plans               pss-plans)
  (commitments         pss-commitments)
  (intents             pss-intents)
  (claims              pss-claims)
  (agreements          pss-agreements)
  (agreement-bundles   pss-agreement-bundles)
  (proposals           pss-proposals)
  (proposal-lists      pss-proposal-lists)
  (scenarios           pss-scenarios)
  (scenario-definitions pss-scenario-definitions)
  (meta                pss-meta)
  (tag-index           pss-tag-index)
  (intents-by-spec     pss-intents-by-spec)
  (commitments-by-spec pss-commitments-by-spec)
  (intents-by-plan     pss-intents-by-plan)
  (commitments-by-plan pss-commitments-by-plan)
  (commitments-by-process pss-commitments-by-process))

(define (empty-plan-store-state)
  (make-plan-store-state
    (hashmap) (hashmap) (hashmap) (hashmap)
    (hashmap) (hashmap) (hashmap) (hashmap)
    (hashmap) (hashmap) (hashmap)
    (hashmap) (hashmap) (hashmap)
    (hashmap) (hashmap) (hashmap)))

;; Helper: update a single field in plan-store-state
(define (pss-with-intents st new-intents)
  (make-plan-store-state
    (pss-plans st) (pss-commitments st) new-intents (pss-claims st)
    (pss-agreements st) (pss-agreement-bundles st)
    (pss-proposals st) (pss-proposal-lists st)
    (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
    (pss-tag-index st) (pss-intents-by-spec st) (pss-commitments-by-spec st)
                 (pss-intents-by-plan st) (pss-commitments-by-plan st)
                 (pss-commitments-by-process st)))

(define (pss-with-commitments st new-commitments)
  (make-plan-store-state
    (pss-plans st) new-commitments (pss-intents st) (pss-claims st)
    (pss-agreements st) (pss-agreement-bundles st)
    (pss-proposals st) (pss-proposal-lists st)
    (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
    (pss-tag-index st) (pss-intents-by-spec st) (pss-commitments-by-spec st)
                 (pss-intents-by-plan st) (pss-commitments-by-plan st)
                 (pss-commitments-by-process st)))


;; =========================================================================
;; Index maintenance helpers
;; =========================================================================

(define (append-to-index idx key val)
  "Append val to the list stored at key."
  (hashmap-set idx key (cons val (hashmap-ref idx key '()))))

(define (remove-from-index idx key val)
  "Remove val from the list at key."
  (let ((lst (hashmap-ref idx key '())))
    (hashmap-set idx key (delete val lst))))

(define (index-intent-tags tag-index intent)
  "Add intent to tag index for each of its resourceClassifiedAs tags."
  (let ((tags (or (intent-resource-classified-as intent) '()))
        (iid (intent-id intent)))
    (fold (lambda (tag idx) (append-to-index idx tag iid))
          tag-index tags)))

(define (index-intent-spec ibs intent)
  "Add intent to spec index."
  (let ((spec (intent-resource-conforms-to intent)))
    (if spec (append-to-index ibs spec (intent-id intent)) ibs)))

(define (index-commitment-spec cbs commitment)
  "Add commitment to spec index."
  (let ((spec (commitment-resource-conforms-to commitment)))
    (if spec (append-to-index cbs spec (commitment-id commitment)) cbs)))


;; =========================================================================
;; Record <-> list serialization for persistence
;; =========================================================================

(define (sm m)
  (if (and m (measure? m))
      (list (measure-has-numerical-value m) (measure-has-unit m)) #f))
(define (dm lst)
  (if (and lst (pair? lst)) (make-measure (car lst) (cadr lst)) #f))

(define (intent->list i)
  (list (intent-id i) (intent-action i) (intent-name i) (intent-note i)
        (intent-image i) (intent-input-of i) (intent-output-of i)
        (intent-resource-inventoried-as i) (intent-resource-conforms-to i)
        (intent-resource-classified-as i)
        (sm (intent-resource-quantity i)) (sm (intent-effort-quantity i))
        (sm (intent-available-quantity i)) (sm (intent-minimum-quantity i))
        (intent-provider i) (intent-receiver i)
        (intent-has-beginning i) (intent-has-end i) (intent-has-point-in-time i)
        (intent-due i) (intent-at-location i) (intent-stage i) (intent-state i)
        (intent-planned-within i) (intent-satisfies i) (intent-in-scope-of i)
        (intent-finished i) (intent-availability-window i)))

(define (list->intent* lst)
  (match lst
    ((id action name note image input-of output-of rias rct rca
      rq eq aq mq provider receiver hb he hpit due at-loc stage state
      pw satisfies iso finished aw)
     (make-intent id action name note image input-of output-of rias rct rca
                  (dm rq) (dm eq) (dm aq) (dm mq)
                  provider receiver hb he hpit due at-loc stage state
                  pw satisfies iso finished aw))))

(define (commitment->list c)
  (list (commitment-id c) (commitment-action c) (commitment-note c)
        (commitment-input-of c) (commitment-output-of c)
        (commitment-resource-inventoried-as c) (commitment-resource-conforms-to c)
        (commitment-resource-classified-as c)
        (sm (commitment-resource-quantity c)) (sm (commitment-effort-quantity c))
        (commitment-provider c) (commitment-receiver c)
        (commitment-has-beginning c) (commitment-has-end c)
        (commitment-has-point-in-time c) (commitment-due c)
        (commitment-created c) (commitment-at-location c)
        (commitment-in-scope-of c) (commitment-stage c) (commitment-state c)
        (commitment-satisfies c) (commitment-clause-of c)
        (commitment-independent-demand-of c) (commitment-planned-within c)
        (commitment-finished c) (commitment-availability-window c)))

(define (list->commitment* lst)
  (match lst
    ((id action note input-of output-of rias rct rca rq eq
      provider receiver hb he hpit due created at-loc iso stage state
      satisfies clause-of ind-demand pw finished aw)
     (make-commitment id action note input-of output-of rias rct rca
                      (dm rq) (dm eq)
                      provider receiver hb he hpit due created at-loc
                      iso stage state satisfies clause-of ind-demand pw
                      finished aw))))

(define (plan->list p)
  (list (plan-id p) (plan-name p) (plan-note p) (plan-due p)
        (plan-created p) (plan-has-independent-demand p)
        (plan-refinement-of p) (plan-classified-as p)))

(define (list->plan* lst) (apply make-plan lst))

(define (claim->list c)
  (list (claim-id c) (claim-action c) (claim-provider c) (claim-receiver c)
        (claim-triggered-by c)
        (sm (claim-resource-quantity c)) (sm (claim-effort-quantity c))
        (claim-resource-conforms-to c) (claim-resource-classified-as c)
        (claim-due c) (claim-created c) (claim-note c) (claim-finished c)))

(define (list->claim* lst)
  (match lst
    ((id action provider receiver triggered-by rq eq rct rca due created note finished)
     (make-claim id action provider receiver triggered-by
                 (dm rq) (dm eq) rct rca due created note finished))))

(define (agreement->list a)
  (list (agreement-id a) (agreement-name a) (agreement-note a)
        (agreement-created a) (agreement-stipulates a)
        (agreement-stipulates-reciprocal a)))

(define (list->agreement* lst) (apply make-agreement lst))

;; Simplified serializers for less-used types
(define (scenario->list s)
  (list (scenario-id s) (scenario-name s) (scenario-note s)
        (scenario-defined-as s) (scenario-refinement-of s)
        (scenario-has-beginning s) (scenario-has-end s) (scenario-in-scope-of s)))
(define (list->scenario* lst) (apply make-scenario lst))

(define (scenario-definition->list sd)
  (list (scenario-definition-id sd) (scenario-definition-name sd)
        (scenario-definition-note sd) (scenario-definition-has-duration sd)
        (scenario-definition-in-scope-of sd)))
(define (list->scenario-definition* lst) (apply make-scenario-definition lst))


;; =========================================================================
;; Serialize / deserialize full plan-store-state
;; =========================================================================

(define (serialize-plan-store-state st)
  (list (serialize-hashmap (pss-plans st) plan->list)
        (serialize-hashmap (pss-commitments st) commitment->list)
        (serialize-hashmap (pss-intents st) intent->list)
        (serialize-hashmap (pss-claims st) claim->list)
        (serialize-hashmap (pss-agreements st) agreement->list)
        ;; Note: indexes not serialized — rebuilt from data on restore
        (pss-agreement-bundles st)  ;; alist-based, already serializable
        (pss-proposals st)
        (pss-proposal-lists st)
        (serialize-hashmap (pss-scenarios st) scenario->list)
        (serialize-hashmap (pss-scenario-definitions st) scenario-definition->list)
        (pss-meta st)  ;; alist-based metadata
        (pss-tag-index st) (pss-intents-by-spec st) (pss-commitments-by-spec st)
                 (pss-intents-by-plan st) (pss-commitments-by-plan st)
                 (pss-commitments-by-process st)))

(define (deserialize-plan-store-state data)
  (match data
    ((sp sc si scl sa sab sprop spl sscen ssd smeta
      stag sibs scbs . _rest)  ;; ignore extra fields if present
     (let* ((d-intents (deserialize-hashmap si list->intent*))
            (d-commitments (deserialize-hashmap sc list->commitment*))
            ;; Rebuild new indexes from data
            (ibp (hashmap-fold (lambda (_id i acc)
                    (let ((pw (intent-planned-within i)))
                      (if pw (hashmap-set acc pw (cons (intent-id i) (hashmap-ref acc pw '()))) acc)))
                  (hashmap) d-intents))
            (cbpl (hashmap-fold (lambda (_id c acc)
                     (let ((pw (commitment-planned-within c)))
                       (if pw (hashmap-set acc pw (cons (commitment-id c) (hashmap-ref acc pw '()))) acc)))
                   (hashmap) d-commitments))
            (cbpr (hashmap-fold (lambda (_id c acc)
                     (let* ((a0 acc)
                            (a1 (if (commitment-input-of c)
                                    (hashmap-set a0 (commitment-input-of c)
                                      (cons (commitment-id c) (hashmap-ref a0 (commitment-input-of c) '())))
                                    a0))
                            (a2 (if (commitment-output-of c)
                                    (hashmap-set a1 (commitment-output-of c)
                                      (cons (commitment-id c) (hashmap-ref a1 (commitment-output-of c) '())))
                                    a1)))
                       a2))
                   (hashmap) d-commitments)))
       (make-plan-store-state
         (deserialize-hashmap sp list->plan*)
         d-commitments d-intents
         (deserialize-hashmap scl list->claim*)
         (deserialize-hashmap sa list->agreement*)
         sab sprop spl
         (deserialize-hashmap sscen list->scenario*)
         (deserialize-hashmap ssd list->scenario-definition*)
         smeta stag sibs scbs ibp cbpl cbpr)))))


;; =========================================================================
;; ^plan-store — persistent Goblins actor
;; =========================================================================

(define-actor (^plan-store bcom st)
  ;; st: <plan-store-state>

  #:portrait
  (lambda () (list (serialize-plan-store-state st)))

  #:version 1

  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^plan-store (deserialize-plan-store-state data)))
      (else (error "Unknown ^plan-store version" version))))

  (methods

    ;; --- Plans ---

    ((add-plan plan)
     (let* ((id (or (plan-id plan) (generate-id "plan-")))
            (new-plans (hashmap-set (pss-plans st) id plan)))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 new-plans (pss-commitments st) (pss-intents st) (pss-claims st)
                 (pss-agreements st) (pss-agreement-bundles st)
                 (pss-proposals st) (pss-proposal-lists st)
                 (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
                 (pss-tag-index st) (pss-intents-by-spec st)
                 (pss-commitments-by-spec st)
                 (pss-intents-by-plan st) (pss-commitments-by-plan st)
                 (pss-commitments-by-process st)))
             id)))

    ((get-plan id) (hashmap-ref (pss-plans st) id #f))
    ((all-plans)   (hashmap-values (pss-plans st)))

    ;; --- Intents ---

    ((add-intent intent)
     ;; VF rule: provider OR receiver, not both
     (when (and (intent-provider intent) (intent-receiver intent))
       (error "VF constraint: Intent cannot have both provider and receiver"))
     (let* ((id (or (intent-id intent) (generate-id "intent-")))
            (new-intents (hashmap-set (pss-intents st) id intent))
            (new-tag-idx (index-intent-tags (pss-tag-index st) intent))
            (new-ibs (index-intent-spec (pss-intents-by-spec st) intent))
            ;; Maintain intents-by-plan index
            (new-ibp (let ((pw (intent-planned-within intent)))
                       (if pw (append-to-index (pss-intents-by-plan st) pw id)
                           (pss-intents-by-plan st)))))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 (pss-plans st) (pss-commitments st) new-intents (pss-claims st)
                 (pss-agreements st) (pss-agreement-bundles st)
                 (pss-proposals st) (pss-proposal-lists st)
                 (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
                 new-tag-idx new-ibs (pss-commitments-by-spec st)
                 new-ibp (pss-commitments-by-plan st)
                 (pss-commitments-by-process st)))
             id)))

    ((get-intent id)  (hashmap-ref (pss-intents st) id #f))
    ((all-intents)    (hashmap-values (pss-intents st)))

    ((open-intents)
     (hashmap-filter (lambda (i) (not (intent-finished i))) (pss-intents st)))

    ((intents-for-plan plan-id)
     ;; O(log n) via index
     (filter-map (lambda (iid) (hashmap-ref (pss-intents st) iid #f))
                 (hashmap-ref (pss-intents-by-plan st) plan-id '())))

    ((intents-for-tag tag)
     (let ((ids (hashmap-ref (pss-tag-index st) tag '())))
       (filter-map (lambda (id) (hashmap-ref (pss-intents st) id #f)) ids)))

    ((intents-for-spec spec-id)
     (let ((ids (hashmap-ref (pss-intents-by-spec st) spec-id '())))
       (filter-map (lambda (id) (hashmap-ref (pss-intents st) id #f)) ids)))

    ((offers)
     (hashmap-filter
       (lambda (i) (and (intent-provider i) (not (intent-receiver i))
                        (not (intent-finished i))))
       (pss-intents st)))

    ((requests)
     (hashmap-filter
       (lambda (i) (and (intent-receiver i) (not (intent-provider i))
                        (not (intent-finished i))))
       (pss-intents st)))

    ;; --- Commitments ---

    ((add-commitment commitment)
     (let* ((id (or (commitment-id commitment) (generate-id "commit-")))
            (new-commitments (hashmap-set (pss-commitments st) id commitment))
            (new-cbs (index-commitment-spec (pss-commitments-by-spec st) commitment))
            ;; Maintain commitments-by-plan index
            (new-cbpl (let ((pw (commitment-planned-within commitment)))
                        (if pw (append-to-index (pss-commitments-by-plan st) pw id)
                            (pss-commitments-by-plan st))))
            ;; Maintain commitments-by-process index
            (new-cbpr (let* ((st0 (pss-commitments-by-process st))
                             (st1 (if (commitment-input-of commitment)
                                      (append-to-index st0 (commitment-input-of commitment) id)
                                      st0))
                             (st2 (if (commitment-output-of commitment)
                                      (append-to-index st1 (commitment-output-of commitment) id)
                                      st1)))
                        st2)))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 (pss-plans st) new-commitments (pss-intents st) (pss-claims st)
                 (pss-agreements st) (pss-agreement-bundles st)
                 (pss-proposals st) (pss-proposal-lists st)
                 (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
                 (pss-tag-index st) (pss-intents-by-spec st) new-cbs
                 (pss-intents-by-plan st) new-cbpl new-cbpr))
             id)))

    ((get-commitment id) (hashmap-ref (pss-commitments st) id #f))
    ((all-commitments)   (hashmap-values (pss-commitments st)))

    ((commitments-for-process process-id)
     ;; O(log n) via index
     (filter-map (lambda (cid) (hashmap-ref (pss-commitments st) cid #f))
                 (hashmap-ref (pss-commitments-by-process st) process-id '())))

    ((commitments-for-plan plan-id)
     ;; O(log n) via index
     (filter-map (lambda (cid) (hashmap-ref (pss-commitments st) cid #f))
                 (hashmap-ref (pss-commitments-by-plan st) plan-id '())))

    ((commitments-for-spec spec-id)
     (let ((ids (hashmap-ref (pss-commitments-by-spec st) spec-id '())))
       (filter-map (lambda (id) (hashmap-ref (pss-commitments st) id #f)) ids)))

    ((add-non-process-commitment action spec-id qty unit provider receiver due plan-id)
     ;; Standalone commitment without inputOf/outputOf
     (let ((c (make-commitment (generate-id "c-") action #f #f #f #f spec-id #f
                               (make-measure qty unit) #f provider receiver
                               #f #f #f due #f #f #f #f #f #f #f #f plan-id #f #f)))
       ($ self-ref 'add-commitment c)))

    ;; --- Promote intent to commitment ---

    ((promote-to-commitment iid counterparty)
     ;; iid: intent ID string
     ;; counterparty: alist with optional 'provider and 'receiver keys
     (let* ((the-intent (hashmap-ref (pss-intents st) iid #f)))
       (unless the-intent (error (format #f "Intent ~a not found" iid)))
       (let* ((prov (or (intent-provider the-intent)
                        (assq-ref counterparty 'provider)))
              (recv (or (intent-receiver the-intent)
                        (assq-ref counterparty 'receiver))))
         (unless (and prov recv)
           (error "Cannot promote: need both provider and receiver"))
         ;; Validate minimumQuantity and availableQuantity (ATP mechanism)
         (let ((commit-qty (if (intent-resource-quantity the-intent)
                               (measure-has-numerical-value (intent-resource-quantity the-intent)) 0))
               (min-qty (if (intent-minimum-quantity the-intent)
                            (measure-has-numerical-value (intent-minimum-quantity the-intent)) 0))
               (avail-qty (if (intent-available-quantity the-intent)
                              (measure-has-numerical-value (intent-available-quantity the-intent)) +inf.0)))
           (when (< commit-qty min-qty)
             (error (format #f "Committed qty ~a < minimum ~a" commit-qty min-qty)))
           (when (> commit-qty avail-qty)
             (error (format #f "Committed qty ~a > available ~a" commit-qty avail-qty))))
         ;; Build commitment from intent fields
         (let* ((cid (generate-id "commit-"))
                (commitment (make-commitment
                              cid (intent-action the-intent) #f
                              (intent-input-of the-intent) (intent-output-of the-intent)
                              (intent-resource-inventoried-as the-intent)
                              (intent-resource-conforms-to the-intent)
                              (intent-resource-classified-as the-intent)
                              (intent-resource-quantity the-intent)
                              (intent-effort-quantity the-intent)
                              prov recv
                              (intent-has-beginning the-intent)
                              (intent-has-end the-intent)
                              (intent-has-point-in-time the-intent)
                              (intent-due the-intent)
                              #f  ;; created
                              (intent-at-location the-intent)
                              (intent-in-scope-of the-intent)
                              (intent-stage the-intent) (intent-state the-intent)
                              iid  ;; satisfies
                              #f #f  ;; clauseOf, independentDemandOf
                              (intent-planned-within the-intent)
                              #f  ;; finished
                              (intent-availability-window the-intent)))
                ;; Decrement availableQuantity (ATP mechanism)
                (commit-qty (if (intent-resource-quantity the-intent)
                                (measure-has-numerical-value (intent-resource-quantity the-intent)) 0))
                (old-avail (if (intent-available-quantity the-intent)
                               (measure-has-numerical-value (intent-available-quantity the-intent)) #f))
                (new-avail-qty (and old-avail (max 0 (- old-avail commit-qty))))
                (new-avail-measure (and new-avail-qty (intent-resource-quantity the-intent)
                                        (make-measure new-avail-qty
                                          (measure-has-unit (intent-resource-quantity the-intent)))))
                ;; Mark intent finished (if not recurring and no more available)
                (finished? (and (not (intent-availability-window the-intent))
                                (or (not new-avail-qty) (<= new-avail-qty 0))))
                (updated-intent
                  (if (or finished? new-avail-measure)
                      (make-intent
                        (intent-id the-intent) (intent-action the-intent)
                        (intent-name the-intent) (intent-note the-intent)
                        (intent-image the-intent)
                        (intent-input-of the-intent) (intent-output-of the-intent)
                        (intent-resource-inventoried-as the-intent)
                        (intent-resource-conforms-to the-intent)
                        (intent-resource-classified-as the-intent)
                        (intent-resource-quantity the-intent)
                        (intent-effort-quantity the-intent)
                        (or new-avail-measure (intent-available-quantity the-intent))
                        (intent-minimum-quantity the-intent)
                        (intent-provider the-intent) (intent-receiver the-intent)
                        (intent-has-beginning the-intent) (intent-has-end the-intent)
                        (intent-has-point-in-time the-intent) (intent-due the-intent)
                        (intent-at-location the-intent) (intent-stage the-intent)
                        (intent-state the-intent) (intent-planned-within the-intent)
                        (intent-satisfies the-intent) (intent-in-scope-of the-intent)
                        finished?
                        (intent-availability-window the-intent))
                      the-intent))
                (new-intents (hashmap-set (pss-intents st) iid updated-intent))
                (new-commitments (hashmap-set (pss-commitments st) cid commitment))
                (new-cbs (index-commitment-spec (pss-commitments-by-spec st) commitment)))
           (bcom (^plan-store bcom
                   (make-plan-store-state
                     (pss-plans st) new-commitments new-intents (pss-claims st)
                     (pss-agreements st) (pss-agreement-bundles st)
                     (pss-proposals st) (pss-proposal-lists st)
                     (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
                     (pss-tag-index st) (pss-intents-by-spec st) new-cbs
                 (pss-intents-by-plan st) (pss-commitments-by-plan st)
                 (pss-commitments-by-process st)))
                 cid)))))

    ;; --- Claims ---

    ((add-claim claim)
     (let* ((id (or (claim-id claim) (generate-id "claim-")))
            (new-claims (hashmap-set (pss-claims st) id claim)))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 (pss-plans st) (pss-commitments st) (pss-intents st) new-claims
                 (pss-agreements st) (pss-agreement-bundles st)
                 (pss-proposals st) (pss-proposal-lists st)
                 (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
                 (pss-tag-index st) (pss-intents-by-spec st)
                 (pss-commitments-by-spec st)
                 (pss-intents-by-plan st) (pss-commitments-by-plan st)
                 (pss-commitments-by-process st)))
             id)))

    ((get-claim id) (hashmap-ref (pss-claims st) id #f))
    ((all-claims)   (hashmap-values (pss-claims st)))

    ;; --- Agreements ---

    ((add-agreement agreement)
     (let* ((id (agreement-id agreement))
            (new-agrs (hashmap-set (pss-agreements st) id agreement)))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 (pss-plans st) (pss-commitments st) (pss-intents st) (pss-claims st)
                 new-agrs (pss-agreement-bundles st)
                 (pss-proposals st) (pss-proposal-lists st)
                 (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
                 (pss-tag-index st) (pss-intents-by-spec st)
                 (pss-commitments-by-spec st)
                 (pss-intents-by-plan st) (pss-commitments-by-plan st)
                 (pss-commitments-by-process st)))
             id)))

    ((get-agreement id) (hashmap-ref (pss-agreements st) id #f))
    ((all-agreements) (hashmap-values (pss-agreements st)))

    ;; --- Agreement bundles ---

    ((add-agreement-bundle bundle)
     (let ((id (or (assq-ref bundle 'id) (generate-id "ab-"))))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 (pss-plans st) (pss-commitments st) (pss-intents st) (pss-claims st)
                 (pss-agreements st) (hashmap-set (pss-agreement-bundles st) id bundle)
                 (pss-proposals st) (pss-proposal-lists st)
                 (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
                 (pss-tag-index st) (pss-intents-by-spec st) (pss-commitments-by-spec st)
                 (pss-intents-by-plan st) (pss-commitments-by-plan st)
                 (pss-commitments-by-process st))))))
    ((get-agreement-bundle id) (hashmap-ref (pss-agreement-bundles st) id #f))
    ((all-agreement-bundles) (hashmap-values (pss-agreement-bundles st)))

    ;; --- Scenarios ---

    ((add-scenario scenario)
     (let ((id (or (assq-ref scenario 'id) (generate-id "scen-"))))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 (pss-plans st) (pss-commitments st) (pss-intents st) (pss-claims st)
                 (pss-agreements st) (pss-agreement-bundles st)
                 (pss-proposals st) (pss-proposal-lists st)
                 (hashmap-set (pss-scenarios st) id scenario) (pss-scenario-definitions st)
                 (pss-meta st) (pss-tag-index st) (pss-intents-by-spec st)
                 (pss-commitments-by-spec st) (pss-intents-by-plan st)
                 (pss-commitments-by-plan st) (pss-commitments-by-process st))))))
    ((get-scenario id) (hashmap-ref (pss-scenarios st) id #f))
    ((all-scenarios) (hashmap-values (pss-scenarios st)))

    ((add-scenario-definition sdef)
     (let ((id (or (assq-ref sdef 'id) (generate-id "sdef-"))))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 (pss-plans st) (pss-commitments st) (pss-intents st) (pss-claims st)
                 (pss-agreements st) (pss-agreement-bundles st)
                 (pss-proposals st) (pss-proposal-lists st)
                 (pss-scenarios st) (hashmap-set (pss-scenario-definitions st) id sdef)
                 (pss-meta st) (pss-tag-index st) (pss-intents-by-spec st)
                 (pss-commitments-by-spec st) (pss-intents-by-plan st)
                 (pss-commitments-by-plan st) (pss-commitments-by-process st))))))
    ((get-scenario-definition id) (hashmap-ref (pss-scenario-definitions st) id #f))
    ((all-scenario-definitions) (hashmap-values (pss-scenario-definitions st)))

    ;; --- Proposals ---

    ((add-proposal proposal)
     (let ((id (proposal-id proposal)))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 (pss-plans st) (pss-commitments st) (pss-intents st) (pss-claims st)
                 (pss-agreements st) (pss-agreement-bundles st)
                 (hashmap-set (pss-proposals st) id proposal) (pss-proposal-lists st)
                 (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
                 (pss-tag-index st) (pss-intents-by-spec st) (pss-commitments-by-spec st)
                 (pss-intents-by-plan st) (pss-commitments-by-plan st)
                 (pss-commitments-by-process st))))))
    ((get-proposal id) (hashmap-ref (pss-proposals st) id #f))
    ((all-proposals) (hashmap-values (pss-proposals st)))

    ((add-proposal-list plist)
     (let ((id (or (assq-ref plist 'id) (generate-id "pl-"))))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 (pss-plans st) (pss-commitments st) (pss-intents st) (pss-claims st)
                 (pss-agreements st) (pss-agreement-bundles st)
                 (pss-proposals st) (hashmap-set (pss-proposal-lists st) id plist)
                 (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
                 (pss-tag-index st) (pss-intents-by-spec st) (pss-commitments-by-spec st)
                 (pss-intents-by-plan st) (pss-commitments-by-plan st)
                 (pss-commitments-by-process st))))))
    ((get-proposal-list id) (hashmap-ref (pss-proposal-lists st) id #f))
    ((all-proposal-lists) (hashmap-values (pss-proposal-lists st)))

    ;; --- Signal metadata ---

    ((set-meta intent-id meta-alist)
     (let ((new-meta (hashmap-set (pss-meta st) intent-id meta-alist)))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 (pss-plans st) (pss-commitments st) (pss-intents st) (pss-claims st)
                 (pss-agreements st) (pss-agreement-bundles st)
                 (pss-proposals st) (pss-proposal-lists st)
                 (pss-scenarios st) (pss-scenario-definitions st) new-meta
                 (pss-tag-index st) (pss-intents-by-spec st)
                 (pss-commitments-by-spec st)
                 (pss-intents-by-plan st) (pss-commitments-by-plan st)
                 (pss-commitments-by-process st))))))

    ((get-meta intent-id) (hashmap-ref (pss-meta st) intent-id #f))

    ;; --- Signal lifecycle ---

    ((emit-signal signal plan-id)
     ;; Convert PlanSignal alist -> Intent + metadata, store both
     (let-values (((intent-fields meta) (signal->intent signal plan-id)))
       ;; Add the intent (this calls bcom internally)
       ;; But we need to add intent AND set meta atomically.
       ;; Build the new state manually:
       (let* ((iid (or (intent-id intent-fields) (generate-id "sig-")))
              (new-intents (hashmap-set (pss-intents st) iid intent-fields))
              (new-tag-idx (index-intent-tags (pss-tag-index st) intent-fields))
              (new-ibs (index-intent-spec (pss-intents-by-spec st) intent-fields))
              (new-ibp (let ((pw (intent-planned-within intent-fields)))
                         (if pw (append-to-index (pss-intents-by-plan st) pw iid)
                             (pss-intents-by-plan st))))
              (new-meta (hashmap-set (pss-meta st) iid meta)))
         (bcom (^plan-store bcom
                 (make-plan-store-state
                   (pss-plans st) (pss-commitments st) new-intents (pss-claims st)
                   (pss-agreements st) (pss-agreement-bundles st)
                   (pss-proposals st) (pss-proposal-lists st)
                   (pss-scenarios st) (pss-scenario-definitions st) new-meta
                   new-tag-idx new-ibs (pss-commitments-by-spec st)
                   new-ibp (pss-commitments-by-plan st)
                   (pss-commitments-by-process st)))
               iid))))

    ((signals-of-kind kind)
     ;; Query by signal kind, reconstruct via intent->signal
     (let ((tag (plan-tag kind)))
       (filter-map
         (lambda (i)
           (intent->signal i (hashmap-ref (pss-meta st) (intent-id i) #f)))
         (filter-map (lambda (iid) (hashmap-ref (pss-intents st) iid #f))
                     (hashmap-ref (pss-tag-index st) tag '())))))

    ((approve-replenishment iid provider receiver . rest)
     ;; Promote replenishment Intent -> Commitment with validation
     (let* ((opts (if (pair? rest) (car rest) '()))
            (intent (hashmap-ref (pss-intents st) iid #f)))
       (unless intent (error (format #f "Replenishment ~a not found" iid)))
       ;; Validate: must not be finished
       (when (intent-finished intent)
         (error (format #f "Replenishment ~a already finished" iid)))
       ;; Validate: must have replenishment tag
       (unless (and (intent-resource-classified-as intent)
                    (any (lambda (t) (string-prefix? "tag:plan:replenishment" t))
                         (intent-resource-classified-as intent)))
         (error (format #f "Intent ~a is not a replenishment signal" iid)))
       (let* ((action-override (assq-ref opts 'action))
              (output-of (assq-ref opts 'output-of))
              (planned-within-override (assq-ref opts 'planned-within))
              (cid (generate-id "commit-"))
              (commitment (make-commitment
                            cid (or action-override (intent-action intent)) #f
                            (intent-input-of intent)
                            (or output-of (intent-output-of intent))
                            #f (intent-resource-conforms-to intent)
                            (intent-resource-classified-as intent)
                            (intent-resource-quantity intent)
                            (intent-effort-quantity intent)
                            provider receiver
                            #f #f #f (intent-due intent) #f
                            (intent-at-location intent) #f
                            #f #f iid #f #f
                            (or planned-within-override (intent-planned-within intent))
                            #f #f))
              ;; Mark intent finished
              (finished-intent (make-intent
                                 iid (intent-action intent) (intent-name intent)
                                 (intent-note intent) (intent-image intent)
                                 (intent-input-of intent) (intent-output-of intent)
                                 (intent-resource-inventoried-as intent)
                                 (intent-resource-conforms-to intent)
                                 (intent-resource-classified-as intent)
                                 (intent-resource-quantity intent) (intent-effort-quantity intent)
                                 (intent-available-quantity intent) (intent-minimum-quantity intent)
                                 (intent-provider intent) (intent-receiver intent)
                                 (intent-has-beginning intent) (intent-has-end intent)
                                 (intent-has-point-in-time intent) (intent-due intent)
                                 (intent-at-location intent) (intent-stage intent)
                                 (intent-state intent) (intent-planned-within intent)
                                 (intent-satisfies intent) (intent-in-scope-of intent)
                                 #t (intent-availability-window intent)))
              ;; Update meta
              (old-meta (hashmap-ref (pss-meta st) iid '()))
              (new-meta-entry (cons* (cons 'status 'approved)
                                     (cons 'approved-commitment-id cid)
                                     (if (pair? old-meta) old-meta '())))
              ;; Build new state
              (new-intents (hashmap-set (pss-intents st) iid finished-intent))
              (new-commitments (hashmap-set (pss-commitments st) cid commitment))
              (new-cbs (index-commitment-spec (pss-commitments-by-spec st) commitment))
              (new-meta (hashmap-set (pss-meta st) iid new-meta-entry)))
         (bcom (^plan-store bcom
                 (make-plan-store-state
                   (pss-plans st) new-commitments new-intents (pss-claims st)
                   (pss-agreements st) (pss-agreement-bundles st)
                   (pss-proposals st) (pss-proposal-lists st)
                   (pss-scenarios st) (pss-scenario-definitions st) new-meta
                   (pss-tag-index st) (pss-intents-by-spec st) new-cbs
                   (pss-intents-by-plan st) (pss-commitments-by-plan st)
                   (pss-commitments-by-process st)))
               cid))))

    ((reject-replenishment iid)
     (let ((intent (hashmap-ref (pss-intents st) iid #f)))
       (unless intent (error (format #f "Replenishment ~a not found" iid)))
       (let* ((finished-intent (make-intent
                                 iid (intent-action intent) (intent-name intent)
                                 (intent-note intent) (intent-image intent)
                                 (intent-input-of intent) (intent-output-of intent)
                                 (intent-resource-inventoried-as intent)
                                 (intent-resource-conforms-to intent)
                                 (intent-resource-classified-as intent)
                                 (intent-resource-quantity intent) (intent-effort-quantity intent)
                                 (intent-available-quantity intent) (intent-minimum-quantity intent)
                                 (intent-provider intent) (intent-receiver intent)
                                 (intent-has-beginning intent) (intent-has-end intent)
                                 (intent-has-point-in-time intent) (intent-due intent)
                                 (intent-at-location intent) (intent-stage intent)
                                 (intent-state intent) (intent-planned-within intent)
                                 (intent-satisfies intent) (intent-in-scope-of intent)
                                 #t (intent-availability-window intent)))
              (old-meta (hashmap-ref (pss-meta st) iid '()))
              (new-meta-entry (cons (cons 'status 'rejected)
                                    (if (pair? old-meta) old-meta '()))))
         (bcom (^plan-store bcom
                 (make-plan-store-state
                   (pss-plans st) (pss-commitments st)
                   (hashmap-set (pss-intents st) iid finished-intent)
                   (pss-claims st)
                   (pss-agreements st) (pss-agreement-bundles st)
                   (pss-proposals st) (pss-proposal-lists st)
                   (pss-scenarios st) (pss-scenario-definitions st)
                   (hashmap-set (pss-meta st) iid new-meta-entry)
                   (pss-tag-index st) (pss-intents-by-spec st)
                   (pss-commitments-by-spec st)
                   (pss-intents-by-plan st) (pss-commitments-by-plan st)
                   (pss-commitments-by-process st)))))))

    ((commitments-for-agreement agreement-id)
     (hashmap-filter
       (lambda (c) (equal? (commitment-clause-of c) agreement-id))
       (pss-commitments st)))

    ((signal-outputs-of-process process-id)
     (hashmap-filter
       (lambda (i) (and (equal? (intent-output-of i) process-id)
                        (let ((tags (intent-resource-classified-as i)))
                          (and tags (any (lambda (t) (string-prefix? "tag:plan:" t)) tags)))))
       (pss-intents st)))

    ;; --- Bulk operations ---

    ((remove-records proc-ids commit-ids intent-ids)
     ;; Batch delete by ID lists with full index cleanup.
     (let* (;; Remove commitments + clean indexes
            (new-commitments
              (fold (lambda (cid hm) (hashmap-remove hm cid)) (pss-commitments st) (or commit-ids '())))
            (new-cbs
              (fold (lambda (cid idx)
                      (let ((c (hashmap-ref (pss-commitments st) cid #f)))
                        (if (and c (commitment-resource-conforms-to c))
                            (let* ((spec (commitment-resource-conforms-to c))
                                   (existing (hashmap-ref idx spec '())))
                              (hashmap-set idx spec (delete cid existing)))
                            idx)))
                    (pss-commitments-by-spec st) (or commit-ids '())))
            (new-cbpl
              (fold (lambda (cid idx)
                      (let ((c (hashmap-ref (pss-commitments st) cid #f)))
                        (if (and c (commitment-planned-within c))
                            (let* ((pw (commitment-planned-within c))
                                   (existing (hashmap-ref idx pw '())))
                              (hashmap-set idx pw (delete cid existing)))
                            idx)))
                    (pss-commitments-by-plan st) (or commit-ids '())))
            ;; Remove intents + clean indexes
            (new-intents
              (fold (lambda (iid hm) (hashmap-remove hm iid)) (pss-intents st) (or intent-ids '())))
            (new-tag-idx
              (fold (lambda (iid idx)
                      (let ((i (hashmap-ref (pss-intents st) iid #f)))
                        (if (and i (intent-resource-classified-as i))
                            (fold (lambda (tag ix)
                                    (hashmap-set ix tag (delete iid (hashmap-ref ix tag '()))))
                                  idx (intent-resource-classified-as i))
                            idx)))
                    (pss-tag-index st) (or intent-ids '())))
            (new-ibs
              (fold (lambda (iid idx)
                      (let ((i (hashmap-ref (pss-intents st) iid #f)))
                        (if (and i (intent-resource-conforms-to i))
                            (let* ((spec (intent-resource-conforms-to i))
                                   (existing (hashmap-ref idx spec '())))
                              (hashmap-set idx spec (delete iid existing)))
                            idx)))
                    (pss-intents-by-spec st) (or intent-ids '())))
            (new-ibp
              (fold (lambda (iid idx)
                      (let ((i (hashmap-ref (pss-intents st) iid #f)))
                        (if (and i (intent-planned-within i))
                            (let* ((pw (intent-planned-within i))
                                   (existing (hashmap-ref idx pw '())))
                              (hashmap-set idx pw (delete iid existing)))
                            idx)))
                    (pss-intents-by-plan st) (or intent-ids '())))
            (new-meta
              (fold (lambda (iid hm) (hashmap-remove hm iid)) (pss-meta st) (or intent-ids '())))
            ;; Clean commitments-by-process index
            (new-cbpr
              (fold (lambda (cid idx)
                      (let ((c (hashmap-ref (pss-commitments st) cid #f)))
                        (let* ((a0 idx)
                               (a1 (if (and c (commitment-input-of c))
                                       (hashmap-set a0 (commitment-input-of c)
                                         (delete cid (hashmap-ref a0 (commitment-input-of c) '())))
                                       a0))
                               (a2 (if (and c (commitment-output-of c))
                                       (hashmap-set a1 (commitment-output-of c)
                                         (delete cid (hashmap-ref a1 (commitment-output-of c) '())))
                                       a1)))
                          a2)))
                    (pss-commitments-by-process st) (or commit-ids '()))))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 (pss-plans st) new-commitments new-intents (pss-claims st)
                 (pss-agreements st) (pss-agreement-bundles st)
                 (pss-proposals st) (pss-proposal-lists st)
                 (pss-scenarios st) (pss-scenario-definitions st) new-meta
                 new-tag-idx new-ibs new-cbs new-ibp new-cbpl
                 new-cbpr)))))

    ((remove-records-for-plan plan-id)
     ;; Surgical removal: find all intents/commitments for this plan.
     ;; Uses the by-plan indexes for O(log n) lookup.
     (let ((iids (hashmap-ref (pss-intents-by-plan st) plan-id '()))
           (cids (hashmap-ref (pss-commitments-by-plan st) plan-id '())))
       ;; Build cleaned state (same logic as remove-records but inline)
       (let* ((new-intents (fold hashmap-remove (pss-intents st) iids))
              (new-commitments (fold hashmap-remove (pss-commitments st) cids))
              ;; Clean intent indexes
              (new-tag-idx (fold (lambda (iid idx)
                                  (let ((i (hashmap-ref (pss-intents st) iid #f)))
                                    (if (and i (intent-resource-classified-as i))
                                        (fold (lambda (tag ix)
                                                (hashmap-set ix tag (delete iid (hashmap-ref ix tag '()))))
                                              idx (intent-resource-classified-as i))
                                        idx)))
                                (pss-tag-index st) iids))
              (new-ibs (fold (lambda (iid idx)
                               (let ((i (hashmap-ref (pss-intents st) iid #f)))
                                 (if (and i (intent-resource-conforms-to i))
                                     (hashmap-set idx (intent-resource-conforms-to i)
                                       (delete iid (hashmap-ref idx (intent-resource-conforms-to i) '())))
                                     idx)))
                             (pss-intents-by-spec st) iids))
              (new-ibp (hashmap-remove (pss-intents-by-plan st) plan-id))
              ;; Clean commitment indexes
              (new-cbs (fold (lambda (cid idx)
                               (let ((c (hashmap-ref (pss-commitments st) cid #f)))
                                 (if (and c (commitment-resource-conforms-to c))
                                     (hashmap-set idx (commitment-resource-conforms-to c)
                                       (delete cid (hashmap-ref idx (commitment-resource-conforms-to c) '())))
                                     idx)))
                             (pss-commitments-by-spec st) cids))
              (new-cbpl (hashmap-remove (pss-commitments-by-plan st) plan-id))
              (new-meta (fold hashmap-remove (pss-meta st) iids)))
         (bcom (^plan-store bcom
                 (make-plan-store-state
                   (pss-plans st) new-commitments new-intents (pss-claims st)
                   (pss-agreements st) (pss-agreement-bundles st)
                   (pss-proposals st) (pss-proposal-lists st)
                   (pss-scenarios st) (pss-scenario-definitions st) new-meta
                   new-tag-idx new-ibs new-cbs new-ibp new-cbpl
                   (pss-commitments-by-process st)))))))

    ;; --- Merge: monoidal fold of source into self ---

    ((merge source-plan-store)
     ;; Query source actor for all records, fold into local state.
     ;; Merge IS the monoid operation: (fold add source-records identity-state).
     ;; We build the new state in one bcom (not N separate transitions).
     (let* (;; Query source
            (their-intents ($ source-plan-store 'all-intents))
            (their-commits ($ source-plan-store 'all-commitments))
            (their-plans   ($ source-plan-store 'all-plans))
            ;; Fold intents into local maps + indexes
            (merged-intents
              (fold (lambda (i hm) (hashmap-set hm (intent-id i) i))
                    (pss-intents st) their-intents))
            (merged-tag-idx
              (fold (lambda (i idx)
                      (fold (lambda (tag ix)
                              (let ((existing (hashmap-ref ix tag '())))
                                (if (member (intent-id i) existing) ix
                                    (hashmap-set ix tag (cons (intent-id i) existing)))))
                            idx (or (intent-resource-classified-as i) '())))
                    (pss-tag-index st) their-intents))
            (merged-ibs
              (fold (lambda (i idx)
                      (let ((spec (intent-resource-conforms-to i)))
                        (if (not spec) idx
                            (let ((existing (hashmap-ref idx spec '())))
                              (if (member (intent-id i) existing) idx
                                  (hashmap-set idx spec (cons (intent-id i) existing)))))))
                    (pss-intents-by-spec st) their-intents))
            (merged-ibp
              (fold (lambda (i idx)
                      (let ((pw (intent-planned-within i)))
                        (if (not pw) idx
                            (let ((existing (hashmap-ref idx pw '())))
                              (if (member (intent-id i) existing) idx
                                  (hashmap-set idx pw (cons (intent-id i) existing)))))))
                    (pss-intents-by-plan st) their-intents))
            ;; Fold commitments
            (merged-commits
              (fold (lambda (c hm) (hashmap-set hm (commitment-id c) c))
                    (pss-commitments st) their-commits))
            (merged-cbs
              (fold (lambda (c idx)
                      (let ((spec (commitment-resource-conforms-to c)))
                        (if (not spec) idx
                            (let ((existing (hashmap-ref idx spec '())))
                              (if (member (commitment-id c) existing) idx
                                  (hashmap-set idx spec (cons (commitment-id c) existing)))))))
                    (pss-commitments-by-spec st) their-commits))
            (merged-cbpl
              (fold (lambda (c idx)
                      (let ((pw (commitment-planned-within c)))
                        (if (not pw) idx
                            (let ((existing (hashmap-ref idx pw '())))
                              (if (member (commitment-id c) existing) idx
                                  (hashmap-set idx pw (cons (commitment-id c) existing)))))))
                    (pss-commitments-by-plan st) their-commits))
            (merged-cbpr
              (fold (lambda (c idx)
                      (let* ((a0 idx)
                             (a1 (if (commitment-input-of c)
                                     (let ((existing (hashmap-ref a0 (commitment-input-of c) '())))
                                       (if (member (commitment-id c) existing) a0
                                           (hashmap-set a0 (commitment-input-of c)
                                             (cons (commitment-id c) existing))))
                                     a0))
                             (a2 (if (commitment-output-of c)
                                     (let ((existing (hashmap-ref a1 (commitment-output-of c) '())))
                                       (if (member (commitment-id c) existing) a1
                                           (hashmap-set a1 (commitment-output-of c)
                                             (cons (commitment-id c) existing))))
                                     a1)))
                        a2))
                    (pss-commitments-by-process st) their-commits))
            ;; Fold plans
            (merged-plans
              (fold (lambda (p hm) (hashmap-set hm (plan-id p) p))
                    (pss-plans st) their-plans)))
       (bcom (^plan-store bcom
               (make-plan-store-state
                 merged-plans merged-commits merged-intents (pss-claims st)
                 (pss-agreements st) (pss-agreement-bundles st)
                 (pss-proposals st) (pss-proposal-lists st)
                 (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
                 merged-tag-idx merged-ibs merged-cbs
                 merged-ibp merged-cbpl merged-cbpr)))))

    ;; --- Recipe instantiation (full implementation) ---

    ((instantiate-recipe recipe-id recipe-store quantity due-date agents
                         . rest)
     ;; Expand recipe template into plan with processes, flows, and agreements.
     ;; Supports scaleFactor, back/forward scheduling, inventory allocation.
     (let* ((scheduling (if (pair? rest) (car rest) 'back))
            (observer (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f))
            (recipe ($ recipe-store 'get-recipe recipe-id))
            (chain ($ recipe-store 'get-process-chain recipe-id))
            ;; Compute scale factor from primary output
            (primary-spec (and recipe (recipe-primary-output recipe)))
            (last-proc (and (pair? chain) (last chain)))
            (last-outs (and last-proc
                            (cdr ($ recipe-store 'flows-for-process
                                     (recipe-process-id last-proc)))))
            (primary-flow (and last-outs primary-spec
                               (find (lambda (f)
                                       (equal? (recipe-flow-resource-conforms-to f) primary-spec))
                                     last-outs)))
            (primary-out-qty (if (and primary-flow (recipe-flow-resource-quantity primary-flow))
                                 (measure-has-numerical-value (recipe-flow-resource-quantity primary-flow))
                                 1))
            (scale-factor (/ quantity primary-out-qty))
            ;; Create plan
            (pid (generate-id "plan-"))
            (_ ($ self-ref 'add-plan
                  (make-plan pid
                    (format #f "Plan: ~a × ~a" (and recipe (recipe-name recipe)) quantity)
                    #f #f #f #f (and due-date (number->string due-date)) #f)))
            ;; Schedule processes
            (ordered-chain (if (eq? scheduling 'back) (reverse chain) chain))
            (initial-cursor (if (eq? scheduling 'back) due-date
                                (or (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                                         (caddr rest))
                                    (current-time))))
            ;; Process creation: walk chain, create Process + flows
            (processes '())
            (commitments '())
            (intents '())
            (allocated '()))
       (let proc-loop ((procs ordered-chain) (cursor initial-cursor))
         (when (pair? procs)
           (let* ((rp (car procs))
                  (dur-s (inexact->exact (round (/ (rp-duration-ms rp) 1000))))
                  (proc-begin (if (eq? scheduling 'back) (- cursor dur-s) cursor))
                  (proc-end (if (eq? scheduling 'back) cursor (+ cursor dur-s)))
                  (proc-id (generate-id "proc-"))
                  (proc (make-process proc-id (recipe-process-name rp) #f
                          (recipe-process-process-conforms-to rp)
                          #f pid #f #f
                          (number->string proc-begin) (number->string proc-end) #f))
                  (flows-pair ($ recipe-store 'flows-for-process (recipe-process-id rp)))
                  (flow-inputs (car flows-pair))
                  (flow-outputs (cdr flows-pair)))
             (set! processes (cons proc processes))
             ;; Input flows: check durable actions, inventory allocation
             (for-each
               (lambda (f)
                 (let* ((action (recipe-flow-action f))
                        (def (get-action-def action))
                        (is-durable (and def (eq? (action-definition-accounting-effect def) 'no-effect)))
                        (spec (recipe-flow-resource-conforms-to f))
                        (rq (recipe-flow-resource-quantity f))
                        (needed (if rq (* (measure-has-numerical-value rq) scale-factor) 0))
                        (unit (if rq (measure-has-unit rq) "each")))
                   ;; Durable inputs: skip demand if resource exists
                   (if (and is-durable spec observer)
                       (let ((resources (filter
                                          (lambda (r) (> (measure-qty (economic-resource-accounting-quantity r)) 0))
                                          ($ observer 'conforming-resources spec))))
                         (unless (pair? resources)
                           ;; Resource doesn't exist — create intent
                           (let ((rec (create-flow-record f proc-id 'input scale-factor
                                        (number->string proc-begin) pid agents plan-store #f)))
                             (if (commitment? rec)
                                 (set! commitments (cons rec commitments))
                                 (set! intents (cons rec intents))))))
                       ;; Non-durable: check inventory + create flow
                       (begin
                         ;; Inventory allocation (if observer available)
                         (when (and observer spec (> needed 0))
                           (let ((resources (filter
                                              (lambda (r) (> (measure-qty (economic-resource-accounting-quantity r)) 0))
                                              ($ observer 'conforming-resources spec))))
                             (let alloc-loop ((rs resources) (remaining needed))
                               (when (and (pair? rs) (> remaining 0))
                                 (let* ((r (car rs))
                                        (avail (measure-qty (economic-resource-accounting-quantity r)))
                                        (take (min avail remaining)))
                                   (set! allocated (cons `(,(economic-resource-id r) ,spec ,take) allocated))
                                   (alloc-loop (cdr rs) (- remaining take)))))))
                         ;; Create flow record
                         (let ((rec (create-flow-record f proc-id 'input scale-factor
                                      (number->string proc-begin) pid agents plan-store #f)))
                           (if (commitment? rec)
                               (set! commitments (cons rec commitments))
                               (set! intents (cons rec intents))))))))
               flow-inputs)
             ;; Output flows
             (for-each
               (lambda (f)
                 (let ((rec (create-flow-record f proc-id 'output scale-factor
                              (number->string proc-end) pid agents plan-store #f)))
                   (if (commitment? rec)
                       (set! commitments (cons rec commitments))
                       (set! intents (cons rec intents)))))
               flow-outputs)
             ;; Advance cursor
             (proc-loop (cdr procs)
                        (if (eq? scheduling 'back) proc-begin proc-end)))))
       ;; RecipeExchange → Agreement conversion
       (let ((agreements '())
             (rex-ids (and recipe (recipe-recipe-exchanges recipe))))
         (when (and rex-ids (pair? rex-ids))
           (for-each
             (lambda (rex-id)
               (let* ((rex ($ recipe-store 'get-recipe-exchange rex-id))
                      (rex-flows ($ recipe-store 'flows-for-exchange rex-id))
                      (flow-list (if (list? rex-flows) rex-flows
                                     (hashmap-values rex-flows)))
                      (bilateral? (= (length flow-list) 2))
                      (primary-cids '())
                      (reciprocal-cids '()))
                 ;; Create commitment for each exchange flow
                 (let flow-loop ((fs flow-list) (idx 0))
                   (when (pair? fs)
                     (let* ((f (car fs))
                            (cid (generate-id "exc-"))
                            (is-primary (or (and (recipe-flow-resource-classified-as f)
                                                 (member "isPrimary" (recipe-flow-resource-classified-as f)))
                                            (and bilateral? (= idx 0))))
                            (commitment (make-commitment
                                          cid (recipe-flow-action f) #f
                                          #f #f #f
                                          (recipe-flow-resource-conforms-to f)
                                          (recipe-flow-resource-classified-as f)
                                          (if (recipe-flow-resource-quantity f)
                                              (make-measure (* (measure-has-numerical-value
                                                                 (recipe-flow-resource-quantity f))
                                                               scale-factor)
                                                            (measure-has-unit
                                                              (recipe-flow-resource-quantity f)))
                                              #f)
                                          #f
                                          (and agents (assq-ref agents 'provider))
                                          (and agents (assq-ref agents 'receiver))
                                          #f #f #f #f #f #f #f #f #f #f #f #f pid #f #f)))
                       (set! commitments (cons commitment commitments))
                       (if is-primary
                           (set! primary-cids (cons cid primary-cids))
                           (set! reciprocal-cids (cons cid reciprocal-cids))))
                     (flow-loop (cdr fs) (+ idx 1))))
                 ;; Create Agreement
                 (let ((agr-id (generate-id "agr-")))
                   (set! agreements
                     (cons (make-agreement agr-id
                             (and rex (recipe-exchange-name rex)) #f
                             (number->string (current-time))
                             (if (pair? primary-cids) (reverse primary-cids) #f)
                             (if (pair? reciprocal-cids) (reverse reciprocal-cids) #f))
                           agreements)))))
             rex-ids))
         ;; Return result
         `((plan-id . ,pid)
           (processes . ,(reverse processes))
           (commitments . ,(reverse commitments))
           (intents . ,(reverse intents))
           (agreements . ,(reverse agreements))
           (allocated . ,(reverse allocated))))))

    ;; --- Proposal publishing ---

    ((publish-offer intent-id . rest)
     ;; Package intent as public offer. Optional reciprocal-intent-id.
     (let* ((intent (hashmap-ref (pss-intents st) intent-id #f))
            (reciprocal-id (and (pair? rest) (car rest))))
       (if (not intent) #f
           (let* ((prop-id (generate-id "prop-"))
                  (proposal (make-proposal prop-id #f #f #f #f #f #f
                              'offer #f #f (list intent-id)
                              (if reciprocal-id (list reciprocal-id) #f) #f)))
             (bcom (^plan-store bcom
                     (make-plan-store-state
                       (pss-plans st) (pss-commitments st) (pss-intents st) (pss-claims st)
                       (pss-agreements st) (pss-agreement-bundles st)
                       (hashmap-set (pss-proposals st) prop-id proposal)
                       (pss-proposal-lists st)
                       (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
                       (pss-tag-index st) (pss-intents-by-spec st) (pss-commitments-by-spec st)
                       (pss-intents-by-plan st) (pss-commitments-by-plan st)
                       (pss-commitments-by-process st)))
                   prop-id)))))

    ((publish-request intent-id . rest)
     (let* ((intent (hashmap-ref (pss-intents st) intent-id #f))
            (reciprocal-id (and (pair? rest) (car rest))))
       (if (not intent) #f
           (let* ((prop-id (generate-id "prop-"))
                  (proposal (make-proposal prop-id #f #f #f #f #f #f
                              'request #f #f
                              (if reciprocal-id (list reciprocal-id) #f)
                              (list intent-id) #f)))
             (bcom (^plan-store bcom
                     (make-plan-store-state
                       (pss-plans st) (pss-commitments st) (pss-intents st) (pss-claims st)
                       (pss-agreements st) (pss-agreement-bundles st)
                       (hashmap-set (pss-proposals st) prop-id proposal)
                       (pss-proposal-lists st)
                       (pss-scenarios st) (pss-scenario-definitions st) (pss-meta st)
                       (pss-tag-index st) (pss-intents-by-spec st) (pss-commitments-by-spec st)
                       (pss-intents-by-plan st) (pss-commitments-by-plan st)
                       (pss-commitments-by-process st)))
                   prop-id)))))

    ((accept-proposal proposal-id counterparty . rest)
     ;; Accept proposal: validate temporal/agent constraints, create Agreement,
     ;; promote intents to commitments with scaling, set clauseOf.
     (let* ((opts (if (pair? rest) (car rest) '()))
            (proposal (hashmap-ref (pss-proposals st) proposal-id #f)))
       (if (not proposal) (error "Proposal not found")
           (begin
             ;; Temporal validation
             (let ((now (number->string (current-time))))
               (when (and (proposal-has-end proposal)
                          (string>? now (proposal-has-end proposal)))
                 (error "Proposal expired"))
               (when (and (proposal-has-beginning proposal)
                          (string<? now (proposal-has-beginning proposal)))
                 (error "Proposal not yet open")))
             ;; proposedTo enforcement
             (when (and (proposal-proposed-to proposal)
                        (pair? (proposal-proposed-to proposal)))
               (let ((accepting (assq-ref opts 'accepting-agent-id)))
                 (unless (and accepting (member accepting (proposal-proposed-to proposal)))
                   (error "Not authorized to accept this proposal"))))
             ;; Unit-based scaling
             (let* ((unit-scale (if (and (proposal-unit-based proposal)
                                         (assq-ref opts 'unit-quantity))
                                    (assq-ref opts 'unit-quantity) 1))
                    (due-override (assq-ref opts 'due))
                    ;; Promote primary intents (publishes)
                    (primary-ids '())
                    (reciprocal-ids '())
                    (all-commitments '()))
               ;; Primary intents
               (for-each
                 (lambda (iid)
                   (let ((cid ($ self-ref 'promote-to-commitment iid counterparty)))
                     (set! primary-ids (cons cid primary-ids))
                     ;; Scale if needed
                     (when (not (= unit-scale 1))
                       ;; Note: scaling would require modifying the commitment's qty
                       ;; which needs a separate update. For now, intent qty is used as-is.
                       #f)
                     (set! all-commitments (cons cid all-commitments))))
                 (or (proposal-publishes proposal) '()))
               ;; Reciprocal intents (flip counterparty)
               (let ((flipped `((provider . ,(assq-ref counterparty 'receiver))
                                (receiver . ,(assq-ref counterparty 'provider)))))
                 (for-each
                   (lambda (iid)
                     (let ((cid ($ self-ref 'promote-to-commitment iid flipped)))
                       (set! reciprocal-ids (cons cid reciprocal-ids))
                       (set! all-commitments (cons cid all-commitments))))
                   (or (proposal-reciprocal proposal) '())))
               ;; Create Agreement
               (let ((agr-id (generate-id "agr-")))
                 ($ self-ref 'add-agreement
                    (make-agreement agr-id (proposal-name proposal) #f
                      (number->string (current-time))
                      (if (pair? primary-ids) (reverse primary-ids) #f)
                      (if (pair? reciprocal-ids) (reverse reciprocal-ids) #f)))
                 ;; Return
                 `((agreement-id . ,agr-id)
                   (commitments . ,(reverse all-commitments)))))))))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define plan-store-env
  (make-persistence-env
    `((((vf planning) ^plan-store) ,^plan-store))))
