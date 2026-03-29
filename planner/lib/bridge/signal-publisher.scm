;;; signal-publisher.scm — Publish planning signals to MQTT
;;;
;;; Takes signal alists (from signals.scm) and publishes them as JSON
;;; to MQTT topics via a publish-fn capability.  Called explicitly after
;;; a planning run completes — the planner is a batch compiler, not reactive.
;;;
;;; Assumes schemas.scm, codec.scm, signals.scm are loaded.

(use-modules (goblins)
             (goblins actor-lib methods)
             (ice-9 match))


(define (signal-topic scope-id signal)
  "Build the MQTT topic for a signal alist."
  (let ((kind (assq-ref signal 'kind))
        (spec-id (assq-ref signal 'spec-id)))
    (if spec-id
        (build-topic scope-id "signals" (symbol->string kind) spec-id)
        (build-topic scope-id "signals" (symbol->string kind)))))

(define (publish-one! publish-fn scope-id signal)
  "Publish a single signal.  Returns the topic."
  (let ((topic (signal-topic scope-id signal)))
    (publish-fn topic (signal->json-string signal))
    topic))


(define-actor (^signal-publisher bcom
                                 publish-fn   ;; procedure: (topic payload) → void
                                 scope-id     ;; string
                                 published)   ;; integer

  #:portrait
  (lambda () (list scope-id published))

  #:version 1

  #:restore
  (lambda (version data)
    (match data
      ((sid pub)
       ;; publish-fn must be re-attached via 'rewire after restore.
       (spawn ^signal-publisher #f sid pub))))

  (methods

    ((publish-signal signal)
     (let ((topic (publish-one! publish-fn scope-id signal)))
       (bcom (^signal-publisher bcom publish-fn scope-id (+ published 1))
             topic)))

    ((publish-batch signals)
     (for-each (lambda (s) (publish-one! publish-fn scope-id s)) signals)
     (bcom (^signal-publisher bcom publish-fn scope-id
                               (+ published (length signals)))
           (length signals)))

    ((rewire new-publish-fn)
     (bcom (^signal-publisher bcom new-publish-fn scope-id published)))

    ((get-stats)
     `((published . ,published)))))
