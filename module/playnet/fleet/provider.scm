;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/fleet/provider.scm — fleet provider protocol
;;;
;;; A provider is an alist of 6 closures, one per reconciler coupling
;;; point. Any VPS backend (SporeStack, VPSBG, bare metal) implements
;;; this protocol to be dispatched by the fleet reconciler.
;;;
;;; Protocol:
;;;
;;;   create-invoice : (host) → (values invoice-id uri currency amount)
;;;   poll-payment   : (host entry) → 'funded | 'pending
;;;   launch         : (host entry) → machine-id
;;;   poll-server    : (machine-id) → (values running? ipv4)
;;;   delete-server  : (machine-id) → #t
;;;   list-servers   : () → list
;;;
;;; Usage:
;;;
;;;   (define registry
;;;     (make-provider-registry
;;;       `(("sporestack" . ,(make-sporestack-provider creds))
;;;         ("vpsbg"      . ,(make-vpsbg-provider vpsbg-creds)))))
;;;
;;;   (provider-call (registry-ref registry "sporestack")
;;;                  'launch host entry)

(define-module (playnet fleet provider)
  #:export (provider-call
            provider-ref
            make-provider-registry
            registry-ref))

(define (provider-ref provider op)
  "Look up operation OP in a provider alist. Returns the closure."
  (let ((pair (assq op provider)))
    (unless pair
      (error "provider: unknown operation" op))
    (cdr pair)))

(define (provider-call provider op . args)
  "Call operation OP on PROVIDER with ARGS."
  (apply (provider-ref provider op) args))

(define (make-provider-registry pairs)
  "Build a provider registry from an alist of (name . provider).
NAME is a string (e.g. \"sporestack\"), PROVIDER is an alist of closures."
  pairs)

(define (registry-ref registry name)
  "Look up provider NAME in the registry. Errors if not found."
  (let ((pair (assoc name registry)))
    (unless pair
      (error "provider registry: unknown provider" name))
    (cdr pair)))
