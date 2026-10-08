;;; trace.scm — Relational provenance and destination tracing
;;;
;;; No dependency on knowledge.scm. Relations ARE the hyperarcs.
;;; Uses transitive-closure-o from (playnet deprecated kanren-constraints).

(define-module (playnet deprecated planner relational trace)
  #:use-module (playnet deprecated planner relational planning-facts)
  #:export (*default-trace-depth* produces-o consumed-by-o provenance-o destination-o
            custody-level-o))

(use-modules (playnet deprecated kanren-constraints))

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


;;; ── Provenance & Destination (instances of transitive-closure-o) ─────────────

(define* (provenance-o facts spec-id ancestor trace
                       #:optional (depth *default-trace-depth*))
  "What inputs are needed (transitively) for SPEC-ID?"
  (transitive-closure-o (lambda (a b) (produces-o facts a b))
                        spec-id ancestor trace depth))

(define* (destination-o facts spec-id downstream trace
                        #:optional (depth *default-trace-depth*))
  "What can be produced (transitively) from SPEC-ID?"
  (transitive-closure-o (lambda (a b) (consumed-by-o facts a b))
                        spec-id downstream trace depth))


;;; ── Custody level (bidirectional zone classification) ──────────────────────────

(define (custody-level-o value levels level)
  "Relate a VALUE to the minimum custody LEVEL covering it."
  (in-list-o level levels)
  (project (value level)
    (if (>= (assq-ref level 'limit) value) succeed fail)))
