;;; topic-observer.scm — Per-topic attenuating proxy actor
;;;
;;; Sits between raw MQTT messages and the scope's ^observer.
;;; Parses JSON, validates against VF schema, enforces attenuation
;;; (allowed actions, allowed specs), then forwards to the observer.
;;;
;;; This is the logical capability boundary — even if Mosquitto ACLs
;;; let a message through, this actor enforces fine-grained VF constraints.
;;;
;;; Assumes schemas.scm, codec.scm are loaded.

(use-modules (goblins)
             (goblins actor-lib methods)
             (json)
             (ice-9 match))


(define (^topic-observer bcom
                         scope-id         ;; string
                         observer-ref     ;; capability ref to ^observer (record-event only)
                         allowed-actions  ;; list of action symbols, or #f for any
                         allowed-specs    ;; list of spec-id strings, or #f for any
                         stats)           ;; alist: ((accepted . N) (rejected . N))
  (define accepted (or (assq-ref stats 'accepted) 0))
  (define rejected (or (assq-ref stats 'rejected) 0))

  (methods
    ((receive-message topic payload-string)
     ;; Returns: (values 'accepted event) or (values 'rejected reason)
     (let ((result (parse-and-validate payload-string allowed-actions allowed-specs)))
       (match result
         (('ok . event)
          (let ((affected ($ observer-ref 'record-event event)))
            (bcom (^topic-observer bcom scope-id observer-ref
                                   allowed-actions allowed-specs
                                   `((accepted . ,(+ accepted 1))
                                     (rejected . ,rejected))))
            (values 'accepted event)))
         (('error . reason)
          (bcom (^topic-observer bcom scope-id observer-ref
                                 allowed-actions allowed-specs
                                 `((accepted . ,accepted)
                                   (rejected . ,(+ rejected 1)))))
          (values 'rejected reason)))))

    ((get-stats)
     `((accepted . ,accepted) (rejected . ,rejected)))))


;; =========================================================================
;; Validation pipeline (pure)
;; =========================================================================

(define (parse-and-validate payload-string allowed-actions allowed-specs)
  "Parse JSON, validate, translate, check attenuation.
   Returns ('ok . event) or ('error . reason-string)."
  (catch #t
    (lambda ()
      (let* ((obj (json-string->scm payload-string))
             (action-str (json-ref obj "action")))
        ;; Required field: action
        (unless action-str
          (error "Missing required field: action"))
        (let ((action (string->action action-str)))
          ;; Attenuation: allowed actions
          (when (and allowed-actions (not (memq action allowed-actions)))
            (error "Action not permitted" action allowed-actions))
          ;; Attenuation: allowed specs
          (let ((spec (json-ref obj "resourceConformsTo")))
            (when (and allowed-specs spec (not (member spec allowed-specs)))
              (error "Spec not permitted" spec allowed-specs)))
          ;; Translate to VF record
          (let ((event (json->economic-event obj)))
            (cons 'ok event)))))
    (lambda (key . args)
      (cons 'error (format #f "~a: ~a" key args)))))
