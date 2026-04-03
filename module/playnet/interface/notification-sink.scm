;;; module/playnet/interface/notification-sink.scm — Output sink + tee proxy
;;;
;;; Two actors:
;;;
;;;   ^tee-alert-store  — Proxy that interposes on push-alert to tee alerts
;;;                       to both the real alert-store AND the output sink.
;;;                       All read methods delegate unchanged. This avoids
;;;                       modifying record-and-monitor or any execution code.
;;;
;;;   ^output-sink — The print side of a channel. Receives output (alerts,
;;;                  messages, anything), formats it, and delivers via a
;;;                  transport adapter. Queues output when offline (same
;;;                  pattern as ^mailbox). Analogous to ^output-port in
;;;                  gplay.scm, but routed through a transport rather than
;;;                  a local port.

(define-module (playnet interface notification-sink)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:export (^tee-alert-store
            ^output-sink
            default-alert-formatter))


;; =========================================================================
;; ^tee-alert-store — proxy interposition on ^alert-store
;; =========================================================================

(define (^tee-alert-store bcom inner-store output-sink)
  ;; inner-store: the real ^alert-store actor ref
  ;; output-sink: ^output-sink actor ref

  (methods

    ;; The interposition point: tee push-alert to both targets
    ((push-alert alert)
     ($ inner-store 'push-alert alert)
     (<-np output-sink 'print alert))

    ;; All read methods delegate to the inner store unchanged
    ((of-kind kind)        ($ inner-store 'of-kind kind))
    ((for-spec spec-id)    ($ inner-store 'for-spec spec-id))
    ((since timestamp)     ($ inner-store 'since timestamp))
    ((all-alerts)          ($ inner-store 'all-alerts))
    ((alert-count)         ($ inner-store 'alert-count))
    ((clear)               ($ inner-store 'clear))))


;; =========================================================================
;; ^output-sink — the print side of a channel
;; =========================================================================

(define (^output-sink bcom
                      channel-context  ;; opaque transport destination (chat-id, room-id, etc.)
                      transport        ;; ^transport-adapter ref or #f
                      formatter        ;; (datum) -> string
                      queue)           ;; list of unsent items (offline buffer)

  (methods

    ((print datum)
     ;; The main entry point. Anything that needs to be displayed
     ;; comes through here — alerts, messages, results, whatever.
     ;; If transport is attached, format and deliver immediately.
     ;; Otherwise, queue for later flush.
     (if transport
         (let ((text (formatter datum)))
           (<-np transport 'send-message channel-context text)
           'delivered)
         (bcom (^output-sink bcom channel-context transport
                              formatter (cons datum queue)))))

    ((bind-transport new-transport new-context)
     ;; Attach a transport adapter and flush any queued output.
     (for-each
       (lambda (datum)
         (let ((text (formatter datum)))
           (<-np new-transport 'send-message new-context text)))
       (reverse queue))
     (bcom (^output-sink bcom new-context new-transport
                          formatter '())))

    ((unbind-transport)
     ;; Detach transport; future output goes to queue.
     (bcom (^output-sink bcom channel-context #f
                          formatter queue)))

    ((flush)
     ;; Re-deliver all queued output through current transport.
     (when transport
       (for-each
         (lambda (datum)
           (let ((text (formatter datum)))
             (<-np transport 'send-message channel-context text)))
         (reverse queue)))
     (bcom (^output-sink bcom channel-context transport
                          formatter '())))

    ((pending-count)
     (length queue))

    ((set-formatter new-formatter)
     (bcom (^output-sink bcom channel-context transport
                          new-formatter queue)))))


;; =========================================================================
;; Default alert formatter
;; =========================================================================

(define (default-alert-formatter alert)
  "Format an alert alist as a human-readable string."
  (let ((kind (or (assq-ref alert 'kind) 'unknown))
        (spec (or (assq-ref alert 'spec-id) ""))
        (ts (or (assq-ref alert 'timestamp) "")))
    (match kind
      ('buffer-status
       (let ((zone (or (assq-ref alert 'zone) "?"))
             (onhand (or (assq-ref alert 'onhand) "?")))
         (format #f "[ALERT] ~a in ~a zone (onhand: ~a)" spec zone onhand)))
      ('material-sync
       (let ((shortage (or (assq-ref alert 'shortage) "?"))
             (process (or (assq-ref alert 'process-id) "")))
         (format #f "[ALERT] ~a shortage: ~a (process: ~a)" spec shortage process)))
      ('adu-shift
       (let ((dir (or (assq-ref alert 'direction) "?"))
             (pct (or (assq-ref alert 'change-pct) "?")))
         (format #f "[ALERT] ~a ADU shifted ~a by ~a%" spec dir pct)))
      (_
       (format #f "[ALERT] ~a: ~a (~a)" kind spec ts)))))
