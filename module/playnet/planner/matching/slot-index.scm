;;; matching/slot-index.scm — Three-tier spatial slot index.
;;;
;;; TypeIndex (spec-id) → SpatialIndex (H3 cell) → TemporalIndex
;;; (time bucket). Skill filtering via a caller-supplied resolver
;;; procedure (spec-id → (agent-id ...)) — skills are
;;; EconomicResources in VF, queried through the observer's
;;; agents-with-skill method, but the index itself stays pure.
;;;
;;; All operations are pure/functional. Degrades gracefully when no
;;; H3 backend is installed.
;;;
;;; Ported from docs/free-assoc/src/lib/protocol/slot-index.ts.

(define-module (playnet planner matching slot-index)
  #:use-module ((playnet planner formulas actions) #:select (output-action?))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner matching schemas)
  #:use-module (playnet planner matching spatial)
  #:use-module (playnet planner matching temporal-index)
  #:export (make-slot-index
            slot-index?
            slot-index-build
            slot-index-insert
            slot-index-remove
            slot-index-query
            slot-index-query-space-time
            slot-index-all
            slot-index-with-skill-resolver
            slot-index-stats
            build-slot-index
            find-matches-indexed))


(define-record-type <slot-index>
  (%make-slot-index types skill-resolver)
  slot-index?
  (types          si-types)
  (skill-resolver si-skill-resolver))

