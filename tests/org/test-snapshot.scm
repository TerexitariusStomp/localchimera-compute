;;; test-snapshot.scm — build-voice-snapshot unit tests
;;;
;;; Mocks a minimal scope-root + account-store so we can verify
;;; build-voice-snapshot produces the right voice-share = gross/total_svc
;;; ratios without touching the full planner stack.

(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness))
(use-modules (playnet utils store-utils))
(use-modules (playnet utils endorsement))
(use-modules (playnet voice ballot) (playnet voice delegation-map) (playnet voice snapshot) (playnet voice voice-signer))
(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap))


;; ── Mock account-store: hashmap citizen-id → gross hours ─────────────────

(define (^mock-account-store _bcom gross-by-id total)
  (methods
    ((total-social-svc . _level) total)
    ((citizen-gross cid . _level) (hashmap-ref gross-by-id cid 0))
    ;; the cells a store states (account.scm credit-cells): a gross per citizen, the total once
    ((credit-cells) (cons (cons '(svc . *) total)
                          (map (lambda (cid) (cons (cons 'gross cid) (hashmap-ref gross-by-id cid 0)))
                               (hashmap-keys gross-by-id))))))

(define (^mock-scope-root _bcom account-store-ref)
  (methods
    ((account-store) account-store-ref)))


(define vat (spawn-vat))


;;; ════════════════════════════════════════════════════════════════════════
;;; 1. Two citizens, single scope: voice-share = gross / total
;;; ════════════════════════════════════════════════════════════════════════

(display "\n── 1. Two-citizen single-scope ──\n")

(with-vat vat
  (define gross (hashmap-set (hashmap-set (hashmap) "alice" 30) "bob" 70))
  (define total 100)
  (define as (spawn ^mock-account-store gross total))
  (define scope (spawn ^mock-scope-root as))
  (define alice-dm (spawn-delegation-map "alice"))
  (define bob-dm   (spawn-delegation-map "bob"))
  (define records
    (list (list "alice" "alice-aid" alice-dm)
          (list "bob"   "bob-aid"   bob-dm)))
  (define snap (build-voice-snapshot records (list scope)))
  (let ((alice-entry (hashmap-ref snap "alice" #f))
        (bob-entry   (hashmap-ref snap "bob" #f)))
    (check-pred "alice in snapshot" alice-entry)
    (check-pred "bob in snapshot"   bob-entry)
    (check-pred "alice voice = 0.3"
                (and alice-entry (= 3/10 (car alice-entry))))
    (check-pred "bob voice = 0.7"
                (and bob-entry (= 7/10 (car bob-entry))))
    (check-pred "alice's delegation-map ref preserved"
                (eq? alice-dm (cdr alice-entry)))))


;;; ════════════════════════════════════════════════════════════════════════
;;; 2. Two scopes summed
;;; ════════════════════════════════════════════════════════════════════════

(display "\n── 2. Two-scope federation ──\n")

(with-vat vat
  ;; watershed: alice 10, bob 20  (total 30)
  ;; tech-coop: alice 5,  bob 15  (total 20)
  ;; federation total: 50; alice 15/50 = 0.3, bob 35/50 = 0.7
  (define ws (spawn ^mock-account-store
                    (hashmap-set (hashmap-set (hashmap) "alice" 10) "bob" 20)
                    30))
  (define tc (spawn ^mock-account-store
                    (hashmap-set (hashmap-set (hashmap) "alice" 5) "bob" 15)
                    20))
  (define s-ws (spawn ^mock-scope-root ws))
  (define s-tc (spawn ^mock-scope-root tc))
  (define adm (spawn-delegation-map "alice"))
  (define bdm (spawn-delegation-map "bob"))
  (define snap (build-voice-snapshot
                 (list (list "alice" "alice-aid" adm)
                       (list "bob"   "bob-aid"   bdm))
                 (list s-ws s-tc)))
  (let ((a (hashmap-ref snap "alice" #f))
        (b (hashmap-ref snap "bob" #f)))
    (check-pred "federation alice = 0.3" (= 3/10 (car a)))
    (check-pred "federation bob = 0.7"   (= 7/10 (car b)))))


;;; ════════════════════════════════════════════════════════════════════════
;;; 3. Citizen with zero gross: voice-share = 0 (still in snapshot)
;;; ════════════════════════════════════════════════════════════════════════

(display "\n── 3. Zero-voice citizen retained ──\n")

(with-vat vat
  (define gross (hashmap-set (hashmap-set (hashmap) "alice" 100) "carol" 0))
  (define as (spawn ^mock-account-store gross 100))
  (define scope (spawn ^mock-scope-root as))
  (define adm (spawn-delegation-map "alice"))
  (define cdm (spawn-delegation-map "carol"))
  (define snap (build-voice-snapshot
                 (list (list "alice" "alice-aid" adm)
                       (list "carol" "carol-aid" cdm))
                 (list scope)))
  (let ((a (hashmap-ref snap "alice" #f))
        (c (hashmap-ref snap "carol" #f)))
    (check-pred "alice = 1.0" (= 1 (car a)))
    (check-pred "carol present, voice 0" (and c (= 0 (car c))))))


;;; ════════════════════════════════════════════════════════════════════════
;;; 4. End-to-end: snapshot → ballot → tally
;;; ════════════════════════════════════════════════════════════════════════

(display "\n── 4. snapshot → open-ballot → tally ──\n")

(with-vat vat
  (define gross (hashmap-set (hashmap-set (hashmap) "alice" 40) "bob" 60))
  (define as (spawn ^mock-account-store gross 100))
  (define scope (spawn ^mock-scope-root as))

  ;; Real citizen-voice + delegation-map for each.
  (define-values (alice-voice alice-sealed?)
    (spawn-voice-signer "alice" "alice-aid"))
  (define-values (bob-voice bob-sealed?)
    (spawn-voice-signer "bob" "bob-aid"))
  (define alice-dm (spawn-delegation-map "alice"))
  (define bob-dm   (spawn-delegation-map "bob"))

  (define records
    (list (list "alice" "alice-aid" alice-dm)
          (list "bob"   "bob-aid"   bob-dm)))
  (define snap (build-voice-snapshot records (list scope)))
  (define registry
    (build-citizen-registry
      (list (cons "alice" alice-sealed?)
            (cons "bob"   bob-sealed?))))

  (define b (open-ballot 'policy "p-snap-1" 'federation "test"
                         registry snap))
  ($ b 'cast "alice" ($ alice-voice 'stance "p-snap-1" 'yes))
  ($ b 'cast "bob"   ($ bob-voice   'stance "p-snap-1" 'no))
  (let* ((tr ($ b 'tally))
         (tally   (assoc-ref tr 'tally))
         (yes-w   (hashmap-ref tally 'yes 0))
         (no-w    (hashmap-ref tally 'no  0)))
    (check-pred "yes weight = 0.4 (alice)" (= 4/10 yes-w))
    (check-pred "no weight  = 0.6 (bob)"   (= 6/10 no-w))))


(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
