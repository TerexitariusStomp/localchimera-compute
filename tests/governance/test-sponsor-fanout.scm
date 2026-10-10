;;; test-sponsor-fanout.scm — sponsor fan-out cap on `invite`
;;;
;;; A single sponsor cannot flood the ecosystem with PHCs. Caps:
;;;   1. Honoured: cap=2 lets two invites through, blocks the third.
;;;   2. Per-window: invites outside the window don't count.
;;;   3. Per-sponsor: alice's invites don't constrain bob's quota.
;;;   4. Override: cap=#f disables the check (migrations / tests).
;;;   5. Indexed: sponsor-recent-invites uses O(1) claim index.

(use-modules (playnet test harness))
(use-modules (playnet planner scope root))
(use-modules (playnet governance scope) (playnet keri acdc) (playnet keri acdc-store) (playnet keri first-person credentials) (playnet keri first-person predicates))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (rnrs bytevectors) (srfi srfi-1))


(define vat (spawn-vat))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Cap honoured — third invite over cap=2 rejects
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Fan-out cap honoured ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define scope-root (spawn-scope-root "FanA"))
  (define scope (spawn-scope "FanA"
                             #:kind 'commune
                             #:scope-aid "E_fanA"
                             #:scope-root-ref scope-root
                             #:acdc-store store))
  (define gov-cap ($ scope 'mint-gov-cap "op"))

  ;; Seed alice as a founder.
  ($ scope 'issue-phc gov-cap "E_alice" "ev:alice")

  ;; Alice invites two with cap=2 — both succeed.
  (define t0 1000)
  ($ scope 'invite gov-cap "E_alice" "E_a1" "ev" t0 2 (* 30 24 3600))
  ($ scope 'invite gov-cap "E_alice" "E_a2" "ev" (+ t0 1) 2 (* 30 24 3600))

  (check-pred "a1 enrolled"
              (holds-live-phc? store "E_fanA" "E_a1"))
  (check-pred "a2 enrolled"
              (holds-live-phc? store "E_fanA" "E_a2"))

  ;; Third invite at the same window with cap=2 must reject.
  (check-pred "third invite over cap=2 rejects"
              (catch #t
                (lambda ()
                  ($ scope 'invite gov-cap "E_alice" "E_a3" "ev"
                     (+ t0 2) 2 (* 30 24 3600))
                  #f)
                (lambda _ #t)))
  (check-pred "a3 NOT enrolled (rejected)"
              (not (holds-live-phc? store "E_fanA" "E_a3"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Per-sponsor — bob's quota is independent of alice's
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Cap is per-sponsor ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define scope-root (spawn-scope-root "FanB"))
  (define scope (spawn-scope "FanB"
                             #:kind 'commune
                             #:scope-aid "E_fanB"
                             #:scope-root-ref scope-root
                             #:acdc-store store))
  (define gov-cap ($ scope 'mint-gov-cap "op"))

  ($ scope 'issue-phc gov-cap "E_alice" "ev:alice")
  ($ scope 'issue-phc gov-cap "E_bob"   "ev:bob")

  ;; Alice maxes out at cap=1.
  ($ scope 'invite gov-cap "E_alice" "E_a1" "ev" 100 1 999999)
  (check-pred "alice's 2nd invite blocked at cap=1"
              (catch #t
                (lambda ()
                  ($ scope 'invite gov-cap "E_alice" "E_a2" "ev" 101 1 999999)
                  #f)
                (lambda _ #t)))

  ;; Bob's quota is fresh.
  ($ scope 'invite gov-cap "E_bob" "E_b1" "ev" 102 1 999999)
  (check-pred "b1 enrolled — bob's quota independent"
              (holds-live-phc? store "E_fanB" "E_b1")))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Window — old invites fall out
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Window expiry — old invites don't count ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define scope-root (spawn-scope-root "FanC"))
  (define scope (spawn-scope "FanC"
                             #:kind 'commune
                             #:scope-aid "E_fanC"
                             #:scope-root-ref scope-root
                             #:acdc-store store))
  (define gov-cap ($ scope 'mint-gov-cap "op"))

  ($ scope 'issue-phc gov-cap "E_alice" "ev:alice")

  ;; Old invite at t=100, window=10s.
  ($ scope 'invite gov-cap "E_alice" "E_old" "ev" 100 1 10)

  ;; New invite at t=200 — old one is outside [190, 200], so quota fresh.
  ($ scope 'invite gov-cap "E_alice" "E_new" "ev" 200 1 10)
  (check-pred "new invite admitted — old fell out of window"
              (holds-live-phc? store "E_fanC" "E_new"))

  ;; Same-window pair fails.
  (check-pred "second invite within window rejects"
              (catch #t
                (lambda ()
                  ($ scope 'invite gov-cap "E_alice" "E_x" "ev" 205 1 10)
                  #f)
                (lambda _ #t))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Cap = #f disables the check
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Cap = #f disables enforcement ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define scope-root (spawn-scope-root "FanD"))
  (define scope (spawn-scope "FanD"
                             #:kind 'commune
                             #:scope-aid "E_fanD"
                             #:scope-root-ref scope-root
                             #:acdc-store store))
  (define gov-cap ($ scope 'mint-gov-cap "op"))

  ($ scope 'issue-phc gov-cap "E_alice" "ev:alice")

  ;; 10 invites under cap=#f — all admitted.
  (for-each
    (lambda (i)
      ($ scope 'invite gov-cap "E_alice"
         (string-append "E_n" (number->string i))
         "ev" (+ 1000 i) #f 1))
    (iota 10))

  (check "10 invites all admitted"
         (length (filter (lambda (c)
                           (equal? (cred-claim c 'sponsor-aid) "E_alice"))
                         ($ store 'by-schema *schema-playnet-personhood*)))
         10))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Direct probe of sponsor-recent-invites
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. sponsor-recent-invites query ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define scope-root (spawn-scope-root "FanE"))
  (define scope (spawn-scope "FanE"
                             #:kind 'commune
                             #:scope-aid "E_fanE"
                             #:scope-root-ref scope-root
                             #:acdc-store store))
  (define gov-cap ($ scope 'mint-gov-cap "op"))

  ($ scope 'issue-phc gov-cap "E_alice" "ev:alice")
  ($ scope 'invite gov-cap "E_alice" "E_p1" "ev" 100 #f 1)
  ($ scope 'invite gov-cap "E_alice" "E_p2" "ev" 200 #f 1)
  ($ scope 'invite gov-cap "E_alice" "E_p3" "ev" 300 #f 1)

  (check "since=0 → 3 invites"
         (length (sponsor-recent-invites store "E_fanE" "E_alice" 0)) 3)
  (check "since=150 → 2 invites"
         (length (sponsor-recent-invites store "E_fanE" "E_alice" 150)) 2)
  (check "since=999 → 0 invites"
         (length (sponsor-recent-invites store "E_fanE" "E_alice" 999)) 0))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
