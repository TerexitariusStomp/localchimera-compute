;;; test-reproduction-diet.scm — the CONSTRAINT DIAL alone feeds everyone.
;;;
;;; Claim (docs/playnet.typ §possibility-tensions · social-material.typ, the
;;; constraint dial): the reproduction of labour-power is defended by HARD barriers,
;;; not by desire — so even with desire left IN, the constraint side alone generates
;;; a food plan that clears every person's nutritional floor while staying inside the
;;; ecological wall. A genuine two-sided "safe operating space":
;;;   • LOWER wall — the deficiency FLOOR: each person begins the day in metabolic
;;;     deficit, so the balance kcal|P ≥ 0 / protein|P ≥ 0 (a `bar` barrier) forces
;;;     the plan to grow enough food to clear it. No desire term touches the floors.
;;;   • UPPER wall — the ecological CEILING: the foods draw a shared `land` resource,
;;;     `frag-cap`ped (the SAME fragility barrier the ecological wheel uses on a
;;;     drawn-down forest/soil) — the plan is never allowed to over-draw nature.
;;; Two foods: grain (cheap calories, protein-poor, land-light) and beans (protein-
;;; dense, costlier, land-hungrier). Desire is left IN (people want veg). We solve
;;; under three regimes and read the diet.
;;;
;;; Run:  guile --no-auto-compile -L module tests/planner/test-reproduction-diet.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner solve solver))

;; people: (id kcal-floor protein-floor)
(define PEOPLE '(("ana" 2800 70) ("bo" 2200 55) ("cy" 1500 35)))
;; foods: (id label kcal protein labour land) — grain protein-poor ⇒ protein floor forces beans
(define FOODS '(("grain" "Grain" 350  5 0.30 1.0) ("beans" "Beans" 340 21 0.80 1.6)))
(define VEG-WANT 3.0)               ; each person WANTS veg (a soft desire, left in)
;; The ecological boundary on land draw. It was (26 34 0.5 80) — tip ~30 — and the
;; check below asked the wall to pull land down by more than FIVE. Both numbers
;; were calibrated against a plan that DREW MORE THAN IT NEEDED: the uncapped
;; run's land carried the centering residue every non-binding activity used to
;; hold. Deriving the path floor from the certified gap (solver.scm `tmin-for`,
;; 2026-08-13) made that plan lean, and the fixture then measured nothing: land
;; here is a function of the HARD FLOORS (veg draws none), so an honest plan
;; draws 21.5 and a wall at 30 never touches it.
;;
;; Land being floor-pinned is not a flaw in the fixture — it is the situation the
;; two-sided space is FOR, and it says exactly what a binding wall can and cannot
;; do. It cannot feed people on less land than feeding them costs. What it can do
;; is take away the slack above the floors: walled, the plan sits at 2800 kcal
;; where unwalled it sat at 2832. So the tip goes just above the floor-pinned
;; draw, and the check asks for that — the wall removes the margin, not the meal.
(define LAND-CEIL (list 20.0 24.0 0.5 80.0))   ; ecological boundary on land draw, tip ~22

(define (recipes)
  (compile-recipe
    (append
      (append-map (lambda (p) (map (lambda (f) (rp (string-append (car f) "-" (car p))
                                                   (string-append (cadr f) "→" (car p)))) FOODS)) PEOPLE)
      (map (lambda (p) (rp (string-append "veg-" (car p)) (string-append "Veg→" (car p)))) PEOPLE))
    (append
      (append-map (lambda (p)
        (append-map (lambda (f)
          (let ((rid (string-append (car f) "-" (car p))) (pid (car p)))
            (list (out (string-append "k-" rid) (string-append "kcal|" pid)    (third f)  rid)
                  (out (string-append "p-" rid) (string-append "protein|" pid) (fourth f) rid)
                  (in  (string-append "l-" rid) "land" (sixth f) rid)                       ; DRAW on land
                  (wrk (string-append "w-" rid) (fifth f) rid)))) FOODS)) PEOPLE)
      (append-map (lambda (p)
        (let ((rid (string-append "veg-" (car p))) (pid (car p)))
          (list (out (string-append "v-" rid) (string-append "veg|" pid) 1.0 rid)
                (wrk (string-append "w-" rid) 0.5 rid)))) PEOPLE))))

;; returns (rows . land) ; each row = (id grain beans veg kcal protein)
(define (solve labour-h ceiling?)
  (declare-world! #:places '(("town" 0.0 0.0)) #:templates (recipes)) (hash-set! *raws* "land" #t)
  (hash-set! *A* (cell "town" 0) labour-h)
  (when ceiling? (hash-set! *frag-cap* (lg "land" (cell "town" 0)) LAND-CEIL))
  (for-each (lambda (p)
    (hash-set! *init* (lg (string-append "kcal|"    (car p)) (cell "town" 0)) (- (second p)))  ; floor (hard)
    (hash-set! *init* (lg (string-append "protein|" (car p)) (cell "town" 0)) (- (third p)))   ; floor (hard)
    (hash-set! *demand* (lg (string-append "veg|" (car p)) (cell "town" 0)) VEG-WANT))          ; desire (soft)
    PEOPLE)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0))))
             (land 0.0)
             (rows (map (lambda (p)
                     (let* ((pid (car p)) (g (V (string-append "p|grain-" pid "|town@0")))
                            (b (V (string-append "p|beans-" pid "|town@0"))) (v (V (string-append "p|veg-" pid "|town@0"))))
                       (set! land (+ land (* 1.0 g) (* 1.6 b)))
                       (list pid g b v (+ (* 350 g) (* 340 b)) (+ (* 5 g) (* 21 b))))) PEOPLE)))
        (cons rows land)))))

