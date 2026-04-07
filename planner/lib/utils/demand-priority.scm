;;; demand-priority.scm — Pluggable priority for cross-scope retraction
;;;
;;; Priority is modular:
;;;   1. Default: composite-buffer-priority from buffer-type.scm
;;;      (legacy — retraction-sort semantics, lower number = more urgent)
;;;   2. Governance: callback (scope-id spec-id) -> number, overrides default
;;;   3. Relational: (demand-priority scope-id spec-id priority) fact
;;;
;;; Two priority conventions coexist during the harmony migration:
;;;
;;;   Legacy retraction-sort (lower = more urgent): range 10 (ecological/red)
;;;   to 63 (consumption/excess). Used by existing retract-across-scopes
;;;   which sorts ascending for deficits.
;;;
;;;   Harmony level (higher = more important): small integer 0-10,
;;;   governance-set per spec. Exponentiated internally to a weight
;;;   multiplier (base^level ≈ 1000x spread over 9 levels). Used by the
;;;   harmony function. See make-harmony-level-fn below.

(use-modules (srfi srfi-1))


;;; ── Default: buffer tier ────────────────────────────────────────────────────

(define *default-priority* 53)  ;; metabolic/green

(define (default-priority-fn spec-id buffer-zone-store)
  "Priority from buffer tier + zone. Returns number (lower = more urgent)."
  (if (not buffer-zone-store)
      *default-priority*
      (let ((bz ($ buffer-zone-store 'zone-for-spec spec-id)))
        (if (not bz)
            *default-priority*
            (composite-buffer-priority
              (or (buffer-zone-tier bz) 'metabolic)
              (or (assq-ref (buffer-status
                              (sum-onhand-at-location #f spec-id #f #f)
                              bz)
                            'zone)
                  'green))))))


;;; ── Relational: priority as a fact ──────────────────────────────────────────

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

(define (fact-matches? fact pattern)
  "Does FACT match PATTERN? Pattern elements that are symbols starting with _
   are treated as wildcards."
  (and (= (length fact) (length pattern))
       (every (lambda (f p)
                (or (and (symbol? p) (string-prefix? "_" (symbol->string p)))
                    (equal? f p)))
              fact pattern)))


;;; ── Governance wrapper ──────────────────────────────────────────────────────

(define* (make-priority-fn #:key (governance-fn #f) (buffer-zone-store #f))
  "Build a priority function. Governance callback overrides buffer default.
   Returns: (lambda (scope-id spec-id) -> number)

   Legacy retraction-sort convention: lower number = more urgent."
  (lambda (scope-id spec-id)
    (or (and governance-fn (governance-fn scope-id spec-id))
        (default-priority-fn spec-id buffer-zone-store))))


;;; ── Harmony priority levels (higher = more important) ──────────────────────
;;;
;;; These are the user-facing priority LEVELS (0-10) consumed by the harmony
;;; function. See planner/lib/relational/harmony.scm for the level → weight
;;; conversion.

(define *default-harmony-level* 0)  ;; unweighted baseline

(define (harmony-level-from-facts facts spec-id)
  "Look up (harmony-priority spec-id level) in facts. Returns level or #f."
  (let ((f (find (lambda (f)
                   (and (eq? (car f) 'harmony-priority)
                        (equal? (cadr f) spec-id)))
                 facts)))
    (and f (caddr f))))

(define (harmony-level-o facts spec-id level)
  "Relate a spec to its governance-assigned harmony level.
   Defaults to *default-harmony-level* if no fact exists."
  (conde
    ((in-list-o `(harmony-priority ,spec-id ,level) facts))
    ((absent-o facts `(harmony-priority ,spec-id _))
     (== level *default-harmony-level*))))

(define* (make-harmony-level-fn #:key (governance-fn #f) (facts #f))
  "Build a level function: (spec-id) -> level (integer).
   GOVERNANCE-FN is an optional callback (spec-id) -> level that overrides
   facts. FACTS is a list of lifted facts containing harmony-priority
   entries."
  (lambda (spec-id)
    (or (and governance-fn (governance-fn spec-id))
        (and facts (harmony-level-from-facts facts spec-id))
        *default-harmony-level*)))
