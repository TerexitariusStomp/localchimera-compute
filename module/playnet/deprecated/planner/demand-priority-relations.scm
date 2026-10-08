;;; demand-priority-relations.scm — RETIRED relational (miniKanren) priority relations
;;;
;;; Extracted from deprecated/planner/utils/demand-priority.scm during the relational→convex
;;; planner split. These are the CLP(FD) `-o` forms of the priority lookups; the
;;; convex planner reads priority through the plain functions that remain in
;;; demand-priority.scm (default-priority-fn / make-priority-fn /
;;; harmony-level-from-facts / make-harmony-level-fn). Dead code — no callers —
;;; preserved here for the record, not loaded by any umbrella. Depends on
;;; kanren-constraints (conde/project/==/succeed/fail/in-list-o) and the
;;; fact-matches? helper that stays in demand-priority.scm.

(define (demand-priority-o facts scope-id spec-id priority)
  "Relate a demand to its governance-assigned priority.
   If no fact exists, unify with default."
  (conde
    ((in-list-o `(demand-priority ,scope-id ,spec-id ,priority) facts))
    ((absent-o facts `(demand-priority ,scope-id ,spec-id))
     (== priority *default-priority*))))

(define (absent-o facts pattern)
  "Succeed if no fact in FACTS matches PATTERN (ground check)."
  (project (facts pattern)
    (if (not (any (lambda (f) (fact-matches? f pattern)) facts))
        succeed
        fail)))

(define (harmony-level-o facts spec-id level)
  "Relate a spec to its governance-assigned harmony level.
   Defaults to *default-harmony-level* if no fact exists."
  (conde
    ((in-list-o `(harmony-priority ,spec-id ,level) facts))
    ((absent-o facts `(harmony-priority ,spec-id _))
     (== level *default-harmony-level*))))
