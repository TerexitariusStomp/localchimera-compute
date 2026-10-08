;;; test-async-federation.scm — vow-based cross-vat federation queries
;;;
;;; Two scope-roots in two separate vats; query global-* aggregates via
;;; vows; build a federation ballot snapshot asynchronously across vats.
;;;
;;; Cross-vat awaiting: we use fibers conditions for synchronization.
;;; signal-condition! is non-blocking — the actor turn completes cleanly.

(setvbuf (current-output-port) 'line)

(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (srfi srfi-11))
(use-modules (playnet org endorsement))
(use-modules (playnet governance async) (playnet governance ballot) (playnet governance delegation-map) (playnet governance voice-signer))
(use-modules (goblins) (goblins utils hashmap)
             (goblins vat) (srfi srfi-1)
             (fibers)
             (fibers conditions)
             (ice-9 atomic))


(define (synthetic-aid id) (string-append "E_" id))

(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.001)))
    (< (abs (- a b)) tol)))


;; ── await-vow ────────────────────────────────────────────────────────────

(define (await-vow vat vow-thunk)
  (let ((box  (make-atomic-box #f))
        (err  (make-atomic-box #f))
        (done (make-condition)))
    (with-vat vat
      (on (vow-thunk)
          (lambda (v)
            (atomic-box-set! box v)
            (signal-condition! done)
            'done)
          #:catch
          (lambda (e)
            (atomic-box-set! err e)
            (signal-condition! done)
            'done)))
    (wait done)
    (let ((e (atomic-box-ref err)))
      (if e (raise-exception e)
          (atomic-box-ref box)))))


;;; ════════════════════════════════════════════════════════════════════════════

(run-fibers
 (lambda ()

   ;;; ── 1. Single-vat async sanity ───────────────────────────────────────
   (display "\n── 1. Single-vat async sanity ──\n")

   (let* ((vat (spawn-vat #:name "single"))
          (scope (with-vat vat
                   (let ((s (spawn-scope-root "Watershed")))
                     ($ ($ s 'account-store) 'add-contribution "alice" 30)
                     ($ ($ s 'account-store) 'add-contribution "bob" 70)
                     s))))

     (let ((result (await-vow vat
                              (lambda () (global-total-social-svc-async (list scope))))))
       (check-pred "async total-social-svc = 100"
                   (= 100 result)))

     (let ((result (await-vow vat
                              (lambda () (voice-share-async "alice" (list scope))))))
       (check-pred "async voice-share alice = 30/100"
                   (= 30/100 result))))


   ;;; ── 2. Cross-vat aggregation ─────────────────────────────────────────
   (display "\n── 2. Cross-vat aggregation ──\n")

   (let* ((vat-A (spawn-vat #:name "vat-A"))
          (vat-B (spawn-vat #:name "vat-B"))
          (vat-fed (spawn-vat #:name "vat-fed"))
          (scope-A (with-vat vat-A
                     (let ((s (spawn-scope-root "Watershed")))
                       ($ ($ s 'account-store) 'add-contribution "alice" 30)
                       s)))
          (scope-B (with-vat vat-B
                     (let ((s (spawn-scope-root "Bakery")))
                       ($ ($ s 'account-store) 'add-contribution "alice" 20)
                       ($ ($ s 'account-store) 'add-contribution "bob" 50)
                       s)))
          (scope-roots (list scope-A scope-B)))

     (let ((result (await-vow vat-fed
                              (lambda () (global-total-social-svc-async scope-roots)))))
       (check-pred "cross-vat total-social-svc = 100"
                   (= 100 result)))

     (let ((result (await-vow vat-fed
                              (lambda () (global-citizen-gross-async "alice" scope-roots)))))
       (check-pred "cross-vat alice gross = 50"
                   (= 50 result)))

     (let ((result (await-vow vat-fed
                              (lambda () (voice-share-async "alice" scope-roots)))))
       (check-pred "cross-vat voice-share alice = 1/2"
                   (= 1/2 result)))

     (let ((result (await-vow vat-fed
                              (lambda () (voice-share-async "bob" scope-roots)))))
       (check-pred "cross-vat voice-share bob = 1/2"
                   (= 1/2 result)))

     (let ((result (await-vow vat-fed
                              (lambda () (global-embodied-labor-in-pool-async scope-roots)))))
       (check-pred "cross-vat embodied-labor-in-pool = 0"
                   (= 0 result))))


   ;;; ── 3. Cross-vat ballot: snapshot + cast + tally ─────────────────────
   (display "\n── 3. Cross-vat ballot ──\n")

   ;; Setup: vat-A has alice (30h labor), vat-B has bob (50h labor).
   ;; Delegation maps live in their home vats (far refs from vat-fed).
   ;; Citizen-voice actors + ballot live in vat-fed (near refs for cast).

   (let* ((vat-A (spawn-vat #:name "ballot-vat-A"))
          (vat-B (spawn-vat #:name "ballot-vat-B"))
          (vat-fed (spawn-vat #:name "ballot-vat-fed"))

          ;; Scope-roots with labor contributions
          (scope-A (with-vat vat-A
                     (let ((s (spawn-scope-root "Watershed")))
                       ($ ($ s 'account-store) 'ensure-account "alice")
                       ($ ($ s 'account-store) 'add-contribution "alice" 30)
                       s)))
          (scope-B (with-vat vat-B
                     (let ((s (spawn-scope-root "Bakery")))
                       ($ ($ s 'account-store) 'ensure-account "bob")
                       ($ ($ s 'account-store) 'add-contribution "bob" 50)
                       s)))

          ;; Delegation maps in their home vats (far refs from vat-fed)
          (dm-alice (with-vat vat-A (spawn-delegation-map "alice")))
          (dm-bob   (with-vat vat-B (spawn-delegation-map "bob")))

          ;; Alice delegates 100% to bob (federation-wide)
          (_ (with-vat vat-A ($ dm-alice 'delegate "bob" 1)))

          ;; Citizen-voice actors in vat-fed (near refs needed for cast)
          (scope-roots (list scope-A scope-B)))

     ;; Phase 1: spawn citizen-voice actors + registry in vat-fed
     (define-values (voice-alice sealed?-alice voice-bob sealed?-bob
                     citizen-registry citizens-for-ballot)
       (with-vat vat-fed
         (let-values (((va sa) (spawn-voice-signer "alice" (synthetic-aid "alice")))
                      ((vb sb) (spawn-voice-signer "bob"   (synthetic-aid "bob"))))
           (values va sa vb sb
                   (hashmap-set (hashmap-set (hashmap) "alice" sa) "bob" sb)
                   (list (list "alice" (synthetic-aid "alice") dm-alice)
                         (list "bob"   (synthetic-aid "bob")   dm-bob))))))

     ;; Phase 2: build voice-snapshot async (crosses vat boundaries)
     (define snapshot
       (await-vow vat-fed
                  (lambda () (open-ballot-async 'policy "p-cross" 'federation
                                                "Cross-vat test ballot"
                                                citizens-for-ballot
                                                citizen-registry
                                                scope-roots))))

     ;; Phase 3: verify snapshot, spawn ballot, cast, tally (all in vat-fed)
     (with-vat vat-fed
       (let ((alice-snap (hashmap-ref snapshot "alice" #f))
             (bob-snap   (hashmap-ref snapshot "bob"   #f)))

         (check-pred "snapshot has alice"
                     (and alice-snap #t))
         (check-pred "snapshot has bob"
                     (and bob-snap #t))

         (check-pred "alice voice-share = 30/80"
                     (approx= (voice-snap-share alice-snap) 30/80))
         (check-pred "bob voice-share = 50/80"
                     (approx= (voice-snap-share bob-snap) 50/80))

         (let ((alice-deleg (voice-snap-delegation alice-snap)))
           (check-pred "alice delegation to bob = 1"
                       (let ((entry (hashmap-ref alice-deleg "bob" #f)))
                         (and entry (= 1 (entry-fraction entry)))))))

       (let ((ballot (spawn-ballot-from-snapshot
                       'policy "p-cross" 'federation "Cross-vat test ballot"
                       snapshot citizen-registry
                       (lambda (_aid) #t) #f)))

         ;; Bob casts 'yes — holds his own 50/80 + alice's delegated 30/80
         ($ ballot 'cast "bob" ($ voice-bob 'stance "p-cross" 'yes))

         (let* ((tally-result (assoc-ref ($ ballot 'tally) 'tally))
                (abstain      (assoc-ref ($ ballot 'tally) 'abstain))
                (yes-weight   (hashmap-ref tally-result 'yes 0)))
           (check-pred "yes weight = 1 (bob direct + alice delegated)"
                       (approx= yes-weight 1))
           (check-pred "abstain = 0"
                       (approx= abstain 0))))))

   (newline)
   (display (string-append "── Results: "
                           (number->string pass-count) " passed, "
                           (number->string fail-count) " failed ──\n")))
 #:drain? #f)

(test-summary!)
