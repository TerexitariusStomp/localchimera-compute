;;; prelude.scm — the shared test harness, a module: (playnet test planner prelude).
;;;
;;;   (use-modules (playnet test planner prelude))
;;;
;;; provides fixture-file (a path beside this file) and planner-file (a path under
;;; module/playnet/planner/, for loading a knowledge/ fixture),
;;; check + check-done (the pass/fail counter + summary), and the
;;; build→solve→index harness (solve-located + Vof). The engine itself is the
;;; test's own import — a test states the layers it reads (engine, compile,
;;; solver, schemas …) beside this line; the harness only shares its fixtures.
;;;
;;; solve-located is #:replace'd: the engine exports a solve-located of its own,
;;; and this arity-0 harness is the one every test written against the prelude
;;; calls, so it wins the name without a duplicate-binding warning.

(define-module (playnet test planner prelude)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (playnet solve engine)
  #:use-module (playnet solve solver)
  #:export (fixture-file planner-file check check-done Vof)
  #:replace (solve-located))

;; the fixtures stand beside this file; the planner's own files are one directory over
(define %fixture-dir
  (dirname (or (%search-load-path "playnet/test/planner/prelude.scm")
               (current-filename)
               "module/playnet/test/planner/prelude.scm")))
(define %planner-dir (string-append (dirname (dirname %fixture-dir)) "/planner"))
(define (fixture-file f) (string-append %fixture-dir "/" f))   ; e.g. (fixture-file "federated-fixtures.scm")
(define (planner-file f) (string-append %planner-dir "/" f))   ; e.g. (planner-file "knowledge/doon-valley.scm")

;; pass/fail counter + a named check
(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
;; a rule + summary; exit 1 if any failed. Optional (fmt . args) success banner.
(define (check-done . banner)
  (format #t "~%════════════════════════════════════════════~%")
  (cond ((= *fail* 0)
         (when (pair? banner) (apply format #t banner))
         (format #t "  All ~a checks passed.~%" *pass*))
        (else (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*))))
  (format #t "════════════════════════════════════════════~%")
  (when (> *fail* 0) (exit 1)))

;; build the located problem + solve → (values x idx). The caller ingests + sets
;; *A*/*cap*/*templates*/demand BEFORE calling. Vof turns (x idx) into a k→value reader.
(define (solve-located)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (values (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list))
              idx))))
(define (Vof x idx) (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0))))
