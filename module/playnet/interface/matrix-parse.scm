;;; module/playnet/interface/matrix-parse.scm — pure parsing helpers
;;;
;;; Same role as telegram-parse.scm: pull the network-free, actor-free
;;; bits out of the bridge daemon so they're testable. The shapes here
;;; come from guile-json's json-string->scm: JSON objects → alists with
;;; string keys, JSON arrays → vectors.

(define-module (playnet interface matrix-parse)
  #:use-module (srfi srfi-1)
  #:export (alist?
            extract-message-from-event
            joined-rooms-from-sync
            channel-id-for-room))

(define (alist? x)
  (and (list? x) (every pair? x)))

(define (extract-message-from-event event self-mxid)
  "Pull (sender body) out of a Matrix timeline event, or #f if it's
   not a routable text message. SELF-MXID lets us drop self-echo so the
   bot doesn't reply to its own messages."
  (let* ((type    (and (alist? event) (assoc-ref event "type")))
         (sender  (and (alist? event) (assoc-ref event "sender")))
         (content (and (alist? event) (assoc-ref event "content")))
         (msgtype (and (alist? content) (assoc-ref content "msgtype")))
         (body    (and (alist? content) (assoc-ref content "body"))))
    (and (equal? type "m.room.message")
         (equal? msgtype "m.text")
         (string? sender)
         (string? body)
         (not (equal? sender self-mxid))
         (list sender body))))

(define (joined-rooms-from-sync sync-response)
  "Walk a /sync response and return a list of (room-id . events-list)
   pairs for joined rooms with timeline events. Empty timelines are
   skipped. EVENTS-LIST is a Scheme list (vector flattened)."
  (let* ((rooms (and (alist? sync-response)
                     (assoc-ref sync-response "rooms")))
         (join  (and (alist? rooms) (assoc-ref rooms "join"))))
    (cond
     ((not (alist? join)) '())
     (else
      (filter-map
       (lambda (entry)
         (let* ((room-id  (car entry))
                (room-obj (cdr entry))
                (timeline (and (alist? room-obj)
                               (assoc-ref room-obj "timeline")))
                (events   (and (alist? timeline)
                               (assoc-ref timeline "events"))))
           (cond
            ((vector? events)
             (and (positive? (vector-length events))
                  (cons room-id (vector->list events))))
            ((pair? events)
             (cons room-id events))
            (else #f))))
       join)))))

(define (channel-id-for-room room-id)
  ;; Matrix room IDs already have ! and : in them; just prefix.
  (string-append "mx-" room-id))
