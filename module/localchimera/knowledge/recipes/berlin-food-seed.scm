;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; berlin-food-seed.scm — the Berlin food chain as DATA over the generic
;;; seed-food-chain! (food-chain-seed.scm). Reclaim from a Betrieb, hold it cold,
;;; hand it out at a Fairteiler.
;;;
;;; The twin of berlin-commune-seed.scm: that file is Berlin's GROWING half as
;;; data over seed-farm-commune!, this one is the half that happens after the
;;; harvest. Between them Berlin has a chain from the field to the table with no
;;; mechanism of its own.
;;;
;;; ── WHAT IS BERLIN ABOUT THIS ────────────────────────────────────────────
;;;   · the vehicle is a LASTENRAD, not a refrigerated van — the existing
;;;     `spec-bt-cargo-bike` (berlin-transit.scm, 100 kg payload), so the chain
;;;     draws on the same vehicle pool the transit recipes already model;
;;;   · a COLD ROOM stands between pickup and handout, the storage column the
;;;     Berlin scope otherwise lacks — August surplus reaches a later period
;;;     because the commune HAS a Kühlraum, not because a caller passed a flag;
;;;   · the handout site decides one crossing. A Fairteiler indoors in a
;;;     Nachbarschaftshaus trips `share-food`; the same table on the pavement
;;;     also trips `feed-in-public`, which is what Berlin's Sondernutzungs-
;;;     erlaubnis answers (contexts/de.sexp). Same chain, one flag, a different
;;;     legal exterior — derived, never written here.
;;;
;;; Nothing in this file names a statute, a permit, or an authority.
;;;
;;; ── PROVENANCE ───────────────────────────────────────────────────────────
;;; [DATA]  Payload and vehicle from berlin-transit.scm (spec-bt-cargo-bike).
;;; [DRAFT] Durations, the 0.9 sorting yield and the cold-room draw are judgment
;;;   figures in the shape foodsharing-style Abholungen run; a Berlin steward
;;;   replaces them with measured ones without touching the mechanism.

;; A Lastenrad load, not a van load: the chain's batch is the bike's payload.
(define-module (localchimera knowledge recipes berlin-food-seed)
  #:use-module (localchimera knowledge recipes foodsharing-kit)
  #:use-module (localchimera knowledge recipes food-chain-seed)
  #:use-module (localchimera vf schemas)
  #:use-module (localchimera vf beyond schedules)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera knowledge recipes berlin-transit)
  #:export (*berlin-food-batch* berlin-food-chain-stages *berlin-food-chain-stages*
            seed-berlin-food-recipe! seed-berlin-food-scope!))

(define *berlin-food-batch* 100.0)

