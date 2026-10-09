;;; module/playnet/planner/knowledge/dsl/vf-lint.scm — is this ValueFlows well formed?
;;;
;;; The planner reads recipes, events and needs as ValueFlows records, and the
;;; rules that make a record solvable were stated in four places: a test per
;;; rule over the recipe tree, the declare and observe doors' own refusals,
;;; the conservation sweep, and the solve's report of what it dropped. This
;;; module states them once, as findings ((playnet planner knowledge dsl findings)),
;;; over two inputs:
;;;
;;;   lint-recipe-store   a recipe store, in its vat — every recipe's chain,
;;;                       every process's flows, the store's specs, and the
;;;                       composition system over the whole set
;;;   lint-records        wire records — the alists a door or a model hands
;;;                       over (events, needs, offers, flows), against the
;;;                       specs and units a scope knows when it has them
;;;
;;; Four readers: tools/lint-recipes.scm (the tree's gate), the planner's
;;; lint-records door, the statute and log extractors' conform checks (a
;;; finding's detail is the fact a model is asked again with), and tests.
;;;
;;; What a finding says is that a record is well formed and coherent with the
;;; scope. Whether the event happened is not its question.

(define-module (playnet planner knowledge dsl vf-lint)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner formulas actions)
  #:use-module (playnet planner knowledge dsl findings)
  #:use-module (playnet planner knowledge catalogues substances)   ; %ambient-kelvin, second-law-production, *heat-carriers*
  #:use-module ((playnet planner knowledge dsl world) #:select (store-composition store-flows))   ; the composition a store stands on, as the solve is handed it
  #:use-module ((playnet utils units) #:select (%intensive-units))
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:export (seed-every-recipe! %vf-actions %input-actions %output-actions %time-units
            lint-recipe-store lint-records))

