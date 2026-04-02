;;; trace.scm — Relational provenance and destination tracing
;;;
;;; No dependency on knowledge.scm. Relations ARE the hyperarcs.
;;; Transitive closure via depth-bounded recursive conde.

(use-modules (playnet kanren-constraints))

(define *default-trace-depth* 10)


;;; ── Edge relations ────────────────────────────────────────────────────────────

(define (produces-o facts spec-id input-spec-id)
  "SPEC-ID is produced by a process that consumes INPUT-SPEC-ID.
   Works for both primary outputs and intermediate products."
  (fresh (rid rname primary-out pid pid2 qty qty2 unit unit2 action action2 pids)
    ;; Find any recipe and its process chain
    (recipe-o facts rid rname primary-out)
    (chain-o facts rid pids)
    ;; Find a process in that chain that outputs spec-id
    (flow-o facts pid 'output spec-id qty unit action)
    (project (pids pid) (if (member pid pids) succeed fail))
    ;; Find a process in that chain that inputs input-spec-id
    (flow-o facts pid2 'input input-spec-id qty2 unit2 action2)
    (project (pids pid2) (if (member pid2 pids) succeed fail))))

(define (consumed-by-o facts spec-id output-spec-id)
  "SPEC-ID is consumed to produce OUTPUT-SPEC-ID."
  (produces-o facts output-spec-id spec-id))


;;; ── Provenance (backward trace with proof) ────────────────────────────────────

(define* (provenance-o facts spec-id ancestor trace #:optional (depth *default-trace-depth*))
  "What inputs are needed (transitively) for SPEC-ID?"
  (if (= depth 0) fail
      (conde
        ;; Base: direct input
        ((produces-o facts spec-id ancestor)
         (== trace (list spec-id ancestor)))
        ;; Step: through an intermediate
        ((fresh (mid rest)
           (produces-o facts spec-id mid)
           (provenance-o facts mid ancestor rest (- depth 1))
           (== trace (cons spec-id rest)))))))


;;; ── Destination (forward trace with proof) ────────────────────────────────────

(define* (destination-o facts spec-id downstream trace #:optional (depth *default-trace-depth*))
  "What can be produced (transitively) from SPEC-ID?"
  (if (= depth 0) fail
      (conde
        ((consumed-by-o facts spec-id downstream)
         (== trace (list spec-id downstream)))
        ((fresh (mid rest)
           (consumed-by-o facts spec-id mid)
           (destination-o facts mid downstream rest (- depth 1))
           (== trace (cons spec-id rest)))))))


;;; ── Custody level (bidirectional zone classification) ──────────────────────────

(define (custody-level-o value levels level)
  "Relate a VALUE to the minimum custody LEVEL covering it."
  (in-list-o level levels)
  (project (value level)
    (if (>= (assq-ref level 'limit) value) succeed fail)))