;;; the four stages, in order. `uses` rows are (spec-id qty unit label).
(define* (berlin-food-chain-stages #:key (public-handout? #f))
  (list
   ;; the pickup draws the COLD half of the shared kit plus a Lastenrad — means
   ;; the Kiezküche holds, not things each person must own and carry
   ;; (foodsharing-kit.scm).
   (food-stage "abholung" "Abholung beim Betrieb" #:hours 0.75
               #:uses (cons '("spec-bt-cargo-bike" 0.75 "hours" "Cargo Bike (Lastenrad)")
                            (foodsharing-cold-uses)))
   (food-stage "sichten" "Sichten & aussortieren" #:hours 0.5 #:yield 0.9
               #:good "spec-bfs-gesichtet" #:good-name "Gesichtete Lebensmittel")
   ;; the handout. Where the table stands decides the crossing.
   ;; the handout draws the HAND half: gloves and tongs for unpackaged Backwaren
   ;; NON-PERSONAL: food goes into a cabinet anyone may open, with nobody there
   ;; to judge the taker or say "eat this today". That is the channel both
   ;; rulebooks gate the strictest list on — and it is why a home-cooked pot may
   ;; pass hand to hand and may not be left here.
   (food-stage "fairteiler" "Ausgabe am Fairteiler" #:hours 0.25
               #:uses (foodsharing-hand-uses)
               #:channel 'non-personal
               #:crossings (if public-handout? '(feed-in-public) '()))
   ;; the STORAGE column. A Fairteiler IS a cooled cabinet: food set out on
   ;; Monday waits in it for whoever comes on Tuesday. The container is
   ;; keep-in-place, so the engine tiles this process along the TIME edge —
   ;; the column that lets an August glut reach a later period at all.
   ;; The stay itself is the period — the arc runs along the time edge — so
   ;; the stated length is the HANDLING: stocking the cabinet and clearing it,
   ;; the same 0.02 h a transport hold pays its container (transport.scm
   ;; recipe-hold). Without it the cold-room draw has no length of its own and
   ;; is taken for the whole period (lint: untimed-use).
   (food-stage "kuehlung" "Fairteiler-Kühlschrank" #:kind 'store #:hours 0.02
               #:uses `(("spec-bfs-kuehlraum" 0.02 "m3h" "Kühlraum (m³·h)")))))

(define *berlin-food-chain-stages* (berlin-food-chain-stages))

;;; Seed Berlin's reclamation chain into RECIPE-STORE. The crossings it declares
;;; are placeless facts about the activity; the bill for them is the legal fold's
;;; business, in Berlin or anywhere else the same chain runs.
(define* (seed-berlin-food-recipe! rs #:key (public-handout? #f)
                                            (id "recipe-berlin-food-chain")
                                            (batch *berlin-food-batch*))
  (seed-food-chain! rs
    #:id id #:name "Berliner Lebensmittelrettung"
    #:intake "spec-bfs-ueberschuss" #:intake-name "Überschuss vom Betrieb"
    #:outlet "spec-bfs-fairteiler"  #:outlet-name "Lebensmittel am Fairteiler"
    #:unit "kg" #:batch batch
    #:classes '("food")
    ;; surplus comes in as a gift from the Betrieb, and goes out as a gift at the
    ;; Fairteiler: the two exchanges legal/crossings.scm reads as recover-surplus and
    ;; share-food
    #:received 'gift
    #:handed-over 'gift
    ;; the chain's labour is QUALIFIED labour: a pickup wants a Foodsaver, and a
    ;; Foodsaver is made by three supervised Einführungsabholungen consuming an
    ;; experienced one's hours (foodsharing-kit.scm). So mentor capacity, not
    ;; goodwill, is what bounds how fast a district can grow.
    #:work (foodsaver-skill) #:work-name "Foodsaver (Ausweis)"
    #:stages (berlin-food-chain-stages #:public-handout? public-handout?))
  ;; The Fairteiler cabinet is a PUBLIC FRIDGE, and operating one is its own
  ;; placeless fact: anyone may leave food in it and anyone may take from it,
  ;; unsupervised by the person who put it there. Declaring it on the container
  ;; spec means the store stage trips `public-fridge`, and Berlin answers with the
  ;; Verteilstation rules (contexts/de.sexp) — registration with the Bezirk, an
  ;; annual LMHV hygiene training, standing supervision, the documentation folder,
  ;; the notices and the recall duty. None of which is named here.
  ($ rs 'add-resource-spec
     (make-resource-specification #:id "spec-bfs-kuehlraum" #:name "Kühlraum (m³·h)"
                                  #:resource-classified-as '("kit" "crossing:public-fridge") #:default-unit-of-resource "m3h" #:keep-in-place #t)))

;;; ─── the whole thing on a live scope ──────────────────────────────────────
;;; The twin of seed-berlin-commune!: the chain, the means the commune HOLDS
;;; (cold room, Lastenrad, hands), the surplus a Betrieb sets out, and the place
;;; they all sit at — everything the live convex solve needs, nothing more.
;;; Labour note: `helpers` × `hours-per-day` on `days` IS the labour supply, because
;;; the engine sizes a person's hours from their availability window. At the chain's
;;; intensity (1.475 Foodsaver-hours per 90 kg delivered ⇒ ~61 kg per hour) one
;;; helper on a 12-hour Monday tops out around 732 kg in that period.
(define* (seed-berlin-food-scope! scope #:key (public-handout? #f)
                                              (place "berlin") (parent #f)
                                              (id "recipe-berlin-food-chain")
                                              (kuehlraum-m3h 200.0) (bikes 1.0)
                                              (helpers 1) (hours-per-day 12.0)
                                              (ueberschuss-kg 400.0)
                                              (commune-name "Kiezküche")
                                              (helper-name "Helferin")
                                              (kit-sets 4)
                                              (days '(monday)))
  (let* ((rs ($ scope 'recipe-store)) (obs ($ scope 'observer))
         (sts ($ scope 'spatial-thing-store)) (as ($ scope 'agent-store))
         (commune (string-append "commune-" place))
         ;; LABOUR SUPPLY COMES FROM THE WINDOW, not from a seeded quantity: the
         ;; engine reads each agent's availability window (agent-window-hours) to
         ;; size their hours per period. So the knobs that actually move the plan
         ;; are HOW MANY helpers and HOW LONG their window is — `helpers` ×
         ;; `hours-per-day` on the collection `days`. The skill resource below is
         ;; sized to match, so the two never disagree.
         (helper-ids (map (lambda (i) (format #f "helfer-~a-~a" place i)) (iota helpers)))
         (helfer-hours (* helpers hours-per-day))
         (win (make-availability-window #f #f
                (list (make-day-schedule days
                        (list (make-time-range "00:00"
                                (format #f "~2,'0d:00" (inexact->exact (round hours-per-day)))))))
                #f)))
    (seed-berlin-food-recipe! rs #:public-handout? public-handout? #:id id)
    ;; …and the kit's OWN specs. The chain registers that a means exists; what it
    ;; is counted in belongs to whoever owns it, and the commune owns the kit. Left
    ;; unsaid, four holdings sit in the catalogue with no denomination — which the
    ;; capacity conversion cannot ask about and would silently guess.
    (seed-foodsharing-kit-specs! rs)
    ;; and the Lastenrad's, from the shed that owns the definition: a cargo bike is
    ;; counted in bikes, and this scope holds one. Importing the declaration is what
    ;; keeps one spec id meaning one thing across every scope that touches it.
    (seed-berlin-transit-specs rs)
    ($ sts 'add-location (make-spatial-thing #:id place #:name "Berlin" #:lat 52.52 #:long 13.40
                                             #:contained-in parent))
    ($ as 'add-agent (make-agent #:id commune #:type 'organization #:name commune-name
                                 #:primary-location place #:classified-as '()))
    (for-each (lambda (h) ($ as 'add-agent (make-agent #:id h #:type 'person #:name helper-name
                                                       #:primary-location place #:classified-as '()
                                                       #:availability-window win)))
              helper-ids)
    (for-each
     (lambda (row)
       (apply (lambda (rid label spec qty unit holder)
                ($ obs 'record-resource
                   (make-economic-resource #:id rid #:name label #:conforms-to spec #:classified-as '()
                     #:accounting-quantity (make-measure qty unit) #:onhand-quantity (make-measure qty unit)
                     #:current-location place #:primary-accountable holder)))
              row))
     `(("bfs-kuehlraum"   "Kühlraum der Kiezküche" "spec-bfs-kuehlraum"   ,kuehlraum-m3h "m3h"   ,commune)
       ("bfs-lastenrad"   "Lastenrad"                    "spec-bt-cargo-bike"   ,bikes         "each"  ,commune)
       ("bfs-ueberschuss" "Überschuss vom Betrieb"       "spec-bfs-ueberschuss" ,ueberschuss-kg "kg"   ,commune)
       ,@(map (lambda (h) `(,(string-append "bfs-" h) "Foodsaver-Stunden"
                            ,(foodsaver-skill) ,hours-per-day "hours" ,h))
              helper-ids)))
    ;; the shared kit — one set per simultaneous pickup, held by the commune
    (seed-foodsharing-kit! obs #:place place #:holder commune #:sets kit-sets)
    place))
