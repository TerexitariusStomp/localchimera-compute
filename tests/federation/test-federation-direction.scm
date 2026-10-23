;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-federation-direction.scm — which way a good crosses is the solve's to say.
;;;
;;; A commune shares a good through one column, its draw on the crossing
;;; measured from what it can give (solve/federation-solve.scm
;;; `commune->scope-record`, solver.scm `give-bound` / `offset-column`). Its
;;; flow on the good is signed — above nothing it supplies, below it draws —
;;; and nobody states which. Held here:
;;;
;;;   1. THE SAME TWO COMMUNES, THE STOCK MOVED. Built by one call, differing
;;;      only in who holds the flour: the one that holds it supplies, and with
;;;      the stock moved the flows change sign; the pull and the demand met stand.
;;;   2. A HAND-BUILT ECONOMY AND ITS TWIN. The scopes whose column can only
;;;      give or only take, and the same scopes each with a column that goes
;;;      either way: one demand met, one pull.
;;;   3. NOBODY CAN SUPPLY. Scopes that can all only draw settle at no flow,
;;;      and the dilemma names the shortfall.
;;;   4. ONE CROSSING PER COMMUNE, the same on every build, however many
;;;      places the commune has.
;;;   5. A COMMUNE LEFT ALONE gives nothing: its column leaves the crossing.
;;;   6. WHAT WAS KEPT IN ANOTHER FORM is set aside: the peer begins again under
;;;      its epoch and the good settles.
;;;   7. WHAT A COMMUNE CAN GIVE IS A WALL: a plan that gives more reads infeasible.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/federation/test-federation-direction.scm

