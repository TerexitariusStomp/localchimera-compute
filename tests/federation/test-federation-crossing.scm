;;; test-federation-crossing.scm — a good several scopes supply and several draw:
;;; ONE pull for it, settled between its participants with no coordinator.
;;;
;;; A boundary link joins two scopes; a CROSSING joins any number, and the claim
;;; under test is that the peers' settled answer is the economy's optimum however
;;; the participants divide into those that supply and those that draw. The
;;; reference is the monolith: every scope's program written into ONE record,
;;; the boundary replaced by the single row that says what is drawn is at most
;;; what is supplied, solved once by the same kernel.
;;;
;;;   1. THE STEP — crossing-step with two participants IS link-step, and for any
;;;      number its flows sum to nothing and its pull is one number.
;;;   2. ONE SUPPLIES, TWO DRAW — a granary supplying two bakers.
;;;   3. TWO SUPPLY, ONE DRAWS — two granaries supplying one baker.
;;;   4. TWO AND TWO — the general crossing; also under a bad network, and with
;;;      ρ adapting or held fixed (the same optimum either way).
;;;   5. SCARCITY — what can be supplied falls short of what is asked: the
;;;      crossing settles at a pull, and those that draw are held to what is
;;;      supplied, pro rata.
;;;   6. THE ROUNDS — the synchronous coordinator (over oracles) and the monolith's
;;      rounds (solve-decomposed) take the same crossings, and land on the same
;;      optimum and the same pull as the peers.
;;   7. NAMES — two peers claiming to master one good are refused at wiring.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/federation/test-federation-crossing.scm

