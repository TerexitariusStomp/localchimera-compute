;;; test-federation-wire.scm — the federated solve across a vat boundary, in
;;; one process: the boundary oracle reproduces solve-decomposed, two communes
;;; in two vats settle through signed messages, and a reply that is not what
;;; its signer said is refused.
;;;
;;;   1. PARITY — solve-consensus over direct oracles is solve-decomposed's
;;;      ADMM: same rounds, same pull, on the same two-commune economy.
;;;   2. TWO VATS — each commune a ^commune-solver in its own vat under its
;;;      own KERI AID; the coordinator in a third; met and pull as in-process.
;;;   3. TAMPER — a commune answering under an AID the coordinator does not
;;;      expect, and a relay that edits a signed reply, both break the solve.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/federation/test-federation-wire.scm

(use-modules ((playnet solve solver) #:select (*last-certificate*)) (playnet test harness)
             (playnet federation wire)
             ((playnet solve decomposed) #:select (solve-decomposed)) ((playnet solve federation-oracle) #:select (make-boundary-oracle solve-consensus))
             ((playnet keri citizen-sig) #:select (make-keri-identity keri-identity-aid))
             (goblins) (goblins actor-lib methods)
             (srfi srfi-1) (ice-9 format))

(use-modules (playnet test planner federation-wire-fixture))

(define (last-certificate) *last-certificate*)   ; the solver's cell, read late

;; ── 1. parity: the oracle IS the scope's half of solve-decomposed ────────────
;; The consensus loop runs FIRST: solve-decomposed's finish settles the
;; kernel's path floor (call-at-settled-floor → pk_set_tmin), and every solve
;; after it in the process starts from that floor. Fresh, the two loops are
;; bit-identical for every round; this order keeps both fresh. The met
;; compared is the rounds' own, which solve-decomposed keeps on its
;; certificate: the plan it answers may be its exact local solve's.
(display "\n── 1. solve-consensus over direct oracles = solve-decomposed ──\n")
(define oracles (list (make-boundary-oracle (fx-commune-a)) (make-boundary-oracle (fx-commune-b))))
(define-values (met-c rounds-c pull-c)
  (call-with-values
      (lambda ()
        (solve-consensus (map (lambda (o) (o 'links)) oracles)
                         (lambda (centres rho*) (map (lambda (o c) (o 'solve! c rho*)) oracles centres))))
    (lambda (reports met rounds pulls) (values met rounds (hash-ref pulls "flour" 0.0)))))
(define-values (met-d rounds-d pull-d)
  (call-with-values (lambda () (solve-decomposed (list (fx-commune-a) (fx-commune-b))
                                                 #:reconcile? #f #:refine? #f))
    (lambda (plans met rounds pulls)
      (values (assq-ref (last-certificate) 'met) rounds (hash-ref pulls "flour" 0.0)))))
(format #t "   decomposed: met ~,2f rounds ~a λ ~,6f~%" met-d rounds-d pull-d)
(format #t "   consensus : met ~,2f rounds ~a λ ~,6f~%" met-c rounds-c pull-c)
(check "A and B share flour, and say no more of it than that"
       (map (lambda (o) (o 'links)) oracles) '(("flour") ("flour")))
(check "A, holding flour, has a column that goes either way; B, holding none, one that takes"
       (map (lambda (o) (o 'sides)) oracles) '((("flour" . net)) (("flour" . take))))
(check "same number of rounds" rounds-c rounds-d)
(check "same boundary pull" (< (abs (- pull-c pull-d)) 1e-9))
(check "same met at the last round" (< (abs (- met-c met-d)) 1e-6))
(check "demand met" (> met-c 98.0))

;; ── 2. two vats, signed ──────────────────────────────────────────────────────
(display "\n── 2. two communes in two vats, one coordinator, signed replies ──\n")
(define id-a (make-keri-identity (fx-seed 1)))
(define id-b (make-keri-identity (fx-seed 2)))

(define (run-wire communes-of aids . opts)
  "Spawn vats A, B, coordinator on the default scheduler; COMMUNES-OF builds
   the two refs given the two vats; run the wire solve from this (plain)
   thread. → (met rounds pull reports) or (error key . args)."
  (let* ((vat-a (spawn-vat #:name "commune-A"))
         (vat-b (spawn-vat #:name "commune-B"))
         (vat-c (spawn-vat #:name "coordinator"))
         (communes (communes-of vat-a vat-b)))
    (catch #t
      (lambda ()
        (call-with-values (lambda () (apply federated-solve-wire vat-c communes #:aids aids opts))
          (lambda (reports met rounds pulls)
            (list met rounds (hash-ref pulls "flour" 0.0) reports))))
      (lambda (k . args) (cons 'error (cons k args))))))

(define (honest-over rec-a rec-b)
  (lambda (vat-a vat-b)
    (list (with-vat vat-a (spawn ^commune-solver (make-boundary-oracle rec-a) id-a #:name "Granary"))
          (with-vat vat-b (spawn ^commune-solver (make-boundary-oracle rec-b) id-b #:name "Table")))))
(define honest (honest-over (fx-commune-a) (fx-commune-b)))

(define (check-wire-run label r ref scarce?)
  (check (string-append label ": the wire solve completed") (not (eq? (car r) 'error)))
  (when (not (eq? (car r) 'error))
    (let ((met (list-ref r 0)) (rounds (list-ref r 1)) (pull (list-ref r 2)) (reports (list-ref r 3))
          (cert (last-certificate)))
      (format #t "   ~a: met ~,2f rounds ~a λ(flour) ~,6f   (in-process: met ~,2f rounds ~a λ ~,6f)~%"
              label met rounds pull (car ref) (cadr ref) (caddr ref))
      (format #t "   certificate: ~s~%" cert)
      (if scarce?
          (begin
            ;; 20 kg in stock, 5 of it the granary's own floor: 15 cross, and the
            ;; table's 40 kg ask is met in part — the shortfall is reported, not
            ;; papered over, and the pull is the dual of the binding stock fold
            (check (string-append label ": the shortfall is honest (met well below 100)") (< 50.0 met 98.0))
            (check (string-append label ": the flow is the stock fold's bound net of the granary's floor: 20 − 5")
                   (< (abs (- (assoc-ref (assq-ref (car reports) 'flows) "flour") 15.0)) 0.5))
            (check (string-append label ": the binding fold pulls the link (|λ| ≫ 0)") (> (abs pull) 1.0)))
          (check (string-append label ": demand met across the wire") (> met 98.0)))
      (check (string-append label ": the wire ran the in-process rounds") rounds (cadr ref))
      (check (string-append label ": the wire pull is the in-process pull") (< (abs (- pull (caddr ref))) 1e-9))
      (check (string-append label ": certificate kind") (assq-ref cert 'kind) 'federated-wire)
      (check (string-append label ": every commune's floors close") (assq-ref cert 'feasible?) #t)
      (check (string-append label ": the plan is executable (nothing drawn that nobody sends)") (assq-ref cert 'coupling-feasible?) #t)
      (check (string-append label ": reports name the AIDs")
             (map (lambda (r) (assq-ref r 'aid)) reports)
             (list (keri-identity-aid id-a) (keri-identity-aid id-b)))
      (check (string-append label ": reports carry flows, not plans")
             (every (lambda (r) (and (assq 'flows r) (not (assq 'plan r)))) reports))
      (check (string-append label ": what A supplies is what B draws")
             (< (abs (+ (assoc-ref (assq-ref (car reports) 'flows) "flour")
                        (assoc-ref (assq-ref (cadr reports) 'flows) "flour")))
                1e-3))
      (check (string-append label ": A supplies and B draws — the flows say so, nobody declared it")
             (and (> (assoc-ref (assq-ref (car reports) 'flows) "flour") 0.0)
                  (< (assoc-ref (assq-ref (cadr reports) 'flows) "flour") 0.0))))))

;; abundant flour: the pull is ~0 and the demand is met
(define ref-2 (fx-reference (fx-commune-a) (fx-commune-b)))
(check-wire-run "abundant" (run-wire honest #f) ref-2 #f)

;; scarce flour: the granary's own floor leaves 15 kg for a 40 kg ask — the
;; pull is the dual of that bound, and the wire settles at the same number
(define ref-2s (fx-reference (fx-commune-a-scarce) (fx-commune-b)))
(check-wire-run "scarce" (run-wire (honest-over (fx-commune-a-scarce) (fx-commune-b))
                                   (list (keri-identity-aid id-a) (keri-identity-aid id-b)))
                ref-2s #t)

;; ── 3. tamper ────────────────────────────────────────────────────────────────
(display "\n── 3. an unexpected signer, and an edited reply, are refused ──\n")
(define id-x (make-keri-identity (fx-seed 9)))
(define r3a (run-wire honest (list (keri-identity-aid id-a) (keri-identity-aid id-x))))
(check "a commune answering under another AID breaks the solve" (eq? (car r3a) 'error))
(when (eq? (car r3a) 'error) (format #t "   refused: ~s~%" (cdr r3a)))

;; a relay in the path that keeps the signature and edits the text: doubles
;; every flow the commune reports
(define (^editing-relay bcom target)
  (define (edit reply)
    (let* ((text (car reply))
           (payload (call-with-input-string text read))
           (flows (assq-ref payload 'flows))
           (payload* (if flows
                         (map (lambda (kv) (if (eq? (car kv) 'flows)
                                               (cons 'flows (map (lambda (f) (cons (car f) (* 2.0 (cdr f)))) flows))
                                               kv))
                              payload)
                         payload)))
      (list (object->string payload*) (cadr reply))))
  (methods
   ((hello rid) (<- target 'hello rid))
   ((round rid centres rho) (on (<- target 'round rid centres rho) edit #:promise? #t))
   ((refine rid z pulls rho) (on (<- target 'refine rid z pulls rho) edit #:promise? #t))
   ((clamp rid caps) (on (<- target 'clamp rid caps) edit #:promise? #t))))

(define r3b
  (run-wire (lambda (vat-a vat-b)
              (let ((real-b (with-vat vat-b (spawn ^commune-solver (make-boundary-oracle (fx-commune-b)) id-b))))
                (list (with-vat vat-a (spawn ^commune-solver (make-boundary-oracle (fx-commune-a)) id-a))
                      (with-vat vat-b (spawn ^editing-relay real-b)))))
            #f))
(check "an edited reply under a valid signature breaks the solve" (eq? (car r3b) 'error))
(when (eq? (car r3b) 'error) (format #t "   refused: ~s~%" (cdr r3b)))

;; ── 4. a deadline: a commune that misses rounds sits them out ───────────────
(display "\n── 4. a silent commune is carried on its last reply, then given up ──\n")
;; The coordinator's own loop first, over direct oracles, B missing rounds 3
;; and 4: the solve carries B's round-2 reply, cannot end on those rounds,
;; and lands where the full run landed.
(define (fresh-oracles a) (list (make-boundary-oracle a) (make-boundary-oracle (fx-commune-b))))
(define (flaky-consensus mute? . opts)
  (flaky-consensus-over (fresh-oracles (fx-commune-a)) mute? opts))
(define (flaky-consensus-over flaky-oracles mute? opts)
  (let ((r 0))
    (call-with-values
        (lambda ()
          (apply solve-consensus (map (lambda (o) (o 'links)) flaky-oracles)
                 (lambda (centres rho*)
                   (set! r (+ r 1))
                   (map (lambda (o c i) (if (and (= i 1) (mute? r)) #f (o 'solve! c rho*)))
                        flaky-oracles centres '(0 1)))
                 opts))
      (lambda (reports met rounds pulls) (list met rounds (hash-ref pulls "flour" 0.0))))))
(define r4 (flaky-consensus (lambda (r) (memv r '(3 4)))))
(define cert-4 (last-certificate))
(format #t "   flaky: met ~,2f rounds ~a λ ~,6f  stale-rounds ~a~%"
        (car r4) (cadr r4) (caddr r4) (assq-ref cert-4 'stale-rounds))
(check "two missed rounds are counted" (assq-ref cert-4 'stale-rounds) 2)
(check "the stale solve still meets the demand" (> (car r4) 98.0))
(check "and settles at the full run's pull (to the barrier's residue)"
       (< (abs (- (caddr r4) pull-c)) 0.05))
;; five missed rounds in a row: the frozen link neither integrates the stale
;; residual nor drifts, so the pull the solve lands on is the same one
(define r4l (flaky-consensus (lambda (r) (<= 3 r 7))))
(format #t "   five missed: met ~,2f rounds ~a λ ~,6f  stale-rounds ~a~%"
        (car r4l) (cadr r4l) (caddr r4l) (assq-ref (last-certificate) 'stale-rounds))
(check "five missed rounds in a row are counted" (assq-ref (last-certificate) 'stale-rounds) 5)
(check "and the pull is still the full run's" (< (abs (- (caddr r4l) pull-c)) 0.05))
;; where the pull is not ~0: the scarce economy's λ ≈ −30.8 is a number a
;; drifting dual would visibly miss
(define r4s (flaky-consensus-over (fresh-oracles (fx-commune-a-scarce)) (lambda (r) (<= 3 r 7)) '()))
(format #t "   scarce, five missed: met ~,2f rounds ~a λ ~,4f  (full run λ ~,4f)~%"
        (car r4s) (cadr r4s) (caddr r4s) (caddr ref-2s))
(check "a frozen link holds the scarce pull too (to the barrier's residue)"
       (< (abs (- (caddr r4s) (caddr ref-2s))) 0.5))
(check "a scope silent past MAX-STALE rounds raises"
       (catch #t (lambda () (flaky-consensus (lambda (r) #t) #:max-stale 3) #f)
         (lambda _ #t)))

;; The same across vats: a commune whose `round` goes unanswered on the third
;; and fourth asks. The promise it returns never resolves; the deadline
;; is what ends the wait.
(define (^mute-on-rounds bcom target from to)
  (define n 0)
  (methods
   ((hello rid) (<- target 'hello rid))
   ((round rid centres rho)
    (set! n (+ n 1))
    (if (<= from n to)
        (call-with-values spawn-promise-and-resolver (lambda (p r) p))
        (<- target 'round rid centres rho)))
   ((refine rid z pulls rho) (<- target 'refine rid z pulls rho))
   ((clamp rid caps) (<- target 'clamp rid caps))))
(define (mute-b from to)
  (lambda (vat-a vat-b)
    (let ((real-b (with-vat vat-b (spawn ^commune-solver (make-boundary-oracle (fx-commune-b)) id-b #:name "Table"))))
      (list (with-vat vat-a (spawn ^commune-solver (make-boundary-oracle (fx-commune-a)) id-a #:name "Granary"))
            (with-vat vat-b (spawn ^mute-on-rounds real-b from to))))))
(define r4w (run-wire (mute-b 3 4) #f #:deadline 0.5))
(check "the wire solve completes past two missed deadlines" (not (eq? (car r4w) 'error)))
(when (not (eq? (car r4w) 'error))
  (check "the certificate counts the stale rounds" (assq-ref (last-certificate) 'stale-rounds) 2)
  (check "demand is met" (> (car r4w) 98.0)))
(define r4x (run-wire (mute-b 3 1000) #f #:deadline 0.2 #:max-stale 3))
(check "a commune that never answers again is given up on" (eq? (car r4x) 'error))
(when (eq? (car r4x) 'error) (format #t "   refused: ~s~%" (cdr r4x)))

(test-summary!)
