;;; movable-circulation.scm — a plan over MOVABLE goods may carry them round a loop.
;;;
;;;   guix shell --pure -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -q -L module tools/probes/movable-circulation.scm
;;;
;;; Seeded random worlds (two or three places, a chain of recipes, some goods declared
;;; #:movable with every pair of places neighbours), planned and then enacted against the
;;; books in the order emitted. A static world (no movable goods) is conserved and fully
;;; served (tests/planner/test-property-enact.scm). With movable goods the carries are
;;; free in the program, so the solve is indifferent to sending q units P0→P1 and q back,
;;; and its answer lands on large q: tens of thousands of units for a
;;; demand of ten. Each such row is a pickup the books refuse to drop off ("the cargo has
;;; not been picked up"), and the plan is left half-served.
;;;
;;; Output per world: rows planned, rows served, rows left, and the largest single carry.
;;; Raising #:tau (0.5, 5, 50) changes none of it.
(use-modules (playnet test harness) (playnet test books)
             (playnet planner vf schemas) (srfi srfi-1) (srfi srfi-11)
             (playnet planner scope live)
             (playnet planner solve engine) (playnet planner solve compile) (playnet planner solve solver)
             (goblins) (goblins vat) (goblins persistence-store memory) (goblins utils hashmap)
             (ice-9 format))
(setvbuf (current-output-port) 'none)
(define E (resolve-module '(playnet planner solve engine)))
(define N 8)
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
         (movable (filter (lambda (s) (= 0 (rnd st 2))) (map spec '(0 1 2 3))))
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
          (rows (cadr w)) (enact (caddr w))
          (out (enact rows))
          (carry (fold (lambda (r a) (if (memq (assq-ref r 'action) '(pickup dropoff)) (max a (assq-ref r 'quantity)) a)) 0.0 rows)))
     (format #t "seed ~a: ~a rows planned, ~a served, ~a left unserved; largest carry ~,1f units (demand ~,0f)~%"
             seed (length rows) (car out) (cadr out) carry (list-ref w 5))))
 (iota N))