(define (floors-met rows) (every (lambda (r p) (and (>= (fifth r) (- (second p) 1)) (>= (sixth r) (- (third p) 0.5)))) rows PEOPLE))
(define (show tag res)
  (let ((rows (car res)) (land (cdr res)))
    (format #t "~%════ ~a ════~%" tag)
    (format #t "  ~4a │ grain  beans │  kcal (floor)   protein (floor)  │ veg (want ~a)~%" "who" VEG-WANT)
    (for-each (lambda (r p)
      (format #t "  ~4a │ ~5,1f ~5,1f │ ~5,0f (~4,0f)~a ~6,1f (~3,0f)~a │ ~4,1f~a~%"
              (first r) (second r) (third r) (fifth r) (second p) (if (>= (fifth r) (- (second p) 1)) "✓" "✗")
              (sixth r) (third p) (if (>= (sixth r) (- (third p) 0.5)) "✓" "✗")
              (fourth r) (if (< (fourth r) (- VEG-WANT 0.4)) " ← desire cut" "")))
      rows PEOPLE)
    (format #t "  land drawn: ~,1f (ecological tip ~~22) · all floors met: ~a~%"
            land (if (floors-met rows) "YES ✓" "NO ✗"))))

(define open (solve 30.0 #f))   ; abundant labour, NO ecological ceiling — plan overshoots
(define capd (solve 30.0 #t))   ; abundant labour, ecological ceiling ON — bounded by the land wall
(define scar (solve 8.0  #t))   ; scarce labour, ceiling ON — floors met exactly, desire cut
(show "ABUNDANT labour · no ecological wall (unbounded)" open)
(show "ABUNDANT labour · ecological wall ON (safe operating space)" capd)
(show "SCARCE labour · ecological wall ON" scar)

(define ok3
  (let* ((c1 (floors-met (car open))) (c2 (floors-met (car capd))) (c3 (floors-met (car scar)))  ; fed in ALL regimes
         ;; the wall BINDS — it pulls land down, and what it takes is the SLACK
         ;; above the floors: walled, every person's kcal sits ON the floor;
         ;; unwalled the plan carries a margin it does not owe anyone.
         (surplus (lambda (rows) (fold (lambda (r p a) (+ a (- (fifth r) (second p)))) 0.0 rows PEOPLE)))
         (c4 (and (< (cdr capd) (cdr open))
                  (> (surplus (car open)) 10.0)
                  (< (surplus (car capd)) 1.0)))
         (c5 (<= (cdr capd) 22.0))                                   ; …and holds the plan inside the wall (tip)
         (c6 (every (lambda (r) (> (third r) 0.05)) (car scar)))     ; real diet: protein floor forces beans
         (c7 (every (lambda (r) (> (fourth r) 2.0)) (car capd)))     ; desire served when able
         (c8 (every (lambda (r) (< (fourth r) 1.0)) (car scar)))     ; desire cut first under scarcity
         (ok (and c1 c2 c3 c4 c5 c6 c7 c8)))
    (format #t "~%  [~a] every reproduction floor met — all three regimes (worst-off protected, not averaged)~%" (if (and c1 c2 c3) "✓" "✗"))
    (format #t "  [~a] the ecological wall BINDS: land ~,1f → ~,1f when the boundary is on~%" (if c4 "✓" "✗") (cdr open) (cdr capd))
    (format #t "  [~a] …and the plan stays inside the wall (land ≤ tip)~%" (if c5 "✓" "✗"))
    (format #t "  [~a] a real diet: the protein floor forces beans into the mix~%" (if c6 "✓" "✗"))
    (format #t "  [~a] desire (veg) served when labour allows~%" (if c7 "✓" "✗"))
    (format #t "  [~a] under scarcity the hard floors are protected and desire is cut first~%" (if c8 "✓" "✗"))
    (format #t "~%  ~a fed from below by reproduction floors, bounded from above by the ecological wall — the constraint dial alone.~%" (if ok "✓" "✗"))
    ok))

;; ── generalization: nothing above is special-cased — it's the generic good/recipe/
;; barrier machinery, so it scales across people, nutrients, and the menu. Here: N
;; heterogeneous people (per-index floors), THREE nutrients (kcal/protein/iron, so the
;; diet must span a harder space), a 4-food menu. And the honest boundary: below the
;; subsistence-minimum the solver reports INFEASIBLE — it won't conjure food from nothing.
(define GN 48)
(define (gperson i)
  (list (format #f "g~2,'0d" i) (+ 1500 (* 350 (modulo i 5))) (+ 35 (* 12 (modulo i 4))) (+ 8 (* 4 (modulo i 3)))))
(define GPEOPLE (map gperson (iota GN)))
(define GFOODS '(("grain" "Grain" 350 5 1.5 0.30) ("beans" "Beans" 340 21 5.0 0.80)
                 ("greens" "Greens" 60 3 8.0 0.50) ("dairy" "Dairy" 250 16 0.2 0.70)))  ; span kcal/protein/iron
(define (grecipes)
  (compile-recipe
    (append-map (lambda (p) (map (lambda (f) (rp (string-append (car f) "-" (car p)) "r")) GFOODS)) GPEOPLE)
    (append-map (lambda (p)
      (append-map (lambda (f)
        (let ((rid (string-append (car f) "-" (car p))) (pid (car p)))
          (list (out (string-append "k-" rid) (string-append "kcal|" pid) (third f) rid)
                (out (string-append "p-" rid) (string-append "protein|" pid) (fourth f) rid)
                (out (string-append "i-" rid) (string-append "iron|" pid) (fifth f) rid)
                (wrk (string-append "w-" rid) (sixth f) rid)))) GFOODS)) GPEOPLE)))
;; returns fed-count, or #f if the solve is infeasible
(define (gsolve labour-h)
  (declare-world! #:places '(("town" 0.0 0.0)) #:templates (grecipes)) (hash-set! *raws* "land" #t)
  (hash-set! *A* (cell "town" 0) labour-h)
  (for-each (lambda (p)
    (hash-set! *init* (lg (string-append "kcal|" (car p)) (cell "town" 0)) (- (second p)))
    (hash-set! *init* (lg (string-append "protein|" (car p)) (cell "town" 0)) (- (third p)))
    (hash-set! *init* (lg (string-append "iron|" (car p)) (cell "town" 0)) (- (fourth p)))) GPEOPLE)
  ;; NB `solve-native-c`, not `solve`: this file defines its own two-argument
  ;; `solve` above, which shadows the planner's. Naming the shadowed one silently
  ;; bound to the local and every solve came back empty.
  ;;
  ;; Reads the VERDICT, not an exception. This used to call `solve-native` — the
  ;; pure-Scheme reference — purely because that was the only backend that
  ;; SIGNALLED infeasibility: the C path returned a plan whose certificate said
  ;; `feasible? #f` and raised nothing, so a test wanting an honest infeasible
  ;; answer had to take the slow solver and catch an error. Both backends now
  ;; decide feasibility by the same phase-I argument and publish the same object,
  ;; so this can use the fast path and ASK, which is also the better test: it
  ;; asserts against a reported quantity instead of against control flow.
  (catch #t
    (lambda ()
      (call-with-values build-located
        (lambda (forms labform ncol cols goods raws idx)
          (let* ((x (car (call-with-values (lambda () (solve-native-c forms labform (located-warm cols ncol idx))) list)))
                 (cert (certificate-of-last-solve))
                 (_ (unless (assq-ref cert 'feasible?)
                      (throw 'plan-infeasible (or (assq-ref cert 'violation) 0.0))))
                 (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0))))
                 (fed 0))
            (for-each (lambda (p)
              (let* ((pid (car p)) (amt (lambda (fid) (V (string-append "p|" fid "-" pid "|town@0"))))
                     (g (amt "grain"))(b (amt "beans"))(gr (amt "greens"))(d (amt "dairy"))
                     (kc (+ (* 350 g)(* 340 b)(* 60 gr)(* 250 d)))(pr (+ (* 5 g)(* 21 b)(* 3 gr)(* 16 d)))(ir (+ (* 1.5 g)(* 5 b)(* 8 gr)(* 0.2 d))))
                (when (and (>= kc (- (second p) 1)) (>= pr (- (third p) 0.5)) (>= ir (- (fourth p) 0.02))) (set! fed (1+ fed))))) GPEOPLE)
            fed))))
    ;; #f = "no plan exists", however the backend said so. `violation` carries HOW
    ;; MUCH the limits are missed by — the obstruction, not the symptom.
    (lambda (key . args) #f)))

(format #t "~%── generalization · ~a heterogeneous people · 3 nutrients (kcal/protein/iron) · 4 foods ──~%" GN)
(define gA (gsolve 220.0))    ; comfortable
(define gB (gsolve 150.0))    ; tighter, still feasible
(define gC (gsolve 70.0))     ; below subsistence-minimum → infeasible
(format #t "  labour 220 → fed ~a · labour 150 → fed ~a · labour 70 → ~a~%"
        (or gA "—") (or gB "—") (if gC "fed" "INFEASIBLE (won't conjure food)"))

(let* ((g1 (eqv? gA GN)) (g2 (eqv? gB GN)) (g3 (not gC))        ; all fed when feasible; honest infeasible when not
       (genok (and g1 g2 g3)) (ok (and ok3 genok)))
  (format #t "  [~a] every one of ~a people fed at both feasible labour levels~%" (if (and g1 g2) "✓" "✗") GN)
  (format #t "  [~a] below subsistence-minimum the solve is reported INFEASIBLE, not faked~%" (if g3 "✓" "✗"))
  (format #t "~%  ~a the constraint dial feeds everyone whenever the world allows — and says so plainly when it doesn't.~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