;;; ─── every recipe in the tree, in one store ──────────────────────────────
;;; The tree is the registry: every `seed-*` the planner umbrella exports is a
;;; recipe seeder by existing. This runs each against RECIPE-STORE; one wanting
;;; anything other than a store errors and is skipped. → (values ran all), the
;;; seeder names that ran and every name tried. Call inside a vat.
(define (seed-every-recipe! recipe-store)
  (let* ((umbrella (resolve-interface '(playnet planner)))
         (seeders (sort (filter (lambda (sym) (string-prefix? "seed-" (symbol->string sym)))
                                (module-map (lambda (sym var) sym) umbrella))
                        (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))
         (ran (filter-map (lambda (sym)
                            (let ((p (false-if-exception (module-ref umbrella sym))))
                              (and (procedure? p)
                                   (false-if-exception (begin (p recipe-store) sym)))))
                          seeders)))
    (values ran seeders)))


;;; ─── the vocabulary ────────────────────────────────────────────────────────
;; The actions are the action table's (vf/schemas.scm), and the side each stands on
;; is the table's reading (formulas/actions.scm), so a recipe is held to the
;; vocabulary the plan and the books read and to no list of this file's own.
(define %vf-actions (map car *action-definitions*))
;; a flow INTO a process names input-of; a flow OUT names output-of
(define %input-actions  process-input-actions)
(define %output-actions process-output-actions)
(define %time-units '("hours" "hour" "h" "minutes" "minute" "days" "day"))
(define (time-unit? u) (and u (member u %time-units) #t))
;; an INTENSIVE unit (degrees, percent moisture) names a state, and a state is a
;; form: a reading is a count of a stock, converted at the door
;; (observation/convert.scm; docs/observation/readings-are-counts.md). A flow in
;; such a unit moves nothing and is refused.
(define (intensive-unit? u) (and u (assoc-ref %intensive-units (format #f "~a" u)) #t))

(define (measure-value m) (and m (measure-has-numerical-value m)))
(define (measure-unit m) (and m (measure-has-unit m)))
(define (positive-measure? m) (let ((v (measure-value m))) (and v (> v 0))))

;;; ─── the recipe store ──────────────────────────────────────────────────────
(define* (lint-recipe-store rs #:key (specs-complete? #t) (ambient-k %ambient-kelvin))
  "Findings over recipe store RS. Call inside RS's vat. SPECS-COMPLETE? says
whether RS holds every spec the recipes may name: a live scope does, so a
missing spec is an error there; a sweep over seeders alone does not (scopes
register the substance and justice specs themselves), so it is an info line."
  (let ((findings '())
        (all-recipes ($ rs 'all-recipes)))
    (define (add! severity kind subject fmt . args)
      (set! findings (cons (finding severity kind subject (apply format #f fmt args)) findings)))
    (define (spec-of id) (and id ($ rs 'get-resource-spec id)))
    (define (flows-of rp) (store-flows rs (recipe-process-id rp)))   ; each flow once, whichever ends it states
    (define (process-hours rp)
      (let ((d (recipe-process-has-duration rp)))
        (and d (> (duration-has-numerical-value d) 0.0) (duration-has-numerical-value d))))
    ;; how long a `use` runs: the flow's effort in a time unit, else its quantity when
    ;; that is the time (shorthand `use*` without a count), else the process's duration
    (define (use-hours f rp)
      (let ((eq (recipe-flow-effort-quantity f)) (rq (recipe-flow-resource-quantity f)))
        (cond ((and eq (positive-measure? eq) (time-unit? (measure-unit eq))) (measure-value eq))
              ((and rq (positive-measure? rq) (time-unit? (measure-unit rq))) (measure-value rq))
              (else (process-hours rp)))))
    (define (use-count f)                 ; how many of the means: the quantity when the effort carries the time, else one
      (let ((eq (recipe-flow-effort-quantity f)) (rq (recipe-flow-resource-quantity f)))
        (if (and eq rq (not (time-unit? (measure-unit rq)))) (measure-value rq) 1.0)))
    ;; a LEAF BOUND, the shape of every first-law reading here: what a process needs
    ;; of a leaf is at most what it draws, within a hair
    (define (short! kind subject need drawn fmt . args)
      (when (> need (+ (* drawn (+ 1.0 1e-9)) 1e-9))
        (apply add! 'error kind subject fmt args)))
    (define produced '())   ; every spec some process produces
    (define consumed '())   ; (spec . process) for every consume
    (define mode-specs '()) ; (process-spec . process) for every travel mode
    (define (mode-process? flows)           ; a relocation whose mover works its own journey (recipes/transport.scm mode-recipe)
      (and (any (lambda (f) (eq? 'pickup (recipe-flow-action f))) flows)
           (any (lambda (f) (and (eq? 'work (recipe-flow-action f)) (recipe-flow-resolve-from-flow f))) flows)))
    ;; ── per recipe, per process, per flow ──
    (for-each
     (lambda (r)
       (let ((chain ($ rs 'get-process-chain (recipe-id r))))
         (when (null? chain)
           (add! 'warning 'empty-recipe (recipe-id r) "names no process the store holds; nothing can run it"))
         (for-each
          (lambda (rp)
            (let* ((pid (recipe-process-id rp))
                   (flows (flows-of rp))
                   (primaries (filter (lambda (f) (and (output-flow? f) (recipe-flow-is-primary f))) flows))
                   (produces (filter output-flow? flows)))
              (when (and (pair? produces) (null? primaries))
                (add! 'warning 'no-primary-output pid "produces ~a things and marks none primary; the composition residual lands nowhere"
                      (length produces)))
              (when (> (length primaries) 1)
                (add! 'error 'many-primary-outputs pid "marks ~a produce flows primary; exactly one carries the residual"
                      (length primaries)))
              ;; a performed process is `based-on` a specification and finds its recipe through it
              (let ((ps (recipe-process-process-conforms-to rp)))
                (when (and ps (not ($ rs 'get-process-spec ps)))
                  (add! (if specs-complete? 'error 'info) 'unknown-process-spec pid
                        "conforms to process specification ~s, which the store does not hold" ps))
                (when (and ps (mode-process? flows))
                  (set! mode-specs (cons (cons ps pid) mode-specs))))
              (for-each
               (lambda (f)
                 (let* ((fid (recipe-flow-id f))
                        (action (recipe-flow-action f))
                        (spec-id (recipe-flow-resource-conforms-to f))
                        (spec (spec-of spec-id))
                        (rq (recipe-flow-resource-quantity f))
                        (eq (recipe-flow-effort-quantity f))
                        (subject (format #f "~a/~a" pid fid)))
                   (cond
                    ((not (memq action %vf-actions))
                     (add! 'error 'unknown-action subject "action ~s is outside ValueFlows; the actions are ~a"
                           action (string-join (map symbol->string %vf-actions) " ")))
                    ((and (memq action %input-actions) (not (recipe-flow-recipe-input-of f)))
                     (add! 'error 'wrong-direction subject "~a flows INTO a process and states no input-of" action))
                    ((and (memq action %output-actions) (not (recipe-flow-recipe-output-of f)))
                     (add! 'error 'wrong-direction subject "~a flows OUT of a process and states no output-of" action)))
                   (when (and spec-id (not spec) (not (eq? action 'work)))
                     (add! (if specs-complete? 'error 'info) 'unknown-spec subject
                           "conforms to ~s, which the store does not hold" spec-id))
                   (when (and rq (not (positive-measure? rq)))
                     (add! 'error 'nonpositive-quantity subject "resource quantity ~a is not above zero" (measure-value rq)))
                   (when (and eq (not (positive-measure? eq)))
                     (add! 'error 'nonpositive-quantity subject "effort quantity ~a is not above zero" (measure-value eq)))
                   (when (and rq (memq action *stock-moving-actions*) (intensive-unit? (measure-unit rq)))
                     (add! 'error 'intensive-unit subject
                           "moves ~a in ~a, an intensive unit: a state is a form, a reading is a count of a stock — convert at the door (observation/convert.scm)"
                           (measure-value rq) (measure-unit rq)))
                   (when (and spec rq (memq action *flow-actions*)
                              (measure-unit rq)
                              (resource-specification-default-unit-of-resource spec)
                              (not (string=? (measure-unit rq) (resource-specification-default-unit-of-resource spec))))
                     (add! 'warning 'unit-mismatch subject "moves ~a in ~a where ~a is counted in ~a"
                           (measure-value rq) (measure-unit rq) spec-id (resource-specification-default-unit-of-resource spec)))
                   (when (and (eq? action 'use) (not (use-hours f rp)))
                     (add! 'error 'untimed-use subject "uses ~a for no stated length: neither the flow's effort nor the process's duration says how long a run takes, so the draw takes the period's length" spec-id))
                   (when (and (eq? action 'work) eq (measure-unit eq) (not (time-unit? (measure-unit eq))))
                     (add! 'warning 'work-not-in-hours subject "work effort is in ~a; labour is read in hours" (measure-unit eq)))
                   (when (output-flow? f) (set! produced (cons spec-id produced)))
                   (when (memq action using-up-actions) (set! consumed (cons (cons spec-id pid) consumed)))))
               flows)))
          chain)))
     all-recipes)
    ;; ── across the store: two modes on one specification cannot be told apart ──
    (for-each
     (lambda (ps)
       (let ((pids (delete-duplicates (map cdr (filter (lambda (m) (equal? (car m) ps)) mode-specs)))))   ; a process two recipes chain is one mode
         (when (> (length pids) 1)
           (add! 'error 'shared-mode-spec (string-join (sort pids string<?) " ")
                 "travel modes share process specification ~s; a performed ride could not name its mode" ps))))
     (delete-duplicates (map car mode-specs)))
    ;; ── across the store: what is drawn that nothing makes ──
    (for-each
     (lambda (sp)
       (unless (member (car sp) produced)
         (add! 'info 'unproduced-input (cdr sp) "consumes ~a, which no process in the store produces; stock or a boundary supplies it" (car sp))))
     (delete-duplicates consumed))
    ;; ── the composition system: every internal transformation, solved together ──
    (let* ((processes (append-map
                       (lambda (r) (map (lambda (rp) (cons (recipe-process-id rp) (balance-flows (flows-of rp))))
                                        ($ rs 'get-process-chain (recipe-id r))))
                       all-recipes))
           (internal (filter (lambda (p) (and (pair? (cdr p)) (not (boundary-process? (cdr p))))) processes))
           (derivable (delete-duplicates (filter-map (lambda (f) (and (output-action? (flow-action f)) (flow-spec f))) (append-map cdr internal))))
           ;; the two frames of the energy row (catalogues/substances.scm *enthalpy*): a molecule's
           ;; heat is its enthalpy of formation, a form's its excess over ambient. A
           ;; process mixing the two compares numbers with different zeros.
           (rows       (append (or (false-if-exception ($ rs 'stated-compositions)) '()) *contains*))
           (formation? (lambda (spec) (eq? 'formation (frame-of spec #:contains rows))))
           ;; what this scope states on its specs, then the table (a mock store with no
           ;; such door states nothing, the root's convention)
           (excess?    (lambda (spec) (eq? 'excess (frame-of spec #:contains rows))))   ; a carrier bridges the frames, a thermal form keeps its base's
           ;; THE SECOND LAW, as one inequality (docs/observation/physics.md): a process
           ;; produces entropy or it cannot run. `second-law-production` reads the entropy
           ;; its outputs carry less its inputs', crediting the unnamed heat loss to the
           ;; surroundings at T₀; a stated coefficient that beats Carnot, a lift with no
           ;; work, a leaf run on ambient heat, all read as entropy destroyed
           ;; a process that touches a NUCLIDE runs a channel nature runs, read over its
           ;; nuclide flows alone (a heat carrier beside them is the channel's own
           ;; yield). A nuclide carries its rest energy as heat, so a recipe that
           ;; consumed one and named no products would spend mc² on nothing: only a
           ;; channel turns mass into heat, and only by its mass defect
           (_channels (for-each
                       (lambda (p)
                         (let ((nuclear (filter (lambda (f) (nuclide? (flow-spec f))) (cdr p))))
                           (when (and (pair? nuclear) (not (nuclear-process-channel nuclear)))
                             (add! 'error 'unknown-channel (car p)
                                   "touches a nuclide and runs no channel nature runs (catalogues/substances.scm *channels*): mass becomes heat only through a channel, and only by its mass defect; conservation is necessary, never sufficient"))))
                       internal))
           (_second-law (for-each
                         (lambda (p)
                           (let ((made (second-law-production (cdr p) #:contains rows #:ambient-k ambient-k)))   ; #f: entropy unstated somewhere, no reading
                             (when (and made (< made (- (* 1e-9 (+ 1.0 (abs made))))))
                               (add! 'error 'second-law (car p)
                                     "would destroy ~,3e kWh/K of entropy: what leaves carries less than what enters, counting the unnamed heat at ~a K. A heat lift beyond Carnot, a lift with no work, or a low-entropy source (sunlight) stated as ambient heat reads so"
                                     (- made) ambient-k))))
                         internal))
           (_frames (for-each
                     (lambda (p)
                       (let ((specs (delete-duplicates (map flow-spec (cdr p)))))
                         (when (and (any formation? specs) (any excess? specs))
                           (add! 'error 'frames-crossed (car p)
                                 "mixes a molecule's enthalpy of formation (~a) with a form's excess over ambient (~a): the two zeros differ, so state the form's formation part or split the process"
                                 (string-join (filter formation? specs) ", ") (string-join (filter excess? specs) ", ")))))
                     internal))
           ;; THE SUN'S LAWS, one reading per process: the kilocalories it makes, the light
           ;; it draws and needs, the water it draws and needs (catalogues/substances.scm), computed
           ;; once and read by the three clauses below
           (figures (map (lambda (p)
                           (let ((flows (cdr p)))
                             (list (car p) flows
                                   (/ (food-energy-made flows) %kwh-per-kcal)                           ; kcal made
                                   (flow-sum flows input-action? (lambda (spec q) (if (equal? spec %sunlight) q 0.0)))   ; sunlight drawn, kWh
                                   (light-needed flows)                                                 ; the crop's light, kWh
                                   (water-drawn flows #:contains rows) (water-needed flows))))          ; litres drawn, litres the crop transpires
                         internal))
           ;; PHOTOSYNTHESIS: the first law on the food-energy leaf. What leaves a process
           ;; carries at most the kilocalories that entered plus the sunlight it drew times
           ;; the share its crop's pathway stores (catalogues/substances.scm *pathways*); a food
           ;; grown from soil with no light stated, or a yield beyond the leaf, reads as
           ;; energy created. An input with no energy row carries none: absence means zero.
           (_photosynthesis (for-each
                             (lambda (g)
                               (let ((pid (car g)) (kcal (caddr g)) (sun (list-ref g 3)) (need (list-ref g 4)))
                                 (short! 'photosynthesis pid need sun
                                         "grows ~,0f kcal of food on ~,0f kWh of sunlight where its pathway needs ~,0f: what leaves carries more than what enters plus the light stored at the crop's share (catalogues/substances.scm *pathways*, sunlight-for, world-sunlit); a harvest draws a stock"
                                         kcal sun need)))
                             figures))
           ;; PATHWAY: a grow's two ceilings are its crop's (catalogues/substances.scm *pathways*), and
           ;; the C3 figures stand for a crop the table does not name. A grown food outside
           ;; the table is told so: C3 is then chosen, never fallen into
           (_pathway (for-each
                      (lambda (g)
                        (when (> (list-ref g 4) 0.0)
                          (for-each (lambda (f)
                                      (when (and (output-action? (flow-action f)) (> (food-energy-kwh (flow-spec f) 1.0) 0.0) (not (pathway-stated? (flow-spec f))))
                                        (add! 'warning 'pathway-unstated (car g)
                                              "grows ~a, a crop *crop-pathway* (catalogues/substances.scm) does not name: its light and water are read at the C3 figures until its pathway is stated"
                                              (flow-spec f))))
                                    (cadr g))))
                      figures))
           ;; every process on the store once, whatever recipes share it, with its raw flows
           (rps (delete-duplicates (append-map (lambda (r) ($ rs 'get-process-chain (recipe-id r))) all-recipes)
                                   (lambda (a b) (equal? (recipe-process-id a) (recipe-process-id b)))))
           (carries-energy? (lambda (spec) (or (member spec *heat-carriers*) (enthalpy spec)
                                               (let ((row (assoc-ref rows spec))) (and (pair? row) (assoc-ref row "heat") #t)))))
           ;; POWER: a means passes energy at its rating (catalogues/substances.scm rated-kw). What a
           ;; process draws in heat carriers is at most Σ P·count·h over the rated means it
           ;; uses: the one law tying the plan's hours to its kilowatt-hours. A means with
           ;; no rating passes any amount, and a process using none is unread here.
           (_power (for-each
                    (lambda (rp)
                      (let* ((flows (flows-of rp))
                             (rated (filter-map
                                     (lambda (f)
                                       (and (eq? 'use (recipe-flow-action f))
                                            (let* ((sid (recipe-flow-resource-conforms-to f)) (sp (spec-of sid))
                                                   (kw (rated-kw sid #:unit (and sp (resource-specification-default-unit-of-resource sp))))
                                                   (h (use-hours f rp)))
                                              (and kw h (cons sid (* kw (use-count f) h))))))
                                     flows))
                             (drawn (apply + (filter-map (lambda (f) (and (memq (recipe-flow-action f) using-up-actions)
                                                                          (member (recipe-flow-resource-conforms-to f) *heat-carriers*)
                                                                          (measure-value (recipe-flow-resource-quantity f))))
                                                         flows))))
                        (when (pair? rated)
                          (short! 'power (recipe-process-id rp) drawn (apply + (map cdr rated))
                                  "draws ~,3f kWh through ~a, rated to pass ~,3f kWh in the hours used: a means passes energy at its rating, E ≤ P·h (catalogues/substances.scm *power-ratings*); state more hours or a larger means"
                                  drawn (string-join (map car rated) ", ") (apply + (map cdr rated))))))
                    rps))
           ;; MOTION: nothing moves for free. A pickup and dropoff through no keep-in-place
           ;; container is an arc through SPACE (recipes/transport.scm), and a relocation
           ;; spends energy: a work flow (the carrier's), a consume that carries heat (a
           ;; fuel, a charge), or the use of a network's service (classified vf:network:
           ;; the seat-hour bought at the boundary carries its traction, as any boundary
           ;; supply carries what made it). Through a container the arc is through time,
           ;; and holding costs what the hold states.
           (_motion (for-each
                     (lambda (rp)
                       (let* ((flows (flows-of rp))
                              (act? (lambda (a) (any (lambda (f) (eq? a (recipe-flow-action f))) flows)))
                              (held? (any (lambda (f) (and (eq? 'use (recipe-flow-action f))
                                                           (let ((sp (spec-of (recipe-flow-resource-conforms-to f))))
                                                             (and sp (resource-specification-keep-in-place sp)))))
                                          flows))
                              (fed? (any (lambda (f)
                                           (let ((a (recipe-flow-action f)))
                                             (cond ((memq a using-up-actions) (carries-energy? (recipe-flow-resource-conforms-to f)))
                                                   ((memq a occupying-actions)
                                                    (let ((sp (spec-of (recipe-flow-resource-conforms-to f))))
                                                      (and sp (member "vf:network" (or (resource-specification-resource-classified-as sp) '())) #t)))
                                                   (else #f))))
                                         flows)))
                         (when (and (act? 'pickup) (act? 'dropoff) (not held?) (not (act? 'work)) (not fed?))
                           (add! 'error 'free-motion (recipe-process-id rp)
                                 "relocates through space with no work and no energy consumed: nothing moves for free; state the carrier's work, the fuel it burns or the network service it rides, or hold it in a keep-in-place container if the arc is through time"))))
                     rps))
           ;; A MEANS TRAVELS AS A MOVER. The plan holds a means — a spec some process
           ;; `use`s — as the capacity it renders where it stands, so a relocation whose
           ;; cargo is a means and whose mover does no work of its own would carry a
           ;; bare good the plan does not hold. A mode whose mover is the means (a
           ;; `work` resolved from its own pickup) carries the thing, and its capacity
           ;; with it (engine.scm means->movers!).
           (_means-haul (let ((used (let ((h (make-hash-table)))
                                      (for-each (lambda (rp)
                                                  (for-each (lambda (f)
                                                              (when (eq? 'use (recipe-flow-action f))
                                                                (hash-set! h (recipe-flow-resource-conforms-to f) #t)))
                                                            (flows-of rp)))
                                                rps)
                                      h)))
                          (for-each
                           (lambda (rp)
                             (let* ((flows (flows-of rp))
                                    (pickup (find (lambda (f) (eq? 'pickup (recipe-flow-action f))) flows))
                                    (rides? (and pickup
                                                 (any (lambda (f) (and (eq? 'work (recipe-flow-action f))
                                                                       (equal? (recipe-flow-id pickup) (recipe-flow-resolve-from-flow f))))
                                                      flows))))
                               (when (and pickup (not rides?) (hash-ref used (recipe-flow-resource-conforms-to pickup) #f))
                                 (add! 'error 'haul-of-means (recipe-process-id rp)
                                       "relocates ~a, a means some process uses, as a bare good: a means is held as the capacity it renders where it stands; state the relocation as a mode whose mover is ~a (transport.scm mode-recipe #:good), and its capacity travels with it"
                                       (recipe-flow-resource-conforms-to pickup) (recipe-flow-resource-conforms-to pickup)))))
                           rps)))
           ;; TRANSPIRATION: the water a crop draws is tied to the energy it stores
           ;; (catalogues/substances.scm *pathways*, the least a leaf of that pathway loses per
           ;; kilocalorie fixed). A grow that consumes less water than that, on the
           ;; molecule basis over every form it consumes, grows a crop nothing watered.
           (_transpiration (for-each
                             (lambda (g)
                               (let ((pid (car g)) (kcal (caddr g)) (drawn (list-ref g 5)) (need (list-ref g 6)))
                                 (short! 'transpiration pid need drawn
                                         "grows ~,0f kcal of food on ~,0f L of water where its pathway transpires at least ~,0f L: a leaf loses water through the opening it takes carbon by (catalogues/substances.scm *pathways*, water-for, world-watered)"
                                         kcal drawn need)))
                             figures))
           ;; THE FIRST LAW, per process, as the solve reads it (engine.scm close-elements!,
           ;; catalogues/substances.scm process-creates): under the composition this store stands on,
           ;; a process carrying out more of a leaf than it draws, past what the bars on
           ;; its flows can explain, makes it from nothing, and the plan refuses it. Said
           ;; here, the author hears it when the recipe is written
           (_creates (let ((comp (store-composition rs))
                           (units (specs->units (or (false-if-exception ($ rs 'all-resource-specs)) '()))))
                       ;; what the recipes leave UNDETERMINED is unread, and named: a product
                       ;; nobody has described, on a loop nothing pins or made beside another
                       ;; such. Stating it is what lets the law read the processes it touches
                       (for-each
                        (lambda (row)
                          (when (and (string? (car row)) (assoc (unread-key (car *element-ids*)) (cdr row)))
                            (add! 'info 'undetermined-composition (car row)
                                  "is made by recipes that do not say what it holds (a loop nothing pins, or an output nobody has described beside another): the first law is unread on every process that touches it until its composition is stated")))
                        comp)
                       (for-each
                        (lambda (rp)
                          (let ((made (process-creates (recipe-process-id rp)
                                                       (balance-flows (flows-in-spec-units (flows-of rp) units) #:basis? #f)
                                                       comp
                                                       #:boundary? (and (member "boundary" (or (recipe-process-process-classified-as rp) '())) #t))))
                            (when (pair? made)
                              (add! 'error 'creates (recipe-process-id rp)
                                    "carries out more than it draws, per run: ~a. What leaves a process entered it: state the draw (a stock, the soil, the air, the power) or the co-product that carries the rest"
                                    (string-join (map (lambda (m) (format #f "~a ~,4f" (car m) (- (cdr m)))) made) ", ")))))
                        rps)))
           (report (if (null? internal) '() (composition-system internal #:contains (composition-claims *contains* derivable)))))
      (for-each
       (lambda (c)
         (add! 'error 'composition-contradiction (string-join (assq-ref c 'processes) ", ")
               "element ~a leaves a residual of ~,4f against the declared compositions~a"
               (assq-ref c 'element) (assq-ref c 'residual)
               (let ((sp (assq-ref c 'spec))) (if sp (format #f " (~a would have to hold ~,4f)" sp (assq-ref c 'value)) ""))))
       (or (assq-ref report 'contradictions) '())))
    (findings-by-severity (reverse findings))))

;;; ─── wire records ──────────────────────────────────────────────────────────
;; A record is an alist with symbol or string keys, as JSON parses or a model
;; writes it: kind (event | need | offer | flow; an action alone reads as an
;; event), action, spec, qty, unit, when, and for a need or offer its arcs.
(define (ref r key)
  (let ((p (or (assoc key r) (assoc (symbol->string key) r)
               (and (string? key) (assq (string->symbol key) r)))))
    (and p (cdr p))))
(define (present? v) (and v (not (and (string? v) (string-null? v))) (not (eq? v 'null))))
(define (->sym v) (cond ((symbol? v) v) ((string? v) (string->symbol v)) (else #f)))
(define (->num v) (cond ((number? v) v) ((and (string? v) (string->number v)) => (lambda (n) n)) (else #f)))
(define %days '("monday" "tuesday" "wednesday" "thursday" "friday" "saturday" "sunday"))
(define (hhmm? s) (and (string? s) (= 5 (string-length s)) (char=? #\: (string-ref s 2))
                       (string-every (lambda (c) (or (char-numeric? c) (char=? c #\:))) s)))

(define* (lint-records records #:key (specs #f) (units #f) (actions %vf-actions))
  "Findings over RECORDS (a list or vector of alists). SPECS, when a list, is
every spec id the scope knows; UNITS, when an alist, spec id → its unit.
Without them the spec is taken on trust and only the shape is judged."
  (let ((findings '()) (i 0))
    (define (add! severity kind subject fmt . args)
      (set! findings (cons (finding severity kind subject (apply format #f fmt args)) findings)))
    (for-each
     (lambda (r)
       (let* ((subject (format #f "records[~a]" i))
              (kind (or (->sym (ref r 'kind)) (if (present? (ref r 'action)) 'event 'need)))
              (action (->sym (ref r 'action)))
              (spec (ref r 'spec))
              (qty (->num (ref r 'qty)))
              (unit (ref r 'unit))
              (arcs (ref r 'arcs)))
         (set! i (+ i 1))
         (cond
          ((not (list? r)) (add! 'error 'not-a-record subject "is not an object"))
          (else
           (unless (memq kind '(event need offer flow))
             (add! 'error 'unknown-kind subject "kind ~s is not event, need, offer or flow" kind))
           (when (and (memq kind '(event flow)) (not (memq action actions)))
             (add! 'error 'unknown-action subject "action ~s is outside ValueFlows; use one of ~a"
                   (or action (ref r 'action)) (string-join (map symbol->string actions) " ")))
           (cond
            ((not (present? spec)) (add! 'error 'missing-spec subject "names no resource or skill in spec"))
            ((and specs (not (member spec specs)))
             (add! 'error 'unknown-spec subject "spec ~s is not one the scope knows; use a known spec id verbatim" spec)))
           (unless (and qty (> qty 0))
             (add! 'error 'nonpositive-quantity subject "qty ~a is not a number above zero" (or qty (ref r 'qty))))
           (when (and (present? spec) units (present? unit) (assoc spec units)
                      (not (string=? (format #f "~a" unit) (cdr (assoc spec units)))))
             (add! 'warning 'unit-mismatch subject "states ~a in ~a where the scope counts it in ~a"
                   spec unit (cdr (assoc spec units))))
           (when (and (eq? action 'work) (present? unit) (not (time-unit? (format #f "~a" unit))))
             (add! 'warning 'work-not-in-hours subject "work is stated in ~a; labour is read in hours" unit))
           (when (and (memq action *stock-moving-actions*) (present? unit) (intensive-unit? unit))
             (add! 'error 'intensive-unit subject
                   "states ~a in ~a, an intensive unit: a reading is a count of a stock — convert at the door" spec unit))
           (when (and (memq kind '(need offer)) (present? arcs))
             (let ((arcs (if (vector? arcs) (vector->list arcs) arcs)) (j 0))
               (for-each
                (lambda (a)
                  (let ((s (format #f "~a.arcs[~a]" subject j))
                        (days (let ((d (ref a 'days))) (if (vector? d) (vector->list d) (or d '())))))
                    (set! j (+ j 1))
                    (unless (and (hhmm? (ref a 'start)) (hhmm? (ref a 'end)))
                      (add! 'error 'bad-arc-time s "start and end must be HH:MM"))
                    (let ((bad (filter (lambda (d) (not (member (string-downcase (format #f "~a" d)) %days))) days)))
                      (when (pair? bad) (add! 'error 'bad-arc-day s "days ~s are not lowercase full day names" bad)))
                    (when (null? days) (add! 'error 'bad-arc-day s "names no day"))))
                (if (list? arcs) arcs '()))))))))
     (if (vector? records) (vector->list records) records))
    (findings-by-severity (reverse findings))))
