;;; planning-facts.scm — Lift VF records to plain tuples, query as relations
;;;
;;; The lift runs once at session start: records → tagged tuples.
;;; Recipe facts are sorted by SNE (lowest first) so that in-list-o
;;; explores cheapest recipes first. run-plan 1 finds the lowest-cost
;;; plan. run-plan* still finds all plans via complete interleaving.
;;;
;;; Fact shapes:
;;;   (recipe    RID NAME PRIMARY-OUTPUT)
;;;   (chain     RID (PID1 PID2 ...))
;;;   (process   PID NAME DURATION-MS)
;;;   (flow      PID DIRECTION SPEC-ID QTY UNIT ACTION)
;;;   (inventory RESOURCE-ID SPEC-ID QTY LOCATION)
;;;   (event     EID ACTION SPEC-ID QTY TIMESTAMP)
;;;   (intent    IID ACTION SPEC-ID QTY UNIT DUE INPUT-OF OUTPUT-OF TAGS FINISHED)
;;;   (commitment CID ACTION SPEC-ID QTY UNIT DUE PROVIDER RECEIVER FINISHED)
;;;   (buffer-zone SPEC-ID TOR TOY TOG ADU DLT-DAYS)

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *non-consuming-actions* '(use work cite deliver-service))


;;; ── Lift ──────────────────────────────────────────────────────────────────────

