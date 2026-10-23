;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/fleet/test-reconciler-persistence.scm
;;;
;;; Round-trip test for ^fleet-reconciler's #:portrait / #:restore wired
;;; through spawn-persistent-vat + a syrup store. Proves the actor's
;;; serialization machinery — which had been dormant — actually works.
;;;
;;; Plan:
;;;   1. Fresh syrup file path. Spawn the reconciler via
;;;      spawn-persistent-vat with fleet-reconciler-env. Mutate its
;;;      in-flight hashmap (we use a synthetic desired-fleet to drive
;;;      one reconcile tick that lands a host in 'invoice-pending or so).
;;;   2. Wait for the auto-snapshot to flush (vat mutation triggers it).
;;;   3. Re-spawn from the SAME syrup file with the SAME env. Inspect
;;;      the in-flight hashmap — should reflect the mutation.
;;;
;;; This is the first end-to-end exercise of the actor's #:portrait /
;;; #:restore in the codebase.
;;;
;;; Run:
;;;   guile -L module -L tests tests/fleet/test-reconciler-persistence.scm

(use-modules (goblins)
             (goblins vat)
             (goblins utils hashmap)
             (goblins persistence-store syrup)
             (ice-9 format)
             (srfi srfi-1)
             (playnet test harness)
             (playnet utils hashmap)   ; hashmap-keys
             (playnet fleet records)
             (playnet fleet sporestack) ; make-sporestack-creds, default-endpoint
             (playnet fleet reconciler))

;;; ── Test data dir ────────────────────────────────────────────────────────

(define test-dir
  (let ((d (string-append "/tmp/playnet-recon-persist-test-"
                          (number->string (getpid)))))
    (when (file-exists? d)
      (system* "rm" "-rf" d))
    (mkdir d)
    d))

(define desired-path (string-append test-dir "/desired-fleet.scm"))
(define hosts-path   (string-append test-dir "/hosts.scm"))
(define syrup-path   (string-append test-dir "/fleet-reconciler.syrup"))

;;; ── Synthetic desired-fleet ──────────────────────────────────────────────

(call-with-output-file desired-path
  (lambda (port)
    (display ";; synthetic for persistence test\n" port)
    (display "(use-modules (playnet fleet records))\n" port)
    (display "(list\n" port)
    (display "  (desired-host\n" port)
    (display "   #:name \"persist-test-1\"\n" port)
    (display "   #:flavor \"vps-1vcpu-1gb\"\n" port)
    (display "   #:operating-system \"debian-12\"\n" port)
    (display "   #:provider \"sporestack\"\n" port)
    (display "   #:region \"nyc1\"\n" port)
    (display "   #:days 30\n" port)
    (display "   #:billing-cycle \"monthly\"\n" port)
    (display "   #:hostname \"persist-test-1\"\n" port)
    (display "   #:role 'dev\n" port)
    (display "   #:estimated-monthly-usd 5\n" port)
    (display "   #:bootstrap-mode 'manual\n" port)
    (display "   #:provider-params '((\"backend\" . \"digitalocean\"))))\n" port)))

;;; ── Stub provider that synchronously creates an invoice ─────────────────
;;; Returns enough to land the in-flight entry in 'invoice-pending.

(define stub-provider
  `((create-invoice
     . ,(lambda (host)
          (values "stub-invoice-id"
                  "monero:STUB_ADDRESS?tx_amount=0.001"
                  'xmr
                  1000000000000)))   ; atomic units (irrelevant — never paid)
    (poll-payment . ,(lambda _ 'pending))
    (launch       . ,(lambda _ #f))
    (poll-server  . ,(lambda _ (values #f #f)))
    (delete-server . ,(lambda _ #t))
    (list-servers  . ,(lambda _ '()))))

(define stub-providers `(("sporestack" . ,stub-provider)))

;;; ── Phase 1: spawn fresh, mutate, snapshot ───────────────────────────────

(format #t "── Phase 1: fresh spawn + mutate ──~%")

(define-values (vat1 reconciler1)
  (spawn-persistent-vat
    fleet-reconciler-env
    (lambda ()
      (spawn ^fleet-reconciler
             #f stub-providers #f
             "ssh-ed25519 STUB"
             desired-path
             hosts-path
             (hashmap)
             0
             0                       ; min-reconcile-interval=0 for tests
             #f))                    ; token-rotation
    (make-syrup-store syrup-path)
    #:name "fleet-reconciler-test-1"))

;; Drive one reconcile tick. The host enters 'invoice-pending because
;; create-invoice succeeds but poll-payment returns 'pending so the
;; entry stays in the hashmap.
(check "fresh spawn returned a non-#f actor ref" (and reconciler1 #t))

(define result1
  (with-vat vat1 ($ reconciler1 'reconcile)))
(check "first reconcile returned an alist" (list? result1))

(define in-flight-1
  (with-vat vat1 ($ reconciler1 'in-flight-entries)))
(define names-1 (hashmap-keys in-flight-1))
(check "in-flight has the synthetic host"
       (member "persist-test-1" names-1))

(format #t "  in-flight names: ~a~%" names-1)

;;; ── Phase 2: drop refs, force GC, re-spawn ───────────────────────────────

(format #t "~%── Phase 2: drop + re-spawn from same syrup ──~%")

(set! reconciler1 #f)
(set! vat1 #f)
(set! in-flight-1 #f)
(gc) (gc)

(check "syrup file exists on disk" (file-exists? syrup-path))
(format #t "  syrup size: ~a bytes~%"
        (stat:size (stat syrup-path)))

(define-values (vat2 reconciler2)
  (spawn-persistent-vat
    fleet-reconciler-env
    (lambda ()
      ;; If this runs, we lost the snapshot — flag it.
      (format #t "  WARN: spawn-fn ran on second spawn (should have restored)~%")
      (spawn ^fleet-reconciler
             #f '() #f "" desired-path hosts-path (hashmap) 0 0 #f))
    (make-syrup-store syrup-path)
    #:name "fleet-reconciler-test-2"))

(check "restore produced a non-#f actor ref" (and reconciler2 #t))

(define in-flight-2
  (with-vat vat2 ($ reconciler2 'in-flight-entries)))
(define names-2 (hashmap-keys in-flight-2))

(format #t "  restored in-flight names: ~a~%" names-2)

(check "restored hashmap contains the same host"
       (member "persist-test-1" names-2))

(check "restored in-flight matches phase-1 length" (= 1 (length names-2)))

;; The provisioning key rests in the portrait: the restored actor holds the
;; one it was first spawned with. Boot hands it the key now on disk, and the
;; hosts it starts from then on carry that key.
(call-with-output-file desired-path
  (lambda (port)
    (display "(use-modules (playnet fleet records))\n(list\n" port)
    (for-each
     (lambda (name)
       (format port " (desired-host #:name ~s #:provider \"sporestack\" #:flavor \"vps-1vcpu-1gb\"
   #:provider-params '((\"backend\" . \"digitalocean\")))\n" name))
     '("persist-test-1" "persist-test-2"))
    (display ")\n" port)))

(with-vat vat2
  ($ reconciler2 'rewire #f stub-providers #f #f)
  ($ reconciler2 'set-ssh-key "ssh-ed25519 ROTATED"))
(with-vat vat2 ($ reconciler2 'reconcile))

(let ((entries (with-vat vat2 ($ reconciler2 'in-flight-entries))))
  (check "a host started after set-ssh-key carries the new key"
         (equal? "ssh-ed25519 ROTATED"
                 ((@@ (playnet fleet reconciler) in-flight-entry-ssh-key-pub)
                  (hashmap-ref entries "persist-test-2"))))
  (check "the host already in flight keeps the key it was started with"
         (equal? "ssh-ed25519 STUB"
                 ((@@ (playnet fleet reconciler) in-flight-entry-ssh-key-pub)
                  (hashmap-ref entries "persist-test-1")))))

;;; ── Phase 3: token-rotation persistence ──────────────────────────────────
;;;
;;; Hand-craft a token-rotation alist in the actor's portrait by way of
;;; direct method calls. We can't actually pay XMR in a unit test, so we
;;; install the rotation via a synthetic method path: spawn a NEW actor
;;; pre-loaded with token-rotation set, snapshot, drop, re-load, and
;;; verify the token-prefix is preserved in token-rotation-status.

(format #t "~%── Phase 3: token-rotation round-trip ──~%")

(define syrup-path-3
  (string-append test-dir "/fleet-reconciler-rot.syrup"))

(define synthetic-token "ss_t_persistence_test_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

(define-values (vat3 reconciler3)
  (spawn-persistent-vat
    fleet-reconciler-env
    (lambda ()
      ;; Hand-construct an actor with a non-#f token-rotation field.
      (let ((creds (make-sporestack-creds
                    sporestack-default-endpoint synthetic-token)))
        (spawn ^fleet-reconciler
               #f '() #f "" desired-path hosts-path
               (hashmap) 0 0
               `((token . ,synthetic-token)
                 (creds . ,creds)
                 (ticks . 5)
                 (started-at . 1700000000)))))
    (make-syrup-store syrup-path-3)
    #:name "fleet-reconciler-rot-1"))

(define status-3
  (with-vat vat3 ($ reconciler3 'token-rotation-status)))
(format #t "  pre-snapshot status: ~a~%" status-3)
(check "rotation status is non-#f after fresh seed" (and status-3 #t))
(check "rotation token-prefix matches synthetic input"
       (equal? "ss_t_persist" (assq-ref status-3 'token-prefix)))

(set! reconciler3 #f)
(set! vat3 #f)
(gc) (gc)

(define-values (vat4 reconciler4)
  (spawn-persistent-vat
    fleet-reconciler-env
    (lambda ()
      (format #t "  WARN: spawn-fn ran (rotation snapshot lost)~%")
      (spawn ^fleet-reconciler
             #f '() #f "" desired-path hosts-path (hashmap) 0 0 #f))
    (make-syrup-store syrup-path-3)
    #:name "fleet-reconciler-rot-2"))

(define status-4
  (with-vat vat4 ($ reconciler4 'token-rotation-status)))
(format #t "  restored status:    ~a~%" status-4)
(check "rotation survives restart"
       (and status-4
            (equal? "ss_t_persist" (assq-ref status-4 'token-prefix))
            (equal? 5 (assq-ref status-4 'ticks))))

;;; ── Cleanup ──────────────────────────────────────────────────────────────

(system* "rm" "-rf" test-dir)

(test-summary!)
