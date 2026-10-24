;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; berlin-flotte.scm — fLotte Berlin as DATA over the Lastenrad mechanism that
;;; berlin-transit.scm already carries.
;;;
;;; fLotte is a free cargo-bike lending network: you register on the platform,
;;; book a bike for one to three consecutive days, and ride it away at no charge
;;; (donation basis). The bikes stand at host locations — libraries, Kiez shops,
;;; Bezirksämter — across all twelve districts.
;;;
;;; THE STRUCTURE IS ALREADY THERE, and it is the point: a fLotte bike is CUSTODY
;;; WITHOUT RIGHTS. `bt-cargo-bike-resource #:loaned? #t` puts fLotte in
;;; primary-accountable and the borrowing scope in custodian-scope, which is
;;; exactly what `resource-rented?` (schemas.scm) tests for — so a plan that leans
;;; on borrowed bikes shows up in the frag wheel's RENTED sector with no new
;;; machinery, and a plan that leans on ONE lender is visibly more exposed than
;;; one spread across lenders. This file adds the real lender, the real counts,
;;; and the loan's real time bound. Nothing else.
;;;
;;; The payload the solver needs is already on the spec: `spec-bt-cargo-bike`
;;; carries "vf:payload-kg:100", which is why the Berlin food chain runs a 100 kg
;;; batch (berlin-food-seed.scm) — one Lastenrad load, not one van load.
;;;
;;; ── PROVENANCE ───────────────────────────────────────────────────────────
;;; [DATA]  Over 240 bikes across all 12 Bezirke, of which ~150 (Stand Dec 2025)
;;;   come through `fLotte kommunal`, funded by the Senat and the Bezirksämter;
;;;   the bikes stand at nearly 280 locations. Booking runs 1–3 consecutive days.
;;;   Source: flotte-berlin.de (Standorte, Lastenrad ausleihen, kommunal).
;;; [GAP]   The per-Bezirk split and the per-station roster are NOT vendored here.
;;;   The platform publishes the station map; an ingest that lands those makes
;;;   `flotte-berlin-resources` take a real roster instead of a count. Until then
;;;   a caller states how many bikes its Kiez can actually reach, and says so.

;;; ─── the lender, and what it lends ────────────────────────────────────────
;;; One id for the whole network. A Bezirk running its own `fLotte kommunal`
;;; sub-pool is a DIFFERENT lender id — which is the honest modelling, because a
;;; Bezirk can withdraw its own bikes without the network withdrawing anything.
(define-module (localchimera knowledge recipes berlin-flotte)
  #:use-module (localchimera vf schemas)
  #:use-module (localchimera vf beyond schedules)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera knowledge recipes berlin-transit)
  #:use-module ((localchimera knowledge recipes transit-shed) #:select (vehicle-resource))
  #:export (%flotte-lender flotte-kommunal-lender *flotte-total-bikes*
            *flotte-kommunal-bikes* *flotte-stations* *flotte-max-loan-days*
            flotte-loan-window flotte-berlin-resources flotte-spread-resources))

(define %flotte-lender "org:flotte-berlin")
(define (flotte-kommunal-lender bezirk)
  (string-append "org:flotte-kommunal:" bezirk))

;; [DATA] the network as a whole, for a steward to size a Kiez against.
(define *flotte-total-bikes*    240)   ; "über 240", all 12 Bezirke
(define *flotte-kommunal-bikes* 150)   ; of those, Senat/Bezirk-funded (Dec 2025)
(define *flotte-stations*       280)   ; "fast 280 Standorte"
(define *flotte-max-loan-days*    3)   ; 1–3 consecutive days per booking

;;; ─── the loan's time bound, as an availability window ─────────────────────
;;; A booking is days, not hours: the bike is yours from pickup until you bring
;;; it back, up to three consecutive days. Modelled as full-day availability on
;;; the booked days, so the solve can place a pickup anywhere inside the loan and
;;; cannot place one outside it.
(define* (flotte-loan-window #:optional (days '(monday tuesday wednesday)))
  (make-availability-window #f #f
    (list (make-day-schedule days (list (make-time-range "00:00" "24:00")))) #f))

;;; ─── the bikes a scope can actually reach ─────────────────────────────────
;;; COUNT is what this Kiez can book, not what Berlin owns — a plan should lean
;;; on bikes someone has actually checked are reachable. AT is the place they are
;;; picked up from. BEZIRK, when given, attributes them to that district's
;;; `fLotte kommunal` sub-pool, so a district withdrawing its funding is a
;;; recall this plan can be tested against.
(define* (flotte-berlin-resources scope #:key (count 1) (at #f) (bezirk #f)
                                              (days '(monday tuesday wednesday))
                                              (id-prefix "res-flotte-"))
  "The fLotte bikes SCOPE has custody of: borrowed, never owned. Feed the result
   to rented-goods for the frag wheel's rented sector."
  (let ((lender (if bezirk (flotte-kommunal-lender bezirk) %flotte-lender))
        (window (flotte-loan-window days)))
    (map (lambda (i)
           ;; a Lastenrad in the lender's free-loan pool, bookable on the loan window's days
           (copy-economic-resource
            (vehicle-resource (string-append id-prefix (number->string i))
                              "spec-bt-cargo-bike" scope #:lender lender #:at at)
            #:availability-window window))
         (iota count))))

;;; ─── the whole Berlin loan pool, spread across its lenders ────────────────
;;; The diversification case in one call: the same total count, drawn from
;;; several districts' sub-pools rather than one. A robust solve over recall
;;; futures prefers this shape for the same reason the festival plan spreads over
;;; twelve Bezirke — defending the floor under revocable permission.
(define* (flotte-spread-resources scope bezirke #:key (per-bezirk 1) (at #f)
                                                     (days '(monday tuesday wednesday)))
  (append-map
   (lambda (b)
     (flotte-berlin-resources scope #:count per-bezirk #:at at #:bezirk b #:days days
                              #:id-prefix (string-append "res-flotte-" b "-")))
   bezirke))