(define* (lift-planning-facts recipe-store #:optional (observer #f)
                              (plan-store #f) (buffer-zone-store #f))
  "Extract all planning facts. Recipes sorted by SNE (lowest first)."
  (let* ((all-recipes ($ recipe-store 'all-recipes))
         ;; Lift non-recipe facts first (needed for SNE computation)
         (chain-facts
           (filter-map
             (lambda (r)
               (let ((chain ($ recipe-store 'get-process-chain (recipe-id r))))
                 (and (pair? chain)
                      `(chain ,(recipe-id r) ,(map recipe-process-id chain)))))
             all-recipes))
         (process-facts
           (append-map
             (lambda (r)
               (let ((chain ($ recipe-store 'get-process-chain (recipe-id r))))
                 (map (lambda (rp)
                        `(process ,(recipe-process-id rp)
                                  ,(recipe-process-name rp)
                                  ,(rp-duration-ms rp)))
                      chain)))
             all-recipes))
         (flow-facts
           (append-map
             (lambda (r)
               (let ((chain ($ recipe-store 'get-process-chain (recipe-id r))))
                 (append-map
                   (lambda (rp)
                     (let* ((pid (recipe-process-id rp))
                            (pair ($ recipe-store 'flows-for-process pid))
                            (inputs (car pair)) (outputs (cdr pair)))
                       (append
                         (map (lambda (f)
                                `(flow ,pid input
                                       ,(recipe-flow-resource-conforms-to f)
                                       ,(and (recipe-flow-resource-quantity f)
                                             (measure-has-numerical-value
                                               (recipe-flow-resource-quantity f)))
                                       ,(and (recipe-flow-resource-quantity f)
                                             (measure-has-unit
                                               (recipe-flow-resource-quantity f)))
                                       ,(recipe-flow-action f)))
                              inputs)
                         (map (lambda (f)
                                `(flow ,pid output
                                       ,(recipe-flow-resource-conforms-to f)
                                       ,(and (recipe-flow-resource-quantity f)
                                             (measure-has-numerical-value
                                               (recipe-flow-resource-quantity f)))
                                       ,(and (recipe-flow-resource-quantity f)
                                             (measure-has-unit
                                               (recipe-flow-resource-quantity f)))
                                       ,(recipe-flow-action f)))
                              outputs))))
                   chain)))
             all-recipes))
         ;; Unsorted recipe facts
         (unsorted-recipes
           (map (lambda (r)
                  `(recipe ,(recipe-id r) ,(recipe-name r) ,(recipe-primary-output r)))
                all-recipes))
         ;; Compute SNE index from structural facts
         (structural-facts (append unsorted-recipes chain-facts process-facts flow-facts))
         (sne-index (build-sne-index structural-facts))
         ;; Sort recipes by SNE (lowest first — cheapest explored first by in-list-o)
         (sorted-recipes
           (sort unsorted-recipes
                 (lambda (a b)
                   (let ((sne-a (or (assoc-ref sne-index (cadddr a)) 999999))
                         (sne-b (or (assoc-ref sne-index (cadddr b)) 999999)))
                     (< sne-a sne-b))))))
    ;; Assemble all facts
    (append
      sorted-recipes
      chain-facts
      process-facts
      flow-facts
      ;; Inventory
      (if observer
          (filter-map
            (lambda (r)
              (let ((qty (measure-qty (economic-resource-accounting-quantity r))))
                (and (> qty 0)
                     `(inventory ,(economic-resource-id r)
                                ,(economic-resource-conforms-to r)
                                ,(inexact->exact (round qty))
                                ,(economic-resource-current-location r)))))
            ($ observer 'all-resources))
          '())
      ;; Events
      (if observer
          (map (lambda (e)
                 `(event ,(economic-event-id e)
                         ,(economic-event-action e)
                         ,(economic-event-resource-conforms-to e)
                         ,(if (economic-event-resource-quantity e)
                              (inexact->exact (round (measure-has-numerical-value
                                (economic-event-resource-quantity e))))
                              0)
                         ,(if (economic-event-has-point-in-time e)
                              (iso-datetime->epoch (economic-event-has-point-in-time e))
                              #f)))
               ($ observer 'all-events))
          '())
      ;; Intents
      (if plan-store
          (map (lambda (i)
                 `(intent ,(intent-id i) ,(intent-action i)
                          ,(intent-resource-conforms-to i)
                          ,(if (intent-resource-quantity i)
                               (inexact->exact (round (measure-has-numerical-value
                                 (intent-resource-quantity i)))) 0)
                          ,(if (intent-resource-quantity i)
                               (measure-has-unit (intent-resource-quantity i)) "each")
                          ,(if (intent-due i) (iso-datetime->epoch (intent-due i)) #f)
                          ,(if (intent-input-of i) 'input #f)
                          ,(if (intent-output-of i) 'output #f)
                          ,(or (intent-resource-classified-as i) '())
                          ,(intent-finished i)))
               ($ plan-store 'all-intents))
          '())
      ;; Commitments
      (if plan-store
          (map (lambda (c)
                 `(commitment ,(commitment-id c) ,(commitment-action c)
                              ,(commitment-resource-conforms-to c)
                              ,(if (commitment-resource-quantity c)
                                   (inexact->exact (round (measure-has-numerical-value
                                     (commitment-resource-quantity c)))) 0)
                              ,(if (commitment-resource-quantity c)
                                   (measure-has-unit (commitment-resource-quantity c)) "each")
                              ,(if (commitment-due c) (iso-datetime->epoch (commitment-due c)) #f)
                              ,(commitment-provider c) ,(commitment-receiver c)
                              ,(commitment-finished c)))
               ($ plan-store 'all-commitments))
          '())
      ;; Buffer zones
      (if buffer-zone-store
          (map (lambda (bz)
                 `(buffer-zone ,(buffer-zone-spec-id bz)
                               ,(buffer-zone-tor bz) ,(buffer-zone-toy bz)
                               ,(buffer-zone-tog bz) ,(buffer-zone-adu bz)
                               ,(buffer-zone-dlt-days bz)))
               ($ buffer-zone-store 'all-zones))
          '()))))


;;; ── Fact relations ────────────────────────────────────────────────────────────

(define (recipe-o facts rid name output)
  "Relate a recipe ID, name, and primary output spec.
   Explores lowest-SNE recipes first (facts are pre-sorted)."
  (in-list-o `(recipe ,rid ,name ,output) facts))

(define (chain-o facts rid pids)
  (in-list-o `(chain ,rid ,pids) facts))

(define (process-o facts pid name duration-ms)
  (in-list-o `(process ,pid ,name ,duration-ms) facts))

(define (flow-o facts pid direction spec-id qty unit action)
  (in-list-o `(flow ,pid ,direction ,spec-id ,qty ,unit ,action) facts))

(define (inventory-o facts resource-id spec-id qty location)
  (in-list-o `(inventory ,resource-id ,spec-id ,qty ,location) facts))
