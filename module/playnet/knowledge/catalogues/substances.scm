;;; knowledge/catalogues/substances.scm — substances as first-class ECONOMIC RESOURCES.
;;;
;;; Nutrients and molecules (carbon, nitrogen, CO₂, …) are ResourceSpecifications
;;; like any other resource, so they can be contained in products, produced and
;;; consumed by processes, held in the stockbook, and one day balanced by the
;;; planner. The bridge between a product and the substances inside it is one
;;; recursive relation, `contains` (mass fractions):
;;;
;;;   contains : spec-id → ((substance-spec-id . mass-fraction) …)
;;;     ("food" . (("C" . 0.12) ("N" . 0.026) …))   ; a product ⊂ its nutrients
;;;     ("co2"  . (("C" . 0.273)))                   ; a molecule ⊂ its elements
;;;     ("C"    . #f)                                 ; an element is a leaf
;;;
;;; A product flow of q units INDUCES a substance flow = q × (its elemental
;;; closure). Crucially this is uniform: feeding a PRODUCT spec auto-expands to
;;; its nutrients (pass-through), while a process that explicitly produces a
;;; SUBSTANCE spec — combustion emitting `co2`, composting releasing `N` — just
;;; appears as that substance directly (the transformation override). Because
;;; elements are conserved, what leaves a loop to a sink vs returns is the rift.
;;;
;;; This module is server-side (doors/service.scm). It hands out the substance
;;; ResourceSpecifications so a scope can register them, plus the pure closure
;;; the matter wire uses. Composition is authored per spec-id in `*contains*`.

(define-module (playnet knowledge catalogues substances)
  #:use-module ((playnet knowledge dsl shorthand) #:select (flow*))
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet knowledge catalogues food-sources)        ; *food-sources* *fdc-nutrients* *food-nutrition-hand*
  #:use-module (playnet knowledge data fdc-sr-legacy)  ; %fdc-slice — the pinned USDA rows
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet knowledge catalogues subsistence) #:select (subsistence-species-base sub-spec sub-unit))   ; the nutrient list is the catalogue's
  #:use-module ((playnet knowledge catalogues housing) #:select (*housing-standard*))   ; the housing rows are leaves of the one registry too
  #:use-module ((playnet vf facts boundary) #:select (*ambient-flows*))   ; the boundless ambient flows, stated once below the solve and the chemistry
  #:use-module ((playnet utils units) #:select (unit->substance convert-unit unit-to))   ; a row is per UNIT of the spec: area, mass and volume read off the one bridge
  #:re-export (food-macros)   ; the release's composition per kilogram, catalogues/food-sources.scm's, published here beside the chemistry it feeds
  #:export (*elements*
            *molecules*
            *contains*
            *nutrients*
            *nutrient-ids*
            *food-nutrition*
            nutrient-content menu-carries menu-starves water-form?
            %kwh-per-kcal food-energy-kwh food-energy-made sunlight-for
            %rain %air water-for water-drawn water-kept water-split oxygen-released leaf-made leaf-needed leaf-of flow-sum flow-made carbon-for heat-drawn
            *pathways* *crop-pathway* pathway-of pathway-stated? photosynthetic-share litres-per-kcal light-needed water-needed %macro-gross-kj-per-kg
            insolation-kwh-per-m2-day area-m2 kg-per-unit %sunlight balance-flows flow-action flow-spec flow-qty bare-flow bare-flows flow-in-basis side-quantities
            *power-ratings* rated-kw
            leaf-cover leaf-substitutes *boundary-carriers*
            nutrient-specs
            expand-nutrient-flows
            *atomic-weights* *periodic-table* atomic-number
            *formula* parse-formula
            *charge* *element-ids*
            *enthalpy* *energy-ids* *heat-carriers* *heat-carrier-rows* %delivered-heat *entropy* *entropy-ids* %ambient-kelvin %sun-kelvin
            *enthalpy-per-kg* *entropy-per-kg* food-elements food-formation-kwh food-entropy-kwh-per-k
            metabolic-outputs metabolic-flows atoms combustion-kj mixture-of macros->mixture *stated-forms* derived-table thermal-form-id thermal-base frame-of
            *mixtures-hand* mixture-elements mixture-formation-kwh mixture-entropy-kwh-per-k formation-kwh
            *density* density-of litres-per-unit litres-in-unit unit-scale container-hours
            %kj-per-kwh entropy-per-kg entropy-stated? second-law-production spec-exergy thermal-row closure-basis
            *nuclides* *nucleon-ids* nuclide? nuclide-a nuclide-z nuclide-l nuclide-mass nuclide-mass-nuclear nuclear-heat-per-mol
            *channels* channel-of decay-fraction nuclear-process-channel
            time-constant hold-cost carry-fraction
            base-at-ambient-row
            atomic-weight
            formula
            charge
            enthalpy enthalpy-per-kg latent-heat-kwh-per-kg thermal-form
            molar-mass
            reaction-basis
            balance-reaction balance-expression expression->flows
            reaction->flows
            *leaves* declare-leaf! leaf-ids signed-leaf? leaf-unit
            reaction->recipe-process
            reaction-network->records
            substance-specs
            substance-spec-ids
            substances->wire
            elemental
            substance-content
            closure-rows
            closure-flows
            closure-reduction
            closure-bands
            derive-contains
            check-conservation conservation-reading
            composition-system composition-known? composition-fraction
            composition-in-force composition-claims composition-superseded
            flow-basis-quantity recipe-flows->derivation derive-compositions composition-of-scope process-creates
            *precision* mixture-source mixture-slack form-slack slack-key slack-key? unread-key unread-key? heat-known? flows-in-spec-units
            flow-residual closed-composition composition-gaps
            composition-unit-gaps
            %environment-frag-weight environment-stock-frag
            *environment-specs*
            environment-spec? boundary-process?
            *composition-unstated*))

;;; ── the tracked ELEMENTS (the conserved display leaves), in stacking order ──
;; (id name colour). These are the bands the matter face colours by.
(define *elements*
  '(("C" "carbon"     "#6f6f6f")
    ("N" "nitrogen"   "#3a78c2")
    ("P" "phosphorus" "#d98a3a")
    ("K" "potassium"  "#7d57b0")
    ("H" "hydrogen"   "#b9c7d6")     ; water's and the fats' hydrogen: what burns to vapour
    ("O" "oxygen"     "#c9584a")))   ; the air's gift and the fire's price: breathed in, burned with

(define *element-ids* (map car *elements*))

