;;; metabolism.scm — Metabolic balance: labour and material flows
;;;
;;; Spec: docs/playnet.typ §"Inter-scope propagation" (both ledgers
;;;       propagating together), §"Metabolic coherence".
;;;
;;; The accounting under the live plan: coherence is *metabolised* — read
;;; off the flows, not solved up front. Two coupled metabolisms:
;;;
;;; 1. Labour metabolism — crystallized-SNLT-denominated: measures human
;;;    time loops. Work flows contribute effort-quantity directly (this is
;;;    SNLT_direct at the stage); resource flows contribute qty ×
;;;    SNLT_cryst(spec). Uses `flow-snlt-cost` from rollup.
;;;
;;; 2. Material metabolism — substance-denominated: per-flow throughput
;;;    in the units of the substance itself (kg, m³, MJ, tCO2e, etc.).
;;;    Uses `flow-substance-qty` from rollup for unit classification.
;;;
;;; Both axes must close for ecological coherence. The labour view
;;; misses what nature gives free; the material view misses weightless
;;; flows (teaching, care, deliberation). Neither subsumes the other.

;; This file is an include-fragment loaded by module/playnet/planner.scm.
;; The umbrella module already imports srfi-1, goblins utils hashmap, and
;; (playnet utils units); rollup.scm is also included into the same scope,
;; so flow-snlt-cost et al. are available at top level without a separate
;; use-modules. Importing rollup as a module name fails because rollup.scm
;; is not a (define-module …) — it has no module identity.

(define-module (playnet deprecated planner algorithms metabolism)
  #:use-module (playnet utils units)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils store-utils)
  #:use-module (playnet algorithms rollup)
  #:export (*input-actions* *output-actions* labour-metabolism material-metabolism
            metabolic-balance metabolic-balance-legacy))

