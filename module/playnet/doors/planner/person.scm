;;; module/playnet/doors/planner/person.scm — a person's own facts, each at their home: position, place, dwelling, availability, profile, skills, means, needs and claims, written and read
;;;
;;; A fragment of the planner service (playnet doors service): a procedure from
;;; the service's context to the doors it serves, composed into every service by
;;; doors/service.scm. `with-planner-ctx` binds the context's fields under their
;;; own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §12). What this fragment alone reads and
;;; writes is defined here, above its doors.

(define-module (playnet doors planner person)
  #:use-module ((goblins) #:select ($))
  #:use-module ((json parser) #:select (json-string->scm))
  #:use-module ((playnet algorithms rollup) #:select (crystallized-snlt-for-spec))
  #:use-module ((playnet doors effort) #:select (finite-positive?))
  #:use-module ((playnet doors plan-wire) #:select (scope-credit->wire wire-number))
  #:use-module ((playnet doors planner solve-cache) #:select (met-of-scope))
  #:use-module ((playnet doors position) #:select (do-set-position location-mode nearest-location own-position-place! sharing-refused? standing-in))
  #:use-module ((playnet doors record-rows) #:select (lookup-spec-name))
  #:use-module ((playnet doors skills) #:select (declare-skill! lower-resource! revoke-skill!))
  #:use-module ((playnet doors slots) #:select (arcs-json->window cats-json->list declare-means-reply declare-need-reply my-slots-reply))
  #:use-module ((playnet knowledge catalogues housing) #:select (housing-gate?))
  #:use-module ((playnet matching filter-rule) #:select (criteria-json->alist))
  #:use-module ((playnet observation account) #:select (claim-fulfillments claim-terms open-claim-for resource-individually-claimable?))
  #:use-module ((playnet observation practice) #:select (practice-view-dated practice-view-hours))
  #:use-module ((playnet observation states) #:select (fulfillment-state-commitment-id fulfillment-state-finished fulfillment-state-total-committed fulfillment-state-total-fulfilled))
  #:use-module ((playnet pools labour-fold) #:select (skill-specs-for-agent))
  #:use-module ((playnet scope live) #:select (practice-view-of profile-tag? scope-labour?))
  #:use-module ((playnet utils clock) #:select ((now . clock-now) iso-now))
  #:use-module ((playnet utils common) #:select (string-or-false))
  #:use-module ((playnet utils envelope) #:select (catch-as-failure failure success))
  #:use-module ((playnet utils units) #:select (%count-unit))
  #:use-module ((playnet vf facts person-facts) #:select (dwelling-id generic-labour-spec generic-labour-spec-id generic-skill-id location-modes location-share-key means-id need-id need-prefix person-place-id position-key))
  #:use-module ((playnet vf formulas actions) #:select (using-up-actions))
  #:use-module ((playnet vf formulas skill-law) #:select (competence-fold skill-law-of))
  #:use-module ((playnet vf schemas) #:select (agent-classified-as agent-primary-location copy-agent economic-event-id economic-resource-conforms-to economic-resource-id economic-resource-onhand-quantity economic-resource-primary-accountable intent-action intent-at-location intent-finished intent-has-beginning intent-id intent-resource-conforms-to intent-resource-quantity make-agent make-economic-resource make-measure make-spatial-thing measure-has-numerical-value resource-specification-id resource-specification-resource-classified-as spatial-thing-lat spatial-thing-long spatial-thing-mappable-address))
  #:use-module ((srfi srfi-1) #:select (any append-map delete-duplicates filter-map find remove))
  #:use-module (playnet doors planner ctx)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (planner-person-doors))

(define (planner-person-doors ctx)
  (with-planner-ctx ctx
    ;; UPSERT: stating who you are, when you can work or where you live IS the
    ;; moment you become a person here. The record is updated by UPDATE, or
    ;; made by MAKE and then FRESH runs once, for what a new person comes with.
    (define* (agent-upsert! as aid update make #:optional (fresh (lambda () #t)))
      (or ($ as 'update-agent aid update)
          (begin ($ as 'add-agent (make)) (fresh) #t)))

    (declared-doors planner

      ;; ONE planned CLAIM confirmed — the citizen took their good. The plan
      ;; registered its `claims` row as a `transfer` commitment when it landed
      ;; (plan-claims! cache), and this door only ever fulfils one: the open commitment
      ;; of SPEC for CLAIMANT at PLACE (when named) with QTY still remaining. Each
      ;; call records QTY more as the account store's claim — the transfer event
      ;; that moves custody and draws the certificate — carrying `fulfills` so
      ;; FulfillmentState governs partials; a row confirmed in full answers
      ;; `already`. A claim the plan never planned is refused at the ledger: the
      ;; want is stated, and the next plan answers it. TOTAL and WHEN-ISO ride the
      ;; wire for the row's own record and decide nothing here. The pool resource
      ;; is whichever holds the spec on this rail with enough on hand; the cost is
      ;; the good's crystallized SNLT, the same number the plan tallied.
      ((record-claim scope-id claimant spec qty total place when-iso)
       (with-scope scope-id
         (lambda (root)
           (catch-as-failure
             (lambda ()
               (let* ((obs  ($ root 'observer))
                      (fs   (open-claim-for obs spec claimant #:place place #:at-least qty))
                      (cid  (and fs (fulfillment-state-commitment-id fs)))
                      ;; the row stood and is confirmed in full: nothing open, a finished one on the books
                      (done (and (not fs)
                                 (any fulfillment-state-finished
                                      (claim-fulfillments obs #:spec spec #:receiver claimant #:place place
                                                          #:open-only? #f)))))
                 (unless (or fs done)
                   (error (format #f "the plan holds no claim of ~a for ~a; state the want and the plan answers" spec claimant)))
                 (if done
                     (success `((event-id . "") (already . #t)))
                     (let* ((pool (filter (lambda (r)
                                            (and (equal? spec (economic-resource-conforms-to r))
                                                 (resource-individually-claimable? r ($ root 'recipe-store))
                                                 (not (equal? claimant (economic-resource-primary-accountable r)))
                                                 (let ((oh (economic-resource-onhand-quantity r)))
                                                   (and oh (>= (measure-has-numerical-value oh) qty)))))
                                          ($ obs 'inventory)))
                            (r    (if (pair? pool) (car pool)
                                      (error (format #f "the pool holds no ~a for ~a to claim" spec claimant))))
                            (snlt (crystallized-snlt-for-spec ($ root 'recipe-store) spec))
                            (cost (if (and (number? snlt) (finite? snlt)) (* qty snlt)
                                      (error "the good has no recipe to price it by" spec))))
                       ($ ($ root 'account-store) 'claim (economic-resource-id r) qty claimant cost (credit-roots claimant)
                          #f place when-iso cid)
                       (success `((event-id . ,(let ((evs (or ($ obs 'fulfilled-by cid) '())))   ; newest first
                                                 (if (pair? evs) (economic-event-id (car evs)) "")))
                                  (fulfills . ,cid)
                                  (claimed . ,cost)
                                  (balance . ,(wire-number ($ obs 'credit-balance claimant)))))))))))))

      ;; Live/expected position: where AGENT is at PERIOD (period 0 = now). The
      ;; planner uses it as the commute origin, overriding the static home. place
      ;; is a known location id (client snaps GPS to nearest place first). All
      ;; three sharing modes call this — manual/continuous on period 0, expected
      ;; on future periods. place=#f clears.
      ((set-position scope-id agent-id period place)
       (with-scope scope-id
         (lambda (root) (do-set-position root agent-id period place))))

      ;; Raw-GPS variant: snap lat/lon to the nearest known location, store only
      ;; that place. For clients that send coordinates (gateway does the coarsening).
      ((set-position-latlon scope-id agent-id period lat lon)
       (with-scope scope-id
         (lambda (root)
           (if (sharing-refused? root agent-id period #t)
               (failure "location sharing is off: declare live or here to send a fix")   ; refused before a place is made for the fix
               (do-set-position root agent-id period
                 (or (nearest-location root lat lon)
                     (own-position-place! root agent-id lat lon
                       (append-map (lambda (e) (or (false-if-exception ($ ($ (cdr e) 'spatial-thing-store) 'all-locations)) '()))
                                   (roster-entries)))))))))

      ;; Whether this person shares where they are: live (a watched fix), here (one
      ;; fix) or off. Stated once, at the home, so every device of theirs reads the
      ;; same; off ends the fix that stands.
      ((set-location-sharing scope-id aid mode)
       (scoped scope-id
         (lambda (root)
(let ((m (and (string? mode) (string->symbol mode)))
                     (ps ($ root 'plan-store)))
                 (unless (memq m location-modes)
                   (error "location sharing is live, here or off" mode))
                 ($ ps 'set-meta (location-share-key aid) `((mode . ,m) (at . ,(clock-now))))
                 (when (eq? m 'off) ($ ps 'set-meta (position-key aid 0) '()))
                 m))))

      ((location-sharing scope-id aid)
       (scoped scope-id
         (lambda (root)
(or (location-mode root aid) 'undeclared))))

      ;; PARENT names the place this one is inside: a room in a site, a shelf in
      ;; a room. The child's id is its parent's with its own name after a slash,
      ;; so two rooms each have a "shelf 1", and a child that states no position
      ;; stands at its parent's.
      ((declare-place scope-id agent-id name lat lon #:optional (address #f) (parent #f))
       (scoped scope-id
         (lambda (root)
(let* ((sts  ($ root 'spatial-thing-store))
                      (slug (string-map (lambda (c) (if (or (char-alphabetic? c) (char-numeric? c)) (char-downcase c) #\-))
                                        (string-trim-both (or name ""))))
                      (pid  (string-or-false parent))
                      (par  (and pid ($ sts 'get-location pid)))
                      (id   (if pid
                                (string-append pid "/" slug)
                                (person-place-id agent-id slug)))
                      (has? (and (number? lat) (number? lon) (not (and (zero? lat) (zero? lon)))))
                      (addr (string-or-false address)))
                 (when (string-null? slug) (error "a place needs a name"))
                 (when (and pid (not par)) (error "no such place to be inside"))
                 ($ sts 'add-location
                    (make-spatial-thing #:id id #:name (string-trim-both name)
                                        #:lat (if has? lat (and par (spatial-thing-lat par)))
                                        #:long (if has? lon (and par (spatial-thing-long par)))
                                        #:mappable-address (or addr (and par (spatial-thing-mappable-address par)))
                                        #:contained-in pid))
                 `((id . ,id))))))

      ;; its own claim). OPTS: (at-location [when]) — where the good should
      ;; reach the citizen and when they want it, recorded on the transfer.
      ((claim scope-id resource-id qty claimant labor-cost #:optional (where #f) (deliver-at #f))
       (scoped scope-id
         (lambda (root)
;; the CLAIMANT states which good and how many; the price is the
               ;; good's crystallized labour, derived here. LABOR-COST stays in the
               ;; door's signature for callers that still send it and is not read:
               ;; a cost the client states could be zero or negative.
               (unless (finite-positive? qty)
                 (error "a claim is for a finite positive quantity" qty))
               (let* ((cost (let* ((r (or ($ ($ root 'observer) 'get-resource resource-id)
                                          (error "Resource not found" resource-id)))
                                   (snlt (crystallized-snlt-for-spec
                                           ($ root 'recipe-store)
                                           (economic-resource-conforms-to r))))
                              (unless (and (number? snlt) (finite? snlt))
                                (error "Resource spec has no recipe to price it by"
                                       resource-id))
                              (* qty snlt))))
                 ;; SOLVENCY: a claim draws on what the pool HOLDS. The ledger's
                 ;; decrement has no floor of its own, so the stock is checked
                 ;; here — the observer's on-hand (what the events say is there),
                 ;; and, for a pool with a live reading (the XMR wallet's
                 ;; unlocked balance, resized by the poller), that reading too:
                 ;; a claim the wallet could not pay out is refused at the door.
                 (let* ((obs  ($ root 'observer))
                        (r    (or ($ obs 'get-resource resource-id)
                                  (error "Resource not found" resource-id)))
                        (oh   (economic-resource-onhand-quantity r))
                        (have (if oh (measure-has-numerical-value oh) 0))
                        ;; a live reading counts once one has been taken (total > 0):
                        ;; a freshly spawned gauge at zero is no reading yet
                        (live (let* ((lr (catch #t (lambda () ($ root 'live-registry)) (lambda _ #f)))
                                     (l  (and lr ($ lr 'get resource-id))))
                                (and l (> ($ l 'total) 0) l)))
                        (avail (if live ($ live 'available) have)))
                   (when (> qty have)
                     (error (format #f "the pool holds ~a; ~a asked" have qty)))
                   (when (and live (> qty avail))
                     (error (format #f "the wallet can pay out ~a right now; ~a asked" avail qty)))
                   ;; THE PLAN'S WORD: the shop's "get" confirms what the plan holds
                   ;; for this citizen — the open claim commitment of the good's spec
                   ;; for them (plan-claims! cache) with QTY still remaining. A good the
                   ;; plan did not set aside for them is refused; the want is stated
                   ;; and the next plan answers. WHERE is where the good is to reach
                   ;; them, recorded on the transfer; the row is found by spec alone.
                   (let* ((spec (economic-resource-conforms-to r))
                          (fs   (or (open-claim-for obs spec claimant #:at-least qty)
                                    (error (format #f "the plan holds no claim of ~a for ~a; state the want and the plan answers"
                                                   spec claimant)))))
                     ($ ($ root 'account-store) 'claim resource-id qty claimant cost (credit-roots claimant)
                        #f                                       ; level
                        where deliver-at (fulfillment-state-commitment-id fs))))
                 `((claimed . ,cost)
                            (balance . ,(wire-number ($ ($ root 'observer) 'credit-balance claimant)))
                            (credit . ,(scope-credit->wire root claimant (credit-roots claimant))))))))

      ;; the member's id arrives as `aid` — naming it agent-id would shadow the
      ;; record accessor the updater calls (the silent-degrade class the live
      ;; first-citizen probe catalogued)
      ((set-availability scope-id aid availability-window)
       (with-scope scope-id
         (lambda (root)
           (let ((as ($ root 'agent-store)))
             ($ as 'update-agent aid
                (lambda (old)
                  (copy-agent old #:availability-window availability-window)))
             `(ok . ,aid)))))

      ;; the member's own PROFILE — the typed tags the subsistence context and the
      ;; diet read (sex: age: pregnant: lactating: region: labour-hours: standard:
      ;; diet: allergy: excludes:, and the bare legacy words). JSON is an array of
      ;; tag strings; every profile tag the record held is replaced by them, every
      ;; other classification stays. UPSERT, as availability is: stating who you
      ;; are is the moment you become a person here.
      ((set-profile scope-id aid json)
       (with-scope scope-id
         (lambda (root)
           (let* ((tags (let ((v (false-if-exception (json-string->scm json))))
                          (if (vector? v) (filter string? (vector->list v)) '())))
                  (as ($ root 'agent-store))
                  (with-tags (lambda (old) (append (remove profile-tag? (or old '())) tags))))
             (agent-upsert! as aid
               (lambda (old) (copy-agent old #:classified-as (with-tags (agent-classified-as old))))
               (lambda () (make-agent #:id aid #:type 'person #:name aid #:classified-as (with-tags '())))
               ;; a new body starts with the same two everyone has — walking
               ;; and cycling — declared here exactly as declare-skill would
               ;; raise them on request, not assumed some other way: the one
               ;; default a fresh profile gets, same as every other skill a
               ;; member may later revoke if it doesn't hold for them.
               (lambda () (declare-skill! root aid "walk") (declare-skill! root aid "cycle")))
             `(ok . ,tags)))))

      ;; the member's registered HOME — the agent record's primary-location, the
      ;; floor every position rule falls back to (live.scm agent-cell: live fix →
      ;; committed work → declared future → home). PLACE is a place the scope
      ;; already knows; "" with LAT/LON declares (or re-places) the member's own
      ;; `place:AID:home` and uses that, so a home needs no place anyone else
      ;; named. UPSERT, as set-profile is. Replies (ok (place . id)).
      ;; the member's id arrives as `aid`: naming it agent-id would shadow the
      ;; record accessor the updater calls (see set-availability)
      ((set-home scope-id aid place lat lon)
       (scoped scope-id
         (lambda (root)
(let* ((sts ($ root 'spatial-thing-store))
                      (as ($ root 'agent-store))
                      (given (string-or-false place))
                      (has? (and (number? lat) (number? lon) (not (and (zero? lat) (zero? lon)))))
                      (id (cond (given
                                 (unless (false-if-exception ($ sts 'get-location given))
                                   (error "no such place in this scope" given))
                                 given)
                                (has?
                                 (let ((id (person-place-id aid "home")))
                                   ($ sts 'add-location
                                      (make-spatial-thing #:id id #:name (string-append "home of " aid) #:lat lat #:long lon
                                                          #:contained-in (standing-in lat lon ($ sts 'all-locations))))
                                   id))
                                (else (error "a home needs a known place or coordinates")))))
                 (agent-upsert! as aid
                   (lambda (old) (copy-agent old #:primary-location id))
                   (lambda () (make-agent #:id aid #:type 'person #:name aid #:primary-location id #:classified-as '())))
                 `((place . ,id))))))

      ;; declare-dwelling: the dwelling this AID lives in, as the housing closure
      ;; reads it (knowledge/housing-substance.scm resource->dwelling-unit): one
      ;; owned resource `dwelling:AID` of spec-dwelling standing at PLACE — the
      ;; AID's registered home when "" — measured by its tags. `area-m2:` and
      ;; `rooms:` are the whole dwelling's, shared by the `beds:` it houses a
      ;; night; `warmth-winter-degc:` and `warmth-summer-degc:` what it is kept
      ;; at in each season — the three gradients its nights deliver. A RENTED
      ;; dwelling is held under split custody: the tenant custodies it, the
      ;; landlord is primary-accountable, so schemas.scm's resource-rented? reads
      ;; it and the fragility wheel shows the eviction risk as it does any
      ;; loaned-in means (rented-fragility.md). `attests:<gate>` is what an inspection of it would
      ;; certify, `certified` that the certificate stands, `rent-eur-night:` its
      ;; own rent where a landlord is paid (the unit's price, else the rent
      ;; recipe's), `tenure:` own|rent|lodged — custody, never a row of the
      ;; vector (docs/rights.md), kept so a bed lent out of a rented flat is
      ;; known to be a lease question. Re-declaring replaces the tags; a
      ;; measurement that is not a positive number is refused.
      ((declare-dwelling scope-id aid place area rooms warmth-winter warmth-summer beds attests-json certified rent tenure)
       (scoped scope-id
         (lambda (root)
(let* ((obs  ($ root 'observer))
                      (as   ($ root 'agent-store))
                      (sts  ($ root 'spatial-thing-store))
                      (given (string-or-false place))
                      (home (and=> ($ as 'get-agent aid) agent-primary-location))
                      (loc  (or given home (error "a dwelling stands at a place: name one, or register a home first")))
                      (m    (lambda (what x) (if (and (real? x) (> x 0)) (number->string (exact->inexact x))
                                                 (error "a dwelling states a positive" what x))))
                      (n    (if (and (number? beds) (> beds 0)) beds 1))
                      (gates (filter housing-gate? (cats-json->list attests-json)))
                      (tags (append (list (string-append "area-m2:" (m "floor area" area))
                                          (string-append "rooms:" (m "room count" rooms))
                                          (string-append "warmth-winter-degc:" (m "winter warmth" warmth-winter))
                                          (string-append "warmth-summer-degc:" (m "summer warmth" warmth-summer))
                                          (string-append "beds:" (number->string n)))
                                    (map (lambda (g) (string-append "attests:" g)) gates)
                                    (if (and certified (pair? gates)) '("certified") '())
                                    (if (and (number? rent) (> rent 0))
                                        (list (string-append "rent-eur-night:" (number->string rent))) '())
                                    (if (and (string? tenure) (member tenure '("own" "rent" "lodged")))
                                        (list (string-append "tenure:" tenure)) '())))
                      (rid  (dwelling-id aid))
                      (rented? (equal? tenure "rent")))
                 (unless (false-if-exception ($ sts 'get-location loc))
                   (error "no such place in this scope" loc))
                 ($ obs 'record-resource
                    (make-economic-resource
                     #:id rid #:name (string-append aid "'s dwelling") #:image "🏠"
                     #:conforms-to "spec-dwelling" #:classified-as tags
                     #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit)
                     #:current-location loc
                     #:primary-accountable (if rented? (string-append "landlord:" aid) aid)   ; primary-accountable: who can recall it
                     #:custodian-scope (if rented? aid #f)                                 ; custodian-scope: who holds it meanwhile
  ))
                 `((resource . ,rid) (place . ,loc) (tags . ,tags))))))

      ;; Dial availability: JSON is an array of {start:"HH:MM", end:"HH:MM",
      ;; days:[name…]} — one arc per object. Each becomes a day-schedule (its
      ;; weekday-set + time-range); they union into the agent's availability
      ;; window. Empty array clears the window (back to unconstrained). The dial
      ;; sends this through HANDLERS.setAvailability; we parse it here (the
      ;; browser spine has no JSON reader), same as solve-brief's overrides.
      ((set-availability-ranges scope-id aid json)
       (with-scope scope-id
         (lambda (root)
           (let* ((window (arcs-json->window json))
                  (as ($ root 'agent-store)))
             ;; a browser-born AID has no prior record, and an update that
             ;; returned #f for it would silently drop the offer (the solve
             ;; then plans over 0 available hours forever)
             (agent-upsert! as aid
               (lambda (old) (copy-agent old #:availability-window window))
               (lambda () (make-agent #:id aid #:type 'person #:name aid #:classified-as '() #:availability-window window))
               ;; generic labour comes with the person: a skill is a
               ;; resource conforming to its spec (agents-with-skill groups
               ;; by primary-accountable), and spec-labor is the one every
               ;; person can work — without it a first citizen's offered
               ;; hours count for nothing the plan can schedule.
               ;; …and the spec says it is worked (its effort unit), which is
               ;; what makes the resource read as a skill at all
               ;; (declare-skill!'s own step, for the generic)
               (lambda ()
                 (unless ($ ($ root 'recipe-store) 'get-resource-spec generic-labour-spec-id)
                   ($ ($ root 'recipe-store) 'add-resource-spec generic-labour-spec))
                 ($ ($ root 'observer) 'record-resource
                    (make-economic-resource
                     #:id (generic-skill-id aid)
                     #:name (string-append aid " " generic-labour-spec-id)
                     #:conforms-to generic-labour-spec-id
                     #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable aid))))
             `(ok . ,aid)))))

      ;; ── skills: an EconomicResource per (agent, skill), moved by EVENTS ──
      ;; The declare/revoke pair is VF's raise/lower (concepts/actions.md):
      ;; a self-declared skill is labour-power formed OUTSIDE the recorded
      ;; economy, so entering it is exactly raise's "beginning balance" case —
      ;; the recorded formation of skills (training, practiced hours) is the
      ;; earned-skills ledger, a different door. Every skill reader takes
      ;; on-hand > 0 as "held", so the events are the whole lifecycle and the
      ;; resource + its history remain across it. A skill lives in the
      ;; observer, so the agent-store's on-agent rail — the labour fold's
      ;; refold trigger — stays quiet on a skill write; the identity re-update
      ;; of the agent record fires it (agents.scm update-agent), and the
      ;; scope's ^labour-pool refolds the new skill set.
      ((declare-skill scope-id agent-id skill-spec-id)
       (with-scope scope-id
         (lambda (root)
           (let ((rid (declare-skill! root agent-id skill-spec-id)))
             ($ ($ root 'agent-store) 'update-agent agent-id (lambda (a) a))
             `(ok . ,rid)))))

      ;; the citizen's own held skills — the roster's reading (on-hand > 0)
      ((my-skills scope-id agent-id)
       (with-scope scope-id
         (lambda (root)
           (success `((skills . ,(skill-specs-for-agent ($ root 'observer)
                                                        agent-id (scope-labour? root))))))))

      ;; raise's inverse: withdrawing the self-declaration lowers the on-hand
      ;; to zero. The resource stays, carrying both events.
      ((revoke-skill scope-id agent-id skill-spec-id)
       (with-scope scope-id
         (lambda (root)
           (let ((rid (revoke-skill! ($ root 'observer) agent-id skill-spec-id)))
             ($ ($ root 'agent-store) 'update-agent agent-id (lambda (a) a))
             `(ok . ,rid)))))

      ;; skill-standing: what the agent has DECLARED, beside what the record
      ;; shows for it — one row per skill that is held or practiced, in the one
      ;; measure every reader of a skill already uses, HOURS:
      ;;   held           on the roster (declare-skill)
      ;;   hours          validated hours — the observer's practiced-hours, the
      ;;                  same recipient-side gate the credit ledger folds, so
      ;;                  Σ hours here is the agent's validated gross
      ;;   competence     where the skill stands today: the record folded through
      ;;                  the skill's own law (skill-law.scm — idle time wears it,
      ;;                  satisfied practice renews it; no law, the ledger itself)
      ;;   events / witnessed / attesters / witnessed-hours
      ;;                  the work-event credentials behind it: how many, how
      ;;                  many reached a witness quorum, co-signed by how many
      ;;                  distinct people, over how many hours
      ;;   pending        ceremonies still collecting: ((count . n) (quorum . k)) …
      ;; A declared skill with no work behind it stands as the citizen's word alone.
      ((skill-standing scope-id agent-id)
       (with-scope scope-id
         (lambda (root)
           (let* ((obs     ($ root 'observer))
                  (held    (skill-specs-for-agent obs agent-id (scope-labour? root)))
                  (practice (practice-view-of obs (person-observers agent-id)))
                  (hours   (practice-view-hours practice agent-id))
                  (social  (door-read 'standing scope-id agent-id (map car (roster-entries))))
                  (pending (door-read 'outbox agent-id))
                  (specs   (or (false-if-exception ($ ($ root 'recipe-store) 'all-resource-specs)) '()))
                  (law-of  (lambda (skill)
                             (let ((sp (find (lambda (x) (equal? (resource-specification-id x) skill)) specs)))
                               (and sp (skill-law-of (resource-specification-resource-classified-as sp))))))
                  (now     (iso-now))
                  (skills  (delete-duplicates (append held (map car hours) (map car social)))))
             (success
              `((standing
                 . ,(map (lambda (skill)
                           (let ((ev (or (assoc-ref social skill) '())))
                             `((skill . ,skill)
                               (held . ,(and (member skill held) #t))
                               (hours . ,(or (assoc-ref hours skill) 0))
                               (competence . ,(competence-fold (practice-view-dated practice agent-id skill)
                                                               (law-of skill) #:today now))
                               (events . ,(or (assq-ref ev 'events) 0))
                               (witnessed . ,(or (assq-ref ev 'witnessed) 0))
                               (attesters . ,(or (assq-ref ev 'attesters) 0))
                               (witnessed-hours . ,(or (assq-ref ev 'witnessed-hours) 0))
                               (pending
                                . ,(filter-map
                                    (lambda (r)
                                      (and (equal? (assq-ref r 'skill) skill)
                                           `((count . ,(assq-ref r 'count))
                                             (quorum . ,(assq-ref r 'quorum)))))
                                    pending)))))
                         skills))))))))

      ;; declare-means: self-declare a MEANS OF PRODUCTION you own — the ownership
      ;; a socialization grant needs to project capacity. Seeds an owned
      ;; EconomicResource (primary-accountable = AGENT-ID, conforms-to = SPEC) into
      ;; SCOPE-ID's observer, the sibling of declare-skill for productive means.
      ;; Ownership is self-asserted here; the assertion's credential form is the
      ;; ownership attestation (governance own-means legs) — once one stands over
      ;; a resource, the socialization gates hear only it (%grant-over? +
      ;; title-permits?) and the federation auditor's ownership-coherent? check
      ;; flags a field that contradicts it. A socialize grant only projects if
      ;; issuer == this owner, in field and title alike.
      ;; ── slots: capacity + need as ONE expression (free-association port) ──
      ;; A slot is quantity + unit + place + a recurring time pattern (the
      ;; arcs wire → <availability-window>). A CAPACITY slot is an owned
      ;; <economic-resource> (deterministic id ⇒ re-declaring IS editing);
      ;; a NEED slot is an <intent> with receiver = the citizen — the same
      ;; window field, so matching/feasibility and the labour pools read
      ;; both sides with the machinery that already exists. No new fields:
      ;; note rides note, the emoji rides image, the pattern rides
      ;; availability-window, bounds ride has-beginning/has-end.
      ((declare-means scope-id agent-id spec qty unit location
                      #:optional (arcs-json #f) (note #f) (emoji #f) (name #f) (cats-json #f) (criteria-json #f))
       (with-scope scope-id
         (lambda (root)
           (declare-means-reply root agent-id spec qty unit location
                                arcs-json note emoji name cats-json (criteria-json->alist criteria-json)
                                #:changed! (lambda () (means-changed! scope-id))))))

      ;; THE CITIZEN'S ORDER BOOK — the plan's word on each of their wants.
      ;; Three states, one list: ASKED (a `need:aid:spec` consume intent the plan
      ;; has not yet answered with a row), HELD (a claim commitment the plan
      ;; registered for them, plan-claims!, with what remains on it) and TAKEN
      ;; (a row confirmed in full). Each row carries the good's crystallized
      ;; SNLT — the certificate it draws per unit — so the face prices nothing.
      ;; A want with no row says so: the plan held none this solve (the pool had
      ;; none, or the certificate could not carry it); the want stands, and the
      ;; next plan answers again.
      ((my-claims scope-id agent-id)
       (scoped scope-id
         (lambda (root)
(let* ((obs ($ root 'observer)) (ps ($ root 'plan-store)) (rs ($ root 'recipe-store))
                      (price (lambda (spec) (let ((p (false-if-exception (crystallized-snlt-for-spec rs spec))))
                                              (and (number? p) (finite? p) p))))
                      (mval (lambda (m) (if m (measure-has-numerical-value m) 0)))
                      (rows (filter-map
                             (lambda (fs)
                               (let* ((cid (fulfillment-state-commitment-id fs))
                                      (t   (claim-terms obs cid))
                                      (spec (and t (assq-ref t 'spec))))
                                 (and t
                                      (let ((total (mval (fulfillment-state-total-committed fs)))
                                            (done  (mval (fulfillment-state-total-fulfilled fs))))
                                        `((id . ,cid)
                                          (spec . ,spec) (name . ,(lookup-spec-name rs spec))
                                          (place . ,(or (assq-ref t 'place) "")) (when . ,(or (assq-ref t 'when) ""))
                                          (total . ,total) (fulfilled . ,done) (remaining . ,(max 0 (- total done)))
                                          (snlt . ,(price spec))
                                          (state . ,(if (fulfillment-state-finished fs) "taken" "held")))))))
                             (claim-fulfillments obs #:receiver agent-id #:open-only? #f)))
                      (answered (map (lambda (r) (assq-ref r 'spec)) rows))
                      (prefix (need-prefix agent-id))
                      (asked (filter-map
                              (lambda (i)
                                (and (string-prefix? prefix (intent-id i))
                                     (memq (intent-action i) using-up-actions)
                                     (not (intent-finished i))
                                     (not (member (intent-resource-conforms-to i) answered))
                                     (let ((spec (intent-resource-conforms-to i)))
                                       `((id . ,(intent-id i)) (spec . ,spec) (name . ,(lookup-spec-name rs spec))
                                         (place . ,(or (intent-at-location i) "")) (when . ,(or (intent-has-beginning i) ""))
                                         (total . ,(mval (intent-resource-quantity i))) (fulfilled . 0) (remaining . 0)
                                         (snlt . ,(price spec)) (state . "asked")))))
                              ($ ps 'all-intents))))
                 `((rows . ,(append asked rows)))))))

      ;; retire-means: withdraw the offer — a `lower` to zero, the record and
      ;; its history standing (readers take on-hand > 0 as offered), the
      ;; mirror of retire-need at the resource layer.
      ((retire-means scope-id agent-id spec)
       (with-scope scope-id
         (lambda (root)
           (let* ((obs ($ root 'observer))
                  (rid (means-id agent-id spec))
                  (r   ($ obs 'get-resource rid)))
             (when r (lower-resource! obs agent-id r "means retired"))
             (means-changed! scope-id)
             `(ok . ,rid)))))

      ;; NEED slot: an <intent> with receiver = the citizen. Deterministic id
      ;; ("need:AID:SPEC") ⇒ re-declaring IS editing (remove + add); the
      ;; window keeps a promoted intent never-finished (planning.scm), i.e. a
      ;; STANDING order — the plan provisions it; the shop's claim is only
      ;; the fallback when communal provision can't satisfy it.
      ((declare-need scope-id agent-id spec qty unit location arcs-json note emoji from until
                     #:optional (name #f) (cats-json #f) (criteria-json #f) (need-kind #f) (voice 0))
       (with-scope scope-id
         (lambda (root)
           (declare-need-reply root agent-id spec qty unit location arcs-json note emoji from until
                               name cats-json (criteria-json->alist criteria-json) need-kind voice
                               #:changed! (lambda () (slots-changed! scope-id))))))

      ;; the citizen's slots, both kinds, one wire: quantity/unit/place/note/
      ;; emoji + the arcs of the availability-window. Zero-qty means are
      ;; retired declarations and are filtered out.
      ((my-slots scope-id agent-id)
       (with-scope scope-id
         (lambda (root)
           (my-slots-reply root agent-id
                           #:met-of (met-of-scope cache root scope-id)
                           #:criteria-of (lambda (r) (means-criteria scope-id root r))))))

      ;; retire a need slot: the intent goes away entirely (a standing order
      ;; withdrawn). Guarded by the deterministic id, so a citizen can only
      ;; retire their own.
      ((retire-need scope-id agent-id spec)
       (with-scope scope-id
         (lambda (root)
           (let ((iid (need-id agent-id spec)))
             ($ ($ root 'plan-store) 'remove-intent iid)
             (slots-changed! scope-id)
             `(ok . ,iid))))))))
