;;; module/playnet/boot/communes.scm — the founding commune under the UC, and the communes this gateway seeds under earth.

(define-module (playnet boot communes)
  #:use-module ((playnet boot restore) #:select (restored-scope))
  #:use-module ((playnet boot scope) #:select (spawn-scope))
  #:use-module ((playnet boot site) #:select (data-path keep-line! law-packs log! seed-demo?))
  #:use-module ((playnet dev plan) #:select (read-dev-people seed-dev-scope!))
  #:use-module ((playnet dev priorities) #:select (issues->facts))
  #:use-module ((playnet dev rad-issues) #:select (rad-issue-pairs))
  #:use-module ((playnet keys keri-backend live) #:select (live-keri-backend))
  #:use-module ((playnet knowledge recipes bay-area-commune-seed) #:select (seed-bay-area-commune!))
  #:use-module ((playnet knowledge recipes berlin-commune-seed) #:select (seed-berlin-commune!))
  #:use-module ((playnet knowledge recipes berlin-festival-seed) #:select (attach-festival-futures! seed-berlin-festival-arm!))
  #:use-module ((playnet knowledge recipes bread-commune-seed) #:select (seed-bread-commune!))
  #:use-module ((playnet knowledge recipes farm-commune-seed) #:select (seed-farm-holds!))
  #:use-module ((playnet scope root) #:select (spawn-scope-root))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (stand-founding-commune! seed-communes!))

;; ── Founding commune "Playnet" under the UC ──
;; The dial PLANS here (economic substrate = the scope-root); the
;; UC is the governance root above. Created in PLANNER-VAT — where
;; the economic root lives, so spawn-scope's $-access to it works.
;; Discover-or-mint + persist the AID, then register the root with
;; the planner BY scope-aid so scope-list shows a real commune,
;; never org:meeting. The uc-curator admits it to the UC via the
;; scope-graph hook spawn-scope fires (current-scope-graph is set).
(define* (stand-founding-commune! #:key planner-vat earth meeting-scope planner-service governance-svc
                                  fc-key fc-aid-early restored)
  "(values fc-aid fc-scope): the founding commune's AID and its ^scope,
restored when FC-AID-EARLY names one among RESTORED, else minted; both #f
when it could not stand."
  (let* ((fc-existing (and fc-aid-early (restored-scope restored fc-aid-early)))
         (stood
          (with-vat planner-vat
            (let* ((minted
                    (and (not fc-existing)
                         (catch #t
                           (lambda ()
                             (spawn-scope "Playnet" #:kind 'commune
                                          #:scope-root-ref meeting-scope
                                          #:durable? #t
                                          #:keri-backend (live-keri-backend)))
                           (lambda (k . a)
                             (log! "  [gateway] founding commune live-keri mint failed (~a ~a); synthetic~%" k a)
                             (catch #t
                               (lambda ()
                                 (spawn-scope "Playnet" #:kind 'commune
                                              #:scope-root-ref meeting-scope
                                              #:durable? #t))
                               (lambda (k2 . a2)
                                 (log! "  [gateway] founding commune mint failed: ~a ~a~%" k2 a2)
                                 #f))))))
                   (fc-aid (or fc-aid-early (and minted ($ minted 'scope-aid)))))
              (if (not fc-aid)
                  (begin
                    (log! "  [gateway] founding commune unavailable; dial has no scope~%")
                    (cons #f #f))
                  (begin
                    (log! "  [gateway] founding commune Playnet: ~a (~a)~%"
                          fc-aid (if fc-existing 'restored 'minted))
                    (when minted
                      (catch #t
                        (lambda () (keep-line! (data-path "founding-commune-aid.txt") fc-aid))
                        (lambda (k . a)
                          (log! "  [gateway] write founding-commune aid-file failed: ~a ~a~%" k a))))
                    ;; key the founding commune in earth by its real AID (rekeys the
                    ;; first-boot %founding-key placeholder; a no-op on restart, where
                    ;; fc-key already IS the aid). The planner reads earth for the
                    ;; roster, and add-scope! is the fold door: crossing it stands up
                    ;; the founding commune's labour/demand/means/folksonomy nodes and
                    ;; descent leaves like every other scope's (earth's add-commune!
                    ;; is an idempotent re-key underneath).
                    ($ earth 'rekey-commune! fc-key fc-aid)
                    ;; the solve queue lands on this vat: from here on every
                    ;; solve runs on a thread of its own and the vat serves
                    ;; every read while it runs (service.scm plan-fn*)
                    ($ planner-service 'set-solve-vat! planner-vat)
                    ($ planner-service 'add-scope! fc-aid meeting-scope)
                    (log! "  [gateway] dial scope -> Playnet (~a)~%" fc-aid)
                    ;; the founding commune's ^scope is the governance
                    ;; service's home: its sign-said is what stamps
                    ;; fp-grant/fp-vouch/ceremony credentials.
                    (let ((fc-scope (or minted fc-existing)))
                      (when fc-scope
                        ($ governance-svc 'set-home-scope! fc-scope)
                        (log! "  [gateway] governance home-scope -> founding commune~%"))
                      (cons fc-aid fc-scope))))))))
    (values (car stood) (cdr stood))))

(define* (seed-communes! #:key planner-vat earth planner-service)
  "The communes seeded under earth: Berlin/Brandenburg, the Bay Area's,
playnet's own development, and the demo's second commune. The development
commune's root, for the operator REPL, or #f."
  (define dev-root #f)
  (with-vat planner-vat
    ;; ── Berlin/Brandenburg commune under the UC — a REAL ecoregional scope ──
    ;; A live commune placed in the registered "berlin" bioregion (live.scm
    ;; boot-loads the shed), so its plan inherits the region's real drought
    ;; futures + water/soil limits by containment — no per-commune wiring.
    ;; Seeded UNCONDITIONALLY (not demo-gated) so it is live in prod. Synthetic
    ;; deterministic AID (E_commune_Berlin) → idempotent across boots; the
    ;; uc-curator auto-adopts it via the scope-graph orphan hook spawn-scope
    ;; fires (current-scope-graph is set). This is the exact founding-commune
    ;; path (spawn-scope-root + spawn-scope + seed + add-scope!), with a real
    ;; ecoregion seeded into its stores.
    ;; DURABILITY: the scope-root re-seeds deterministically each boot (same
    ;; AID, same farm), so Berlin reliably returns identical across reboots;
    ;; and socialization GRANTS to it are durable independently — a custody
    ;; ACDC in the durable gov-acdc-store keyed by this stable AID, so a
    ;; re-seed re-discovers them (test-berlin-live-scope's sibling checks).
    ;; The scope-root NAME drives the dial's commune-switcher label; the AID
    ;; stays the clean deterministic E_commune_Berlin (no slash).
    (catch #t
      (lambda ()
        (let* ((broot ($ earth 'ensure-commune! "E_commune_Berlin" "Berlin/Brandenburg" (law-packs)))  ; durable under earth
               (bc    (spawn-scope "Berlin" #:kind 'commune #:scope-root-ref broot))
               (b-aid ($ bc 'scope-aid)))
          ;; seed the farm ONCE — a restored/durable root already carries it
          (when (null? ($ ($ broot 'observer) 'all-resources))
            (seed-berlin-commune! broot))
          ;; the farm's land and water reach tomorrow: the hold
          ;; door, idempotent — a durable root seeded before
          ;; holds existed gains them on this boot
          (seed-farm-holds! broot "berlin-commune-farm")
          ;; …and the FOOD FESTIVAL arm (its own once-guard). Its
          ;; crowd terms carry a rolling window, so the arm also
          ;; registers on the planner tick's re-stand door: the
          ;; day the window ages out, the next resolve-stale!
          ;; re-lays it and the solve behind it rolls the
          ;; schedule forward.
          ($ planner-service 're-stand!
             (lambda () (seed-berlin-festival-arm! broot)))
          ;; the twelve Bezirke's pits, growing as gardening WORK the
          ;; willingness rail runs over, and the crowd's standing
          ;; terms — a floor held in every branch + the want above
          (seed-berlin-festival-arm! broot)
          ;; the festival's futures: the shed's weather crossed
          ;; with the districts' own shade rides the "berlin"
          ;; bioregion, so the commune inherits it by containment.
          ;; Permission is a wall, not a future: the crowd's floor
          ;; is a right held against ANY ONE district lost
          ;; (`against:1`, the budgeted wall), which is what
          ;; spreads the planting across the districts
          (attach-festival-futures!)
          ;; key earth by the real governance AID (a no-op when the synthetic
          ;; AID matches; corrects earth if it ever drifts). The planner reads
          ;; earth — this is the sole registration.
          ($ earth 'rekey-commune! "E_commune_Berlin" b-aid)
          (log! "  [gateway] Berlin/Brandenburg commune under UC: ~a~%" b-aid)))
      (lambda (k . a)
        (log! "  [gateway] Berlin commune seed failed: ~a ~a~%" k a)))
    ;; ── Bay Area subscopes: SF + Oakland market-garden communes under earth ──
    ;; Durable communes placed in the registered "bay-area" bioregion (each
    ;; city ⊂ bay-area), so they inherit California's Mediterranean drought
    ;; futures + its EXTREME water limit by containment. Same durable path as
    ;; Berlin: earth-held root, seeded once, deterministic AID. Nested scopes.
    (for-each
     (lambda (spec)
       (catch #t
         (lambda ()
           (let* ((aid    (list-ref spec 0)) (spawn-nm (list-ref spec 1))
                  (nm     (list-ref spec 2)) (city (list-ref spec 3))
                  (place  (list-ref spec 4))
                  (broot  ($ earth 'ensure-commune! aid nm (law-packs)))              ; durable under earth
                  (sc     (spawn-scope spawn-nm #:kind 'commune #:scope-root-ref broot))
                  (sc-aid ($ sc 'scope-aid)))
             (when (null? ($ ($ broot 'observer) 'all-resources))         ; seed once
               (seed-bay-area-commune! broot #:place place #:city city #:city-name nm))
             (seed-farm-holds! broot place)   ; durable roots gain their holds
             ($ earth 'rekey-commune! aid sc-aid)   ; earth keyed by the real AID
             (log! "  [gateway] Bay Area commune ~a under UC: ~a~%" nm sc-aid)))
         (lambda (k . a)
           (log! "  [gateway] Bay Area commune seed failed: ~a ~a~%" k a))))
     (list (list "E_commune_SF"      "SF"      "San Francisco" "san-francisco" "sf-garden")
           (list "E_commune_Oakland" "Oakland" "Oakland"       "oakland"       "oak-garden")))
    ;; ── playnet development, as a commune under earth ──────────────
    ;; Real, not demo-gated, same durable path as Berlin/Bay Area:
    ;; a synthetic deterministic AID, earth-held, one persistence
    ;; graph (earth.scm's own "no per-commune store files").
    ;; Deliberately stops at ensure-commune! — no spawn-scope /
    ;; rekey-commune! / seed-farm-holds! the way Berlin/Bay Area
    ;; continue: this is internal tooling, not a KERI-governed
    ;; community, and Berlin/Bay Area's own synthetic-AID
    ;; precedent already establishes a commune needs neither a
    ;; minted governance scope-aid nor network reachability to
    ;; be real and planned-over (a future addition, never a
    ;; blocker — see the dev-commune plan's own out-of-scope
    ;; note). An open Radicle issue is a want, its `area:` a skill
    ;; (knowledge/skills/dev-skills.scm), the scope's people
    ;; docs/dev-scope.sexp states — module/playnet/
    ;; bridge/dev-plan.scm's own plan-dev-week runs over exactly
    ;; this commune, reached by tools/{dev-plan,dev-signal-cycle,
    ;; dev-loop-close}.scm through the REPL socket below (so a
    ;; booked hour lands as a REAL VF event this gateway's own
    ;; account.scm/skill-law.scm already read — the whole point).
    ;;
    ;; `rad`/network I/O at boot, wrapped: a Radicle-unreachable
    ;; boot never blocks the gateway. The tools' own runs reseed
    ;; on their own schedule regardless — this is only so the
    ;; commune is not EMPTY between them.
    (catch #t
      (lambda ()
        (let* ((droot ($ earth 'ensure-commune! "E_commune_devwork" "playnet development" (law-packs))))
          (when (null? ($ ($ droot 'observer) 'all-resources))
            (let ((facts  (false-if-exception (issues->facts (rad-issue-pairs))))
                  (people (read-dev-people (or (getenv "DEV_SCOPE_PATH") "docs/dev-scope.sexp"))))
              (seed-dev-scope! droot (or facts '()) people)))
          (set! dev-root droot)
          (log! "  [gateway] playnet development commune under earth: E_commune_devwork~%")))
      (lambda (k . a)
        (log! "  [gateway] dev commune seed failed: ~a ~a~%" k a)))
    ;; Demo-only 2nd commune so the dial's commune switcher is
    ;; exercisable in dev; prod registers real UC-subtree communes
    ;; the same way (spawn-scope + add-scope!). It plans over the
    ;; bread town — the grow→mill→bake economy the live planner
    ;; suites share ((playnet test planner bread)), seeded off the
    ;; same record lists by seed-bread-commune!, so what the suite
    ;; proves is what the switcher lands on.
    (when (seed-demo?)
      (catch #t
        (lambda ()
          (let* ((root2 (spawn-scope-root "Bread town" #:law-packs (law-packs)))
                 (c2    (spawn-scope "Bread town" #:kind 'commune
                                     #:scope-root-ref root2))
                 (c2-aid ($ c2 'scope-aid)))
            (seed-bread-commune! root2)
            ($ planner-service 'add-scope! c2-aid root2)
            (log! "  [gateway] demo 2nd commune Bread town: ~a~%" c2-aid)))
        (lambda (k . a)
          (log! "  [gateway] demo 2nd commune failed: ~a ~a~%" k a)))))
  dev-root)
