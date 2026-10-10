;;; signal-publisher.scm — Publish planning signals to MQTT
;;;
;;; Takes signal alists (from signals.scm) and publishes them as JSON
;;; to MQTT topics via a publish-fn capability.  Called explicitly after
;;; a planning run completes — the planner is a batch compiler, not reactive.
;;;
;;; THE topic contract lives here, in `signal-topic`, and it is the shape
;;; the consumers actually subscribe to: playnet/signals/<kind>/<spec-id>
;;; (server/dev-bridge.scm reads playnet/signals/deficit/#, and the
;;; mosquitto ACL grants the "publisher" account playnet/signals/#).
;;; The scope travels IN the payload — publish-one! annotates the signal
;;; with its scope-id — so the topic tree stays one flat signal fabric
;;; every consumer can subscribe to by kind, whichever scope emitted it.
;;; tools/dev-signal-cycle.scm publishes through this same door.
;;;
;;; Assumes schemas.scm, codec.scm, signals.scm are loaded.

(define-module (playnet bridge signal-publisher)
  #:use-module (playnet bridge codec)
  #:use-module (ice-9 match)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (signal-topic publish-one! ^signal-publisher))


(define (signal-topic signal)
  "Build the MQTT topic for a signal alist: playnet/signals/<kind>/<spec-id>
   (playnet/signals/<kind> when the signal names no spec)."
  (let ((kind (assq-ref signal 'kind))
        (spec-id (assq-ref signal 'spec-id)))
    (string-join
     (append (list "playnet" "signals" (symbol->string kind))
             (if spec-id (list spec-id) '()))
     "/")))

(define (publish-one! publish-fn scope-id signal)
  "Publish a single signal, its scope carried in the payload.  Returns the topic."
  (let ((topic (signal-topic signal))
        (annotated (if (or (not scope-id) (assq 'scope signal))
                       signal
                       (cons (cons 'scope scope-id) signal))))
    (publish-fn topic (signal->json-string annotated))
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
