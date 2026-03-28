;;; signal-publisher.scm — Publish planning signals to MQTT
;;;
;;; Takes signal alists (from signals.scm) and publishes them as JSON
;;; to MQTT topics via the bridge actor.  Called explicitly after a
;;; planning run completes — the planner is a batch compiler, not reactive.
;;;
;;; Assumes schemas.scm, codec.scm, signals.scm are loaded.

(use-modules (goblins)
             (goblins actor-lib methods))


(define (^signal-publisher bcom
                           publish-fn   ;; procedure: (topic payload-string) → void
                           scope-id     ;; string
                           published)   ;; count of published messages
  (methods
    ((publish-signal signal)
     ;; signal: typed signal alist with 'kind key
     (let* ((kind (assq-ref signal 'kind))
            (spec-id (assq-ref signal 'spec-id))
            (topic (if spec-id
                       (build-topic scope-id "signals"
                                    (symbol->string kind) spec-id)
                       (build-topic scope-id "signals"
                                    (symbol->string kind))))
            (payload (signal->json-string signal)))
       (publish-fn topic payload)
       (bcom (^signal-publisher bcom publish-fn scope-id (+ published 1)))))

    ((publish-batch signals)
     ;; Publish a list of signals (after a planning run).
     ;; Returns count published.
     (let loop ((sigs signals) (n 0) (self (lambda () #f)))
       (if (null? sigs)
           (begin
             (bcom (^signal-publisher bcom publish-fn scope-id
                                      (+ published n)))
             n)
           (let* ((signal (car sigs))
                  (kind (assq-ref signal 'kind))
                  (spec-id (assq-ref signal 'spec-id))
                  (topic (if spec-id
                             (build-topic scope-id "signals"
                                          (symbol->string kind) spec-id)
                             (build-topic scope-id "signals"
                                          (symbol->string kind))))
                  (payload (signal->json-string signal)))
             (publish-fn topic payload)
             (loop (cdr sigs) (+ n 1) self)))))

    ((get-stats)
     `((published . ,published)))))
