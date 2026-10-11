;;; test-voice-field-solve.scm — the field on a solve: one labform entry per
;;; work column, and what it does to the plan.
;;;
;;; docs/planning/voice/voice-in-lean.md, FieldSolve.lean twins:
;;;   τ = 0                  the labform is byte-identical and so is the plan (today)
;;;   3   warp_mem           every column's coefficient stays within (1±τ)·own, > 0
;;;   19  gap_beats_voice    a disliked way far cheaper than its alternative still runs
;;;   19′ tie_goes_to_voice  of two ways of equal cost the liked one runs
;;;   5a  what_statement_cancels  a like on every way of the good moves nothing
;;; and the report: the solve's alist carries τ, the stances read, and each
;;; part's marginal price (theorem 20, −τ·Σ ℓ_j·x_j).
;;;
;;; Fixture: one town, one period, bread wanted, two or three ways to bake it,
;;; on the aggregate labour path (col-labour on the process column).
;;;
;;; Run:  guile -q -L module tests/solve/test-voice-field-solve.scm

(use-modules (playnet test planner prelude)
             (playnet solve engine) (playnet solve world) (playnet solve compile) (playnet solve solver)
             (playnet vf facts parts) (playnet solve voice-field)
             (srfi srfi-1) (ice-9 format))

(define (~= a b . tol) (< (abs (- a b)) (if (pair? tol) (car tol) 1e-6)))

;; ways of bread: (proc-id hours-per-loaf)
(define (recipes ways)
  (compile-recipe
    (map (lambda (w) (rp (car w) (string-append "Bake " (car w)))) ways)
    (append-map (lambda (w)
                  (list (out (string-append "o-" (car w)) "bread" 1.0 (car w))
                        (wrk (string-append "w-" (car w)) (cadr w) (car w))))
                ways)))

(define (world! ways)
  (declare-world! #:places '(("town" 0.0 0.0)) #:templates (recipes ways))
  (hash-set! *A* (cell "town" 0) 1000.0)
  (hash-set! *demand* (lg "bread" (cell "town" 0)) 20.0))

(define (field! tau pushes)
  (set! *voice-tau* tau)
  (set! *voice-pushes* pushes)
  (set! *voice-hours* (lambda (π) 50.0)))          ; every way worked 50 hours: an even reference

(define (assembled)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx) (list forms labform cols idx))))
(define (level x idx proc) ((Vof x idx) (string-append "p|" proc "|" (cell "town" 0))))
(define (coeff labform idx key) (let ((i (hash-ref idx key))) (or (assv-ref labform i) 0.0)))

(format #t "~%=== τ = 0 is today ===~%")
(world! '(("a" 2.0) ("b" 2.0)))
(let ((base (assembled)))
  (field! 0.0 (list (cons (make-part #:process "a") 1.0)))
  (let ((again (assembled)))
    (check "with τ = 0 and a push standing, the labform is identical" (equal? (cadr base) (cadr again)))
    (check "…and no stance is reported" (not *voice-stances*))))

(format #t "~%=== 19′ tie_goes_to_voice ===~%")
(world! '(("a" 2.0) ("b" 2.0)))
(field! 0.3 (list (cons (make-part #:process "a") 1.0)))
(call-with-values solve-located
  (lambda (x idx)
    (check "of two ways of equal cost, the liked one runs" (> (level x idx "a") (level x idx "b")))))
(world! '(("a" 2.0) ("b" 2.0)))
(field! 0.3 (list (cons (make-part #:process "a") -1.0)))
(call-with-values solve-located
  (lambda (x idx)
    (check "a dislike sends the work the other way" (> (level x idx "b") (level x idx "a")))))

(format #t "~%=== 19 gap_beats_voice ===~%")
(world! '(("cheap" 1.0) ("dear" 2.0)))
(field! 0.3 (list (cons (make-part #:process "cheap") -1.0) (cons (make-part #:process "dear") 1.0)))
(call-with-values solve-located
  (lambda (x idx)
    ;; centred: cheap −1, dear +1 ⇒ stances −1 and +1 (even reference 0): cheap costs 1.3, dear 1.4
    (check "a disliked way far cheaper than its alternative still runs" (> (level x idx "cheap") (level x idx "dear")))))

(format #t "~%=== 3 warp_mem, on the assembled labform ===~%")
(world! '(("a" 2.0) ("b" 2.0) ("c" 3.0)))
(field! 0.0 '())
(let* ((base (assembled)) (lf0 (cadr base)) (idx (cadddr base))
       (rnd (let ((st (seed->random-state 20260922))) (lambda () (- (* 2.0 (random:uniform st)) 1.0)))))
  (let loop ((k 0) (ok #t))
    (if (= k 12)
        (check "every coefficient stays within (1±τ)·own and positive, under random stances" ok)
        (begin
          (field! 0.5 (list (cons (make-part #:process "a") (rnd)) (cons (make-part #:process "b") (rnd))
                            (cons (make-part #:process "c") (rnd)) (cons (make-part #:place "town") (rnd))))
          (let* ((lf (cadr (assembled))))
            (loop (+ k 1)
                  (and ok
                       (every (lambda (p)
                                (let ((w0 (coeff lf0 idx (string-append "p|" p "|" (cell "town" 0))))
                                      (w  (coeff lf  idx (string-append "p|" p "|" (cell "town" 0)))))
                                  (and (> w 0.0) (<= (* w0 0.5) (+ w 1e-9)) (<= w (+ (* w0 1.5) 1e-9)))))
                              '("a" "b" "c")))))))))

(format #t "~%=== 5a what_statement_cancels ===~%")
(world! '(("a" 2.0) ("b" 2.0)))
(field! 0.0 '())
(let ((lf0 (cadr (assembled))))
  (field! 0.3 (list (cons (make-part) -1.0)))               ; "less bread", on every way
  (let ((lf (cadr (assembled))))
    (check "a push on every way of the good leaves every coefficient where it was"
           (every (lambda (ic) (~= (cdr ic) (or (assv-ref lf0 (car ic)) -1.0))) lf))))

(format #t "~%=== the report ===~%")
(world! '(("a" 2.0) ("b" 2.0)))
(field! 0.3 (list (cons (make-part #:process "a") 1.0)))
(call-with-values solve-located
  (lambda (x idx)
    (let* ((cols (caddr (assembled))) (rep (solve-report x cols idx 1.0)) (v (assq-ref rep 'voice)))
      (check "the report carries the field" (and v (~= (assq-ref v 'tau) 0.3)))
      (check "the stances read, by column key"
             (let ((sa (assoc-ref (assq-ref v 'stances) (string-append "p|a|" (cell "town" 0)))))
               (and sa (> sa 0.0))))
      (check "theorem 20: a part's marginal price is −τ·Σ ℓ_j·x_j over its columns"
             (let ((pa (assoc-ref (assq-ref v 'parts) "process=a")))
               (and pa (~= pa (- (* 0.3 2.0 (level x idx "a"))) 1e-3)))))))

(check-done)