(define (make-slot-index)
  (%make-slot-index (hashmap) #f))


;;; ── Binding field accessors ─────────────────────────────────────────────────

(define (binding-spec b)
  (intent-resource-conforms-to (intent-binding-intent b)))

(define (binding-offerer b)
  (let ((i (intent-binding-intent b)))
    ((if (output-action? (intent-action i)) intent-provider intent-receiver) i)))

(define (binding-radius b)
  (let ((c (intent-binding-criteria b)))
    (or (and c (intent-matching-criteria-search-radius-km c))
        *default-search-radius-km*)))

(define (binding-skills b)
  (let ((c (intent-binding-criteria b)))
    (and c (intent-matching-criteria-required-skills c))))


;;; ── Spatial tier (h3-cell → temporal-index) ─────────────────────────────────

(define (spatial-insert si cell b)
  (let ((ti (hashmap-ref si cell (make-temporal-index))))
    (hashmap-set si cell (temporal-index-insert ti b))))

(define (spatial-remove si cell b)
  (let ((ti (hashmap-ref si cell #f)))
    (if (not ti) si
        (let ((ti* (temporal-index-remove ti b)))
          (if (zero? (temporal-index-size ti*))
              (hashmap-remove si cell)
              (hashmap-set si cell ti*))))))

(define (spatial-gather si cells gather-fn)
  "Collect bindings from CELLS using GATHER-FN on each temporal-index."
  (append-map (lambda (c)
                (let ((ti (hashmap-ref si c #f)))
                  (if ti (gather-fn ti) '())))
              cells))

(define (with-remote si center results gather-fn)
  "Append remote-cell slots unless the query itself targets remote."
  (if (equal? center *remote-h3-index*) results
      (let ((ti (hashmap-ref si *remote-h3-index* #f)))
        (if ti (append results (gather-fn ti)) results))))

(define (spatial-query si center radius . maybe-time-range)
  (let* ((cells   (get-cells-in-radius center radius))
         (gather  (if (null? maybe-time-range)
                      temporal-index-all
                      (lambda (ti) (temporal-index-query ti (car maybe-time-range)))))
         (results (spatial-gather si cells gather)))
    (with-remote si center results gather)))


;;; ── Type tier (spec-id → spatial hashmap) ───────────────────────────────────

(define (type-insert ti spec cell b)
  (hashmap-set ti spec (spatial-insert (hashmap-ref ti spec (hashmap)) cell b)))

(define (type-remove ti spec cell b)
  (let ((si (hashmap-ref ti spec #f)))
    (if (not si) ti (hashmap-set ti spec (spatial-remove si cell b)))))

(define (type-query ti spec center radius . rest)
  (let ((si (hashmap-ref ti spec #f)))
    (if (not si) '() (apply spatial-query si center radius rest))))

(define (type-all ti)
  (hashmap-fold (lambda (_ si acc)
                  (hashmap-fold (lambda (_ ti acc)
                                 (append (temporal-index-all ti) acc))
                               acc si))
                '() ti))


;;; ── Skill filtering ─────────────────────────────────────────────────────────
;;;
;;; Skills are EconomicResources in VF: an agent "has" a skill when
;;; the observer holds a resource conforming to that skill's spec with
;;; the agent as primary-accountable. The slot-index accepts a
;;; skill-resolver procedure (spec-id → (agent-id ...)) so it stays
;;; pure — the caller wraps the observer:
;;;
;;;   (slot-index-with-skill-resolver idx
;;;     (lambda (spec-id) ($ observer 'agents-with-skill spec-id)))

(define (list->hm-set lst)
  (fold (lambda (x s) (hashmap-set s x #t)) (hashmap) lst))

(define (hm-set-intersect a b)
  (hashmap-fold (lambda (k _v acc)
                  (if (hashmap-ref b k #f) (hashmap-set acc k #t) acc))
                (hashmap) a))

(define (hm-set-empty? s)
  (zero? (hashmap-fold (lambda (_k _v acc) (+ acc 1)) 0 s)))

(define (qualified-agents resolve required-spec-ids)
  "Agent-ids with ALL required skills (a list of spec-id strings),
   as a hashmap (set), or #f if no filtering needed."
  (and required-spec-ids (pair? required-spec-ids)
       (let loop ((specs required-spec-ids) (result #f))
         (if (null? specs) (or result (hashmap))
             (let* ((cset (list->hm-set (resolve (car specs))))
                    (next (if result (hm-set-intersect result cset) cset)))
               (if (hm-set-empty? next) (hashmap)
                   (loop (cdr specs) next)))))))

(define (skill-filter candidates resolve probe)
  (if (not resolve) candidates
      (let ((qa (qualified-agents resolve (binding-skills probe))))
        (if (not qa) candidates
            (filter (lambda (b)
                      (let ((o (binding-offerer b)))
                        (or (not o) (hashmap-ref qa o #f))))
                    candidates)))))


;;; ── Composite ───────────────────────────────────────────────────────────────

(define (slot-index-insert idx b)
  (%make-slot-index (type-insert (si-types idx) (binding-spec b)
                                 (binding-h3-index b) b)
                    (si-skill-resolver idx)))

(define (slot-index-remove idx b)
  (%make-slot-index (type-remove (si-types idx) (binding-spec b)
                                 (binding-h3-index b) b)
                    (si-skill-resolver idx)))

(define (slot-index-build idx bindings)
  (fold (lambda (b acc) (slot-index-insert acc b)) idx bindings))

(define (slot-index-with-skill-resolver idx resolve)
  "Attach a skill resolver: (spec-id → (agent-id ...)).
   Typical usage:
     (slot-index-with-skill-resolver idx
       (lambda (spec-id) ($ observer 'agents-with-skill spec-id)))"
  (%make-slot-index (si-types idx) resolve))

(define (slot-index-query idx probe)
  (skill-filter (type-query (si-types idx) (binding-spec probe)
                            (binding-h3-index probe) (binding-radius probe))
                (si-skill-resolver idx) probe))

(define (slot-index-query-space-time idx probe time-range)
  (skill-filter (type-query (si-types idx) (binding-spec probe)
                            (binding-h3-index probe) (binding-radius probe)
                            time-range)
                (si-skill-resolver idx) probe))

(define (slot-index-all idx) (type-all (si-types idx)))

(define (slot-index-stats idx)
  (let ((ti (si-types idx)))
    `((total-slots . ,(length (type-all ti)))
      (type-count  . ,(hashmap-fold (lambda (_k _v acc) (+ acc 1)) 0 ti)))))

(define (build-slot-index bindings)
  (slot-index-build (make-slot-index) bindings))

(define (find-matches-indexed probe idx)
  (slot-index-query idx probe))
