;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-federated-repro.scm — reproduction floors ACROSS a vat boundary.
;;;
;;; "Free healthy food for everyone in the city" is not a claim about one commune.
;;; A city is many scopes, and the people who need feeding are rarely in the scope
;;; that grows the food. Until now the per-person subsistence floors
;;; (live.scm `scope-consumption`, knowledge/subsistence-catalogue.scm) worked only
;;; INSIDE a scope: `solve/federation-solve.scm` carried no floors at all, so a federated
;;; solve could not express "this commune's people are hungry".
;;;
;;; It carries them now (`commune->scope-record #:repro-floors`), and this test
;;; pins what that buys:
;;;
;;;   KIEZ has people and no food. Its floors are unclosable on its own.
;;;   FARM has food and no people. Its food is #:never-raw, so it is genuinely
;;;        the only source.
;;;   Alone, the Kiez starves. Federated, the ADMM finds the pull at which the
;;;        farm supplies and every body's floor closes.
;;;
;;; The floors are the REAL ones — `subsistence-floors` over the catalogue's
;;; L0–L4 layers, so the pregnant person's iron floor is 27/18 of the base and the
;;; solve has to actually find it.
;;;
;;; What crosses the boundary is a GOOD and its PULL. No person, no plate, no
;;; intake record — the neighbouring commune learns λ, never who ate what.
;;;
;;; Run: guile -L module/playnet/planner tests/solve/test-federated-repro.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve federation-solve) (playnet solve plan)
             (playnet solve compile)
             (playnet vf schemas))
