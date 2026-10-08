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

(define-module (playnet deprecated planner utils demand-priority)
  #:use-module (playnet planner vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet deprecated planner utils buffer-type)
  #:use-module (playnet planner ddmrp buffers)
  #:export (*default-priority* default-priority-fn fact-matches? make-priority-fn
            *default-harmony-level* harmony-level-from-facts make-harmony-level-fn)
  #:use-module (srfi srfi-1))



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
              ;; 'metabolic flat, not (or (buffer-zone-tier bz) 'metabolic):
              ;; buffer-zone-tier exists nowhere, and there is no accessor to
              ;; substitute — <buffer-zone> carries buffer-classification, whose
              ;; vocabulary is (replenished replenished-override min-max) while
              ;; composite-buffer-priority wants a buffer TYPE (ecological
              ;; strategic reserve social metabolic consumption). Different
              ;; vocabularies, so the classification is not the missing field.
              ;; Giving <buffer-zone> a tier means deciding how a zone acquires
              ;; one — buffer-type-from-tags is the obvious candidate — which is
              ;; a design question, not a rename. Until then this reads the
              ;; default it always fell back to.
              'metabolic
              (or (assq-ref (buffer-status
                              (sum-onhand-at-location #f spec-id #f #f)
                              bz)
                            'zone)
                  'green))))))


;;; ── Priority fact matching (the relational `-o` forms were retired to
;;;    deprecated/planner/demand-priority-relations.scm) ───────────────────────

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
;;; function. See module/playnet/planner/relational/harmony.scm for the level → weight
;;; conversion.

(define *default-harmony-level* 0)  ;; unweighted baseline

(define (harmony-level-from-facts facts spec-id)
  "Look up (harmony-priority spec-id level) in facts. Returns level or #f."
  (let ((f (find (lambda (f)
                   (and (eq? (car f) 'harmony-priority)
                        (equal? (cadr f) spec-id)))
                 facts)))
    (and f (caddr f))))

(define* (make-harmony-level-fn #:key (governance-fn #f) (facts #f))
  "Build a level function: (spec-id) -> level (integer).
   GOVERNANCE-FN is an optional callback (spec-id) -> level that overrides
   facts. FACTS is a list of lifted facts containing harmony-priority
   entries."
  (lambda (spec-id)
    (or (and governance-fn (governance-fn spec-id))
        (and facts (harmony-level-from-facts facts spec-id))
        *default-harmony-level*)))
