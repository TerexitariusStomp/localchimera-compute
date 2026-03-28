;;; agents.scm — Goblins actor for agent directory management
;;;
;;; Translated from src/lib/agents.ts (AgentStore)
;;; State: 3 hashmaps (agents, roles, relationships).

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (srfi srfi-1))

;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Record <-> list serialization
;; =========================================================================

(define (agent->list a)
  (list (agent-id a) (agent-type a) (agent-name a) (agent-note a)
        (agent-image a) (agent-primary-location a) (agent-classified-as a)
        (agent-availability-window a)))

(define (list->agent lst)
  (apply make-agent lst))

(define (agent-relationship-role->list r)
  (list (agent-relationship-role-id r)
        (agent-relationship-role-label r)
        (agent-relationship-role-inverse-label r)
        (agent-relationship-role-note r)
        (agent-relationship-role-classified-as r)))

(define (list->agent-relationship-role lst)
  (apply make-agent-relationship-role lst))

(define (agent-relationship->list r)
  (list (agent-relationship-id r)
        (agent-relationship-subject r)
        (agent-relationship-object r)
        (agent-relationship-relationship r)
        (agent-relationship-in-scope-of r)
        (agent-relationship-note r)))

(define (list->agent-relationship lst)
  (apply make-agent-relationship lst))


;; =========================================================================
;; ^agent-store
;; =========================================================================

(define-actor (^agent-store bcom agents roles relationships)
  ;; agents:        hashmap of string -> <agent>
  ;; roles:         hashmap of string -> <agent-relationship-role>
  ;; relationships: hashmap of string -> <agent-relationship>

  #:portrait
  (lambda ()
    (list (serialize-hashmap agents agent->list)
          (serialize-hashmap roles agent-relationship-role->list)
          (serialize-hashmap relationships agent-relationship->list)))

  #:version 1

  #:restore
  (lambda (version sa sr srel)
    (case version
      ((1) (spawn ^agent-store
                  (deserialize-hashmap sa list->agent)
                  (deserialize-hashmap sr list->agent-relationship-role)
                  (deserialize-hashmap srel list->agent-relationship)))
      (else (error "Unknown ^agent-store version" version))))

  (methods

    ;; --- Agents ---

    ((add-agent ag)
     (let* ((id (or (agent-id ag) (generate-id "agent-")))
            (new-agents (hashmap-set agents id ag)))
       (bcom (^agent-store bcom new-agents roles relationships) id)))

    ((get-agent id)
     (hashmap-ref agents id #f))

    ((all-agents)
     (hashmap-values agents))

    ((people)
     (hashmap-filter (lambda (a) (eq? (agent-type a) 'person)) agents))

    ((organizations)
     (hashmap-filter (lambda (a) (eq? (agent-type a) 'organization)) agents))

    ((ecological-agents)
     (hashmap-filter (lambda (a) (eq? (agent-type a) 'ecological-agent)) agents))

    ;; --- Roles ---

    ((add-role role)
     (let* ((id (or (agent-relationship-role-id role) (generate-id "role-")))
            (new-roles (hashmap-set roles id role)))
       (bcom (^agent-store bcom agents new-roles relationships) id)))

    ((get-role id)
     (hashmap-ref roles id #f))

    ((all-roles)
     (hashmap-values roles))

    ;; --- Relationships ---

    ((add-relationship rel)
     (let* ((id (or (agent-relationship-id rel) (generate-id "rel-")))
            (new-rels (hashmap-set relationships id rel)))
       (bcom (^agent-store bcom agents roles new-rels) id)))

    ((get-relationship id)
     (hashmap-ref relationships id #f))

    ((all-relationships)
     (hashmap-values relationships))

    ((relationships-as-subject agent-id)
     (hashmap-filter
       (lambda (r) (equal? (agent-relationship-subject r) agent-id))
       relationships))

    ((relationships-as-object agent-id)
     (hashmap-filter
       (lambda (r) (equal? (agent-relationship-object r) agent-id))
       relationships))

    ((relationships-for-role role-id)
     (hashmap-filter
       (lambda (r) (equal? (agent-relationship-relationship r) role-id))
       relationships))

    ((relationships-in-scope scope-agent-id)
     (hashmap-filter
       (lambda (r) (equal? (agent-relationship-in-scope-of r) scope-agent-id))
       relationships))

    ;; --- Mutations ---

    ((remove-relationship id)
     (if (hashmap-ref relationships id #f)
         (bcom (^agent-store bcom agents roles (hashmap-remove relationships id)) #t)
         #f))

    ((remove-agent id)
     ;; Cascade: remove all relationships where agent is subject or object.
     ;; Returns list of removed relationship IDs.
     (let* ((removed-ids
              (hashmap-fold
                (lambda (rid rel acc)
                  (if (or (equal? (agent-relationship-subject rel) id)
                          (equal? (agent-relationship-object rel) id))
                      (cons rid acc)
                      acc))
                '() relationships))
            (new-rels (fold (lambda (rid hm) (hashmap-remove hm rid))
                            relationships removed-ids))
            (new-agents (hashmap-remove agents id)))
       (bcom (^agent-store bcom new-agents roles new-rels) removed-ids)))

    ((clear)
     (bcom (^agent-store bcom (hashmap) (hashmap) (hashmap))))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define agent-store-env
  (make-persistence-env
    `((((vf agents) ^agent-store) ,^agent-store))))
