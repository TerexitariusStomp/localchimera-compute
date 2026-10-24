;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/interface/call-context.scm — Per-call context (interface layer)
;;;
;;; A call-context bundles everything an interface-layer caller knows about
;;; a request: who, where, and how to talk back. Layer-pure: this module
;;; knows nothing about scopes, ledgers, or any specific backend.
;;;
;;;   ^channel.handle-input → backend.handle → handler / flow-step
;;;
;;; The channel builds a `request-ctx` carrying user-id, channel-id,
;;; channel-ref, raw-text. The backend (whatever it is) may `extend-ctx`
;;; with its own fields before passing the result to its inner machinery
;;; — but those fields are the backend's business, not this module's.
;;; A scope-handler adds `scope-ref` and `org-ref`; a router doesn't add
;;; anything; a read-only-view might add a snapshot ref. The accessors
;;; for backend-specific fields belong with the backend that defines them.
;;;
;;; Represented as alists for cheap serialization across OCapN, easy
;;; extension, and trivial composition. Accessors are tolerant: missing
;;; fields return #f.
;;;
;;; A handler that wants to send extra messages back to the user (beyond
;;; its return value) calls (ctx-reply ctx text) — this uses <-np against
;;; the channel-ref so it works for both local and remote backends.

(define-module (localchimera interface call-context)
  #:use-module (goblins)
  #:export (make-request-ctx
            extend-ctx
            ctx-ref
            ctx-user
            ctx-channel
            ctx-channel-id
            ctx-raw
            ctx-reply
            ctx-start-flow
            ctx-cancel-flow))


;; =========================================================================
;; Constructors
;; =========================================================================

(define (make-request-ctx user-id channel-id channel-ref raw-text)
  "Build a request-ctx — the slice that crosses the channel→backend boundary."
  `((user-id     . ,user-id)
    (channel-id  . ,channel-id)
    (channel-ref . ,channel-ref)
    (raw-text    . ,raw-text)))

(define (extend-ctx ctx . field-pairs)
  "Return a new ctx with FIELD-PAIRS prepended. FIELD-PAIRS is a flat list
   of (key value key value ...). Later lookups shadow earlier ones, which
   is exactly the alist semantics we want.

   Backends use this to add their own fields (e.g. scope-handler adds
   scope-ref + org-ref). Accessors for those fields live with the
   backend that owns them — keep call-context layer-pure."
  (let loop ((rest field-pairs) (acc ctx))
    (cond
     ((null? rest) acc)
     ((null? (cdr rest))
      (error "extend-ctx: odd number of field arguments" field-pairs))
     (else
      (loop (cddr rest)
            (cons (cons (car rest) (cadr rest)) acc))))))


;; =========================================================================
;; Generic + interface-layer accessors
;; =========================================================================

(define (ctx-ref ctx key)        (assq-ref ctx key))
(define (ctx-user ctx)           (assq-ref ctx 'user-id))
(define (ctx-channel ctx)        (assq-ref ctx 'channel-ref))
(define (ctx-channel-id ctx)     (assq-ref ctx 'channel-id))
(define (ctx-raw ctx)            (assq-ref ctx 'raw-text))


;; =========================================================================
;; Channel callbacks
;; =========================================================================
;; Helpers handlers reach for when they want to do more than just return a
;; string. All go through <-np so a handler running in a remote scope-vat
;; can still talk back to a channel in the bridge-vat.

(define (ctx-reply ctx text)
  "Send TEXT to the channel as an extra message, outside the normal
   handler return value. No-op if the channel-ref is absent."
  (let ((chan (ctx-channel ctx)))
    (when chan
      (<-np chan 'send-out text))))

(define (ctx-start-flow ctx flow-name)
  "Ask the channel to start FLOW-NAME for this user. Returns a vow."
  (let ((chan (ctx-channel ctx)))
    (and chan
         (<- chan 'start-flow (ctx-user ctx) flow-name))))

(define (ctx-cancel-flow ctx)
  "Ask the channel to cancel any active flow for this user."
  (let ((chan (ctx-channel ctx)))
    (when chan
      (<-np chan 'cancel-flow (ctx-user ctx)))))
