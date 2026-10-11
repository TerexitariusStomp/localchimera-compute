;;; test-subsistence-consumption.scm — the whole band binds to FOOD PRODUCTION
;;; through the `contains` closure (knowledge/catalogues/substances.scm), unified with the rift.
;;;
;;; Food carries its human-nutrients the same way it carries its soil-elements:
;;; nutrient-content (catalogues/substances.scm) reads a food's composition off the SAME
;;; closure the metabolic-rift wire uses for C/N/P/K. So a person's nutrient BAND
;;; (from the subsistence catalogue: the deficiency floor, the toxicity ceiling,
;;; and the energy ceiling a body can take) binds to how much of each food the
;;; plan grows — the worker's nutrition and the soil's nutrients, one containment
;;; graph. Guarded only by KNOWLEDGE: a nutrient no food on the table carries
;;; gets no band. A nutrient the table carries in trace is NOT dropped: the floor
;;; stands, the plan is infeasible, and menu-starves names why.
;;;
;;; The table is the bread town's own (knowledge/recipes/bread-commune-seed):
;;; grain, beans, greens, rapeseed oil, fish, milk — the smallest table the
;;; engine feeds five bodies off under every floor and ceiling. Grain alone is
;;; the counter-example: no meal under a body's energy ceiling reaches its
;;; vitamin K from wheat, and the plan says so.
;;;
;;; Run:  guile --no-auto-compile -L module tests/solve/test-subsistence-consumption.scm

;; self-locate the `module` dir so (playnet knowledge catalogues substances) resolves
;; under any -L (the test-tensions loop passes -L module/playnet/planner).
(use-modules (srfi srfi-1) (ice-9 format))
(let ((self (find file-exists? (filter string? (cons (false-if-exception (current-filename)) (command-line))))))
  (when self (add-to-load-path (string-append (dirname self) "/../../module"))))
(use-modules (playnet test harness)
             (playnet knowledge catalogues substances)   ; nutrient-content · menu-carries · menu-starves
             (playnet solve engine) (playnet solve plan)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand)
             (playnet knowledge dsl world)
             (playnet knowledge recipes bread-commune-seed)
             (playnet knowledge catalogues subsistence))

