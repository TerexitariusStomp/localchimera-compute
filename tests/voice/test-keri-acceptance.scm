;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-keri-acceptance.scm — the full KERI-gated VF acceptance chain.
;;;
;;; Demonstrates:
;;;   1. demand-bridge populates `proposed-to` from an acceptors list,
;;;      so the planner enforces a whitelist at acceptance time.
;;;   2. accept-proposal rejects a caller whose verify-with predicate
;;;      returns #f (unauthorized acceptor).
;;;   3. accept-proposal succeeds when the acceptor is whitelisted AND
;;;      verify-with approves — and on success, fires the on-agreement
;;;      callback which issues an agreement ACDC into ^acdc-store.
;;;   4. on-commitment callbacks fire during fold-promotions (existing
;;;      behavior).
;;;   5. on-event fires when record-event is called (new observer hook),
;;;      suitable for emitting work-event ACDCs that reference the
;;;      agreement via `realization-of`.

(use-modules ((localchimera utils units) #:select (%count-unit)))
(use-modules (localchimera test harness)
             (localchimera scope root) (localchimera vf schemas)
             (localchimera credentials commitments) (localchimera keri acdc) (localchimera keri acdc) (localchimera keri acdc-store)
             (localchimera scope demand-registry)
             (localchimera voice demand-bridge)
             (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (srfi srfi-1))


;; Minimal stand-in for a closed ^expression. promote-demands
;; only calls ($ expr 'result), so this is all we need.
(define-actor (^fake-expr bcom demand-id)
  (methods
    ((result)
     `((ranked . ((,demand-id . 1.0)))))))


(define vat (spawn-vat))

(with-vat vat

  (define scope (spawn-scope-root "keri-scope"))
  (define ps    ($ scope 'plan-store))
  (define dreg  ($ scope 'demand-registry))
  (define obs   ($ scope 'observer))
  (define acdc  (spawn-acdc-store))

  ;; ── Wire the callbacks (what the governance gateway would do). ──

  (define agreement-emissions '())
  (define event-emissions '())

  ($ ps 'set-on-agreement
     (lambda (agr proposal result)
       (let* ((acceptor-aid (assq-ref result 'accepting-agent-id))
              (proposer-aid (car (proposal-in-scope-of proposal)))
              (agr-id (agreement-id agr))
              (proposal-id (assq-ref result 'proposal-id))
              (primary (assq-ref result 'primary-commitment-ids))
              (recip   (assq-ref result 'reciprocal-commitment-ids))
              (counterparty (assq-ref result 'counterparty)))
         (let ((said
                ($ acdc 'issue
                   (make-agreement-credential
                     #:acceptor-aid acceptor-aid
                     #:proposer-aid proposer-aid
                     #:agreement-id agr-id
                     #:proposal-id proposal-id
                     #:primary-commitment-ids primary
                     #:reciprocal-commitment-ids recip
                     #:counterparty-provider (assq-ref counterparty 'provider)
                     #:counterparty-receiver (assq-ref counterparty 'receiver)
                     #:accepted-at (agreement-created agr)))))
           (set! agreement-emissions (cons said agreement-emissions))))))

  ($ obs 'set-on-event
     (lambda (event affected . _)
       (set! event-emissions (cons (economic-event-id event) event-emissions))))


  ;; ── A citizen voices a demand.  Scope promotes with an acceptor
  ;;    whitelist — only "scope-steward" may accept. ──

  (define did ($ dreg 'propose "alice" "bread order"
                  '((resource-conforms-to . "spec-bread")
                    (quantity-value       . 20)
                    (quantity-unit        . "each"))))

  ;; Simulate an already-closed expression by fabricating a ranked
  ;; result; open-expression needs a full citizen registry and is
  ;; exercised in other tests.
  (define fake-expr (spawn ^fake-expr did))

  (promote-demands scope fake-expr 0.5
                   #:acceptors '("scope-steward"))

  (let* ((proposal-id (string-append did "-proposal"))
         (prop ($ ps 'get-proposal proposal-id)))
    (check-pred "promoted proposal has proposed-to = [steward]"
                (equal? '("scope-steward") (proposal-proposed-to prop))))


  ;; ── Prepare: populate the published intent's receiver slot so
  ;;    promotion has both provider and receiver at accept time. The
  ;;    demand-bridge left provider=#f, receiver=scope-name; accept's
  ;;    counterparty fills the provider. ──

  (let* ((proposal-id (string-append did "-proposal"))
         (accepting-counterparty `((provider . "bakery-bob")
                                    (receiver . "keri-scope"))))

    ;; Case 1: verify-with rejects the caller.
    (check-pred "verify-with returning #f blocks acceptance"
                (catch #t
                  (lambda ()
                    ($ ps 'accept-proposal proposal-id accepting-counterparty
                       `((accepting-agent-id . "scope-steward")
                         (verify-with . ,(lambda (_a _p) #f))))
                    #f)
                  (lambda _ #t)))

    ;; Case 2: accepting-agent-id not in the whitelist.
    (check-pred "unknown accepting-agent-id rejected by proposed-to"
                (catch #t
                  (lambda ()
                    ($ ps 'accept-proposal proposal-id accepting-counterparty
                       `((accepting-agent-id . "random-stranger")
                         (verify-with . ,(lambda (_a _p) #t))))
                    #f)
                  (lambda _ #t)))

    ;; Case 3: both gates pass → acceptance proceeds.
    (define accept-result
      ($ ps 'accept-proposal proposal-id accepting-counterparty
         `((accepting-agent-id . "scope-steward")
           (verify-with . ,(lambda (aid pid)
                             (and (equal? "scope-steward" aid)
                                  (equal? proposal-id pid)))))))

    (check-pred "acceptance returned agreement-id"
                (string? (assq-ref accept-result 'agreement-id)))
    (check-pred "one primary commitment"
                (= 1 (length (assq-ref accept-result 'primary-commitment-ids))))


    ;; ── on-agreement fired → agreement ACDC was issued. ──

    (check-pred "one agreement ACDC emitted"
                (= 1 (length agreement-emissions)))

    (let ((agr-creds ($ acdc 'by-schema *schema-localchimera-agreement*)))
      (check-pred "acdc-store holds the agreement credential"
                  (= 1 (length agr-creds)))
      (let ((c (car agr-creds)))
        (check-pred "credential issuer = acceptor aid"
                    (equal? "scope-steward" (cred-issuer c)))
        (check-pred "credential proposal-id claim matches"
                    (equal? proposal-id
                            (assq-ref (cred-claims c) 'proposal-id)))
        (check-pred "credential primary-commitment-ids non-empty"
                    (pair? (assq-ref (cred-claims c) 'primary-commitment-ids)))))


    ;; ── on-event fires when an event is recorded (work-event ACDC
    ;;    emission would happen here in production wiring). ──

    (let ((primary-cid (car (assq-ref accept-result 'primary-commitment-ids))))
      ($ obs 'record-event
         (make-economic-event
           #:id "ev-bread-1"                                ;; id
           #:action 'produce                                    ;; action
                                          ;; input-of
                                          ;; output-of
                                          ;; resource-inventoried-as
                                          ;; to-resource-inventoried-as
           #:resource-conforms-to "spec-bread"                                ;; resource-conforms-to
           #:resource-classified-as '()                                         ;; resource-classified-as
           #:provider "bakery-bob"                                ;; provider
           #:receiver "keri-scope"                                ;; receiver
           #:resource-quantity (make-measure 20 %count-unit)                    ;; resource-quantity
                                          ;; effort-quantity
                                          ;; has-beginning
                                          ;; has-end
           #:has-point-in-time (number->string (current-time))             ;; has-point-in-time
           #:created (number->string (current-time))             ;; created
                                          ;; at-location
                                          ;; to-location
                                          ;; state
           #:fulfills primary-cid                                 ;; fulfills
                                          ;; satisfies
                                          ;; corrects
           #:realization-of (assq-ref accept-result 'agreement-id)      ;; realization-of
                                          ;; settles
                                          ;; note
           #:in-scope-of '("keri-scope")                             ;; in-scope-of
)))                                          ;; previous-event

    (check-pred "on-event fired for the recorded event"
                (equal? '("ev-bread-1") event-emissions))))


;; ────────────────────────────────────────────────────────────────────

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
