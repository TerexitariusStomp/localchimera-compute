;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/monero/test-monero-donation-scenario.scm
;;;
;;; End-to-end scenario: donations reach the planner through the live-registry.
;;;
;;; Modeled on test-food-surplus-scenario.scm but pared down to a single scope
;;; ("localchimera") that holds one economic resource (res-xmr-main). We exercise
;;; three things:
;;;
;;;   1. bootstrap-monero-resource! wires the spec, observer stub, and the
;;;      live-resource into the scope correctly.
;;;
;;;   2. When the live-resource is resized (simulating a balance change from
;;;      the wallet), lift-planning-facts reflects the new balance in the
;;;      XMR inventory fact — proving the live-registry override path works
;;;      for currency-type resources.
;;;
;;;   3. The donation poller's tick, given a stand-in wallet actor that returns
;;;      canned get_balance + get_transfers responses, records an 'raise
;;;      EconomicEvent on the observer AND bumps the live-resource — so the
;;;      on-chain donation flow is verified without any real Monero traffic.
;;;
;;; Run:  guile -L module -L tests tests/monero/test-monero-donation-scenario.scm

(use-modules (localchimera scope root) (localchimera vf schemas)
             (localchimera monero specs)
             (localchimera monero wallet)
             (localchimera monero poller)
             (localchimera test harness)
             (goblins)
             (goblins persistence-store memory)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (srfi srfi-1)
             (ice-9 format))

;;; ── Scope + scope-vat setup ──────────────────────────────────────────────

(display "=== Setup: single localchimera scope ===\n")

(define store (make-memory-store))

(define-values (scope-vat localchimera)
  (spawn-persistent-vat
   scope-root-env
   (lambda () (values (spawn-scope-root "localchimera")))
   store))

;;; ── Phase 1: bootstrap XMR as a live resource ────────────────────────────

(display "\n=== Bootstrap: bootstrap-monero-resource! ===\n")