(use-modules (playnet solve federation-solve))
(use-modules (playnet test harness)
             (playnet federation async)
             (playnet solve admm-link)
             ((playnet solve decomposed) #:select (solve-decomposed)) ((playnet solve federation-oracle) #:select (make-boundary-oracle solve-consensus))
             (playnet solve solver)
             (srfi srfi-1) (ice-9 format))

(load (string-append (dirname (current-filename)) "/federation-crossing-fixture.scm"))

;; ── 1. the step ─────────────────────────────────────────────────────────────
(format #t "~%── 1. the crossing step ──~%")
(let ((worst 0.0))
  ;; the two-party step written out from its definition — over-relax each flow toward
  ;; z, z their mean, each dual moved by what its side's flow left over
  (define (by-hand z us ur xe xi alpha)
    (let* ((eh (+ (* alpha xe) (* (- 1.0 alpha) z)))
           (rh (+ (* alpha xi) (* (- 1.0 alpha) z)))
           (z* (/ (+ eh rh) 2.0)))
      (list z* (+ us (- eh z*)) (+ ur (- rh z*)))))
  (for-each
   (lambda (alpha)
     (for-each
      (lambda (t)
        (let* ((z (* 3.0 (sin t))) (us (cos (* 2.0 t))) (xe (+ 5.0 (* 4.0 (cos t)))) (xi (- 5.0 (* 3.0 (sin (* 3.0 t)))))
               (want (by-hand z us (- us) xe xi alpha)))
          (call-with-values (lambda () (crossing-step (list z (- z)) us (list xe (- xi)) alpha))
            (lambda (zs u1)
              (call-with-values (lambda () (link-step z us (- us) xe xi alpha))
                (lambda (z1 us1 ur1)
                  (set! worst (max worst
                                   (abs (- (car zs) (car want))) (abs (+ (cadr zs) (car want)))
                                   (abs (- u1 (cadr want))) (abs (+ u1 (caddr want)))
                                   (abs (- z1 (car want))) (abs (- us1 (cadr want))) (abs (- ur1 (caddr want)))))))))))
      (iota 25 0.3 0.7)))
   '(1.0 1.4 1.6 1.9))
  (check "with one that gives and one that takes crossing-step and link-step are the definition's own step" (< worst 1e-12)))
(let ((sums '()) (spread 0.0))
  (for-each
   (lambda (n)
     (let* ((zs (map (lambda (i) (sin (* 1.7 i))) (iota n)))
            (ys (map (lambda (i) (+ 2.0 (cos (* 2.3 i)))) (iota n))))
       (call-with-values (lambda () (crossing-step zs 0.4 ys 1.6))
         (lambda (zs* u*)
           (set! sums (cons (abs (fold + 0.0 zs*)) sums))))))
   '(2 3 5 8))
  (check "the agreed flows of a crossing sum to nothing, for any number of participants"
         (every (lambda (s) (< s 1e-12)) sums)))

;; peers over the scopes; the first whose column gives masters the good and knows the rest
(define* (peer-for specs i #:key (adapt #t) (damping 1.0) (rho 4.0) (epoch 0))
  (let* ((master (find (lambda (sp) (= (list-ref sp 3) 1)) specs))
         (sp (list-ref specs i)) (mine? (eq? sp master)))
    (make-peer (make-boundary-oracle (scope-record sp))
               #:name (car sp) #:adapt adapt #:damping damping #:rho rho #:epoch epoch
               #:mastering (if mine? '("G") '())
               #:members (if mine?
                             (list (cons "G" (map car (filter (lambda (o) (not (eq? o sp))) specs))))
                             '()))))
(define* (peers-of specs #:key (adapt #t) (damping 1.0) (rho 4.0))
  (map (lambda (i) (peer-for specs i #:adapt adapt #:damping damping #:rho rho)) (iota (length specs))))

(define (run specs . sim-opts)
  (let ((peers (peers-of specs)))
    (call-with-values (lambda () (apply simulate peers sim-opts))
      (lambda (settled? time stats peers)
        (list settled? time stats (map (lambda (p) (p 'attest)) peers) peers)))))

(define (cert-of r) (assemble-attestations (cadddr r)))
(define (ref k c) (cdr (assq k c)))
(define (pull-of c) (let ((p (assoc "G" (ref 'pulls c)))) (if p (cdr p) 0.0)))

(define (holds label specs r ref-met)
  (let ((c (cert-of r)))
    (format #t "   ~a: settled ~a at t=~,1f  delivered ~a  met ~,2f (monolith ~,2f)  λ ~,4f  balance ~,6f  overdraw ~,6f~%"
            label (car r) (cadr r) (assq-ref (caddr r) 'delivered) (ref 'met c) ref-met (pull-of c)
            (ref 'consensus c) (ref 'overdraw c))
    (check (string-append label ": the federation settled") (car r))
    (check (string-append label ": the participants of the good agree on a version") (ref 'settled? c))
    (check (string-append label ": what is supplied is what is drawn (to 1e-3)")
           (< (ref 'consensus c) 1e-3))
    (check (string-append label ": every scope made its exact local solve and was held to its flow")
           (ref 'final? c))
    (check (string-append label ": every scope's floors close on its final plan") (ref 'feasible? c))
    (check (string-append label ": nothing is drawn beyond what is supplied (to 1e-4)")
           (< (ref 'overdraw c) 1e-4))
    (check (string-append label ": the demand met is the monolith's (within 0.3 points)")
           (< (abs (- (ref 'met c) ref-met)) 0.3))
    c))

;; ── 2–4. the shapes of a crossing ─────────────────────────────────────────────
(for-each
 (lambda (shape title)
   (format #t "~%── ~a ──~%" title)
   (let* ((specs (economy shape 1.2))
          (mono (monolith-met specs)))
     (holds (symbol->string shape) specs (run specs) mono)))
 '(one-supplies two-supply two-and-two)
 '("2. one supplies, two draw" "3. two supply, one draws" "4. two supply, two draw"))

(format #t "~%── 4. two and two: a bad network, ρ adapting and ρ held ──~%")
(let* ((specs (economy 'two-and-two 1.2)) (mono (monolith-met specs)))
  (for-each
   (lambda (seed)
     (holds (format #f "bad network, seed ~a" seed) specs
            (run specs #:seed seed #:delay '(0.01 . 1.0) #:drop 0.2 #:dup 0.2 #:horizon 400.0) mono))
   '(3 11))
  (let ((fixed (let ((peers (peers-of specs #:adapt #f)))
                 (call-with-values (lambda () (simulate peers))
                   (lambda (settled? time stats peers)
                     (list settled? time stats (map (lambda (p) (p 'attest)) peers) peers)))))
        (adaptive (run specs)))
    (holds "ρ held fixed" specs fixed mono)
    (check "ρ adapting and ρ held reach the same pull (within 5%)"
           (let ((a (pull-of (cert-of adaptive))) (f (pull-of (cert-of fixed))))
             (< (abs (- a f)) (+ 1e-3 (* 0.05 (abs f))))))
    (format #t "   messages: ρ adapting ~a, ρ held ~a~%"
            (assq-ref (caddr adaptive) 'delivered) (assq-ref (caddr fixed) 'delivered)))
  (let ((damped (let ((peers (peers-of specs #:damping 0.6)))
                  (call-with-values (lambda () (simulate peers #:seed 5 #:delay '(0.01 . 0.5) #:drop 0.1 #:horizon 400.0))
                    (lambda (settled? time stats peers)
                      (list settled? time stats (map (lambda (p) (p 'attest)) peers) peers))))))
    (holds "damped (η = 0.6) under delay and loss" specs damped mono)))

;; ── 5. scarcity ─────────────────────────────────────────────────────────────
(format #t "~%── 5. scarcity: the good settles at a pull ──~%")
(let* ((specs (economy 'two-and-two 0.35)) (mono (monolith-met specs))
       (r (run specs)) (c (holds "scarce" specs r mono)))
  (check "scarce: the pull is not zero" (> (abs (pull-of c)) 0.1))
  (check "scarce: the demand met falls short of full" (< (ref 'met c) 99.0))
  (check "scarce: the pull is one number — every participant reads the master's"
         (let ((rows (append-map (lambda (a) (cdr (assq 'links a))) (cadddr r))))
           (every (lambda (row)
                    (< (abs (- (cdr (assq 'pull row)) (pull-of c)))
                       (+ 1e-3 (* 0.02 (abs (pull-of c))))))
                  rows))))

;; ── 7. the penalty weight ───────────────────────────────────────────────────
(format #t "~%── 7. a badly scaled ρ ──~%")
(define (rho-of-master r)
  (let ((row (find (lambda (l) (cdr (assq 'master? l)))
                   (append-map (lambda (a) (cdr (assq 'links a))) (cadddr r)))))
    (cdr (assq 'rho row))))
(let* ((specs (economy 'two-and-two 0.35)) (mono (monolith-met specs))
       (run-rho (lambda (rho0 adapt)
                  (let* ((peers (peers-of specs #:adapt adapt #:rho rho0))
                         (r (call-with-values (lambda () (simulate peers #:horizon 300.0))
                              (lambda (settled? time stats peers)
                                (list settled? time stats (map (lambda (p) (p 'attest)) peers) peers))))
                         (c (cert-of r)))
                    (format #t "   ρ0 ~a, adapt ~a: settled ~a at t=~,1f  delivered ~a  met ~,2f  λ ~,4f  ρ ended ~,3f~%"
                            rho0 adapt (car r) (cadr r) (assq-ref (caddr r) 'delivered) (ref 'met c) (pull-of c) (rho-of-master r))
                    (list r c)))))
  (define results
    (map (lambda (rho0) (list rho0 (run-rho rho0 #t) (run-rho rho0 #f)))
         '(0.02 4.0 2000.0)))
  (check "whatever ρ the goods start at, adapting or not, the federation settles at the monolith's optimum"
         (every (lambda (row)
                  (every (lambda (rc) (and (car (car rc)) (< (abs (- (ref 'met (cadr rc)) mono)) 0.3)))
                         (cdr row)))
                results))
  (check "and at one pull (within 1%)"
         (let ((ps (append-map (lambda (row) (map (lambda (rc) (pull-of (cadr rc))) (cdr row))) results)))
           (< (- (apply max ps) (apply min ps)) (* 0.01 (abs (car ps))))))
  (let ((end (lambda (rho0 adapt) (rho-of-master (car ((if adapt cadr caddr) (assv rho0 results))))))
        (sent (lambda (rho0 adapt) (assq-ref (caddr (car ((if adapt cadr caddr) (assv rho0 results)))) 'delivered))))
    (check "a ρ far too large is brought down by its own master (2000 → under 200)" (< (end 2000.0 #t) 200.0))
    (check "a ρ far too small is brought up (0.02 → at least four times that)" (>= (end 0.02 #t) 0.08))
    (check "a ρ held fixed stays where it began" (= (end 2000.0 #f) 2000.0))
    (check "adapting costs no more messages than not, from a ρ far too large"
           (<= (sent 2000.0 #t) (sent 2000.0 #f)))))

;; ── 8. outages and restarts ─────────────────────────────────────────────────
(format #t "~%── 8. a participant cut off, a participant and the master restarted ──~%")
(let* ((specs (economy 'two-and-two 1.2)) (mono (monolith-met specs)))
  (holds "a baker cut off for 25 s" specs
         (run specs #:outages '((2 1.0 26.0)) #:horizon 400.0) mono)
  (holds "a baker restarted mid-solve" specs
         (let ((peers (peers-of specs)))
           (call-with-values
               (lambda () (simulate peers #:restarts (list (list 3 0.8 (lambda () (peer-for specs 3 #:epoch 1000)))) #:horizon 400.0))
             (lambda (settled? time stats peers)
               (list settled? time stats (map (lambda (p) (p 'attest)) peers) peers))))
         mono)
  (holds "the master restarted after it had settled" specs
         (let ((peers (peers-of specs)))
           (call-with-values
               (lambda () (simulate peers #:restarts (list (list 0 40.0 (lambda () (peer-for specs 0 #:epoch 5000)))) #:horizon 600.0))
             (lambda (settled? time stats peers)
               (list settled? time stats (map (lambda (p) (p 'attest)) peers) peers))))
         mono))

;; ── 9. a violent network, many seeds ────────────────────────────────────────
(format #t "~%── 9. delays over three orders of magnitude, 30% loss and duplication ──~%")
(let* ((specs (economy 'two-and-two 0.35)) (mono (monolith-met specs))
       (rows (map (lambda (seed)
                    (let* ((r (run specs #:seed seed #:delay '(0.001 . 3.0) #:drop 0.3 #:dup 0.3 #:horizon 900.0))
                           (c (cert-of r)))
                      (format #t "   seed ~a: settled ~a at t=~,1f  delivered ~a dropped ~a  met ~,2f  λ ~,4f~%"
                              seed (car r) (cadr r) (assq-ref (caddr r) 'delivered) (assq-ref (caddr r) 'dropped)
                              (ref 'met c) (pull-of c))
                      (cons r c)))
                  '(1 2 3 4 5 6 7 8))))
  (check "every seed settles" (every (lambda (rc) (car (car rc))) rows))
  (check "every seed lands on the monolith's demand met (within 0.3 points)"
         (every (lambda (rc) (< (abs (- (ref 'met (cdr rc)) mono)) 0.3)) rows))
  (check "every seed lands on one pull (within 2%)"
         (let ((ps (map (lambda (rc) (pull-of (cdr rc))) rows)))
           (< (- (apply max ps) (apply min ps)) (* 0.02 (abs (car ps))))))
  (check "every seed finishes with the floors closed and nothing overdrawn"
         (every (lambda (rc) (and (ref 'final? (cdr rc)) (ref 'feasible? (cdr rc)) (< (ref 'overdraw (cdr rc)) 1e-4))) rows)))

;; ── 10. the synchronous loops ───────────────────────────────────────────────
(format #t "~%── 10. the coordinator's rounds and the monolith's rounds take crossings too ──~%")
(for-each
 (lambda (mult)
   (for-each
    (lambda (shape)
      (let* ((specs (economy shape mult)) (mono (monolith-met specs))
             (peers-cert (cert-of (run specs)))
             (recs (map scope-record specs))
             (oracles (map make-boundary-oracle recs))
             (label (format #f "~a, soil ×~a" shape mult)))
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
          (lambda (reports met rounds pulls)
            (let ((pull (hash-ref pulls "G" 0.0)))
              (format #t "   ~a — coordinator: met ~,2f in ~a rounds  λ ~,4f  (monolith ~,2f, peers λ ~,4f)~%"
                      label met rounds pull mono (pull-of peers-cert))
              (check (string-append label ": the coordinator lands on the monolith's demand met") (< (abs (- met mono)) 0.5))
              (check (string-append label ": and on the peers' pull")
                     (< (abs (- pull (pull-of peers-cert))) (+ 0.02 (* 0.03 (abs pull))))))))
        (call-with-values (lambda () (solve-decomposed recs #:iters 400))
          (lambda (plans met rounds pulls)
            (let ((pull (hash-ref pulls "G" 0.0)))
              (format #t "   ~a — rounds:      met ~,2f in ~a rounds  λ ~,4f~%" label met rounds pull)
              (check (string-append label ": the monolith's rounds land on its demand met") (< (abs (- met mono)) 0.5))
              (check (string-append label ": and on the peers' pull")
                     (< (abs (- pull (pull-of peers-cert))) (+ 0.02 (* 0.03 (abs pull))))))))))
    '(one-supplies two-supply two-and-two)))
 '(1.2 0.35))

;; ── 6. names ────────────────────────────────────────────────────────────────
(format #t "~%── 6. wiring ──~%")
(let* ((specs (economy 'two-supply 1.2))
       (peers (map (lambda (sp) (make-peer (make-boundary-oracle (scope-record sp)) #:name (car sp))) specs)))
  (check "two peers that both master the good are refused at wiring"
         (catch #t (lambda () (simulate peers) #f) (lambda _ #t))))

(test-summary!)
