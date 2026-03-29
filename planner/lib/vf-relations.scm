;;; vf-relations.scm — Relational query layer over ValueFlows records
;;;
;;; miniKanren relations that pattern-match directly over VF record lists.
;;; No hyperarc conversion — the records ARE the facts.
;;;
;;; The algorithms answer known questions fast.
;;; Relations answer the questions you haven't thought of yet.
;;;
;;; Load after schemas.scm:
;;;   (primitive-load "planner/lib/schemas.scm")
;;;   (primitive-load "planner/lib/vf-relations.scm")
;;;
;;; Requires xorg/kanren.scm on the load path (-L module).

(use-modules (xorg kanren))

;;; ── Helper: membero over Scheme lists ─────────────────────────────────────
;;; Our kanren.scm exports membero, but it works on logic-variable lists.
;;; For concrete Scheme lists of records, we need a version that iterates.

(define (in-list-o x lst)
  "x is a member of concrete Scheme list LST.
   LST must be a concrete Scheme list (not a logic variable)."
  (if (null? lst)
      fail
      (conde
       ((== x (car lst)))
       ((in-list-o x (cdr lst))))))

;;; ── Field extraction pattern ──────────────────────────────────────────────
;;; Record accessors can't operate on logic variables. We extract fields
;;; from concrete records, then unify the results with logic variables.
;;; This macro generates the pattern: iterate list, extract, unify.

(define (choose-and-extract lst extract-fn result)
  "Choose an element from LST, apply EXTRACT-FN to get a list of values,
   then unify RESULT with that list."
  (if (null? lst)
      fail
      (let ((extracted (extract-fn (car lst))))
        (conde
         ((== result extracted))
         ((choose-and-extract (cdr lst) extract-fn result))))))

;;; ═══════════════════════════════════════════════════════════════════════════
;;; CORE ENTITY RELATIONS
;;; Destructure records into queryable fields.
;;; ═══════════════════════════════════════════════════════════════════════════

(define (event-o events eid action resource-id provider-id receiver-id)
  "Relate an event list to one event's core fields."
  (fresh (tuple)
    (choose-and-extract events
      (lambda (ev)
        (list (economic-event-id ev)
              (economic-event-action ev)
              (economic-event-resource-inventoried-as ev)
              (economic-event-provider ev)
              (economic-event-receiver ev)))
      tuple)
    (== tuple (list eid action resource-id provider-id receiver-id))))

(define (event-full-o events eid action resource-id provider-id receiver-id
                      process-in process-out cost timestamp)
  "Full event destructuring with process and cost."
  (fresh (tuple)
    (choose-and-extract events
      (lambda (ev)
        (list (economic-event-id ev)
              (economic-event-action ev)
              (economic-event-resource-inventoried-as ev)
              (economic-event-provider ev)
              (economic-event-receiver ev)
              (economic-event-input-of ev)
              (economic-event-output-of ev)
              (economic-event-effort-quantity ev)
              (economic-event-has-point-in-time ev)))
      tuple)
    (== tuple (list eid action resource-id provider-id receiver-id
                    process-in process-out cost timestamp))))

(define (resource-o resources rid spec-id accountable-id state)
  "Relate a resource list to one resource's core fields."
  (fresh (tuple)
    (choose-and-extract resources
      (lambda (r)
        (list (economic-resource-id r)
              (economic-resource-conforms-to r)
              (economic-resource-primary-accountable r)
              (economic-resource-state r)))
      tuple)
    (== tuple (list rid spec-id accountable-id state))))

(define (agent-o agents aid name type)
  "Relate an agent list to one agent's core fields."
  (fresh (tuple)
    (choose-and-extract agents
      (lambda (a)
        (list (agent-id a) (agent-name a) (agent-type a)))
      tuple)
    (== tuple (list aid name type))))

(define (process-o processes pid name)
  "Relate a process list to one process's core fields."
  (fresh (tuple)
    (choose-and-extract processes
      (lambda (p) (list (process-id p) (process-name p)))
      tuple)
    (== tuple (list pid name))))

(define (spec-o specs sid name)
  "Relate a spec list to one spec's core fields."
  (fresh (tuple)
    (choose-and-extract specs
      (lambda (s) (list (resource-specification-id s) (resource-specification-name s)))
      tuple)
    (== tuple (list sid name))))

;;; ═══════════════════════════════════════════════════════════════════════════
;;; FK TRAVERSAL — navigate links between records
;;; ═══════════════════════════════════════════════════════════════════════════

(define (provides-resource-o events resources agent-id resource-id)
  "AGENT-ID is the primary accountable for RESOURCE-ID."
  (fresh (spec state)
    (resource-o resources resource-id spec agent-id state)))

(define (event-for-resource-o events resource-id eid action)
  "Event EID with ACTION affects RESOURCE-ID."
  (fresh (provider receiver)
    (event-o events eid action resource-id provider receiver)))

