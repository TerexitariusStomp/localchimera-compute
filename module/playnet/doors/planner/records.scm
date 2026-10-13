;;; module/playnet/doors/planner/records.scm — the books at a scope: counts and their schedule, labels, observations, a condition read, a thing dropped, a plan enacted and its flows confirmed, the inventory, a journey, the replica, the lint
;;;
;;; A fragment of the planner service (playnet doors service): a procedure from
;;; the service's context to the doors it serves, composed into every service by
;;; doors/service.scm. `with-planner-ctx` binds the context's fields under their
;;; own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §12). What this fragment alone reads and
;;; writes is defined here, above its doors.

(define-module (playnet doors planner records)
  #:use-module ((goblins) #:select ($))
  #:use-module ((json builder) #:select (scm->json-string))
  #:use-module ((json parser) #:select (json-string->scm))
  #:use-module ((playnet doors assignments) #:select (willing-predicate))
  #:use-module ((playnet doors count-door) #:select (count-history-reply count-schedule-reply do-count-stock do-read-condition label-stock-reply lay-counts read-label-reply with-expected))
  #:use-module ((playnet doors effort) #:select (do-drop-event))
  #:use-module ((playnet doors inventory) #:select (build-inventory-snapshot build-process-context build-resource-detail))
  #:use-module ((playnet doors journeys) #:select (ensure-place! trip-good trip-ids))
  #:use-module ((playnet doors plan-wire) #:select (scope-members))
  #:use-module ((playnet doors planner solve-cache) #:select (cache-solve! hold-row! mark-solve-stale! planned-material planned-row-id planned-rows planned-runs row-left solve-vocabulary-of))
  #:use-module ((playnet doors position) #:select (solve-keywords))
  #:use-module ((playnet knowledge catalogues thermal) #:select (declare-thermal-form!))
  #:use-module ((playnet knowledge dsl findings) #:select (findings->wire))
  #:use-module ((playnet knowledge dsl vf-lint) #:select (lint-records))
  #:use-module ((playnet observation log-observe) #:select (do-log-observe))
  #:use-module ((playnet observation observer) #:select (reach-slack target-passed?))
  #:use-module ((playnet scope live) #:select (enact-rows find-recipe-process-for-spec materialize-willing! mode-process-for-manner persist-materialized! record-flow-done record-work-done))
  #:use-module ((playnet scope replica) #:select (replica->text scope->replica))
  #:use-module ((playnet utils clock) #:select ((now . clock-now) instant->unix iso-now))
  #:use-module ((playnet utils common) #:select (string-or-false))
  #:use-module ((playnet utils envelope) #:select (catch-as-failure failure success))
  #:use-module ((playnet utils units) #:select (%count-unit))
  #:use-module ((playnet vf formulas actions) #:select (*flow-actions* occupying-actions relocating-actions))
  #:use-module ((playnet vf formulas counting) #:select (count-process?))
  #:use-module ((playnet vf formulas flows) #:select (make-relocation-event row-id row-quantity))
  #:use-module ((playnet vf schemas) #:select (commitment-finished commitment-id commitment-input-of commitment-provider make-commitment make-measure make-process recipe-process-process-conforms-to resource-specification-id specs->units))
  #:use-module ((srfi srfi-1) #:select (filter-map fold))
  #:use-module (playnet doors planner ctx)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (planner-records-doors))

(define (planner-records-doors ctx)
  (with-planner-ctx ctx

    (declared-doors planner

      ((lint-records scope-id records-json)
       (with-scope scope-id
         (lambda (root)
           (catch-as-failure
             (lambda ()
               (let* ((rs ($ root 'recipe-store))
                      (specs ($ rs 'all-resource-specs))
                      (ids (map resource-specification-id specs))
                      (units (specs->units specs))
                      (records (let ((v (json-string->scm records-json)))
                                 (cond ((vector? v) (vector->list v)) ((list? v) v) (else '())))))
                 (scm->json-string (findings->wire (lint-records records #:specs ids #:units units)))))))))

      ;; ── Journeys: the map's route-and-go becomes VF records ─────────────────
      ;; A journey is one performed Process, based on the scope's mode for the way it
      ;; was made (mode = a routing costing: the baseline walk, bike and car, or a
      ;; shed's own modes), with two commitments and the two events that fulfil them:
      ;; a pickup at departure (the trip as input-of) and a dropoff on arrival (the
      ;; trip as output-of), resource-less, each of one rider. The observer's
      ;; arc-observations pairs the two by the process; the live boundary reads the
      ;; trip's manner off the mode recipe (live.scm trip-manner-of), and the
      ;; arc-time table's observed half starts learning from the federation's own
      ;; movement. PLACES are SpatialThing ids when known (then the table learns the
      ;; arc); a "geo:lat,lng" place is minted as one, and prices nothing until it
      ;; corresponds to a located place.

      ((journey-begin scope-id agent-id from-place to-place mode)
       (with-person scope-id agent-id
         (lambda (root)
           (catch-as-failure
         (lambda ()
           (let* ((obs ($ root 'observer))
                  (ps  ($ root 'plan-store))
                  (rs  ($ root 'recipe-store))
                  (mode (if (symbol? mode) (symbol->string mode) mode))
                  (now (iso-now))
                  ;; the instant alone is second-precision — a double-tap
                  ;; on the journey button collided two journeys onto one
                  ;; cid, silently overwriting the first commitment AND
                  ;; resetting its fulfillment via the unguarded
                  ;; register-commitment below. The agent's running count
                  ;; of jc- commitments disambiguates (record-purchase's
                  ;; own fix pattern).
                  (cid (string-append "jc-" agent-id "-"
                                      (number->string (instant->unix (clock-now))) "-"
                                      (number->string
                                       (length (filter (lambda (k)
                                                         (string-prefix? (string-append "jc-" agent-id "-")
                                                                         (or (commitment-id k) "")))
                                                       ($ ps 'all-commitments))))))
                  (ids  (trip-ids cid))
                  (pid  (car ids)) (dcid (cdr ids))
                  ;; the trip is one performed Process, based on the scope's mode for the
                  ;; way it was made; a costing no mode carries is classified by itself
                  (mode-rp (mode-process-for-manner rs mode))
                  (good (trip-good rs mode-rp))
                  (process (make-process #:id pid #:name (string-append "journey by " mode) #:note "journey (map)"
                                         #:based-on (and mode-rp (recipe-process-process-conforms-to mode-rp))
                                         #:classified-as (list (string-append "manner:" mode)) #:in-scope-of (list scope-id) #:has-beginning now))
                  (pickup
                   (make-commitment
                    #:id cid #:action 'pickup #:note "journey commitment (map)"
                    #:input-of pid                          ; input-of = the trip's process
   #:resource-conforms-to good #:resource-quantity (make-measure 1 %count-unit)   ; one rider, as the mode's pickup flow says
                    #:provider agent-id #:receiver agent-id
                    #:has-beginning now #:created now                ; begins now; created now
                    #:at-location from-place #:in-scope-of (list scope-id)))
                  (dropoff
                   (make-commitment
                    #:id dcid #:action 'dropoff #:note "journey arrival (map)" #:output-of pid                          ; output-of = the trip's process
   #:resource-conforms-to good #:resource-quantity (make-measure 1 %count-unit)
                    #:provider agent-id #:receiver agent-id #:created now
                    #:at-location to-place #:in-scope-of (list scope-id))))
             (ensure-place! ($ root 'spatial-thing-store) from-place)
             (ensure-place! ($ root 'spatial-thing-store) to-place)
             ($ obs 'record-process process)
             ;; the journey is two commitments LIKE ANY OTHER: they live in the
             ;; plan-store (snapshots, calendars, chat strata all see them)…
             ($ ps 'add-commitment-silent pickup)
             ($ ps 'add-commitment-silent dropoff)
             ;; …and the store armed their fulfilment on the observer as they entered
             ($ obs 'record-event
                ;; a journey's pickup: the trip's process as input-of, one rider of the mode's
                ;; good, has-beginning = departure (it has not completed)
                (make-relocation-event
                 #:id (string-append "ev-pu-" cid) #:action 'pickup
                 #:input-of pid #:provider agent-id #:spec good #:qty (and good 1)
                 #:beg now #:when #f #:created (iso-now)
                 #:from from-place #:fulfills cid
                 #:note (string-append "journey depart by " mode)
                 #:in-scope-of scope-id))
             (success `((commitment . ,cid) (arrival . ,dcid)))))))))

      ((journey-end scope-id agent-id commitment-id from-place to-place mode)
       (scoped scope-id
         (lambda (root)
(let* ((obs ($ root 'observer))
                      (rs  ($ root 'recipe-store))
                      (mode (if (symbol? mode) (symbol->string mode) mode))
                      (ids (trip-ids commitment-id))
                      (pid (car ids)) (dcid (cdr ids))
                      (rp  (let ((spec ($ obs 'process-spec pid))) (and spec (find-recipe-process-for-spec rs spec))))
                      (now (iso-now)))
                 ($ obs 'record-event
                    ;; a journey's dropoff: the trip's process as output-of, has-end = arrival
                    (let ((good (trip-good rs rp)))
                      (make-relocation-event
                       #:id (string-append "ev-do-" commitment-id) #:action 'dropoff
                       #:output-of pid #:provider agent-id #:spec good #:qty (and good 1)
                       #:end now #:when now #:created now
                       #:from to-place #:to to-place #:fulfills dcid
                       #:note (string-append "journey arrive by " mode)
                       #:in-scope-of scope-id)))
                 `((commitment . ,commitment-id) (arrival . ,dcid))))))

      ;; Materialize: run the willing-only plan AND persist its assignments as
      ;; stored suggested intents (mi|worker|skill|cell + suggested-provider meta),
      ;; so they surface in the next scope-snapshot under "Awaiting your acceptance"
      ;; — closing the offer→willingness→materialize→accept loop without a manual
      ;; bridge. Returns the plan alist plus (materialized . N).
      ((materialize scope-id demand #:optional (opts '()))
       (with-scope scope-id
         (lambda (root)
           (catch-as-failure
             (lambda ()
               (let ((o opts))
                 (on-plan
                   (apply plan-fn* root scope-id
                          (solve-keywords root o #:demand demand
                                          #:willing? (willing-predicate root)))   ; always the materialization binding
                   (lambda (al)
                     (let ((n (persist-materialized! root (assq-ref al 'work)
                                                     #:plan-id (or (assq-ref o 'plan-id) "plan-materialized"))))
                       (success (cons (cons 'materialized n) (cache-solve! cache scope-id demand al)))))
                   #:catch (lambda (e) (failure (format #f "~a" e))))))))))

      ;; Enact a plan's MATERIAL flows — "it all happened as planned": record the
      ;; produce/consume/pickup/dropoff/use events the observer folds, moving stock. plan is the
      ;; alist from `plan` (only its (material …) is used).
      ((enact scope-id plan)
       (scoped scope-id
         (lambda (root)
;; the rows enacted are the plan's own, found by id: a row the last plan
               ;; does not state waits unrecorded, and its quantity is the plan's, not the client's
               (let* ((stated  (let ((h (make-hash-table)))
                                 (for-each (lambda (m) (hash-set! h (row-id m) m)) (planned-material cache scope-id))
                                 h))
                      (asked   (or (assq-ref plan 'material) '()))
                      (mine    (filter-map (lambda (m) (hash-ref stated (row-id m) #f)) asked))
                      (strange (filter (lambda (m) (not (hash-ref stated (row-id m) #f))) asked))
                      (r       (begin (for-each (lambda (m) (hold-row! ($ root 'observer) scope-id m)) mine)
                                      (enact-rows root mine #:vocabulary (solve-vocabulary-of cache scope-id)
                                                  #:runs (planned-runs cache scope-id)))))
                 `((events . ,(car r))
                            (unmet . ,(append (map (lambda (m) (cons (row-id m) "the plan states no such row")) strange)
                                              (map (lambda (u) (cons (car u) (format #f "~a" (cdr u)))) (cdr r)))))))))

      ;; ONE material row observed — the per-row browser door onto the same
      ;; confirmation mile enact walks wholesale. The row is found among the rows
      ;; the last plan states, by its own id (ROW-ID, which the schedule carries) or,
      ;; for a caller that has none, by its coordinates (action, spec, place, when,
      ;; process). Each plan row is a commitment under
      ;; the plan's own row id, so this door and enact name one commitment per row
      ;; and FulfillmentState governs partials as it does for work: QTY is spread
      ;; over the matching rows' remainders in plan order (a numbered event each),
      ;; a finished row answers `already` instead of double-moving stock, and more
      ;; than the rows hold is refused here, where the member's word becomes an
      ;; event. TOTAL rides the wire and decides nothing: the row is the plan's. The
      ;; flow is dated at the row's planned slot, or at its confirmation when the slot
      ;; is still ahead (live.scm planned-stamp). The two rows of a relocation chain
      ;; through the cargo's own lot: a dropoff lands what its pickup carried, and
      ;; is refused before that. NOTE rides the
      ;; wire and decides nothing: the row is the plan's.
      ;; NB the clock argument is named when-iso, never `when`: a method
      ;; parameter named `when` lexically shadows the macro.
      ((record-flow scope-id action spec qty total place when-iso proc note #:optional (row-id #f))
       (with-scope scope-id
         (lambda (root)
           (catch-as-failure
             (lambda ()
               (if (not (memq (string->symbol action)                    ; the actions a material row carries: a flow, a relocation, an occupation
                              (append *flow-actions* relocating-actions occupying-actions)))
                   (failure (string-append "unknown flow action: " action))
                   (let* ((obs  ($ root 'observer))
                          (rows (if (and (string? row-id) (not (string-null? row-id)))
                                    (filter (lambda (m) (equal? (planned-row-id m) row-id)) (planned-material cache scope-id))
                                    (planned-rows cache scope-id action spec place when-iso proc))))
                     (when (null? rows)
                       (error "the plan holds no such row; confirm what the plan states" action spec place))
                     (for-each (lambda (m) (hold-row! obs scope-id m)) rows)
                     (let* ((open (filter (lambda (m) (> (row-left obs m) (reach-slack (row-quantity m)))) rows))
                            (room (fold + 0 (map (lambda (m) (row-left obs m)) open))))
                       (cond
                        ((null? open) (success `((event-id . "") (already . #t))))
                        ((target-passed? qty room)
                         (error (format #f "the row holds ~a more; ~a recorded" room qty)))
                        (else
                         (let spend ((ms open) (need qty) (first #f))
                           (if (or (null? ms) (not (target-passed? need 0)))
                               (success `((event-id . ,(or first ""))))
                               (let* ((m    (car ms))
                                      (cid  (planned-row-id m))
                                      (take (min need (row-left obs m)))
                                      (evid (string-append "ev-" cid "-"
                                                           (number->string (length (or ($ obs 'fulfilled-by cid) '()))))))
                                 (record-flow-done root m
                                                   #:quantity take #:event-id evid
                                                   #:vocabulary (solve-vocabulary-of cache scope-id)
                                                   #:runs (planned-runs cache scope-id))
                                 (spend (cdr ms) (- need take) (or first evid)))))))))))))))

      ((inventory-snapshot scope-id plan-id)
       (with-scope scope-id
         (lambda (root)
           (with-expected root (planned-material cache scope-id)
                          (build-inventory-snapshot root scope-id plan-id)
                          (clock-now)))))

      ((resource-detail scope-id resource-id)
       (with-scope scope-id
         (lambda (root) (build-resource-detail root resource-id))))

      ((process-context scope-id process-id)
       (with-scope scope-id
         (lambda (root) (build-process-context root process-id))))

      ;; Needs-based materialization for the live calendar: assign willing workers
      ;; to the scope's OPEN needs (the "race") so they surface under "Awaiting
      ;; your acceptance". The browser calls this right after express-willingness,
      ;; so marking willing immediately materializes. Returns (materialized . N).
      ((materialize-willing scope-id)
       (scoped scope-id
         (lambda (root)
`((materialized . ,(materialize-willing! root))))))

      ;; A NEW PLACE, named by a citizen — free-association's LocationEditor
      ;; "Specific" address, on VF: a <spatial-thing> in the scope's store,
      ;; deterministic id (place:AID:slug ⇒ naming it again re-places it),
      ;; coordinates optional (0/0 = none). Returns the id, so a slot's WHERE
      ;; can point at it the moment it exists.
      ;; a state is a form (docs/observation/physics.md §2–3): the scope declares
      ;; BASE warmed by DELTA-T kelvin with SPECIFIC-HEAT kJ/(kg·K), held in ENCLOSURE
      ;; (a keep-in-place spec) of conductance UA kW/K over MASS kg; the store gains
      ;; the form, its stated row, the base's zero, and the relaxation recipe
      ((thermal-form! scope-id base specific-heat delta-t enclosure #:optional (ua #f) (mass #f))
       (scoped scope-id
         (lambda (root)
(declare-thermal-form! ($ root 'recipe-store) base specific-heat delta-t enclosure
                                               #:ua ua #:mass mass))))

      ;; Whether COMMITMENT-ID is a count the plan asked of AGENT-ID and still
      ;; stands: what a photo read draws on in place of the week's allotment.
      ((count-commitment-of scope-id agent-id commitment-id)
       (with-scope scope-id
         (lambda (root)
           (let ((c ($ ($ root 'plan-store) 'get-commitment commitment-id)))
             (success (and c
                           (count-process? (commitment-input-of c))
                           (equal? agent-id (commitment-provider c))
                           (not (commitment-finished c))
                           #t))))))

      ;; The schedule of counts: every target the inventory shows, soonest due
      ;; first, with the interval the plan's reliance and the ledger's drift
      ;; give it (counting.scm).
      ((count-schedule scope-id #:optional (regime #f))
       (with-scope scope-id
         (lambda (root)
           (count-schedule-reply root scope-id (node-of scope-id nodes-reading) regime))))

      ;; Lay the counts that are due as offers (count-door.scm lay-counts).
      ((plan-counts scope-id agent-id #:optional (regime #f) (counter #f) (at-most #f))
       (with-person scope-id agent-id
         (lambda (root)
           (catch-as-failure
            (lambda ()
              (success (lay-counts root scope-id agent-id (scope-members root scope-id)
                                   (node-of scope-id nodes-reading) regime counter at-most
                                   (instant->unix (clock-now)))))))))

      ;; The counts of one stock, newest first: each adjustment a count landed, who
      ;; counted, by what technique, and the picture it names. What a member reads
      ;; to contest a count (governance contest-work); a contested and voided count
      ;; is gone from it, since it reads the standing events.
      ;; The scope as its member's device holds it: its goods, places, people, standing
      ;; needs and the observer's books, as one text (replica.scm). What a device
      ;; seeds its copy from on taking a seat, and again after it flushes.
      ((scope-replica scope-id agent-id)
       (with-person scope-id agent-id
         (lambda (root)
           (catch-as-failure
            (lambda () (success (replica->text (scope->replica root))))))))

      ((count-history scope-id agent-id resource-id #:optional (limit #f))
       (with-scope scope-id
         (lambda (root) (count-history-reply root agent-id resource-id limit))))

      ;; The code a stock is known by, for its label: given on the first asking,
      ;; the same on every asking after.
      ((label-stock scope-id agent-id resource-id)
       (with-person scope-id agent-id
         (lambda (root) (label-stock-reply root scope-id agent-id resource-id))))

      ;; What a label names: the thing, where it is, and what is in it.
      ((read-label scope-id agent-id code)
       (with-person scope-id agent-id
         (lambda (root) (read-label-reply root code))))

      ;; Settlement: draw earned credit to receive an individually-claimable good.
      ;; The account-store validates the draw against the elastic effective-balance
      ;; (rejecting over-draw), records the transfer event — which, when the scope is
      ;; credentialed, the on-event hook attests as a claim ACDC — and decrements
      ;; claimed-capacity. Single-scope here; federation-wide draw is the multi-scope
      ;; extension. Returns the new balance.
      ;; labor-cost #f ⇒ derive it here: qty × SNLT_crystallized of the
      ;; resource's spec — the same measure that values the pool K, so a claim
      ;; costs exactly what the good cost society (the browser never prices
      ;; Leaving a thing in a shared container, and taking one out. ACTION is
      ;; "dropoff" | "pickup"; the observer reads every effect off the VF
      ;; ActionDefinition, so this method holds no rules of its own beyond what
      ;; the ledger can check. OPTS: (resource-id [note [accountable]]).
      ;;
      ;; RESOURCE-ID names the thing moved — a pickup must name one, and a dropoff
      ;; that names one MOVES it, rights and rail intact. ACCOUNTABLE is a claim of
      ;; rights over a thing being introduced, and it is only ever a declaration:
      ;; left out, the thing enters the books owned by nobody, because putting
      ;; something down is not how anyone comes to own it.
      ((drop-event scope-id action container-id agent spec qty unit #:optional (resource-id #f) (note #f) (accountable #f))
       (with-person scope-id agent
         (lambda (root)
           (do-drop-event root (if (equal? action "pickup") 'pickup 'dropoff)
                          container-id agent spec qty
                          #:scope scope-id         ; whose commons this box is
                          #:unit (if (and (string? unit) (not (string-null? unit))) unit %count-unit)
                          #:resource-id (string-or-false resource-id)
                          #:note (string-or-false note)
                          #:accountable (string-or-false accountable)))))

      ;; The captain's log observes: a spoken entry's suggested event, recorded
      ;; SELF-scoped on the observer (see do-log-observe for the door's width).
      ;; NOTE carries the entry's own line; WHEN the narrated time (ISO, "" = now).
      ((log-observe scope-id agent-id action spec qty unit note when-iso)
       (with-person scope-id agent-id
         (lambda (root)
           (do-log-observe root scope-id agent-id action spec qty unit
                           #:note (string-or-false note)
                           #:when-iso (and (string? when-iso)
                                           (not (string-null? when-iso))
                                           when-iso)))))

      ;; A count of a stock the books hold: the difference lands as a raise or
      ;; lower on that stock, with the technique, the place, the instant and
      ;; the evidence hash on the event (see do-count-stock). An empty string
      ;; leaves an optional field unstated. A count that moves the stock leaves
      ;; the plan standing on an old figure, so the plan is marked stale: its
      ;; wire says so until the next solve lands.
      ;; a reading of a stock's condition: the form it names, landed as the counts
      ;; that say so (count-door.scm do-read-condition)
      ((read-condition scope-id agent-id resource-id reading unit
                       #:optional (when-iso #f) (ambient #f) (note #f))
       (with-person scope-id agent-id
         (lambda (root)
           (do-read-condition root scope-id agent-id resource-id reading (string-or-false unit)
                              #:when-iso (string-or-false when-iso)
                              #:ambient (let ((a (string-or-false ambient))) (and a (if (string? a) (string->number a) a)))
                              #:note (string-or-false note)))))

      ((count-stock scope-id agent-id resource-id counted unit
                    #:optional (technique #f) (place #f) (when-iso #f)
                               (fulfills #f) (evidence #f) (note #f))
       (with-person scope-id agent-id
         (lambda (root)
           (let ((landed (do-count-stock root scope-id agent-id resource-id counted (string-or-false unit)
                                         #:technique (string-or-false technique) #:place (string-or-false place)
                                         #:when-iso (string-or-false when-iso) #:fulfills (string-or-false fulfills)
                                         #:evidence (string-or-false evidence) #:note (string-or-false note)
                                         #:rows (planned-material cache scope-id))))
             (when (and (pair? landed) (eq? (car landed) 'ok)
                        (let ((delta (assq-ref (cdr landed) 'delta)))
                          (and (number? delta) (not (zero? delta)))))
               (mark-solve-stale! cache scope-id))
             landed)))))))
