;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-box-propagation.scm — the rail on interval propagation, measured.
;;;
;;; `column-caps` (solver.scm) propagates upper bounds to a fixpoint: a row
;;; bounds each of its negative columns once every positive one is capped, which
;;; is what lets it see an activity bounded by a supply that is itself bounded
;;; (0.3·x ≤ hours ≤ 20) — the shape no single row expresses. The loop is railed
;;; at *box-prop-rounds* so it cannot run away.
;;;
;;; A rail nobody watches is a silent approximation. It is sound at any depth —
;;; each round only lowers caps, so stopping early leaves a LOOSER bound, never
;;; a wrong one — but a program cut off early can read as unbounded when it is
;;; bounded, and then `tmin-for` declines to derive its floor and the plan keeps
;;; the overproduction residue. So the question is whether the rail ever binds.
;;;
;;; MEASURED (2026-08-13) by raising the rail to 1000 and shouting whenever any
;;; program used more than 8 rounds, across the whole test suite — every planner
;;; fixture in the repo, ~460 files: ZERO programs exceeded 8. The reason shows
;;; in the shapes below: these programs are bounded by budget rows (a worker's
;;; hours, a cell's cap) that carry every activity they bound in ONE row, so the
;;; fixpoint is reached almost immediately and does not deepen with the chain.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/solve/test-box-propagation.scm

(use-modules (playnet solve decomposed) (playnet test planner prelude)
             (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (srfi srfi-1)
             (ice-9 format))

(define (measure thunk)
  "→ (rounds railed? unbounded-columns) for the program THUNK builds."
  (thunk)
  (call-with-values build-located
    (lambda (forms lf ncol cols goods raws idx)
      (let* ((C (flatten forms))
             (u (column-caps C ncol)))
        (list *box-prop-last-rounds* *box-prop-last-railed?*
              (let lp ((j 0) (c 0))
                (if (= j ncol) c
                    (lp (+ j 1) (if (= (vector-ref u j) +inf.0) (+ c 1) c)))))))))

;; A ROSTER: one task, N people who could do it — supply → activity, one hop.
(define (roster n)
  (lambda ()
    (declare-world! #:places '("flat")
                    #:templates (list (list "binrun" '(("binsdone" . 1.0)) '() 0.3))
                    #:workers
                      (map (lambda (i) (list (format #f "p~a" i) '("cleaning") (cell "flat" 0) 20.0))
                           (iota n 1)))
    (hash-set! *proc-skill* "binrun" "cleaning")
    (hash-set! *demand* (lg "binsdone" (cell "flat" 0)) 1.0)))

;; A DEEP CHAIN: g0 → g1 → … → gK, each made from the last. The shape the rail
;; was written to be afraid of — a bound that must walk K links to the far end.
(define (chain K)
  (lambda ()
    (declare-world! #:places '("p")
                    #:templates
                      (cons (list "s0" '(("g0" . 1.0)) '() 0.1)
                            (map (lambda (i) (list (format #f "s~a" i)
                                                   (list (cons (format #f "g~a" i) 1.0))
                                                   (list (cons (format #f "g~a" (- i 1)) 1.0)) 0.1))
                                 (iota K 1)))
                    #:workers (list (list "w" '("sk") (cell "p" 0) 100.0)))
    (for-each (lambda (t) (hash-set! *proc-skill* (car t) "sk")) *templates*)
    (hash-set! *demand* (lg (format #f "g~a" K) (cell "p" 0)) 1.0)))

(define (pad s w) (let ((t (format #f "~a" s)))
                    (string-append t (make-string (max 0 (- w (string-length t))) #\space))))

(display "\n── how many rounds does propagation actually use? ──\n")
(format #t "  (rail = ~a)\n" *box-prop-rounds*)

(define shapes
  (append (map (lambda (n) (cons (format #f "roster ~a" n) (roster n))) '(1 10 60))
          (map (lambda (k) (cons (format #f "chain K=~a" k) (chain k))) '(2 5 10 20 40 80))))

(define measured
  (map (lambda (sh)
         (let ((r (measure (cdr sh))))
           (format #t "  ~a rounds=~2a  railed=~a  unbounded=~a\n"
                   (pad (car sh) 12) (car r) (cadr r) (caddr r))
           r))
       shapes))

(check "the rail never binds — every program reaches its fixpoint inside it"
       (not (any cadr measured)))
(check "…with room to spare, so it is a rail and not a working limit"
       (every (lambda (r) (< (car r) *box-prop-rounds*)) measured))
;; DEPTH DOES NOT DRIVE IT. The rail's premise was that a longer chain needs
;; more rounds. It does not: a budget row bounds every activity it covers at
;; once, so an 80-link chain converges in the same rounds as a 2-link one.
(check "chain depth does not deepen the propagation"
       (let ((deep (list-ref measured (- (length measured) 1)))
             (shallow (list-ref measured 3)))
         (<= (car deep) (car shallow))))
;; and the whole point of the pass: these programs come out BOUNDED, which is
;; what licenses `tmin-for` to derive their floor.
(check "every column is bounded, which is what licenses the derived floor"
       (every (lambda (r) (= 0 (caddr r))) measured))

(format #t "\n  0 of ~a shapes reach the rail.~%" (length measured))

;;; ── …AND WHERE IT HONESTLY READS UNBOUNDED ──────────────────────────────────
;;; The shapes above all come out bounded, so they all get a derived floor. The
;;; case that does not is the federated one, and it is worth pinning rather than
;;; describing: a scope's IMPORT column is a free source, and nothing inside that
;;; scope's own program bounds it. No amount of propagation invents a bound —
;;; that is the honest answer, and it is what keeps the certificate's curvature
;;; branch from being spent (solver.scm, `tmin-for`).
;;;
;;; MEASURED: exactly ONE scope per cover is bounded — the granary/root, the
;;; only one with no import — and it is the only one that gets a derived floor.
;;;
;;;     star  S=8  : 1/8  bounded · floors 0.00042…0.00500
;;;     star  S=16 : 1/16 bounded · floors 0.00025…0.00500
;;;     chain S=8  : 1/8  bounded · floors 0.00083…0.00500
;;;     chain S=16 : 1/16 bounded · floors 0.00083…0.00500
;;;
;;; So the asymmetry recorded in open-threads §7.3 is exact: in a cover of S
;;; scopes, S−1 of them keep the shipped floor and the overproduction that comes
;;; with it, while a monolithic program of the same shape would derive one. That
;;; is the price of the certificate on the federated path, and it is a price —
;;; not a free win — which is why it is asserted here rather than assumed.
(primitive-load "module/playnet/test/planner/federated-fixtures.scm")

(display "\n── the federated case: bounded scopes are the exception ──\n")
(define fed
  (map (lambda (cs)
         (let* ((mk (if (eq? 'star (car cs)) fx-star fx-chain))
                (scopes (mk (cdr cs)))
                (bs (map (lambda (sc) (forms-box-bounded? (assq-ref sc 'forms))) scopes))
                (ts (map (lambda (sc) (tmin-for (assq-ref sc 'forms))) scopes)))
           (format #t "  ~a S=~2a : ~a/~a bounded · floors ~,5f…~,5f\n"
                   (pad (car cs) 5) (cdr cs) (count (lambda (b) b) bs) (length bs)
                   (apply min ts) (apply max ts))
           (list (car cs) (cdr cs) bs ts)))
       '((star . 8) (star . 16) (chain . 8) (chain . 16))))

(check "a federated cover has exactly one bounded scope — the one with no import"
       (every (lambda (r) (= 1 (count (lambda (b) b) (caddr r)))) fed))
(check "…so S−1 scopes keep the shipped floor, and one derives a tighter one"
       (every (lambda (r) (and (= *kern-tmin-default* (apply max (cadddr r)))
                               (< (apply min (cadddr r)) *kern-tmin-default*)))
              fed))

(check-done "  The rail is measured, not assumed — and where a program honestly reads~%  unbounded, it is the federated import column and nothing else.~%")
