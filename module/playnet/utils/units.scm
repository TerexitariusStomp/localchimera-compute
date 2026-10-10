;;; units.scm — GNU Units integration for metabolic accounting
;;;
;;; Provides unit conversion and substance classification for the
;;; two coupled metabolisms (labour SNLT + material substance).
;;;
;;; Primary path: shell out to GNU Units (`units --terse`) for
;;; arbitrary unit conversion. Falls back to curated tables when
;;; the `units` command is unavailable.
;;;
;;; API:
;;;   (unit->substance unit-string)       → symbol | 'other | 'rate
;;;   (substance-base-unit substance)     → symbol
;;;   (convert-unit qty unit-string)      → number (in base units)
;;;   (units-convert have want)           → number | #f
;;;   (unit-factor from to)               → how many TO one FROM is | #f (unlike substances)
;;;   %placeholder-unit                   → the unit a row carries until its door states the spec's own
;;;   %count-unit, %effort-unit           → "each", "hours": the unit a count and an effort are written in
;;;   (count-unit? unit)                  → #t when UNIT counts (each, one, a run) or names none
;;;   (hours-in qty unit)                 → QTY of a time UNIT as hours
;;;   (time-unit? unit)                   → #t when UNIT measures time
;;;   (unit-measurable-substance unit)    → the substance a known unit adds up in | #f

(define-module (playnet utils units)
  #:use-module (srfi srfi-1)
  #:export (unit->substance
            substance-base-unit
            convert-unit
            units-convert unit-to unit-factor hours-in time-unit? placeholder-unit? %placeholder-unit unit-measurable-substance
            %count-unit %effort-unit count-unit? %time-unit-names
            unit-known? convert-unit/strict
            unit-rate-parts unit-rate?
            units-available?
            %intensive-units))

;; An INTENSIVE unit states a condition of a thing (its temperature, its
;; moisture), and the extensive quantity that carries it:
;; intensive unit → (substance extensive-unit kind).
(define %intensive-units
  '(("degC"         . (heat  "kWh" temperature))
    ("°C"           . (heat  "kWh" temperature))
    ("%moisture"    . (water "kg"  moisture))        ; wet basis unless said
    ("%moisture-dry" . (water "kg" moisture-dry))))