(define (event-by-agent-o events agent-id eid role)
  "Agent AGENT-ID participates in event EID as ROLE (provider or receiver)."
  (fresh (action resource other)
    (conde
     ((event-o events eid action resource agent-id other)
      (== role 'provider))
     ((event-o events eid action resource other agent-id)
      (== role 'receiver)))))

(define (event-in-process-o events eid process-id direction)
  "Event EID connects to PROCESS-ID as DIRECTION (input or output)."
  (fresh (action resource provider receiver proc-in proc-out cost ts)
    (event-full-o events eid action resource provider receiver proc-in proc-out cost ts)
    (conde
     ((== process-id proc-in) (== direction 'input))
     ((== process-id proc-out) (== direction 'output)))))

(define (process-input-o events process-id resource-id)
  "RESOURCE-ID is consumed as input by PROCESS-ID."
  (fresh (eid action provider receiver proc-out cost ts)
    (event-full-o events eid action resource-id provider receiver process-id proc-out cost ts)))

(define (process-output-o events process-id resource-id)
  "RESOURCE-ID is produced as output by PROCESS-ID."
  (fresh (eid action provider receiver proc-in cost ts)
    (event-full-o events eid action resource-id provider receiver proc-in process-id cost ts)))

(define (resource-spec-o resources specs resource-id spec-name)
  "RESOURCE-ID conforms to a spec with SPEC-NAME."
  (fresh (spec-id accountable state)
    (resource-o resources resource-id spec-id accountable state)
    (spec-o specs spec-id spec-name)))

;;; ═══════════════════════════════════════════════════════════════════════════
;;; TRANSITIVE RELATIONS — chains with proof traces
;;; ═══════════════════════════════════════════════════════════════════════════

(define *max-chain-depth* 10)

(define (resource-flow-o events from-agent to-agent proof)
  "Resources flow from FROM-AGENT to TO-AGENT via events.
   PROOF is a list of (event-id action resource-id) triples."
  (resource-flow-step events from-agent to-agent proof *max-chain-depth*))

(define (resource-flow-step events from to proof depth)
  (if (= depth 0)
      fail
      (conde
       ;; Direct: one event where from=provider, to=receiver
       ((fresh (eid action resource)
          (event-o events eid action resource from to)
          (== proof (list (list eid action resource)))))
       ;; Transitive: from→mid via one event, then mid→to recursively
       ((fresh (eid action resource mid rest-proof)
          (event-o events eid action resource from mid)
          (resource-flow-step events mid to rest-proof (- depth 1))
          (== proof (cons (list eid action resource) rest-proof)))))))

(define (event-chain-o events first-eid last-eid proof)
  "Chain of events linked via previous-event, from FIRST-EID to LAST-EID.
   PROOF is the list of event IDs in order."
  (event-chain-step events first-eid last-eid proof *max-chain-depth*))

(define (event-chain-step events first last proof depth)
  (if (= depth 0)
      fail
      (conde
       ;; Base: first IS last
       ((== first last)
        (== proof (list first)))
       ;; Step: find an event whose previous-event is first, recurse
       ((fresh (tuple mid rest)
          (choose-and-extract events
            (lambda (ev)
              (list (economic-event-id ev) (economic-event-previous-event ev)))
            tuple)
          (== tuple (list mid first))
          (event-chain-step events mid last rest (- depth 1))
          (== proof (cons first rest)))))))

(define (custody-chain-o events resource-id agents)
  "Who held RESOURCE-ID over time? AGENTS is a list of provider agent-ids."
  (let ((relevant (filter (lambda (ev)
                            (equal? (economic-event-resource-inventoried-as ev)
                                    resource-id))
                          events)))
    (== agents (map economic-event-provider relevant))))

;;; ═══════════════════════════════════════════════════════════════════════════
;;; AGGREGATE QUERIES — pure Scheme over relational results
;;; ═══════════════════════════════════════════════════════════════════════════

(define (query-events-for-resource events resource-id)
  "All events affecting RESOURCE-ID."
  (run* (q)
    (fresh (eid action)
      (event-for-resource-o events resource-id eid action)
      (== q (list eid action)))))

(define (query-events-by-agent events agent-id)
  "All events involving AGENT-ID (as provider or receiver)."
  (run* (q)
    (fresh (eid role)
      (event-by-agent-o events agent-id eid role)
      (== q (list eid role)))))

(define (query-resource-flow events from-agent to-agent)
  "How do resources flow from one agent to another? Returns proof traces."
  (run 10 (proof)
    (resource-flow-o events from-agent to-agent proof)))

(define (query-process-io events process-id)
  "What goes in and out of a process?"
  (let ((inputs  (run* (r) (process-input-o events process-id r)))
        (outputs (run* (r) (process-output-o events process-id r))))
    `((inputs . ,inputs) (outputs . ,outputs))))

(define (query-who-provided events resource-id)
  "Which agents provided events for this resource?"
  (run* (agent)
    (fresh (eid action receiver)
      (event-o events eid action resource-id agent receiver))))

(define (query-who-received events resource-id)
  "Which agents received via events for this resource?"
  (run* (agent)
    (fresh (eid action provider)
      (event-o events eid action resource-id provider agent))))
