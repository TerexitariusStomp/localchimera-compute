#!/usr/bin/env -S guile -L module
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; tools/emit/physics-emit.scm — docs/observation/physics-register.md from the code
;;;
;;;   physics-emit.scm [out]      the register's tables, read off the chemistry layer
;;;
;;; docs/observation/physics.md is the prose of every law the planner holds; the
;;; tables it rests on are DATA in knowledge/catalogues/substances.scm: the conserved leaves
;;; and their laws, the heat carriers and the entropy each carries, the nuclear
;;; channels with their half-lives, the constants. This emit writes them as
;;; Markdown, once, from the same bindings the solve and the lint read, and
;;; `make check-physics-fresh` regenerates and diffs the committed copy — the
;;; gate seam-wire.ts and nutrition-catalogue.ts already have. The register is
;;; then a reading of the code, never a restatement of it.
(use-modules (localchimera knowledge catalogues substances)
             ((localchimera solve engine) #:select (*climb-per-km*))
             ((localchimera knowledge catalogues food-sources) #:select (*food-sources*))
             ((localchimera knowledge catalogues housing-substance) #:select (*dwelling-envelope*))
             (ice-9 format) (srfi srfi-1))

(define (row . cells) (string-append "| " (string-join (map (lambda (c) (format #f "~a" c)) cells) " | ") " |"))
(define (table header . rows)
  (string-join (cons* (apply row header)
                      (row-separator (length header))
                      rows)
               "\n"))
(define (row-separator n) (string-append "|" (string-join (make-list n "---") "|") "|"))
(define (num x) (if (and (number? x) (not (exact? x))) (format #f "~,6g" x) (format #f "~a" x)))

(define leaves
  (apply table '("Leaf" "Kind" "Unit" "Signed" "Law")
         (map (lambda (l) (row (car l) (cadr l) (caddr l) (if (cadddr l) "yes" "no") (list-ref l 4))) *leaves*)))

(define carriers
  (apply table '("Carrier" "Heat per kWh" "Entropy per kWh, kWh/K" "Reads as")
         (map (lambda (r)
                (let ((e (assoc-ref (cdr r) "entropy")))
                  (row (car r) (num (assoc-ref (cdr r) "heat")) (num e)
                       (cond ((zero? e) "work") ((< (abs (- e (/ 1.0 %ambient-kelvin))) 1e-12) "heat at ambient, T₀") (else "radiation, 1/T_sun")))))
              *heat-carrier-rows*)))

(define channels
  (apply table '("Reactants" "Products" "Kind" "Half-life, years")
         (map (lambda (c) (row (string-join (car c) " + ") (string-join (cadr c) " + ") (caddr c)
                               (if (cadddr c) (num (cadddr c)) "induced")))
              *channels*)))

(define molecules
  (apply table '("Species" "Formula" "ΔHf, kJ/mol" "S°, J/(mol·K)")
         (map (lambda (m) (let ((id (car m)))
                            (row id (or (assoc-ref *formula* id) "") (or (assoc-ref *enthalpy* id) "") (or (assoc-ref *entropy* id) ""))))
              *molecules*)))

(define (pairs-table header alist)      ; a (name . figure) alist as a two-column table
  (apply table header (map (lambda (r) (row (car r) (num (cdr r)))) alist)))
(define ratings (pairs-table '("Means" "Rating, kW per unit") *power-ratings*))

(define foods
  (apply table '("Food" "C, kg/unit" "N" "Water" "ΔHf, kWh/unit" "S, kWh/(K·unit)")
         (filter-map (lambda (s)
                       (let ((id (car s)) (r (food-elements (car s))))
                         (and r (row id (num (or (assoc-ref r "C") 0)) (num (or (assoc-ref r "N") 0)) (num (or (assoc-ref r "h2o") 0))
                                    (num (enthalpy-per-kg id)) (num (entropy-per-kg id))))))
                     *food-sources*)))

(define densities
  (apply table '("Good" "Bulk density, kg/L" "A cubic metre holds, kg per day")
         (map (lambda (r) (row (car r) (num (cdr r)) (num (/ 24.0 (container-hours (car r) 1000.0))))) *density*)))

(define envelopes (pairs-table '("Dwelling type" "Envelope U·A, kW/K") *dwelling-envelope*))

(define constants
  (table '("Constant" "Value" "Binding")
         (row "Ambient T₀" (format #f "~a K" %ambient-kelvin) "`%ambient-kelvin`")
         (row "Sun" (format #f "~a K" %sun-kelvin) "`%sun-kelvin`")
         (row "kJ per kWh" (num %kj-per-kwh) "`%kj-per-kwh`")
         (row "Latent heat of evaporation, 25 °C" (format #f "~,4f kWh/kg, derived" (latent-heat-kwh-per-kg 'evaporation)) "`latent-heat-kwh-per-kg`")
         (row "Latent heat of fusion" (format #f "~,4f kWh/kg, derived" (latent-heat-kwh-per-kg 'fusion)) "`latent-heat-kwh-per-kg 'fusion`")
         (row "kWh per kcal" (format #f "~,4e, derived" %kwh-per-kcal) "`%kwh-per-kcal`")
         (row "Ambient flows" (string-join *boundary-carriers* ", ") "`*ambient-flows*` (engine.scm), read as `*boundary-carriers*`")
         (row "Climb per level kilometre" (string-join (map (lambda (r) (format #f "~a ~a m" (car r) (cdr r))) *climb-per-km*) ", ") "`*climb-per-km*` (engine.scm); the arc's climb as road")))

(define pathways
  (apply table '("Pathway" "Share of the light stored" "Litres transpired per kcal stored" "Crops named")
         (map (lambda (r) (row (symbol->string (car r)) (num (assq-ref (cdr r) 'share)) (num (assq-ref (cdr r) 'litres-per-kcal))
                               (let ((crops (filter-map (lambda (c) (and (eq? (cdr c) (car r)) (car c))) *crop-pathway*)))
                                 (if (null? crops) "every crop the table does not name" (string-join crops ", ")))))
              *pathways*)))

(define mixtures
  (apply table '("Form" "C" "H" "O" "N" "Water" "Gross heat, kJ/kg" "Formation, kWh/kg")
         (map (lambda (r) (let ((cells (cdr r)) (g (lambda (k) (or (assoc-ref (cdr r) k) 0))))
                            (row (car r) (num (g "C")) (num (g "H")) (num (g "O")) (num (g "N")) (num (g "h2o"))
                                 (if (assoc-ref cells "gross-kj") (num (assoc-ref cells "gross-kj")) "stated none")
                                 (let ((h (mixture-formation-kwh (car r)))) (if h (num h) "unread")))))
              *mixtures-hand*)))

(define precision                       ; how far a stated figure may stand from the thing, by where it came from
  (let ((leaves '("C" "H" "O" "N" "P" "K" "heat")))
    (apply table (cons "Source" leaves)
           (map (lambda (s) (apply row (symbol->string (car s))
                                   (map (lambda (l) (let ((v (assoc-ref (cdr s) l))) (if v (number->string v) "exact"))) leaves)))
                *precision*))))

(define gross-heats (pairs-table '("Macronutrient" "Gross heat of combustion, kJ/kg") %macro-gross-kj-per-kg))

(define doc
  (string-append
   "# The physics register, read off the code\n\n"
   "Generated by `tools/emit/physics-emit.scm` from `module/localchimera/knowledge/catalogues/substances.scm`;\n"
   "`make check-physics-fresh` refuses drift. The prose is `docs/observation/physics.md`.\n\n"
   "## Conserved leaves\n\n" leaves "\n\n"
   "## Heat carriers\n\n" carriers "\n\n"
   "## Molecules with stated enthalpy and entropy\n\n" molecules "\n\n"
   "## Foods, from the release\n\nPer kilogram of the food, off the pinned USDA rows (`food-elements`, `food-formation-kwh`, `food-entropy-kwh-per-k`): carbon, nitrogen and water (hydrogen and oxygen ride the same row); the formation enthalpy its macronutrients' gross heats of combustion return to (Merrill & Watt); the entropy at the run of organic solids and water. Eating breathes in oxygen and returns the nitrogen as urea and faeces, the undigested as faeces, the rest of the carbon as breath, the hydrogen and water as vapour, and exactly the metabolisable kilocalories less the vapour's latent heat as heat (`metabolic-flows`).\n\n" foods "\n\n"
   "## Mixtures stated by hand\n\nA form the release does not carry, said once as what a kilogram holds (`*mixtures-hand*`); its row, formation and entropy derive by the food's own route (`mixture-elements`, `mixture-formation-kwh`).\n\n" mixtures "\n\n"
   "## Gross heats of combustion\n\nWhat a calorimeter reads per macronutrient (`%macro-gross-kj-per-kg`); the catalogue's kilocalories are Atwater's metabolisable figure, smaller by what leaves undigested and as urea.\n\n" gross-heats "\n\n"
   "## Precision, by source\n\nHow far a stated figure may stand from the thing, as a share of the figure, per leaf (`*precision*`, `mixture-slack`): an element's is a share of the dry matter's figure, heat's a share of the gross heat of combustion, and water carries none. A row states its own under `±` where it knows better. The closure refuses a process only past what these explain (`process-creates`, `template-creates`).\n\n" precision "\n\n"
   "## Photosynthetic pathways\n\nEach pathway's two ceilings (`*pathways*`, `pathway-of`): a grow consumes at least its crop's light (`sunlight-for`) and transpires at least its water (`water-for`); a reading tightens either.\n\n" pathways "\n\n"
   "## Nuclear channels\n\n" channels "\n\n"
   "## Bulk densities\n\nA good counted by mass has a volume (`litres-per-unit`); a unit's share of a container is its litres over the container's, times the period's hours (`container-hours`), so the container's `use` is capacity by volume.\n\n" densities "\n\n"
   "## Rated means\n\nA means passes energy at its rating, E ≤ P·h (`rated-kw`); land's rating is the day's insolation over its hours, times the area.\n\n" ratings "\n\n"
   "## Dwelling envelopes\n\nA warm night draws U·A·ΔT over its hours as delivered heat (`night-heat-kwh`); the outdoors is the shed's record (`outdoor-degc`).\n\n" envelopes "\n\n"
   "## Constants\n\n" constants "\n"))

(define out (if (> (length (command-line)) 1) (cadr (command-line)) "docs/observation/physics-register.md"))
(call-with-output-file out (lambda (p) (display doc p)))
(format #t "physics-emit: ~a (~a leaves, ~a carriers, ~a channels)~%" out (length *leaves*) (length *heat-carrier-rows*) (length *channels*))
