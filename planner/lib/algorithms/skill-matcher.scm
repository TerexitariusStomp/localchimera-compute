;;; skill-matcher.scm — Match work flows to agents by skill
;;;
;;; Pure function (no actor state). Given work RecipeFlows, queries the
;;; observer for agents holding the required skill (resource-conforms-to)
;;; and returns per-flow agent assignments.
;;;
;;; Algorithm: Greedy, most-constrained-first (standard CSP heuristic).
;;; Sort work flows by candidate count (fewest first), then assign.

(use-modules (srfi srfi-1)
             (goblins utils hashmap))

;; Assumes schemas.scm is loaded.


(define* (match-work-flows work-flows observer agent-store
                           #:key (scope-id #f) (already-assigned '()))
  "Match work WORK-FLOWS to agents by skill.
   WORK-FLOWS: list of RecipeFlow records with action='work.
   OBSERVER: observer actor (has 'agents-with-skill method).
   AGENT-STORE: agent-store actor (has 'relationships-in-scope method), or #f.
   SCOPE-ID: if set, restrict candidates to agents with a relationship in scope.
   ALREADY-ASSIGNED: list of agent-ids already committed (avoid double-booking).
   Returns alist: ((flow-id . agent-id-or-#f) ...)"

  ;; Collect scope members if filtering by scope
  (let* ((scope-members
           (if (and scope-id agent-store)
               (let ((rels ($ agent-store 'relationships-in-scope scope-id)))
                 (delete-duplicates
                   (map agent-relationship-subject (hashmap-values rels))))
               #f))

         ;; Build (flow . candidates) pairs
         (flow-candidates
           (map (lambda (f)
                  (let* ((spec-id (recipe-flow-resource-conforms-to f))
                         (raw (if (and observer spec-id)
                                  ($ observer 'agents-with-skill spec-id)
                                  '()))
                         ;; Filter by scope membership
                         (scoped (if scope-members
                                     (filter (lambda (a) (member a scope-members)) raw)
                                     raw)))
                    (cons f scoped)))
                work-flows))

         ;; Sort by candidate count (fewest first — most constrained)
         (sorted (sort flow-candidates
                   (lambda (a b) (< (length (cdr a)) (length (cdr b)))))))

    ;; Greedy assignment
    (let assign-loop ((remaining sorted)
                      (assigned already-assigned)
                      (result '()))
      (if (null? remaining)
          (reverse result)
          (let* ((entry (car remaining))
                 (flow (car entry))
                 (candidates (cdr entry))
                 ;; Remove already-assigned agents
                 (available (filter (lambda (a) (not (member a assigned))) candidates))
                 ;; Pick first available (or #f)
                 (picked (if (pair? available) (car available) #f)))
            (assign-loop
              (cdr remaining)
              (if picked (cons picked assigned) assigned)
              (cons (cons (recipe-flow-id flow) picked) result)))))))
