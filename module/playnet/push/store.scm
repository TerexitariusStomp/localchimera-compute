;;; module/playnet/push/store.scm — ^push-subscription-store
;;;
;;; Each device's Web Push subscription, parsed, keyed by the device's id
;;; ((playnet push subscriptions) says why that key). The store is the one
;;; piece of push state and touches no crypto: (playnet push adapter), which
;;; puts a notification on the wire, needs libgcrypt; a gateway test of the
;;; stores a member is forgotten from (tests/keri/test-forget.scm) needs only
;;; this. The adapter re-exports it, so the gateway's import stands.

(define-module (playnet push store)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module ((playnet push subscriptions) #:select (parse-subscription))
  #:use-module ((srfi srfi-1) #:select (remove))
  #:export (^push-subscription-store))

(define (^push-subscription-store bcom subscriptions)
  (methods
   ;; SUBSCRIPTION is the browser's JSON; one that does not parse is refused
   ;; and the device keeps the subscription it had.
   ((register device-id subscription)
    (let ((sub (parse-subscription subscription)))
      (if sub
          (bcom (^push-subscription-store
                 bcom
                 (cons (cons device-id sub)
                       (remove (lambda (p) (equal? (car p) device-id))
                               subscriptions)))
                'ok)
          'malformed)))
   ;; idempotent: a device-id with no subscription is left as it is
   ((unregister device-id)
    (bcom (^push-subscription-store
            bcom (remove (lambda (p) (equal? (car p) device-id))
                         subscriptions))
          'ok))
   ((entries) subscriptions)
   ((count) (length subscriptions))))
