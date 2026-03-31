;;; trace.scm — Relational provenance and destination tracing
;;;
;;; No dependency on knowledge.scm. Relations ARE the hyperarcs.
;;; Transitive closure via depth-bounded recursive conde.

(use-modules (playnet kanren-constraints))

(define *default-trace-depth* 10)


;;; ── Edge relations ────────────────────────────────────────────────────────────

(define (produces-o facts spec-id input-spec-id)
  "SPEC-ID is produced by a recipe that consumes INPUT-SPEC-ID."
  (fresh (rid rname pid qty unit action pids)
    (recipe-o facts rid rname spec-id)
    (chain-o facts rid pids)
    (flow-o facts pid 'input input-spec-id qty unit action)
    (project (pids pid)
      (if (member pid pids) succeed fail))))

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
