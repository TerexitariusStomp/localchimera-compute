;;; capacity-execute.scm — Capacity-managed execution primitives
;;;
;;; Three composable procedures for doing real work with infrastructure:
;;;
;;;   with-capacity       — reserve, thunk, release (guaranteed cleanup)
;;;   with-resources      — multi-resource version (nested reserve/release)
;;;   execute-with-event  — + VF event recording via observer
;;;
;;; These are procedures, not actors. Any actor can call them within a vat
;;; turn to do capacity-managed work. The reserve, work, event recording,
;;; and release all happen atomically in one turn.

;; Assumes store-utils.scm and schemas.scm are loaded.


;; =========================================================================
;; with-capacity — the core primitive
;; =========================================================================

(define (with-capacity live-ref amount thunk)
  "Reserve AMOUNT from LIVE-REF, run THUNK, release on completion or error.
   Returns THUNK's result. Cleanup is guaranteed via dynamic-wind."
  (let ((rsv-id ($ live-ref 'reserve amount)))
    (dynamic-wind
      (lambda () #f)
      thunk
      (lambda () ($ live-ref 'release rsv-id)))))


;; =========================================================================
;; with-resources — multi-resource version
;; =========================================================================

(define (with-resources resource-specs thunk)
  "Reserve all resources in RESOURCE-SPECS, run THUNK, release all.
   RESOURCE-SPECS: ((live-ref . amount) ...)
   Resources are reserved in order, released in reverse (via nesting).
   If any reservation fails, already-reserved resources are released."
  (if (null? resource-specs)
      (thunk)
      (with-capacity (caar resource-specs) (cdar resource-specs)
        (lambda ()
          (with-resources (cdr resource-specs) thunk)))))


;; =========================================================================
;; execute-with-event — capacity + VF event recording
;; =========================================================================

(define (now-iso)
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

(define* (execute-with-event observer resource-specs thunk
                             #:key (action 'use) (process-id #f)
                                   (provider #f) (receiver #f))
  "Reserve resources, run THUNK, record VF events, release.
   RESOURCE-SPECS: ((live-ref resource-id spec-id amount unit) ...)
   Records one EconomicEvent per resource after THUNK succeeds.
   All atomic within a single vat turn."
  (let* ((pairs (map (lambda (spec)
                       (cons (car spec) ($ (car spec) 'reserve (cadddr spec))))
                     resource-specs))
         (timestamp (now-iso)))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let ((result (thunk)))
          ;; Record one 'use event per resource consumed
          (for-each
            (lambda (spec)
              ($ observer 'record-event
                 (make-economic-event
                   (generate-id "ev-") action process-id #f
                   (cadr spec)       ;; resource-inventoried-as
                   #f                ;; to-resource-inventoried-as
                   (caddr spec)      ;; resource-conforms-to
                   #f                ;; resource-classified-as
                   (or provider "")  ;; provider
                   (or receiver "")  ;; receiver
                   (make-measure (cadddr spec) (list-ref spec 4)) ;; resource-quantity
                   #f                ;; effort-quantity
                   #f #f timestamp #f ;; times
                   #f #f             ;; locations
                   #f #f #f #f       ;; state, fulfills, satisfies, corrects
                   #f #f #f #f #f    ;; realization-of, settles, note, in-scope-of, previous-event
                   #f #f)))          ;; exclude-from-adu, market-value
            resource-specs)
          result))
      (lambda ()
        (for-each (lambda (pair) ($ (car pair) 'release (cdr pair)))
                  pairs)))))
