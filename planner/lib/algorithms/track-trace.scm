;;; track-trace.scm — Resource provenance (trace backward) and destination (track forward)

(use-modules (srfi srfi-1))

(define* (trace start-id observer #:key (include-stale #f))
  "DFS backward traversal from resource/event.
   Returns list of flow-node alists in dependency order (inputs first)."
  (let ((visited (make-hash-table))
        (result '()))
    (define (visit-event event-id depth parent-id)
      (when (and event-id (not (hash-ref visited event-id #f)))
        (hash-set! visited event-id #t)
        (let ((event ($ observer 'get-event event-id)))
          (when event
            ;; Skip corrected events unless include-stale
            (unless (and (not include-stale) (economic-event-corrects event))
              (set! result (cons `((id . ,event-id) (type . event) (depth . ,depth)
                                  (parent . ,parent-id) (event . ,event))
                                result))
              ;; Follow inputOf → process → outputOf events
              (when (economic-event-input-of event)
                (visit-process (economic-event-input-of event) (+ depth 1) event-id))
              ;; Follow resource backward
              (when (economic-event-resource-inventoried-as event)
                (let ((r ($ observer 'get-resource (economic-event-resource-inventoried-as event))))
                  (when (and r (economic-resource-previous-event r))
                    (visit-event (economic-resource-previous-event r) (+ depth 1) event-id)))))))))

    (define (visit-process process-id depth parent-id)
      (unless (hash-ref visited process-id #f)
        (hash-set! visited process-id #t)
        ;; Find output events for this process
        (let ((events ($ observer 'events-for-process process-id)))
          (for-each
            (lambda (e)
              (when (economic-event-output-of e)
                (visit-event (economic-event-id e) depth parent-id)))
            events))))

    ;; Start from resource or event
    (let ((resource ($ observer 'get-resource start-id)))
      (if resource
          ;; Start from resource's last event
          (when (economic-resource-previous-event resource)
            (visit-event (economic-resource-previous-event resource) 0 #f))
          ;; Start from event directly
          (visit-event start-id 0 #f)))
    (reverse result)))

(define* (track start-id observer #:key (include-stale #f))
  "DFS forward traversal from resource/event. Returns flow-node list."
  (let ((visited (make-hash-table))
        (result '()))
    (define (visit-event event-id depth parent-id)
      (when (and event-id (not (hash-ref visited event-id #f)))
        (hash-set! visited event-id #t)
        (let ((event ($ observer 'get-event event-id)))
          (when event
            (unless (and (not include-stale) (economic-event-corrects event))
              (set! result (cons `((id . ,event-id) (type . event) (depth . ,depth)
                                  (parent . ,parent-id) (event . ,event))
                                result))
              ;; Follow outputOf → process → inputOf events (forward)
              (when (economic-event-output-of event)
                (visit-process-forward (economic-event-output-of event) (+ depth 1) event-id)))))))

    (define (visit-process-forward process-id depth parent-id)
      (unless (hash-ref visited process-id #f)
        (hash-set! visited process-id #t)
        (let ((events ($ observer 'events-for-process process-id)))
          (for-each
            (lambda (e)
              (when (economic-event-input-of e)
                (visit-event (economic-event-id e) depth parent-id)))
            events))))

    (let ((resource ($ observer 'get-resource start-id)))
      (if resource
          ;; Find events where this resource is the input
          (let ((events ($ observer 'events-for-resource start-id)))
            (for-each
              (lambda (e)
                (when (equal? (economic-event-resource-inventoried-as e) start-id)
                  (visit-event (economic-event-id e) 0 #f)))
              events))
          (visit-event start-id 0 #f)))
    (reverse result)))
