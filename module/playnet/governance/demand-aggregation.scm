;;; demand-aggregation.scm — merge equivalent demand-side intents.
;;;
;;; Pure function. Given a list of demand-side <intent> records, group
;;; those sharing (resource-conforms-to, at-location) whose
;;; time-windows transitively overlap; sum their resource-quantities
;;; when units align; return one merged intent per cluster.
;;;
;;; Under-specified intents (missing spec or location) pass through
;;; unchanged — aggregation can't silently merge wishes whose equivalence
;;; can't be decided. Once such a wish is elaborated, a later call
;;; picks it up.
;;;
;;; Call sites:
;;;   - Pre-tally: aggregate near-duplicate wishes before opening a
;;;     expression, so points pool over clusters instead of
;;;     splitting across near-duplicates.
;;;   - Post-promotion: feed the planner consolidated independent
;;;     demand rather than many small overlapping intents.
;;;
;;; Same function, two call sites. The caller decides.

(define-module (playnet governance demand-aggregation)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)                    ;; string-join
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:export (aggregate-demands
            windows-overlap?
            intents-aggregatable?))


;; =========================================================================
;; Time-window overlap (ISO 8601 strings; #f = unbounded on that side)
;; =========================================================================

(define (windows-overlap? a-begin a-end b-begin b-end)
  "#t if the closed intervals [a-begin, a-end] and [b-begin, b-end]
   overlap or touch. #f on a side means unbounded past (begin) or
   unbounded future (end). ISO 8601 datetime strings are compared
   lexicographically, which matches chronological order for
   well-formed timestamps."
  (and (or (not a-end)   (not b-begin) (string<=? b-begin a-end))
       (or (not b-end)   (not a-begin) (string<=? a-begin b-end))))


;; =========================================================================
;; Equivalence
;; =========================================================================

(define (intent-aggregation-key intent)
  "Returns (spec . location) if both are present; #f if the intent is
   under-specified and should pass through aggregation unchanged."
  (let ((spec (intent-resource-conforms-to intent))
        (loc  (intent-at-location intent)))
    (and spec loc (cons spec loc))))

(define (intents-aggregatable? a b)
  "Two intents can merge iff (1) both have the same (spec, location)
   key, and (2) their time-windows overlap."
  (let ((ka (intent-aggregation-key a))
        (kb (intent-aggregation-key b)))
    (and ka kb (equal? ka kb)
         (windows-overlap?
           (intent-has-beginning a) (intent-has-end a)
           (intent-has-beginning b) (intent-has-end b)))))


;; =========================================================================
;; Clustering by transitive overlap
;; =========================================================================

(define (cluster-by-overlap intents)
  "Group INTENTS into equivalence classes where membership is
   defined by transitive intents-aggregatable?. O(n²) — fine for
   typical scope sizes."
  (let loop ((remaining intents) (clusters '()))
    (cond
      ((null? remaining) clusters)
      (else
       (let ((head (car remaining)) (rest (cdr remaining)))
         (call-with-values
           (lambda ()
             (partition
               (lambda (cluster)
                 (any (lambda (m) (intents-aggregatable? head m)) cluster))
               clusters))
           (lambda (matching others)
             (loop rest
                   (cons (cons head (apply append matching))
                         others)))))))))


;; =========================================================================
;; Merge one cluster of aggregatable intents
;; =========================================================================

(define (min-string strs)
  (fold (lambda (s acc) (if (or (not acc) (string<? s acc)) s acc))
        #f strs))
(define (max-string strs)
  (fold (lambda (s acc) (if (or (not acc) (string>? s acc)) s acc))
        #f strs))

(define (merge-intents cluster)
  "Build one intent representing CLUSTER (non-empty list of
   aggregatable intents). Quantities sum iff every intent has a
   compatible-unit <measure>; otherwise the merged intent's
   resource-quantity is #f (unknown at aggregation time)."
  (let* ((first   (car cluster))
         (n       (length cluster))
         (begins  (filter-map intent-has-beginning cluster))
         (ends    (filter-map intent-has-end       cluster))
         (any-unbounded-begin?
           (any (lambda (i) (not (intent-has-beginning i))) cluster))
         (any-unbounded-end?
           (any (lambda (i) (not (intent-has-end       i))) cluster))
         (merged-begin (and (not any-unbounded-begin?) (min-string begins)))
         (merged-end   (and (not any-unbounded-end?)   (max-string ends)))
         (quantities   (map intent-resource-quantity cluster))
         (all-quantified? (every (lambda (q) q) quantities))
         (units (and all-quantified? (map measure-has-unit quantities)))
         (uniform-units?
           (and units (pair? units)
                (every (lambda (u) (equal? u (car units))) units)))
         (summed-quantity
           (and uniform-units?
                (make-measure
                  (fold + 0 (map measure-has-numerical-value quantities))
                  (car units))))
         (merged-name
           (if (= n 1)
               (intent-name first)
               (string-append "aggregated (" (number->string n)
                              " demands): "
                              (string-join (map intent-name cluster) " + "))))
         (merged-note
           (string-append "aggregated from " (number->string n)
                          " demand"
                          (if (= n 1) "" "s"))))
    (make-intent                                    ; the id is the caller's to assign
      #:action (intent-action first)
      #:name merged-name
      #:note merged-note
      #:image (intent-image first)
      #:input-of (intent-input-of first) #:output-of (intent-output-of first)
      #:resource-inventoried-as (intent-resource-inventoried-as first)
      #:resource-conforms-to (intent-resource-conforms-to first)
      #:resource-classified-as (intent-resource-classified-as first)
      #:resource-quantity summed-quantity
      #:effort-quantity (intent-effort-quantity first)
      #:available-quantity (intent-available-quantity first)
      #:minimum-quantity (intent-minimum-quantity first)
      #:provider (intent-provider first)
      #:receiver (intent-receiver first)
      #:has-beginning merged-begin
      #:has-end merged-end
      #:has-point-in-time (intent-has-point-in-time first)
      #:due (intent-due first)
      #:at-location (intent-at-location first)
      #:stage (intent-stage first)
      #:state (intent-state first)
      #:planned-within (intent-planned-within first)
      #:satisfies (intent-satisfies first)
      #:in-scope-of (intent-in-scope-of first)
      #:finished (intent-finished first)
      #:availability-window (intent-availability-window first))))


;; =========================================================================
;; Public: aggregate-demands
;; =========================================================================

(define (aggregate-demands intents)
  "Cluster INTENTS by (spec, location, overlapping time-window) and
   return one merged intent per cluster. Intents missing spec or
   location pass through unchanged.

   Order: merged clusters first (by no particular order), then
   pass-through intents in input order. Callers that need a stable
   order should sort the result themselves."
  (call-with-values
    (lambda ()
      (partition intent-aggregation-key intents))
    (lambda (aggregatable unaggregatable)
      (let* ((clusters (cluster-by-overlap aggregatable))
             (merged   (map merge-intents clusters)))
        (append merged unaggregatable)))))
