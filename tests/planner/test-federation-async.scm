;;; test-federation-async.scm — the federated pull solve with no coordinator
;;; and no rounds: peers that message each other, a network that reorders,
;;; loses and repeats them, and a federation that has settled when it falls
;;; silent.
;;;
;;; The claim under test is a property, not a run: WHATEVER order the messages
;;; arrive in, the federation settles on the pull and the flows the
;;; synchronous coordinator finds. So each economy is solved once by
;;; solve-consensus as the reference, then by peers under several seeded
;;; networks, and every run is held to the reference.
;;;
;;;   1. THE PAIR — the two-commune economy, abundant and scarce (λ ≈ −30.8).
;;;   2. THE CHAIN — four scopes, three links, the middle two each master of
;;;      one link and a participant of another: the links run at their own versions.
;;;   3. A BAD NETWORK — delays over two orders of magnitude, 25% loss, 25%
;;;      duplication: the same answer, from every seed.
;;;   4. AN OUTAGE — a scope cut off for a stretch: its links stall, nothing
;;;      else does, and the federation settles once it is back.
;;;   5. SILENCE — a settled federation says nothing, and says it again when
;;;      asked; the attestations agree pairwise.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-federation-async.scm

(use-modules (playnet test harness)
             (playnet planner federation async)
             (playnet planner solve admm-link)
             ((playnet planner federation crossing) #:select (make-tuning make-crossing crossing-snapshot crossing-restore!))
             ((playnet planner solve engine) #:select (make-boundary-oracle solve-consensus))
             (playnet planner solve solver)
             (srfi srfi-1) (ice-9 format))

(use-modules (playnet test planner federation-wire-fixture))
(load (string-append (dirname (dirname (dirname (current-filename))))
                     "/module/playnet/test/planner/federated-fixtures.scm"))

;; the synchronous coordinator on fresh oracles, with its finish (the exact local
;; solve at the settled pulls, then the clamp): (met rounds pulls)
(define (reference recs)
  (let ((oracles (map make-boundary-oracle recs)))
    (call-with-values
        (lambda ()
          (solve-consensus
           (map (lambda (o) (o 'links)) oracles)
           (lambda (centres rho*) (map (lambda (o c) (o 'solve! c rho*)) oracles centres))
           #:iters 400
           #:finish! (lambda (phase args rho*)
                       (case phase
                         ((refine) (map (lambda (o a) (o 'refine! (car a) (cadr a) rho*)) oracles args))
                         ((clamp) (map (lambda (o c) (o 'clamp! c)) oracles args))))))
      (lambda (reports met rounds pulls) (list met rounds pulls)))))

;; the peers over fresh oracles, on a simulated network: (settled? time stats attests peers)
(define (run-async recs . sim-opts)
  (let ((peers (federation-of (map make-boundary-oracle recs))))
    (call-with-values (lambda () (apply simulate peers sim-opts))
      (lambda (settled? time stats peers)
        (list settled? time stats (map (lambda (p) (p 'attest)) peers) peers)))))

(define (pull-of cert link) (let ((p (assoc link (cdr (assq 'pulls cert))))) (if p (cdr p) 0.0)))
(define (ref-pull ref link) (hash-ref (caddr ref) link 0.0))
(define (met-of cert) (cdr (assq 'met cert)))
(define (settled-of cert) (cdr (assq 'settled? cert)))
(define (consensus-of cert) (cdr (assq 'consensus cert)))

(define (report label r ref links)
  (let ((cert (assemble-attestations (cadddr r))))
    (format #t "   ~a: settled ~a at t=~,1f  delivered ~a dropped ~a  met ~,2f (ref ~,2f)  consensus ~,5f~%"
            label (car r) (cadr r) (assq-ref (caddr r) 'delivered) (assq-ref (caddr r) 'dropped)
            (met-of cert) (car ref) (consensus-of cert))
    (for-each (lambda (l) (format #t "      ~a: λ ~,4f (ref ~,4f)~%" l (pull-of cert l) (ref-pull ref l))) links)
    cert))

(define (agrees label r ref links pull-tol)
  (let ((cert (report label r ref links)))
    (check (string-append label ": the federation settled") (car r))
    (check (string-append label ": every link's two ends agree") (settled-of cert))
    (check (string-append label ": the flows agree across every link") (< (consensus-of cert) 1e-3))
    (check (string-append label ": every scope made its exact local solve and was held to its masters' shipments")
           (cdr (assq 'final? cert)))
    (check (string-append label ": every scope's floors close on its final plan") (cdr (assq 'feasible? cert)))
    ;; a clamp that would break a scope's floors is not taken, so what remains
    ;; is the solver's own noise (flows here run to hundreds of kg)
    (check (string-append label ": no scope takes what its master does not ship (to 1e-4 kg)")
           (<= (cdr (assq 'overdraw cert)) 1e-4))
    (check (string-append label ": the demand met, at the final plans, is the reference's")
           (< (abs (- (met-of cert) (car ref))) 0.5))
    ;; PULL-TOL a number: the good is scarce, its pull unique, and the run's
    ;; is the reference's to that much. (abundant . BOUND): the good is abundant,
    ;; its optimum a flat face the run lands anywhere on, and the pull there is
    ;; the barrier's gradient at that point — read as a bound, small against a
    ;; scarce good's (the pair's flour settles at −30.8).
    (for-each (lambda (l)
                (if (pair? pull-tol)
                    (check (string-append label ": the pull on " l " is an abundant good's")
                           (< (abs (pull-of cert l)) (cdr pull-tol)))
                    (check (string-append label ": the pull on " l " is the reference's")
                           (< (abs (- (pull-of cert l) (ref-pull ref l))) pull-tol))))
              links)
    cert))

;; ── 0. the arithmetic under it ───────────────────────────────────────────────
(display "\n── 0. the link step, and Anderson's trust region ──\n")
(call-with-values (lambda () (link-step 10.0 0.0 0.0 12.0 8.0 1.0))
  (lambda (z us ur)
    (check "plain ADMM: z is the mean of the two flows" (< (abs (- z 10.0)) 1e-12))
    (check "each dual moves by what its flow left over, equal and opposite"
           (and (< (abs (- us 2.0)) 1e-12) (< (abs (+ us ur)) 1e-12)))))
(call-with-values (lambda () (link-step 10.0 1.0 -1.0 12.0 8.0 1.6))
  (lambda (z us ur)
    (check "over-relaxed: the duals stay each other's negation" (< (abs (+ us ur)) 1e-12))
    (check "…and the centres a scope solves against are z less its own dual"
           (call-with-values (lambda () (link-centres z us ur))
             (lambda (o c) (and (< (abs (- o (- z us))) 1e-12) (< (abs (- c (- z ur))) 1e-12)))))))
;; a history whose residual differences are nearly parallel: the least-squares
;; mixes with coefficients ~1e12 and would land the state a billion away
(call-with-values
    (lambda () (admm-anderson-step (vector 1.0 1.0 1.0) (vector 0.0 1.0 0.0)
                                   (list (vector 1.0 1.0 1.0) (vector 1.0 1.001 1.0))
                                   (list (vector 0.0 1.0 0.0) (vector 0.0 1.0000000000001 0.0)) 8))
  (lambda (v hg hf)
    (check "a degenerate history's leap is refused: the plain step stands, the history restarts"
           (and (equal? v (vector 1.0 1.0 1.0)) (null? hg) (null? hf)))))
(call-with-values
    (lambda () (admm-anderson-step (vector 1.0 1.0 1.0) (vector 0.0 1.0 0.0)
                                   (list (vector 1.0 1.0 1.0) (vector 1.0 1.001 1.0))
                                   (list (vector 0.0 1.0 0.0) (vector 0.0 1.0000000000001 0.0)) 8
                                   #:trust 1e30))
  (lambda (v hg hf)
    (check "…and with the region off, that same history lands the state far away"
           (> (abs (- (vector-ref v 1) 1.0)) 1e3))))

;; the leap budget: an accelerator takes at most so many leaps in its life, so
;; every run is plain from some step on — the hypothesis of the machine-checked
;; convergence of the composition (docs/formal, AveragedIteration)
(let* ((ex (make-exchange '(("flour" . 2)) '(("flour" 10.0 -10.0)) #:rho 4.0))
       (acc (make-exchange-accelerator ex #:budget 3))
       (plain-after-budget #t) (leaps-seen '()))
  ;; two scopes that answer a centre with a flow of their own: slow to agree, so
  ;; the extrapolation has something to leap
  (define (round!)
    (let ((ys (list (+ (* 0.9 (exchange-centre ex "flour" 0)) 2.0)
                    (- (* 0.8 (exchange-centre ex "flour" 1)) 1.0))))
      (acc 'begin!)
      (exchange-step! ex "flour" ys 1.6)
      (let ((stepped (exchange->vector ex)) (spent? (>= (acc 'leaps) 3)))
        (acc 'end!)
        (when (and spent? (not (equal? stepped (exchange->vector ex)))) (set! plain-after-budget #f))
        (set! leaps-seen (cons (acc 'leaps) leaps-seen)))))
  (do ((i 0 (+ i 1))) ((= i 12)) (round!))
  (acc 'reset!)                                   ; a restart of the history gives no leap back
  (do ((i 0 (+ i 1))) ((= i 12)) (round!))
  (check "the accelerator leaps, and no more often than its budget" (apply max leaps-seen) 3)
  (check "the count of leaps never falls: a restart of the history gives none back"
         (apply >= leaps-seen))
  (check "the budget spent, every step after is the step itself" plain-after-budget))
(let* ((t (make-tuning 1.6 1.0 #t 8 #t 10.0 4 1e-4 1e-4 3))
       (m (make-crossing "flour" 4.0 0 '("a" "b") '(10.0 -10.0) t))
       (m* (make-crossing "flour" 4.0 0 '("a" "b") '(10.0 -10.0) t))
       (leaps (lambda (s) (last s))))
  (check "a master's snapshot keeps the leaps taken, and a restart resumes at them"
         (let ((s (crossing-snapshot m)))
           (list (leaps s)
                 (leaps (crossing-snapshot (crossing-restore! m* (append (drop-right s 1) (list 7)))))))
         '(0 7))
  (check "a snapshot says the form its flows are spoken in and the members it is of"
         (list-head (crossing-snapshot m) 2) '(signed ("a" "b")))
  (check "one spoken in another form is set aside, and the good stands as it was made"
         (crossing-restore! m* (cons 'sided (cdr (crossing-snapshot m)))) #f)
  (check "one of other members is set aside too"
         (crossing-restore! (make-crossing "flour" 4.0 0 '("a" "c") #f t) (crossing-snapshot m)) #f))

;; ── 1. the pair ──────────────────────────────────────────────────────────────
(display "\n── 1. two communes, one link: the async solve settles where the coordinator does ──\n")
(define ref-abundant (reference (list (fx-commune-a) (fx-commune-b))))
(agrees "abundant" (run-async (list (fx-commune-a) (fx-commune-b)) #:seed 1) ref-abundant '("flour") 0.05)
(define ref-scarce (reference (list (fx-commune-a-scarce) (fx-commune-b))))
(agrees "scarce" (run-async (list (fx-commune-a-scarce) (fx-commune-b)) #:seed 1) ref-scarce '("flour") 0.5)

;; ── 2. the chain ─────────────────────────────────────────────────────────────
(display "\n── 2. a chain of four: links at their own versions ──\n")
(define chain-links '("L0" "L1" "L2"))
(define ref-chain (reference (fx-chain 4)))
(define r-chain (run-async (fx-chain 4) #:seed 3))
(agrees "chain" r-chain ref-chain chain-links '(abundant . 5.0))
(check "the middle scopes hold two links each (master of one, participant of the other)"
       (every (lambda (a) (= 2 (length (cdr (assq 'links a))))) (list (cadr (cadddr r-chain)) (caddr (cadddr r-chain)))))

;; ── 3. a bad network ─────────────────────────────────────────────────────────
(display "\n── 3. delays 1 ms – 2 s, 25% lost, 25% repeated: the same answer, from every seed ──\n")
(for-each
 (lambda (seed)
   (let ((r (run-async (fx-chain 4) #:seed seed #:delay '(0.001 . 2.0) #:drop 0.25 #:dup 0.25
                       #:tick 1.0 #:horizon 3000.0)))
     (agrees (format #f "chain, seed ~a" seed) r ref-chain chain-links '(abundant . 5.0))))
 '(11 12 13 14))
(agrees "scarce pair, lossy"
        (run-async (list (fx-commune-a-scarce) (fx-commune-b)) #:seed 7 #:delay '(0.001 . 2.0)
                   #:drop 0.25 #:dup 0.25 #:tick 1.0 #:horizon 3000.0)
        ref-scarce '("flour") 0.5)

;; ── 4. an outage ─────────────────────────────────────────────────────────────
(display "\n── 4. a scope cut off for a while ──\n")
(let ((r (run-async (fx-chain 4) #:seed 5 #:outages '((2 0.5 40.0)) #:tick 1.0 #:horizon 3000.0)))
  (agrees "chain, scope 2 cut off from t=0.5 to t=40" r ref-chain chain-links '(abundant . 5.0))
  (check "the federation settled only after the scope came back" (> (cadr r) 40.0)))

;; ── 4b. a restart ─────────────────────────────────────────────────────────────
(display "\n── 4b. a scope that comes back with nothing ──\n")
;; the middle scope 1 is a participant of L0 and master of L1; its process dies
;; and returns with no state and a later epoch: its neighbours hold versions
;; it never published, and must take its new ones as newer
(define (restart-of i at epoch)
  (list i at (lambda () (make-peer (make-boundary-oracle (list-ref (fx-chain 4) i)) #:epoch epoch))))
(let ((r (run-async (fx-chain 4) #:seed 4 #:tick 1.0 #:horizon 3000.0
                    #:restarts (list (restart-of 1 6.0 1000)))))
  (agrees "chain, scope 1 restarted mid-solve" r ref-chain chain-links '(abundant . 5.0)))
(let ((r (run-async (fx-chain 4) #:seed 4 #:tick 1.0 #:horizon 3000.0
                    #:restarts (list (restart-of 1 80.0 1000) (restart-of 0 90.0 2000)))))
  (agrees "chain, scopes 1 and 0 restarted after it had settled" r ref-chain chain-links '(abundant . 5.0))
  (check "and it settled again after the second restart" (> (cadr r) 90.0)))
;; a scope that masters nothing restarted after everything is quiet: nobody is pending, so
;; it must ask for the centre it lost
(let ((r (run-async (fx-chain 4) #:seed 6 #:tick 1.0 #:horizon 3000.0
                    #:restarts (list (restart-of 3 90.0 1000)))))
  (agrees "chain, the last scope restarted after it had settled" r ref-chain chain-links '(abundant . 5.0))
  (check "and it settled again after the restart" (> (cadr r) 90.0)))

;; ── 4c. a resume ──────────────────────────────────────────────────────────────
(display "\n── 4c. a scope that comes back with what it kept ──\n")
;; the same middle scope, restarted after the federation had settled, from
;; its own `snapshot`: it stands where it stood — the versions it held are the
;; ones it ends on, nothing outranked, and the federation is final again
(let* ((recs (fx-chain 4))
       (peers (map (lambda (r) (make-peer (make-boundary-oracle r))) recs))
       (p1 (list-ref peers 1))
       (kept #f)
       (resume (lambda ()
                 (set! kept (p1 'snapshot))
                 (make-peer (make-boundary-oracle (list-ref recs 1)) #:restore kept))))
  (call-with-values (lambda () (simulate peers #:seed 4 #:tick 1.0 #:horizon 3000.0 #:restarts (list (list 1 80.0 resume))))
    (lambda (settled? time stats peers*)
      (let* ((r (list settled? time stats (map (lambda (p) (p 'attest)) peers*) peers*))
             (versions (lambda (a) (map (lambda (l) (cons (cdr (assq 'link l)) (cdr (assq 'v l)))) (cdr (assq 'links a)))))
             (kept-versions (append (map (lambda (e) (cons (car e) (list-ref (cdr e) 2))) (cdr (assq 'crossings kept)))   ; after the form and the members
                                    (map (lambda (e) (cons (car e) (list-ref (cdr e) 4))) (cdr (assq 'holders kept))))))
        (agrees "chain, scope 1 resumed from its snapshot after it had settled" r ref-chain chain-links '(abundant . 5.0))
        (check "it stands at the versions it kept"
               (every (lambda (lv) (equal? (cdr lv) (assoc-ref kept-versions (car lv))))
                      (versions (list-ref (cadddr r) 1))))
        (check "and the restored scope is done" ((list-ref peers* 1) 'done?))))))

;; ── 5. silence ───────────────────────────────────────────────────────────────
(display "\n── 5. a settled federation is silent ──\n")
(let* ((r (run-async (fx-chain 4) #:seed 2))
       (peers (list-ref r 4)))
  (check "settled" (car r))
  (check "every peer says so" (every (lambda (p) (p 'settled?)) peers))
  (check "and a tick has nothing to re-send" (every (lambda (p) (null? (p 'tick 1e6))) peers))
  (check "every link is quiet in every attestation"
         (every (lambda (a) (every (lambda (l) (cdr (assq 'quiet? l))) (cdr (assq 'links a)))) (cadddr r))))

(test-summary!)
