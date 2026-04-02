;;; planning-facts.scm — Lift, index, and query planning facts
;;;
;;; Facts are lifted once at session start. Indexes are built for O(1)
;;; key lookup. Relation functions use indexed sublists instead of
;;; scanning the full N-element fact list.
;;;
;;; recipe-o scans O(R) recipes for a spec, not O(N) total facts.
;;; flow-o scans O(F) flows for a process, not O(N).
;;; inventory-o scans O(I) resources for a spec, not O(N).

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

;; Actions excluded from recursive demand explosion. 'use' resources (tools,
;; compute, ovens) are handled separately with time-windowed allocation via
;; use-schedule-inputs / solve-use-inputs-o in demand-relation.scm.
(define *non-consuming-actions* '(use work cite deliver-service))


;;; ── Index builder ─────────────────────────────────────────────────────────────

(define (build-indexes facts)
  "Build hash-table indexes for O(1) key lookup.
   Returns alist of (index-name . hash-table)."
  (let ((recipes-by-output (make-hash-table))
        (chains-by-recipe (make-hash-table))
        (flows-by-process (make-hash-table))
        (inventory-by-spec (make-hash-table))
        (buffer-by-spec (make-hash-table)))
    (for-each (lambda (f)
      (case (car f)
        ((recipe)
         (let ((output (cadddr f)))
           (hash-set! recipes-by-output output
             (cons f (hash-ref recipes-by-output output '())))))
        ((chain)
         (hash-set! chains-by-recipe (cadr f) f))
        ((flow)
         (let ((pid (cadr f)))
           (hash-set! flows-by-process pid
             (cons f (hash-ref flows-by-process pid '())))))
        ((inventory)
         (let ((spec (caddr f)))
           (hash-set! inventory-by-spec spec
             (cons f (hash-ref inventory-by-spec spec '())))))
        ((buffer-zone)
         (hash-set! buffer-by-spec (cadr f) f))))
      facts)
    `((recipes-by-output . ,recipes-by-output)
      (chains-by-recipe . ,chains-by-recipe)
      (flows-by-process . ,flows-by-process)
      (inventory-by-spec . ,inventory-by-spec)
      (buffer-by-spec . ,buffer-by-spec))))

(define (idx-ref indexes name key)
  "O(1) index lookup. Returns list of matching facts or '()."
  (let ((table (assq-ref indexes name)))
    (if table (hash-ref table key '()) '())))

(define (idx-ref-single indexes name key)
  "O(1) lookup for single-valued indexes. Returns fact or #f."
  (let ((table (assq-ref indexes name)))
    (if table (hash-ref table key #f) #f)))


;;; ── Lift ──────────────────────────────────────────────────────────────────────

(define* (lift-planning-facts recipe-store #:optional (observer #f)
                              (plan-store #f) (buffer-zone-store #f)
                              (live-registry #f))
  "Extract all planning facts. Recipes sorted by SNE (lowest first)."
  (let* ((all-recipes ($ recipe-store 'all-recipes))
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
                        (let ((mbq (recipe-process-minimum-batch-quantity rp)))
                          `(process ,(recipe-process-id rp)
                                    ,(recipe-process-name rp)
                                    ,(rp-duration-ms rp)
                                    ,(if mbq
                                         (inexact->exact
                                           (ceiling (measure-has-numerical-value mbq)))
                                         1))))
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
                                       ,(recipe-flow-action f)
                                       ,(recipe-flow-resolve-from-flow f)))
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
                                       ,(recipe-flow-action f)
                                       ,(recipe-flow-resolve-from-flow f)))
                              outputs))))
                   chain)))
             all-recipes))
         (unsorted-recipes
           (map (lambda (r)
                  `(recipe ,(recipe-id r) ,(recipe-name r) ,(recipe-primary-output r)))
                all-recipes))
         (structural-facts (append unsorted-recipes chain-facts process-facts flow-facts))
         (sne-index (build-sne-index structural-facts))
         (sorted-recipes
           (sort unsorted-recipes
                 (lambda (a b)
                   (let ((sne-a (or (assoc-ref sne-index (cadddr a)) 999999))
                         (sne-b (or (assoc-ref sne-index (cadddr b)) 999999)))
                     (< sne-a sne-b))))))
    (append
      sorted-recipes chain-facts process-facts flow-facts
      (if observer
          (filter-map
            (lambda (r)
              (let* ((rid (economic-resource-id r))
                     (live (and live-registry ($ live-registry 'get rid)))
                     (qty (if live
                              ($ live 'available)
                              (measure-qty (economic-resource-accounting-quantity r)))))
                (and (> qty 0)
                     `(inventory ,rid
                                ,(economic-resource-conforms-to r)
                                ,(inexact->exact (round qty))
                                ,(economic-resource-current-location r)
                                ,(economic-resource-contained-in r)))))
            ($ observer 'all-resources))
          '())
      (if observer
          (map (lambda (e)
                 `(event ,(economic-event-id e)
                         ,(economic-event-action e)
                         ,(economic-event-resource-conforms-to e)
                         ,(if (economic-event-resource-quantity e)
                              (inexact->exact (round (measure-has-numerical-value
                                (economic-event-resource-quantity e)))) 0)
                         ,(if (economic-event-has-point-in-time e)
                              (iso-datetime->epoch (economic-event-has-point-in-time e)) #f)))
               ($ observer 'all-events))
          '())
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
      (if buffer-zone-store
          (map (lambda (bz)
                 `(buffer-zone ,(buffer-zone-spec-id bz)
                               ,(buffer-zone-tor bz) ,(buffer-zone-toy bz)
                               ,(buffer-zone-tog bz) ,(buffer-zone-adu bz)
                               ,(buffer-zone-dlt-days bz)))
               ($ buffer-zone-store 'all-zones))
          '()))))


;;; ── Indexed fact relations ────────────────────────────────────────────────────
;;; These use the index for O(1) key lookup, then scan O(R) or O(I) matches.
;;; Falls back to full scan when no index available.

(define (recipe-o facts rid name output)
  "O(R) per spec — indexed by output spec."
  (in-list-o `(recipe ,rid ,name ,output) facts))

(define (recipe-indexed-o indexes output rid name)
  "O(R) — indexed lookup by output spec. Returns recipes for this output."
  (let ((matches (idx-ref indexes 'recipes-by-output output)))
    (if (null? matches)
        fail
        (in-list-o `(recipe ,rid ,name ,output) matches))))

(define (chain-indexed-o indexes rid pids)
  "O(1) — direct lookup by recipe-id. Walks rid in substitution first."
  (lambda (st)
    (let* ((walked (walk* rid (cstate-S st)))
           (fact (idx-ref-single indexes 'chains-by-recipe walked)))
      (if fact ((== pids (caddr fact)) st) '()))))

(define (flow-indexed-o indexes pid direction spec-id qty unit action)
  "O(F) per process — indexed by process-id. Walks pid in substitution first."
  (lambda (st)
    (let* ((walked (walk* pid (cstate-S st)))
           (matches (idx-ref indexes 'flows-by-process walked)))
      (if (null? matches)
          '()
          ((fresh (resolve-from)
             (in-list-o `(flow ,walked ,direction ,spec-id ,qty ,unit ,action ,resolve-from)
                        matches))
           st)))))

(define (inventory-indexed-o indexes spec-id resource-id qty location)
  "O(I) per spec — indexed by spec-id."
  (let ((matches (idx-ref indexes 'inventory-by-spec spec-id)))
    (if (null? matches)
        fail
        (in-list-o `(inventory ,resource-id ,spec-id ,qty ,location) matches))))

(define (buffer-zone-indexed-o indexes spec-id tor toy tog adu dlt)
  "O(1) — direct lookup by spec-id."
  (let ((fact (idx-ref-single indexes 'buffer-by-spec spec-id)))
    (if fact
        (== `(buffer-zone ,spec-id ,tor ,toy ,tog ,adu ,dlt) fact)
        fail)))


;;; ── Unindexed fallbacks (for backward compatibility) ──────────────────────────

(define (chain-o facts rid pids)
  (in-list-o `(chain ,rid ,pids) facts))

(define (process-o facts pid name duration-ms)
  (fresh (mbq)
    (in-list-o `(process ,pid ,name ,duration-ms ,mbq) facts)))

(define (flow-o facts pid direction spec-id qty unit action)
  (fresh (resolve-from)
    (in-list-o `(flow ,pid ,direction ,spec-id ,qty ,unit ,action ,resolve-from) facts)))

(define (inventory-o facts resource-id spec-id qty location)
  (fresh (contained-in)
    (in-list-o `(inventory ,resource-id ,spec-id ,qty ,location ,contained-in) facts)))
