;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/interface/output-sink.scm — Channel output sink
;;;
;;; The *print side* of a channel. Receives output (strings, alerts —
;;; whatever a backend chooses to push), formats it via the configured
;;; formatter, and delivers via the bound transport adapter. Queues
;;; output when offline so nothing is lost while a transport is
;;; detached.
;;;
;;; Optional doorbell: a fire-and-forget callback that fires when a
;;; message queues while no transport is bound. Used for Web Push —
;;; the doorbell sends a preview to wake the device, the full content
;;; stays in the queue for the reconnect flush.
;;;
;;; Layer-pure: this module knows about no specific alert vocabulary
;;; or backend type. The default `passthrough-formatter` is a trivial
;;; string-coercion; backends that ship richer alert shapes also ship
;;; their own formatters (see e.g. `scope-alert-formatter` in
;;; `backends/scope.scm`).

(define-module (localchimera interface output-sink)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:export (^output-sink
            passthrough-formatter))


;; =========================================================================
;; ^output-sink — the print side of a channel
;; =========================================================================

(define* (^output-sink bcom
                       channel-context
                       transport
                       formatter
                       queue
                       #:optional (doorbell #f))
  ;; doorbell: (lambda (formatted-text) ...) or #f
  ;; Called when a message queues while offline — for push previews.

  (methods

    ((print datum)
     (if transport
         (let ((text (formatter datum)))
           (<-np transport 'send-message channel-context text)
           'delivered)
         (let ((text (formatter datum)))
           (when doorbell (doorbell text))
           (bcom (^output-sink bcom channel-context transport
                                formatter (cons datum queue) doorbell)))))

    ((bind-transport new-transport new-context)
     (for-each
       (lambda (datum)
         (let ((text (formatter datum)))
           (<-np new-transport 'send-message new-context text)))
       (reverse queue))
     (bcom (^output-sink bcom new-context new-transport
                          formatter '() doorbell)))

    ((unbind-transport)
     (bcom (^output-sink bcom channel-context #f
                          formatter queue doorbell)))

    ((flush)
     (when transport
       (for-each
         (lambda (datum)
           (let ((text (formatter datum)))
             (<-np transport 'send-message channel-context text)))
         (reverse queue)))
     (bcom (^output-sink bcom channel-context transport
                          formatter '() doorbell)))

    ((pending-count)
     (length queue))

    ((set-formatter new-formatter)
     (bcom (^output-sink bcom channel-context transport
                          new-formatter queue doorbell)))

    ((set-doorbell new-doorbell)
     (bcom (^output-sink bcom channel-context transport
                          formatter queue new-doorbell)))))


;; =========================================================================
;; Generic passthrough formatter
;; =========================================================================

(define (passthrough-formatter datum)
  "Default formatter: strings pass through unchanged; anything else gets
   coerced via ~a. Backends that want richer formatting pass their own."
  (if (string? datum) datum (format #f "~a" datum)))
