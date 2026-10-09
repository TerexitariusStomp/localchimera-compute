;;; test-property-enact.scm — a plan enacted against the books conserves every good.
;;;
;;; Ten seeded worlds (two or three places, a chain of three recipes that make one or
;;; two goods each, random stocks of the first two goods, a random demand): the solve
;;; plans, its material rows are enacted against a fresh observer in the order they
;;; were emitted and in reverse, and for every good what is on hand afterwards is
;;; what was held, plus what the rows produced, less what they consumed — and every
;;; row is served, none left over.
;;;
;;; Goods that MOVE are in: a random subset of the specs is declared #:movable, every
;;; pair of places neighbours, τ > 0. A carry costs its τ·km in every labour model
;;; (engine labform carry-terms) and opposing carries of one good between one pair of
;;; cells are netted before rows are emitted (net-carries), so the rows hold a pickup
;;; to its dropoff and the books keep every one. Before 2026-10-09 the carries were free
;;; under workers and the solve circulated tens of thousands of units the books refused.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-property-enact.scm
(use-modules (playnet test harness) (playnet test books)
             (playnet planner vf schemas) (srfi srfi-1) (srfi srfi-11)
             (playnet planner scope live)
             (playnet planner solve engine) (playnet planner solve compile) (playnet planner solve solver)
             (goblins) (goblins vat) (goblins persistence-store memory) (goblins utils hashmap)
             (ice-9 format))
(setvbuf (current-output-port) 'none)
(define E (resolve-module '(playnet planner solve engine)))
(define N 10)
(define SEED0 1)

(define (rnd st n) (random n st))
(define (pick st l) (list-ref l (rnd st (length l))))
(define (spec i) (format #f "s~a" i))

(define (one-world seed)
  (let* ((st (seed->random-state seed))
         (nplaces (+ 2 (rnd st 2)))
         (places (map (lambda (i) (list (format #f "P~a" i) 0.0 (* 0.05 i))) (iota nplaces)))
         (pn (map car places))
         (nspec 5)
         ;; templates: each makes spec (k+1..) from lower specs; acyclic chain
         (templates
          (map (lambda (k)
                 (let* ((out (+ k 1 (rnd st 2)))
                        (outs (if (= 0 (rnd st 3))
                                  (list (cons (spec out) 1.0) (cons (spec (min 4 (+ out 1))) 0.5))
                                  (list (cons (spec out) 1.0))))
                        (ins (list (cons (spec k) (+ 0.5 (* 0.5 (rnd st 3)))))))
                   (list (format #f "t~a" k) outs ins 0.1)))
               '(0 1 2)))
         (movable (filter (lambda (s) (= 0 (rnd st 2))) (map spec '(0 1 2 3))))   ; some goods move
         (seeds (map (lambda (i) (list (spec i) (pick st pn) (+ 20.0 (* 10.0 (rnd st 10))))) '(0 1)))
         (demand-spec (spec 3)) (demand-at (pick st pn)) (demand-q (+ 3.0 (rnd st 8))))
    (declare-world! #:places places
                    #:templates templates
                    #:workers (map (lambda (p) (list (format #f "w~a" p) '("sk") (cell p 0) 100.0)) pn)
                    #:movable movable #:tau 0.5
                    #:neighbours (map (lambda (p) (cons p (filter (lambda (q) (not (equal? p q))) pn))) pn))
    (for-each (lambda (t) (hash-set! *proc-skill* (car t) "sk")) *templates*)
    (for-each (lambda (s) (hash-set! *init* (lg (car s) (cell (cadr s) 0)) (caddr s))) seeds)
    (hash-set! *demand* (lg demand-spec (cell demand-at 0)) demand-q)
    (let* ((planned
            (call-with-values build-located
              (lambda (forms labform ncol cols goods raws idx)
                (let* ((x0 ((module-ref E 'located-warm) cols ncol idx))
                       (x (call-with-values (lambda () (solve-native forms labform x0)) (lambda (x . _) x))))
                  ((module-ref E 'plan->material) x cols idx)))))
           (rows (map (lambda (m)
                        `((id . ,(commitment-id m)) (action . ,(commitment-action m))
                          (conforms-to . ,(commitment-resource-conforms-to m))
                          (quantity . ,(measure-has-numerical-value (commitment-resource-quantity m)))
                          (at-location . ,(commitment-at-location m)) (input-of . ,(commitment-input-of m))
                          (output-of . ,(commitment-output-of m)) (note . ,(commitment-note m))))
                      planned))
           (all-specs (map spec (iota nspec)))
           (seed-of (lambda (s) (fold (lambda (x a) (if (equal? (car x) s) (+ a (caddr x)) a)) 0.0 seeds)))
           (expected (lambda (s)
                       (+ (seed-of s)
                          (fold (lambda (r a)
                                  (if (equal? (assq-ref r 'conforms-to) s)
                                      (case (assq-ref r 'action) ((produce) (+ a (assq-ref r 'quantity)))
                                        ((consume) (- a (assq-ref r 'quantity))) (else a))
                                      a))
                                0.0 rows))))
           (enact (lambda (order)
                    (let-values (((vat scope) (fresh-scope)))
                      (with-vat vat
                        (let ((obs ($ scope 'observer)))
                          (for-each (lambda (s) ($ obs 'seed-resource (res (string-append "r-" (car s)) (car s) (caddr s) (cadr s)))) seeds)
                          (let ((r (enact-rows scope order)))
                            (list (length (car r)) (length (cdr r))
                                  (map (lambda (s) (cons s (spec-total obs s))) all-specs)))))))))
      (list seed rows enact expected all-specs demand-q demand-at))))

(for-each
 (lambda (k)
   (let* ((seed (+ SEED0 k)) (w (one-world seed))
          (rows (cadr w)) (enact (caddr w)) (expected (cadddr w)))
     (for-each
      (lambda (label order)
        (let* ((out (enact order)) (enacted (car out)) (left (cadr out)) (totals (caddr out)))
          (check (format #f "seed ~a, ~a: every row is enacted, none left unserved" seed label)
                 (and (= enacted (length order)) (= left 0)) #t)
          (check (format #f "seed ~a, ~a: every good is conserved (held + produced - consumed)" seed label)
                 (every (lambda (t) (< (abs (- (cdr t) (expected (car t)))) 0.01)) totals) #t)))
      '("in the emitted order" "in reverse order") (list rows (reverse rows)))))
 (iota N))
(test-summary!)
