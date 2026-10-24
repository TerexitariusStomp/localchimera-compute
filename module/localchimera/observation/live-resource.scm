;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; live-resource.scm — Goblins actor for infrastructure resources
;;;
;;; An economic resource that IS an actor. The observer tracks total capacity
;;; (via 'raise/'lower events); the live-resource actor tracks available
;;; capacity (via reserve/release). The planner sees available capacity
;;; in inventory facts — allocates normally.
;;;
;;; Within a scope's vat, reserve + record-event happen in one turn (atomic).
;;; Across scopes, the actor is reachable via <- over OCapN.

(define-module (localchimera observation live-resource)
  #:use-module (localchimera utils store-utils)
  #:export (^live-resource live-resource-env)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1))


;; Assumes store-utils.scm is loaded.


;; =========================================================================
;; ^live-resource
;; =========================================================================

(define-actor (^live-resource bcom resource-id spec-id total available
                              unit location reservations)
  ;; resource-id:   string — matches the economic-resource-id in the observer
  ;; spec-id:       string — conforms-to ResourceSpecification
  ;; total:         number — total capacity (mirrors observer accounting-quantity)
  ;; available:     number — currently free capacity
  ;; unit:          string — e.g. "cpu-hours", "GB"
  ;; location:      string or #f — e.g. "dc-1", "browser"
  ;; reservations:  alist of (reservation-id . amount)

  #:portrait
  (lambda () (list resource-id spec-id total available unit location reservations))

  #:version 1

  #:restore
  (lambda (version . data)
    (case version
      ((1) (apply spawn ^live-resource data))
      (else (error "Unknown ^live-resource version" version))))

  (methods

    ;; --- Read-only ---
    ((id) resource-id)
    ((spec) spec-id)
    ((total) total)
    ((available) available)
    ((unit) unit)
    ((location) location)
    ((reservations) reservations)

    ;; --- Reserve capacity ---
    ((reserve amount)
     (when (> amount available)
       (error (format #f "~a: insufficient capacity — need ~a, have ~a"
                      resource-id amount available)))
     (let ((rid (generate-id "rsv-")))
       (bcom (^live-resource bcom resource-id spec-id total
               (- available amount) unit location
               (cons (cons rid amount) reservations))
             rid)))

    ;; --- Release a reservation ---
    ((release reservation-id)
     (let ((entry (assoc reservation-id reservations)))
       (unless entry
         (error (format #f "~a: unknown reservation ~a" resource-id reservation-id)))
       (bcom (^live-resource bcom resource-id spec-id total
               (+ available (cdr entry)) unit location
               (filter (lambda (r) (not (equal? (car r) reservation-id)))
                       reservations)))))

    ;; --- Resize total capacity (elastic scaling) ---
    ((resize new-total)
     (let ((delta (- new-total total)))
       (bcom (^live-resource bcom resource-id spec-id new-total
               (+ available delta) unit location
               reservations))))))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define live-resource-env
  (make-persistence-env
    `((((vf observation) ^live-resource) ,^live-resource))))
