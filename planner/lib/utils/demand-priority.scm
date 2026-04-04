;;; demand-priority.scm — Pluggable priority for cross-scope retraction
;;;
;;; Priority is modular:
;;;   1. Default: composite-buffer-priority from buffer-type.scm
;;;   2. Governance: callback (scope-id spec-id) -> number, overrides default
;;;   3. Relational: (demand-priority scope-id spec-id priority) fact
;;;
;;; Lower number = more urgent. Range: 10 (ecological/red) to 63 (consumption/excess).
;;; Non-buffered specs default to tier 5 (metabolic), zone 'green → score 53.

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
   Returns: (lambda (scope-id spec-id) -> number)"
  (lambda (scope-id spec-id)
    (or (and governance-fn (governance-fn scope-id spec-id))
        (default-priority-fn spec-id buffer-zone-store))))
