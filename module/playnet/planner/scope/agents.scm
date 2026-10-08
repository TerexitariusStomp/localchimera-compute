;;; agents.scm — Goblins actor for agent directory management
;;;
;;; Translated from src/lib/agents.ts (AgentStore)
;;; State: 3 hashmaps (agents, roles, relationships).

(define-module (playnet planner scope agents)
  #:use-module (playnet planner vf schemas)
  #:use-module ((playnet utils records) #:select (vf-record-from-list))
  #:use-module (playnet utils store-utils)
  #:use-module (playnet planner vf serdes)
  #:use-module (playnet planner vf serdes-bindings)   ; the registered record types vf-serialize reads
  #:use-module (goblins utils hashmap)
  #:export (agent->list list->agent agent-relationship-role->list
            list->agent-relationship-role agent-relationship->list
            list->agent-relationship ^agent-store agent-store-env)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1))


;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Record <-> list serialization
;; =========================================================================

(define (agent->list a)
  ;; the availabilityWindow is a NESTED record — serialize it (vf-serialize, the
  ;; self-describing format the plan-store uses) so the agent-store persists it,
  ;; not the raw record (which the persistence layer can't apply → "Wrong type").
  (list (agent-id a) (agent-type a) (agent-name a) (agent-note a)
        (agent-image a) (agent-primary-location a) (agent-classified-as a)
        (let ((w (agent-availability-window a))) (and w (vf-serialize w)))))

(define list->agent
  (let ((read (vf-record-from-list <agent>)))
    (lambda (lst)
      (read (if (and (> (length lst) 7) (list-ref lst 7))   ; deserialize the window back
                (append (list-head lst 7) (list (vf-deserialize (list-ref lst 7))))
                lst)))))

(define (agent-relationship-role->list r)
  (list (agent-relationship-role-id r)
        (agent-relationship-role-label r)
        (agent-relationship-role-inverse-label r)
        (agent-relationship-role-note r)
        (agent-relationship-role-classified-as r)))

(define list->agent-relationship-role (vf-record-from-list <agent-relationship-role>))

(define (agent-relationship->list r)
  (list (agent-relationship-id r)
        (agent-relationship-subject r)
        (agent-relationship-object r)
        (agent-relationship-relationship r)
        (agent-relationship-in-scope-of r)
        (agent-relationship-note r)))

(define list->agent-relationship (vf-record-from-list <agent-relationship>))


;; =========================================================================
;; ^agent-store
;; =========================================================================

(define-actor (^agent-store bcom agents roles relationships
                           #:optional (callbacks '()))
  ;; agents:        hashmap of string -> <agent>
  ;; roles:         hashmap of string -> <agent-relationship-role>
  ;; relationships: hashmap of string -> <agent-relationship>
  ;; callbacks:     optional alist of (key . proc)
  ;;   on-agent: (proc agent) — fired after add/update
  ;;   on-agent-removed: (proc id) — fired when an agent is removed
  ;; NOTE: goblins' define-actor does NOT accept a dotted rest arg in
  ;; the actor formals (its main pattern is a proper list, and
  ;; parse-arg-names only knows #:optional/#:key/#:rest) — use
  ;; #:optional, not `. maybe-callbacks`, or the whole form fails to
  ;; match. Also, #:portrait/#:version/#:restore must precede any
  ;; internal (define ...) since keyword parsing stops at the first
  ;; non-keyword form.
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

  (define on-agent (assq-ref callbacks 'on-agent))
  (define on-agent-removed (assq-ref callbacks 'on-agent-removed))

  (methods

    ;; --- Agents ---

    ((add-agent ag)
     (let* ((id (or (agent-id ag) (generate-id "agent-")))
            (new-agents (hashmap-set agents id ag)))
       (when on-agent (on-agent ag))
       (bcom (^agent-store bcom new-agents roles relationships callbacks) id)))

    ((update-agent id updater)
     "Replace agent ID with (updater old-agent) → new-agent."
     (let ((old (hashmap-ref agents id #f)))
       (if (not old) #f
           (let* ((new-ag (updater old))
                  (new-agents (hashmap-set agents id new-ag)))
             (when on-agent (on-agent new-ag))
             (bcom (^agent-store bcom new-agents roles relationships
                                callbacks)
                   id)))))

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
       (bcom (^agent-store bcom agents new-roles relationships callbacks) id)))

    ((get-role id)
     (hashmap-ref roles id #f))

    ((all-roles)
     (hashmap-values roles))

    ;; --- Relationships ---

    ((add-relationship rel)
     (let* ((id (or (agent-relationship-id rel) (generate-id "rel-")))
            (new-rels (hashmap-set relationships id rel)))
       (bcom (^agent-store bcom agents roles new-rels callbacks) id)))

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
         (bcom (^agent-store bcom agents roles (hashmap-remove relationships id) callbacks) #t)
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
       (when on-agent-removed (on-agent-removed id))
       (bcom (^agent-store bcom new-agents roles new-rels callbacks) removed-ids)))

    ((set-on-agent proc)
     (bcom (^agent-store bcom agents roles relationships
                         (cons (cons 'on-agent proc) callbacks))))

    ((set-on-agent-removed proc)
     (bcom (^agent-store bcom agents roles relationships
                         (cons (cons 'on-agent-removed proc) callbacks))))

    ((clear)
     (bcom (^agent-store bcom (hashmap) (hashmap) (hashmap) callbacks)))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define agent-store-env
  (make-persistence-env
    `((((vf agents) ^agent-store) ,^agent-store))))