(use-modules (playnet knowledge catalogues subsistence)
             (playnet knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

;; ── the world ────────────────────────────────────────────────────────────────
(define FARM "farm") (define KIEZ "kiez")
(define (place id lat lon) (place* id #:lat lat #:lon lon))
(define (res spec loc q) (er (string-append spec "@" loc) spec #f #:place loc #:qty q #:unit "kg"))
(define (worker id loc) (person* id #:place loc #:tags '("general")))

;; what a kilo of the food that crosses carries. [DRAFT] — a plain, generous staple.
(define *food-per-kg*
  '(("energy" . 2500.0) ("protein" . 70.0) ("iron" . 12.0)
    ("calcium" . 500.0) ("zinc" . 7.0) ("fibre" . 15.0)))
(define %delivers (map car *food-per-kg*))

;; the three people of the Kiez, as subsistence CONTEXTS — the catalogue does the
;; rest. The pregnant one is the discriminating case: her iron floor is 27/18 of
;; the female base, so a plan that feeds "everyone the same" misses her.
(define *kiez-people*
  `(("ada"  . ((sex . "F") (age . 30) (region . "temperate") (labour-hours . 5)))
    ("bo"   . ((sex . "M") (age . 30) (region . "temperate") (labour-hours . 8)))
    ("cleo" . ((sex . "F") (age . 30) (region . "temperate") (labour-hours . 3)
               (pregnant . #t)))))

;; THE INTERMEDIATE CROSSES, NOT THE FINISHED GOOD. solve/federation-solve.scm's design
;; notes say it in as many words: drawing the good the barrier directly wants is
;; a free source the barrier grabs regardless, and the dual diverges. A first draft
;; of this test had `food` cross — the very good EAT consumes — and λ ran to 5e16
;; without converging in 200 rounds.
;;
;; So the farm supplies GRAIN and the Kiez mills it into food. What is drawn is then
;; one step behind what the floors pull on, the coupling binds, and the pull is
;; finite. The mill costs a little labour, which is also more honest: nobody eats
;; a sack of grain.
(define mill-procs (list (rp "mill" "Mill grain into food")))
(define mill-flows
  (list (consume* "m<" "grain" 1.0 "mill")
        (out* "m>" "food" 1.0 "mill" #:primary #f)
        (wrk "mw" 0.02 "mill")))

;; one EAT recipe per person: 1 kg food → that person's nutrient goods.
(define (eat-recipe pid)
  (let ((rid (string-append "eat~" pid)))
    (cons (rp rid (string-append "eat (" pid ")"))
          (cons (consume* (string-append rid "<") "food" 1.0 rid)
                (map (lambda (nu)
                       (out* (string-append rid ">" (car nu)) (string-append (car nu) "|" pid)
                             (cdr nu) rid "unit" #:primary #f))
                     *food-per-kg*)))))

;; that person's floors, guarded to what the menu can deliver — the same guard
;; scope-consumption applies, so no floor is set on a nutrient no food supplies.
(define (person-floors pid ctx)
  (filter-map (lambda (fl)
                (and (member (car fl) %delivers)
                     (cons (lg (string-append (car fl) "|" pid) (cell KIEZ 0)) (cdr fl))))
              (subsistence-floors ctx)))

(define kiez-procs (append mill-procs (map car (map (lambda (p) (eat-recipe (car p))) *kiez-people*))))
(define kiez-flows (append mill-flows (append-map cdr (map (lambda (p) (eat-recipe (car p))) *kiez-people*))))
(define kiez-floors (append-map (lambda (p) (person-floors (car p) (cdr p))) *kiez-people*))

(format #t "~%── the Kiez's real floors, from the catalogue (L0–L4) ──~%")
(for-each (lambda (p)
            (let ((fl (person-floors (car p) (cdr p))))
              (format #t "  ~6a ~a floors · energy ~,0f · iron ~,1f~%" (car p) (length fl)
                      (or (assoc-ref fl (lg (string-append "energy|" (car p)) (cell KIEZ 0))) 0)
                      (or (assoc-ref fl (lg (string-append "iron|" (car p)) (cell KIEZ 0))) 0))))
          *kiez-people*)

(define preg-iron
  (assoc-ref (person-floors "cleo" (assoc-ref *kiez-people* "cleo"))
             (lg "iron|cleo" (cell KIEZ 0))))
(define ada-iron
  (assoc-ref (person-floors "ada" (assoc-ref *kiez-people* "ada"))
             (lg "iron|ada" (cell KIEZ 0))))
(check "the catalogue raises the pregnant person's iron floor above the base"
       (> preg-iron (* 1.4 ada-iron)))

;; ── 1. the Kiez ALONE : the floors cannot close ──────────────────────────────
(define alone
  (call-with-values
    (lambda ()
      (plan-from-records '() (list (worker "ada" KIEZ)) (list (place KIEZ 52.5 13.4))
        kiez-procs kiez-flows
        #:periods '(0) #:repro-floors kiez-floors #:never-raw '("food" "grain")
        #:per-agent? #f #:backend 'native-c #:allow-infeasible? #t))
    (lambda (i c m fill cols x idx n rep)
      (list (cons 'fill fill)
            (cons 'feasible (assq-ref (assq-ref rep 'certificate) 'feasible?))))))

(format #t "~%── the Kiez alone, food marked never-raw ──~%")
(format #t "  feasible? ~a~%" (assq-ref alone 'feasible))
(check "a Kiez with no food and no boundary cannot close its floors"
       (not (assq-ref alone 'feasible)))

;; ── 2. FEDERATED : farm supplies, Kiez draws, floors drive the pull ────────
;; HOW MUCH FOOD THESE THREE BODIES NEED — and the answer is not what one
;; nutrient says. A first draft of this comment computed it from iron alone and
;; got 4.42 kg; the real figure is 6.25, because THE BINDING NUTRIENT DIFFERS PER
;; PERSON. Per kg this food carries 2500 kcal, 70 g protein, 12 mg iron, 500 mg
;; calcium, 7 mg zinc, 15 g fibre; against each body's floors that gives:
;;
;;   person  energy protein  iron  calcium  zinc  fibre | binds on
;;   ada       0.95    0.71  1.50    2.00   1.14   1.87 | CALCIUM  2.00 kg
;;   bo        1.17    1.07  0.67    2.00   1.57   1.87 | CALCIUM  2.00 kg
;;   cleo      0.99    0.92  2.25    2.00   1.14   1.87 | IRON     2.25 kg
;;                                                        ───────  6.25 kg
;;
;; This is the argument FOR per-individual floors, derived rather than asserted:
;;   · one ration for everyone, sized to the average, starves cleo of iron;
;;   · sizing by iron — the obvious nutrient for a pregnant person — starves all
;;     three of calcium;
;;   · only per-person, per-nutrient floors land on 6.25.
;;
;; Note too that cleo's iron floor is 50 % above ada's (27 vs 18) but she needs
;; only 12 % more food (2.25 vs 2.00), because the binding constraint moves. A
;; nutritional requirement does not map linearly onto a quantity of food, and
;; "how much food does a city need" depends jointly on who is in it and on what
;; the available food is made of.
(define %total-food-needed 6.25)
(define %farm-stock 8.0)
(define (farm-record stock)
  (commune->scope-record
    (list (res "grain" FARM stock)) (list (worker "far" FARM)) (list (place FARM 52.4 13.0))
    '() '()
    #:id "farm" #:never-raw '("grain") #:crossing '("grain")))
(define farm-rec (farm-record %farm-stock))

(define kiez-rec
  (commune->scope-record
    '() (list (worker "ada" KIEZ)) (list (place KIEZ 52.5 13.4))
    kiez-procs kiez-flows
    #:id "kiez" #:never-raw '("food" "grain") #:crossing '("grain")
    #:repro-floors kiez-floors))

(define fed
  (call-with-values (lambda () (federated-solve (list farm-rec kiez-rec) #:iters 200))
    (lambda (plans met rounds pulls) (list plans met rounds pulls))))

(define plans  (list-ref fed 0))
(define met    (list-ref fed 1))
(define rounds (list-ref fed 2))
(define pulls (list-ref fed 3))

(format #t "~%── federated: farm ⇄ kiez, coupled only by the pull of food ──~%")
(format #t "  rounds ~a · met ~a~%" rounds met)
(format #t "  pull λ(grain) = ~a~%" (hash-ref pulls "grain" 'none))

;; decode the Kiez's own plan: how much of each nutrient reached each person
(define kiez-material
  (federated-materials (cadr plans) (assq-ref kiez-rec 'cols) (assq-ref kiez-rec 'idx)))

(define (delivered nut pid)
  (fold (lambda (m acc)
          (if (and (eq? (assq-ref m 'action) 'produce)
                   (equal? (assq-ref m 'conforms-to) (string-append nut "|" pid)))
              (+ acc (abs (or (assq-ref m 'quantity) 0)))
              acc))
        0.0 kiez-material))

(format #t "~%  per person, delivered vs floor:~%")
(define shortfalls
  (append-map
   (lambda (p)
     (let ((pid (car p)))
       (filter-map
        (lambda (fl)
          (let* ((key (car fl)) (need (cdr fl))
                 (nut (substring key 0 (string-index key #\|)))
                 (got (delivered nut pid)))
            (and (< got (* 0.999 need)) (list pid nut got need))))
        (person-floors pid (cdr p)))))
   *kiez-people*))

(for-each (lambda (p)
            (let ((pid (car p)))
              (format #t "    ~6a energy ~8,0f/~6,0f · iron ~6,1f/~5,1f · protein ~6,1f/~5,1f~%"
                      pid
                      (delivered "energy" pid)
                      (or (assoc-ref (person-floors pid (cdr p)) (lg (string-append "energy|" pid) (cell KIEZ 0))) 0)
                      (delivered "iron" pid)
                      (or (assoc-ref (person-floors pid (cdr p)) (lg (string-append "iron|" pid) (cell KIEZ 0))) 0)
                      (delivered "protein" pid)
                      (or (assoc-ref (person-floors pid (cdr p)) (lg (string-append "protein|" pid) (cell KIEZ 0))) 0))))
          *kiez-people*)

(when (pair? shortfalls)
  (format #t "~%  shortfalls: ~a~%" shortfalls))

;; a real convergence test: it must STOP before the iteration cap, and the pull
;; must be finite. The first draft asserted only (> rounds 0), which is vacuous —
;; it passed while the dual was diverging to 5e16 at the 200-round ceiling.
(check "the ADMM converges — it stops before the iteration cap"
       (and (number? rounds) (< rounds 200)))
(check "grain carries a FINITE boundary pull — the floors drive it, and it settles"
       (let ((l (hash-ref pulls "grain" #f)))
         (and l (> (abs l) 0.0) (< (abs l) 1e6))))
(check "EVERY person's EVERY deliverable floor is met across the boundary"
       (null? shortfalls))
(check "including the pregnant person's raised iron floor"
       (>= (delivered "iron" "cleo") (* 0.999 preg-iron)))
;; `met` is demand-fill, and this solve states NO demand — only floors. 0.0 is
;; the correct reading of "nothing was asked for beyond subsistence", and it is
;; worth pinning so a future reader does not mistake it for starvation.
(check "met is 0 because nothing was DEMANDED — the floors are not demand"
       (= 0.0 met))
(check "the split is unequal — the plan feeds bodies, not portions"
       (let ((ec (delivered "energy" "cleo")) (eb (delivered "energy" "bo")))
         (> (abs (- ec eb)) 1.0)))
(check "total food drawn matches the 6.25 kg the floors actually need"
       (let ((total (/ (fold + 0.0 (map (lambda (p) (delivered "energy" (car p))) *kiez-people*))
                       2500.0)))
         (and (>= total (* 0.99 %total-food-needed)) (<= total (+ %farm-stock 0.01)))))
(check "ada's iron overshoots her floor because CALCIUM binds her, not iron"
       (let ((iron (delivered "iron" "ada")))
         (and (> iron (* 1.2 ada-iron)) (< (abs (- iron 24.0)) 6.0))))
(check "nothing about a person crossed the boundary — only the good did"
       (null? (filter (lambda (m) (let ((s (assq-ref m 'conforms-to)))
                                    (and (string? s) (string-index s #\|))))
                      (federated-materials (car plans)
                                           (assq-ref farm-rec 'cols)
                                           (assq-ref farm-rec 'idx)))))

;; THE FEDERATED SOLVE KEEPS THE RELAXATION, and says so. A Kiez whose mill is
;; declared a whole count is solved here to the digit — the ADMM's guarantee is
;; convex — and its record, its per-scope result and the wire name the scope.
(check "a scope with nothing declared is marked none"
       (and (eq? 'none (assq-ref kiez-rec 'discrete)) (null? (federated-relaxed-scopes (list farm-rec kiez-rec)))))
(let* ((whole-kiez (commune->scope-record
                     '() (list (worker "ada" KIEZ)) (list (place KIEZ 52.5 13.4))
                     (cons (rp* "mill" "Mill grain into food" #:tags '("whole-count"))
                           (cdr kiez-procs))
                     kiez-flows
                     #:id "kiez" #:never-raw '("food" "grain") #:crossing '("grain")
                     #:repro-floors kiez-floors))
       (recs (list (farm-record %farm-stock) whole-kiez))
       (per (call-with-values (lambda () (federated-solve recs #:iters 200))
              (lambda (plans met rounds pulls) (federated-per-scope plans recs)))))
  (check "a scope declaring a whole count is marked relaxed by the federated solve"
         (eq? 'relaxed (assq-ref whole-kiez 'discrete)))
  (check "…its per-scope result carries the word" (eq? 'relaxed (assq-ref (caddr (assoc "kiez" per)) 'discrete)))
  (check "…and the relaxed scopes are named for the wire" (equal? '("kiez") (federated-relaxed-scopes recs))))

;;; ─── THE LIMIT : a floor with no desire above it has no pull to settle at ─
;;; Traced round by round, and the answer is not either of the two things an
;;; earlier draft of this comment claimed. It is not infeasibility, and it is not
;;; the farm being at its bound.
;;;
;;; Round-by-round, supply 5.0 against a floor of 4.5:
;;;
;;;   it | supplied |  drawn | residual |    λ
;;;    1 |   5.000 |   4.501 |    0.499 | -14.3
;;;    5 |   4.999 |   4.501 |    0.498 | -8.53
;;;   20 |   5.000 |   4.501 |    0.499 | -14.1     ← frozen, then λ blows up
;;;
;;; The KIEZ, which draws, stands exactly at its floor — it is behaving
;;; perfectly. The FARM, which supplies, sends its whole stock, because grain
;;; has no other use at the farm: holding it back costs nothing and gains
;;; nothing. So:
;;;
;;;   what the farm supplies is a curve VERTICAL at its stock
;;;   a bare floor is a demand curve VERTICAL at the floor
;;;   two vertical lines at different quantities never intersect
;;;
;;; The residual is frozen at stock − floor. It is not a disagreement about
;;; the pull. NOBODY WANTS THE LAST 0.5 kg, and ADMM's whole job is to make
;;; what is supplied equal what is drawn, which needs someone to want the
;;; marginal unit.
;;;
;;; Give the Kiez any real desire above subsistence and it settles at once — with
;;; the farm STILL at its bound, which is what rules the bound out as the
;;; cause:
;;;
;;;   floor only, no desire   | 200 rounds | supplied 5.000 | drawn 4.500 | diverges
;;;   floor + wants 0.2 more  | 200 rounds | supplied 5.000 | drawn 4.526 | diverges
;;;   floor + wants 1.0 more  |  12 rounds | supplied 5.000 | drawn 5.000 | SETTLES
;;;   floor + wants 5.0 more  |  11 rounds | supplied 5.000 | drawn 5.000 | SETTLES
;;;
;;; and the cases that looked hopeless before settle too, once desire is stated:
;;;
;;;   supply 4.6, floor 4.5, wants 2.0 | 12 rounds | SETTLES
;;;   supply 6.0, floor 4.5, wants 2.0 | 12 rounds | SETTLES
;;;   supply 3.0, floor 4.5, wants 2.0 | 200 rounds | diverges  ← genuinely impossible
;;;
;;; So there are TWO different divergences, and only one of them is a real
;;; problem:
;;;
;;;   (a) supply < floor — no allocation exists. Divergence is the right answer,
;;;       and `plan-dilemma` is the machinery for reporting it as a dilemma.
;;;   (b) surplus nobody claims — an artifact of a scope stating ONLY floors.
;;;
;;; (b) is a MODELLING error, not an engine defect. A scope that states floors
;;; and no desire is telling the federation "I want exactly subsistence and not
;;; one gram more", which is neither true of any commune nor clearable. Desire
;;; above the floor is already a first-class channel (`#:demand`,
;;; `desire-weights`); stating it is what a real scope does anyway.
(define (probe-limit supply want iters)
  (let ((k (commune->scope-record '() (list (worker "ada" KIEZ)) (list (place KIEZ 52.5 13.4))
             kiez-procs kiez-flows
             #:id "kiez" #:never-raw '("food" "grain") #:crossing '("grain")
             #:demand (if (> want 0)
                          (map (lambda (p) (cons (lg (string-append "energy|" (car p)) (cell KIEZ 0))
                                                 (* want 2500.0)))
                               *kiez-people*)
                          '())
             #:repro-floors kiez-floors)))
    (call-with-values
      (lambda () (federated-solve (list (farm-record supply) k) #:iters iters))
      (lambda (plans met rounds pulls)
        (list rounds (or (hash-ref pulls "grain" #f) 0.0))))))

(define bare    (probe-limit 8.0 0.0 60))   ; floors only, surplus unclaimed
(define desired (probe-limit 8.0 1.0 60))   ; the same surplus, wanted
(define starved (probe-limit 3.0 1.0 60))   ; genuinely below subsistence

(format #t "~%── the limit: who wants the marginal unit? (floors need 6.25 kg) ──~%")
(format #t "  supply 8.0, floors only        → rounds ~a · λ ~,3g~%" (car bare) (cadr bare))
(format #t "  supply 8.0, + desire above     → rounds ~a · λ ~,3g~%" (car desired) (cadr desired))
(format #t "  supply 3.0, + desire (< floors)→ rounds ~a · λ ~,3g~%" (car starved) (cadr starved))

;; NOTE, so this is not read as more than it is: at supply 8.0 the floors-only
;; case ALSO settles (27 rounds), because the residual there is large enough that
;; ρ-adaptation forces consensus. So this configuration does not discriminate
;; between "floors only" and "floors + desire" — the evidence for that
;; distinction is the single-good sweep quoted in the comment above, where the
;; residual is small (0.5) and only desire closes it. Asserted here is the part
;; this configuration DOES show: the two divergence causes are different things.
(check "a want genuinely below subsistence does not settle — correctly, no allocation exists"
       (>= (car starved) 60))
(check "a surplus that settles and a shortfall that cannot are distinguishable"
       (and (< (car desired) 60) (>= (car starved) 60)))
(check "at THIS supply the floors-only case already settles — so this run does not
         test the desire effect; the single-good sweep does"
       (< (car bare) 60))

;; ── stage 4 (truth-telling.md): pulls between scopes, persons never ──
;; The federation's λ surfaced per member scope, and what a scope's
;; membership displaces in the others: solve/externality.scm's
;; withdrawal-displacement over scope records.
(format #t "~%── stage 4: the fold's pulls, per scope ──~%")
(define scope-pulls (federated-scope-pulls (list farm-rec kiez-rec) plans pulls))
(format #t "  ~s~%" scope-pulls)
(check "every member scope has a row of boundary pulls"
       (equal? (map car scope-pulls) '("farm" "kiez")))
(check "the farm supplies grain and the kiez draws it — read off their flows — at ONE pull λ"
       (let ((f (cdr (assoc "farm" scope-pulls))) (k (cdr (assoc "kiez" scope-pulls))))
         (and (= (length f) 1) (= (length k) 1)
              (> (cadr (car f)) 6.0) (< (cadr (car k)) -6.0)
              (< (abs (+ (cadr (car f)) (cadr (car k)))) 1e-2)
              (equal? (caddr (car f)) (caddr (car k)))
              (equal? (caddr (car f)) (hash-ref pulls "grain" #f)))))
(define base #f)   ; solved inside: the read needs the certificate's per-scope feasibility
(define kiez-got (federated-delivered kiez-rec (cadr plans)))
(format #t "  delivered to the kiez of what it asked: ~a~%" kiez-got)
(check "the kiez's delivered reading is positive: the farm's grain fed it"
       (> kiez-got 0.0))
(define farm-displacement (federated-withdrawal-displacement (list farm-rec kiez-rec) "farm" #:iters 200 #:base base))
(format #t "  what the farm's membership displaces in the others (withdrawn): ~a~%" farm-displacement)
(check "with the only scope that supplies withdrawn the kiez loses everything: its floors cannot close alone"
       (< (abs (- farm-displacement (- kiez-got))) (* 0.05 (max kiez-got 1e-9))))
(define kiez-displacement (federated-withdrawal-displacement (list farm-rec kiez-rec) "kiez" #:iters 200 #:base base))
(format #t "  what the kiez's membership displaces in the others (withdrawn): ~a~%" kiez-displacement)
(check "with the only scope that draws withdrawn the farm loses nothing (it asked for nothing)"
       (< (abs kiez-displacement) 1e-6))

(format #t "~%══ ~a passed, ~a failed ══~%" *pass* *fail*)
(when (> *fail* 0) (exit 1))
