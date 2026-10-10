;;; berlin-festival-seed.scm — the food festival, LIVE on the Berlin commune.
;;;
;;; The live half of tests/planner/test-berlin-festival.scm over the same real
;;; Baumkataster ground: twelve Bezirke of street-tree pits, each Bezirk a
;;; PLACE of its own (knowledge/berlin-baumscheiben.scm carries the register's
;;; centroids), the same two crops with the register's own shade read, seeded
;;; into a scope's ordinary VF stores so the whole user arc runs over it: the
;;; crowd's need stands in the demand fold, growing is WORK a citizen raises a
;;; hand for (skill "gardening"), the harvest is CARRIED to the festival ground
;;; by cargo bike (skill "cycling"), the solve schedules both, the presentation
;;; caller offers them, and an accept pins one.
;;;
;;; The recipes are what ValueFlows means them to be: ONE "Grow salad" and
;;; ONE "Grow beans", location-agnostic templates the engine tiles over the
;;; districts through its own place dimension (a column is (proc, place,
;;; period); a shift's id carries its place). A district's harvest is the
;;; located act (proc . place), and that is the handle every district-level
;;; fact holds: the site's shade multiplies the yield there, and a permission
;;; withdrawal zeroes it there — as shocks on the located column, not as a
;;; process minted per district.
;;;
;;; The FUTURES ride too: attach-festival-futures! crosses the shed's weather
;;; with permission (citywide hold + twelve single-Amt withdrawals, [DRAFT]
;;; elicited probabilities) onto the "berlin" bioregion, every branch carrying
;;; the districts' own shade, and the crowd's terms stand two-tier — a FLOOR
;;; held in every branch (the fold routes kind floor → #:repro-floors) with
;;; the want above it. Defending the floor under revocable permission is what
;;; spreads the planting across the districts — distribution derived, no new
;;; solver, the engine test's claim on live machinery.
;;;
;;; A durable commune seeded under the earlier shape (a process per district,
;;; a spec per district, pits pooled at the festival ground) gains this one on
;;; its next boot: the old processes retire from the store, the old pit rows
;;; are re-seeded as the districts' own, and nothing of that shape solves
;;; again.
(define-module (playnet knowledge recipes berlin-festival-seed)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module (playnet knowledge dsl shorthand)
  #:use-module (playnet knowledge dsl world)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf beyond schedules)
  #:use-module (playnet vf beyond scenario)
  #:use-module (playnet knowledge worlds bioregions)
  #:use-module (playnet knowledge worlds berlin-baumscheiben)
  #:use-module ((playnet vf facts tension-terms) #:select (with-tension-terms))
  #:use-module ((playnet knowledge recipes farm-commune-seed) #:select (seed-holds!))
  #:use-module ((playnet knowledge recipes transit-shed) #:select (seed-relocation-recipe!))
  #:use-module ((playnet utils clock) #:select (now instant->civil civil->instant))
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:export (festival-world seed-berlin-festival-arm! attach-festival-futures!
            festival-grow-id festival-site-shocks))

;; SHADE, from the register's median tree age per Bezirk (the test's read:
;; old lindens shade and dry their pits; the 0.012/yr slope is a judgment
;; figure, the ages under it are data)
(define (shade b) (max 0.5 (- 1.0 (* 0.012 (- (bs-age b) 34)))))

;; two crops on a Baumscheibe: yields kg/m²/season [DRAFT, the test's]
(define %crops '(("beans" . 1.0) ("salad" . 2.0)))
;; ONE process per crop — the template every district's column is tiled from
(define (festival-grow-id crop) (string-append "grow-" crop))
(define %grow-ids (map (lambda (c) (festival-grow-id (car c))) %crops))

;; tending a pit is people's time: 0.5 h per m² per season, as WORK the
;; willingness rail runs over — the live seed's one deliberate departure
;; from the test's crew-hours-as-stock
(define %h-per-m2 0.5)
(define %skill "gardening")
;; the carry: the harvest reaches the festival ground by cargo bike, a
;; relocation the engine tiles along the district → ground arc (transit-shed
;; seed-relocation-recipe!, transport.scm's per-unit·km rates). 40 kg per
;; trip, 0.08 h per trip-km (a laden Lastenrad's pace across the city).
(define %carry "carry-harvest")
(define %cycle "cycling")
(define %carry-kg 40.0)
(define %carry-h-per-km 0.08)

;; a worker's day, as the availability the solve's banding reads: hours a
;; PERSON keeps, so no band of the plan lands in the middle of the night
(define (working-window start end)
  (make-availability-window #f #f
    (list (make-day-schedule '(monday tuesday wednesday thursday friday saturday sunday)
                             (list (make-time-range start end))))
    #f))

;; the district's own yield, in every future: (proc . place) → shade
(define (festival-site-shocks)
  (append-map (lambda (b)
                (map (lambda (p) (cons (cons p (bs-place b)) (shade b))) %grow-ids))
              *berlin-baumscheiben*))

;; a crew member's skill, in the shape declare-skill writes — so
;; skill-holders and the candidate field read it
(define (skill-resource crew skill)
  (make-economic-resource
   #:id (string-append "skill:" crew ":" skill)
   #:name (string-append crew " " skill)
   #:conforms-to skill
   #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable crew))

;; ── the earlier shape leaves ────────────────────────────────────────────────
;; A store seeded before 2026-09-03 holds a grow process per (crop, district)
;; and a hold per district spec, all at the festival ground. Each retires
;; through the store's own door — its flows and recipes with it — the first
;; time this seed meets it, and the districts' pit rows are re-seeded below
;; under the shared spec at their own places (the same row ids: a re-seed is
;; an upsert). Idempotent: a store without the shape is left alone.
(define (retire-district-shape! rs ps place)
  (let* ((olds (append-map
                (lambda (b)
                  (cons (string-append "hold-" (bs-spec b) "-" place)
                        (map (lambda (c) (string-append "grow-" (car c) "-" (bs-place b))) %crops)))
                *berlin-baumscheiben*))
         (old? (lambda (proc) (and proc (member proc olds) #t)))
         ;; the plan-store's records ON those processes — laid shifts, offers,
         ;; standing accepts — have no column left to stand in; they leave
         ;; whenever they are met, whether the processes left on this boot or
         ;; an earlier one (accepts->pins reads any straggler as void, too)
         (coms (filter-map (lambda (c) (and (old? (commitment-input-of c)) (commitment-id c)))
                           ($ ps 'all-commitments)))
         (ints (filter-map (lambda (i) (and (old? (intent-input-of i)) (intent-id i)))
                           ($ ps 'all-intents))))
    (for-each (lambda (id) (when ($ rs 'get-recipe-process id) ($ rs 'retire-recipe-process id)))
              olds)
    (when (or (pair? coms) (pair? ints))
      (format (current-error-port)
              "  [festival] the earlier shape leaves: ~a commitment(s), ~a intent(s) on retired processes~%"
              (length coms) (length ints))
      ($ ps 'remove-records olds coms ints))))

(define* (festival-world #:key (place "berlin-festival") (shed "berlin"))
  "The festival arm as data. The ground: the festival place and every Bezirk,
   each a place of its own with the register's centroid, all contained-in the
   shed — a drought is a drought in every one of them. The specs: the meal,
   the two skills, and the ONE pit spec every district's ground conforms to.
   Every district's plantable pit area, at its own place. One grow recipe per
   crop — consume pits, the tending as gardening work, the crop at its
   nominal yield (the site says the rest). The acts stay DIVISIBLE, as a cost
   decision made with open eyes: a minimumBatchQuantity here is read
   correctly and certifies on a one-day horizon, while over the crowd's
   three-day window the branch-and-bound across the tiled acts × 40 futures
   runs for minutes per node; the engine's work-emission floor (plan->work)
   keeps sub-act slivers out of the emitted needs, offers and commitments
   instead, at zero solve cost. A Kiez crew per district, at its district,
   holding both skills — every further hand is a citizen's own declare-skill.
   The crew is a COLLECTIVE (an organization agent supplying labour), not a
   dependent of the commune: a person in the roster is reproduced from the
   foods reachable at their cell, and salad and beans alone floor nobody,
   which would starve the program in every future."
  (world-sky   ; each grow states the light its crop stores, the water it transpires and the air it fixes (world.scm)
  (world
   #:spatials (cons (make-spatial-thing #:id place #:name "Berlin food festival" #:lat 52.51
                                        #:long 13.42 #:contained-in shed)
                    (filter (lambda (st) (member (spatial-thing-id st)
                                                 (map bs-place *berlin-baumscheiben*)))
                            (berlin-baumscheiben-spatials #:shed shed)))
   #:specs (list (spec* "meal" "Festival meal" "kg")
                 (spec* %skill "Gardening" %effort-unit)
                 (spec* %cycle "Cargo-bike riding" %effort-unit)
                 (spec* *pit-spec* "Street-tree pits" "m2"))
   #:procs (map (lambda (c) (rp* (festival-grow-id (car c)) (string-append "Grow " (car c)) (* %h-per-m2 1.0)))
                %crops)
   #:flows (append-map
            (lambda (c)
              (let ((p (festival-grow-id (car c))))
                (list (consume* (string-append p "-in") *pit-spec* 1.0 p "m2")
                      (wk* (string-append p "-h") %skill %h-per-m2 p)
                      (out* (string-append p "-out") "meal" (cdr c) p))))
            %crops)
   #:recipes (map (lambda (c) (let ((p (festival-grow-id (car c))))
                                (make-recipe #:id (string-append "r-" p)
                                             #:name (string-append "Grow " (car c))
                                             #:primary-output "meal" #:recipe-processes (list p))))
                  %crops)
   #:agents (map (lambda (b)
                   (make-agent #:id (string-append "w-" (bs-place b)) #:type 'organization
                               #:name (string-append (bs-name b) " Kiez crew") #:primary-location (bs-place b) #:classified-as '()
                               #:availability-window (working-window "09:00" "17:00")))
                 *berlin-baumscheiben*)
   #:resources (append (berlin-baumscheiben-resources #:spec-of (lambda (_) *pit-spec*))
                       (append-map (lambda (b)
                                     (let ((crew (string-append "w-" (bs-place b))))
                                       (list (skill-resource crew %skill) (skill-resource crew %cycle))))
                                   *berlin-baumscheiben*)))))

(define* (seed-berlin-festival-arm! scope #:key (place "berlin-festival")
                                    (shed "berlin") (crowd-kg 60.0))
  "Seed the festival arm onto SCOPE's stores, once (the shared pit spec is
   the guard). CROWD-KG is the standing need at the festival place —
   scaled to a Kiez festival, not the test's 24,000-person city crowd, so
   a live commune's few hands are a real fraction of the work."
  (let ((rs  ($ scope 'recipe-store))
        (obs ($ scope 'observer))
        (as  ($ scope 'agent-store))
        (sts ($ scope 'spatial-thing-store))
        (ps  ($ scope 'plan-store)))
    (retire-district-shape! rs ps place)
    (unless ($ rs 'get-resource-spec *pit-spec*)
      ;; the ground, the specs, the pits, the recipes and the crews, as ONE
      ;; world (festival-world below), seeded through the one door
      (seed-world! scope (festival-world #:place place #:shed shed))
      ;; the carry: pick-up at a district, drop-off at the ground
      (seed-relocation-recipe! rs
        #:process %carry #:recipe (string-append "r-" %carry)
        #:name "Carry the harvest: pick-up → festival"
        #:pspec-name "Cargo-bike haul (pick-up → drop-off)"
        #:good "meal" #:payload %carry-kg #:unit "kg"
        #:duration (make-duration 0.5 %effort-unit)
        #:tags '("tag:transport")
        #:work (cons %cycle %carry-h-per-km)))
    ;; the pits are there tomorrow: a hold per district's ground, so a
    ;; multi-day horizon plants on every day of it — outside the arm's guard,
    ;; idempotent by id, so a durable commune gains them on its next boot
    (for-each (lambda (b)
                (seed-holds! rs obs (bs-place b) (list (cons *pit-spec* "m2"))
                             #:container-name (string-append (bs-name b) "'s ground")))
              *berlin-baumscheiben*)
    ;; …and the festival table: the ground HOLDS the harvest carried to it
    ;; until the crowd eats — which is what makes the ground a cell the
    ;; carry can land on and the crowd's need can stand at
    (seed-holds! rs obs place (list (cons "meal" "kg")) #:container-name "The festival table")
    ;; every crew stands as the collective it is, with its working hours —
    ;; idempotent and outside the arm's guard, so a durable commune that
    ;; seeded its crews as persons, or windowless, gains both on its next boot
    (for-each
     (lambda (b)
       (let* ((crew (string-append "w-" (bs-place b)))
              (a    ($ as 'get-agent crew)))
         (when (and a (or (not (eq? (agent-type a) 'organization))
                          (not (agent-availability-window a))))
           ($ as 'update-agent crew
              (lambda (old)
                (make-agent #:id (agent-id old) #:type 'organization #:name (agent-name old)
                            #:note (agent-note old) #:image (agent-image old)
                            #:primary-location (agent-primary-location old) #:classified-as (agent-classified-as old)
                            #:availability-window (or (agent-availability-window old)
                                (working-window "09:00" "17:00"))))))))
     *berlin-baumscheiben*)
    ;; …and the crowd's terms re-assert: the commune's standing declaration,
    ;; never a one-shot a member's accept may extinguish. Each term carries its
    ;; own WINDOW — a rolling three-day slice of the season, from today — and
    ;; that window is what lays a multi-day horizon under every solve
    ;; (demand-fold cells->horizon), so the plan face shows the days ahead and
    ;; an offer for tomorrow can stand while its forcing point nears. The
    ;; window's length is the solve-cost dial: each added day multiplies the
    ;; extensive form's bands. A boot that finds a term finished, or its
    ;; window behind today, stands it back up on the fresh window.
    ;; The window opens on the first day the crowd can still be SERVED: a
    ;; day whose crews have gone home (the working window ends 17:00, and
    ;; the harvest reaches the ground by their carry) holds no term — a
    ;; floor laid on it would be a wall in the past, unmeetable by anyone,
    ;; and the program would refuse the whole plan for it (found live, at
    ;; 20:00). The re-stand door runs every tick, so the day rolls over the
    ;; moment it is spent.
    (let* ((clock  (instant->civil (now) "%Y-%m-%d %H"))
           (day    (substring clock 0 10))
           (hour   (string->number (substring clock 11 13)))
           (today  (if (>= hour 17)
                       (instant->civil (+ (civil->instant day) 86400) "%Y-%m-%d")
                       day))
           (until (instant->civil (+ (civil->instant today) (* 2 86400)) "%Y-%m-%d"))
           ;; a standing need is re-laid when it is finished, when its window
           ;; has passed, or when its TERMS differ from what the seed states
           ;; today — the crowd's floor gaining `against:1` is a change of
           ;; the right, and the durable store must carry the right as stated
           (reassert (lambda (id cats)
                       (let* ((i ($ ps 'get-intent id))
                              (stale? (and i (or (intent-finished i)
                                                 (not (equal? (intent-resource-classified-as i) cats))
                                                 (let ((b (intent-has-beginning i))
                                                       (u (intent-has-end i)))
                                                   (or (not u) (string<? u today)
                                                       (not b) (string<? b today)))))))
                         (when stale?
                           (format (current-error-port) "  [festival] re-laying ~a (terms ~s)~%" id (intent-resource-classified-as i))
                           ($ ps 'remove-intent id))
                         (or (not i) (and stale? #t)))))
           (floor-cats (append (with-tension-terms '() "floor" 0) '("against:1")))
           (want-cats  (with-tension-terms '() "des" 100)))
    (when (reassert "need:festival-crowd:meal-floor" floor-cats)
      ($ ps 'add-intent
         (make-intent #:id "need:festival-crowd:meal-floor" #:action 'consume #:name "festival floor" #:image "🥗" #:resource-conforms-to "meal"
                      ;; a right held AGAINST ANY ONE district lost — the budgeted
                      ;; wall (engine lay-budgeted-floors), in place of a future
                      ;; per district withdrawn: what is known is "any one may
                      ;; withdraw", and that is all the wall states
                      #:resource-classified-as floor-cats
                      #:resource-quantity (make-measure (* 0.05 crowd-kg) "kg") #:receiver "festival-crowd"
                      #:has-beginning today #:has-end until
                      #:at-location place)))
    (when (reassert "need:festival-crowd:meal" want-cats)
      ($ ps 'add-intent
         (make-intent #:id "need:festival-crowd:meal" #:action 'consume #:name "festival meals" #:image "🥗" #:resource-conforms-to "meal"
                      #:resource-classified-as want-cats
                      #:resource-quantity (make-measure crowd-kg "kg") #:receiver "festival-crowd"
                      #:has-beginning today #:has-end until
                      #:at-location place))))))

;; ── the futures: weather × permission × site, on the shed ───────────────────
;; A withdrawal that lands AFTER planting is a harvest loss — a `produce`
;; shock 0.0 on that district's located grow acts (planting is first-stage,
;; shared by every branch; zeroing the GROUND instead would make planting
;; infeasible outright). Weather reshapes each crop's yield ([DRAFT]
;; responses, the test's), keyed by the crop's one process, so it reaches
;; every district's column. The site's shade rides in every branch. The
;; product rides the "berlin" bioregion's registered futures, so the
;; commune inherits it by containment like every other scope — the farm's
;; own spec shocks stand untouched in every branch.
(define %crop-response
  '(("normal"  . (("beans" . 1.00) ("salad" . 1.00)))
    ("drought" . (("beans" . 0.75) ("salad" . 0.45)))
    ("flood"   . (("beans" . 0.96) ("salad" . 0.96)))
    ;; the p=0 stress tail defends at drought's response — held, not hoped
    ("stress"  . (("beans" . 0.75) ("salad" . 0.45)))))

(define (festival-weather-shocks response)
  (map (lambda (c) (cons (festival-grow-id (car c)) (or (assoc-ref response (car c)) 1.0)))
       %crops))

(define (attach-festival-futures!)
  "Lay the festival over the berlin shed's registered weather futures — every
   branch carrying the districts' own shade and the weather's crop response —
   and re-register the bioregion with the product, every other field kept.
   Permission is not a future here: the crowd's floor is a right held
   AGAINST ANY ONE district lost (the seed's `against:1`, the budgeted wall),
   which states what is known without a probability for each district. The
   p=0 stress tail stays a branch: already defended without one. Idempotent:
   a scenario set already carrying the site's shade is left standing."
  (let ((b (hash-ref *bioregions* "berlin")))
    (when (and b (not (any (lambda (s)
                             (any (lambda (m) (pair? (car m)))          ; a located (proc . place) shock = the site rode already
                                  (or (planning-scenario-yield-multipliers s) '())))
                           (bioregion-scenarios b))))
      (let* ((site   (festival-site-shocks))
             (weather-of (lambda (s)          ; "berlin-drought" → its response row
                           (or (any (lambda (r) (and (string-suffix? (car r)
                                                       (planning-scenario-id s))
                                                     (cdr r)))
                                    %crop-response)
                               (cdar %crop-response))))
             (cross
              (map (lambda (s)
                     (make-planning-scenario
                      (planning-scenario-id s) (planning-scenario-scenario s)
                      (planning-scenario-probability s)
                      (append (or (planning-scenario-yield-multipliers s) '())
                              site (festival-weather-shocks (weather-of s)))
                      (planning-scenario-note s)))
                   (bioregion-scenarios b))))
        (register-bioregion!
         (make-bioregion "berlin" (bioregion-name b)
                         (bioregion-lat b) (bioregion-lon b)
                         (bioregion-parent b)
                         cross
                         (bioregion-fragilities b)))))))
