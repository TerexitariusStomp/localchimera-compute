;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/fleet/test-auto-rotor.scm — 'auto provider routing through
;;; the reconciler
;;;
;;; The rotor function (next-healthy-provider-name!) is unit-tested in
;;; test-rotor.scm. The end-to-end reconciler test pins each host to a
;;; specific provider. Neither exercises the actor's `provider-for`
;;; integration with the sentinel "auto" plus mark-providers-unhealthy.
;;;
;;; This test:
;;;   1. Builds a desired-fleet with a host whose provider = "auto".
;;;   2. Spawns the reconciler with two stub providers (sporestack, vpsbg).
;;;   3. Runs `(reconcile)`; asserts exactly one of the providers'
;;;      create-invoice was called (whichever the rotor picked).
;;;   4. Calls (mark-providers-unhealthy '("sporestack")) — runs
;;;      reconcile on a fresh actor with the same registry; asserts the
;;;      vpsbg provider was the one called.
;;;
;;; Run:
;;;   guile -L module -L tests tests/fleet/test-auto-rotor.scm

(use-modules (goblins)
             (goblins vat)
             (goblins utils hashmap)
             (ice-9 format)
             (srfi srfi-1)
             (playnet test harness)
             (playnet utils hashmap)
             (playnet fleet records)
             (playnet fleet reconciler))

;;; ── Recording stub providers ─────────────────────────────────────────────

(define sporestack-create-calls 0)
(define vpsbg-create-calls 0)

(define (make-stub-provider tag bump-fn)
  ;; Implements the protocol; create-invoice records itself, the rest
  ;; are no-ops sufficient to leave the host in 'invoice-pending.
  `((create-invoice
     . ,(lambda (host)
          (bump-fn)
          (values (string-append "stub-inv-" tag)
                  (string-append "monero:STUB_ADDR_" tag "?tx_amount=0.001")
                  'xmr
                  1000000000)))
    (poll-payment . ,(lambda _ 'pending))
    (launch       . ,(lambda _ #f))
    (poll-server  . ,(lambda _ (values #f #f)))
    (delete-server . ,(lambda _ #t))
    (list-servers  . ,(lambda _ '()))))

(define stub-sporestack
  (make-stub-provider "sporestack"
                      (lambda () (set! sporestack-create-calls
                                       (+ 1 sporestack-create-calls)))))

(define stub-vpsbg
  (make-stub-provider "vpsbg"
                      (lambda () (set! vpsbg-create-calls
                                       (+ 1 vpsbg-create-calls)))))

(define stub-providers
  `(("sporestack" . ,stub-sporestack)
    ("vpsbg"      . ,stub-vpsbg)))

;;; ── Synthetic desired-fleet with provider="auto" ─────────────────────────

(define test-dir
  (let ((d (string-append "/tmp/auto-rotor-" (number->string (getpid)))))
    (when (file-exists? d) (system* "rm" "-rf" d))
    (mkdir d)
    d))

(define desired-path (string-append test-dir "/desired-fleet.scm"))
(define hosts-path   (string-append test-dir "/hosts.scm"))

(call-with-output-file desired-path
  (lambda (port)
    (display "(use-modules (playnet fleet records))\n" port)
    (display "(list\n" port)
    (display "  (desired-host\n" port)
    (display "   #:name \"auto-host-1\"\n" port)
    (display "   #:flavor \"vps-1vcpu-1gb\"\n" port)
    (display "   #:operating-system \"debian-12\"\n" port)
    (display "   #:provider \"auto\"\n" port)
    (display "   #:region \"any\"\n" port)
    (display "   #:days 30\n" port)
    (display "   #:billing-cycle \"monthly\"\n" port)
    (display "   #:hostname \"auto-host-1\"\n" port)
    (display "   #:role 'dev\n" port)
    (display "   #:estimated-monthly-usd 5\n" port)
    (display "   #:bootstrap-mode 'manual\n" port)
    (display "   #:provider-params '()))\n" port)))

;;; ── Test harness: spawn fresh actor, run reconcile, return totals ────────

(define vat (spawn-vat #:name "auto-rotor-test"))

(define (spawn-recon)
  (with-vat vat
    (spawn ^fleet-reconciler
           #f                  ; policy not needed — host stays in
                               ; 'invoice-pending after one tick (poll-
                               ; payment returns 'pending) so policy
                               ; never gets called.
           stub-providers
           #f
           ""
           desired-path
           hosts-path
           (hashmap)
           0
           0                   ; min-reconcile-interval=0
           #f)))               ; idle token-rotation

;;; ── Phase 1: both healthy → rotor picks one ──────────────────────────────

(format #t "── Phase 1: both providers healthy ──~%")

(set! sporestack-create-calls 0)
(set! vpsbg-create-calls 0)

(define rec1 (spawn-recon))
(with-vat vat ($ rec1 'reconcile))

(format #t "  sporestack: ~a, vpsbg: ~a~%"
        sporestack-create-calls vpsbg-create-calls)

(check "exactly one provider was invoked"
       (= 1 (+ sporestack-create-calls vpsbg-create-calls)))

;;; ── Phase 2: sporestack marked unhealthy → vpsbg gets it ─────────────────

(format #t "~%── Phase 2: sporestack unhealthy ──~%")

(set! sporestack-create-calls 0)
(set! vpsbg-create-calls 0)

(define rec2 (spawn-recon))
(with-vat vat ($ rec2 'mark-providers-unhealthy '("sporestack")))
(with-vat vat ($ rec2 'reconcile))

(format #t "  sporestack: ~a, vpsbg: ~a~%"
        sporestack-create-calls vpsbg-create-calls)

(check "sporestack NOT called when unhealthy"
       (zero? sporestack-create-calls))
(check "vpsbg picked up the auto host" (= 1 vpsbg-create-calls))

;;; ── Phase 3: vpsbg unhealthy too → fallback to first registered ──────────

(format #t "~%── Phase 3: both unhealthy → fallback ──~%")

(set! sporestack-create-calls 0)
(set! vpsbg-create-calls 0)

(define rec3 (spawn-recon))
(with-vat vat ($ rec3 'mark-providers-unhealthy '("sporestack" "vpsbg")))
(with-vat vat ($ rec3 'reconcile))

(format #t "  sporestack: ~a, vpsbg: ~a~%"
        sporestack-create-calls vpsbg-create-calls)

(check "fallback: still calls one of the registered providers"
       (= 1 (+ sporestack-create-calls vpsbg-create-calls)))

;; Restore state for any subsequent suite.
(with-vat vat ($ rec3 'mark-providers-unhealthy '()))

;;; ── Cleanup ──────────────────────────────────────────────────────────────

(system* "rm" "-rf" test-dir)

(test-summary!)