;; ── the table: what the bread town produces that carries nutrition
(define TABLE
  (delete-duplicates
   (filter-map (lambda (f) (and (eq? 'produce (recipe-flow-action f))
                                (let ((spec (recipe-flow-resource-conforms-to f)))
                                  (and (pair? (nutrient-content spec 1)) spec))))
               (world-flows bread-world))))
;; five bodies, as subsistence-catalogue contexts
(define PEOPLE (list (cons "fem"   '((sex . "F") (age . 34) (region . "temperate") (labour-hours . 5)))
                     (cons "man"   '((sex . "M") (age . 28) (region . "cold") (labour-hours . 9)))
                     (cons "preg"  '((sex . "F") (age . 41) (region . "temperate") (pregnant . #t) (labour-hours . 3)))
                     (cons "elder" '((sex . "M") (age . 70) (region . "temperate") (labour-hours . 2)))
                     (cons "child" '((sex . "F") (age . 8) (region . "temperate") (labour-hours . 0)))))

;; per (person, food): grow-and-feed — labour → that person's nutrient goods, the
;; amounts READ FROM catalogues/substances.scm's containment table (nutrient-content).
(define win (all-week-window "09:00" "17:00"))
(define agents (map (lambda (i) (person* (format #f "w~a" i) #:name (format #f "W~a" i) #:window win)) (iota 3)))
(define spatials (list (place* "town")))
(define resources (map (lambda (i) (er (format #f "sk~a" i) "skill-grow" (format #f "w~a" i) #:qty 1.0 #:unit "kg")) (iota 3)))
(define (food-flows pp fd)
  (let ((rid (string-append fd "-" (car pp))) (pid (car pp)))
    (append (map (lambda (nu) (out* (string-append (car nu) "-" rid) (string-append (car nu) "|" pid) (cdr nu) rid "unit"))
                 (nutrient-content fd 1))
            (list (wk* (string-append "w-" rid) "skill-grow" 0.5 rid)))))
(define (bands-of pp carries)
  (filter-map (lambda (b) (and (member (car b) carries)
                               (cons (string-append (car b) "|" (car pp) "#town@0") (cdr b))))
              (subsistence-bands (cdr pp))))

;; solve the five bodies over MENU under the whole band → (values feasible? material)
(define (feed menu)
  (let* ((carries (menu-carries menu))
         (procs (append-map (lambda (pp) (map (lambda (fd) (rp* (string-append fd "-" (car pp)) fd)) menu)) PEOPLE))
         (flows (append-map (lambda (pp) (append-map (lambda (fd) (food-flows pp fd)) menu)) PEOPLE))
         (bands (append-map (lambda (pp) (bands-of pp carries)) PEOPLE))
         (floors (map (lambda (b) (cons (car b) (cadr b))) bands))
         (caps (filter-map (lambda (b) (and (caddr b) (cons (car b) (cons (caddr b) (cadddr b))))) bands)))
    (set! *emp-rho* 0.5)
    (call-with-values
        (lambda () (plan-from-records resources agents spatials procs flows
                                      #:demand '() #:repro-floors floors #:repro-caps caps
                                      #:backend 'native-c #:allow-infeasible? #t))
      (lambda (ints coms material fill cols x idx ntot report)
        (let ((cert (assq-ref report 'certificate)))
          (values (and (list? cert) (assq-ref cert 'feasible?)) material))))))
(define (delivered material pid nut)
  (fold (lambda (c a) (if (and (eq? (commitment-action c) 'produce)
                               (equal? (commitment-resource-conforms-to c) (string-append nut "|" pid)))
                          (+ a (measure-has-numerical-value (commitment-resource-quantity c))) a))
        0.0 material))

(display "\n── the town's table feeds five bodies under the whole band ──\n")
(format #t "  table: ~a~%" (string-join TABLE " "))
(check "the town's table carries what the engine needs — grain, beans, greens, an oil, fish, milk, salt — and the mill's and the bake's outputs beside them"
       (lset<= equal? '("grain" "beans" "greens" "rapeseed-oil" "fish" "dairy" "salt" "flour" "bread") TABLE))
(check "…and no body starves on it: no floor stands beyond what a meal under the energy ceiling delivers"
       (every (lambda (pp) (null? (menu-starves TABLE (subsistence-bands (cdr pp))))) PEOPLE))
(define-values (fed? material) (feed TABLE))
(check "the solve certifies the plan feasible: every floor and every ceiling, five bodies at once" (eq? #t fed?))
(define carries (menu-carries TABLE))
(for-each
 (lambda (pp)
   (let* ((pid (car pp)) (rows (filter (lambda (b) (member (car b) carries)) (subsistence-bands (cdr pp))))
          (short (filter (lambda (b) (< (delivered material pid (car b)) (* 0.98 (cadr b)))) rows))
          (over  (filter (lambda (b) (and (caddr b) (> (delivered material pid (car b)) (* 1.02 (caddr b))))) rows)))
     (format #t "  ~5a: energy ~5,0f in [~5,0f, ~5,0f]  iron ~4,1f in [~4,1f, ~4,1f]~%"
             pid (delivered material pid "energy") (cadr (assoc "energy" rows)) (caddr (assoc "energy" rows))
             (delivered material pid "iron") (cadr (assoc "iron" rows)) (caddr (assoc "iron" rows)))
     (check (format #f "~a is fed to every floor the table carries" pid) (null? short))
     (check (format #f "…and past no ceiling, the energy ceiling included" pid) (null? over))))
 PEOPLE)

(display "\n── grain alone starves, and the plan says so ──\n")
(check "menu-starves names vitamin K for every body: 4.7 kg of wheat a day is past what a body can take"
       (every (lambda (pp) (member "vit K" (menu-starves '("grain") (subsistence-bands (cdr pp))))) PEOPLE))
(define-values (grain-fed? _m) (feed '("grain")))
(check "…and the solve refuses the plan: the floor stands, the ceiling stands, nothing between them" (not (eq? #t grain-fed?)))
(check "the guard is knowledge alone: what grain carries is banded, what it carries none of is not"
       (and (member "vit K" (menu-carries '("grain"))) (not (member "vit B12" (menu-carries '("grain"))))))

(test-summary!)