;;; ── the periodic table (g/mol) — the single reference everything derives from.
;;; Molar mass, mass fractions, masses all compute from this; nothing is typed by
;;; hand. Add elements here as formulas need them.
;; ONE periodic table: symbol → (Z standard-atomic-weight). The weight is g/mol, #f
;; for an element with no standard weight (only radioactive isotopes). Formulas read
;; weights off it, nuclide ids read charges off it; a row is an element's two facts.
(define *periodic-table*
  '(("H" . (1 1.008)) ("He" . (2 4.0026)) ("C" . (6 12.011)) ("N" . (7 14.007)) ("O" . (8 15.999))
    ("Na" . (11 22.990)) ("Mg" . (12 24.305)) ("Al" . (13 26.982)) ("Si" . (14 28.085)) ("P" . (15 30.974))
    ("S" . (16 32.06)) ("Cl" . (17 35.45)) ("K" . (19 39.098)) ("Ca" . (20 40.078)) ("Fe" . (26 55.845))
    ("Kr" . (36 83.798)) ("Sr" . (38 87.62)) ("Y" . (39 88.906)) ("Cs" . (55 132.905)) ("Ba" . (56 137.327))
    ("Ra" . (88 #f)) ("Th" . (90 232.038)) ("Pa" . (91 231.036)) ("U" . (92 238.029)) ("Pu" . (94 #f))))
(define *atomic-weights*                  ; the weight column, for the readers that want an alist
  (filter-map (lambda (e) (and (cadr (cdr e)) (cons (car e) (cadr (cdr e))))) *periodic-table*))
(define (atomic-weight e)
  (let ((row (assoc-ref *periodic-table* e)))
    (cond ((not row) (error "unknown element" e))
          ((not (cadr row)) (error "no standard atomic weight: an element of isotopes alone" e))
          (else (cadr row)))))
(define (atomic-number e) (let ((row (assoc-ref *periodic-table* e))) (and row (car row))))

;;; ── MOLECULES by FORMULA (atom counts) — the mole/atom-exact layer. A molecule
;;; is its atoms; molar mass and element mass-fractions are DERIVED, not typed.
;;; This is what lets reactions BALANCE (integer atom conservation), not just be
;;; asserted. Products (mixtures) stay mass-composed in *contains* below.
(define *formula*
  '(("co2"     . "CO2")
    ("co"      . "CO")
    ("ch4"     . "CH4")
    ("nh3"     . "NH3")
    ("h2o"     . "H2O")
    ("h2o-g"   . "H2O")      ; the same molecule as vapour: its atoms are water's, its enthalpy is not
    ("h2o-s"   . "H2O")      ; and as ice
    ("o2"      . "O2")
    ("n2"      . "N2")
    ("glucose" . "C6H12O6")
    ("urea"    . "CH4N2O")                ; what a body's nitrogen leaves as
    ;; charged species (redox): an electron carries no atoms; ions carry their
    ;; atoms plus a charge in *charge* below.
    ("e-"      . "")
    ("Fe3+"    . "Fe")
    ("Fe2+"    . "Fe")
    ;; ── MATERIALS a recipe draws, by the formula of what they ARE ─────────────
    ;; A formula keyed by a SPEC id behaves exactly as one keyed by a molecule, and
    ;; that is the point: `elemental` prefers a formula over a mixture row, so these
    ;; specs get their element mass-fractions DERIVED from the periodic table rather
    ;; than typed. A number nobody typed is a number nobody can mistype.
    ;;
    ;; Where a material is a MIXTURE, the formula is its dominant component and the
    ;; approximation is named here rather than hidden in a fraction:
    ("spec-sp-hdpe"         . "C2H4")                 ; polyethylene, per repeat unit
    ("spec-sp-stearic-acid" . "C18H36O2")     ; octadecanoic acid
    ("spec-sp-quarry-fines" . "CaCO3")      ; limestone/marble ≡ CaCO₃
    ("spec-bn-kaolin"       . "Al2Si2O9H4")  ; kaolinite Al₂Si₂O₅(OH)₄ — carries NO tracked element
    ("spec-petrol"          . "C8H18")                ; octane, the conventional surrogate for motor petrol
    ("spec-bn-colophony"    . "C20H30O2")     ; abietic acid, the dominant resin acid of rosin
    ("spec-bn-beeswax"      . "C46H92O2")     ; myricyl palmitate, the dominant ester of beeswax
    ("spec-sp-biopolymer"   . "C3H4O2")        ; the PLA repeat unit, standing for the PBS/PLA-PBAT/PHA blend
    ("spec-hh-soap"         . "C18H35NaO2")     ; sodium stearate, the dominant soap salt
    ("spec-hh-paper"        . "C6H10O5")                 ; cellulose, per repeat unit
    ("spec-hh-glass"        . "SiO2")))                         ; silica — carries NO tracked element, and says so by deriving it
(define *molecules*
  '(("co2" "carbon dioxide") ("co" "carbon monoxide") ("ch4" "methane") ("nh3" "ammonia")
    ("h2o" "water") ("h2o-g" "water vapour") ("h2o-s" "ice") ("o2" "oxygen") ("n2" "nitrogen gas") ("glucose" "glucose") ("urea" "urea")))

;; CHARGE — the second conserved quantity (electrons aren't atoms). Default 0, so
;; every neutral molecule is untouched and no charge row appears unless an ion is
;; present. Energy is the third conserved quantity and lives in the LINEAR checks
;; below (a decimal row has no place in an integer equation): `*enthalpy*` gives
;; each molecule its standard enthalpy of formation, `elemental` carries it as the
;; leaf "heat", and the same residual that closes carbon closes energy. A NUCLEAR
;; set swaps the element rows for nucleon number and charge (`*nuclides*` below):
;; the null space balances a decay the same way, and the mass defect is the heat.
(define *charge*
  '(("e-" . -1) ("Fe3+" . 3) ("Fe2+" . 2) ("OH-" . -1) ("H+" . 1)))
(define (charge id) (or (assoc-ref *charge* id) 0))

;; ENERGY — the third conserved quantity (docs/observation/readings-are-counts.md
;; §1.5). Two reference frames share the one leaf "heat", kWh per unit of the spec:
;;   molecules  the standard enthalpy of formation at 25 °C, kJ/mol (NIST-JANAF /
;;              CRC), so a reaction's heat of reaction is Hess's law read off the
;;              same residual that reads its atoms — combustion of methane leaves
;;              +890 kJ/mol as surplus heat, an endothermic step is open until a
;;              heat carrier is consumed;
;;   forms      sensible heat relative to ambient, c·ΔT/3600 kWh/kg (`thermal-form`),
;;              and latent heat where a phase changes.
;; A process whose flows cross the two frames must state the form's formation part;
;; vf-lint refuses it otherwise. The heat carriers (electricity, `spec-bn-heat`,
;; `ambient-heat`) carry one kWh of heat per kWh; a product's heat is STATED, never
;; derived from a residual, because heat's residual is loss to the surroundings and
;; that loss is the `≥ 0` half element closure allows.
(define *enthalpy*                       ; kJ/mol, standard state, 25 °C
  '(("co2"     . -393.5)
    ("co"      . -110.5)
    ("ch4"     . -74.9)
    ("nh3"     . -45.9)
    ("h2o"     . -285.8)                 ; liquid
    ("h2o-g"   . -241.8)                 ; vapour: the difference is the latent heat of evaporation
    ("h2o-s"   . -291.8)                 ; ice at 0 °C: the difference is the latent heat of fusion
    ("o2"      . 0.0)
    ("n2"      . 0.0)
    ("glucose" . -1273.3)
    ("urea"    . -333.1)                 ; solid
    ;; FUELS the recipes draw by formula (*formula* keys them by spec id): stated in
    ;; the formation frame, so burning them closes over energy under Hess's law and
    ;; the second law reads the stove. Liquid octane stands for petrol, stearic acid
    ;; for tallow; wood and biomass, mixtures with no formula, wait on a per-kg row.
    ("spec-petrol"          . -250.1)    ; n-octane, liquid
    ("spec-sp-stearic-acid" . -947.7)))  ; octadecanoic acid, solid
;; ── THE LEAVES, declared once ──────────────────────────────────────────────────
;; A conserved quantity is a LEAF a unit of a spec carries. Each is declared here
;; with its unit, its sign and its law, and everything else derives: the id lists
;; the readers key on (`leaf-ids`), the sign rule of `substance-content`
;; (`signed-leaf?`), and the register's table (tools/emit/physics-emit.scm). The tracked
;; elements are leaves too, of kind element, unsigned: matter is an amount or nothing.
(define *leaves* '())                     ; ((id . (kind unit signed? law)) …), in declaration order
(define* (declare-leaf! id kind unit law #:key (signed? #f))
  (set! *leaves* (append (remove (lambda (l) (equal? (car l) id)) *leaves*)
                         (list (cons id (list kind unit signed? law))))))
(define (leaf-ids kind) (filter-map (lambda (l) (and (eq? (cadr l) kind) (car l))) *leaves*))
(define (signed-leaf? id) (let ((l (assoc-ref *leaves* id))) (and l (caddr l))))
(define (leaf-unit id) (let ((l (assoc-ref *leaves* id))) (and l (cadr l))))
(for-each (lambda (e) (declare-leaf! (car e) 'element "kg/kg"
                                     "conserved by every internal transformation: created by none, lost to a named or unnamed sink"))
          *elements*)
(declare-leaf! "heat" 'energy "kWh" "the first law: a molecule's enthalpy of formation, a nucleus's energy below free nucleons, a form's excess over ambient, a carrier's kWh; created by none, lost to the surroundings" #:signed? #t)
(declare-leaf! "entropy" 'entropy "kWh/K" "the second law: produced, never destroyed; a process whose outputs carry less than its inputs plus the unnamed heat at T₀ cannot run" #:signed? #t)
(declare-leaf! "A" 'nucleon "nucleons/mol" "nucleon number, conserved by every nuclear channel" #:signed? #t)
(declare-leaf! "Z" 'nucleon "charge/mol" "charge, conserved by every nuclear channel" #:signed? #t)
(declare-leaf! "L" 'nucleon "leptons/mol" "lepton number, conserved by every nuclear channel: the electron +1, the antineutrino −1" #:signed? #t)
(define *energy-ids* (leaf-ids 'energy))
;; what the engine's composition map CLOSES over (`close-elements!`): the elements
;; and heat, each an `El|leaf ≥ 0` balance — creation refused, loss allowed. Entropy
;; stays out: produced, it is the lint's reading, never a closure row.
(define (closure-basis) (append *element-ids* *energy-ids*))
;; ENTROPY — the quantity the second law says is PRODUCED, never destroyed. Standard
;; molar entropies at 25 °C, J/(mol·K) (NIST-JANAF / CRC); a form's entropy is relative
;; to the same form at ambient, m·c·ln(T/T₀); a heat carrier's is Q/T at the temperature
;; it carries heat at: electricity none (it is work), ambient heat 1/T₀, sunlight 1/5778,
;; delivered heat 1/T₀ (ambient grade unless it lands in a thermal form). The leaf is
;; "entropy", kWh/K per unit of the spec. Unnamed heat loss goes to the surroundings
;; at T₀ and produces its Q/T₀ there (`second-law-production`), so a process reads as
;; impossible exactly when it would have to destroy entropy — Carnot and every other
;; second-law bound fall out of that one inequality, and exergy is its reading.
(define %ambient-kelvin 293.15)
(define %sun-kelvin 5778.0)
(define *entropy*                        ; J/(mol·K), standard state, 25 °C
  '(("co2"     . 213.8)
    ("co"      . 197.7)
    ("ch4"     . 186.3)
    ("nh3"     . 192.8)
    ("h2o"     . 70.0)
    ("h2o-g"   . 188.8)
    ("o2"      . 205.2)
    ("n2"      . 191.6)
    ("glucose" . 212.1)
    ("urea"    . 104.6)
    ("spec-petrol"          . 361.2)     ; n-octane, liquid
    ("spec-sp-stearic-acid" . 435.6)))   ; octadecanoic acid, solid
(define *entropy-ids* (leaf-ids 'entropy))
;; MIXTURES with a stated enthalpy and entropy per kilogram, in the FORMATION frame
;; (so they burn under Hess's law beside the molecules). A mixture has no formula to
;; derive from, so each figure is an estimate with its derivation named, and a
;; measured value replaces it. Biomass as received: half cellulose (−5.94 MJ/kg per
;; C₆H₁₀O₅ unit) and half water (−15.9 MJ/kg) give −10.9 MJ/kg, −3.0 kWh/kg; an
;; entropy of 1.4 kJ/(kg·K) is the run of woody biomass tables.
;; FOODS, FROM THE RELEASE. The pinned USDA rows (data/fdc-sr-legacy.scm, sliced by
;; catalogues/food-sources.scm *fdc-composition*) state each food's water, protein, fat,
;; carbohydrate, ash, phosphorus and potassium per 100 g. From those, per UNIT of the
;; food (a kilogram; salt's gram), follow the elements it is made of and the heat
;; and entropy it carries in the formation frame, so a food burns, grows and is
;; eaten under Hess's law beside the molecules: carbohydrate as the polysaccharide
;; unit C₆H₁₀O₅ (C 0.444, H 0.062), protein at its run of amino acids (C 0.53,
;; H 0.07, N 0.16), fat as a triglyceride (C 0.77, H 0.12); the formation enthalpy
;; from the combustion products the Atwater kilocalories return to, CO₂ for every
;; carbon and liquid water for every hydrogen, plus the water it already holds;
;; the entropy at the run of organic solids, 1.3 kJ/(kg·K) dry, water's 3.89 wet.
;; Estimates with their derivation named; a measured figure on the spec replaces one.
(define %kj-per-kwh 3600.0)
(define %mm-h2o (+ (* 2 (atomic-weight "H")) (atomic-weight "O")))   ; g/mol, the two molecules a food burns to, stated once
(define %mm-co2 (+ (atomic-weight "C") (* 2 (atomic-weight "O"))))
(define %macro-elements                 ; mass fraction of C, H, O and N in each macronutrient (the rest of protein is sulphur)
  '(("protein" . (("C" . 0.53) ("H" . 0.07) ("O" . 0.22) ("N" . 0.16)))
    ("fat" . (("C" . 0.77) ("H" . 0.12) ("O" . 0.11)))
    ("carbohydrate" . (("C" . 0.444) ("H" . 0.062) ("O" . 0.494)))))
(define %entropy-dry-kj-per-kg-k 1.3)   ; the run of organic solids
;; the heat each macronutrient gives a calorimeter, kJ per kilogram (Merrill & Watt
;; 1955: protein 5.65, fat 9.40, carbohydrate 4.10 kcal/g). GROSS energy, the
;; bomb's, is what Hess's law wants for a formation; the catalogue's kilocalories
;; are Atwater's METABOLISABLE figure, less what leaves undigested and as urea
(define %macro-gross-kj-per-kg '(("protein" . 23640.0) ("fat" . 39330.0) ("carbohydrate" . 17150.0)))
;; ONE HESS ROUTE, its three constants stated once: what a kilogram of carbon releases
;; forming CO₂, a kilogram of hydrogen forming liquid water, and a kilogram of water's
;; own formation, kJ. A formation is the products' heat plus the gross heat back; a
;; combustion is the formation less the products' heat: the same three numbers read
;; in either direction (formation-kwh, combustion-kj).
(define %kj-per-kg-c (/ (* (assoc-ref *enthalpy* "co2") 1000.0) (atomic-weight "C")))
(define %kj-per-kg-h (/ (* (assoc-ref *enthalpy* "h2o") 1000.0) (* 2 (atomic-weight "H"))))
(define %kj-per-kg-water (/ (* (assoc-ref *enthalpy* "h2o") 1000.0) %mm-h2o))
(define (formation-kwh c h water gross-kj)
  "The enthalpy of formation, kWh per kilogram, of a mixture whose kilogram holds C
   of carbon and H of hydrogen in its dry matter, WATER of the molecule, and gives a
   calorimeter GROSS-KJ: Hess's law from the products it burns to (CO₂ per carbon,
   liquid water per hydrogen, nitrogen as N₂ at zero) and the water it holds, the
   gross heat back."
  (/ (+ (* c %kj-per-kg-c) (* h %kj-per-kg-h) (* water %kj-per-kg-water) gross-kj) %kj-per-kwh))
(define (entropy-kwh-per-k dry water)
  "The entropy, kWh/K per kilogram, of DRY kilograms of organic solids at their run
   and WATER kilograms of the molecule at its table value."
  (/ (+ (* dry %entropy-dry-kj-per-kg-k)
        (* water (/ (* (assoc-ref *entropy* "h2o") 1e-3 1000.0) %mm-h2o)))
     %kj-per-kwh))
;; A STATED MIXTURE is the one spelling behind every form the tables describe: per
;; kilogram, the dry matter's elements, the water molecule, the gross heat a
;; calorimeter reads (kJ; absent where the form is not burned, and the first and
;; second law then leave it unread) and, for a food, its metabolisable kilocalories.
;; The release's macronutrients become one (macros->mixture); a hand row is one as
;; written; an alias is its target's. Every derived figure — composition row,
;; formation, entropy, the body's flows — reads the mixture and nothing else.
(define (macros->mixture m)
  "The macronutrients M (food-macros: water, protein, fat, carbohydrate, ash,
   phosphorus, potassium, kcal per kilogram) as a stated mixture: the elements at
   each macronutrient's run (%macro-elements), phosphorus and potassium as stated,
   the water, the gross heat of combustion (%macro-gross-kj-per-kg) and the
   kilocalories carried."
  (define (el e) (apply + (map (lambda (x) (* (or (assoc-ref m (car x)) 0) (or (assoc-ref (cdr x) e) 0))) %macro-elements)))
  `(("C" . ,(el "C")) ("H" . ,(el "H")) ("O" . ,(el "O")) ("N" . ,(el "N"))
    ("P" . ,(or (assoc-ref m "phosphorus") 0)) ("K" . ,(or (assoc-ref m "potassium") 0))
    ("h2o" . ,(or (assoc-ref m "water") 0))
    ;; the organic solids the release counts: what the entropy of dry matter runs over
    ("dry" . ,(apply + (map (lambda (k) (or (assoc-ref m k) 0)) '("protein" "fat" "carbohydrate" "ash"))))
    ("gross-kj" . ,(apply + (map (lambda (g) (* (or (assoc-ref m (car g)) 0) (cdr g))) %macro-gross-kj-per-kg)))
    ("kcal" . ,(or (assoc-ref m "kcal") 0))))
;; MIXTURES STATED BY HAND: a form the release does not carry and no macronutrient
;; describes, said once as what a kilogram of it holds: the dry matter's elements,
;; the water molecule, and the gross heat a calorimeter reads (kJ per kilogram of
;; the form as it stands; absent where the form is not burned and so unread by the
;; first law). Its composition row, formation and entropy all derive from this one
;; statement by the route a release food takes. [DRAFT] figures at the run of their
;; class, derivation named:
;;   spec-biomass  green waste as received, half moisture; dry wood and leaf near
;;                 C .50 H .06 O .43, 19 MJ/kg dry (Phyllis, rounded), C:N 25
;;   faeces        as passed, three quarters water; dry near C .45 H .065 O .30
;;                 N .05, P and K at the run, 20 MJ/kg dry: the body's undigested
;;   residue       straw at 15 % moisture, 16 MJ/kg as fed
;;   excreta       the sanitation fixtures' MIXED urine and dung, 85 % water
;;   foodwaste     kitchen scraps, 70 % water; compost, mixedwaste, landfillmix at
;;                 their run, half water; food the farm fixtures' mixed produce,
;;                 70 % water and no heat stated (its kilocalories are the fixtures'
;;                 season-per-run statement, see physics.md §7)
;;   spec-bn-lanolin  wool wax: esters near C .77 H .13 O .10, 40 MJ/kg
;; C, N, P and K where a row stood before are kept to the figure it stated.
(define *mixtures-hand*
  '(("spec-biomass"    . (("C" . 0.25)  ("H" . 0.030) ("O" . 0.215) ("N" . 0.010) ("P" . 0.002)  ("K" . 0.006)  ("h2o" . 0.50) ("gross-kj" . 9500.0)))
    ("faeces"          . (("C" . 0.1125) ("H" . 0.016) ("O" . 0.075) ("N" . 0.0125) ("P" . 0.005) ("K" . 0.0025) ("h2o" . 0.75) ("gross-kj" . 5000.0)))
    ("residue"         . (("C" . 0.42)  ("H" . 0.055) ("O" . 0.37)  ("N" . 0.010) ("P" . 0.003)  ("K" . 0.020)  ("h2o" . 0.15) ("gross-kj" . 16000.0)))
    ("excreta"         . (("C" . 0.09)  ("H" . 0.012) ("O" . 0.05)  ("N" . 0.045) ("P" . 0.013)  ("K" . 0.022)  ("h2o" . 0.85) ("gross-kj" . 3500.0)))
    ("foodwaste"       . (("C" . 0.14)  ("H" . 0.020) ("O" . 0.10)  ("N" . 0.022) ("P" . 0.005)  ("K" . 0.017)  ("h2o" . 0.70) ("gross-kj" . 5500.0)))
    ("mixedwaste"      . (("C" . 0.11)  ("H" . 0.015) ("O" . 0.08)  ("N" . 0.031) ("P" . 0.009)  ("K" . 0.020)  ("h2o" . 0.50) ("gross-kj" . 4500.0)))
    ("compost"         . (("C" . 0.18)  ("H" . 0.020) ("O" . 0.13)  ("N" . 0.022) ("P" . 0.012)  ("K" . 0.021)  ("h2o" . 0.50) ("gross-kj" . 6000.0)))
    ("landfillmix"     . (("C" . 0.12)  ("H" . 0.015) ("O" . 0.09)  ("N" . 0.020) ("P" . 0.006)  ("K" . 0.012)  ("h2o" . 0.50) ("gross-kj" . 4500.0)))
    ("food"            . (("C" . 0.12)  ("H" . 0.018) ("O" . 0.11)  ("N" . 0.026) ("P" . 0.006)  ("K" . 0.020)  ("h2o" . 0.70)))
    ("spec-bn-lanolin" . (("C" . 0.77)  ("H" . 0.13)  ("O" . 0.10)  ("gross-kj" . 40000.0)))))
;; a form whose substance is another's: bran is what the mill takes off the grain,
;; grain by another name, so its row, its formation and its entropy are the grain's
(define *composition-aliases*
  '(("bran" . "grain")                  ; what the mill takes off the grain
    ("spec-produce" . "greens")))       ; the surplus fixtures' fresh produce
(define (mixture-of id)
  "The stated mixture behind form ID: its hand row, else its macronutrients (the
   release's or the hand's, food-macros), else its alias's; #f where nothing is stated."
  (or (assoc-ref *mixtures-hand* id)
      (and=> (food-macros id) macros->mixture)
      (and=> (assoc-ref *composition-aliases* id) mixture-of)))
(define %mixture-figures '("gross-kj" "kcal" "dry" "±"))   ; the mixture's figures that are no leaf
(define (mixture-elements id)
  "Form ID's composition row, (leaf . kg) per kilogram: the elements and the water
   its stated mixture holds; #f where nothing is stated."
  (and=> (mixture-of id)
         (lambda (row) (filter (lambda (p) (and (not (member (car p) %mixture-figures)) (> (cdr p) 0))) row))))
(define (mixture-formation-kwh id)
  "Form ID's enthalpy of formation, kWh/kg, by the one Hess route (formation-kwh);
   #f where its mixture states no gross heat."
  (let ((row (mixture-of id)))
    (define (f k) (or (assoc-ref row k) 0.0))
    (and row (assoc-ref row "gross-kj") (formation-kwh (f "C") (f "H") (f "h2o") (f "gross-kj")))))
(define (mixture-entropy-kwh-per-k id)
  "Form ID's entropy, kWh/K per kilogram: its dry matter (the organic solids the
   release counts, else all that is not water) at the run of organic solids and its
   water at water's; #f where its mixture states no gross heat (an unburned form is
   unread by the second law as by the first)."
  (let ((row (mixture-of id)))
    (and row (assoc-ref row "gross-kj")
         (let ((water (or (assoc-ref row "h2o") 0.0)))
           (entropy-kwh-per-k (or (assoc-ref row "dry") (- 1.0 water)) water)))))
;; the release's readers keep their names: a food is a stated mixture like any other
(define food-elements mixture-elements)
(define food-formation-kwh mixture-formation-kwh)
(define food-entropy-kwh-per-k mixture-entropy-kwh-per-k)
;; every form with a stated mixture, and ONE derivation over them
(define *stated-forms*
  (delete-duplicates (append (map car *mixtures-hand*) (map car *food-sources*) (map car *food-macros-hand*) (map car *composition-aliases*))))
(define (derived-table figure)
  "((form . FIGURE) …) over every stated form FIGURE reads."
  (filter-map (lambda (id) (let ((v (figure id))) (and v (cons id v)))) *stated-forms*))
(define *enthalpy-per-kg* (derived-table mixture-formation-kwh))       ; kWh/kg
(define *entropy-per-kg*  (derived-table mixture-entropy-kwh-per-k))   ; kWh/(K·kg)
;; VOLUME AND LIFT. A litre has a mass only where a density is stated, and the
;; model held none (`composition-unit-gaps`); it holds bulk densities now, kg per
;; litre as the good is counted (a sack of grain, a shelf of loaves), so a good
;; counted by mass has a volume and one counted by volume a mass. What a container
;; holds follows: a store keeps a good by lending it the container's hours through
;; the period (engine `store-recipe`, the `use` of a keep-in-place spec), and a
;; unit's share of a container is its litres over the container's, so a cubic
;; metre holds 770 kg of grain and 250 of bread, and the same `use` is capacity by
;; volume. Lifting a mass through a height costs m·g·h, stated once, for the arc
;; that knows its climb.
(define *density*                        ; kg per litre, bulk, as counted; estimates with their derivation named
  '(("grain" . 0.77) ("spec-wheat" . 0.77) ("bran" . 0.25) ("flour" . 0.59) ("bread" . 0.25)
    ("beans" . 0.85) ("greens" . 0.15) ("carrot" . 0.60) ("dairy" . 1.03) ("spec-milk" . 1.03)
    ("eggs" . 1.03) ("fish" . 1.00) ("fish-stock" . 1.00) ("flax" . 0.70) ("walnuts" . 0.50)
    ("rapeseed-oil" . 0.92) ("soy" . 0.75) ("salt" . 1.20) ("fodder" . 0.12) ("spec-biomass" . 0.30)
    ("grow-water" . 1.00) ("spec-water" . 1.00) ("drinking-water" . 1.00) ("rain" . 1.00) ("water" . 1.00)))
(define (density-of spec) (assoc-ref *density* spec))
(define (litres-per-unit spec unit)
  "The litres one UNIT of SPEC occupies: a volume unit's own litres, a mass unit's
   kilograms over the density; #f where neither is known."
  (or (litres-in-unit unit)
      (let ((kg (kg-per-unit unit))) (and kg (density-of spec) (/ kg (density-of spec))))))
(define* (container-hours good container-litres #:key (unit "kg") (period-hours 24.0))
  "The container hours one UNIT of GOOD takes for a period held: its share of the
   container's litres times the period's hours (a unit's `use` in a store recipe);
   #f where the good's volume is unknown. PERIOD-HOURS over it is the capacity."
  (let ((l (litres-per-unit good unit)))
    (and l (> container-litres 0) (* period-hours (/ l container-litres)))))
(define (%per-kg table id scale)
  "TABLE's per-mole figure for ID as kWh (or kWh/K) per kilogram, or #f: the figure
   times SCALE kJ per table unit, over the molar mass, over kJ per kWh."
  (let ((v (assoc-ref table id)) (mm (molar-mass id)))
    (and v mm (> mm 0) (/ (* v scale 1000.0) mm %kj-per-kwh))))
(define (entropy-per-kg id)
  "A species' standard entropy as kWh/K per kilogram, or #f: a molecule's from the
   table, a mixture's as stated."
  (or (assoc-ref *entropy-per-kg* id) (%per-kg *entropy* id 1e-3)))   ; J → kJ
;; the HEAT CARRIERS: one kWh of heat per kWh, in neither frame — a carrier is the
;; bridge between them (combustion's heat of reaction leaves as spec-bn-heat)
;; the ambient flows by NAME, checked against the engine's list at load: one spelling
;; for the seeder, the lint and the carrier row, and a renamed flow fails here
(define (ambient name)
  (or (find (lambda (s) (string=? s name)) *ambient-flows*)
      (error "substances: the engine states no ambient flow named" name *ambient-flows*)))
(define %sunlight (ambient "sunlight"))        ; the sun's light
(define %rain     (ambient "rain"))            ; the sky's water, boundless where no land states it
(define %air      (ambient "co2"))             ; the air's carbon dioxide, what a crop's carbon is fixed from
(define %delivered-heat "spec-bn-heat")        ; heat handed over at ambient grade: what a stove, a proofer or a dwelling draws
(define *heat-carrier-rows*                 ; one kWh of heat per kWh, and the entropy it carries, Q/T — derived, never typed
  `(("spec-sp-electricity" . (("heat" . 1.0) ("entropy" . 0.0)))                     ; work: says its entropy is none
    ("spec-bt-charge"      . (("heat" . 1.0) ("entropy" . 0.0)))                     ; the e-assist charge: work
    (,%delivered-heat      . (("heat" . 1.0) ("entropy" . ,(/ 1.0 %ambient-kelvin))))  ; delivered heat, ambient grade
    ("ambient-heat"        . (("heat" . 1.0) ("entropy" . ,(/ 1.0 %ambient-kelvin))))  ; the surroundings at T₀
    (,%sunlight            . (("heat" . 1.0) ("entropy" . ,(/ 1.0 %sun-kelvin))))))    ; radiation at 5778 K: the low entropy a leaf runs on
(define *heat-carriers* (map car *heat-carrier-rows*))
(define *boundary-carriers* *ambient-flows*)   ; the carriers at the system's edge, no recipe makes them: the engine's own list of boundless ambient flows, read here
(define %kj-per-kcal 4.184)                                  ; the thermochemical calorie
(define %kwh-per-kcal (/ %kj-per-kcal %kj-per-kwh))          ; derived: 1.162e-3
;; PHOTOSYNTHESIS, the one channel that fills a food's energy leaf. Sunlight is the
;; only source of food energy a recipe may name (the first law on the nutrient leaf
;; "energy": a process whose products carry more kilocalories than its inputs draws
;; the difference from light or cannot run, vf-lint `photosynthesis`), and a crop
;; turns at most this share of the light that falls on it into stored energy: the
;; season-long field efficiency of C3 crops, 1–2 % of incident radiation into
;; biomass (Zhu, Long & Ort 2008, Curr. Opin. Biotechnol. 19:153), taken at its
;; lower end and applied to the edible part, so it is a ceiling every real harvest
;; sits well under. Conservation is necessary, never sufficient: the bound refuses
;; a recipe that beats the leaf, and says nothing about soil, water or season.
;; THE PATHWAYS. A leaf fixes carbon by one of three chemistries, and each has its
;; own two ceilings: the share of the light it stores over a season, and the least
;; water it transpires per kilocalorie stored (a leaf takes carbon through the
;; opening it loses water by). C3 is the run of crops (wheat, potato, the greens):
;; 1 % of the light (Zhu, Long & Ort 2008), some 500 kg of water per kg of dry
;; matter, 0.12 L per kcal. C4 (maize, sorghum, sugarcane) stores half again as
;; much and transpires half: 0.06. CAM (agave, pineapple, the succulents) opens
;; at night, stores little and transpires a fifth of C3: 0.025. A crop the table
;; does not name is C3. Stated figures with their derivation named, ceilings on
;; efficiency and so floors on what a grow draws; a reading tightens them.
(define *pathways*
  '((c3  . ((share . 0.010) (litres-per-kcal . 0.12)))
    (c4  . ((share . 0.015) (litres-per-kcal . 0.06)))
    (cam . ((share . 0.005) (litres-per-kcal . 0.025)))))
(define *crop-pathway*                  ; food → pathway, stated for every crop the release and the fixtures grow
  '(("grain" . c3) ("spec-wheat" . c3) ("wheat" . c3) ("barley" . c3) ("beans" . c3) ("bean" . c3) ("pea" . c3)
    ("greens" . c3) ("carrot" . c3) ("potato" . c3) ("tomato" . c3) ("flax" . c3) ("walnuts" . c3) ("soy" . c3)
    ("rapeseed-oil" . c3) ("fodder" . c3)
    ("maize" . c4) ("sorghum" . c4) ("sugarcane" . c4) ("millet" . c4)
    ("agave" . cam) ("pineapple" . cam) ("cactus-pear" . cam)))
(define (pathway-stated? food) (and (assoc-ref *crop-pathway* food) #t))
(define (pathway-of food) (or (assoc-ref *crop-pathway* food) 'c3))
(define (pathway-figure food key) (assq-ref (assq-ref *pathways* (pathway-of food)) key))
(define (photosynthetic-share food) (pathway-figure food 'share))
(define (litres-per-kcal food) (pathway-figure food 'litres-per-kcal))
;; LIGHT PER SQUARE METRE PER DAY, by latitude and month: what bounds a field.
;; An estimate with its derivation named, until a reading replaces it. The annual
;; mean falls with latitude as 6.0·cos(φ)^1.6 kWh/m²/day (the equator near 6,
;; San Francisco 4.2, Berlin 2.8, Oslo 2.0: NASA POWER climatology to within a
;; few tenths), and the year swings around it as a cosine with its crest at the
;; solstice, its amplitude (1.1·sin φ)^1.5 capped at 0.9 (Berlin's June near
;; 5 and December near 0.5; the south's crest six months on).
(define (insolation-kwh-per-m2-day lat month)
  "Global horizontal irradiation, kWh per square metre per day, at latitude LAT
   (degrees, south negative) in MONTH (1–12); an estimate, derivation above."
  (let* ((phi (* (abs lat) (/ 3.141592653589793 180.0)))
         (mean (* 6.0 (expt (max 0.05 (cos phi)) 1.6)))
         (amp (min 0.9 (expt (* 1.1 (sin phi)) 1.5)))
         (season (cos (* 2 3.141592653589793 (/ (- month 6.5) 12.0)))))
    (* mean (+ 1.0 (* amp (if (negative? lat) (- season) season))))))
;; A composition row is per UNIT of the spec. These read the units table once, so a
;; spec counted in tonnes, hectares or square metres is read at its own scale.
;; ONE BRIDGE (utils/units.scm unit-to): a conversion that fails is the classification
;; — a unit is a mass because it converts to kilograms, an area because it converts
;; to square metres, a volume because it converts to litres.
(define (area-m2 unit)
  "Square metres in one UNIT of land (ha, acre, m2…), or #f for a unit that is no area."
  (or (unit-to unit "m2") (and=> (unit-to unit "ha") (lambda (ha) (* 10000.0 ha)))))
(define (kg-per-unit unit)
  "Kilograms in one UNIT of mass (t, g, kg…), or #f for a unit that is no mass."
  (unit-to unit "kg"))
(define (litres-in-unit unit)
  "Litres in one UNIT of volume (L, ML, m3…), or #f for a unit that is no volume."
  (unit-to unit "l"))
(define %unit-scales (make-hash-table))     ; unit → its scale, asked of the bridge once: every reader of a flow asks it per flow
(define (unit-scale unit)
  "What one UNIT of a spec is, for a row stated per kilogram or per litre: its
   kilograms, else its litres (a litre of water is a kilogram); #f for a count."
  (let ((known (hash-get-handle %unit-scales unit)))
    (if known (cdr known)
        (let ((k (or (kg-per-unit unit) (litres-in-unit unit))))
          (hash-set! %unit-scales unit k)
          k))))
;; POWER: a means passes energy at a RATE. What a process draws through a means it
;; uses is at most the means' rating times the hours it is used, E ≤ P·h: the one
;; law that ties the plan's hours to its kilowatt-hours. The land's rating is the
;; sun's (the day's insolation over its 24 hours, times the area), a device's is
;; its plate figure; a means with no rating passes any amount and is unread. The
;; shine (world.scm) and the lint `power` (dsl/vf-lint.scm) read the one figure.
(define *power-ratings*                     ; kW one unit of the means passes at most, its plate figure
  '(("spec-hh-vacuum"     . 1.0)
    ("spec-hh-dishwasher" . 1.8)
    ("spec-hh-washer"     . 2.0)
    ("spec-hh-iron"       . 1.0)
    ("proofing-box"       . 0.1)))
(define* (rated-kw spec #:key unit lat month)
  "Kilowatts one UNIT of SPEC passes at most: land's is the light falling on it,
   the insolation at LAT in MONTH over the day times its area; a device's is its
   plate rating (*power-ratings*); #f where none is stated."
  (let ((m2 (area-m2 unit)))
    (if m2
        (and lat month (* (/ (insolation-kwh-per-m2-day lat month) 24.0) m2))
        (assoc-ref *power-ratings* spec))))
(define (enthalpy id) (or (assoc-ref *enthalpy* id) (assoc-ref *enthalpy-per-kg* id)))   ; in the formation frame, by mole or by kilogram
(define (enthalpy-per-kg id)
  "A species' enthalpy of formation as kWh per kilogram, or #f: a molecule's from
   the table and its molar mass, a mixture's as stated per kilogram."
  (or (assoc-ref *enthalpy-per-kg* id) (%per-kg *enthalpy* id 1.0)))
(define* (latent-heat-kwh-per-kg #:optional (change 'evaporation))
  "Water's latent heat, kWh/kg, derived from two formation enthalpies: evaporation
   at 25 °C, ΔHf(vapour) − ΔHf(liquid) (0.678; the 100 °C value is 0.628); fusion,
   ΔHf(liquid) − ΔHf(ice) (0.0927)."
  (case change
    ((evaporation) (- (enthalpy-per-kg "h2o-g") (enthalpy-per-kg "h2o")))
    ((fusion)      (- (enthalpy-per-kg "h2o") (enthalpy-per-kg "h2o-s")))
    (else (error "latent-heat-kwh-per-kg: no such change" change))))
(define* (thermal-row base specific-heat delta-t #:key (contains *contains*) (ambient-k %ambient-kelvin))
  "The composition row of BASE warmed by DELTA-T: the base's rows plus the sensible
   heat relative to ambient, c·ΔT/3600 kWh/kg, signed, and the entropy relative to
   the same form at ambient, c·ln(T/T₀)/3600 kWh/(K·kg)."
  ;; in the base's own frame: a base with a formation enthalpy (a food's from the
  ;; release, or heat stated on its row) hands it on, so the warmed form is one
  ;; number above it and the two never cross frames
  (let* ((base-row (or (assoc-ref contains base) '()))
         (without (lambda (k r) (remove (lambda (p) (equal? (car p) k)) r))))
    (cons* (cons "heat" (+ (or (enthalpy-per-kg base) (assoc-ref base-row "heat") 0.0) (/ (* specific-heat delta-t) %kj-per-kwh)))
           (cons "entropy" (+ (or (entropy-per-kg base) (assoc-ref base-row "entropy") 0.0) (/ (* specific-heat (log (/ (+ ambient-k delta-t) ambient-k))) %kj-per-kwh)))
           (without "heat" (without "entropy" base-row)))))
(define* (thermal-form base specific-heat delta-t #:key (contains *contains*) (ambient-k %ambient-kelvin))
  "A warmed (or cooled) form of BASE: (values id row). ID is base+ΔT\"K\"; ROW is
   `thermal-row`. Specific heat in kJ/(kg·K), stated once per material. The row is
   the scope's to STATE on the form's spec (knowledge/thermal.scm
   declare-thermal-form!); nothing here remembers it."
  (let ((id (thermal-form-id base delta-t)))
    (values id (thermal-row base specific-heat delta-t #:contains contains #:ambient-k ambient-k))))
;; which FRAME a spec's heat is stated in: 'formation for a molecule or a mixture
;; with an enthalpy of formation, and for a thermal form of such a base (its row
;; hands the base's formation on, `thermal-row`); 'excess for a form whose stated
;; row carries heat relative to itself at ambient and nothing more; #f for a form
;; that states no heat, and for a heat carrier, which bridges the frames
(define (thermal-form-id base delta-t)
  "base+ΔTK: the one spelling of a thermal form's id, whose base `thermal-base` reads back."
  (string-append base (if (negative? delta-t) "" "+") (number->string delta-t) "K"))
(define (thermal-base id)
  "The base a thermal form's id names (`thermal-form-id`), or #f."
  (and (string? id) (string-suffix? "K" id)
       (let ((i (or (string-rindex id #\+) (string-rindex id #\-))))
         (and i (> i 0) (string->number (substring id (+ i 1) (- (string-length id) 1)))
              (substring id 0 i)))))
(define* (frame-of spec #:key (contains *contains*))
  "'formation, 'excess or #f. A plain form's heat, from the tables or stated on its
   row, is its formation: relative to itself at ambient it carries none, so only a
   THERMAL form can carry an excess, and it carries its base's frame: formation
   where the base states heat, excess where the base states nothing."
  (define (row-heat id)                 ; a stated zero is the frame's zero (base-at-ambient-row), no formation
    (let ((row (assoc-ref contains id))) (and (pair? row) (assoc-ref row "heat") (not (zero? (assoc-ref row "heat"))) (assoc-ref row "heat"))))
  (cond ((member spec *heat-carriers*) #f)
        ((enthalpy spec) 'formation)
        ((thermal-base spec) => (lambda (base) (if (frame-of base #:contains contains) 'formation 'excess)))
        ((row-heat spec) 'formation)
        (else #f)))
;; THE BODY'S OUTPUTS. Eating FOOD returns its carbon as breath and its hydrogen and
;; water as vapour, and the heat the food's formation enthalpy leaves once those
;; products are formed: the exact balance, so the first law closes on the eat with
;; no loss unnamed, and the second law reads it (gases and vapour carry entropy out).
(define* (atoms spec qty #:key (contains *contains*))
  "The carbon, hydrogen, oxygen and nitrogen in QTY of SPEC, ((element . kg) …), every
   form opened to its atoms, the water molecule with them: the one reader the body's
   books are kept in."
  (substance-content spec qty #:contains contains #:tracked '("C" "H" "O" "N")))
(define* (formation-of spec #:key (contains *contains*))
  "SPEC's enthalpy of formation, kWh per kilogram: the heat its row in CONTAINS
   states where it states one (what a scope says of a loaf its own bake made),
   else the tables'; #f where none is stated."
  (let ((row (assoc-ref contains spec)))
    (or (and (pair? row) (assoc-ref row "heat")) (enthalpy-per-kg spec))))
(define* (combustion-kj spec #:key (contains *contains*))
  "The heat a kilogram of SPEC releases burning to CO₂ and liquid water, kJ, by Hess:
   its formation less its products' (the three constants of formation-kwh read the
   other way). A stated mixture's gross heat comes back exactly; a molecule's is its
   heat of combustion. #f where no formation is stated."
  (let ((h (formation-of spec #:contains contains)) (a (atoms spec 1.0 #:contains contains)))
    (define (g e) (or (assoc-ref a e) 0.0))
    (and h (- (* h %kj-per-kwh) (* (g "C") %kj-per-kg-c) (* (g "H") %kj-per-kg-h)))))
(define* (metabolic-flows food qty #:key (contains *contains*))
  "The flows of eating QTY of FOOD, (recipe flows of substance), the exact balance on every
   tracked atom and on heat, kept in two readers: `atoms` and `combustion-kj`. Two
   outputs are sized together off two conservations: FAECES carry what the body does
   not digest, the gross heat of the food less its metabolisable kilocalories less
   what the urea burns for; UREA carries the nitrogen the faeces do not (two linear
   equations, two unknowns). The rest of the carbon is breath, the rest of the
   hydrogen and the water are vapour, the oxygen those need beyond the food's own is
   breathed in (`o2`, an ambient flow), and the heat is what the formation leaves
   once every product is formed: the metabolisable kilocalories less the vapour's
   latent heat, by construction, a consume of ambient heat where that is negative
   (watery greens cost more to evaporate than they give). A form stating no
   kilocalories is taken as wholly digested. For a form that is water and nothing else, the water back as liquid
   h2o; '() for a food with no formation enthalpy, whose eating stays unread."
  (let ((h (formation-of food #:contains contains)) (mix (mixture-of food)))
    (cond
     ((water-form? food)
      (map (lambda (p) (bare-flow 'produce (car p) (cdr p))) (substance-content food qty #:contains contains #:tracked '("h2o"))))
     ((not h) '())
     (else
      (let* ((in (atoms food qty #:contains contains))
             (g (lambda (e) (or (assoc-ref in e) 0.0)))                                   ; the food's atoms
             (per-kg (lambda (spec e) (or (assoc-ref (atoms spec 1.0 #:contains contains) e) 0.0)))   ; a product's, per kilogram
             (frac (lambda (mol e) (or (assoc-ref (formula-mass-fractions mol) e) 0.0)))  ; a molecule's, per kilogram
             (gross (* qty (combustion-kj food #:contains contains)))
             (metabolisable (if (and mix (assoc-ref mix "kcal")) (* qty (assoc-ref mix "kcal") %kj-per-kcal) gross))
             (unoxidised (max 0.0 (- gross metabolisable)))
             ;; nitrogen: u·n_u + f·n_f = N; energy: u·b_u + f·b_f = unoxidised
             (bu (combustion-kj "urea" #:contains contains)) (bf (combustion-kj "faeces" #:contains contains))
             (nu (frac "urea" "N")) (nf (per-kg "faeces" "N"))
             (det (- (* nu bf) (* nf bu)))
             (faeces (max 0.0 (if (> (abs det) 1e-12) (/ (- (* nu unoxidised) (* bu (g "N"))) det) 0.0)))
             (urea (max 0.0 (/ (- (g "N") (* faeces nf)) nu)))
             (left (lambda (e) (max 0.0 (- (g e) (* urea (frac "urea" e)) (* faeces (per-kg "faeces" e))))))
             (co2 (/ (left "C") (frac "co2" "C")))                                        ; the rest of the carbon as breath
             (vapour (/ (left "H") (frac "h2o" "H")))                                     ; the rest of the hydrogen, the water with it, as vapour
             (o2 (max 0.0 (- (+ (* co2 (frac "co2" "O")) (* vapour (frac "h2o" "O")) (* urea (frac "urea" "O")) (* faeces (per-kg "faeces" "O")))
                             (g "O"))))                                                    ; the oxygen the products hold beyond the food's: breathed in
             (heat (- (* h qty)
                      (* co2 (enthalpy-per-kg "co2")) (* vapour (enthalpy-per-kg "h2o-g"))
                      (* urea (enthalpy-per-kg "urea")) (* faeces (enthalpy-per-kg "faeces")))))
        ;; the heat is a produce where the food warms the body and a consume of the
        ;; surroundings' warmth where evaporating its water costs more than its
        ;; kilocalories give (a kilogram of greens): the same balance, its sign read
        (filter (lambda (f) (> (flow-qty f) 1e-12))
                (list (bare-flow 'consume "o2" o2) (bare-flow 'produce "co2" co2) (bare-flow 'produce "h2o-g" vapour)
                      (bare-flow 'produce "urea" urea) (bare-flow 'produce "faeces" faeces)
                      (bare-flow (if (>= heat 0.0) 'produce 'consume) "ambient-heat" (abs heat) "kWh"))))))))
(define* (metabolic-outputs food qty #:key (contains *contains*))
  "((spec . qty) …): what eating QTY of FOOD produces (metabolic-flows), the
   register's and the tests' reading of the body's outputs."
  (side-quantities (metabolic-flows food qty #:contains contains) output-action?))

(define* (base-at-ambient-row base #:key (contains *contains*))
  "The row of BASE as the frame's zero: no excess heat, no entropy relative to
   itself at ambient, beside whatever the table says it is made of. Stating it is
   what lets the second law read a process that warms the base."
  (let ((row (or (assoc-ref contains base) '())))
    (cons* (cons "heat" (or (enthalpy-per-kg base) (assoc-ref row "heat") 0.0))
           (cons "entropy" (or (entropy-per-kg base) (assoc-ref row "entropy") 0.0))
           (remove (lambda (p) (member (car p) '("heat" "entropy"))) row))))

(define* (entropy-stated? spec #:key (contains *contains*))
  "Whether SPEC's entropy is on record in CONTAINS: a molecule with a standard
   entropy, or a row with an entropy entry — a carrier's Q/T, work's zero, a
   thermal form's m·c·ln(T/T₀), its base's zero. A mixture nobody has given an
   entropy is NOT stated, and a reading over it would see entropy vanish for want
   of data; absence means nobody has said."
  (or (and (assoc-ref *entropy* spec) #t)
      (and (assoc-ref *entropy-per-kg* spec) #t)
      (let ((row (assoc-ref contains spec)))
        (and row (assoc "entropy" row) #t))))

(define* (second-law-production flows #:key (contains *contains*) (ambient-k %ambient-kelvin))
  "Entropy PRODUCED by an internal transformation, kWh/K: what its outputs carry less
   what its inputs carried, plus the entropy the unnamed heat loss makes on reaching
   the surroundings at AMBIENT-K. Negative means the process would destroy entropy:
   it cannot run as stated. #f when some substance flow's entropy is not on record
   (`entropy-stated?`): the reading is made only where the data is. FLOWS as
   (recipe flows of substance)."
  (if (not (every (lambda (f) (entropy-stated? (flow-spec f) #:contains contains)) flows)) #f
  (let* ((both (append *entropy-ids* *energy-ids*))
         (r (flow-residual flows #:contains contains #:tracked both))
         (s-consumed-minus-produced (or (assoc-ref r "entropy") 0))
         (heat-lost (or (assoc-ref r "heat") 0)))                 ; consumed − produced: the unnamed loss
    (+ (- s-consumed-minus-produced) (/ heat-lost ambient-k)))))

(define* (spec-exergy spec #:key (contains *contains*) (ambient-k %ambient-kelvin))
  "The most work one unit of SPEC could yield against the surroundings, kWh: its heat
   less T₀ times its entropy — a READING of the two leaves, never a row."
  (let ((l (elemental spec #:contains contains #:stop (append *energy-ids* *entropy-ids*))))
    (- (or (assoc-ref l "heat") 0.0) (* ambient-k (or (assoc-ref l "entropy") 0.0)))))

;; NUCLEONS — the conserved quantities of a nuclear reaction. Fission turns uranium
;; into barium and krypton, so the element rows are the wrong law there; what holds
;; is nucleon number A and charge Z, and mass is not conserved: the defect leaves as
;; energy, E = mc², through the same "heat" leaf a chemical reaction's enthalpy uses.
;; A nuclide is counted in MOLES (as the reaction recipes are), its leaves per mole:
;; A nucleons, Z protons, and its whole mass-energy in kWh, so a reaction's heat
;; residual is Σm_in − Σm_out times c² with nothing else said. Atomic masses in u
;; (AME2020); electrons cancel in any charge-conserving equation. A species set that
;; mixes nuclides with molecules mixes two laws and is refused.
;; A nuclide's id is "Sym-A", so its charge and nucleon number are DERIVED from it
;; (`nuclide-z` off the periodic table, `nuclide-a` off the suffix): the table states
;; each isotope's one datum, its atomic mass in u (AME2020). The neutron is "n", no
;; element, charge none. A mistyped Z is then impossible.
(define *nuclides*                       ; id → atomic mass, u
  '(("n"      . 1.00866491590)
    ("H-1"    . 1.00782503190)
    ("H-2"    . 2.01410177784)
    ("H-3"    . 3.01604928132)
    ("He-3"   . 3.01602932197)
    ("He-4"   . 4.00260325413)
    ("C-12"   . 12.0)
    ("C-14"   . 14.003241989)
    ("N-14"   . 14.00307400446)
    ("O-16"   . 15.99491461957)
    ("Kr-92"  . 91.92615621)
    ("Sr-90"  . 89.90773)
    ("Y-90"   . 89.907142)
    ("Cs-137" . 136.90708923)
    ("Ba-137" . 136.905827)
    ("Ba-141" . 140.914403)
    ("Ra-228" . 228.031064)
    ("Th-232" . 232.03805)
    ("Th-234" . 234.043601)
    ("Pa-234" . 234.043302)
    ("U-235"  . 235.04392819)
    ("U-238"  . 238.05078826)
    ("Pu-239" . 239.05216359)))
;; the light leptons of beta decay: no nucleons, a charge, a lepton number, a mass of
;; their own (the antineutrino's is nothing the table resolves) — (Z A L mass)
(define *leptons*
  '(("beta-"        . (-1 0  1 0.000548579909))
    ("antineutrino" . (0  0 -1 0.0))))
(define (%nuclide-symbol id) (let ((i (string-index id #\-))) (if i (substring id 0 i) id)))
(define (%nuclide-number id) (let ((i (string-index id #\-))) (if i (string->number (substring id (+ i 1))) 1)))
(define *nucleon-ids* (leaf-ids 'nucleon))
;; LEPTON NUMBER: the electron and the antineutrino of a beta decay carry +1 and −1,
;; every nuclide 0, so n → p + e⁻ + ν̄ conserves it and a decay that dropped the
;; antineutrino would be refused.
(define (nuclide-l id) (let ((l (assoc-ref *leptons* id))) (if l (caddr l) 0)))
;; NUCLEAR mass: the table holds atomic masses (AME), which carry Z electrons. With
;; the electron an explicit species, a nucleus is its atom less its electrons, so
;; every mass-energy residual counts each electron once — alpha and fission channels
;; unchanged (Z is conserved), beta decay right (Q = M_atomic(parent) − M_atomic(daughter)).
(define %electron-u 0.000548579909)
(define (nuclide-mass-nuclear id)
  (if (assoc-ref *leptons* id) (nuclide-mass id)                         ; a lepton is no atom: its mass is its own
      (- (nuclide-mass id) (* (nuclide-z id) %electron-u))))

;; CHANNELS — conservation is necessary, never sufficient: on A and Z alone the null
;; space admits 19 U-235 → Ba-141 + 47 Kr-92, a channel nature never runs. Which
;; channel runs is a fact of nature stated as DATA: a decay mode with its half-life,
;; a fission fragment channel with what induces it, a fusion reaction. A nuclear
;; recipe is refused unless its reactants and products are a channel here, and a
;; decay's rate is a relaxation: the fraction of a stock gone in a period is
;; 1 − 2^(−p/t½), the store-recipe-that-leaks of knowledge/thermal.scm with the
;; daughter as the base form and the mass defect as the heat (decay heat).
;;   (reactants products kind half-life-years)  half-life #f for an induced reaction
(define *channels*
  '((("U-238")        ("Th-234" "He-4")            alpha    4.468e9)
    (("Pu-239")       ("U-235" "He-4")             alpha    2.411e4)
    (("Th-232")       ("Ra-228" "He-4")            alpha    1.405e10)
    (("Th-234")       ("Pa-234" "beta-" "antineutrino")  beta     6.6e-2)
    (("C-14")         ("N-14" "beta-" "antineutrino")    beta     5.73e3)
    (("H-3")          ("He-3" "beta-" "antineutrino")    beta     12.32)
    (("Sr-90")        ("Y-90" "beta-" "antineutrino")    beta     28.8)
    (("Cs-137")       ("Ba-137" "beta-" "antineutrino")  beta     30.08)
    (("U-235" "n")    ("Ba-141" "Kr-92" "n" "n" "n") fission  #f)
    (("H-2" "H-3")    ("He-4" "n")                 fusion   #f)
    (("H-2" "H-2")    ("He-3" "n")                 fusion   #f)))
(define (%bag l) (sort (map (lambda (x) (format #f "~a" x)) l) string<?))
(define (channel-of reactants products)
  "The channel whose reactants and products are exactly these bags, or #f."
  (find (lambda (c) (and (equal? (%bag (car c)) (%bag reactants)) (equal? (%bag (cadr c)) (%bag products))))
        *channels*))
(define (nuclear-process-channel flows)
  "FLOWS (recipe flows of substance) of nuclides → the channel they run, or #f: each
   consume/produce of q moles of a nuclide is q copies of it in the bag."
  (define (bag side?) (append-map (lambda (f) (if (side? (flow-action f)) (make-list (inexact->exact (round (flow-qty f))) (flow-spec f)) '())) flows))
  (channel-of (bag input-action?) (bag output-action?)))
;; ── RELAXATION, the one exponential ────────────────────────────────────────────
;; Newton's cooling, first-order kinetics and radioactive decay are one law: a stock
;; relaxes toward its rest state with a time constant τ, keeping e^(−p/τ) of its
;; excess through a period p (docs/observation/physics.md §3). A half-life is τ·ln 2.
(define (time-constant mass specific-heat ua)
  "τ in hours: m·c / (U·A). No conductance (UA #f or 0) is an infinite τ."
  (if (and (real? ua) (> ua 0))
      (/ (* mass specific-heat) ua %kj-per-kwh)
      +inf.0))
(define (hold-cost ua delta-t hours)
  "kWh to hold an excess of DELTA-T degrees for HOURS against conductance UA:
   the loss replaced as it happens, in every regime."
  (if (and (real? ua) (> ua 0)) (* ua (abs delta-t) hours) 0.0))
(define (carry-fraction tau period-hours)
  "e^(−p/τ): the share of an excess LEFT alone that reaches the next period.
   1 at infinite τ (no loss), 0 as τ → 0."
  (cond ((not (finite? tau)) 1.0)
        ((<= tau 0) 0.0)
        (else (exp (- (/ period-hours tau))))))
(define %hours-per-year 8766.0)          ; the Julian year, 365.25 days
(define* (decay-fraction half-life-years #:key (period-hours 24.0))
  "The share of a nuclide stock that decays in one period: 1 − 2^(−p/t½), the
   relaxation above with τ = t½ / ln 2."
  (- 1.0 (carry-fraction (/ (* half-life-years %hours-per-year) (log 2.0)) period-hours)))
(define %c 299792458.0)                                        ; m/s
(define %kwh-per-mol-per-u (/ (* 1e-3 %c %c) (* 1000.0 %kj-per-kwh)))   ; 1 u per mole = 1 g/mol; E = mc², in kWh
(define (nuclide? id) (and (or (assoc-ref *nuclides* id) (assoc-ref *leptons* id)) #t))
(define (nuclide-z id)
  (let ((l (assoc-ref *leptons* id)))
    (if l (car l)
        (let ((sym (%nuclide-symbol id)))
          (cond ((string=? sym "n") 0)
                ((atomic-number sym))
                (else (error "nuclide-z: no such element in the periodic table" id)))))))
(define (nuclide-a id) (let ((l (assoc-ref *leptons* id))) (if l (cadr l) (%nuclide-number id))))
(define (nuclide-mass id) (let ((l (assoc-ref *leptons* id))) (if l (cadddr l) (assoc-ref *nuclides* id))))
;; THE BOUND FRAME. A molecule states its heat relative to the standard elements, so
;; every bound molecule sits below zero and a fuel consumed with no products
;; contributes heat in of the wrong sign: the first law's ≥ 0 row refuses conjuring
;; heat from it. A nucleus states its heat the same way, relative to A free
;; neutrons: (m_nuclear − A·m_n)·c², so every bound nucleus sits below zero by its
;; binding energy (and the proton by m_p − m_n). A channel that conserves nucleons
;; sees the reference cancel and keeps its mass defect to the electronvolt; a
;; nuclide consumed into nothing contributes negative heat and cannot power a thing;
;; one produced from nothing wastes heat, which the row allows and which powers
;; nothing either. A lepton has no nucleons, so its heat is its rest energy, and
;; beta decay's Q comes out through it.
(define (nuclear-heat-per-mol id)
  (* (- (nuclide-mass-nuclear id) (* (nuclide-a id) (assoc-ref *nuclides* "n"))) %kwh-per-mol-per-u))
(define (nuclide-leaves id)
  (list (cons "A" (exact->inexact (nuclide-a id))) (cons "Z" (exact->inexact (nuclide-z id)))
        (cons "L" (exact->inexact (nuclide-l id)))
        (cons "heat" (nuclear-heat-per-mol id))))

;; formula of any species: a molecule's atoms, or a bare element as itself.
(define (parse-formula str)
  "A Hill formula string → ((element . count) …): \"C6H12O6\" → C 6, H 12, O 6.
   A capital starts an element, a lowercase continues it, digits count it, an
   absent count is one. The empty string is no atoms (an electron)."
  (let loop ((cs (string->list str)) (acc '()))
    (cond
     ((null? cs) (reverse acc))
     ((char-upper-case? (car cs))
      (let* ((sym-end (let scan ((r (cdr cs)) (n 1)) (if (and (pair? r) (char-lower-case? (car r))) (scan (cdr r) (+ n 1)) n)))
             (sym (list->string (list-head cs sym-end)))
             (rest (list-tail cs sym-end))
             (num-end (let scan ((r rest) (n 0)) (if (and (pair? r) (char-numeric? (car r))) (scan (cdr r) (+ n 1)) n)))
             (count (if (zero? num-end) 1 (string->number (list->string (list-head rest num-end))))))
        (loop (list-tail rest num-end) (cons (cons sym count) acc))))
     (else (error "parse-formula: a formula starts each element with a capital" str)))))
(define (formula id)
  (let ((f (assoc-ref *formula* id)))
    (cond ((string? f) (parse-formula f))
          (f f)
          ((assoc id *periodic-table*) (list (cons id 1)))
          (else #f))))
;; molar mass (g/mol) = Σ atom-count × atomic weight — derived from the formula.
(define (molar-mass id)
  (if (nuclide? id) (nuclide-mass id)                                   ; one isotope: its own mass, g/mol
      (let ((f (formula id))) (and f (fold (lambda (p a) (+ a (* (cdr p) (atomic-weight (car p))))) 0 f)))))

;;; ── ENVIRONMENT specs: nature's stocks — the soil, the air, the water. These
;;; are EconomicResources like any other; what marks them is that we mean to keep
;;; them BALANCED. Their quantity DRIFTING (soil nitrogen falling, atmospheric
;;; carbon rising) IS the metabolic rift — our unbalanced exchange with nature.
;;; The economy's own resources (carrot, compost) cycle freely and don't count.
;;; This one list is the single normative input: which stocks the loop owes.
(define *environment-specs* '("co2" "ch4" "nh3" "soil-n" "soil-p" "soil-k" "crop-runoff"))
(define (environment-spec? id) (and (member id *environment-specs*) #t))

;;; ── THE EDGE OF THE ACCOUNTING ──────────────────────────────────────────────
;; Conservation is a claim about an INTERNAL transformation. A process with substance
;; on one side only crosses the system edge — fixation and extraction bring matter in,
;; emission lets it out — so it is not judged against a balance it was never inside.
;; The predicate lives beside the list that says which stocks the edge is drawn at.
;;
;; The principled form gives such a row an explicit ENVIRONMENT variable per element,
;; making the rift that variable's solved value rather than a separate reading. That
;; is a modelling change; this is the predicate it would replace.
;; ── A FLOW, AND ITS QUANTITY IN A BASIS ───────────────────────────────────────
;; Everything below that balances substance reads RecipeFlow records. A flow states
;; its quantity in its own unit (a megalitre, a tonne, a mole, a count); a balance
;; needs every quantity of a kind in one unit, so a flow is CONVERTED to the basis
;; the tables are stated in (`flow-in-basis`): a mass or a volume to kilograms (a
;; litre of water is a kilogram), anything else left in its own unit. What generates
;; flows (a reaction, an eating) states them in the basis already: moles, kilograms,
;; kilowatt-hours. The number is carried as it is given, so an exact balance stays
;; exact.
(define (flow-action f) (recipe-flow-action f))
(define (flow-spec f) (recipe-flow-resource-conforms-to f))
(define (flow-qty f)
  "Flow F's quantity as stated, in its own unit; 0 where none is stated."
  (let ((m (recipe-flow-resource-quantity f))) (if m (measure-has-numerical-value m) 0)))
(define* (bare-flow action spec q #:optional (unit "kg"))
  "A flow of ACTION on SPEC, Q of it in UNIT, of no process: what a balance, a
   reaction or a fixture states when only the substance matters."
  (flow* #f action spec q #f unit))
(define (bare-flows rows)
  "ROWS ((action spec qty [unit]) …) as bare flows: the short spelling of a balance's
   flows, for a fixture or a table."
  (map (lambda (r) (apply bare-flow r)) rows))
(define (flow-basis-quantity f)
  "Flow record F's quantity in its row's basis, kilograms or litres, through the one
   unit bridge (unit-scale): a farm's two megalitres read as the two million litres
   they are, and a count stays a count; 0 where no quantity is stated."
  (let* ((m (recipe-flow-resource-quantity f))
         (k (and m (and=> (measure-has-unit m) unit-scale))))
    (cond ((not m) 0)
          ((and k (not (= k 1))) (* (measure-has-numerical-value m) k))
          (else (measure-has-numerical-value m)))))
(define (flow-in-basis f)
  "F with its quantity in the basis: kilograms where its unit is a mass or a volume."
  (let* ((m (recipe-flow-resource-quantity f))
         (k (and m (and=> (measure-has-unit m) unit-scale))))
    (if (and k (not (= k 1)))
        (copy-recipe-flow f #:resource-quantity (make-measure (* (measure-has-numerical-value m) k) "kg"))
        f)))
(define* (balance-flows flows #:key (basis? #t))
  "The flows of FLOWS a balance of substance is taken over: the stock-moving ones (a
   consume, a produce) of a specification with a stated quantity, each in its basis
   (flow-in-basis), which the tables are read in. With BASIS? #f each stands in its
   own unit, which a composition scaled to the spec's unit is read in
   (composition-of-scope)."
  (filter-map (lambda (f)
                (and (flow-spec f) (recipe-flow-resource-quantity f)
                     (memq (flow-action f) *flow-actions*)
                     (if basis? (flow-in-basis f) f)))
              flows))
(define (side-quantities flows side?)
  "((spec . qty) …) of the flows of FLOWS whose action SIDE? holds of (input-action?,
   output-action?): one side of a balance."
  (filter-map (lambda (f) (and (side? (flow-action f)) (cons (flow-spec f) (flow-qty f)))) flows))
(define (boundary-process? flows)
  "FLOWS, recipe flows of substance (balance-flows). True when substance crosses in
   one direction only."
  (or (not (any (lambda (f) (input-action? (flow-action f))) flows))
      (not (any (lambda (f) (output-action? (flow-action f))) flows))))

;;; ── THE DEBT, WHERE THE DATA IS ─────────────────────────────────────────────
;; Substances a recipe touches whose composition nobody has stated. Element closure
;; reads an unstated composition as ZERO, so each of these would make its consumers
;; look as though they conjure matter — which is why closure stays off in a scope that
;; draws them (docs/planning/solve/planner-coherence-open-threads.md §2.1, which sizes the
;; work: most of the list falls out of a `*formula*` row, King's cited N/P/K table, or
;; a protein→nitrogen reading of `*food-nutrition*`).
;;
;; It is DATA and it lives with the data. Held in a test it read as an assertion, and
;; a list of what is missing is not something a test discovers — it is something a
;; test GUARDS, by failing when the two disagree in either direction.
;;
;; An EMPTY `*contains*` row is the other answer, and belongs to anything that is not
;; matter: heat, electricity and accumulated wealth are declared above, not listed here.
(define *composition-unstated*
  '(;; A 30 cm bamboo skewer, counted in `each`. A mass FRACTION is meaningless
    ;; against a count — fraction × skewers is not a mass — so this one waits on a
    ;; mass per skewer rather than on a composition (§2.3, one element one unit).
    ;; Papering over it with a fraction would put a number in the ledger that means
    ;; nothing, which is worse than the gap.
    "spec-bn-bamboo"
    ;; The soil a field recipe draws (recipes/bread-commune-seed.scm `grow` and its
    ;; siblings consume "soil" by the kilogram). A soil is a mixture of everything, and
    ;; the recipes draw it as the whole rather than as the soil-n/soil-p/soil-k stores
    ;; the grow recipe of recipes/grow.scm draws; until those seeds draw the stores,
    ;; or a soil row is derived from them, the gap is named here.
    "soil"
    ;; Produce as grown, as a share or as a vend (recipes/compliance-food.scm)
    ;; and the ingredients of a way of giving out food (recipes/ways.scm): each a
    ;; basket of whatever the season brings, drawn by the kilogram as one spec. A
    ;; composition would be the basket's of the day, which the records carry and
    ;; the spec does not. Swept since the registry of seeders became the modules
    ;; of knowledge/recipes/ themselves (dsl/vf-lint.scm `recipe-seeders`).
    "spec-cf-produce" "spec-fd-member-produce" "spec-fd-public-produce" "spec-way-ingredients"))

;;; ── the substance ResourceSpecifications (elements + molecules) ─────────────
;; A scope registers these (rs 'add-resource-spec …) to make nutrients real
;; resources that recipes/processes and the stockbook can reference.
(define (subst-spec id name)
  (make-resource-specification #:id id #:name name #:default-unit-of-resource "kg"))
(define substance-specs
  (append (map (lambda (e) (subst-spec (car e) (cadr e))) *elements*)
          (map (lambda (m) (subst-spec (car m) (cadr m))) *molecules*)
          ;; the boundary carriers — the surroundings and the sun — are specs a scope
          ;; registers with the substances; the recipe-drawn carriers (electricity,
          ;; delivered heat, the charge) are the recipes' own specs
          (map (lambda (id) (make-resource-specification #:id id
                                                         #:name (string-map (lambda (c) (if (char=? c #\-) #\space c)) id)
                                                         #:default-unit-of-resource "kWh"))
               *boundary-carriers*)))
(define substance-spec-ids (append *element-ids* (map car *molecules*) *boundary-carriers*))

;;; ── the `contains` relation: substance identities + a product FALLBACK ──────
;; The proper VF source of a product's composition is the RECIPE that makes it:
;; what the grow process drew from the soil (consumed substances) is what the
;; crop embodies — see `derive-contains` below, which reads it off the recipe's
;; own flows. `*contains*` is the FALLBACK, in two parts:
;;
;;   (1) SUBSTANCE / ENVIRONMENT identities — not variable-composition mixtures
;;       but definitions: the soil-nitrogen store IS nitrogen, a runoff stream
;;       carries a known nutrient signature. These ground the derivation (the
;;       recipe consumes `soil-n`, and `soil-n` ≡ N). Keep.
;;   (2) PRODUCT-MIXTURE fallback — a fixed per-type composition for products
;;       that have NO producing recipe to derive from. Honest stopgap, and the
;;       variable-composition flattening: every carrot identical. A grow recipe
;;       OVERRIDES its product's row here (recipe-derived wins; see service.scm).
(define *contains*
  (let ((stated
  '(;; (1) substance / environment identities — definitional, ground the derivation
    ("soil-n"      . (("N" . 1.0)))      ; the soil's plant-available nitrogen store
    ("soil-p"      . (("P" . 1.0)))      ; plant-available phosphorus
    ("soil-k"      . (("K" . 1.0)))      ; plant-available potassium
    ;; WATER is the molecule: one kilogram of h2o per kilogram. On the element basis
    ;; it descends to H and O, both untracked, so it carries none of C/N/P/K and an
    ;; unbalanced recipe's residual has nowhere to hide in it (an UNSTATED composition
    ;; is a free variable composition-system would solve to a negative fraction). On
    ;; the molecule basis (#:tracked '("h2o")) every water form reads as the litre it
    ;; is, and `water-form?` names the forms that are water and nothing else: the
    ;; ones a body's drinking-water floor is met from (docs/observation/physics.md §6).
    ;; A row is per LITRE here (a litre is a kilogram), and a scope that counts a
    ;; water form in megalitres reads it at its own scale through the one unit bridge
    ;; (`unit-scale`, live scope-composition), as a tonne of grain reads its row.
    ("grow-water"     . (("h2o" . 1.0)))
    ("water"          . (("h2o" . 1.0)))   ; the farm commune's summer water
    ("rain"           . (("h2o" . 1.0)))   ; the litre that falls (%rain, the engine's ambient flow): what a grow draws when it names no other water
    ("spec-water"     . (("h2o" . 1.0)))
    ("drinking-water" . (("h2o" . 1.0)))
    ;; the PLANETARY fluxes (eco-catalogue.scm) are the same atoms one scale up: the
    ;; nitrogen boundary is reactive nitrogen, the phosphorus boundary phosphorus. A
    ;; recipe draws them by naming the spec, so they need their identity for the same
    ;; reason `soil-n` does — element closure reads an unstated composition as ZERO,
    ;; and a spec that really carries an element while saying nothing makes its
    ;; consumers look as though they conjure matter. (`warming` and
    ;; `ocean-acidification` get NO row: °C and Ω are states, not substances.)
    ("nitrogen"    . (("N" . 1.0)))
    ("phosphorus"  . (("P" . 1.0)))
    ;; NOT MATTER, and saying so is the point. An EMPTY row means "carries none of the
    ;; tracked elements"; an ABSENT row means "nobody has said". Element closure reads
    ;; both as zero, so the difference is invisible to the solve and everything to a
    ;; reader — and `composition-gaps` reports only the absent ones. Heat and
    ;; electricity are ENERGY: made of no carbon, and each carries one kWh of the
    ;; conserved leaf "heat" per kWh, so a heater's output is bounded by its input and
    ;; a heat pump runs only on the ambient heat it draws (`*enthalpy*` above).
    ;; Accumulated wealth is an abstraction and carries nothing.
    ;; the heat carriers' rows are `*heat-carrier-rows*` above, spliced in front
    ("spec-accumulated-wealth" . ())
    ("spec-usd"               . ())   ; pooled maintenance dollars — a claim, not a substance
    ;; LABOUR-HOURS specs, drawn by recipes that buy a trade's time. An hour of an
    ;; electrician is not made of carbon; the PERSON is, and the plan accounts for
    ;; them through the reproduction bands, not through the rift ledger.
    ("spec-electrician-h"     . ())
    ("spec-plumber-h"         . ())
    ("spec-helper-h"          . ())
    ("spec-dev-effort"        . ())   ; a developer session
    ;; MÍMIR co-facilitation (recipes/mimir.scm) — a facilitator's hour, the AI
    ;; co-facilitator's use, every draft the delivery gate audits, and every
    ;; deliverable that comes out the other side (a closed pre-design, a
    ;; session design, a checked agenda, an audited hand-back, an instrument,
    ;; a closing report) are process and paper, not carbon.
    ("spec:mimir-facilitator-h"          . ())
    ("spec:mimir-agent"                  . ())
    ("spec:mimir-predesign-draft"        . ())
    ("spec:mimir-predesign"              . ())
    ("spec:mimir-session-design-draft"   . ())
    ("spec:mimir-session-design"         . ())
    ("spec:mimir-agenda-draft"           . ())
    ("spec:mimir-handback"               . ())
    ("spec:mimir-instrument"             . ())
    ("spec:mimir-closing-report"         . ())
    ;; A dilute microbial inoculant. Its carbon is real and unmeasured, and leaving it
    ;; at nothing is the LENIENT direction: an understated INPUT can only mask a loss,
    ;; never invent one (an understated OUTPUT is what would invent a finding). So the
    ;; solve stays honest while the number is still owed.
    ("spec-catalyst"          . ())
    ;; 20 kg of a 1000 kg compound run — lubricant, stabiliser, brightener. Organic,
    ;; so its carbon is real; unmeasured here, and lenient for the same reason.
    ("spec-sp-additive"       . ())

    ;; ── HOUSEHOLD work (recipes/household.scm) ────────────────────────────────
    ;; Housework moves matter, it does not make it, and these rows are what lets
    ;; that be checked rather than asserted. Each stream leaves as what it entered
    ;; as, so the identity rows carry the composition and no dilution fraction is
    ;; typed anywhere: greywater IS the water (the molecule, as every water form
    ;; holds it, so the hydrogen and oxygen a wash draws leave with it),
    ;; the spent surfactant IS the soap (whose fractions derive from its formula),
    ;; the waste IS the soil that was lifted off the floor and the plate.
    ("spec-hh-greywater"      . (("h2o" . 1.0)))
    ("spec-hh-soap-spent"     . (("spec-hh-soap" . 1.0)))
    ;; Household soil — street dust, skin and fibre, kitchen grease, food residue.
    ;; The one authored judgment in the set, and it is not a new number: mixed
    ;; household waste is what this is, so it takes that row entire.
    ("spec-hh-soil-load"      . (("mixedwaste" . 1.0)))
    ("spec-hh-waste"          . (("spec-hh-soil-load" . 1.0)))
    ("spec-hh-drain-solids"   . (("spec-hh-soil-load" . 1.0)))
    ;; The STATES housework delivers. A cleaned floor is a floor in a condition,
    ;; not a thing anybody made: no matter crosses, and an empty row says so where
    ;; silence would have left a free variable. Laundry is measured in kg of cloth
    ;; HANDLED — a throughput, not a claim on the cloth, which the wash neither
    ;; makes nor destroys.
    ("spec-hh-floor-cleaned"  . ())
    ("spec-hh-floor-washed"   . ())
    ("spec-hh-surface-dusted" . ())
    ("spec-hh-bathroom-clean" . ())
    ("spec-hh-dishes-soiled"  . ())
    ("spec-hh-dishes-washed"  . ())
    ("spec-hh-laundry-dirty"  . ())
    ("spec-hh-laundry-clean"  . ())
    ("spec-hh-laundry-dry"    . ())
    ("spec-hh-laundry-ironed" . ())
    ("spec-hh-rooms-tidy"     . ())
    ("spec-hh-bed-made"       . ())
    ("spec-hh-windows-cleaned" . ())
    ("spec-hh-plants-watered" . ())
    ("skill-hh-domestic"      . ())   ; an hour of housework, like the trades above
    ;; Cooking and care — reproduction-of-labour-power.md §4's own-named gap.
    ;; A meal is a STATE a cooked pot confers, the same reading as the states
    ;; above; the raw food it draws is real matter, and this file is lenient
    ;; about it for the same reason spec-sp-additive above is: unmeasured
    ;; here, the way the household's textile fibre (laundry, above) already
    ;; is. Care is labour and nothing else, so its own hour is empty exactly
    ;; as skill-hh-domestic's is.
    ("spec-hh-food-raw"       . ())
    ("spec-hh-meal-cooked"    . ())
    ("spec-hh-child-minded"   . ())
    ("spec-hh-care-given"     . ())
    ("skill-hh-cooking"       . ())
    ("skill-hh-childcare"     . ())
    ("skill-hh-eldercare"     . ())
    ;; ── DWELLING (recipes/dwelling.scm) ──────────────────────────────────────
    ;; Shelter is a STATE a night confers, not matter; a bed and a dwelling are
    ;; durables a night's shelter `use`s and `cite`s without moving a gram. Empty
    ;; where silence would have left a free variable — as the housework states.
    ("spec-shelter"           . ())
    ("spec-bed"             . ())
    ("spec-dwelling"          . ())
    ;; ── FLAT KEY (recipes/flat-key.scm) ──────────────────────────────────────
    ;; An opening and a shift are states; the key, the oven and the cutter are
    ;; durables a run uses. The blank's brass becomes the key's and the swarf's,
    ;; counted in "each" and unmeasured here, as the household's fibre is.
    ("spec-flat-access"       . ())
    ("spec-oven-shift"        . ())
    ("spec-oven"              . ())
    ("spec-flat-key"          . ())
    ("spec-key-blank"         . ())
    ("spec-key-cutter"        . ())
    ("spec-key-swarf"         . ())
    ("skill-locksmith"        . ())
    ("skill-errand"           . ())
    ;; ── HOUSING (knowledge/housing-catalogue.scm, catalogues/housing-substance.scm) ─────
    ;; The rows shelter reduces to when a scope asks HOW WELL — states a night
    ;; in a dwelling confers, not matter, the declaration spec-shelter makes
    ;; above. The per-unit and per-person goods are made per solve, as a
    ;; person's `food~pid` and `nutrient|pid` are.
    ("hs-area"                . ())
    ("hs-warmth"              . ())
    ("hs-privacy"             . ())
    ("hs-safety"              . ())
    ("hs-sanitation"          . ())
    ("hs-energy"              . ())
    ("hs-dry"                 . ())
    ("hs-quiet"               . ())
    ("hs-dark"                . ())
    ("hs-accessibility"       . ())
    ("spec-eur"               . ())   ; a claim, not a substance — as `spec-usd` above

    ;; ── CURRENCY (recipes/currency.scm) ───────────────────────────────────────
    ;; Every fiat currency and store-of-value in the table is a claim, not a
    ;; substance — gold and silver included: a gram of gold sitting in a
    ;; recipe's price flow is priced as money, not weighed as an element this
    ;; ledger tracks, the same reasoning as spec-eur/spec-usd above.
    ("spec-gbp"               . ())
    ("spec-jpy"               . ())
    ("spec-chf"               . ())
    ("spec-cad"               . ())
    ("spec-aud"               . ())
    ("spec-cny"               . ())
    ("spec-inr"               . ())
    ("spec-gold"              . ())
    ("spec-silver"            . ())

    ;; ── COLD CHAIN (recipes/cold-chain.scm) ───────────────────────────────────
    ;; spec-cc-raw is the pipeline's own BOUNDARY intake — greens arriving from
    ;; outside, consumed by rp-receive and never produced by anything in this
    ;; store — so it is a real gap, not a derivable spec, and needs a stated row
    ;; like any other input. Left empty, the lenient direction: an unmeasured
    ;; real composition (real leafy greens do carry carbon) understates an
    ;; INPUT, which can only mask a loss, never invent one — the same reasoning
    ;; spec-catalyst above states for its own dilute, unmeasured carbon. Every
    ;; later stage good (spec-cc-received/-sorted/-packed, spec-leafy-greens
    ;; itself) is DERIVABLE — each produced by exactly one recipe-process — so
    ;; none of them need a row here at all.
    ("spec-cc-raw"            . ())

    ;; ── the WASTE STREAMS a household sorts into ──────────────────────────────
    ;; Each stream is what it is made of, by identity or by formula, so the sort
    ;; needs no element number of its own. Organic waste IS food waste; residual
    ;; waste IS mixed household waste — which is also what the cleaning soil is,
    ;; so soil binned as residual disturbs nothing.
    ("spec-hh-organics"       . (("foodwaste" . 1.0)))
    ("spec-hh-residual"       . (("mixedwaste" . 1.0)))
    ;; Packaging is ~70% plastics by mass and ~30% aluminium and steel. The metals
    ;; carry none of the tracked four, so the row names only the plastic share and
    ;; the remainder is accounted for by carrying nothing — stated here rather
    ;; than left to look like a rounding error.
    ("spec-hh-packaging"      . (("spec-sp-hdpe" . 0.7)))
    ;; The unsorted stream is the mixture of exactly what the sort separates it
    ;; into, in exactly the proportions `*household-waste-streams*` states. That is
    ;; what makes a SPLIT conserve by construction: change a yield in the recipe
    ;; and this row is the one other place to change.
    ("spec-hh-discards"       . (("spec-hh-organics"  . 0.40)
                                 ("spec-hh-paper"     . 0.20)
                                 ("spec-hh-glass"     . 0.12)
                                 ("spec-hh-packaging" . 0.13)
                                 ("spec-hh-residual"  . 0.15)))
    ;; A bin run relocates; it transforms nothing. Each collected stream is its
    ;; stream, and the balance across the trip is exact without a second number.
    ("spec-hh-organics-collected"  . (("spec-hh-organics"  . 1.0)))
    ("spec-hh-paper-collected"     . (("spec-hh-paper"     . 1.0)))
    ("spec-hh-glass-collected"     . (("spec-hh-glass"     . 1.0)))
    ("spec-hh-packaging-collected" . (("spec-hh-packaging" . 1.0)))
    ("spec-hh-residual-collected"  . (("spec-hh-residual"  . 1.0)))

    ;; ── IDENTITY rows: a thing that IS another thing ──────────────────────────
    ;; `contains` is recursive, so a row naming a composed spec inherits its
    ;; composition entire — no second copy of the numbers to keep in step. An
    ;; uncertified batch of food is food; the surplus a shop hands over is food.
    ("spec-ftf-uncertified"   . (("food" . 1.0)))
    ("spec-bfs-ueberschuss"   . (("food" . 1.0)))

    ;; the foods and crops derive: wheat grain, milk, the sea's fish, carrot and the
    ;; farm's produce from the release (`food-elements`, aliases for the names the
    ;; fixtures use), the wastes, the residue, the biomass, lanolin and the body's
    ;; faeces from the hand-stated mixtures (`*mixtures-hand*`, `mixture-elements`)
    ("runoff"      . (("N" . 0.050) ("P" . 0.020) ("K" . 0.030)))
    ("crop-runoff" . (("N" . 0.050) ("P" . 0.022) ("K" . 0.030)))
    ;; (2) product-mixture FALLBACK — used only when no recipe derives the product
    ("fertiliser"  . (("N" . 0.40) ("P" . 0.18) ("K" . 0.42))))))
    ;; …and behind the stated rows, every hand-stated mixture and every food the
    ;; release carries, derived: a stated row wins, the tables fill the rest
    (let ((derived (filter (lambda (r) (not (assoc (car r) stated))) (derived-table mixture-elements))))
      (append *heat-carrier-rows* stated derived))))

;;; ── the elemental closure ─────────────────────────────────────────────────
(define (acc-add acc id frac)
  (let ((cell (assoc id acc)))
    (if cell
        (map (lambda (p) (if (eq? p cell) (cons id (+ (cdr cell) frac)) p)) acc)
        (cons (cons id frac) acc))))

;; a molecule's element MASS FRACTIONS, derived from its formula + atomic weights
;; (no magic numbers — co2's carbon fraction is 12.011/44.009, computed).
(define (formula-mass-fractions mol)
  (let ((f (formula mol)) (mm (molar-mass mol)))
    (map (lambda (p) (cons (car p) (/ (* (cdr p) (atomic-weight (car p))) mm))) f)))

;; elemental: spec id → ((element . mass-fraction) …). A MOLECULE's fractions are
;; derived from its formula; a PRODUCT's from the `contains` table; an element is
;; itself. One uniform descent to the conserved element basis. `contains` defaults
;; to the fallback table but a caller (the matter wire) passes a RECIPE-DERIVED
;; map in front of it, so a product's real composition comes from its recipe and
;; the table is consulted only when no recipe derives the product.
(define* (elemental id #:optional (seen '()) #:key (contains *contains*) (stop '()))
  "STOP: ids the descent returns as leaves instead of opening — a molecule basis
   (\"h2o\" read as water, its atoms untouched) over the atom law beneath."
  (cond
    ((member id seen) '())
    ((member id stop) (list (cons id 1.0)))                        ; a tracked molecule, as itself
    ((nuclide? id) (nuclide-leaves id))                            ; nucleons, charge, mass-energy per mole
    ((assoc-ref *formula* id)                                      ; molecule → derived atoms, its heat, its entropy
     (let* ((fr (formula-mass-fractions id)) (h (enthalpy-per-kg id)) (e (entropy-per-kg id))
            (fr (if e (cons (cons "entropy" e) fr) fr)))
       (if h (cons (cons "heat" h) fr) fr)))
    ((assoc-ref contains id)
     => (lambda (edges)
          (let* ((atoms (fold (lambda (edge acc)
                                (let ((child (car edge)) (frac (cdr edge)))
                                  (fold (lambda (e a) (acc-add a (car e) (* frac (cdr e))))
                                        acc (elemental child (cons id seen) #:contains contains #:stop stop))))
                              '() edges))
                 ;; a mixture's own heat and entropy, stated per kilogram for the WHOLE
                 ;; mixture, stand in place of what its parts' rows summed to (the water
                 ;; edge alone says nothing of the cellulose the statement includes)
                 (h (assoc-ref *enthalpy-per-kg* id)) (e (assoc-ref *entropy-per-kg* id))
                 (without (lambda (k r) (remove (lambda (p) (equal? (car p) k)) r))))
            (let* ((r (if e (cons (cons "entropy" e) (without "entropy" atoms)) atoms))
                   (r (if h (cons (cons "heat" h) (without "heat" r)) r)))
              r))))
    (else (list (cons id 1.0)))))                                  ; element leaf

;; substance-content: spec id + quantity → ((tracked-substance . amount) …), keeping
;; only the tracked leaves. '() for specs with no composition. #:contains overrides
;; composition (recipe-derived map in front of the fallback table); #:tracked selects
;; which leaves to keep — the C/N/P/K elements (default, the rift wire) or the human
;; *nutrient-ids* (the reproduction-of-labour-power wire). One closure, two readings.
(define* (substance-content spec qty #:key (contains *contains*) (tracked *element-ids*))
  (filter-map
   (lambda (p) (let ((v (* (cdr p) qty)))
                 (and (member (car p) tracked)
                      (or (> v 0)                                          ; matter: a positive amount, or nothing
                          (and (signed-leaf? (car p)) (not (zero? v))))   ; a signed leaf: heat, entropy, charge, lepton number
                      (cons (car p) v))))
   (elemental spec #:contains contains #:stop tracked)))

;;; ── ONE combinator behind every table-driven closure ────────────────────────
;; Two closures already read through substance-content: the elements (the
;; default CONTAINS/TRACKED, read as a coefficient table straight off *contains*
;; — engine.scm's *composition*, no flow, no owner) and the human nutrients
;; (CONTAINS/TRACKED swapped for *food-nutrition*/*nutrient-ids*, read as PRODUCE
;; flows — `expand-nutrient-flows` below, and `live.scm`'s `eat`). What differs
;; between the two is never the rows themselves; it is only what a row becomes
;; once computed. CLOSURE-ROWS names the first half — the shared primitive,
;; called generically; CLOSURE-FLOWS names the second, for whichever closure's
;; rows are meant to stand as produce flows rather than a bare coefficient
;; table. A new table-driven right states its own table, asks CLOSURE-ROWS for
;; the rows, and — only if it needs flows — CLOSURE-FLOWS for the rest; nothing
;; else in the pipeline changes underneath it.
(define* (closure-rows spec qty #:key (contains *contains*) (tracked *element-ids*) (content #f))
  "SPEC × QTY -> the rows a table-driven closure assigns it: (CONTENT spec qty)
   when CONTENT is given — a domain's own reader, e.g. nutrient-content — else
   the shared primitive over CONTAINS/TRACKED (substance-content), the element
   default. Every table-driven closure reads through here, whichever shape its
   rows become next: a coefficient table, read as-is (elements, *composition*),
   or a set of produce flows (closure-flows, below)."
  (if content (content spec qty) (substance-content spec qty #:contains contains #:tracked tracked)))

(define* (closure-flows rid rows #:key (name (lambda (row) row)) (process rid) (unit "unit"))
  "ROWS (an alist (row . amount) …, from closure-rows) as PRODUCE flows, ids
   RID>row. PROCESS is which process the flow belongs to: RID's own new
   process by default, or an existing one — the original produce flow's own
   process, when a closure rides on top of it instead of standing alone
   (expand-nutrient-flows's use). NAME renames each row before it becomes a
   good: the identity by default, a shared good the way a production
   recipe's own byproduct rows are; or a per-owner name like `row|pid` when
   the caller passes one — a private good, the way a person's own nutrients
   are (`eat`). The one place either shape of flow-producing closure builds
   its flows."
  (map (lambda (nu)
         (flow* (string-append rid ">" (car nu)) 'produce (name (car nu)) (cdr nu) process unit))
       rows))

;; The two halves above are what a closure IS. The two below are what a closure
;; is FOR, wherever its rows are a person's own and a floor stands on them — the
;; shape form-and-substance.typ names once and food and housing both take:
;; a REDUCTION (a claimed form in, the substance a floor reads out) and the
;; BANDS over it (a catalogue's rows, where the person is, each period).
(define* (closure-reduction proc inputs rows #:key (name (lambda (row) row)))
  "PROC as a reduction: it consumes INPUTS ((id-suffix spec qty unit) …) — the
   claimed form, and whatever else the act spends — and produces ROWS (from
   closure-rows) through closure-flows, renamed by NAME (`row|pid` for a
   person's own). → (proc . flows). `eat` is this over a food; `live-in` over
   a night in a dwelling."
  (let ((rid (recipe-process-id proc)))
    (cons proc
          (append (map (lambda (i)
                         (flow* (string-append rid "<" (car i)) 'consume (cadr i) (caddr i) rid (cadddr i)))
                       inputs)
                  (closure-flows rid rows #:name name)))))

(define (closure-bands owner rows deliverable periods where)
  "A catalogue's ROWS ((row floor ceiling w) …) as OWNER's located bands,
   ((row|owner#place@t floor ceiling w) …): one set per period at the cell
   WHERE puts them, so the requirement travels with the body. Guarded to
   DELIVERABLE — a row nothing at hand supplies gets no band (its floor would
   be unfillable, its ceiling inert); saying so is the caller's, in its own
   domain's words."
  (for-each (lambda (r)
              (unless (assoc-ref *leaves* (car r))
                (error "a floor names a quantity no leaf is declared for: a need is a need for substance, and the registry lists every substance a plan holds (catalogues/substances.scm declare-leaf!)" (car r))))
            rows)
  (append-map
   (lambda (t)
     (let ((place (or (where owner t) "?")))
       (filter-map (lambda (r)
                     (and (member (car r) deliverable)
                          (cons (string-append (car r) "|" owner "#" place "@" (number->string t))
                                (cdr r))))
                   rows)))
   periods))

;;; ── SUBSTITUTION as a reading: two forms substitute to the degree their leaf ──
;;; vectors overlap against a floor. Nothing is declared; the registry's rows are
;;; read (docs/observation/physics.md §6).
(define* (leaf-cover target other #:key (content nutrient-content) (against #f))
  "How far a unit of OTHER stands in for a unit of TARGET: the least, over the leaves
   TARGET carries (those AGAINST names, when given: a floor's own rows), of OTHER's
   amount over TARGET's. 1 or more: OTHER covers every leaf of TARGET; 0: some leaf
   TARGET carries OTHER lacks. A TARGET with no leaf read is covered by nothing."
  (let* ((t (content target 1)) (o (content other 1))
         (t (if against (filter (lambda (p) (member (car p) against)) t) t)))
    (if (null? t) 0.0
        (apply min (map (lambda (p) (/ (or (assoc-ref o (car p)) 0.0) (cdr p))) t)))))
(define* (leaf-substitutes target candidates #:key (content nutrient-content) (against #f) (floor 0.0))
  "The CANDIDATES that stand in for TARGET, ((other . cover) …) by cover descending,
   keeping covers above FLOOR and TARGET itself out: what the plan proposes when a
   form runs short, read off the rows and declared by nobody."
  (sort (filter-map (lambda (c)
                      (and (not (equal? c target))
                           (let ((k (leaf-cover target c #:content content #:against against)))
                             (and (> k floor) (cons c k)))))
                    candidates)
        (lambda (a b) (> (cdr a) (cdr b)))))

;;; ── human NUTRIENTS: the reproduction-of-labour-power substances ────────────
;; The CONSUMPTION side of the reproduction of labour-power (playnet.typ §The
;; categories of social reproduction · "Means of consumption"). subsistence-
;; catalogue.scm authors each nutrient's BAND (deficiency floor rda, toxicity
;; ceiling ul, weight w); here we author FOOD COMPOSITION — how much of each a unit
;; of food delivers — so a person's nutrient floor binds to food production through
;; the SAME `contains` closure the rift wire (C/N/P/K) already uses. Food carries
;; BOTH its soil-elements (the rift, leaving the loop) and its human-nutrients
;; (subsistence, entering the person): "the worker and the soil, robbed together
;; under capital, are defended together" (social-material.typ). Nutrients are
;; tracked LEAVES (like elements), so the recursive closure needs no change.
;; The nutrients ARE the catalogue's species base — one list, read here for its
;; spec ids and units, so a nutrient added there is a resource here the same
;; moment. The long names are this file's own, for the resource specification.
(define *nutrient-names*
  '(("energy" . "food energy") ("omega-3" . "omega-3 fatty acids") ("drinking-water" . "drinking water")
    ("vit C" . "vitamin C") ("vit A" . "vitamin A") ("vit D" . "vitamin D") ("vit E" . "vitamin E") ("vit K" . "vitamin K")
    ("vit B1" . "thiamin") ("vit B2" . "riboflavin") ("vit B3" . "niacin") ("vit B5" . "pantothenic acid")
    ("vit B6" . "vitamin B6") ("vit B7" . "biotin") ("vit B12" . "vitamin B12")))
(define *nutrients*
  ;; (id name unit)
  (map (lambda (n) (list (sub-spec n) (or (assoc-ref *nutrient-names* (sub-spec n)) (sub-spec n)) (sub-unit n)))
       (subsistence-species-base)))
(define *nutrient-ids* (map car *nutrients*))
;; the nutrients are leaves of the one registry: what a food carries per kilogram,
;; read by the reproduction closure (`nutrient-content`); unsigned, an amount or nothing
(for-each (lambda (n) (declare-leaf! (car n) 'nutrient (caddr n)
                                     "a nutrient a food carries per kilogram; a floor on it is a need met by any adequate mix of forms"))
          *nutrients*)
;; and the housing rows: what a dwelling carries per person, the standard's own words
(for-each (lambda (r) (declare-leaf! (car r) 'housing (list-ref r 3) (cadr r))) *housing-standard*)

;; FOOD → nutrient content PER UNIT (per kg) — READ, not authored. Each food
;; spec bound in knowledge/food-sources.scm stands for one USDA FoodData
;; Central food (SR Legacy, public domain), whose per-100 g rows are sliced
;; into knowledge/data/fdc-sr-legacy.scm by tools/emit/fdc-snapshot.scm and pinned
;; by the release archive's sha256; the catalogue's nutrient ids map onto FDC's
;; there too (total n-3 = ALA + EPA + DHA + DPA). This table is that slice ×10,
;; one row per bound spec, plus the hand overlay for what the source does not
;; carry (iodine, biotin, and drinking water's own row). A spec bound nowhere
;; carries nothing, and the menu guard says so. Content coefficients, not
;; mass fractions, read via the closure with #:contains *food-nutrition*
;; #:tracked *nutrient-ids*.
;; What the source settles that a remembered figure could not: whole wheat's
;; vitamin K (19 µg/kg against a 90 µg floor), a leafy green's iron, the
;; lysine of a cereal against the 5.1 % of protein the floor follows. What it
;; does not settle, and is stated: cooking losses and retention; selenium,
;; which follows the soil more than the crop (wheat runs 3–70 µg/100 g
;; between plains); the water a food carries, left out on purpose — a floor of
;; litres met from the moisture of grain would ask for twenty kilograms of it,
;; so drinking water is its own row, one kilogram one litre.
(define (fdc-food-row fdc-id)
  "The catalogue's nutrient rows for one FDC food, per KILOGRAM: each catalogue id
   summed over the FDC ids it maps to, scaled from per-100 g; a nutrient the food
   states no amount of, or zero, is no row. One basis for every row of every
   table here, per kilogram or per litre; a scope that counts a food in grams or
   megalitres reads it at its own scale (`unit-scale`)."
  (let ((amounts (or (and=> (assv fdc-id (assq-ref %fdc-slice 'foods)) caddr) '())))
    (filter-map (lambda (m)
                  (let ((total (fold (lambda (id acc) (+ acc (or (assv-ref amounts id) 0))) 0 (cdr m))))
                    (and (> total 0) (cons (car m) (* 10.0 total)))))
                *fdc-nutrients*)))
(define (water-form? spec)
  "A form that is water and nothing else: its composition row is h2o alone. What a
   drinking-water floor is met from; a mixture's moisture (grain, biomass) is a
   form's own and meets no floor."
  (let ((row (assoc-ref *contains* spec)))
    (and (pair? row) (null? (cdr row)) (equal? (car row) '("h2o" . 1.0)))))
(define *water-forms* (filter water-form? (map car *contains*)))
(define *food-nutrition*
  (let ((specs (delete-duplicates (append (map car *food-sources*) (map car *food-macros-hand*) (map car *food-nutrition-hand*) *water-forms*))))
    (map (lambda (spec)
           (let ((src (assoc-ref *food-sources* spec)) (hand (or (assoc-ref *food-nutrition-hand* spec) '())))
             (cons spec (append (if src (fdc-food-row (food-source-id src)) '())
                                ;; a food stated by hand macros carries the energy its macros state, once (fodder)
                                (if src '() (or (and=> (assoc-ref *food-macros-hand* spec) (lambda (m) `(("energy" . ,(assoc-ref m "kcal"))))) '()))
                                hand
                                ;; a water form carries the litre it is, one per kilogram: the
                                ;; nutrient row DERIVED from the molecule row, stated nowhere twice
                                (if (water-form? spec) '(("drinking-water" . 1.0)) '())))))
         specs)))

;; nutrient-content: food spec + qty → ((nutrient . amount) …) via the same closure
;; substance-content runs for C/N/P/K — the reproduction-floor twin of the rift wire.
(define* (nutrient-content food qty)
  (substance-content food qty #:contains *food-nutrition* #:tracked *nutrient-ids*))
(define (food-energy-kwh food qty)
  "The food energy QTY of FOOD carries, as kWh: its kilocalorie row times the
   calorie; 0 for a form with no energy row."
  (* %kwh-per-kcal (or (assoc-ref (nutrient-content food qty) "energy") 0.0)))
(define (flow-sum flows side? per-flow)
  "Σ (PER-FLOW spec qty) over the flows of FLOWS on the side SIDE? holds of
   (input-action?, output-action?): the one sum every reading of a process's sides is
   written with."
  (apply + (map (lambda (sq) (per-flow (car sq) (cdr sq))) (side-quantities flows side?))))
(define (flow-made flows per-flow)
  "What FLOWS make of PER-FLOW's quantity: the produced side over the consumed side."
  (- (flow-sum flows output-action? per-flow) (flow-sum flows input-action? per-flow)))
(define (food-energy-made flows)
  "The food energy, kWh, that FLOWS (recipe flows of substance) make: what the produced
   forms carry over what the consumed ones carry. A form with no energy row carries
   none, so soil, water and light count as nothing here: absence means zero. The
   ONE reading behind the lint that refuses energy from nothing (vf-lint
   `photosynthesis`) and the seeder that states the light (world.scm `world-sunlit`)."
  (flow-made flows food-energy-kwh))
(define (sunlight-for food qty)
  "The sunlight, kWh, that growing QTY of FOOD needs: its food energy over the share
   its pathway stores (*pathways*). A recipe that grows FOOD consumes at least
   this; 0 for a form that carries no energy row, since nothing is then known."
  (/ (food-energy-kwh food qty) (photosynthetic-share food)))
(define (water-for food qty)
  "The water, litres, that growing QTY of FOOD transpires at least: its food energy
   in kilocalories times its pathway's litres per kilocalorie; 0 for a form with no
   energy row."
  (* (litres-per-kcal food) (/ (food-energy-kwh food qty) %kwh-per-kcal)))
;; what a process's PRODUCTS need over what its INPUTS already paid for: a grow
;; draws the light and water of what it makes; a mill, whose flour came in as
;; grain, draws none. Per food, so a maize field and a wheat field each state
;; their own pathway's figures. The one reading behind the lint and the seeder.
(define (needed-over flows per-food) (max 0.0 (flow-made flows per-food)))
(define (light-needed flows) (needed-over flows sunlight-for))
(define (water-needed flows) (needed-over flows water-for))
(define* (leaf-of leaf #:key (contains *contains*))
  "The per-flow reader of LEAF on the composition table: (spec qty) → kilograms of
   LEAF, every form opened to it, none where no row carries it."
  (lambda (spec qty) (or (assoc-ref (substance-content spec qty #:contains contains #:tracked (list leaf)) leaf) 0.0)))
(define* (leaf-made flows leaf #:key (contains *contains*))
  "What FLOWS (recipe flows of substance) make of LEAF on the composition table: the
   produced forms' amount over the consumed forms'. A form with no row carries none."
  (flow-made flows (leaf-of leaf #:contains contains)))
(define* (leaf-needed flows leaf #:key (contains *contains*))
  "What FLOWS' products carry of LEAF over what their inputs brought, kg, none when
   the inputs brought more: what a grow draws from the air or the ground (world.scm
   world-aired, world-rooted); a mill, whose flour's nitrogen came in as grain, draws none."
  (max 0.0 (leaf-made flows leaf #:contains contains)))
(define* (carbon-for flows #:key (contains *contains*))
  "The carbon dioxide, kg, FLOWS fix their carbon from: the carbon needed times CO₂'s
   mass over carbon's. 0 where nothing is made."
  (* (leaf-needed flows "C" #:contains contains) (/ %mm-co2 (atomic-weight "C"))))
(define* (water-drawn flows #:key (contains *contains*))
  "The water, litres, FLOWS (recipe flows of substance) consume: every consumed form read
   on the molecule basis, so a litre of rain, of irrigation and the moisture in a
   feed all count, and a form with no water row counts as none."
  (flow-sum flows input-action? (leaf-of "h2o" #:contains contains)))
(define* (water-split flows #:key (contains *contains*))
  "The water, litres, FLOWS split for the hydrogen their products hold: a leaf builds
   its dry matter's hydrogen out of water and lets the oxygen go, so what the
   products' dry matter carries of hydrogen over what the inputs' brought, over
   water's share of hydrogen, is water that left neither as vapour nor as liquid.
   The hydrogen is read beside the water molecule, so a form's own moisture counts
   as the water it is; none where the inputs brought the hydrogen."
  (let ((dry-h (lambda (spec qty) (or (assoc-ref (substance-content spec qty #:contains contains #:tracked '("H" "h2o")) "H") 0.0))))
    (/ (max 0.0 (flow-made flows dry-h)) (assoc-ref (formula-mass-fractions "h2o") "H"))))
(define* (oxygen-released flows #:key (contains *contains*))
  "The oxygen, kg, FLOWS return to the air: what they drew of it, in the carbon
   dioxide and the water, over what their products and their vapour hold. A leaf
   fixing carbon lets this go; none where the products hold what was drawn."
  (max 0.0 (- (leaf-made flows "O" #:contains contains))))
(define (heat-drawn flows)
  "The heat, kWh, FLOWS (recipe flows of substance) draw through the carriers (*heat-carriers*:
   light, electricity, a fuel's kilowatt-hours): what a process has to lift its water
   with (world.scm world-watered) and to run its stones on. A form that is no carrier
   brings none here: its formation heat is the closure's reading, not the process's power."
  (flow-sum flows input-action? (lambda (spec qty) (if (member spec *heat-carriers*) qty 0.0))))
(define* (water-kept flows #:key (contains *contains*))
  "The water, litres, FLOWS' products keep: the produced forms' h2o; what a grow
   drew and did not keep is what it breathed out (world.scm world-watered)."
  (flow-sum flows output-action? (leaf-of "h2o" #:contains contains)))

;; menu-carries: the nutrients a MENU (food specs) carries at all — the guard
;; set a person's bands are cut to (closure-bands #:deliverable). A floor on a
;; nutrient nothing at hand carries is outside the scope's knowledge: no record
;; of its states it, so no band stands on it, and the caller says so.
(define (menu-carries menu)
  (delete-duplicates (append-map (lambda (fd) (map car (nutrient-content fd 1))) menu)))

;; menu-starves: the floors among ROWS ((nutrient floor ceiling …) …) that no
;; meal off MENU can fill — a DIAGNOSIS, never a guard. A body's energy band has
;; a ceiling (the catalogue's energy-ceiling rule), and a meal under it delivers
;; of nutrient n at most that ceiling times the densest food's n per
;; kilocalorie; a floor above that stands on no meal this body can take, and
;; the solve will say so as infeasibility, which names nothing. This names it.
;; Whole wheat's 19 µg/kg of vitamin K against a 90 µg floor is 4.7 kg of grain
;; a day, three times what a body can eat: a grain-only town starves its people
;; of vitamin K, and the plan cannot be made to say otherwise by growing more
;; grain. A food with no energy row (drinking water) fills whatever it carries;
;; this is the single-nutrient NECESSARY condition, and whether one meal fills
;; every floor at once is the solve's question.
(define (menu-starves menu rows)
  (let* ((contents (map (lambda (fd) (nutrient-content fd 1)) menu))
         (carries (menu-carries menu))
         (energy-row (assoc "energy" rows))
         (ceiling (and energy-row (caddr energy-row) (> (caddr energy-row) 0.0) (caddr energy-row)))
         (per-kcal (lambda (n c)                 ; the most of N a kilocalorie of food C carries; +inf when the food costs none
                     (let ((amount (or (assoc-ref c n) 0.0)) (e (or (assoc-ref c "energy") 0.0)))
                       (cond ((<= amount 0.0) 0.0) ((<= e 0.0) +inf.0) (else (/ amount e)))))))
    (if (not ceiling)
        '()
        (filter-map (lambda (r)
                      (let ((n (car r)) (floor (cadr r)))
                        (and (member n carries) (> floor 0.0)
                             (< (* ceiling (apply max (map (lambda (c) (per-kcal n c)) contents))) (- floor 1e-9))
                             n)))
                    rows))))

;; the nutrient ResourceSpecifications — register alongside substance-specs so a
;; scope's stockbook and recipes can reference nutrients as real resources.
(define nutrient-specs
  (map (lambda (n) (make-resource-specification #:id (car n) #:name (cadr n)
                                                #:default-unit-of-resource (caddr n)))
       *nutrients*))

;; ── substance-EXPANSION: a produce flow of a composed spec INDUCES its substance
;; produce flows, feeding the SOLVE (not just the display wire). So a food recipe
;; that produces `grain` also produces grain's nutrients (energy, protein, iron …)
;; via the `contains` closure — and a reproduction floor on a nutrient binds to the
;; food production that carries it. The SAME idea gives a recipe its C/N/P/K to the
;; rift; here #:content selects the nutrient reading. Aggregate goods (the commune
;; pool). Returns the original flows plus the induced ones. Opt-in: callers expand
;; only when reproduction is enabled, so nothing changes for a plain solve.
(define* (expand-nutrient-flows flows #:key (content nutrient-content))
  (append flows
    (append-map
     (lambda (f)
       (if (memq (recipe-flow-action f) creating-actions)
           (let* ((spec (recipe-flow-resource-conforms-to f))
                  (m    (recipe-flow-resource-quantity f))
                  (qty  (and m (measure-has-numerical-value m))))
             (if (and spec qty (> qty 0))
                 (closure-flows (recipe-flow-id f) (closure-rows spec qty #:content content)
                                 #:process (recipe-flow-recipe-output-of f))   ; not the primary output
                 '()))
           '()))
     flows)))

;; tally-elements: a ledger of (spec . qty) flows → ((element . total-mass) …)
;; over the tracked elements. The one accounting primitive both the conservation
;; CHECK and the composition DERIVATION read: the per-element mass crossing a set
;; of flows. (Their only difference is what they do with consumed − produced.)
(define* (tally-elements flows #:key (contains *contains*) (tracked *element-ids*))
  (fold (lambda (f acc)
          (fold (lambda (p a) (acc-add a (car p) (cdr p)))
                acc (substance-content (car f) (cdr f) #:contains contains #:tracked tracked)))
        '() flows))

;;; ── composition EMERGES from a recipe (proper VF, not a spec table) ─────────
;; A crop's nutrients are what the grow process drew from the soil. So a product's
;; composition is read off its OWN recipe: of the substances the process consumed,
;; the part NOT carried away by its other (substance) outputs is embodied in the
;; primary product, per unit of it. This is conservation made constructive —
;;
;;     embodied[e]  =  Σ consumed[e]  −  Σ other-produced[e]          (per element)
;;     fraction[e]  =  embodied[e] / primary-output-qty
;;
;; — and it eliminates the *contains* guess for any product a recipe makes: two
;; grow methods (more fertiliser, more runoff) are two recipes, hence two
;; compositions, the variable-composition problem faced at the recipe level.
;; `consumed` / `produced` are ((spec . qty) …) from the recipe's own flows;
;; `primary` is the spec whose composition we derive. The known substances
;; (soil-n, crop-runoff, co2, …) expand through the base table; the primary
;; product is the unknown we solve for. Returns (primary . ((element . frac) …))
;; or #f if the primary isn't produced. Pass #:contains a map that already holds
;; UPSTREAM products' derived compositions and a multi-step recipe chains: the
;; caller (recipe-derived-contains) iterates to a fixpoint so biomass → prepped →
;; windrow → HumiSoil carries its nutrients the whole way, one feedstock authored.
(define* (derive-contains consumed produced primary #:key (contains *contains*))
  (let ((qP (assoc-ref produced primary)))
    (and qP (> qP 0)
         (let ((cin  (tally-elements consumed #:contains contains))                    ; drawn in
               (cout (tally-elements (alist-delete primary produced) #:contains contains)))  ; bled to other outputs
           (cons primary
                 (filter-map
                  (lambda (e)
                    (let ((frac (/ (- (or (assoc-ref cin e) 0) (or (assoc-ref cout e) 0)) qP)))
                      (and (not (zero? frac)) (cons e frac))))
                  *element-ids*))))))

;;; ── WHICH COMPOSITION IS IN FORCE, AND WHICH ROWS ARE CLAIMS ────────────────
;; A product's composition has two possible sources and one precedence: the RECIPE
;; that makes it wins, and a `*contains*` row is the fallback for a product no recipe
;; derives. That rule was written three times — twice as `(append derived *contains*)`
;; in service.scm and once as its complement in the conservation sweep — so it is
;; named here.
;;
;; TWO QUESTIONS, and they are not the same question, which is why there are two
;; functions rather than one used twice:
;;
;;   a READER wants the composition in force — the matter wire, and the solve's own
;;   `#:composition`. Derived VALUES win, and they are what it must be handed.
;;
;;   a CONSISTENCY CHECK wants to know which declared rows are CLAIMS. It may not be
;;   handed derived values at all: a derived composition is defined AS the residual
;;   the check is testing, so feeding it back makes the test circular and it passes
;;   by construction. Derivable specs are UNKNOWNS to solve for, and the live claims
;;   are the declared rows about everything else.
(define (composition-in-force derived declared)
  "The composition each spec ACTUALLY has: DERIVED where a recipe derives it,
   DECLARED only where none does. What every READER of a composition is handed."
  (append derived
          (remove (lambda (row) (and (assoc-ref derived (car row)) #t)) declared)))

(define (composition-claims declared derivable)
  "The declared rows that are live CLAIMS — DERIVABLE naming the specs some recipe
   derives. A row for such a spec is the fallback, superseded, and a claim about
   nothing: grow-composition-test asserts the carrot's derived and declared figures
   differ ON PURPOSE so the precedence is observable, and a check fed that row would
   report a deliberate divergence as an inconsistency."
  (remove (lambda (row) (and (member (car row) derivable) #t)) declared))

(define (composition-superseded declared derivable)
  "The complement of `composition-claims` — the rows a recipe overrides. Named so a
   caller can SAY which fallbacks are inert rather than inferring it twice."
  (filter (lambda (row) (and (member (car row) derivable) #t)) declared))

;;; ── the conservation primitive: the integer null space of a balance matrix ──
;; Balancing a reaction, finding a network's independent reactions, and (with a
;; charge row) balancing redox are ALL the same thing: the integer null space of
;; a matrix whose rows are CONSERVED QUANTITIES and columns are SPECIES. We build
;; that matrix once, reduce it once, and read every answer off the null space.

;; in-place reduced row echelon form over exact rationals; returns the pivots as
;; ((row . col) …). A is a vector of m row-vectors, each length n.
(define (rref! A m n)
  (let ((pivots '()))
    (let loop ((r 0) (c 0))
      (when (and (< r m) (< c n))
        (let scan ((i r))
          (cond
            ((>= i m) (loop r (1+ c)))
            ((not (zero? (vector-ref (vector-ref A i) c)))
             (let ((t (vector-ref A r))) (vector-set! A r (vector-ref A i)) (vector-set! A i t))
             (let ((p (vector-ref (vector-ref A r) c)))
               (do ((j 0 (1+ j))) ((= j n)) (vector-set! (vector-ref A r) j (/ (vector-ref (vector-ref A r) j) p))))
             (do ((k 0 (1+ k))) ((= k m))
               (unless (= k r)
                 (let ((f (vector-ref (vector-ref A k) c)))
                   (unless (zero? f)
                     (do ((j 0 (1+ j))) ((= j n))
                       (vector-set! (vector-ref A k) j
                         (- (vector-ref (vector-ref A k) j) (* f (vector-ref (vector-ref A r) j)))))))))
             (set! pivots (cons (cons r c) pivots))
             (loop (1+ r) (1+ c)))
            (else (scan (1+ i)))))))
    (reverse pivots)))

;; rational list → smallest integers (clear denominators by LCM, reduce by GCD),
;; preserving sign.
(define (clear-denominators vals)
  (let* ((den (fold (lambda (v a) (lcm a (denominator v))) 1 vals))
         (ints (map (lambda (v) (* v den)) vals))
         (g (fold gcd 0 (map abs ints))))
    (if (> g 0) (map (lambda (v) (quotient v g)) ints) ints)))

;; the CONSERVED-QUANTITY matrix for a species set: one row per element present,
;; plus a CHARGE row iff any species is charged. Entries are the raw (unsigned)
;; counts — the reactant/product sign convention lives in the solution, not here.
;; Pluggable: `'energy (per-species ΔHf + a heat carrier) and `'isotope (each
;; isotope its own element) would be further row-sources — documented, not built
;; (we have no thermo data; faking a row would be a lie).
(define (species-conserved-rows species)
  (let ((nuclear (filter nuclide? species)))
    (cond
     ((and (pair? nuclear) (= (length nuclear) (length species)))   ; a NUCLEAR set: nucleons, charge, and leptons when any
      (let ((leptons? (any (lambda (s) (not (zero? (nuclide-l s)))) species)))
        (values (if leptons? '(A Z L) '(A Z))
                (list->vector
                 (append (list (list->vector (map nuclide-a species))
                               (list->vector (map nuclide-z species)))
                         (if leptons? (list (list->vector (map nuclide-l species))) '()))))))
     ((pair? nuclear)
      (error "nucleons and elements are two laws: a species set mixes nuclides with molecules" species))
     (else
      (let* ((els (delete-duplicates (append-map (lambda (s) (map car (or (formula s) '()))) species)))
             (charged? (any (lambda (s) (not (zero? (charge s)))) species))
             (rows (append els (if charged? '(charge) '()))))
        (values rows
                (list->vector
                 (map (lambda (q)
                        (list->vector
                         (map (lambda (s) (if (eq? q 'charge) (charge s)
                                              (or (assoc-ref (or (formula s) '()) q) 0)))
                              species)))
                      rows))))))))

;; reaction-basis: a flat species list → the integer null-space BASIS, i.e. the
;; k independent balanced reactions for k degrees of freedom. Each basis vector
;; is a list of SIGNED integer coefficients aligned to `species` (a negative
;; entry = that species sits on the opposite side of the arrow). k = 0 means
;; nothing balances; k = 1 is a unique reaction; k ≥ 2 means the set spans a
;; reaction subspace — not one equation, a network. (Liebig's "uniqueness fails
;; → it's a network" made literal.)
(define (reaction-basis species)
  (let* ((n (length species)))
    (call-with-values (lambda () (species-conserved-rows species))
      (lambda (rows A)
        (let* ((m (length rows))
               (piv (rref! A m n))
               (pivcols (map cdr piv))
               (frees (filter (lambda (c) (not (memv c pivcols))) (iota n))))
          (map (lambda (free)
                 (let ((x (make-vector n 0)))
                   (vector-set! x free 1)
                   (for-each (lambda (pr) (vector-set! x (cdr pr) (- (vector-ref (vector-ref A (car pr)) free)))) piv)
                   (clear-denominators (vector->list x))))
               frees))))))

;;; ── balance a chemical equation: a VIEW of the primitive ───────────────────
;; reactants, products: lists of species ids. Returns ((species . coeff) …) with
;; smallest positive integers when the equation has exactly ONE degree of freedom
;; and separates cleanly into +reactants / +products; else #f — an element (or
;; charge) on only one side, an impossible transmutation (N → Au), or a multi-DOF
;; set (that's a reaction NETWORK — ask reaction-basis instead).
(define (balance-reaction reactants products)
  (let* ((species (append reactants products))
         (rcount (length reactants))
         (basis (reaction-basis species)))
    (and (= (length basis) 1)
         (let* ((v (list->vector (car basis)))
                ;; orient so the first reactant is positive
                (v (if (negative? (vector-ref v 0)) (list->vector (map - (car basis))) v))
                (idx (iota (length species)))
                (react-ok (every (lambda (i) (positive? (vector-ref v i))) (iota rcount)))
                (prod-ok  (every (lambda (i) (negative? (vector-ref v i))) (filter (lambda (i) (>= i rcount)) idx))))
           (and react-ok prod-ok
                (map (lambda (s i) (cons s (abs (vector-ref v i)))) species idx))))))

;; a balanced reaction → VF flows: scale to a basis amount, emit consume/produce
;; with both moles and derived mass. (reactants consumed, products produced.)
;;; ── a reaction as an EXPRESSION: (-> (ch4 (2 o2)) (co2 (2 h2o))) ────────────
;; The equation as a chemist writes it, as data the reader already knows how to
;; take apart: each side a list of species, a species a symbol or string or
;; (count species). `balance-expression` fills the counts from the null space;
;; `expression->flows` turns a stated equation into consume/produce flows in
;; moles and mass, refusing one that does not balance on its conserved rows.
(define (%side-terms side)
  (map (lambda (t) (cond ((pair? t) (cons (format #f "~a" (cadr t)) (car t)))
                         (else (cons (format #f "~a" t) #f))))
       side))
(define (%term->datum sp)
  (let ((id (car sp)) (n (cdr sp)))
    (cond ((and n (= n 1)) (string->symbol id))
          (n (list n (string->symbol id)))
          (else (string->symbol id)))))
(define (balance-expression expr)
  "(-> reactants products) with every count filled from the null space, or #f when
   no single balanced equation exists over the species named."
  (let* ((lhs (map car (%side-terms (cadr expr)))) (rhs (map car (%side-terms (caddr expr))))
         (b (balance-reaction lhs rhs)))
    (and b (list '-> (map (lambda (s) (%term->datum (cons s (assoc-ref b s)))) lhs)
                     (map (lambda (s) (%term->datum (cons s (assoc-ref b s)))) rhs)))))
(define* (expression->flows expr #:key (basis #f) (moles 1) (tol 1e-9))
  "A stated equation → recipe flows in moles, BASIS moles of one species (the
   first reactant when unnamed) setting the scale. An equation whose counts do not
   conserve the species' rows is refused with an error naming the row."
  (let* ((lhs (%side-terms (cadr expr))) (rhs (%side-terms (caddr expr)))
         (count (lambda (sp) (or (cdr sp) 1)))
         (species (append (map car lhs) (map car rhs))))
    (call-with-values (lambda () (species-conserved-rows species))
      (lambda (rows A)
        (let ((n (length species))
              (coef (append (map (lambda (sp) (- (count sp))) lhs) (map count rhs))))
          (for-each (lambda (q i)
                      (let ((sum (apply + (map (lambda (j) (* (vector-ref (vector-ref A i) j) (list-ref coef j))) (iota n)))))
                        (unless (< (abs sum) tol) (error "expression->flows: the equation does not conserve" q expr))))
                    rows (iota (length rows))))
        (let* ((basis-id (or (and basis (format #f "~a" basis)) (car (car lhs))))
               (basis-count (count (or (assoc basis-id (append lhs rhs)) (cons basis-id 1))))
               (scale (/ moles basis-count)))
          (define (flow act sp) (bare-flow act (car sp) (* (count sp) scale) "mol"))
          (append (map (lambda (sp) (flow 'consume sp)) lhs)
                  (map (lambda (sp) (flow 'produce sp)) rhs)))))))

(define (reaction->flows reactants products basis-spec basis-mol)
  (let ((b (balance-reaction reactants products)))
    (and b
         (let ((scale (/ basis-mol (assoc-ref b basis-spec))))
           (define (flow act s) (bare-flow act s (* (assoc-ref b s) scale) "mol"))
           (append (map (lambda (s) (flow 'consume s)) reactants)
                   (map (lambda (s) (flow 'produce s)) products))))))

;;; ── reactions as PLANNER ACTIVITIES: a balanced reaction → a VF recipe ─────
;; The unification: a reaction network IS a plan. A balanced reaction becomes a
;; recipe-process whose consume flows are the reactants and produce flows the
;; products (stoichiometric coefficients, in mol). Fed to the planner's recipe
;; store, the convex engine solves the FLUX distribution that meets a demand
;; under conservation — flux-balance analysis through the engine we already have,
;; no new solver. (Engine: build-located's per-good balance bars ARE S·v=0;
;; solve returns activity levels = fluxes.) Process-spec is omitted — the engine
;; keys on the process id and never dereferences a spec.
(define* (reaction->recipe-process id reactants products #:key (name id) (seq 0))
  (let ((b (balance-reaction reactants products)))
    (and b
         (values
          (make-recipe-process #:id id #:name name #:sequence-group seq)
          (append
           (map (lambda (s)
                  (flow* (string-append id "<" s) 'consume s (assoc-ref b s) id "mol"))
                reactants)
           (map (lambda (s i)
                  (flow* (string-append id ">" s) 'produce s (assoc-ref b s) id "mol" #:primary (= i 0)))
                products (iota (length products))))))))

;; a network of reactions → (values processes flows recipe). Each def is
;; (id reactants products); `product` names the network's deliverable (its
;; primary output). The recipe wraps all processes so the recipe-store walks them.
(define (reaction-network->records defs net-id product)
  (let loop ((defs defs) (procs '()) (flows '()))
    (if (null? defs)
        (values (reverse procs) (reverse flows)
                (make-recipe #:id net-id #:name net-id #:primary-output product
                             #:recipe-processes (map recipe-process-id (reverse procs))
                             #:recipe-exchanges '()))
        (let ((d (car defs)))
          (call-with-values
              (lambda () (reaction->recipe-process (car d) (cadr d) (caddr d)))
            (lambda (p fs) (loop (cdr defs) (cons p procs) (append (reverse fs) flows))))))))

;;; ── conservation: every tracked ELEMENT an internal transformation consumes
;;; must reappear in its outputs ────────────────────────────────────────────
;; The keystone invariant. NOT "lossless": a loss is just a named output (a
;; produce of runoff/CO₂), so lossy recipes balance. Molecules form/break
;; freely — only ELEMENTS are conserved (CO₂'s carbon = the fuel's carbon).
;; BOUNDARY recipes (extraction/fixation in, emission out) cross the system edge
;; and are exempt. flows = recipe flows of substance (balance-flows)
;; (use/work/cite carry no substance and are ignored). Returns #t when balanced,
;; else a list of (element consumed produced) imbalances — so a recipe can never
;; silently make matter vanish: the rift must be routed somewhere explicit. Same
;; consumed−produced residual `derive-contains` attributes to a product; here it
;; is flagged. flows = recipe flows of substance (balance-flows).
(define* (check-conservation flows #:key (boundary? #f) (tol 1e-6) (tracked *element-ids*))
  ;; a READING of `flow-residual`: the same consumed−produced, reported where it is
  ;; nonzero. The consumed/produced totals ride along because a caller wants to see
  ;; both sides of an imbalance, not just its size. TRACKED chooses the conserved
  ;; quantities read: the elements (default), or with *energy-ids* the heat too.
  (if boundary? #t
      (let* ((cin  (tally-elements (side-quantities flows input-action?) #:tracked tracked))
             (cout (tally-elements (side-quantities flows output-action?) #:tracked tracked))
             (bad (filter-map
                   (lambda (er)
                     (and (> (abs (cdr er)) tol)
                          (list (car er) (or (assoc-ref cin (car er)) 0) (or (assoc-ref cout (car er)) 0))))
                   (flow-residual flows #:tracked tracked))))
        (if (null? bad) #t bad))))

;; conservation-reading: one word for a step's balance, as the web face marks
;; its junctions — "closed" when every tracked element consumed reappears in an
;; output, "open" when some leaves unnamed (the rift, at one process), and ""
;; when nothing crossing it is a substance the ledger tracks, so there is
;; nothing to balance.
(define* (conservation-reading flows #:key (boundary? #f) (tracked *element-ids*))
  (begin
    (cond ((and (null? (tally-elements (side-quantities flows input-action?) #:tracked tracked))
                (null? (tally-elements (side-quantities flows output-action?) #:tracked tracked))) "")
          ((eq? #t (check-conservation flows #:boundary? boundary? #:tracked tracked)) "closed")
          (else "open"))))

;;; ── wire shape for the browser ────────────────────────────────────────────
;; [[id colour] …] in *elements* order — exactly app.html's SUBSTANCES list.
(define* (substances->wire #:optional (elems *elements*))
  (map (lambda (e) (list (car e) (caddr e))) elems))

;;; ════════════════════════════════════════════════════════════════════════════
;;; THE COMPOSITION SYSTEM — conservation as one linear system, not a per-recipe check
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; `derive-contains` solves one recipe at a time: composition(primary) = the
;; residual. One equation, one unknown, solved by substitution — so it balances by
;; construction, and `check-conservation` asked of the same recipe can only agree.
;; The circularity is not in either function; it is in treating a recipe as the unit.
;;
;; The unit is the whole recipe set. For each process p and element e, conservation
;; says what goes in comes out:
;;
;;     Σ_{consumed} q · comp(spec, e)  =  Σ_{produced} q · comp(spec, e)
;;
;; with comp(spec, e) UNKNOWN for a spec nobody has stated. Elements, molecules
;; (from their formulae) and declared rows are known and move to the constant side.
;; The system decouples by element — a row for carbon mentions only carbon — so it
;; is one small system per tracked element, and the answer per spec is its RANK:
;;
;;   DETERMINED     a pivot column: the recipes force this value. Conservation is
;;                  definitional here, and that is not a weakness — the value is
;;                  forced, so there is nothing left to check.
;;   FREE           a non-pivot column: under-determined, infinitely many solutions,
;;                  and `derive-contains` picks one. Conservation is VACUOUS here —
;;                  which the system now says, where a per-recipe check passed and
;;                  said nothing.
;;   CONTRADICTORY  either a reduced row reading `0 = c` with c ≠ 0, or a value the
;;                  system determines to be NEGATIVE. The second is the one that
;;                  bites in practice: with a free unknown left, the residual is
;;                  absorbable and the algebra stays consistent — it just has to put
;;                  the missing matter somewhere, and a spec forced to hold −2.8%
;;                  nitrogen is a contradiction about the world rather than about the
;;                  matrix. Both name the recipes responsible.
;;
;; So the guarantee is not "conservation always checks" — a product one recipe makes
;; and nobody measured carries no redundant information, and no method invents any.
;; The guarantee is that every spec gets a DEFINITE verdict, and nothing passes
;; vacuously in silence. Over-determination is what makes a check possible, and it
;; arrives from three places: a declared measurement, a second recipe for the same
;; product, or mass closure.
;;
;; A contradiction NAMES ITSELF. Pivoting carries an identity block alongside, so a
;; row that reduces to `0 = c` still records which original rows combined to make
;; it — a Farkas certificate. Its nonzero entries are the inconsistent set, which is
;; what makes a global solve blameable: "these three processes disagree" rather than
;; "the system is red".

(define (exact-q x)
  "A quantity as an exact rational, to a millionth. Rank is a question about
   equality, and equality between floats is not a question with an answer — so the
   coefficients are rationalised ONCE, here, and every verdict downstream is exact.
   Recipe quantities are authored decimals (0.075, 44.0), so the simplest rational
   within a millionth is the number the author wrote."
  (if (exact? x) x (rationalize (inexact->exact x) 1/1000000)))

(define (rref-augmented! A m npiv ntot)
  "Row-reduce A pivoting only within the first NPIV columns, applying every row
   operation across all NTOT. The extra columns ride along: the constant side, and an
   identity block recording which original rows each reduced row is made of."
  (let ((pivots '()))
    (let loop ((r 0) (c 0))
      (when (and (< r m) (< c npiv))
        (let scan ((i r))
          (cond
           ((>= i m) (loop r (1+ c)))
           ((not (zero? (vector-ref (vector-ref A i) c)))
            (let ((t (vector-ref A r))) (vector-set! A r (vector-ref A i)) (vector-set! A i t))
            (let ((p (vector-ref (vector-ref A r) c)))
              (do ((j 0 (1+ j))) ((= j ntot))
                (vector-set! (vector-ref A r) j (/ (vector-ref (vector-ref A r) j) p))))
            (do ((k 0 (1+ k))) ((= k m))
              (unless (= k r)
                (let ((f (vector-ref (vector-ref A k) c)))
                  (unless (zero? f)
                    (do ((j 0 (1+ j))) ((= j ntot))
                      (vector-set! (vector-ref A k) j
                                   (- (vector-ref (vector-ref A k) j)
                                      (* f (vector-ref (vector-ref A r) j)))))))))
            (set! pivots (cons (cons r c) pivots))
            (loop (1+ r) (1+ c)))
           (else (scan (1+ i)))))))
    (reverse pivots)))

(define* (composition-known? spec #:optional (contains *contains*))
  "Is this spec's composition STATED — by a formula, a declared row, or by being a
   tracked element itself? Everything else is an unknown for the system to solve."
  (or (and (assoc-ref *formula* spec) #t)
      (and (assoc-ref contains spec) #t)
      (and (member spec *element-ids*) #t)))

(define* (composition-fraction spec element #:optional (contains *contains*))
  "How much of ELEMENT a unit of SPEC carries, for a spec whose composition is known."
  (or (assoc-ref (elemental spec #:contains contains) element) 0))

(define* (composition-system processes #:key (contains *contains*) (tracked *element-ids*))
  "Conservation over the whole recipe set, as one linear system per tracked element.

   PROCESSES: ((id flow …) …) with action ∈ consume|produce — the same
   shape `check-conservation` takes, one level up.

   Returns an alist:
     (determined    . ((spec element value) …))     forced by the recipes
     (free          . ((spec element) …))            under-determined: no check possible
     (contradictions . (((element . e) (residual . r) (processes . (id …))
                         [(spec . s) (value . v)]) …))   ; spec/value on a negative

   A contradiction's PROCESSES are the minimal inconsistent set — the rows whose
   combination reduces to `0 = residual` — so the finding points at recipes rather
   than at the system."
  ;; net_p(s) = consumed − produced, per process, per spec. Every value below
  ;; (SPECS, UNKNOWNS, ROWS, ROW-NETS, m, n) is ELEMENT-INDEPENDENT — net-of
  ;; never reads ELEMENT, only the process/spec structure — so they are
  ;; computed ONCE here, not once per tracked element (dozens) below. ROW-NETS
  ;; is one hash per row (spec → net), built by a single pass over that row's
  ;; own flows, replacing a fresh O(row-flows) `net-of` fold PER (row, spec)
  ;; PAIR PER ELEMENT: the matrix build was O(elements × rows × unknowns ×
  ;; row-flows) for a result that never depended on elements × row-flows at all.
  (define (net-of flows spec)
    (fold (lambda (f a)
            (if (equal? spec (flow-spec f))
                (if (input-action? (flow-action f)) (+ a (exact-q (flow-qty f))) (- a (exact-q (flow-qty f))))
                a))
          0 flows))
  (define (row-net-table flows)
    (let ((h (make-hash-table)))
      (for-each (lambda (f)
                  (let* ((spec (flow-spec f))
                         (delta (if (input-action? (flow-action f)) (exact-q (flow-qty f)) (- (exact-q (flow-qty f))))))
                    (hash-set! h spec (+ (hash-ref h spec 0) delta))))
                flows)
      h))
  (let* ((specs (delete-duplicates (append-map (lambda (p) (map flow-spec (cdr p))) processes)))
         (unknowns0 (filter (lambda (s) (not (composition-known? s contains))) specs))
         (rows (filter (lambda (p) (pair? (cdr p))) processes))
         (row-nets (map (lambda (p) (row-net-table (cdr p))) rows))
         ;; a spec whose net is zero in every process constrains nothing
         (unknowns (filter (lambda (s) (any (lambda (h) (not (zero? (hash-ref h s 0)))) row-nets))
                           unknowns0))
         (m (length rows)) (n (length unknowns))
         (det '()) (free '()) (bad '()))
    (for-each
     (lambda (element)
         ;; n = 0 is not nothing to do — it is the FULLY DECLARED case, where every
         ;; composition is stated and each row must balance on its own. That is the
         ;; most over-determined the system gets, so it is where a contradiction is
         ;; most certain and most narrowly blamed.
         (when (> m 0)
           (let* ((ntot (+ n 1 m))
                  (A (list->vector
                      (map (lambda (p i h)
                             (let ((v (make-vector ntot 0)))
                               ;; the unknown coefficients
                               (for-each (lambda (s j) (vector-set! v j (hash-ref h s 0)))
                                         unknowns (iota n))
                               ;; the constant side: what the KNOWN specs contribute,
                               ;; moved across the equals sign
                               (vector-set! v n
                                            (- (fold (lambda (s a)
                                                       (+ a (* (hash-ref h s 0)
                                                               (exact-q (composition-fraction s element contains)))))
                                                     0
                                                     (filter (lambda (s) (composition-known? s contains)) specs))))
                               ;; the certificate block
                               (vector-set! v (+ n 1 i) 1)
                               v))
                           rows (iota m) row-nets)))
                  (piv (rref-augmented! A m n ntot))
                  (pivcols (map cdr piv)))
             ;; a reduced row with no unknowns left and a nonzero constant is a
             ;; contradiction, and its certificate names the rows that made it
             (do ((i 0 (1+ i))) ((= i m))
               (let ((row (vector-ref A i)))
                 (when (and (every (lambda (j) (zero? (vector-ref row j))) (iota n))
                            (not (zero? (vector-ref row n))))
                   (set! bad
                         (cons (list (cons 'element element)
                                     (cons 'residual (exact->inexact (vector-ref row n)))
                                     (cons 'processes
                                           (filter-map (lambda (k)
                                                         (and (not (zero? (vector-ref row (+ n 1 k))))
                                                              (car (list-ref rows k))))
                                                       (iota m))))
                               bad)))))
             ;; A pivot column is DETERMINED only when its row has nothing left in the
             ;; FREE columns. With a free variable still in the row the pivot is
             ;; PARAMETRIC — expressed in terms of that variable, not pinned — and the
             ;; constant is one coefficient of an expression rather than a value. So
             ;; the negativity test does not apply to it: its sign is whatever the free
             ;; variable makes it, and calling that a contradiction would report a
             ;; finding against an under-determined system, which is the one thing this
             ;; rewrite exists to stop doing.
             (define (pinned? r)
               (every (lambda (j) (or (memv j pivcols) (zero? (vector-ref (vector-ref A r) j))))
                      (iota n)))
             ;; A determined value that comes out NEGATIVE is the second kind of
             ;; contradiction, and the one that bites hardest in practice: the system
             ;; is satisfiable, but only by a composition no matter can have. The
             ;; residual had to go somewhere and the only unknown left absorbed it — so
             ;; the finding names that spec, which is more useful than the residual.
             (for-each (lambda (s j)
                         (if (and (memv j pivcols)
                                  (pinned? (car (find (lambda (p) (= (cdr p) j)) piv))))
                             (let* ((r (car (find (lambda (p) (= (cdr p) j)) piv)))
                                    (row (vector-ref A r))
                                    (v (exact->inexact (vector-ref row n))))
                               (if (< v -1e-9)
                                   (set! bad
                                         (cons (list (cons 'element element)
                                                     (cons 'spec s)
                                                     (cons 'value v)
                                                     (cons 'residual v)
                                                     (cons 'processes
                                                           (filter-map
                                                            (lambda (k)
                                                              (and (not (zero? (vector-ref row (+ n 1 k))))
                                                                   (car (list-ref rows k))))
                                                            (iota m))))
                                               bad))
                                   (set! det (cons (list s element v) det))))
                             (set! free (cons (list s element) free))))
                       unknowns (iota n)))))
     tracked)
    (list (cons 'determined (reverse det))
          (cons 'free (reverse free))
          (cons 'contradictions (reverse bad)))))

;;; ── ONE RESIDUAL, THREE READINGS ────────────────────────────────────────────
;; `consumed − produced`, per element, is the only arithmetic in this file's
;; conservation half, and three things read it:
;;
;;   derive-contains       ATTRIBUTES it to the primary product (composition)
;;   check-conservation     FLAGS it                              (a check)
;;   composition-system     SOLVES for the compositions that zero it (the rank)
;;
;; They differ in what they do with it, never in what it is — so it is computed
;; once, here, and each of them is a reading rather than a re-derivation.
(define* (flow-residual flows #:key (contains *contains*) (tracked *element-ids*))
  "(recipe flows of substance) → ((element . consumed−produced) …) over TRACKED. The one
   place the conservation residual is computed."
  (begin
    (let ((cin  (tally-elements (side-quantities flows input-action?) #:contains contains #:tracked tracked))
          (cout (tally-elements (side-quantities flows output-action?) #:contains contains #:tracked tracked)))
      (filter-map (lambda (e)
                    (let ((i (or (assoc-ref cin e) 0)) (o (or (assoc-ref cout e) 0)))
                      (cons e (- i o))))
                  tracked))))

;;; ── the CLOSED composition map, for the solve ───────────────────────────────
;; The engine takes composition as policy and holds no chemistry: it looks a spec up
;; in a flat map and multiplies. So the recursive closure (`elemental` — a product
;; through its parts through their elements) must be run BEFORE it gets there, and it
;; is run here, where it lives. Nothing engine-side re-walks `contains`.
(define* (closed-composition specs #:key (contains *contains*) (tracked *element-ids*))
  "SPECS → ((spec (element . mass-fraction) …) …), the closure already taken, in the
   shape `ingest-located! #:composition` reads. Specs carrying none of TRACKED are
   omitted — an absent entry and a zero entry mean the same thing to the solve."
  (filter-map
   (lambda (spec)
     (let ((edges (filter (lambda (p) (member (car p) tracked))
                          (elemental spec #:contains contains #:stop tracked))))
       (and (pair? edges) (cons spec edges))))
   (delete-duplicates specs)))

;;; ── HOW FAR A STATED FIGURE MAY STAND FROM THE THING ────────────────────────
;; A figure is stated with its bar. The bar belongs to the DATA: it says how far the
;; figure may stand from the thing it describes, as a share of the figure, per leaf,
;; and it is stated once per SOURCE, since a figure is as good as where it came from.
;; A row that knows better states its own under "±" (a reading of this batch), and
;; that stands in place of its source's.
;;
;; The bar is an INTERVAL and no distribution: a row stands for a class (wheat, not
;; this sack), and how the class's members scatter inside the bar is not known, so
;; no probability is claimed of it. Bars add as intervals add, each flow at its own
;; bar at once, which is the widest reading: the closure REFUSES by them, and a
;; refusal has to hold whatever the truth inside the bars turns out to be. The
;; robust wall reads the same kind of set with the other quantifier: a promise must
;; hold for every truth in the set, a refusal for none (docs/observation/physics.md).
;;
;; [DRAFT] figures, derivation named:
;;   formula   a molecule's atoms are its definition and its enthalpy of formation is
;;             tabulated to four figures: no bar. Water is a molecule, so the water in
;;             any form carries none, and heat is judged at the scale of the dry
;;             matter's heat of combustion, where the uncertainty is.
;;   release   the elements are the macronutrients' at their class's run: carbon
;;             within three percent across proteins, fats and carbohydrates; hydrogen
;;             and oxygen five; nitrogen ten, the protein factor running 5.2 to 6.4
;;             about 6.25 (Jones 1931; FAO 2003). Phosphorus and potassium are read
;;             off one sample and two samples of one food stand a quarter apart. The
;;             gross heat is Merrill and Watt's factors, three percent.
;;   hand      a mixture stated at the run of its class: wider on every leaf.
(define *precision*
  '((formula . ())
    (release . (("C" . 0.03) ("H" . 0.05) ("O" . 0.05) ("N" . 0.10) ("P" . 0.25) ("K" . 0.25) ("heat" . 0.03)))
    (hand    . (("C" . 0.15) ("H" . 0.15) ("O" . 0.15) ("N" . 0.25) ("P" . 0.35) ("K" . 0.35) ("heat" . 0.10)))))
(define (mixture-source id)
  "Where form ID's stated mixture came from: 'hand, 'release, its alias's; #f where
   nothing is stated."
  (cond ((or (assoc-ref *mixtures-hand* id) (assoc-ref *food-macros-hand* id)) 'hand)
        ((food-macros id) 'release)
        ((assoc-ref *composition-aliases* id) => mixture-source)
        (else #f)))
(define (unread-key leaf) (string-append "?" leaf))    ; a row that holds LEAF in an amount nobody has stated says so under this
(define (unread-key? k) (and (string? k) (string-prefix? "?" k)))
(define* (heat-known? id #:optional (seen '()) #:key (contains *contains*))
  "Is form ID's heat stated: a carrier's, a molecule's or a mixture's formation, a row
   that states its own, or a form made wholly of forms whose heat is? A form holding
   bare atoms with no formation stated holds heat nobody has said, and the first law
   on heat is unread where it enters (absence means zero of an element; of heat it
   means unknown)."
  (let ((row (assoc-ref contains id)))
    (cond ((member id seen) #t)
          ((member id *heat-carriers*) #t)
          ((enthalpy id) #t)
          ((and (pair? row) (assoc "heat" row)) #t)
          ((pair? row)
           (every (lambda (edge) (or (slack-key? (car edge)) (unread-key? (car edge))
                                     (and (or (assoc-ref contains (car edge)) (assoc-ref *formula* (car edge)))
                                          (heat-known? (car edge) (cons id seen) #:contains contains))))
                  row))
          (else #f))))
(define (slack-key leaf) (string-append "±" leaf))     ; a row's bar on LEAF rides the row, under the leaf's name behind the sign
(define (slack-key? k) (and (string? k) (string-prefix? "±" k)))
(define (row-bars row) (filter (lambda (e) (slack-key? (car e))) row))                      ; a row's own bars, as it carries them
(define (bars->slack row) (map (lambda (e) (cons (substring (car e) 1) (cdr e))) (row-bars row)))   ; …read back as ((leaf . bar) …)
(define (slack->bars slack) (map (lambda (p) (cons (slack-key (car p)) (cdr p))) slack))
(define (mixture-slack id)
  "((leaf . bar) …) per kilogram of form ID: how far each stated figure may stand from
   the thing, in the leaf's own unit. An element's bar is its share of the dry
   matter's figure; heat's is its share of the gross heat of combustion; the water
   carries none. '() where nothing is stated."
  (let ((row (mixture-of id)))
    (if (not row) '()
        (let* ((rel (or (assoc-ref row "±") (assoc-ref *precision* (mixture-source id)) '()))
               (r (lambda (leaf) (or (assoc-ref rel leaf) 0.0))))
          (filter (lambda (p) (> (cdr p) 0.0))
                  (append (map (lambda (e) (cons e (* (r e) (or (assoc-ref row e) 0.0)))) *element-ids*)
                          (list (cons "heat" (* (r "heat") (/ (or (assoc-ref row "gross-kj") 0.0) %kj-per-kwh))))))))))
(define* (form-slack id #:optional (seen '()) #:key (contains *contains*))
  "((leaf . bar) …) per kilogram of any form ID: a stated mixture's own (mixture-slack),
   none for a molecule, and for a form made of other forms the sum of what its parts
   carry, each by its share."
  (cond ((member id seen) '())
        ((mixture-of id) (mixture-slack id))
        ((assoc-ref *formula* id) '())
        ((assoc-ref contains id)
         => (lambda (edges)
              (fold (lambda (edge acc)
                      (if (slack-key? (car edge)) acc
                          (fold (lambda (s a) (acc-add a (car s) (* (abs (cdr edge)) (cdr s))))
                                acc (form-slack (car edge) (cons id seen) #:contains contains))))
                    '() edges)))
        (else '())))

;;; ── ONE UNIT PER SPEC, at the door ──────────────────────────────────────────
;; A spec is counted in one unit and a flow may be written in another (a hundred
;; grams of a salt the scope counts in kilograms). The flow is restated in its
;; spec's unit through the one bridge before anything reads it, so the solve, the
;; body and the closure all take the same number for the same thing.
(define %unit-ratios (make-hash-table))     ; (from . to) → the ratio, asked of the bridge once
(define (unit-ratio from to)
  "How many TO one FROM is, or #f where the two do not convert."
  (let* ((key (cons from to)) (known (hash-get-handle %unit-ratios key)))
    (if known (cdr known)
        (let ((k (unit-to from to)))
          (hash-set! %unit-ratios key k)
          k))))
(define (flows-in-spec-units flows units)
  "Flow records FLOWS with every consume and produce restated in the unit its spec
   is counted in, UNITS as ((spec . unit) …). A flow already in that unit, of a spec
   UNITS does not name, or in a unit that does not convert to it stands as written
   (the lint `unit-mismatch` names the last)."
  (map (lambda (f)
         (let* ((m (recipe-flow-resource-quantity f)) (u (and m (measure-has-unit m)))
                (want (assoc-ref units (recipe-flow-resource-conforms-to f)))
                (k (and u want (not (equal? u want)) (memq (recipe-flow-action f) *flow-actions*) (unit-ratio u want))))
           (if k
               (copy-recipe-flow f #:resource-quantity (make-measure (* k (measure-has-numerical-value m)) want))
               f)))
       flows))

;;; ── THE COMPOSITION A SCOPE STANDS ON, assembled once ───────────────────────
;; What a recipe makes is what it drew less what its other outputs carry: a product's
;; composition is derived from its process, chained through the store, and stands in
;; front of the table. The live door hands the result to the solve (live.scm
;; scope-composition) and the lint reads the same rows at the recipe store
;; (dsl/vf-lint.scm `creates`), so the law a plan is refused by is the law a recipe is
;; written against. Every row carries its bars beside its figures (slack-key), so
;; the solve, which holds no chemistry, is handed how good the chemistry is with it.
(define (recipe-flows->derivation pid flows)
  "Process PID's flow records → (pid consumed produced primary), CONSUMED and
   PRODUCED as ((spec . qty) …) in the rows' basis, PRIMARY the spec its residual
   lands on (the flow marked primary, else the first produced); #f for a process
   that produces nothing."
  (let* ((side (lambda (action) (filter (lambda (f) (and (eq? action (recipe-flow-action f)) (recipe-flow-resource-conforms-to f))) flows)))
         ;; one entry a spec, its flows summed: a process drawing a thing twice drew their sum
         (pairs (lambda (fs) (reverse (fold (lambda (f acc) (acc-add acc (recipe-flow-resource-conforms-to f) (flow-basis-quantity f))) '() fs))))
         (outs (side 'produce))
         (prim (and (pair? outs) (or (find recipe-flow-is-primary outs) (car outs)))))
    (and prim (list pid (pairs (side 'consume)) (pairs outs) (recipe-flow-resource-conforms-to prim)))))
(define* (derive-compositions procs #:key (contains *contains*) (given '()))
  "PROCS as ((pid consumed produced primary) …). GIVEN names the specs whose rows in
   CONTAINS are somebody's word and stand as they are. Three values: the derived rows keyed
   by spec, the same keyed (pid . spec), one per process, and the specs the recipes
   leave undetermined.

   What a store's recipes say of composition is ONE linear system, the one
   `composition-system` checks: a process's primary holds what the process drew less
   what its other outputs hold, over what it makes. This is its SOLUTION, read with
   the recipe's own word on where the residual lands (the flow marked primary).

   A CHAIN is solved by substitution, in the order the recipes depend: a spec is
   derived once every spec its makers draw or co-produce is. What can never come up
   in that order lies on a CYCLE or draws on one (wax recovered and remelted into
   the melt it came from, a warmed form relaxing to its base and warmed again), and
   a cycle is solved exactly, in rationals, by the row reduction the system is
   checked with. A cycle has three ends and each is a finding:
     it SETTLES     a loop that loses each turn and is fed from outside has a steady
                    composition, and this is it;
     NOTHING PINS   a closed loop holds whatever was first put in it. The recipes do
                    not say, so the spec is undetermined: what is stated of it
                    stands, and where nothing is, its leaves are unread;
     it GROWS       the recipes make matter each turn, which only a negative
                    composition could balance. A product holds no negative amount,
                    so the row holds none of that leaf and the closure refuses the
                    process that then carries out more than it draws.

   AN OUTPUT NOBODY HAS DESCRIBED is an unknown of the system like any product: what
   the recipes force of it is derived, and where they force nothing (a process
   making two things of which neither is stated) both are undetermined. Of a thing
   that is only ever drawn, absence means zero; of a thing that is made, it means
   nobody has said.

   A POOL. A spec several recipes make is drawn from a pool whose mixture is the
   plan's to choose, so its row is their mean and their spread is its bar: whatever
   mixture the plan draws lies inside it. A derived row carries what its inputs
   carried: its bar on a leaf is the bars of all it drew and all its other outputs
   hold, over what it makes, so a chain hands its uncertainty on and adds none."
  (define primaries (remove (lambda (s) (member s given)) (delete-duplicates (map cadddr procs))))
  (define (makers s) (filter (lambda (p) (equal? s (cadddr p))) procs))
  ;; made beside a primary, by nobody's primary, and described by nobody
  (define bare
    (remove (lambda (t) (or (member t primaries) (member t given) (composition-known? t contains)))
            (delete-duplicates (append-map (lambda (p) (map car (caddr p))) procs))))
  (define (made p) (assoc-ref (caddr p) (cadddr p)))
  (define (others p) (alist-delete (cadddr p) (caddr p)))
  (define (slack-of spec known)             ; ((leaf . bar) …) per kilogram: a derived row's own, else the table's
    (let ((row (assoc-ref known spec)))
      (if row (bars->slack row) (form-slack spec #:contains contains))))
  (define (leaves-of row) (remove (lambda (e) (slack-key? (car e))) row))
  ;; what ONE process makes of its primary under KNOWN: the leaves it holds and their bars, or #f
  (define (made-row p known)
    (let ((row (derive-contains (cadr p) (caddr p) (cadddr p) #:contains (append known contains))))
      (and row (made p) (> (made p) 0)
           (let ((held (filter (lambda (e) (> (cdr e) 0.0)) (cdr row))))
             (and (pair? held)
                  (append held
                          (map (lambda (e)
                                 (cons (slack-key (car e))
                                       (/ (apply + (map (lambda (f) (* (abs (cdr f)) (or (assoc-ref (slack-of (car f) known) (car e)) 0.0)))
                                                        (append (cadr p) (others p))))
                                          (made p))))
                               held)))))))
  ;; a POOL's row under KNOWN: its makers' mean, their spread added to its bars
  (define (pool-row s known)
    (let ((rows (filter-map (lambda (p) (made-row p known)) (makers s))))
      (cond ((null? rows) #f)
            ((null? (cdr rows)) (cons s (car rows)))
            (else
             (let* ((k (length rows))
                    (leaves (delete-duplicates (append-map (lambda (r) (map car (leaves-of r))) rows)))
                    (of (lambda (r key) (or (assoc-ref r key) 0.0))))
               (cons s
                     (append-map
                      (lambda (e)
                        (let* ((vs (map (lambda (r) (of r e)) rows)) (mean (/ (apply + vs) k)))
                          (list (cons e mean)
                                (cons (slack-key e)
                                      (+ (/ (apply + (map (lambda (r) (of r (slack-key e))) rows)) k)
                                         (apply max (map (lambda (v) (abs (- v mean))) vs)))))))
                      leaves)))))))
  ;; what a spec's row DEPENDS on: the derived specs its makers draw or make beside it.
  ;; Memoized on S: depends-on is loop-invariant per spec (PRIMARIES, BARE and
  ;; PROCS are all fixed for this whole call), but the main loop below re-checks
  ;; every still-waiting spec's readiness on EVERY round until one is ready —
  ;; recomputing it from scratch each time made the outer loop's P-scanning
  ;; (inside MAKERS) effectively O(waiting² × procs) instead of O(waiting × procs).
  (define %depends-on-memo (make-hash-table))
  (define (depends-on s)
    (or (hash-ref %depends-on-memo s #f)
        (let ((d (delete-duplicates
                  (filter (lambda (t) (or (member t primaries) (member t bare)))
                          (append-map (lambda (p) (map car (append (cadr p) (others p)))) (makers s))))))
          (hash-set! %depends-on-memo s d)
          d)))
  ;; THE CYCLE, solved: over the specs U still moving, with SETTLED in front of the
  ;; table as what is known, one system per leaf for the amounts and one for the bars
  (define (solve-cycle eqs settled)
    (let* ((U (append eqs (filter (lambda (t) (any (lambda (s) (member t (depends-on s))) eqs)) bare)))   ; an equation a primary, a column an unknown
           (m (length eqs)) (n (length U)) (known (lambda (spec) (not (member spec U))))
           (index (lambda (spec) (list-index (lambda (u) (equal? u spec)) U)))
           (amount (lambda (leaf) (lambda (spec)
                                    (exact-q (or (assoc-ref (tally-elements (list (cons spec 1.0)) #:contains (append settled contains)
                                                                            #:tracked (list leaf))
                                                            leaf)
                                                 0)))))
           (bar (lambda (leaf) (lambda (spec) (exact-q (or (assoc-ref (slack-of spec settled) leaf) 0)))))
           ;; one reduction: SIGN is how an other output's share enters (−1 for an amount
           ;; it carries off, +1 for a bar it adds); OF reads what a known spec holds
           (reduce (lambda (sign of)
                     (let ((A (list->vector (map (lambda (_) (make-vector (+ n 1) 0)) eqs))))
                       (for-each
                        (lambda (s i)
                          (let ((row (vector-ref A i)) (ps (filter (lambda (p) (and (made p) (> (made p) 0))) (makers s))))
                            (vector-set! row i 1)
                            (for-each
                             (lambda (p)
                               (let ((w (/ 1 (* (length ps) (exact-q (made p))))))
                                 (define (enter! pairs weight)
                                   (for-each (lambda (f)
                                               (let ((q (* w weight (abs (exact-q (cdr f))))))
                                                 (if (known (car f))
                                                     (vector-set! row n (+ (vector-ref row n) (* q (of (car f)))))
                                                     (let ((j (index (car f)))) (vector-set! row j (- (vector-ref row j) q))))))
                                             pairs))
                                 (enter! (cadr p) 1)
                                 (enter! (others p) sign)))
                             ps)))
                        eqs (iota m))
                       (let* ((piv (rref-augmented! A m n (+ n 1))) (cols (map cdr piv)))
                         (filter-map
                          (lambda (s j)
                            (let ((p (find (lambda (p) (= (cdr p) j)) piv)))
                              (and p
                                   (let ((row (vector-ref A (car p))))
                                     ;; pinned: nothing free is left in its row, so the recipes force it
                                     (and (every (lambda (c) (or (memv c cols) (zero? (vector-ref row c)))) (iota n))
                                          (cons s (exact->inexact (vector-ref row n))))))))
                          U (iota n))))))
           (per-leaf (map (lambda (e) (list e (reduce -1 (amount e)) (reduce 1 (bar e)))) *element-ids*))
           ;; a spec is determined where the recipes force every leaf of it and every bar
           (forced (filter (lambda (s) (every (lambda (l) (and (assoc s (cadr l)) (assoc s (caddr l))
                                                               (>= (assoc-ref (caddr l) s) 0.0)))
                                              per-leaf))
                           U)))
      (values
       (filter-map (lambda (s)
                     (let ((held (filter-map (lambda (l) (let ((v (assoc-ref (cadr l) s))) (and (> v 0.0) (cons (car l) v)))) per-leaf)))
                       (and (pair? held)
                            (cons s (append held (map (lambda (e) (cons (slack-key (car e)) (assoc-ref (caddr (assoc (car e) per-leaf)) s))) held))))))
                   forced)
       (remove (lambda (s) (member s forced)) U))))
  (define (finish by-spec undetermined)
    (values by-spec
            (append-map (lambda (s)
                          (if (or (member s undetermined) (not (assoc s by-spec))) '()
                              (filter-map (lambda (p) (let ((row (made-row p by-spec))) (and row (cons (cons (car p) s) row))))
                                          (makers s))))
                        primaries)
            undetermined))
  ;; DONE as a hash-set, not a list `member`-scanned per dependency per round:
  ;; the same object throughout (mutated, never rebuilt), so a round's
  ;; readiness check costs O(deps) instead of O(deps × |done|).
  (let ((done (make-hash-table)))
    (let loop ((waiting primaries) (known '()))
      (let ((ready (find (lambda (s) (every (lambda (t) (hash-ref done t #f)) (depends-on s))) waiting)))
        (cond (ready
               (hash-set! done ready #t)
               (let ((row (pool-row ready (append known (filter (lambda (r) (member (car r) given)) contains)))))
                 (loop (delete ready waiting) (if row (append known (list row)) known))))
              ((null? waiting) (finish known '()))
              (else
               (call-with-values (lambda () (solve-cycle waiting known))
                 (lambda (solved undetermined) (finish (append known solved) undetermined)))))))))
(define* (composition-of-scope procs #:key (stated '()) (units '()) (contains *contains*))
  "The composition a scope stands on, in the shape the solve reads: rows keyed by
   spec (closed to the leaves, the elements and heat) for what a process draws, and
   rows keyed (pid . spec) for what a process makes, each with its bars. PROCS are
   its recipes' processes (recipe-flows->derivation), STATED the rows it states on
   its own specs, UNITS ((spec . unit) …) what it counts each spec in. What the scope
   states is its word and stands first with the bars it states (a reading narrows
   its own bar; a row stating none is taken at its word); a recipe's derivation
   fills in where nothing is stated; the table is the fallback.

   ONE BASIS, scaled last. Everything is derived and closed per kilogram or litre:
   the scope's own rows are read there first (what it states per unit of its spec,
   over what a unit is), and each finished row is scaled to its spec's unit at the
   end through the one bridge. So a row is per UNIT of the spec everywhere, a
   molecule counted in grams as much as a mixture, and a form made of forms is
   closed through figures of one kind. Every spec the scope names is closed, and
   every molecule the table knows, so what a recipe draws or a body breathes out
   carries its formula's row and no form a flow touches is weightless."
  (let* ((scale-of (lambda (spec) (let ((k (unit-scale (assoc-ref units spec)))) (if (and k (> k 0.0)) k 1.0))))
         (times (lambda (k entries) (if (= k 1.0) entries (map (lambda (e) (cons (car e) (* k (cdr e)))) entries))))
         (said (map (lambda (row) (cons (car row) (times (/ 1.0 (scale-of (car row))) (cdr row)))) stated)))   ; the scope's word, per kilogram
    (call-with-values (lambda () (derive-compositions procs #:contains (append said contains) #:given (map car said)))
      (lambda (by-spec by-process undetermined)
        (let ((comp (composition-in-force (append said by-spec) contains)))
          ;; a spec's bars: the scope's own where it states the spec, else what its
          ;; recipe handed on, with the table's for every leaf the recipe does not
          ;; derive (heat is stated, never derived)
          (define (bars-of id)
            (let ((word (assoc-ref said id)) (made (assoc-ref by-spec id)))
              (if word (row-bars word)
                  (let ((table (slack->bars (form-slack id #:contains contains))))
                    (if made
                        (append (row-bars made) (remove (lambda (b) (assoc (car b) (row-bars made))) table))
                        table)))))
          ;; HEAT FOLLOWS THE ATOMS. A form's heat is its own statement. A row a recipe
          ;; DERIVED holds the atoms the recipe drew, which are more or fewer than the
          ;; table's kilogram holds, and its heat is then the table's with the
          ;; difference held at the last form an atom takes (carbon as carbon dioxide,
          ;; hydrogen as water): the same figure an unnamed loss is granted, so the
          ;; recipe that puts all it drew into its product and the one that lets the
          ;; rest go unnamed read alike, and neither has made heat.
          (define leaf-floor                ; kWh a kilogram of the leaf holds in the last form it takes (the Hess constants of formation-kwh)
            `(("C" . ,(/ %kj-per-kg-c %kj-per-kwh)) ("H" . ,(/ %kj-per-kg-h %kj-per-kwh))))
          (define (table-row id)            ; what the table alone says of ID, closed
            (or (assoc-ref (closed-composition (list id) #:contains contains #:tracked (closure-basis)) id) '()))
          (define (heat-of id made)         ; MADE: the derived row; #f where the table states no heat of ID
            (let ((table (table-row id)))
              (and=> (and (heat-known? id #:contains contains) (assoc-ref table "heat"))
                     (lambda (h)
                       (fold (lambda (f a) (+ a (* (cdr f) (- (or (assoc-ref made (car f)) 0.0) (or (assoc-ref table (car f)) 0.0)))))
                             h leaf-floor)))))
          (define (with-heat row)
            (let ((id (car row)))
              (cond ((assoc-ref said id) row)
                    ((assoc-ref by-spec id)
                     => (lambda (made)
                          (let ((h (heat-of id made)))
                            (if h (cons id (cons (cons "heat" h) (alist-delete "heat" (cdr row)))) row))))
                    ((heat-known? id #:contains comp) row)
                    (else (cons id (alist-delete "heat" (cdr row)))))))   ; what its water alone holds is half a figure
          ;; a row holding matter and no heat says its heat is unknown, so the law on
          ;; heat is unread where it enters and never read as none
          (define (or-unknown row)
            (if (or (assoc "heat" (cdr row))
                    (not (any (lambda (e) (and (member (car e) *element-ids*) (> (abs (cdr e)) 0.0))) (cdr row))))
                row
                (cons (car row) (append (cdr row) (list (cons (unread-key "heat") 1.0))))))
          (define (per-unit spec row) (cons (car row) (times (scale-of spec) (cdr row))))
          (append
           ;; what a process makes: its atoms, and the heat that follows them
           (map (lambda (row)
                  (let* ((spec (cdar row)) (h (heat-of spec (cdr row))))
                    (per-unit spec (or-unknown (if h (cons (car row) (cons (cons "heat" h) (cdr row))) row)))))
                by-process)
           ;; what a leaf lost with no name took with it, at the most
           (map (lambda (f) (list (car f) (cons "heat" (cdr f)))) leaf-floor)
           ;; a spec the recipes leave undetermined, of which nothing is stated either:
           ;; its every leaf is unknown, and says so
           (filter-map (lambda (s) (and (not (assoc-ref said s)) (not (composition-known? s contains))
                                        (cons s (map (lambda (e) (cons (unread-key e) 1.0)) (closure-basis)))))
                       undetermined)
           (map (lambda (row)
                  (let ((row (or-unknown (with-heat row))))
                    (per-unit (car row) (cons (car row) (append (cdr row) (bars-of (car row)))))))
                (closed-composition (delete-duplicates (append (map car comp) (map car units) (map car *molecules*)))
                                    #:contains comp #:tracked (closure-basis)))))))))
(define* (process-creates pid flows comp #:key (boundary? #f))
  "((leaf . net) …): what ONE run of process PID carries out beyond what it draws
   under COMP (composition-of-scope), past what the bars on its flows can explain;
   '() for a conserving or a lossy process. FLOWS as (recipe flows of substance) in the
   specs' own units. The engine's verdict (engine.scm template-creates) in the
   engine's own arithmetic: what it makes reads its own row, what it draws the
   spec's; a run's allowed shortfall on a leaf is each flow's quantity times its
   row's bar, summed; a leaf lost with no name is credited with what it took with
   it at the most (the rows COMP keys by leaf); a process that says it is the edge
   (BOUNDARY?) or draws nothing of any leaf is judged by no balance."
  (let* ((touched (delete-duplicates (map flow-spec flows)))
         (rows-of (lambda (spec) (append (or (assoc-ref comp (cons pid spec)) '()) (or (assoc-ref comp spec) '()))))
         (unread? (lambda (e) (any (lambda (spec) (and (assoc (unread-key e) (rows-of spec)) #t)) touched)))
         (leaves (remove unread?
                         (delete-duplicates (remove (lambda (k) (or (slack-key? k) (unread-key? k)))
                                                    (append-map (lambda (r) (map car (cdr r))) comp)))))
         (frac (lambda (spec e own?)
                 (or (and own? (assoc-ref (or (assoc-ref comp (cons pid spec)) '()) e))
                     (assoc-ref (or (assoc-ref comp spec) '()) e)
                     0.0)))
         (made (lambda (per) (flow-sum flows output-action? (lambda (spec q) (per spec q #t)))))
         (drew (lambda (per) (flow-sum flows input-action? (lambda (spec q) (per spec q #f)))))
         (amount (lambda (e) (lambda (spec q own?) (* q (frac spec e own?)))))
         (bar (lambda (e) (lambda (spec q own?) (abs (* q (frac spec (slack-key e) own?)))))))
    (if (or boundary? (every (lambda (e) (zero? (drew (amount e)))) leaves)) '()
        (let* ((sides (map (lambda (e) (cons e (cons (drew (amount e)) (made (amount e))))) leaves))
               (taken (lambda (e)
                        (fold (lambda (s a)
                                (let ((lost (- (cadr s) (cddr s))))
                                  (if (and (> lost 0.0) (not (equal? (car s) e)))
                                      (+ a (* lost (or (assoc-ref (or (assoc-ref comp (car s)) '()) e) 0.0)))
                                      a)))
                              0.0 sides))))
          (filter-map (lambda (s)
                        (let* ((e (car s)) (i (cadr s)) (o (cddr s)) (net (- i o (taken e)))
                               (allowed (+ (drew (bar e)) (made (bar e)))))
                          (and (< net (- (+ allowed (* 1e-9 (max (abs i) (abs o))) 1e-12))) (cons e net))))
                      sides)))))

;;; ── COMPLETENESS: which specs still carry an unstated composition ───────────
;; Element closure reads an absent composition as ZERO, so a spec that really does
;; carry an element and says nothing makes its consumers look like they CONJURE
;; matter — the closure would refuse a perfectly good recipe. The identities have to
;; be complete before the constraint can be trusted, and this is the list of what is
;; missing: substance-bearing specs a recipe touches, with no composition stated and
;; no recipe to derive one from.
(define* (composition-gaps flows-by-process #:key (contains *contains*))
  "FLOWS-BY-PROCESS: ((id flow …) …). Returns the specs whose
   composition is neither stated nor derivable — the ones element closure would read
   as carrying nothing."
  (let* ((all (delete-duplicates (append-map (lambda (p) (map flow-spec (cdr p))) flows-by-process)))
         (derivable (delete-duplicates
                     (filter-map (lambda (f) (and (output-action? (flow-action f)) (flow-spec f)))
                                 (append-map cdr flows-by-process)))))
    (filter (lambda (s)
              (and (not (composition-known? s contains))
                   (not (member s derivable))))
            all)))

;;; ── one element, one unit ───────────────────────────────────────────────────
;; An element row sums `q · fraction` across every flow that carries it, so the
;; quantities have to be in the SAME unit or the sum is arithmetic over apples and
;; tonnes. A `fraction` is per unit of the spec AS COUNTED (`spec-biomass` per kg,
;; a catalyst per litre), which is the right reading — but it means one element drawn
;; in kg here and tonnes there does not add up.
;;
;; Converting silently is the wrong fix: a litre of catalyst has a mass only if
;; somebody states its density, and the model holds none. So this REPORTS instead,
;; in the codebase's own idiom — declared, never inferred. A scope whose element
;; carriers disagree on units learns it here rather than in a wrong plan.
(define* (composition-unit-gaps specs unit-of #:key (contains *contains*) (tracked *element-ids*))
  "((element unit …) …) for every tracked element whose CARRIERS are counted in more
   than one unit. Empty when each element's carriers agree, which is the condition
   element closure needs."
  (filter-map
   (lambda (element)
     (let ((units (delete-duplicates
                   (filter-map
                    (lambda (spec)
                      (and (> (abs (or (assoc-ref (elemental spec #:contains contains) element) 0)) 0)
                           (unit-of spec)))
                    specs))))
       (and (> (length units) 1) (cons element (sort units string<?)))))
   tracked))

;;; ── THE RIFT, FELT BEFORE IT HAPPENS ────────────────────────────────────────
;; `*environment-specs*` above is the normative list: the stocks whose DRIFT is the
;; metabolic rift. Planetary drift is already a barrier — eco-catalogue.scm carries
;; the nitrogen and phosphorus fluxes as per-period fragilities and co2 as a budget
;; coupled to warming and ocean acidification, each cited and weighted. What a LOCAL
;; stock had instead was a plain bar: soil nitrogen at a farm could be drawn to its
;; last kilogram, because a bar is only felt when it is reached.
;;
;; A soil stock wants both properties at once — a level that falls and rises (crops
;; draw it, compost and fixation return it) and a fixed governance weight so the plan
;; eases off before exhausting it. That is precisely `*stock-frag-w*`: the good's own
;; `≥ 0` balance, carried as a fragility rather than a bar. No new channel, and the
;; wall/level parity is already proven (test-representation-parity.scm).
;;
;; So this is a SEAM, not a mechanism: it names which stocks deserve the treatment,
;; in the `(spec . weight)` shape `#:stock-frag` and `migrated->stock-frag` both
;; already speak. A scope appends it to whatever limits it already migrates.
(define %environment-frag-weight 5.0)   ; a GOVERNANCE number, not a physical one — how hard a scope wants depletion felt before it arrives. Matched to the planetary biogeochemical boundaries (eco-catalogue.scm: nitrogen and phosphorus at 5.0), so a local soil stock is defended at the same strength as the flux it feeds. A scope may say otherwise.
(define* (environment-stock-frag specs #:key (weight %environment-frag-weight))
  "((spec . weight) …) for the environment stocks among SPECS — the drift that is the
   rift, carried as a fragility on the stock's own balance so it is felt before the
   stock is gone. Pass to `#:stock-frag`, beside any migrated ecological limits."
  (map (lambda (s) (cons s weight))
       (filter environment-spec? (delete-duplicates specs))))
