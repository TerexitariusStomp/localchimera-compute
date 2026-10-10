;;; observation/convert.scm — a reading is a count of a stock; the door converts.
;;;
;;; docs/observation/readings-are-counts.md: the reading fold's cells are
;;; EXTENSIVE and add across scopes, so an intensive number (degrees, percent)
;;; never enters it. This module is the one conversion, applied at a door
;;; before an event is made: an intensive measure of a form becomes a count
;;; of a substance stock the form holds, or refuses. The physics it rests on
;;; is §1.5 of that document, one procedure per fact:
;;;
;;;   reading->count   degrees less ambient, times mass times specific heat →
;;;                    kWh of heat EXCESS over the surroundings (fact 1, 3);
;;;                    percent moisture times mass → kg of water, wet or dry
;;;                    basis (fact 1)
;;;   count->reading   the inverse, what a dashboard shows of a cell
;;;   time-constant, hold-cost, carry-fraction — the relaxation physics (facts 2
;;;                    and 6), defined once in knowledge/catalogues/substances.scm beside the
;;;                    half-life it shares an exponential with, re-exported here
;;;   latent-heat      kWh per kg at a phase change (fact 4); the drying floor
;;;
;;; A refusal is a pair (refused . reason), never a number, so a caller that
;;; multiplies it raises at once (parts.scm's `nothing` rule). Units: mass in
;;; kg, specific heat in kJ/(kg·K), conductance U·A in kW/K, temperature in
;;; degrees Celsius, energy in kWh, time in hours. 1 kWh = 3600 kJ.

(define-module (playnet observation convert)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet knowledge catalogues substances) #:select (latent-heat-kwh-per-kg %kj-per-kwh time-constant hold-cost carry-fraction))
  #:use-module ((playnet utils units) #:select (%intensive-units))   ; which units state a condition, and what carries it
  #:export (%latent-changes
            reading->count count->reading refused?
            latent-heat drying-energy-floor)
  #:re-export (%intensive-units time-constant hold-cost carry-fraction))   ; the one exponential lives with the physics tables


;; The phase changes of water a reading may name. Each one's latent heat is DERIVED
;; from the chemistry table's formation enthalpies (catalogues/substances.scm): evaporation
;; ΔHf(vapour) − ΔHf(liquid), 2444 kJ/kg at 25 °C (the boiling-point value is 2260);
;; fusion ΔHf(liquid) − ΔHf(ice), 334 kJ/kg.
(define %latent-changes '(fusion evaporation))

(define (refused reason . args) (cons 'refused (apply format #f reason args)))
(define (refused? x) (and (pair? x) (eq? (car x) 'refused)))

(define (latent-heat change)
  "kWh per kilogram of water at CHANGE ('fusion or 'evaporation)."
  (if (memq change %latent-changes)
      (latent-heat-kwh-per-kg change)
      (refused "no latent heat for ~a" change)))

(define (drying-energy-floor kg-water)
  "The least energy, kWh, a step removing KG-WATER by evaporation consumes."
  (* kg-water (latent-heat 'evaporation)))

(define* (reading->count value unit #:key mass specific-heat ambient)
  "An intensive reading VALUE in UNIT of a form of MASS kg → (substance count
   extensive-unit), or a refusal. Temperature needs SPECIFIC-HEAT (kJ/kg·K)
   and AMBIENT (°C): the count is the signed heat excess over ambient, kWh.
   Moisture needs MASS alone: percent of the wet mass, or of the dry mass
   for the dry-basis unit, as kilograms of water."
  (let ((row (assoc-ref %intensive-units unit)))
    (cond
     ((not row) (refused "~a is no intensive unit the table knows" unit))
     ((not (and (real? mass) (> mass 0))) (refused "a reading of a form needs its mass"))
     ((not (real? value)) (refused "a reading is a number"))
     (else
      (let ((substance (car row)) (ext (cadr row)) (kind (caddr row)))
        (case kind
          ((temperature)
           (cond ((not (and (real? specific-heat) (> specific-heat 0)))
                  (refused "a temperature needs the form's specific heat"))
                 ((not (real? ambient))
                  (refused "a temperature is read against an ambient"))
                 (else (list substance
                             (/ (* mass specific-heat (- value ambient)) %kj-per-kwh)
                             ext))))
          ((moisture)      (list substance (* mass (/ value 100.0)) ext))
          ((moisture-dry)  (let ((r (/ value 100.0)))              ; w = m·r/(1+r)
                             (list substance (* mass (/ r (+ 1.0 r))) ext)))
          (else (refused "no conversion for ~a" kind))))))))

(define* (count->reading substance count unit #:key mass specific-heat ambient)
  "The inverse of reading->count: a stock COUNT of SUBSTANCE shown as the
   intensive reading in UNIT, or a refusal."
  (let ((row (assoc-ref %intensive-units unit)))
    (cond
     ((not row) (refused "~a is no intensive unit the table knows" unit))
     ((not (eq? (car row) substance)) (refused "~a is read in ~a, never ~a" (car row) unit substance))
     ((not (and (real? mass) (> mass 0))) (refused "a reading of a form needs its mass"))
     (else
      (case (caddr row)
        ((temperature)
         (if (and (real? specific-heat) (> specific-heat 0) (real? ambient))
             (+ ambient (/ (* count %kj-per-kwh) (* mass specific-heat)))
             (refused "a temperature needs specific heat and ambient")))
        ((moisture)     (* 100.0 (/ count mass)))
        ((moisture-dry) (* 100.0 (/ count (- mass count))))
        (else (refused "no conversion for ~a" (caddr row))))))))
