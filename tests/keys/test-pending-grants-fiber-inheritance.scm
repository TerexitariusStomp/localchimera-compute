;;; tests/keys/test-pending-grants-fiber-inheritance.scm
;;;
;;; Verifies the deployment-time uncertainty I flagged: when the
;;; gateway sets `(current-pending-grants <ref>)` at boot, is that
;;; value visible later from:
;;;   - a child fiber
;;;   - a vat spawned later (via `with-vat`)
;;;   - a vat spawned EARLIER (the case that killed make-parameter)
;;;   - inside an actor method called via `$` or `<-`
;;;
;;; Without this, `scope-deliver-grant!` would silently bypass the
;;; queue and drop deferred grants on the floor — which is the
;;; symptom we'd see only at production deploy, hidden by the
;;; catch-and-log path.
;;;
;;; History: current-pending-grants WAS a make-parameter; vats inherit
;;; the dynamic state of their spawn moment, so any vat spawned before
;;; the boot-time set read #f forever. It is now a boot cell
;;; ((playnet utils boot-cell)) — one shared location, spawn-order
;;; immune. This suite pins that.
;;;
;;; Run: guile -L module -L tests tests/keys/test-pending-grants-fiber-inheritance.scm

(use-modules (playnet test harness)
             (playnet keys pending-grants)
             ((playnet keys exchange) #:select (current-pending-grants))
             (goblins)
             (ice-9 threads)
             (fibers))

(define %vat (spawn-vat #:name "shared"))
(define %q   (with-vat %vat (spawn-pending-grants)))

;; ── A vat spawned BEFORE the set — the parameter killer ───────────
;; Spawn the reader vat FIRST, set the cell after; the read must see
;; the value. (As a make-parameter this returned #f: vats inherit the
;; dynamic state of their spawn moment.)

(define %early-vat (spawn-vat #:name "early"))
(define %early-reader
  (with-vat %early-vat
    (spawn (lambda (_b) (lambda _ (current-pending-grants))))))

;; ── Set the cell at "boot" level ───────────────────────────────────

(current-pending-grants %q)

(check "cell readable from setting thread"
       (eq? %q (current-pending-grants)))

(check "vat spawned BEFORE the set sees the value"
       (eq? %q (with-vat %early-vat ($ %early-reader 'read))))

;; ── Child thread sees it (one shared location — no per-thread
;;     dynamic state involved).

(define %child-result
  (call-with-new-thread
   (lambda () (current-pending-grants))))

(check "new thread sees the shared cell"
       (eq? %q (join-thread %child-result)))

;; ── Directly inside a with-vat thunk (the old parameter gap) ──────

(check "cell visible directly inside with-vat"
       (eq? %q (with-vat %vat (current-pending-grants))))

;; ── Enqueue from inside an actor method (the real-world path) ─────

(define %recorder-vat (spawn-vat #:name "recorder"))
(define %recorder
  (with-vat %recorder-vat
    (spawn (lambda (bcom)
             (lambda _
               ;; Simulate scope-deliver-grant!'s pattern: read the
               ;; parameter, enqueue if bound.
               (let ((q (current-pending-grants)))
                 (when q
                   (<- q 'enqueue
                       (make-pending-grant
                        'test-ok
                        '((cred-said . "ECred-from-vat")
                          (holder    . "EHolder-from-vat")))))))))))

(with-vat %recorder-vat ($ %recorder 'fire))

;; The enqueue is async (<- returns a vow). Give Goblins one turn to
;; deliver the message by doing a synchronous $ on the queue.
(check "enqueue from inside a vat reached the queue"
       (let loop ((tries 0))
         (cond
          ((>= tries 50) #f)
          ((= 1 (with-vat %vat ($ %q 'count))) #t)
          (else (loop (1+ tries))))))

;; ── spawn-fiber inheritance (gateway's drain-fiber pattern) ───────
;;
;; The gateway uses spawn-fiber inside run-fibers to run the periodic
;; drain. If parameters set at boot don't propagate into spawn-fiber
;; thunks, the drain fiber would fail silently. Probe explicitly via
;; a fiber that writes its observation back through a channel.

(use-modules ((fibers channels) #:select (make-channel put-message get-message)))

(define %fiber-result
  (run-fibers
   (lambda ()
     (define ch (make-channel))
     (spawn-fiber
      (lambda ()
        (put-message ch (current-pending-grants))))
     (get-message ch))
   #:drain? #t))

(check "spawn-fiber sees the shared cell"
       (eq? %q %fiber-result))

;; ── set/restore (boot cells trade parameterize for simplicity) ─────

(define %temp-q (with-vat %vat (spawn-pending-grants)))

(let ((saved (current-pending-grants)))
  (current-pending-grants %temp-q)
  (check "explicit set overrides"
         (eq? %temp-q (current-pending-grants)))
  (current-pending-grants saved))

(check "explicit restore — original value back"
       (eq? %q (current-pending-grants)))

(test-summary!)
