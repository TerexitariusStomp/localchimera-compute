;;; test-subsistence-catalogue.scm — reproduction floors DERIVED from the
;;; composed subsistence catalogue, driving a live diet.
;;;
;;; Part 1: the catalogue composes a person's floor from the layers (species base ×
;;; geography × life-stage × labour × historical-moral) — matching nutrition.js.
;;; Part 2: floors derived from real person contexts drive plan-from-records
;;; (#:repro-floors) so each person is fed to THEIR composed requirement.
;;;
;;; Run:  guile --no-auto-compile -L module tests/planner/test-subsistence-catalogue.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner vf schemas)
             (playnet planner knowledge dsl shorthand))
(use-modules (playnet planner knowledge catalogues subsistence))

(define (floor-of ctx spec) (assoc-ref (subsistence-floors ctx) spec))
(define (~= a b tol) (< (abs (- a b)) tol))

;; ── Part 1 · the layers compose (values match nutrition.js) ──────────────────
(define fem34 '((sex . "F") (age . 34) (region . "temperate") (labour-hours . 5)))
(define coldM '((sex . "M") (age . 28) (region . "cold") (labour-hours . 9)))
(define preg  '((sex . "F") (age . 41) (region . "temperate") (pregnant . #t) (labour-hours . 3)))

(format #t "~%── the composed reproduction floor (the layers) ──~%")
(format #t "  temperate F/34 labour5 : energy ~,0f  protein ~,1f  iron ~,1f~%"
        (floor-of fem34 "energy") (floor-of fem34 "protein") (floor-of fem34 "iron"))
(format #t "  cold M/28 labour9      : energy ~,0f  (climate ×1.12 · labour ×1.42)~%" (floor-of coldM "energy"))
(format #t "  pregnant F/41 labour3  : iron ~,1f  folate ~,0f~%" (floor-of preg "iron") (floor-of preg "folate"))

(define part1
  (and (~= (floor-of fem34 "energy") 2383 5) (~= (floor-of fem34 "iron") 18 0.1)
       (~= (floor-of coldM "energy") 3491 8) (> (floor-of preg "iron") 20) (~= (floor-of preg "folate") 600 5)))
(format #t "~%  [~a] labour raises the energy floor · female iron 2.25× · cold×labour compound · pregnancy folds in dependent~%"
        (if part1 "✓" "✗"))

;; ── Part 2 · derived floors drive a live diet (the record path) ──────────────
(set! *emp-rho* 0.5)
(define PEOPLE (list (cons "fem" fem34) (cons "cold" coldM) (cons "preg" preg)))
(define FOODS '(("grain" 350 8 0.30) ("beans" 340 21 0.80)))   ; (id energy protein labour-h)

(define win (all-week-window))
;; a handful of growers so labour never binds (isolating the floors)
(define agents (map (lambda (i) (person* (format #f "w~a" i) #:name (format #f "W~a" i) #:window win)) (iota 6)))
(define spatials (list (place* "town")))
(define resources (map (lambda (i) (er (format #f "sk~a" i) "skill-grow" (format #f "w~a" i) #:qty 1.0 #:unit "kg")) (iota 6)))
(define procs
  (append-map (lambda (pp) (map (lambda (f) (rp* (string-append (car f) "-" (car pp))
                                              (string-append (car f) "→" (car pp)))) FOODS)) PEOPLE))
(define flows
  (append-map (lambda (pp)
    (append-map (lambda (f)
      (let ((rid (string-append (car f) "-" (car pp))) (pid (car pp)))
        (list (out* (string-append "e-" rid) (string-append "energy|" pid) (second f) rid "kcal")
              (out* (string-append "p-" rid) (string-append "protein|" pid) (third f) rid "g")
              (wk* (string-append "w-" rid) "skill-grow" (fourth f) rid)))) FOODS)) PEOPLE))

;; DERIVE each person's energy+protein floor from the catalogue, keyed to their good
(define repro
  (append-map (lambda (pp)
    (let ((pid (car pp)) (ctx (cdr pp)))
      (list (cons (string-append "energy|"  pid "#town@0") (floor-of ctx "energy"))
            (cons (string-append "protein|" pid "#town@0") (floor-of ctx "protein"))))) PEOPLE))

(define result
  (call-with-values
    (lambda () (plan-from-records resources agents spatials procs flows
                 #:demand '() #:repro-floors repro #:backend 'native-c))
    (lambda (ints coms material fill cols x idx ntot report)
      (map (lambda (pp)
        (let* ((pid (car pp))
               (get (lambda (spec) (fold (lambda (c a)
                        (if (and (eq? (commitment-action c) 'produce)
                                 (equal? (commitment-resource-conforms-to c) (string-append spec "|" pid)))
                            (+ a (measure-has-numerical-value (commitment-resource-quantity c))) a)) 0.0 material))))
          (list pid (get "energy") (get "protein")))) PEOPLE))))

(format #t "~%── derived floors drive the diet (energy/floor · protein/floor) ──~%")
(define fed-ok
  (every (lambda (r pp)
           (let* ((ctx (cdr pp)) (ef (floor-of ctx "energy")) (pf (floor-of ctx "protein"))
                  (e (second r)) (p (third r)) (ok (and (>= e (* 0.98 ef)) (>= p (* 0.98 pf)))))
             (format #t "  ~5a: energy ~5,0f/~5,0f  protein ~5,1f/~5,1f  ~a~%" (first r) e ef p pf (if ok "✓" "✗"))
             ok))
         result PEOPLE))

(let ((ok (and part1 fed-ok)))
  (format #t "~%  [~a] every person fed to THEIR catalogue-composed reproduction floor~%" (if fed-ok "✓" "✗"))
  (format #t "~%  ~a the reproduction of labour-power, composed from the determinants, drives the live plan~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
