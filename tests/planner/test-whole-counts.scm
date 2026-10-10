;;; test-whole-counts.scm — acts that happen a whole number of times.
;;;
;;; The relaxation may run 0.5 of an act. At population scale that is the RIGHT
;;; object — a district performs 12.5 appendectomies a week and the fraction is a
;;; rate — and it stops meaning anything when a period holds about one unit. So
;;; this is for the few acts that are genuinely countable, and the test's job is
;;; to show it changes nothing anywhere else.
;;;
;;; A whole count is the SECOND kind of discreteness in the engine, not a second
;;; engine: MBQ splits a column 0 | ≥L, a whole count splits it ≤⌊v⌋ | ≥⌈v⌉, and
;;; both run on one tree against one certificate.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-whole-counts.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b tol) (< (abs (- a b)) tol))
(define (whole? v) (< (abs (- v (round v))) 1e-4))

;;; A theatre performs operations. Each operation needs surgeon-hours; the demand
;;; is deliberately set so the relaxation wants a fractional number of them.
(define* (build! #:key (want 2.5) (hours 100.0) (whole-counts '()))
  (declare-world! #:places '("clinic")
                  #:templates
                    (compile-recipe (list (rp "operate" "Operate"))
                                    (list (out "o" "repair" 1.0 "operate")
                                          (wrk "w" 1.0 "operate"))))
  (apply declare-whole! whole-counts)
  (hash-set! *demand* (lg "repair" (cell "clinic" 0)) want)
  (hash-set! *A* (cell "clinic" 0) hours))

(define (run-relaxed)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let ((x (car (call-with-values
                     (lambda () (solve-native forms labform (located-warm cols ncol idx))) list))))
        (col-value x idx "p|operate|clinic@0")))))

(define (run-discrete)
  (call-with-values solve-discrete
    (lambda (cfg certified? lb cost k nodes)
      ;; re-solve at the winning config, cuts and FIXINGS, which solve-discrete restored
      (call-with-values located-solve
        (lambda (x forms labform idx)
          (list (col-value x idx "p|operate|clinic@0") certified? nodes cost))))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. The relaxation is fractional — the thing being fixed
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 1. what the relaxation says ──~%~%")

(build! #:want 2.5)
(define relaxed (run-relaxed))
(format #t "    relaxed operations: ~,3f~%~%" relaxed)
(check "the relaxation runs a fractional number of operations"
       (not (whole? relaxed)))
(check "…and it is between 2 and 3, so the fraction is real and not noise"
       (and (> relaxed 2.0) (< relaxed 3.0)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Declared whole, the count comes out whole
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 2. declared countable ──~%~%")

(build! #:want 2.5 #:whole-counts '("operate"))
(define got (run-discrete))
(format #t "    whole operations: ~,3f   certified ~a   ~a node(s)~%~%"
        (car got) (cadr got) (caddr got))

(check "the count is a whole number"          (whole? (car got)))
(check "…and the search certified it global"  (cadr got))
(check "the tree is small — a handful of nodes, not a sweep"
       (< (caddr got) 20))
(check "it lands at one of the two integers the relaxation sat between"
       (or (= 2 (round (car got))) (= 3 (round (car got)))))

;; the strongest check available: cost every integer it could have been and
;; confirm the search found the best one. If these ever disagree, the search is
;; wrong rather than the fixture.
(define (cost-at n)
  (build! #:want 2.5 #:whole-counts '("operate"))
  (cost-of-config 'all '() (list (cons "p|operate|clinic@0" n))))
(define scan (map (lambda (n) (cons n (cost-at n))) (iota 9)))
(format #t "    exhaustive scan: ~a~%~%"
        (map (lambda (p) (format #f "~a:~,3f" (car p) (cdr p))) scan))
(define best (fold (lambda (p a) (if (< (cdr p) (cdr a)) p a)) (car scan) scan))
(check "the search agrees with an exhaustive scan over every integer"
       (= (car best) (round (car got))))

;; a fact is not a near-miss: the column left the program, so its value is the
;; integer itself and not an iterate that stopped nearby
(check "the count is EXACT, not merely close"
       (= 3 (car got)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Degeneracy — undeclared acts are untouched
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; The strongest signal: if declaring nothing moves any number, the construction
;; is wrong rather than the tests.

(format #t "~%── 3. nothing declared, nothing changed ──~%~%")

(build! #:want 2.5)
(check "with nothing declared the plan is the relaxation, to the digit"
       (near? (run-relaxed) relaxed 1e-9))

(build! #:want 2.5)
(check "…and solve-discrete short-circuits: no batch columns, no whole ones"
       (call-with-values solve-discrete
         (lambda (cfg certified? lb cost k nodes) (and certified? (= 0 nodes)))))

;; a flow is correctly fractional and must STAY fractional
(build! #:want 2.5 #:whole-counts '("some-other-act"))
(check "declaring an unrelated act leaves this one fractional"
       (not (whole? (run-relaxed))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. The cuts are the METHOD's, never the world's
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; playnet's own rule: the solver sees everything, the certificate sees only the
;; world. A branch bound is scaffolding the search erected — it must not appear
;; in what the plan claims to have proven.

(format #t "~%── 4. a branch is not a limit the world has ──~%~%")

(build! #:want 2.5 #:whole-counts '("operate"))
(with-col-bounds! (list (cons "p|operate|clinic@0" (cons 1.0 2.0))))
(call-with-values build-located
  (lambda (forms labform ncol cols goods raws idx)
    (let* ((world (world-forms forms))
           (n-all (length forms))
           (n-world (length world)))
      (format #t "    ~a forms, ~a of them the world's~%~%" n-all n-world)
      (check "the cuts reach the solver"        (> n-all n-world))
      (check "…and none of them reach the certificate"
             (= (- n-all n-world) 2)))))       ; exactly the lo and hi just set

;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. An impossible cut prunes rather than raising
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 5. a branch that cannot be taken ──~%~%")

(build! #:want 2.5 #:hours 2.0 #:whole-counts '("operate"))
(check "a cut demanding more than the cell can supply costs infinity, not an error"
       (= +inf.0 (cost-of-config 'all (list (cons "p|operate|clinic@0" (cons 50.0 #f))))))

(build! #:want 2.5 #:hours 2.0 #:whole-counts '("operate"))
(check "…so the search still returns a whole answer under a tight cap"
       (whole? (car (run-discrete))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. The door the knowledge layer actually uses
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; `declare-whole!` above lives in the ENGINE, which is primitive-loaded. A recipe
;; reaches the planner as a MODULE, and module/playnet/planner.scm does not
;; include the engine — so a recipe cannot call it, and a guarded call there is a
;; silently dead branch rather than a caller.
;;
;; Countable acts therefore arrive the way storability does: as data, through the
;; keyword. This is the path a scope really takes, so it is the one that has to
;; keep working.

(format #t "~%── 6. countable acts, stated as data ──~%~%")

(ingest-located! '() '() (list (place* "hall"))
                 #:periods '(0) #:whole '("rp-meeting"))

(check "#:whole registers the act, with nothing reaching across the seam"
       (equal? '("rp-meeting") (hash-map->list (lambda (k v) k) *whole-procs*)))
(check "…and its columns read as countable"
       (whole-col? "p|rp-meeting|hall@0"))
(check "…while an undeclared act stays a rate"
       (not (whole-col? "p|bake|hall@0")))

(ingest-located! '() '() (list (place* "hall"))
                 #:periods '(0))
(check "declaring none declares none — the degenerate case is free"
       (= 0 (hash-count (const #t) *whole-procs*)))

(format #t "~%~a passed, ~a failed~%~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