(use-modules (playnet test harness)
             (playnet federation async)
             (playnet solve admm-link)
             ((playnet solve engine) #:select (lg cell)) ((playnet solve federation-oracle) #:select (make-boundary-oracle solve-consensus)) ((playnet solve federation-solve) #:select (commune->scope-record federated-solve federated-flows loose-gives federated-dilemma close-stranded-links))
             (playnet solve solver)
             (playnet vf schemas)
             (playnet test planner federation-wire-fixture)
             (srfi srfi-1) (ice-9 format))

(load (string-append (dirname (current-filename)) "/federation-crossing-fixture.scm"))

;; ── the communes ─────────────────────────────────────────────────────────────
;; a commune that bakes: FLOUR kg on hand, a worker, a want of WANT loaves
(define* (bakery name home flour want #:key (places (list home)))
  (commune->scope-record
   (if (> flour 0.0) (list (fx-res "flour" home flour)) '())
   (list (fx-worker (string-append "w-" name) home))
   (map (lambda (p i) (fx-place p (+ 42.70 (* 0.05 i)) 23.32)) places (iota (length places)))
   fx-bake-p fx-bake-f
   #:id name
   #:demand (list (cons (lg "bread" (cell home 0)) want))
   #:never-raw '("flour")
   #:crossing '("flour")))

(define (settle recs)
  "The coordinator over fresh oracles, with its finish → (flows met pull): the
   signed flow of each commune on flour, the mean met, the pull."
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
      (lambda (reports met rounds pulls)
        (list (map (lambda (r) (cdar (assq-ref r 'flows))) reports) met
              (cdar (hash-map->list cons pulls)) rounds)))))

;; ── 1. the stock moved ───────────────────────────────────────────────────────
(display "\n── 1. the same two communes, the stock moved ──\n")
(define (pair flour-north flour-south)
  (list (bakery "North" "n-home" flour-north 40.0) (bakery "South" "s-home" flour-south 40.0)))
(define north-holds (settle (pair 60.0 0.0)))
(define south-holds (settle (pair 0.0 60.0)))
(format #t "   North holds 60: flows ~a  met ~,2f  pull ~,4f  (~a rounds)~%" (car north-holds) (cadr north-holds) (caddr north-holds) (cadddr north-holds))
(format #t "   South holds 60: flows ~a  met ~,2f  pull ~,4f  (~a rounds)~%" (car south-holds) (cadr south-holds) (caddr south-holds) (cadddr south-holds))
(let ((n1 (car (car north-holds))) (s1 (cadr (car north-holds)))
      (n2 (car (car south-holds))) (s2 (cadr (car south-holds))))
  (check "the commune that holds the flour supplies it, the other draws" (and (> n1 1.0) (< s1 -1.0)))
  (check "with the stock moved, each flow has changed its sign" (and (< n2 -1.0) (> s2 1.0)))
  (check "what one supplies is what the other draws, either way"
         (and (< (abs (+ n1 s1)) 1e-2) (< (abs (+ n2 s2)) 1e-2)))
  (check "the flows are each other's, exchanged" (and (< (abs (- n1 s2)) 0.5) (< (abs (- s1 n2)) 0.5)))
  (check "sixty for a want of eighty: each commune is left thirty, so thirty cross"
         (< (abs (- n1 30.0)) 1.0))
  (check "the demand met stands" (< (abs (- (cadr north-holds) (cadr south-holds))) 0.1))
  (check "the pull stands" (< (abs (- (caddr north-holds) (caddr south-holds)))
                              (* 0.02 (abs (caddr north-holds))))))

;; ── 2. the twin ──────────────────────────────────────────────────────────────
(display "\n── 2. a hand-built economy and its twin ──\n")
;; the fixture's scope with its column turned into a draw that goes either way:
;; the column enters the grain balance, measured from what the scope can give
(define (twin-record spec)
  (let* ((forms (scope-forms 0 0 (list-ref spec 1) (list-ref spec 2) -1))
         (G (call-with-values (lambda () (give-bound forms 3 0)) (lambda (G culprit) G))))
    (list (cons 'forms (offset-column forms 0 G))
          (cons 'labform (list (cons 1 0.3) (cons 2 0.5)))
          (cons 'x0 (vector (+ 0.1 G) 0.1 0.1))
          (cons 'crossings (list (cons* 0 "G" -1 G))))))
(for-each
 (lambda (label soil)
   (let* ((specs (economy label soil))
          (sided (settle (map scope-record specs)))
          (twin (settle (map twin-record specs))))
     (format #t "   ~a ×~a  sided: met ~,2f pull ~,4f   twin: met ~,2f pull ~,4f~%      sided flows ~a~%      twin flows  ~a~%"
             label soil (cadr sided) (caddr sided) (cadr twin) (caddr twin) (car sided) (car twin))
     (check (format #f "~a ×~a: one demand met" label soil) (< (abs (- (cadr sided) (cadr twin))) 0.5))
     (check (format #f "~a ×~a: in the twin, what is supplied is what is drawn" label soil)
            (< (abs (fold + 0.0 (car twin))) 1e-2))
     (when (< soil 1.0)
       (check (format #f "~a ×~a: one pull (within 5%)" label soil)
              (< (abs (- (caddr sided) (caddr twin))) (* 0.05 (abs (caddr sided)))))
       (check (format #f "~a ×~a: each scope's flow is the one it had (within 2% of the largest)" label soil)
              (let ((top (apply max (map abs (car sided)))))
                (every (lambda (a b) (< (abs (- a b)) (* 0.02 top))) (car sided) (car twin)))))))
 '(one-supplies two-supply two-and-two two-and-two)
 '(1.2 1.2 1.2 0.35))

;; ── 3. nobody can supply ─────────────────────────────────────────────────────
(display "\n── 3. a good every scope can only draw ──\n")
(let* ((specs '(("baker-1" 42.0 90.0 -1) ("baker-2" 42.0 90.0 -1)))
       (r (settle (map scope-record specs))))
  (format #t "   two bakers, no granary: flows ~a  met ~,2f  pull ~,4f~%" (car r) (cadr r) (caddr r))
  (check "nothing crosses" (every (lambda (y) (< (abs y) 1e-2)) (car r)))
  (check "the pull is a number" (and (real? (caddr r)) (< (abs (caddr r)) +inf.0))))
(let* ((recs (list (bakery "East" "e-home" 0.0 40.0) (bakery "West" "w-home" 0.0 40.0)))
       (dilemma (federated-dilemma recs (lambda (sid) '())))
       (flour (cdr (assoc "flour" dilemma))))
  (format #t "   two communes that hold no flour and want eighty loaves: ~s~%" dilemma)
  (check "the dilemma names the shortfall by quantity: eighty asked, none held"
         (list (assq-ref flour 'verdict) (assq-ref flour 'need) (assq-ref flour 'stock))
         '(shortfall 80.0 0.0))
  (check "neither can give the flour" (map (lambda (r) (assq-ref r 'gives)) recs)
         '((("flour" . 0.0)) (("flour" . 0.0)))))

;; ── 4. one crossing per commune ──────────────────────────────────────────────
(display "\n── 4. a commune of several places has one crossing ──\n")
(let ((a (bakery "Wide" "a-home" 300.0 5.0 #:places '("a-home" "a-field" "a-yard")))
      (b (bakery "Wide" "a-home" 300.0 5.0 #:places '("a-home" "a-field" "a-yard"))))
  (format #t "   crossings ~s~%" (assq-ref a 'crossings))
  (check "three places, one crossing column" (length (assq-ref a 'crossings)) 1)
  (check "the same column on every build" (assq-ref a 'crossings) (assq-ref b 'crossings))
  (check "it can give what it holds" (cdddr (car (assq-ref a 'crossings))) 300.0)
  (let ((r (settle (list a (bakery "Table" "t-home" 0.0 40.0)))))
    (format #t "   with a commune that draws: flows ~a  met ~,2f~%" (car r) (cadr r))
    (check "and the two settle: the want is met by what crosses"
           (and (> (cadr r) 98.0) (> (car (car r)) 39.0) (< (abs (fold + 0.0 (car r))) 1e-2)))))

;; ── 5. left alone ────────────────────────────────────────────────────────────
(display "\n── 5. a commune whose good nobody else shares ──\n")
(let* ((alone (car (close-stranded-links (list (bakery "Granary" "g-home" 300.0 5.0)))))
       (o (make-boundary-oracle alone)))
  (o 'solve! '() 1.0)
  (check "its column has left the crossing" (assq-ref alone 'crossings) '())
  (check "its oracle shares nothing" (o 'links) '())
  (check "and its own want is met from its own flour" (> (o 'met) 99.0)))
(let ((both (close-stranded-links (list (bakery "Granary" "g-home" 300.0 5.0) (bakery "Table" "t-home" 0.0 40.0)))))
  (check "two that share the good keep their crossings"
         (map (lambda (r) (length (assq-ref r 'crossings))) both) '(1 1)))

;; ── 6. kept in another form ──────────────────────────────────────────────────
(display "\n── 6. a snapshot kept in another form, beside a live neighbour ──\n")
(let* ((recs (lambda () (list (bakery "Granary" "g-home" 20.0 5.0) (bakery "Table" "t-home" 0.0 40.0))))
       (peers (federation-of (map make-boundary-oracle (recs))))
       (granary (car peers))
       (resume (lambda ()
                 ;; what the granary kept, as a peer of another form would have written it
                 (let ((kept (filter (lambda (kv) (not (eq? (car kv) 'form))) (granary 'snapshot))))
                   (check "a snapshot that names no form does not stand" (snapshot-stands? kept) #f)
                   (make-peer (make-boundary-oracle (car (recs)))
                              #:mastering '("flour") #:restore kept #:epoch 1000)))))
  (call-with-values (lambda () (simulate peers #:seed 5 #:tick 1.0 #:horizon 3000.0
                                         #:restarts (list (list 0 60.0 resume))))
    (lambda (settled? time stats peers*)
      (let* ((cert (assemble-attestations (map (lambda (p) (p 'attest)) peers*)))
             (row (car (assq-ref ((car peers*) 'attest) 'links))))
        (format #t "   settled ~a at t=~,1f  met ~,2f  consensus ~,5f  the granary's version ~a~%"
                settled? time (assq-ref cert 'met) (assq-ref cert 'consensus) (assq-ref row 'v))
        (check "the federation settles again" settled?)
        (check "the good began again under its epoch: its versions outrank the ones before"
               (>= (assq-ref row 'v) 1000))
        (check "and what is supplied is what is drawn" (< (assq-ref cert 'consensus) 1e-3))
        (check "every commune's floors close on its final plan"
               (and (assq-ref cert 'final?) (assq-ref cert 'feasible?)))))))
(let ((m '((kind . flow) (link . "flour") (from . #f) (v . 3) (x . 40.0))))
  (check "a message that names no form is dropped: a magnitude is no signed flow"
         (let ((p (car (federation-of (map make-boundary-oracle
                                           (list (bakery "Granary" "g-home" 20.0 5.0) (bakery "Table" "t-home" 0.0 40.0)))))))
           (p 'start 0.0)
           (p 'deliver m 1.0))
         '()))

;; ── 7. what a commune can give is a wall ─────────────────────────────────────
(display "\n── 7. a plan that gives more than the commune can ──\n")
(let* ((rec (bakery "Granary" "g-home" 300.0 5.0))
       (o (make-boundary-oracle rec))
       (col (car (car (assq-ref rec 'crossings))))
       (forms (flatten (world-forms (assq-ref rec 'forms))))
       (lab (assq-ref rec 'labform)))
  (o 'solve! '(("flour" . 40.0)) 4.0)
  (let* ((x (let ((v (vector-copy (o 'plan))))          ; as the kernel holds it: the draw, measured from 300
              (vector-set! v col (+ (vector-ref v col) 300.0)) v))
         (given (- 300.0 (vector-ref x col)))
         (over (let ((v (vector-copy x))) (vector-set! v col -0.3) v)))
    (format #t "   it gives ~,2f of 300; a plan giving 300.3 stands ~,1f below the column's wall~%" given 0.3)
    (check "its plan is feasible" (assq-ref (kkt-report forms lab x) 'feasible?))
    (check "one that gives a thousandth more than it can is not"
           (not (assq-ref (kkt-report forms lab over) 'feasible?)))))

;; ── 8. a give-bound far above what crosses ──────────────────────────────────
(display "\n── 8. a loose give-bound is said ──\n")
(let ((recs (list (bakery "Granary" "g-home" 300.0 5.0) (bakery "Table" "t-home" 0.0 40.0))))
  (call-with-values (lambda () (federated-solve recs #:iters 200))
    (lambda (plans met rounds pulls)
      (let* ((crossed (fold (lambda (rec plan a)
                              (let ((y (assoc-ref (federated-flows rec plan) "flour")))
                                (if (> y 0.0) (+ a y) a)))
                            0.0 recs plans))
             ;; the same records, the granary's bound read a million times over
             (far (cons (map (lambda (kv)
                               (if (eq? (car kv) 'gives)
                                   (cons 'gives (map (lambda (g) (cons (car g) (* 1e6 (cdr g)))) (cdr kv)))
                                   kv))
                             (car recs))
                        (cdr recs)))
             (named (loose-gives far plans)))
        (format #t "   crossed ~,2f kg; a bound of 300 kg passes ~,4f kg as noise~%" crossed (* 3e-5 300.0))
        (check "a commune that can give what it holds is named by nobody" (loose-gives recs plans) '())
        (check "a bound a million times the stock names its commune and its good"
               (map (lambda (r) (list (car r) (cadr r))) named) '(("Granary" "flour")))
        (check "and says the noise in the good's unit, above the flow it is read against"
               (let ((r (car named))) (> (list-ref r 4) (* 1e-2 (list-ref r 3)))))
        (check "the threshold is the caller's: at a share of everything nothing is loose"
               (loose-gives far plans #:share 1e9) '())))))

(test-summary!)
