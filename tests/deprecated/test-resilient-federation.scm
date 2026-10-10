;;; test-resilient-federation.scm — vow-allsettled + resilient vat-federation
;;;
;;; Validates the best-effort federation pattern: broken peer
;;; proposals become deficits attributed to the dead peer instead of
;;; breaking the whole federation.

(setvbuf (current-output-port) 'line)

(use-modules (playnet test harness)
             (playnet deprecated vat-federation)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (fibers) (fibers conditions)
             (ice-9 atomic)
             (ice-9 format)
             (srfi srfi-1)
             (srfi srfi-11))


(define (await-vow vat vow-thunk)
  (let ((box (make-atomic-box #f))
        (err (make-atomic-box #f))
        (done (make-condition)))
    (with-vat vat
      (catch #t
        (lambda ()
          (on (vow-thunk)
              (lambda (v)
                (atomic-box-set! box v)
                (signal-condition! done))
              #:catch
              (lambda (e)
                (atomic-box-set! err e)
                (signal-condition! done))))
        (lambda args
          (atomic-box-set! err args)
          (signal-condition! done))))
    (wait done)
    (let ((e (atomic-box-ref err)))
      (cond
       ((pair? e) (apply throw e))
       (e (raise-exception e))
       (else (atomic-box-ref box))))))


;;; ── Simple actors for vow-allsettled scenarios ───────────────────────────

(define (^echo-actor bcom)
  "Responds to `(echo val)` with `val`. For simulating successful vows."
  (methods
   ((echo val) val)))

(define (^fail-actor bcom)
  "Responds to `(go)` by raising. For simulating failed vows."
  (methods
   ((go) (error 'fail-actor "simulated failure"))))


;;; ── A leaf that deliberately fails its propose-for ────────────────────────

(define (^broken-leaf bcom scope-id)
  "A leaf whose propose-for raises. Simulates a peer whose vat died
   between receiving the message and responding (for test purposes;
   in production the vat-severance path would produce the same vow
   break via OCapN)."
  (methods
   ((describe) scope-id)
   ((propose-for demand)
    (error 'broken-leaf "simulated peer failure" scope-id))))


;;; ── A leaf that never responds (simulates hung peer) ─────────────────────

(define (^slow-leaf bcom scope-id)
  "A leaf that returns an un-fulfillable promise. Simulates a peer
   whose method invocation is initiated but will never resolve
   (network-partitioned peer, infinite loop, etc.). Exercises the
   deadline path."
  (methods
   ((describe) scope-id)
   ((propose-for demand)
    ;; Return a promise that will never resolve on its own.
    (let-values (((p r) (spawn-promise-and-resolver)))
      p))))


;;; ════════════════════════════════════════════════════════════════════════════

(run-fibers
 (lambda ()

   ;;; ── 1. vow-allsettled: all fulfilled ────────────────────────────────
   (display "\n── 1. vow-allsettled: all fulfilled ──\n")

   (let* ((vat (spawn-vat))
          (echo (with-vat vat (spawn ^echo-actor))))
     (define outcomes
       (await-vow vat
         (lambda ()
           (vow-allsettled (list (<- echo 'echo 'a)
                                 (<- echo 'echo 'b))))))
     (check "two fulfilled → both wrapped as (fulfilled . value)"
            outcomes '((fulfilled . a) (fulfilled . b))))


   ;;; ── 2. vow-allsettled: mixed fulfill + break ────────────────────────
   (display "\n── 2. vow-allsettled: one broken, one fulfilled ──\n")

   (let* ((vat (spawn-vat))
          (echo (with-vat vat (spawn ^echo-actor)))
          (fail (with-vat vat (spawn ^fail-actor))))
     (define outcomes
       (await-vow vat
         (lambda ()
           (vow-allsettled (list (<- echo 'echo 'ok-value)
                                 (<- fail 'go))))))
     (check "length = 2" (length outcomes) 2)
     (check "first is fulfilled"
            (car (car outcomes)) 'fulfilled)
     (check "first's value"
            (cdr (car outcomes)) 'ok-value)
     (check "second is broken"
            (car (cadr outcomes)) 'broken))


   ;;; ── 3. vow-allsettled: empty list ───────────────────────────────────
   (display "\n── 3. vow-allsettled: empty ──\n")

   (let ((vat (spawn-vat)))
     (check "empty input → empty outcomes"
            (await-vow vat (lambda () (vow-allsettled '())))
            '()))


   ;;; ── 4. plan-federate-resilient: all peers alive ─────────────────────
   (display "\n── 4. plan-federate-resilient: happy path ──\n")

   (let* ((vat-A (spawn-vat #:name "pfr-A"))
          (vat-B (spawn-vat #:name "pfr-B"))
          (vat-C (spawn-vat #:name "pfr-C"))
          (a (with-vat vat-A (spawn ^scope-leaf 'commune-A '((apple . 3)))))
          (b (with-vat vat-B (spawn ^scope-leaf 'commune-B '((apple . 5))))))
     (define result
       (await-vow vat-C
         (lambda () (plan-federate-resilient (list a b) '(apple 4)))))
     (check "happy-path resilient: residual 0"
            (assq-ref result 'residual) 0)
     (check "happy-path resilient: coherence 1"
            (assq-ref result 'coherence) 1))


   ;;; ── 5. plan-federate-resilient: one peer dead ───────────────────────
   (display "\n── 5. plan-federate-resilient: one peer dead ──\n")

   (let* ((vat-A (spawn-vat #:name "pfr-deadA"))
          (vat-B (spawn-vat #:name "pfr-deadB"))
          (vat-C (spawn-vat #:name "pfr-deadC"))
          (alive (with-vat vat-A (spawn ^scope-leaf 'alive '((apple . 10)))))
          (dead  (with-vat vat-B (spawn ^broken-leaf 'dead))))
     (define result
       (await-vow vat-C
         (lambda () (plan-federate-resilient (list dead alive) '(apple 5)))))
     ;; The alive peer provides all 5 apples. Federation completes,
     ;; the dead peer's attempted deficit is either absorbed (since the
     ;; alive peer fully satisfies) or surfaces as a no-op. Either way
     ;; the plan doesn't break.
     (check "plan completes despite dead peer (no exception)"
            (pair? result))
     (check "residual 0 — alive peer covers demand"
            (assq-ref result 'residual) 0)
     (check "plan attributes alive peer's contribution"
            (assoc-ref (assq-ref (assq-ref result 'plan) 'alive) 'apple)
            5))


   ;;; ── 6. plan-federate-resilient: all peers dead ──────────────────────
   (display "\n── 6. plan-federate-resilient: all peers dead ──\n")

   (let* ((vat-A (spawn-vat #:name "alldead-A"))
          (vat-B (spawn-vat #:name "alldead-B"))
          (vat-C (spawn-vat #:name "alldead-C"))
          (d1 (with-vat vat-A (spawn ^broken-leaf 'd1)))
          (d2 (with-vat vat-B (spawn ^broken-leaf 'd2))))
     (define result
       (await-vow vat-C
         (lambda () (plan-federate-resilient (list d1 d2) '(apple 7)))))
     (check "all-dead: plan still resolves (no exception)"
            (pair? result))
     (check "all-dead: full residual reported"
            (assq-ref result 'residual) 7)
     (check "all-dead: coherence 0"
            (assq-ref result 'coherence) 0))


   ;;; ── 7. Strict mode still breaks (sanity check) ──────────────────────
   (display "\n── 7. Strict plan-federate still breaks on dead peer ──\n")

   (let* ((vat-A (spawn-vat #:name "strict-A"))
          (vat-B (spawn-vat #:name "strict-B"))
          (vat-C (spawn-vat #:name "strict-C"))
          (alive (with-vat vat-A (spawn ^scope-leaf 'alive '((apple . 10)))))
          (dead  (with-vat vat-B (spawn ^broken-leaf 'dead))))
     (check "strict plan-federate breaks on dead peer"
            (catch #t
              (lambda ()
                (await-vow vat-C
                  (lambda () (plan-federate (list alive dead) '(apple 3))))
                #f)  ; didn't throw — that's a fail
              (lambda _ #t))))


   ;;; ── 8. with-sever-handling: local refs no-op ────────────────────────
   ;;; Local refs don't sever — their vats just get killed and any
   ;;; outstanding <- breaks via normal vow-break path. Verify that
   ;;; passing local refs to with-sever-handling is a safe no-op:
   ;;; body runs, result returned, no exceptions.
   (display "\n── 8. with-sever-handling: local refs are no-op ──\n")

   (let* ((vat (spawn-vat))
          (echo (with-vat vat (spawn ^echo-actor))))
     (define result
       (await-vow vat
         (lambda ()
           (with-sever-handling
             (list echo)  ; local near-ref; no severance possible
             (lambda (ref reason)
               (error 'unexpected-sever "local ref severed??" ref reason))
             (lambda ()
               (<- echo 'echo 'local-ok))))))
     (check "local refs: body runs, result returned"
            result 'local-ok))


   ;;; ── 9. Per-peer deadline: slow peer drops out ───────────────────────
   (display "\n── 9. plan-federate-with-deadline: slow peer dropped ──\n")

   (let* ((vat-fast (spawn-vat #:name "fast-peer"))
          (vat-slow (spawn-vat #:name "slow-peer"))
          (vat-coord (spawn-vat #:name "deadline-coord"))
          (fast (with-vat vat-fast
                  (spawn ^scope-leaf 'fast '((apple . 10)))))
          (slow (with-vat vat-slow (spawn ^slow-leaf 'slow))))
     ;; 0.5 second deadline — fast responds instantly, slow never does.
     (define result
       (await-vow vat-coord
         (lambda ()
           (plan-federate-with-deadline (list slow fast) '(apple 4) 0.5))))
     (check "deadline: plan completes despite hung peer"
            (pair? result))
     (check "deadline: fast peer covers demand (residual 0)"
            (assq-ref result 'residual) 0)
     (check "deadline: fast peer contributed 4"
            (assoc-ref (assq-ref (assq-ref result 'plan) 'fast) 'apple) 4))


   ;;; ── 10. All peers slow: deadline yields full residual ──────────────
   (display "\n── 10. All peers slow — all deadlines hit ──\n")

   (let* ((vat-1 (spawn-vat #:name "slow-1"))
          (vat-2 (spawn-vat #:name "slow-2"))
          (vat-coord (spawn-vat #:name "all-slow-coord"))
          (s1 (with-vat vat-1 (spawn ^slow-leaf 's1)))
          (s2 (with-vat vat-2 (spawn ^slow-leaf 's2))))
     (define result
       (await-vow vat-coord
         (lambda ()
           (plan-federate-with-deadline (list s1 s2) '(apple 5) 0.3))))
     (check "all-slow: plan resolves (doesn't hang forever)"
            (pair? result))
     (check "all-slow: residual is full demand"
            (assq-ref result 'residual) 5)
     (check "all-slow: coherence 0"
            (assq-ref result 'coherence) 0))


   (format #t "~%=== Results: ~a passed, ~a failed ===~%" pass-count fail-count)
   (primitive-exit (if (zero? fail-count) 0 1))))
