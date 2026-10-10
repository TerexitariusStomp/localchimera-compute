;;; test-integration.scm — gateway-facing governance flow
;;;
;;; Exercises ^governance-service end-to-end:
;;;   - ensure-citizen on auth'd access
;;;   - open / close gated on governor credential
;;;   - cast: voice = labor in snapshot, no membership gate
;;;   - get-result / list-proposals reads
;;;   - persistence: tally survives re-spawn of the ballot-store
;;;
;;; Uses mock scope-root + account-store and explicit credential predicates;
;;; no KERIA dependency.

(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness))
(use-modules (playnet scope ballot-store) (playnet utils store-utils) (srfi srfi-1))
(use-modules (playnet utils endorsement))
(use-modules (playnet scope ballot-store) (playnet boot governance))
(use-modules (playnet scope ballot-store))
(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap))


;; ── Mocks ────────────────────────────────────────────────────────────────

(define (^mock-account-store _bcom gross-by-id total)
  (methods
    ((total-social-svc . _level) total)
    ((citizen-gross cid . _level) (hashmap-ref gross-by-id cid 0))
    ;; the cells a store states (account.scm credit-cells): a gross per citizen, the total once
    ((credit-cells) (cons (cons '(svc . *) total)
                          (map (lambda (cid) (cons (cons 'gross cid) (hashmap-ref gross-by-id cid 0)))
                               (hashmap-keys gross-by-id))))))

(define (^mock-scope-root _bcom account-store-ref ballot-store-ref)
  (methods
    ((account-store) account-store-ref)
    ((ballot-store)  ballot-store-ref)))


(define vat (spawn-vat))


;;; ════════════════════════════════════════════════════════════════════════
;;; 1. Happy path: governor opens, two members cast, tally is recorded
;;; ════════════════════════════════════════════════════════════════════════

(display "\n── 1. Governor opens, members cast, tally recorded ──\n")

(define governor-set
  ;; Only carol-aid is a governor (gates ballot/expression open/close).
  ;; There is no membership gate on voice — voice = labor in snapshot.
  (list "carol-aid"))

(define (governor? aid) (and (member aid governor-set) #t))

(with-vat vat
  ;; Build the scope.
  (define gross (hashmap-set (hashmap-set (hashmap) "alice-aid" 40)
                              "bob-aid" 60))
  (define as (spawn ^mock-account-store gross 100))
  (define bs (spawn-ballot-store))
  (define scope (spawn ^mock-scope-root as bs))

  (define svc (spawn-governance-service (list scope) bs
                                         #:governor? governor?))

  ;; Carol (governor) opens the ballot. (Alice and Bob get auto-spawned
  ;; on cast-stance below.)
  (let ((r ($ svc 'open "carol-aid" 'ballot 'policy "p-int-1"
              "first integration ballot" 'federation)))
    (check-pred "open-ballot returned (ok proposal-id)"
                (and (pair? r) (eq? (car r) 'ok))))

  ;; Alice casts yes; Bob casts no. ensure-citizen spawns their voices
  ;; under the hood. But wait — at open-ballot time, the snapshot was
  ;; built only from citizens already known to the service (carol).
  ;; To exercise the realistic case, we ensure-citizen alice/bob FIRST
  ;; via reading their delegation-map, then re-open the ballot.

  ($ svc 'delegation-map "alice-aid")  ;; spawn alice
  ($ svc 'delegation-map "bob-aid")    ;; spawn bob

  (let ((r2 ($ svc 'open "carol-aid" 'ballot 'policy "p-int-2"
                  "ballot with all citizens spawned" 'federation)))
    (check-pred "second open-ballot ok"
                (and (pair? r2) (eq? (car r2) 'ok))))

  (let ((alice-cast ($ svc 'cast "alice-aid" "p-int-2" 'yes))
        (bob-cast   ($ svc 'cast "bob-aid"   "p-int-2" 'no)))
    (check-pred "alice cast ok" (eq? alice-cast 'ok))
    (check-pred "bob cast ok"   (eq? bob-cast   'ok)))

  ;; Live tally before close.
  (let* ((live ($ svc 'get-result "p-int-2"))
         (tag  (car live))
         (tally-list (cdr live))
         (tally (assoc-ref tally-list 'tally)))
    (check-pred "live tally tag = open" (eq? tag 'open))
    (check-pred "live yes weight = 0.4" (= 4/10 (hashmap-ref tally 'yes 0)))
    (check-pred "live no weight = 0.6"  (= 6/10 (hashmap-ref tally 'no 0))))

  ;; Close — only governor permitted.
  (let ((bad ($ svc 'close "alice-aid" "p-int-2")))
    (check-pred "non-governor close rejected"
                (and (pair? bad) (eq? (car bad) 'error))))
  (let ((ok ($ svc 'close "carol-aid" "p-int-2")))
    (check-pred "governor close ok"
                (and (pair? ok) (eq? (car ok) 'ok))))

  ;; After close: tally is persisted as 'closed.
  (let* ((rec ($ svc 'get-result "p-int-2"))
         (tag (car rec))
         (rec-body (cdr rec)))
    (check-pred "tally tag = closed" (eq? tag 'closed))
    (check-pred "closed tally has yes 0.4"
                (= 4/10 (hashmap-ref (assoc-ref rec-body 'tally) 'yes 0))))

  ;; list-proposals: should include p-int-2 as 'closed.
  (let ((props ($ svc 'list-proposals)))
    (check-pred "p-int-2 listed as closed"
                (any (lambda (p)
                       (and (equal? (car p) "p-int-2")
                            (eq? (cdr p) 'closed)))
                     props))))


;;; ════════════════════════════════════════════════════════════════════════
;;; 2. Voice rides on labor, not membership: anyone with labor can cast
;;; ════════════════════════════════════════════════════════════════════════

(display "\n── 2. Voice = labor, not membership ──\n")

(with-vat vat
  ;; mallory is NOT in any membership list, but she has labor evidence.
  ;; Voice rides on labor; membership is irrelevant to casting.
  (define gross (hashmap-set (hashmap-set (hashmap) "alice-aid" 50)
                              "mallory-aid" 50))
  (define as (spawn ^mock-account-store gross 100))
  (define bs (spawn-ballot-store))
  (define scope (spawn ^mock-scope-root as bs))
  (define svc (spawn-governance-service (list scope) bs
                                         #:governor? governor?))

  ;; Pre-spawn alice + mallory so the snapshot includes them.
  ($ svc 'delegation-map "alice-aid")
  ($ svc 'delegation-map "mallory-aid")

  ($ svc 'open "carol-aid" 'ballot 'policy "p-int-3"
     "voice ≠ membership" 'federation)

  ;; Both can cast — KERI auth is the only identity gate, and weight
  ;; comes from labor in the snapshot.
  (let ((r ($ svc 'cast "alice-aid" "p-int-3" 'yes)))
    (check-pred "alice cast ok" (eq? r 'ok)))
  (let ((r ($ svc 'cast "mallory-aid" "p-int-3" 'no)))
    (check-pred "mallory (non-member) cast also ok — voice is by labor"
                (eq? r 'ok)))

  ;; Tally reflects labor: each contributed 50/100 = 0.5.
  (let* ((live ($ svc 'get-result "p-int-3"))
         (tally (assoc-ref (cdr live) 'tally)))
    (check-pred "alice yes-weight = 0.5"
                (= 1/2 (hashmap-ref tally 'yes 0)))
    (check-pred "mallory no-weight = 0.5"
                (= 1/2 (hashmap-ref tally 'no 0)))))


;;; ════════════════════════════════════════════════════════════════════════
;;; 3. Non-governor cannot open a ballot
;;; ════════════════════════════════════════════════════════════════════════

(display "\n── 3. Non-governor open rejected ──\n")

(with-vat vat
  (define as (spawn ^mock-account-store (hashmap) 0))
  (define bs (spawn-ballot-store))
  (define scope (spawn ^mock-scope-root as bs))
  (define svc (spawn-governance-service (list scope) bs
                                         #:governor? governor?))
  (let ((r ($ svc 'open "alice-aid" 'ballot 'policy "p-int-4" "denied" 'federation)))
    (check-pred "non-governor open rejected"
                (and (pair? r) (eq? (car r) 'error)))))


;;; ════════════════════════════════════════════════════════════════════════
;;; 4. ballot-store survives re-spawn (state persistence sanity)
;;; ════════════════════════════════════════════════════════════════════════

(display "\n── 4. Tally survives ballot-store recreate ──\n")

(with-vat vat
  ;; Two ballot-stores can hold the same tally if we hand it across.
  ;; The persistence layer (syrup) is exercised via spawn-persistent-vat
  ;; in production; here we sanity-check that record-tally is independent
  ;; of the live ballot ref.
  (define bs1 (spawn-ballot-store))
  ($ bs1 'record-tally "p-int-5"
       (hashmap-set (hashmap) 'yes 100)
       0
       12345)
  (let ((rec ($ bs1 'get-tally "p-int-5")))
    (check-pred "tally yes = 100"
                (= 100 (hashmap-ref (assoc-ref rec 'tally) 'yes 0)))
    (check-pred "abstain = 0" (= 0 (assoc-ref rec 'abstain)))
    (check-pred "timestamp preserved" (= 12345 (assoc-ref rec 'timestamp))))

  ;; list-proposals: present even after forget.
  ($ bs1 'forget "p-int-5")
  (let ((props ($ bs1 'list-proposals)))
    (check-pred "still listed as closed after forget"
                (any (lambda (p)
                       (and (equal? (car p) "p-int-5")
                            (eq? (cdr p) 'closed)))
                     props))))


(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
