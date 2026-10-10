;;; topic-observer.scm — Per-topic attenuating proxy actor
;;;
;;; Sits between raw MQTT messages and the scope's execution layer.
;;; The codec handles parsing and VF validation; this actor adds only
;;; the attenuation checks (allowed actions, allowed specs) and wires
;;; through record-and-monitor so monitors and alerts fire normally.
;;;
;;; Assumes schemas.scm, codec.scm, scope-execution.scm are loaded.

(define-module (playnet bridge topic-observer)
  #:use-module (playnet vf schemas)
  #:use-module (playnet bridge codec)
  #:use-module (ice-9 match)
  #:use-module (playnet execution scope-execution)
  #:use-module (playnet vf schemas)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^topic-observer attenuate-and-parse))

(use-modules (goblins)
             (goblins actor-lib methods)
             (json)
             (ice-9 match))


(define-actor (^topic-observer bcom
                               scope-id         ;; string
                               observer-ref     ;; capability ref to ^observer
                               alert-store-ref  ;; capability ref to ^alert-store (or #f)
                               ctx              ;; execution context alist (or #f)
                               allowed-actions  ;; list of action symbols, or #f for any
                               allowed-specs    ;; list of spec-id strings, or #f for any
                               accepted         ;; integer
                               rejected)        ;; integer

  #:portrait
  (lambda ()
    ;; observer-ref, alert-store-ref are near actor refs (same planner-vat)
    ;; and serialize natively.  ctx is an alist of near refs — also serializable.
    (list scope-id observer-ref alert-store-ref ctx
          allowed-actions allowed-specs accepted rejected))

  #:version 2

  #:upgrade
  (migrations
   [(2 sid aa as acc rej)
    ;; v1 portrait excluded live refs.  #f is safe: receive-message
    ;; guards on (and ctx alert-store-ref) before using them, and
    ;; 'rewire can re-attach after restore if needed.
    (list sid #f #f #f aa as acc rej)])

  #:restore
  (lambda (version sid obs-ref alert-ref ctx aa as acc rej)
    (case version
      ((2) (spawn ^topic-observer sid obs-ref alert-ref ctx aa as acc rej))
      (else (error "Unknown ^topic-observer version" version))))

  (methods

    ((receive-message topic payload-string)
     (let ((result (attenuate-and-parse payload-string
                                        allowed-actions allowed-specs)))
       (match result
         (('ok . event)
          (let ((affected (if (and ctx alert-store-ref)
                              (record-and-monitor observer-ref event
                                                  ctx alert-store-ref)
                              ($ observer-ref 'record-event event))))
            (bcom (^topic-observer bcom scope-id observer-ref
                                   alert-store-ref ctx allowed-actions
                                   allowed-specs (+ accepted 1) rejected)
                  (list 'accepted affected))))
         (('error . reason)
          (bcom (^topic-observer bcom scope-id observer-ref
                                 alert-store-ref ctx allowed-actions
                                 allowed-specs accepted (+ rejected 1))
                (list 'rejected reason))))))

    ((rewire obs-ref alert-ref new-ctx)
     (bcom (^topic-observer bcom scope-id obs-ref alert-ref new-ctx
                             allowed-actions allowed-specs
                             accepted rejected)))

    ((get-stats)
     `((accepted . ,accepted) (rejected . ,rejected)))))


;; =========================================================================
;; Attenuation — the ONLY logic this actor adds beyond the codec
;; =========================================================================

(define (attenuate-and-parse payload-string allowed-actions allowed-specs)
  "Parse via codec, then enforce attenuation policy.
   Returns ('ok . event) or ('error . reason)."
  (catch #t
    (lambda ()
      (let* ((event (json->economic-event (json-string->scm payload-string)))
             (action (economic-event-action event))
             (spec (economic-event-resource-conforms-to event)))
        (when (and allowed-actions (not (memq action allowed-actions)))
          (error "Action not permitted" action))
        (when (and allowed-specs spec (not (member spec allowed-specs)))
          (error "Spec not permitted" spec))
        (cons 'ok event)))
    (lambda (key . args)
      (cons 'error (format #f "~a: ~a" key args)))))
