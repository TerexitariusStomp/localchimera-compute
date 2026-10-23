;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; capacity-execute.scm — Capacity-managed execution primitives
;;;
;;; Composable procedures for doing real work with infrastructure:
;;;
;;;   with-capacity       — reserve, thunk, release (guaranteed cleanup)
;;;   with-resources      — multi-resource version (nested reserve/release)
;;;   execute-with-event  — + VF event recording via observer
;;;   dispatch-async      — async work dispatch via <- with completion callback
;;;
;;; These are procedures, not actors. Any actor can call them within a vat
;;; turn to do capacity-managed work.

;; Assumes store-utils.scm and schemas.scm are loaded.


;; =========================================================================
;; with-capacity — the core primitive (synchronous, same vat)
;; =========================================================================

(define-module (playnet execution capacity-execute)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet utils clock) #:select (instant->civil instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (playnet utils store-utils)
  #:use-module (goblins)
  #:use-module (goblins actor-lib on)
  #:export (with-capacity with-resources now-iso execute-with-event dispatch-async
            with-enforced-capacity))

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
  (instant->civil (clock-now)))

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
          ;; Record one event per resource
          (for-each
            (lambda (spec)
              ($ observer 'record-event
                 (make-economic-event
                   #:id (generate-id "ev-") #:action action #:input-of process-id
                   #:resource-inventoried-as (cadr spec)       ;; resource-inventoried-as
                ;; to-resource-inventoried-as
                   #:resource-conforms-to (caddr spec)      ;; resource-conforms-to
                ;; resource-classified-as
                   #:provider (or provider "")  ;; provider
                   #:receiver (or receiver "")  ;; receiver
                   #:resource-quantity (make-measure (cadddr spec) (list-ref spec 4)) ;; resource-quantity
                ;; effort-quantity
 #:has-point-in-time timestamp ;; times
             ;; locations
       ;; state, fulfills, satisfies, corrects
)))    ;; realization-of, settles, note, in-scope-of, previous-event
            resource-specs)
          result))
      (lambda ()
        (for-each (lambda (pair) ($ (car pair) 'release (cdr pair)))
                  pairs)))))


;; =========================================================================
;; dispatch-async — async work dispatch via <- with completion handling
;; =========================================================================
;;
;; For long-running or cross-scope work that can't complete in one vat turn.
;; Returns a promise. The live-resource is reserved immediately (synchronous),
;; work is dispatched asynchronously, and release happens on completion.
;;
;; Usage:
;;   (dispatch-async compute-ref 4
;;     (lambda () (<- remote-worker 'run task-data))
;;     #:on-complete (lambda (result rsv-id)
;;                     ($ live-ref 'release rsv-id)
;;                     ($ observer 'record-event ...)))

(define* (dispatch-async live-ref amount work-thunk
                         #:key (on-complete #f) (on-error #f))
  "Reserve AMOUNT synchronously, dispatch WORK-THUNK asynchronously.
   WORK-THUNK should return a promise (via <-).
   ON-COMPLETE: (lambda (result reservation-id) ...) — called when work finishes.
   ON-ERROR: (lambda (error reservation-id) ...) — called on failure.
   If neither callback releases, the reservation leaks — caller is responsible."
  (let ((rsv-id ($ live-ref 'reserve amount)))
    (let ((result-promise (work-thunk)))
      (when (and result-promise on-complete)
        (on result-promise
            (lambda (result)
              (on-complete result rsv-id))
            #:catch
            (lambda (err)
              (if on-error
                  (on-error err rsv-id)
                  ;; Default: release on error
                  ($ live-ref 'release rsv-id)))
            #:promise? #t))
      (values result-promise rsv-id))))


;; =========================================================================
;; Enforcement protocol — interface for OS-level resource enforcement
;; =========================================================================
;;
;; A ^live-resource can optionally delegate to an enforcer actor that maps
;; accounting reservations to physical constraints (cgroups, WASM limits,
;; ulimit, container quotas).
;;
;; The enforcer protocol:
;;   ($ enforcer 'apply resource-id amount unit)  — set physical limit
;;   ($ enforcer 'release resource-id)            — remove physical limit
;;
;; Example: a cgroups enforcer would call
;;   (system* "cgset" "-r" (format #f "cpu.max ~a" (* amount 100000)) cgroup-path)
;;
;; This is a protocol definition, not an implementation. Concrete enforcers
;; are platform-specific (Linux cgroups, WASM memory, Docker, etc.).

(define* (with-enforced-capacity live-ref enforcer-ref amount unit thunk)
  "Like with-capacity, but also applies physical enforcement via ENFORCER-REF.
   The enforcer sets OS-level limits before the thunk runs and removes them after."
  (let ((rsv-id ($ live-ref 'reserve amount))
        (rid ($ live-ref 'id)))
    (dynamic-wind
      (lambda ()
        (when enforcer-ref
          ($ enforcer-ref 'apply rid amount unit)))
      thunk
      (lambda ()
        (when enforcer-ref
          ($ enforcer-ref 'release rid))
        ($ live-ref 'release rsv-id)))))
