;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/push/subscriptions.scm — whose device a Web Push reaches.
;;;
;;; The decisions around the transport, as pure functions with no crypto and
;;; no actors, so they are tested by themselves (tests/push/
;;; test-push-adapter.scm) and (localchimera push adapter) carries them out.

(define-module (localchimera push subscriptions)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:export (parse-subscription subscriptions-for deliver-to!))

;;; ── a subscription, and whose it is ─────────────────────────────────────
;;;
;;; A browser hands over its PushSubscription as JSON
;;; ({endpoint, keys: {p256dh, auth}}) under the id of the device it is on.
;;; The store keeps it PARSED, keyed by that device id: the id is what the
;;; recipient registry binds a `push` channel to and what the router hands
;;; back as the delivery's context, and it is what an expired subscription is
;;; removed by.

(define (parse-subscription json)
  "The subscription JSON as an alist, or #f when it is no subscription: it
   parses, and names an endpoint and both keys."
  (let ((sub (and (string? json)
                  (false-if-exception (json-string->scm json)))))
    (and (pair? sub)
         (string? (assoc-ref sub "endpoint"))
         (let ((keys (assoc-ref sub "keys")))
           (and (pair? keys)
                (string? (assoc-ref keys "p256dh"))
                (string? (assoc-ref keys "auth"))))
         sub)))

(define (subscriptions-for entries ctx)
  "The (device-id . subscription) entries a delivery reaches: the one device
   CTX names, or every device when CTX is #f (a broadcast)."
  (if ctx
      (filter (lambda (e) (equal? (car e) ctx)) entries)
      entries))

(define (deliver-to! send! entries payload urgency gone!)
  "Send PAYLOAD to each of ENTRIES with (SEND! subscription payload urgency),
   and call (GONE! device-id) for each the push service reports expired."
  (for-each
   (lambda (e)
     (when (eq? (send! (cdr e) payload urgency) 'gone)
       (gone! (car e))))
   entries))