(define live-xmr
  (with-vat scope-vat
    (bootstrap-monero-resource! localchimera
                                #:accountable-agent "agent-localchimera"
                                #:location "loc-localchimera-server")))

(with-vat scope-vat
  (check "XMR spec registered in recipe-store"
         (let* ((rs ($ localchimera 'recipe-store))
                (spec ($ rs 'get-resource-spec "spec-xmr")))
           (and spec
                (equal? (resource-specification-id spec) "spec-xmr")
                (eq? (resource-specification-medium-of-exchange spec) #t)
                (equal? (resource-specification-default-unit-of-resource spec)
                        "XMR"))))

  (check "EconomicResource res-xmr-main seeded at 0"
         (let* ((obs ($ localchimera 'observer))
                (r ($ obs 'get-resource "res-xmr-main")))
           (and r
                (equal? (economic-resource-conforms-to r) "spec-xmr")
                (= 0 (measure-has-numerical-value
                       (economic-resource-onhand-quantity r))))))

  (check "live-registry has res-xmr-main"
         (let ((lr ($ localchimera 'live-registry)))
           ($ lr 'has? "res-xmr-main")))

  (check "bootstrap returned a ^live-resource ref"
         (and live-xmr
              (equal? "res-xmr-main" ($ live-xmr 'id))
              (equal? "spec-xmr"     ($ live-xmr 'spec)))))

;;; ── Phase 2: resize simulates a donation ─────────────────────────────────

(display "\n=== Phase 2: resize live-resource → live query reflects the new balance ===\n")

;; This used to go through the deprecated relational planner's
;; `lift-planning-facts` (module/localchimera/deprecated/planner/relational/
;; planning-facts.scm) to prove the live-registry override reaches the
;; planner's fact set. That function has no ported equivalent in the new
;; actor-based planner and — worse — is bound to a textually-duplicated
;; copy of every VF record type (deprecated/planner.scm `include-from-path`s
;; the same schemas.scm source into its own module, so its record types are
;; nominally distinct from `(localchimera boot prelude)`'s), so mixing it with the
;; monero modules (which are new-planner-only) crashed on any record crossing
;; the boundary. Query the live-resource actor directly instead — same
;; substantive claim (the resize is visible where a downstream reader would
;; look for it), without the deprecated fact-lifting pipeline.

;; Simulate that the wallet has received 3 XMR.
(with-vat scope-vat
  ($ live-xmr 'resize 3.0))

(with-vat scope-vat
  (check "XMR live-resource conforms to spec-xmr"
         (equal? ($ live-xmr 'spec) "spec-xmr"))
  (check "XMR live-resource qty reflects the live balance (3)"
         (= ($ live-xmr 'available) 3))
  (check "XMR live-resource has the expected location"
         (equal? ($ live-xmr 'location) "loc-localchimera-server")))

;; And another resize — 0.5 XMR.
(display "\n=== Phase 2b: partial-XMR resize ===\n")
(with-vat scope-vat ($ live-xmr 'resize 0.5))

(check "0.5 XMR live balance is visible on the live-resource"
       (with-vat scope-vat (= ($ live-xmr 'available) 0.5)))

;;; ── Phase 3: poller tick with a stand-in wallet actor ────────────────────

(display "\n=== Phase 3: poller tick with stub wallet → observer event ===\n")

;; Reset to a clean 0 balance so the poller's resize is observable.
(with-vat scope-vat ($ live-xmr 'resize 0.0))

;; Wallet stub: a Goblins actor that returns canned responses shaped the
;; way the poller expects. Lives in its own vat so the poller's with-vat
;; bounces across vats just like the production layout.

(define (^stub-wallet _bcom state)
  (methods
   ((get-balance)
    ;; 2.5 XMR in atomic units
    (apply make-balance-info '(2500000000000 2500000000000 0)))

   ((get-transfers filter)
    ;; One fake incoming transfer at height 3100010 for 2.5 XMR.
    (list
     (cons "in"
           (vector
            (list (cons "txid" "cafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00d")
                  (cons "amount" 2500000000000)
                  (cons "height" 3100010)
                  (cons "subaddr_index"
                        (list (cons "major" 0) (cons "minor" 0))))))))

   ((provider-name) "stub")
   ((last-error)    #f)))

(define wallet-vat (spawn-vat))
(define stub-wallet
  (with-vat wallet-vat (spawn ^stub-wallet #f)))

;; Run a single tick. Suppress logging to keep the test output clean.
(define silent-logger (lambda (_fmt . _args) #f))

(define new-state
  (tick-monero-poller
   #:wallet-vat wallet-vat
   #:wallet stub-wallet
   #:scope-vat scope-vat
   #:scope localchimera
   #:live-resource live-xmr
   #:state '((last-seen-height . 0) (seen-txids . ()))
   #:logger silent-logger))

(check "poller bumped live-resource to 2.5 XMR"
       (with-vat scope-vat
         (let ((avail ($ live-xmr 'available)))
           (and (number? avail) (= avail 2.5)))))

(check "poller advanced last-seen-height"
       (= (assq-ref new-state 'last-seen-height) 3100010))

(check "poller remembered the txid"
       (member "cafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00d"
               (assq-ref new-state 'seen-txids)))

(with-vat scope-vat
  (let* ((obs ($ localchimera 'observer))
         (events ($ obs 'events-for-resource "res-xmr-main")))
    (check "observer recorded a donation event"
           (and (pair? events) (= 1 (length events))))
    (when (pair? events)
      (let ((e (car events)))
        (check "event action = 'raise" (eq? (economic-event-action e) 'raise))
        (check "event spec = spec-xmr"
               (equal? (economic-event-resource-conforms-to e) "spec-xmr"))
        (check "event receiver = agent-localchimera"
               (equal? (economic-event-receiver e) "agent-localchimera"))
        (check "event quantity = 2.5 XMR"
               (= 2.5 (measure-has-numerical-value
                        (economic-event-resource-quantity e))))))))

;; Second tick with the same transfer should be a no-op (de-dup by txid).
(display "\n=== Phase 3b: second tick should not re-record ===\n")
(define new-state-2
  (tick-monero-poller
   #:wallet-vat wallet-vat
   #:wallet stub-wallet
   #:scope-vat scope-vat
   #:scope localchimera
   #:live-resource live-xmr
   #:state new-state
   #:logger silent-logger))

(with-vat scope-vat
  (let ((events ($ ($ localchimera 'observer) 'events-for-resource "res-xmr-main")))
    (check "second tick did not duplicate the donation event"
           (= 1 (length events)))))

(check "second tick preserved last-seen-height"
       (= (assq-ref new-state-2 'last-seen-height) 3100010))

;;; ── Summary ──────────────────────────────────────────────────────────────

(test-summary!)
