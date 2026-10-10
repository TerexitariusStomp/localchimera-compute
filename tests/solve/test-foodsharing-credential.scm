;;; test-foodsharing-credential.scm — the two things a plan can say about
;;; foodsharing's entry cost that its wiki cannot.
;;;
;;; Design: docs/planning/food/foodsharing-requirements.md §1 and §3. Becoming a
;;; Foodsaver takes a quiz and then at least THREE Einführungsabholungen supervised
;;; by an experienced one. Running a pickup takes a kit — a Kühlbox with
;;; Kühlelemente, food-safe containers, gloves, tongs — which today every person
;;; buys and carries privately, and arriving without it is the commonest reason
;;; someone is turned away.
;;;
;;; Encoded (knowledge/recipes/foodsharing-kit.scm) those become two ordinary
;;; objects the engine already knows:
;;;
;;;   THE COMPETENCE is a skill with lifecycle dynamics whose training column
;;;     consumes the MENTOR's hours of the same skill. So a district's growth is
;;;     bounded by how much experienced time it can spare to teach — not by how
;;;     many people want in.
;;;
;;;   THE KIT is a pool of `use`-able means the commune HOLDS. So the number of
;;;     simultaneous pickups is a property of the pool, and raising it is a
;;;     purchase decision rather than a hundred private ones.
;;;
;;; Both are read off the same located solve, four periods, one Kiez.
;;;
;;; Run: guile --no-auto-compile -L module/playnet/planner \
;;;        tests/solve/test-foodsharing-credential.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine))
(use-modules (playnet knowledge recipes foodsharing-kit))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define PER '(0 1 2 3))
(define KIEZ "kiez")
(define SKILL (foodsaver-skill))
(define TRAINEES '("Nina" "Ole" "Pia"))

;; ── the world ────────────────────────────────────────────────────────────────
;; ONE process: an Abholung. It wants a Foodsaver's hour and one set of the kit,
;; and it yields rescued food. Everything scarce about foodsharing is in those two
;; inputs.
(define (svc spec cell) (lg (string-append "Svc|" spec) cell))

(define* (setup #:key (mentor-hours 40.0) (mentors '("Bo")) (kit-sets 4)
                      (demand-kg 1200.0) (demand-profile #f))
  ;; the Abholung: 1 h of Foodsaver labour + one kit set → 30 kg rescued
  ;; who is in the Kiez. The mentors hold the Ausweis already; the trainees can
  ;; only carry it once taught, which the engine gates on their competence L.
  (declare-world! #:places (list (list KIEZ 52.52 13.40)) #:periods PER
                  #:templates
                    (list (list "abholung"
                                (list (cons "rescued" 30.0))
                                (map (lambda (row) (cons (string-append "Svc|" (kit-spec-id row))
                                                         (kit-per-pickup row)))
                                     *foodsharing-kit*)
                                1.0
                                (list (cons SKILL 1.0))))
                  #:workers
                    (append-map
                      (lambda (t)
                        (append
                         (map (lambda (m) (list m (list SKILL) (cell KIEZ t) mentor-hours)) mentors)
                         (map (lambda (n) (list n (if (= t 0) '() (list SKILL)) (cell KIEZ t) 40.0))
                              TRAINEES)))
                      PER))
  ;; the competence's lifecycle + who may be taught (foodsharing-kit.scm)
  (declare-foodsaver-skill! set-skill-spec!)
  (for-each (lambda (n) (enrol-foodsaver-trainee! add-trainable! n 0)) TRAINEES)
  ;; the KIT as a shared pool: `kit-sets` simultaneous pickups' worth, every period
  (for-each
   (lambda (t)
     (for-each (lambda (row)
                 ;; capacity is a FLOW: the kit sets a Kiez holds, over the
                 ;; hours of the period they are held for
                 (hash-set! *cap* (svc (kit-spec-id row) (cell KIEZ t))
                            (stock->flow (* kit-sets (kit-per-pickup row)) t)))
               *foodsharing-kit*))
   PER)
  ;; more rescue wanted than any of this can deliver — so the plan runs up
  ;; against whichever of the two ceilings binds first. DEMAND-PROFILE gives a
  ;; per-period want instead of the same one throughout, which is what lets a
  ;; fixture ask whether the plan builds capacity for a demand that has not
  ;; arrived yet (§1b).
  (for-each (lambda (t)
              (hash-set! *demand* (lg "rescued" (cell KIEZ t))
                         (if demand-profile (list-ref demand-profile t) demand-kg)))
            PER))

(define* (run . args)
  (apply setup args)
  (call-with-values solve-located
    (lambda (x forms labform cols goods raws idx)
      (define (V key) (let ((i (hash-ref idx key #f))) (if i (vector-ref x i) 0.0)))
      (list (cons 'pickups (map (lambda (t) (V (string-append "p|abholung|" (cell KIEZ t)))) PER))
            (cons 'trained (map (lambda (t)
                                  (apply + (map (lambda (n) (V (Tkey n SKILL t))) TRAINEES)))
                                PER))
            ;; hours the TRAINEES actually work under the Ausweis — competence,
            ;; not the training activity that produces it
            (cons 'novice-work
                  (map (lambda (t)
                         (apply + (map (lambda (n)
                                         (V (string-append "w|" n "|" SKILL "|" (cell KIEZ t))))
                                       TRAINEES)))
                       PER))))))

(define (g k r) (cdr (assq k r)))
(define (total k r) (apply + (g k r)))
(define (row tag xs) (format #t "  ~20a~{~7,2f~}~%" tag xs))

;;; ═══ 1. mentor capacity is the ceiling on a district's growth ═══════════════
;;; The trainees are willing and present in every run. What changes is how many
;;; hours an experienced Foodsaver can spare, and that alone moves the plan.
(define thin  (run #:mentor-hours 8.0  #:kit-sets 60))
(define fat   (run #:mentor-hours 20.0 #:kit-sets 60))
(define pair  (run #:mentor-hours 20.0 #:mentors '("Bo" "Cem") #:kit-sets 60))

(format #t "~%── the kit is ample; only MENTOR hours differ ──~%")
(format #t "  period                       0      1      2      3~%")
(row "one mentor,  8 h" (g 'pickups thin))
(row "one mentor, 20 h" (g 'pickups fat))
(row "two mentors, 20 h" (g 'pickups pair))
(row "novice hours (20 h)" (g 'novice-work fat))
(format #t "  Σ trained — thin ~,2f · fat ~,2f · pair ~,2f~%"
        (total 'trained thin) (total 'trained fat) (total 'trained pair))
(format #t "  Σ pickups — thin ~,2f · fat ~,2f · pair ~,2f~%"
        (total 'pickups thin) (total 'pickups fat) (total 'pickups pair))

(check "training happens at all — the plan funds its own Foodsavers"
       (> (total 'trained fat) 0.0))
(check "more qualified hours ⇒ more food rescued, trainees unchanged"
       (< (total 'pickups thin) (total 'pickups fat)))
;; NOT monotone, and that is the finding: a mentor-hour spent teaching is a
;; mentor-hour not spent picking, so the plan SUBSTITUTES between them. The
;; district with more hours teaches no more than the one with fewer — it simply
;; picks more. Teaching is not a free by-product of having capacity.
(check "teaching competes with picking for the SAME hours (non-monotone)"
       (not (< (total 'trained thin) (total 'trained fat))))
(check "a second experienced Foodsaver raises the ceiling again"
       (>= (total 'pickups pair) (total 'pickups fat)))
(check "no novice works in period 0 — the Ausweis lags the training"
       (< (car (g 'novice-work fat)) 1e-6))
(check "… and they do work once taught"
       (> (apply + (cdr (g 'novice-work fat))) 0.0))

;;; ═══ 1b. the capacity trap, made measurable ═══════════════════════════════
;;; If teaching and picking draw on one budget, then a Kiez under pressure to
;;; deliver TODAY will not build the capacity it needs TOMORROW. That is the
;;; thing every foodsharing district actually reports — nobody has time to
;;; onboard newcomers.
;;;
;;; A trap about TOMORROW needs a tomorrow to point at. This asked it with a
;;; want that was the same in every period, and then read "the slack district
;;; teaches more" off a plan where teaching served nothing at all: with no later
;;; demand, capacity built now is capacity for no one, and the honest plan does
;;; not build it. What made that read as teaching was the barrier's residue —
;;; the slack district has idle mentor-hours and the old central-path floor
;;; pushed the training column out into them. Deriving the floor from the
;;; certified gap removed it, the ordering inverted, and the finding turned out
;;; to be an artefact. See planner-coherence-open-threads.md §7.4.
;;;
;;; So the demand RISES. Both districts face the same surge in periods 2–3; they
;;; differ only in whether they are already flat out before it arrives. Nothing
;;; tells either to train — training is simply what the surge is worth.
(define CALM  120.0)
(define SURGE 2400.0)
(define breathing (run #:mentor-hours 20.0 #:kit-sets 60
                       #:demand-profile (list CALM CALM SURGE SURGE)))
(define pressed   (run #:mentor-hours 20.0 #:kit-sets 60
                       #:demand-profile (list SURGE SURGE SURGE SURGE)))

(format #t "~%── the same district, room to breathe vs flat out ──~%")
(format #t "  period                       0      1      2      3~%")
(row "breathing: trained" (g 'trained breathing))
(row "pressed:   trained" (g 'trained pressed))
(row "breathing: pickups" (g 'pickups breathing))
(row "pressed:   pickups" (g 'pickups pressed))

(define (early k r) (+ (list-ref (g k r) 0) (list-ref (g k r) 1)))
(define (surge k r) (+ (list-ref (g k r) 2) (list-ref (g k r) 3)))

(format #t "~%  Σ trained — breathing ~,2f · pressed ~,2f~%"
        (total 'trained breathing) (total 'trained pressed))
(format #t "  pickups before the surge — breathing ~,2f · pressed ~,2f~%"
        (early 'pickups breathing) (early 'pickups pressed))
(format #t "  pickups AT the surge     — breathing ~,2f · pressed ~,2f~%"
        (surge 'pickups breathing) (surge 'pickups pressed))

(check "a district with room to breathe trains; one already flat out does not"
       (> (total 'trained breathing) (* 10.0 (total 'trained pressed))))
(check "… and it trains BEFORE the surge, not during it"
       (and (> (early 'trained breathing) 1.0)
            (< (surge 'trained breathing) 0.1)))
(check "the pressed district rescues more food TODAY"
       (> (early 'pickups pressed) (early 'pickups breathing)))
;; the trap itself: same surge, same roster, same kit — and the district that
;; spent every early hour picking has nobody extra to send when it matters.
(check "… and less when the surge comes — it has nobody extra to send"
       (< (surge 'pickups pressed) (surge 'pickups breathing)))
(check "the capacity it built is capacity it USES — novices carry the surge"
       (> (surge 'novice-work breathing) (* 10.0 (surge 'novice-work pressed))))

;;; ═══ 2. the kit is a POOL, and its size is the other ceiling ═══════════════
;;; Now hold the teaching constant and vary only how many complete kits the
;;; Kiezküche owns. This is the question the wiki cannot ask, because it has no
;;; concept of a kit anyone but you owns.
(define kit1 (run #:mentor-hours 60.0 #:kit-sets 1))
(define kit2 (run #:mentor-hours 60.0 #:kit-sets 2))
(define kit8 (run #:mentor-hours 60.0 #:kit-sets 8))

(format #t "~%── the teaching is ample; only the SHARED KIT differs ──~%")
(format #t "  period                       0      1      2      3~%")
(row "1 kit set"  (g 'pickups kit1))
(row "2 kit sets" (g 'pickups kit2))
(row "8 kit sets" (g 'pickups kit8))
(format #t "  Σ pickups — 1 set ~,2f · 2 sets ~,2f · 8 sets ~,2f~%"
        (total 'pickups kit1) (total 'pickups kit2) (total 'pickups kit8))

(check "one shared kit caps the Kiez at one pickup at a time"
       (<= (apply max (g 'pickups kit1)) 1.0001))
(check "a second kit set raises throughput"
       (> (total 'pickups kit2) (total 'pickups kit1)))
(check "and the pool keeps buying throughput until teaching binds instead"
       (> (total 'pickups kit8) (total 'pickups kit2)))

;;; ═══ 3. which ceiling binds is a question with an answer ═══════════════════
;;; The point of holding both in one model: a Kiez can ask whether its next hour
;;; is better spent teaching or its next euro on another Kühlbox, and the plan
;;; answers.
(define scarce-both (run #:mentor-hours 8.0  #:kit-sets 1))
(define more-kit    (run #:mentor-hours 8.0  #:kit-sets 8))
(define more-mentor (run #:mentor-hours 60.0 #:kit-sets 1))

(format #t "~%── which ceiling binds? both scarce, then relieve one at a time ──~%")
(format #t "  both scarce            Σ pickups ~,2f~%" (total 'pickups scarce-both))
(format #t "  + more kit             Σ pickups ~,2f~%" (total 'pickups more-kit))
(format #t "  + more mentor hours    Σ pickups ~,2f~%" (total 'pickups more-mentor))

(check "relieving EITHER ceiling helps when both bind"
       (and (>= (total 'pickups more-kit) (total 'pickups scarce-both))
            (>= (total 'pickups more-mentor) (total 'pickups scarce-both))))
(check "the plan names which relief buys more — a question the wiki cannot pose"
       (not (= (total 'pickups more-kit) (total 'pickups more-mentor))))

(format #t "~%══ ~a passed, ~a failed ══~%" *pass* *fail*)
(when (> *fail* 0) (exit 1))
