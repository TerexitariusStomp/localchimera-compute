;;; track-trace.scm — Resource provenance (trace backward) and destination (track forward)

(define-module (playnet algorithms track-trace)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:export (trace track)
  #:use-module (srfi srfi-1))


(define* (trace start-id observer #:key (include-stale #f))
  "DFS BACKWARD traversal from a resource or event: what this came from.
   Returns a list of flow-node alists in dependency order (inputs first).

   Two backward edges, and only backward ones:
     output-of P   → every INPUT event of P (what the process consumed,
                     used and worked to make this)
     on resource R → the event recorded on R just before this one (the
                     observer's by-resource index, newest first — the
                     chain trace-resource would walk if every event
                     carried its previousEvent; ordinary events do not)
   An input event's own provenance is its resource's earlier history, so
   an input never pulls its process's OUTPUTS in — that is the forward
   direction, `track`'s."
  (let ((visited (make-hash-table))
        (result '()))
    (define (prior-on-resource event)
      ;; the event just before EVENT on the same resource, or #f
      (let ((rid (economic-event-resource-inventoried-as event)))
        (and rid
             (let loop ((es ($ observer 'events-for-resource rid)))   ; newest first
               (cond ((or (null? es) (null? (cdr es))) #f)
                     ((equal? (economic-event-id (car es)) (economic-event-id event))
                      (economic-event-id (cadr es)))
                     (else (loop (cdr es))))))))
    (define (visit-event event-id depth parent-id)
      (when (and event-id (not (hash-ref visited event-id #f)))
        (hash-set! visited event-id #t)
        (let ((event ($ observer 'get-event event-id)))
          (when event
            (unless (and (not include-stale) (economic-event-corrects event))
              (set! result (cons `((id . ,event-id) (type . event) (depth . ,depth)
                                  (parent . ,parent-id) (event . ,event))
                                result))
              ;; what made this: the process's inputs
              (when (economic-event-output-of event)
                (visit-process-inputs (economic-event-output-of event) (+ depth 1) event-id))
              ;; what this was before: the resource's earlier event — the
              ;; event's own previousEvent when stamped, else the index
              (let ((prev (or (economic-event-previous-event event)
                              (prior-on-resource event))))
                (when prev (visit-event prev (+ depth 1) event-id))))))))
    (define (visit-process-inputs process-id depth parent-id)
      (unless (hash-ref visited process-id #f)
        (hash-set! visited process-id #t)
        (for-each
          (lambda (e)
            (when (equal? process-id (economic-event-input-of e))
              (visit-event (economic-event-id e) depth parent-id)))
          ($ observer 'events-for-process process-id))))
    ;; Start from resource or event
    (let ((resource ($ observer 'get-resource start-id)))
      (if resource
          (when (economic-resource-previous-event resource)
            (visit-event (economic-resource-previous-event resource) 0 #f))
          (visit-event start-id 0 #f)))
    (reverse result)))

(define* (track start-id observer #:key (include-stale #f))
  "DFS FORWARD traversal from a resource or event: what this became. The
   dual of `trace`, edge for edge:
     input-of P    → every OUTPUT event of P (what the process made of it)
     on resource R → the event recorded on R just after this one
   Returns flow-node alists, origin first."
  (let ((visited (make-hash-table))
        (result '()))
    (define (next-on-resource event)
      (let ((rid (economic-event-resource-inventoried-as event)))
        (and rid
             (let loop ((es ($ observer 'events-for-resource rid)) (newer #f))   ; newest first
               (cond ((null? es) #f)
                     ((equal? (economic-event-id (car es)) (economic-event-id event))
                      (and newer (economic-event-id newer)))
                     (else (loop (cdr es) (car es))))))))
    (define (visit-event event-id depth parent-id)
      (when (and event-id (not (hash-ref visited event-id #f)))
        (hash-set! visited event-id #t)
        (let ((event ($ observer 'get-event event-id)))
          (when event
            (unless (and (not include-stale) (economic-event-corrects event))
              (set! result (cons `((id . ,event-id) (type . event) (depth . ,depth)
                                  (parent . ,parent-id) (event . ,event))
                                result))
              ;; what this fed: the process's outputs
              (when (economic-event-input-of event)
                (visit-process-outputs (economic-event-input-of event) (+ depth 1) event-id))
              ;; what happened to it next on its own resource
              (let ((next (next-on-resource event)))
                (when next (visit-event next (+ depth 1) event-id))))))))
    (define (visit-process-outputs process-id depth parent-id)
      (unless (hash-ref visited process-id #f)
        (hash-set! visited process-id #t)
        (for-each
          (lambda (e)
            (when (equal? process-id (economic-event-output-of e))
              (visit-event (economic-event-id e) depth parent-id)))
          ($ observer 'events-for-process process-id))))
    (let ((resource ($ observer 'get-resource start-id)))
      (if resource
          ;; from the resource's OLDEST event forward
          (let ((events (reverse ($ observer 'events-for-resource start-id))))
            (for-each
              (lambda (e)
                (when (equal? (economic-event-resource-inventoried-as e) start-id)
                  (visit-event (economic-event-id e) 0 #f)))
              events))
          (visit-event start-id 0 #f)))
    (reverse result)))
