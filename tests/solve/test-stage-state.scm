;;; test-stage-state.scm — a stage is part of what a thing is.
;;;
;;; Soil after legumes is not soil after maize; a line that has just run peanuts
;;; is not a clean line. VF says this with `stage` and `state`, and the solve read
;;; neither — so every ordering constraint had to be smuggled in as an invented
;;; spec, or written off as needing a binary.
;;;
;;; It needs no new machinery. The lattice identifies a good BY ITS NAME, so
;;; qualifying the name is enough: an act that outputs a stage produces that good,
;;; an act that requires it consumes it, and the ORDER falls out of the balance
;;; rows. No indicator variable, no product of binaries.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-stage-state.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve discrete) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

;; a flow that names the stage its end of the act requires or leaves is the
;; shared produce / consume flow with #:stage (knowledge shorthand); the staged
;; produce marks nothing primary
(define (out/s id spec stage q proc) (out* id spec q proc #:stage stage #:primary #f))
(define (in/s  id spec stage q proc) (consume* id spec q proc #:stage stage))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. The naming rule
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 1. a stage narrows the name ──~%~%")

(check "no stage, no change — the degenerate case is the old name"
       (equal? "soil" (qualified-good "soil" #f #f)))
(check "a stage narrows it"        (equal? "soil/after-legumes" (qualified-good "soil" "after-legumes" #f)))
(check "a state narrows it"        (equal? "line!clean" (qualified-good "line" #f "clean")))
(check "and both, in order"        (equal? "soil/tilled!wet" (qualified-good "soil" "tilled" "wet")))
(check "an empty stage is no stage" (equal? "soil" (qualified-good "soil" "" "")))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Ordering falls out of the flow — no binary anywhere
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; Maize needs nitrogen-rich soil, which only the legume act leaves behind. The
;; ORDER is never stated: maize consumes `soil/after-legumes`, legumes produce it,
;; and the balance row is what forbids maize from running first.

(format #t "~%── 2. maize after legumes, because that is the soil it eats ──~%~%")

(define* (rotation #:key (legumes-possible? #t))
  (declare-world! #:places '("field") #:periods '(0 1)
                  #:templates
                    (compile-recipe
                      (list (rp "legume" "Grow legumes") (rp "maize" "Grow maize"))
                      (list (out/s "l1" "soil" "after-legumes" 1.0 "legume") (wrk "l2" 0.1 "legume")
                            (in/s  "m1" "soil" "after-legumes" 1.0 "maize")
                            (out  "m2" "maize" 1.0 "maize")        (wrk "m3" 0.1 "maize")))
                  #:storable '("soil/after-legumes" "maize"))
  ;; the legume act is available only when it is possible at all
  (unless legumes-possible?
    (set-templates! (filter (lambda (tpl) (not (equal? "legume" (car tpl)))) *templates*)))
  (for-each (lambda (t) (hash-set! *A* (cell "field" t) 100.0)) '(0 1))
  (hash-set! *demand* (lg "maize" (cell "field" 1)) 5.0)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let ((x (car (call-with-values
                     (lambda () (solve-native forms labform (located-warm cols ncol idx))) list))))
        (list (fold + 0.0 (map (lambda (t)
                                 (let ((j (hash-ref idx (format #f "p|maize|field@~a" t) #f)))
                                   (if j (vector-ref x j) 0.0))) '(0 1)))
              (fold + 0.0 (map (lambda (t)
                                 (let ((j (hash-ref idx (format #f "p|legume|field@~a" t) #f)))
                                   (if j (vector-ref x j) 0.0))) '(0 1)))
              goods)))))

(define with-legumes (rotation))
(format #t "    maize grown ~,2f, legumes grown ~,2f~%" (car with-legumes) (cadr with-legumes))
(format #t "    goods the model knows: ~a~%~%"
        (filter (lambda (g) (string-contains g "soil")) (caddr with-legumes)))

(check "the staged soil is a good in its own right"
       (any (lambda (g) (string-contains g "soil/after-legumes")) (caddr with-legumes)))
(check "maize grows"                    (> (car with-legumes) 0.1))
(check "…and legumes grow to feed it — the order was never stated"
       (> (cadr with-legumes) 0.1))
(check "the two run in step: no more maize than the soil for it"
       (<= (car with-legumes) (+ 0.001 (cadr with-legumes))))

;; the control: take the legume act away and maize has no soil to eat
(define no-legumes (rotation #:legumes-possible? #f))
(format #t "    without the legume act: maize ~,2f~%~%" (car no-legumes))
(check "with nothing to leave that soil behind, maize cannot run at all"
       (< (car no-legumes) 0.001))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. It is ordinary material flow — nothing discrete was added
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 3. no binary was harmed ──~%~%")

(check "no whole-count declaration was needed"
       (= 0 (hash-count (const #t) *whole-procs*)))
(check "no minimum-batch declaration was needed"
       (= 0 (hash-count (const #t) *mbq-procs*)))
(check "the search has nothing to search — this is one convex solve"
       (call-with-values solve-discrete
         (lambda (cfg cert lb cost k nodes) (and cert (= 0 nodes)))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Degeneracy — an unstaged model is byte-identical
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 4. nothing staged, nothing changed ──~%~%")

(define (plain-soil)
  (declare-world! #:places '("field") #:periods '(0 1)
                  #:templates
                    (compile-recipe
                      (list (rp "legume" "Grow legumes") (rp "maize" "Grow maize"))
                      (list (out "l1" "soil" 1.0 "legume") (wrk "l2" 0.1 "legume")
                            (in  "m1" "soil" 1.0 "maize")
                            (out "m2" "maize" 1.0 "maize") (wrk "m3" 0.1 "maize")))
                  #:storable '("soil" "maize"))
  (for-each (lambda (t) (hash-set! *A* (cell "field" t) 100.0)) '(0 1))
  (hash-set! *demand* (lg "maize" (cell "field" 1)) 5.0)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx) (sort goods string<?))))

(check "an unstaged model names plain goods, with no qualifier anywhere"
       (not (any (lambda (g) (or (string-contains g "/") (string-contains g "~")))
                 (plain-soil))))

(format #t "~%~a passed, ~a failed~%~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