;; GNU Units is a subprocess: a browser (Hoot) has none, and convert-unit then
;; reads only the curated tables below, which is what it already did whenever
;; `units` was not installed.
(cond-expand
 (guile
  (use-modules (ice-9 popen) (ice-9 rdelim))
  (define %definitions-path
    ;; (current-filename) is #f when this module is loaded via
    ;; primitive-load-path / -L (the test-suite + Guix package builds both
    ;; hit that path). Fall back to %load-path lookup.
    (or (and=> (current-filename)
               (lambda (f) (string-append (dirname f) "/definitions.units")))
        (search-path %load-path "playnet/utils/definitions.units")))

  (define %units-cache (make-hash-table 2000))

  ;; Where GNU units is, found ONCE and on first use. The gateway's box has none, and
  ;; a conversion used to ask the operating system for it every time: a failed fork
  ;; and a line on stderr per conversion (sixty at every boot), burying the log's
  ;; real warnings. The answer is kept in a table, not a `set!` global: a global
  ;; written after load can be folded to its first value by another module's
  ;; inlining.
  (define %units-state (make-hash-table 2))

  (define (units-program)
    "The GNU units executable on PATH, or #f where there is none (the curated
     tables below answer there, to six significant digits)."
    (let ((known (hash-ref %units-state 'program 'unknown)))
      (if (eq? known 'unknown)
          (let ((found (search-path (filter (lambda (d) (not (string-null? d)))
                                            (string-split (or (getenv "PATH") "") #\:))
                                    "units")))
            (hash-set! %units-state 'program found)
            found)
          known)))

  (define (units-available?) (and (units-program) #t))

  (define (units-convert have want)
    "Convert between units using GNU Units. Returns numeric factor or #f.
     Shells out: units --terse -o %.15g -f DEFINITIONS_PATH HAVE WANT, at the
     precision of a double (the program's default is eight digits, which makes
     ninety minutes an hour and a half only to the eighth place)."
    (let ((cache-key (string-append have "\0" want)))
      (or (hash-ref %units-cache cache-key #f)
          (and (units-program)
            (catch #t
              (lambda ()
                (let* ((port (open-pipe*
                              OPEN_READ
                              (units-program) "--terse" "-o" "%.15g" "-f" %definitions-path
                              have want))
                       (line (read-line port))
                       (exit-val (close-pipe port)))
                  (if (and (eq? exit-val 0) line (not (string=? line "")))
                      (let ((n (string->number line)))
                        (when n (hash-set! %units-cache cache-key n))
                        n)
                      #f)))
              (lambda _ #f))))))
  )
 (else
  (define (units-available?) #f)
  (define (units-convert have want) #f)))

(define *substance-categories*
  '((mass
     (kg . mass) (g . mass) (t . mass) (tonne . mass) (ton . mass)
     (lb . mass) (lbs . mass) (oz . mass))
    (volume
     (l . volume) (liter . volume) (liters . volume)
     (litre . volume) (litres . volume)
     (ml . volume) (mL . volume)
     (m3 . volume) (m³ . volume) (cu-m . volume)
     (gal . volume) (gallon . volume) (gallons . volume))
    (energy
     (j . energy) (J . energy) (kj . energy) (kJ . energy)
     (mj . energy) (MJ . energy)
     (gj . energy) (GJ . energy)
     (kwh . energy) (kWh . energy) (mwh . energy) (MWh . energy)
     (btu . energy) (BTU . energy) (therm . energy))
    (emission
     (tCO2e . emission) (tco2e . emission)
     (kgCO2e . emission) (kgco2e . emission)
     (co2e . emission) (CO2e . emission))
    (water
     (m3-water . water) (m³-water . water)
     (l-water . water) (gal-water . water))
    (nitrogen
     (kg-N . nitrogen) (kgN . nitrogen) (kg-n . nitrogen)
     (t-N . nitrogen) (tN . nitrogen))
    (phosphorus
     (kg-P . phosphorus) (kgP . phosphorus) (kg-p . phosphorus)
     (t-P . phosphorus) (tP . phosphorus))
    (land
     (ha . land) (hectare . land) (hectares . land)
     (m2 . land) (m² . land) (sq-m . land)
     (acre . land) (acres . land))
    (time
     (second . time) (seconds . time) (sec . time) (s . time)
     (minute . time) (minutes . time) (min . time)
     (hour . time) (hours . time) (h . time) (hr . time) (hrs . time)
     (day . time) (days . time) (d . time)
     (week . time) (weeks . time) (wk . time)
     (fortnight . time) (fortnights . time)
     (month . time) (months . time)
     (quarter . time) (quarters . time)
     (year . time) (years . time) (yr . time) (yrs . time))))

;; ── DIVISION UNITS: a rate is one unit, written as a quotient ────────────────
;; OM2 — the vocabulary ValueFlows takes its units from
;; (docs/valueflows/specification/external-terms.md) — builds a derived unit as a
;; UnitDivision over a numerator and a denominator, which is how it says
;; `kilometrePerHour`. So `hours/week` is a single unit and belongs in the one
;; slot a Measure has for what its number is measured in, rather than in a second
;; field beside it: `vf:Unit` is `{omUnitIdentifier, label, symbol}`, an opaque
;; handle whose whole structure lives in OM2.
;;
;; This matters beyond tidiness, because a CAPACITY is a rate. `200 seat-hours` is
;; not a quantity anybody can spend until it says per what — and a quantity of
;; time with no denominator is the one shape that cannot be read at all, since
;; multiplying it by the hours a period offers counts that length twice.
(define (unit-rate-parts unit)
  "The (NUMERATOR . DENOMINATOR) of a quotient unit — (\"hours\" . \"week\") for
   \"hours/week\" — or #f for a simple one. One solidus, no exponents: enough for
   a rate, and everything past it is GNU Units' job (`units-convert`)."
  (and (string? unit)
       (let ((i (string-index unit #\/)))
         (and i (> i 0) (< (+ i 1) (string-length unit))
              (let ((num (string-trim-both (substring unit 0 i)))
                    (den (string-trim-both (substring unit (+ i 1)))))
                (and (> (string-length num) 0) (> (string-length den) 0)
                     (not (string-index den #\/))
                     (cons num den)))))))
(define (unit-rate? unit) (and (unit-rate-parts unit) #t))

(define (unit->substance unit)
  "Map a unit string to its substance category symbol.
   Returns 'time for temporal units, 'rate for a quotient unit (a ratio is not a
   substance — `hours/week` measures no stock of anything), 'other otherwise."
  (cond
   ((not (string? unit)) 'other)
   ((unit-rate? unit) 'rate)
   (else
    (let ((unit-sym (string->symbol unit)))
      (or (any (lambda (cat-pair)
                 (let ((cat (car cat-pair))
                       (units (cdr cat-pair)))
                   (and (assq unit-sym units) cat)))
               *substance-categories*)
          'other)))))

(define (substance-base-unit substance)
  "Return the canonical base unit symbol for a substance category."
  (case substance
    ((mass) 'kg)
    ((volume) 'l)
    ((energy) 'MJ)
    ((emission) 'tCO2e)
    ((water) 'm³)
    ((nitrogen) 'kg-N)
    ((phosphorus) 'kg-P)
    ((land) 'ha)
    ((time) 'hours)
    (else 'each)))

(define *unit->base*
  '((kg . 1) (g . 0.001) (t . 1000) (tonne . 1000) (ton . 907.185)
    (lb . 0.453592) (lbs . 0.453592) (oz . 0.0283495)
    (l . 1) (liter . 1) (liters . 1) (litre . 1) (litres . 1)
    (ml . 0.001) (mL . 0.001)
    (m3 . 1000) (m³ . 1000) (cu-m . 1000)
    (gal . 3.78541) (gallon . 3.78541) (gallons . 3.78541)
    (j . 0.000001) (J . 0.000001)
    (kj . 0.001) (kJ . 0.001)
    (mj . 1) (MJ . 1)
    (gj . 1000) (GJ . 1000)
    (kwh . 3.6) (kWh . 3.6)
    (mwh . 3600) (MWh . 3600)
    (btu . 0.001055) (BTU . 0.001055)
    (therm . 105.5)
    (tCO2e . 1) (tco2e . 1) (kgCO2e . 0.001) (kgco2e . 0.001)
    (m3-water . 1) (m³-water . 1) (l-water . 0.001) (gal-water . 0.00378541)
    (kg-N . 1) (kgN . 1) (kg-n . 1) (t-N . 1000) (tN . 1000)
    (kg-P . 1) (kgP . 1) (kg-p . 1) (t-P . 1000) (tP . 1000)
    (ha . 1) (hectare . 1) (hectares . 1)
    (m2 . 0.0001) (m² . 0.0001) (sq-m . 0.0001)
    (acre . 0.404686) (acres . 0.404686)
    ;; ── time, in HOURS ────────────────────────────────────────────────────
    ;; The base for time is the hour, and every capacity on the lattice is
    ;; denominated in it (playnet.typ: a period is a length of time). So the
    ;; table has to cover the units a scope will actually plan in — a season,
    ;; a year — rather than stopping at the week and returning the quantity
    ;; unchanged, which reads a year as one hour.
    ;;
    ;; A month and a year are not exact multiples of a day, and the convention
    ;; here is the Julian year (365.25 d) with the month as a twelfth of it.
    ;; That is a CHOICE, and it is the right kind of small: a plan whose period
    ;; is "a month" is already saying it does not care about the difference
    ;; between February and March. Anything needing calendar exactness sets a
    ;; period SPAN (concrete dates) instead, which is measured, not converted.
    ;; a ledger counts time in hours and compares it to what a commitment holds, so
    ;; a second and a minute carry every digit a double has (90 minutes ARE 1.5 hours)
    (second . 0.0002777777777777778) (seconds . 0.0002777777777777778) (sec . 0.0002777777777777778) (s . 0.0002777777777777778)
    (minute . 0.016666666666666666) (minutes . 0.016666666666666666) (min . 0.016666666666666666)
    (hour . 1) (hours . 1) (h . 1) (hr . 1) (hrs . 1)
    (day . 24) (days . 24) (d . 24)
    (week . 168) (weeks . 168) (wk . 168)
    (fortnight . 336) (fortnights . 336)
    (month . 730.5) (months . 730.5)
    (quarter . 2191.5) (quarters . 2191.5)
    (year . 8766) (years . 8766) (yr . 8766) (yrs . 8766)))

(define (convert-unit qty unit)
  "Convert quantity to base units for its substance category.
   Tries GNU Units first (handles any unit in definitions.units).
   Falls back to curated *unit->base* table.

   An unrecognised unit returns QTY UNCHANGED. That is deliberate for the
   metabolic accounting this was written for — an unknown unit is passed
   through rather than dropped — but it means the result is only as
   trustworthy as `unit-known?` says it is: `1 year` came back as `1` for as
   long as the table stopped at the week. Any caller for whom a wrong number
   is worse than no number should ask first, or use `convert-unit/strict`."
  (let ((rate (unit-rate-parts unit)))
    (if rate
        ;; a quotient converts as a quotient: each side to its own base, then
        ;; divide. `200 hours/week` is 200/168 hours per hour — the utilisation
        ;; the number actually states — and `kg/ha` is already based on both
        ;; sides, so it comes back unchanged. GNU Units is skipped here because
        ;; it declines a conversion between a rate and a simple base, which is
        ;; the right answer to the wrong question.
        (let ((num (convert-unit qty (car rate)))
              (den (convert-unit 1.0 (cdr rate))))
          (if (and (number? num) (number? den) (not (zero? den))) (/ num den) qty))
        (let* ((substance (unit->substance unit))
               (base (symbol->string (substance-base-unit substance))))
          (cond
           ((string=? unit base) qty)
           ((units-convert unit base) => (lambda (factor) (* qty factor)))
           (else
            (let ((factor (assq-ref *unit->base* (string->symbol unit))))
              (if factor (* qty factor) qty))))))))

(define (unit-measurable-substance unit)
  "The substance UNIT measures when it is a known unit of one that adds up (mass,
   volume, time, energy…), else #f: a count, a name the tables do not know and a
   rate are measurable in nothing."
  (and (string? unit) (unit-known? unit)
       (let ((substance (unit->substance unit)))
         (and (not (memq substance '(other rate))) substance))))

(define (unit-to unit want)
  "How many WANT one UNIT is, or #f when the two do not convert: GNU Units where
   it is present, else the curated table. Two units of one substance convert
   through that substance's base unit (a minute in hours, a pound in grams). A
   conversion that fails classifies — a unit is a mass because it converts to
   kilograms — which is how the chemistry layer reads every unit."
  (and (string? unit) (string? want)
       (or (and (string=? unit want) 1.0)
           (units-convert unit want)
           (let ((substance (unit-measurable-substance unit)))
             (and substance
                  (eq? substance (unit-measurable-substance want))
                  (exact->inexact (/ (convert-unit 1 unit) (convert-unit 1 want))))))))

(define %placeholder-unit "unit")   ; the unit a row carries until its door states the specification's own
(define (placeholder-unit? u) (or (not u) (equal? u %placeholder-unit)))

;; The two units the planner writes of its own accord: a count of a thing and an
;; effort in time. Every site that mints a measure for one spells the constant, so
;; the spelling stands once, and every reader that asks "is this a count?" asks
;; count-unit? (a run is a count of runs; a unit nothing states is a count).
(define %count-unit  "each")
(define %effort-unit "hours")
(define (count-unit? u) (or (not u) (and (member u '("each" "one" "run" "runs")) #t)))
(define (unit-factor from to)
  "How many TO one FROM is, or #f when the two measure different substances. A
   count or a name the tables do not know (\"each\", \"loaf\") and the placeholder
   \"unit\" the plan's rows carry until its doors state the specification's own
   unit read as TO: the one rule by which a quantity is stated in the unit a stock
   is counted in."
  (cond ((or (placeholder-unit? from) (placeholder-unit? to) (equal? from to)) 1)
        ((unit-to from to))
        ((and (unit-measurable-substance from) (unit-measurable-substance to)) #f)
        (else 1)))

;; Every spelling of a unit of time the tables know — what the page is handed
;; (tools/units-emit.scm → ui/app/units-catalogue.ts) so it asks the same question.
(define %time-unit-names
  (map (lambda (p) (symbol->string (car p))) (assq-ref *substance-categories* 'time)))

(define (time-unit? unit)
  "UNIT measures time: a duration is stated in one."
  (eq? (unit->substance unit) 'time))
(define (hours-in qty unit)
  "QTY of UNIT as hours: a ledger counts time in one. A unit that is no time reads as
   hours already (the placeholder a plan's rows carry)."
  (* qty (or (unit-factor unit "hours") 1)))

(define (unit-known? unit)
  "Can UNIT be converted to its category's base? A unit this answers #f for is
   one `convert-unit` will pass through unchanged."
  (and (string? unit)
       (let ((rate (unit-rate-parts unit)))
         (if rate
             ;; a quotient is known when both of its sides are — the same rule
             ;; that makes it convertible
             (and (unit-known? (car rate)) (unit-known? (cdr rate)))
             (let* ((substance (unit->substance unit))
                    (base (symbol->string (substance-base-unit substance))))
               (or (string=? unit base)
                   (and (assq-ref *unit->base* (string->symbol unit)) #t)
                   (and (units-convert unit base) #t)))))))

(define* (convert-unit/strict qty unit #:key (what "quantity"))
  "convert-unit, but an unconvertible unit is an ERROR rather than a number that
   looks fine. For the places where a silently unconverted quantity would be
   read as an answer — a period's length, a capacity — rather than carried."
  (unless (unit-known? unit)
    (error (string-append "unknown unit for " what ":") unit))
  (convert-unit qty unit))
