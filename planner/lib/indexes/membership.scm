;;; membership.scm — Membership index: citizen/scope mapping
;;;
;;; Builds from agents + relationships. Maps persons to scopes.

(use-modules (srfi srfi-1) (goblins utils hashmap))

(define (build-membership-index agents relationships)
  "Build membership index from agent/relationship lists.
   Returns alist: ((citizens . list) (person-to-scope . hashmap)
                    (scope-parent . hashmap) (scope-to-citizens . hashmap))."
  (let ((citizens '())
        (person-to-scope (hashmap))
        (scope-parent (hashmap))
        (scope-to-citizens (hashmap)))
    ;; Collect citizens (Person agents)
    (for-each
      (lambda (a)
        (when (eq? (agent-type a) 'person)
          (set! citizens (cons (agent-id a) citizens))))
      agents)
    ;; Build scope mapping from relationships
    (for-each
      (lambda (rel)
        (let ((subj (agent-relationship-subject rel))
              (obj (agent-relationship-object rel)))
          ;; Subject is member of object (scope)
          (when (member subj citizens)
            (set! person-to-scope (hashmap-set person-to-scope subj obj))
            (let ((existing (hashmap-ref scope-to-citizens obj '())))
              (set! scope-to-citizens
                (hashmap-set scope-to-citizens obj (cons subj existing)))))))
      relationships)
    `((citizens . ,citizens)
      (person-to-scope . ,person-to-scope)
      (scope-parent . ,scope-parent)
      (scope-to-citizens . ,scope-to-citizens))))

(define (citizen-share scope-id index)
  "Ratio of citizens whose scope is scope-id (or descendant)."
  (let ((all-citizens (assq-ref index 'citizens))
        (scope-citizens (hashmap-ref (assq-ref index 'scope-to-citizens) scope-id '())))
    (if (null? all-citizens) 0
        (/ (length scope-citizens) (length all-citizens)))))

(define (commune-share federation-id scope-id index)
  "Citizen share restricted to federation population."
  (let ((fed-citizens (hashmap-ref (assq-ref index 'scope-to-citizens) federation-id '()))
        (scope-citizens (hashmap-ref (assq-ref index 'scope-to-citizens) scope-id '())))
    (if (null? fed-citizens) 0
        (/ (length (filter (lambda (c) (member c fed-citizens)) scope-citizens))
           (length fed-citizens)))))