(define *input-actions* '(consume use work accept pickup))
(define *output-actions* '(produce modify deliver-service dropoff))

;; ===========================================================================
;; Labour metabolism — SNLT-denominated (uses rollup:flow-snlt-cost)
;; ===========================================================================

(define* (labour-metabolism events horizon-from horizon-to recipe-store
                            #:key scope-filter)
  "Compute SNLT-denominated labour metabolism balance.
   Returns: ((net-labour . hours) (labour-input . hours) (labour-output . hours)
             (by-spec . alist) (by-scope . alist))."
  (let ((by-spec (make-hash-table))
        (by-scope (make-hash-table))
        (total-input 0)
        (total-output 0))
    (for-each
      (lambda (e)
        (let* ((ts (or (economic-event-has-point-in-time e)
                       (economic-event-has-beginning e)))
               (in-range (or (not ts)
                             (and (or (not horizon-from) (string>=? ts horizon-from))
                                  (or (not horizon-to) (string<=? ts horizon-to)))))
               (action (economic-event-action e))
               (spec (economic-event-resource-conforms-to e))
               (rq (economic-event-resource-quantity e))
               (eq (economic-event-effort-quantity e))
               (snlt-value (flow-snlt-cost recipe-store action spec rq eq 1))
               (scope-id (and scope-filter (economic-event-provider e))))
          (when (and in-range (> snlt-value 0))
            (cond
              ((memq action *input-actions*)
               (set! total-input (+ total-input snlt-value))
               (when spec
                 (let ((entry (hash-ref by-spec spec '((input . 0) (output . 0)))))
                   (hash-set! by-spec spec
                     `((input . ,(+ (assq-ref entry 'input) snlt-value))
                       (output . ,(assq-ref entry 'output))))))
               (when scope-id
                 (let ((entry (hash-ref by-scope scope-id '((input . 0) (output . 0)))))
                   (hash-set! by-scope scope-id
                     `((input . ,(+ (assq-ref entry 'input) snlt-value))
                       (output . ,(assq-ref entry 'output)))))))
              ((memq action *output-actions*)
               (set! total-output (+ total-output snlt-value))
               (when spec
                 (let ((entry (hash-ref by-spec spec '((input . 0) (output . 0)))))
                   (hash-set! by-spec spec
                     `((input . ,(assq-ref entry 'input))
                       (output . ,(+ (assq-ref entry 'output) snlt-value))))))
               (when scope-id
                 (let ((entry (hash-ref by-scope scope-id '((input . 0) (output . 0)))))
                   (hash-set! by-scope scope-id
                     `((input . ,(assq-ref entry 'input))
                       (output . ,(+ (assq-ref entry 'output) snlt-value)))))))))))
      events)
    `((net-labour . ,(- total-output total-input))
      (labour-input . ,total-input)
      (labour-output . ,total-output)
      (by-spec . ,(hash-map->list cons by-spec))
      (by-scope . ,(hash-map->list cons by-scope)))))

;; ===========================================================================
;; Material metabolism — substance-denominated (uses rollup:flow-substance-qty)
;; ===========================================================================

(define* (material-metabolism events horizon-from horizon-to
                               #:key scope-filter (substances 'all))
  "Compute substance-denominated material metabolism balance.
   Uses rollup's unit classification and conversion.
   Returns: ((by-substance . alist)) where each substance has:
            ((substance . sym) (net . n) (input . n) (output . n)
             (base-unit . sym) (specs . list))."
  (let ((by-substance (make-hash-table)))
    (for-each
      (lambda (e)
        (let* ((ts (or (economic-event-has-point-in-time e)
                       (economic-event-has-beginning e)))
               (in-range (or (not ts)
                             (and (or (not horizon-from) (string>=? ts horizon-from))
                                  (or (not horizon-to) (string<=? ts horizon-to)))))
               (action (economic-event-action e))
               (spec (economic-event-resource-conforms-to e))
               (rq (economic-event-resource-quantity e))
               (scope-id (and scope-filter (economic-event-provider e)))
               ;; Use rollup's substance extraction
               (substance-entry (flow-substance-qty rq)))
          (when (and in-range substance-entry)
            (let* ((substance (car substance-entry))
                   (qty (cdr substance-entry))
                   ;; Filter by requested substances
                   (include? (or (eq? substances 'all)
                                  (memq substance substances))))
              (when include?
                (let ((entry (hash-ref by-substance substance
                                '((input . 0) (output . 0) (specs . ())))))
                  (cond
                    ((memq action *input-actions*)
                     (hash-set! by-substance substance
                       `((input . ,(+ (assq-ref entry 'input) qty))
                         (output . ,(assq-ref entry 'output))
                         (specs . ,(if spec
                                       (cons spec (assq-ref entry 'specs))
                                       (assq-ref entry 'specs))))))
                    ((memq action *output-actions*)
                     (hash-set! by-substance substance
                       `((input . ,(assq-ref entry 'input))
                         (output . ,(+ (assq-ref entry 'output) qty))
                         (specs . ,(if spec
                                       (cons spec (assq-ref entry 'specs))
                                       (assq-ref entry 'specs)))))))))))))
      events)
    ;; Build result with net and base-unit per substance
    (map (lambda (pair)
           (let* ((substance (car pair))
                  (data (cdr pair)))
             `((substance . ,substance)
               (net . ,(- (assq-ref data 'output)
                          (assq-ref data 'input)))
               (input . ,(assq-ref data 'input))
               (output . ,(assq-ref data 'output))
               (base-unit . ,(substance-base-unit substance))
               (specs . ,(delete-duplicates (assq-ref data 'specs))))))
         (hash-map->list cons by-substance))))

;; ===========================================================================
;; Combined metabolic report
;; ===========================================================================

(define* (metabolic-balance events horizon-from horizon-to recipe-store
                            #:key scope-filter (substances 'all))
  "Compute both labour and material metabolic balance.
   Returns: ((labour . alist) (materials . alist))."
  `((labour . ,(labour-metabolism events horizon-from horizon-to recipe-store
                                   #:scope-filter scope-filter))
    (materials . ,(material-metabolism events horizon-from horizon-to
                                       #:scope-filter scope-filter
                                       #:substances substances))))

;; ===========================================================================
;; Backward-compatible API (deprecated — uses SNLT, not market-prices)
;; ===========================================================================

(define* (metabolic-balance-legacy events horizon-from horizon-to recipe-store)
  "Deprecated: use metabolic-balance instead. This variant returns the old
   format for compatibility."
  (let ((result (labour-metabolism events horizon-from horizon-to recipe-store)))
    `((net-balance . ,(assq-ref result 'net-labour))
      (total-input . ,(assq-ref result 'labour-input))
      (total-output . ,(assq-ref result 'labour-output))
      (by-spec . ,(assq-ref result 'by-spec)))))