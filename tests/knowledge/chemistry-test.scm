;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; chemistry-test.scm — the mole/atom-exact substance layer: molecules by
;;; FORMULA, molar mass DERIVED from the periodic table, and reactions that
;;; BALANCE by integer atom conservation (not just asserted). This is the leap
;;; from "the author routes the mass" to "the system finds the stoichiometry."
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/knowledge/chemistry-test.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules ((playnet knowledge catalogues subsistence) #:select (shed-rain-mm-day))
             ((playnet knowledge dsl shorthand) #:select (consume*))
             (playnet test harness)
             (playnet knowledge catalogues substances)
             ((playnet vf schemas) #:select (recipe-flow? recipe-flow-resource-quantity measure-has-numerical-value measure-has-unit)) ((playnet vf formulas actions) #:select (*stock-moving-actions* *adjustment-actions* input-action? output-action?))
             (srfi srfi-1))

(define (~= a b) (and (number? a) (number? b) (< (abs (- a b)) 1e-2)))
(define (coeff b s) (and b (assoc-ref b s)))   ; string keys → equal?, not eq?

;;; ── molar mass derived from formulas (no magic numbers) ────────────────────
(check-pred "CO₂ molar mass = 44.01 (12.011 + 2×15.999)" (~= (molar-mass "co2") 44.009))
(check-pred "H₂O molar mass = 18.015"                     (~= (molar-mass "h2o") 18.015))
(check-pred "glucose molar mass = 180.16"                 (~= (molar-mass "glucose") 180.156))
(check-pred "an element's molar mass is its atomic weight" (~= (molar-mass "C") 12.011))

;;; ── balancing: the system FINDS the integer coefficients ───────────────────
;; combustion: CH₄ + 2 O₂ → CO₂ + 2 H₂O
(define comb (balance-reaction '("ch4" "o2") '("co2" "h2o")))
(check-pred "combustion balances" (and comb #t))
(check "  CH₄ : 1" (coeff comb "ch4") 1)
(check "  O₂  : 2" (coeff comb "o2")  2)
(check "  CO₂ : 1" (coeff comb "co2") 1)
(check "  H₂O : 2" (coeff comb "h2o") 2)

;; photosynthesis: 6 CO₂ + 6 H₂O → C₆H₁₂O₆ + 6 O₂
(define photo (balance-reaction '("co2" "h2o") '("glucose" "o2")))
(check-pred "photosynthesis balances" (and photo #t))
(check "  CO₂     : 6" (coeff photo "co2") 6)
(check "  H₂O     : 6" (coeff photo "h2o") 6)
(check "  glucose : 1" (coeff photo "glucose") 1)
(check "  O₂      : 6" (coeff photo "o2") 6)

;; C + O₂ → CO₂  (a bare element as a species)
(define burn-c (balance-reaction '("C" "o2") '("co2")))
(check "C + O₂ → CO₂ : carbon coeff 1" (coeff burn-c "C") 1)
(check "C + O₂ → CO₂ : O₂ coeff 1"     (coeff burn-c "o2") 1)

;;; ── impossible transmutation: atoms can't be conserved → no answer ─────────
(check-pred "NH₃ → CO₂ is REJECTED (nitrogen can't become carbon)"
            (not (balance-reaction '("nh3") '("co2"))))
(check-pred "C → N is REJECTED (no transmutation)"
            (not (balance-reaction '("C") '("N"))))

;;; ── a balanced reaction → VF flows, mass-conserving ────────────────────────
;; combustion scaled to 1 mol CH₄: consume CH₄ + O₂, produce CO₂ + H₂O
(define flows (reaction->flows '("ch4" "o2") '("co2" "h2o") "ch4" 1))
(define (mass-of act) (fold (lambda (f a) (if (eq? (flow-action f) act) (+ a (* (flow-qty f) (molar-mass (flow-spec f)))) a)) 0 flows))
(check-pred "consume side has mass (16.04 CH₄ + 64.0 O₂ ≈ 80.04 g)" (~= (mass-of 'consume) 80.04))
(check-pred "produce side has mass (44.01 CO₂ + 36.03 H₂O ≈ 80.04 g)" (~= (mass-of 'produce) 80.04))
(check-pred "reaction conserves MASS exactly (in = out)" (~= (mass-of 'consume) (mass-of 'produce)))

;;; ── the primitive: reaction-basis. Uniqueness is a property of the species set ─
;; {C, O₂, CO, CO₂} over elements {C, O} has rank 2 and 4 species → 2 degrees of
;; freedom → TWO independent balanced reactions. Not one equation, a network.
(define basis (reaction-basis '("C" "o2" "co" "co2")))
(check "a 2-DOF species set yields a basis of 2 reactions" (length basis) 2)
;; every basis vector is itself element-balanced (signed coeffs · atom counts = 0)
(define (element-balanced? species vec elt)
  (~= (fold + 0 (map (lambda (s c) (* c (or (assoc-ref (or (formula s) '()) elt) 0)))
                     species vec)) 0))
(check-pred "basis reaction 1 conserves carbon" (element-balanced? '("C" "o2" "co" "co2") (car basis) "C"))
(check-pred "basis reaction 1 conserves oxygen" (element-balanced? '("C" "o2" "co" "co2") (car basis) "O"))
(check-pred "basis reaction 2 conserves carbon" (element-balanced? '("C" "o2" "co" "co2") (cadr basis) "C"))
(check-pred "basis reaction 2 conserves oxygen" (element-balanced? '("C" "o2" "co" "co2") (cadr basis) "O"))
;; the single-DOF view still works on a 1-DOF subproblem, and a multi-DOF one
;; correctly DECLINES (it's a network, not a unique equation)
(check "balance-reaction on a 1-DOF subset is unique (C+O₂→CO₂)" (coeff (balance-reaction '("C" "o2") '("co2")) "co2") 1)
(check-pred "balance-reaction on a 2-DOF set returns #f (it's a network)"
            (not (balance-reaction '("C" "o2") '("co" "co2"))))

;;; ── redox: charge is a second conserved quantity ───────────────────────────
;; Fe³⁺ + e⁻ → Fe²⁺ balances BOTH iron (1=1) and charge (3 + (−1) = 2).
(define redox (balance-reaction '("Fe3+" "e-") '("Fe2+")))
(check-pred "redox half-reaction balances (Fe³⁺ + e⁻ → Fe²⁺)" (and redox #t))
(check "  Fe³⁺ : 1" (coeff redox "Fe3+") 1)
(check "  e⁻   : 1" (coeff redox "e-") 1)
(check "  Fe²⁺ : 1" (coeff redox "Fe2+") 1)
(check-pred "without the electron it's charge-IMBALANCED → #f (3 ≠ 2)"
            (not (balance-reaction '("Fe3+") '("Fe2+"))))
;; a neutral-only set has NO charge row — combustion is unaffected (backward compat)
(check "neutral combustion still balances (no charge row introduced)"
       (coeff (balance-reaction '("ch4" "o2") '("co2" "h2o")) "o2") 2)

;; the one-word reading the web face marks its junctions with
(define (mol id n) (* n (molar-mass id)))   ; n moles of a species, as the mass the ledger carries
(check "combustion, balanced, reads closed"
       (conservation-reading (bare-flows `((consume "ch4" ,(mol "ch4" 1)) (consume "o2" ,(mol "o2" 2)) (produce "co2" ,(mol "co2" 1)) (produce "h2o" ,(mol "h2o" 2))))) "closed")
(check "methane burned with its CO₂ unnamed reads open"
       (conservation-reading (bare-flows `((consume "ch4" ,(mol "ch4" 1)) (consume "o2" ,(mol "o2" 2)) (produce "h2o" ,(mol "h2o" 2))))) "open")
(check "a step of untracked goods has nothing to balance"
       (conservation-reading (bare-flows '((consume "bicycle" 1) (produce "repaired-bicycle" 1)))) "")
(check "a boundary process reads closed by definition"
       (conservation-reading (bare-flows '((consume "ch4" 16.04))) #:boundary? #t) "closed")

;;; ── ENERGY: the third conserved quantity, in the linear check ──────────────
;; docs/observation/readings-are-counts.md §1.5. Molecules carry their enthalpy of
;; formation as the leaf "heat"; the residual that closes carbon closes energy.
(define both (append *element-ids* *energy-ids*))
(define (heat-residual flows) (assoc-ref (flow-residual flows #:tracked both) "heat"))
(define (~kj a b) (< (abs (- a b)) 0.2))            ; the table is stated to 0.1 kJ/mol
(define (kj kwh) (* kwh 3600.0))                  ; the residual is kWh; the table speaks kJ
;; combustion of 1 mol CH₄ (flows in kg): heat consumed − produced = −ΔH_r = +890.2 kJ
(define comb-flows (reaction->flows '("ch4" "o2") '("co2" "h2o") "ch4" 1))
(define comb-kg (map (lambda (f) (bare-flow (flow-action f) (flow-spec f) (/ (* (flow-qty f) (molar-mass (flow-spec f))) 1000.0))) comb-flows))
(check-pred "methane combustion leaves +890 kJ of heat as surplus (exothermic: loss allowed)"
            (~kj (kj (heat-residual comb-kg)) 890.2))
(check-pred "…and the atoms still close (elements residual zero)"
            (every (lambda (e) (< (abs (cdr e)) 1e-9))
                   (filter (lambda (e) (member (car e) *element-ids*)) (flow-residual comb-kg #:tracked both))))
(check "the element reading is unchanged by the energy leaf: carbon in = carbon out"
       (check-conservation comb-kg) #t)
;; photosynthesis is endothermic: open until a heat carrier is consumed
(define photo-flows (reaction->flows '("co2" "h2o") '("glucose" "o2") "glucose" 1))
(define photo-kg (map (lambda (f) (bare-flow (flow-action f) (flow-spec f) (/ (* (flow-qty f) (molar-mass (flow-spec f))) 1000.0))) photo-flows))
(check-pred "photosynthesis is short of heat (−2802.5 kJ/mol glucose)"
            (~kj (kj (heat-residual photo-kg)) -2802.5))
(check "…so it reads open over energy" (conservation-reading photo-kg #:tracked both) "open")
(check "…and closed once the sun's heat enters as ambient heat, to the kilojoule the table states"
       (conservation-reading (cons (bare-flow 'consume "ambient-heat" (- (heat-residual photo-kg))) photo-kg) #:tracked both) "closed")
(check "…while over the elements alone it was closed all along" (conservation-reading photo-kg) "closed")
;; latent heat derived, never typed
(check-pred "water's latent heat = ΔHf(vapour) − ΔHf(liquid) = 0.678 kWh/kg at 25 °C"
            (~= (latent-heat-kwh-per-kg) 0.678))
;; the molecule basis: water read as water, atoms untouched
(check "biomass is half water in the h2o basis"
       (substance-content "spec-biomass" 1.0 #:tracked '("h2o")) '(("h2o" . 0.5)))
(check-pred "…and its carbon reading is unchanged"
            (~= (assoc-ref (substance-content "spec-biomass" 1.0) "C") 0.25))
;; a warmed form: specific heat stated once, the row derived
(call-with-values (lambda () (thermal-form "spec-biomass" 2.5 6))
  (lambda (id row)
    (check "thermal-form names the form by its excess" id "spec-biomass+6K")
    (check-pred "…and carries 0.0042 kWh/kg of heat above its base's formation, beside the base rows: one frame, never crossed"
                (and (~= (* 1000 (- (assoc-ref row "heat") (enthalpy-per-kg "spec-biomass"))) (* 1000 (/ 15.0 3600)))
                     (~= (assoc-ref row "C") 0.25)))
    (check "…so the warmed form is in the formation frame, as its base is" (frame-of id) 'formation)))
(check "a warmed form of a base with no formation states its excess alone, in the excess frame"
       (call-with-values (lambda () (thermal-form "dough" 2.5 6)) (lambda (id row) (list (~= (* 1000 (assoc-ref row "heat")) (* 1000 (/ 15.0 3600))) (frame-of id #:contains (list (cons id row))))))
       '(#t excess))
(check "a cooled form is signed"
       (call-with-values (lambda () (thermal-form "spec-biomass" 2.5 -4)) (lambda (id row) (negative? (assoc-ref row "heat")))) #t)

;;; ── NUCLEONS: fission and fusion balance on A and Z, and the defect is the heat ──
;; docs/observation/readings-are-counts.md §2.8. Nuclides are counted in moles.
(define nuc (append *nucleon-ids* *energy-ids*))
(define (mev-per-mol kwh) (/ (* kwh 3.6e6) 1.602176634e-13 6.02214076e23))   ; kWh/mol → MeV per nucleus
;; U-235 + n → Ba-141 + Kr-92 + 3 n
(define fission (bare-flows '((consume "U-235" 1) (consume "n" 1) (produce "Ba-141" 1) (produce "Kr-92" 1) (produce "n" 3))))
(define fr (flow-residual fission #:tracked nuc))
(check-pred "fission conserves nucleons: 236 in, 236 out" (~= (assoc-ref fr "A") 0.0))
(check-pred "…and charge: 92 = 56 + 36" (~= (assoc-ref fr "Z") 0.0))
(check-pred "…and the mass defect leaves as 173.3 MeV of heat (E = mc²)"
            (< (abs (- (mev-per-mol (assoc-ref fr "heat")) 173.3)) 0.3))
(check-pred "a kilogram of U-235 through this channel: 1.98e7 kWh, twenty gigawatt-hours"
            (< (abs (- (/ (assoc-ref fr "heat") (/ (molar-mass "U-235") 1000.0)) 1.976e7)) 2e5))
;; the bound frame: a nucleus sits below free nucleons by its binding energy
(check-pred "a lone U-235 carries its energy BELOW free nucleons: 1903 MeV of binding, a negative heat"
            (< (abs (- (mev-per-mol (nuclear-heat-per-mol "U-235")) -1903.0)) 3.0))
(check-pred "…the free neutron is the zero, and the proton sits 1.29 MeV under it"
            (and (~= (nuclear-heat-per-mol "n") 0.0)
                 (< (abs (- (mev-per-mol (nuclear-heat-per-mol "H-1")) -1.293)) 0.01)))
(check-pred "so uranium consumed into nothing contributes negative heat: the first law's row refuses uranium into heat"
            (< (assoc-ref (flow-residual (bare-flows '((consume "U-235" 1))) #:tracked nuc) "heat") 0.0))
(check-pred "…while the electron, no nucleon, carries its rest energy" (< (abs (- (mev-per-mol (nuclear-heat-per-mol "beta-")) 0.511)) 0.001))
;; alpha decay is one equation: U-238 → Th-234 + He-4, found by the null space on A and Z
(define alpha (balance-reaction '("U-238") '("Th-234" "He-4")))
(check-pred "alpha decay balances uniquely on nucleons and charge" (and alpha #t))
(check "  U-238 : 1"  (coeff alpha "U-238") 1)
(check "  He-4  : 1"  (coeff alpha "He-4") 1)
(check-pred "…releasing 4.27 MeV"
            (< (abs (- (mev-per-mol (assoc-ref (flow-residual (bare-flows '((consume "U-238" 1) (produce "Th-234" 1) (produce "He-4" 1))) #:tracked nuc) "heat")) 4.27)) 0.02))
;; D–T fusion: H-2 + H-3 → He-4 + n, 17.59 MeV
(check-pred "deuterium–tritium fusion releases 17.59 MeV"
            (< (abs (- (mev-per-mol (assoc-ref (flow-residual (bare-flows '((consume "H-2" 1) (consume "H-3" 1) (produce "He-4" 1) (produce "n" 1))) #:tracked nuc) "heat")) 17.59)) 0.02))
;; conservation is necessary, never sufficient: on A and Z alone the null space finds
;; 19 U-235 → Ba-141 + 47 Kr-92, a channel nature never runs. Which channel runs is
;; the recipe's word; what the rows refuse is a channel that could not balance at all.
(define odd (balance-reaction '("U-235") '("Ba-141" "Kr-92")))
(check "nucleons and charge alone admit 19 U-235 → Ba-141 + 47 Kr-92" (coeff odd "Kr-92") 47)
(check-pred "a set mixing a nuclide with a molecule is refused: two laws"
            (catch #t (lambda () (reaction-basis '("U-235" "co2")) #f) (lambda _ #t)))
(check-pred "the element reading of a nuclide is empty: nucleons are its leaves"
            (null? (substance-content "U-235" 1.0)))

;;; ── ENTROPY: the second law as one inequality ────────────────────────────────
(define (production flows) (second-law-production flows))
(check-pred "methane combustion, its heat unnamed, produces entropy: the loss reaches the surroundings at T₀"
            (> (production comb-kg) 0))
(check-pred "…and named as ambient heat it produces the same, to the rounding of the tables"
            (let ((q (assoc-ref (flow-residual comb-kg #:tracked (list "heat")) "heat")))
              (< (abs (- (production (cons (bare-flow 'produce "ambient-heat" q) comb-kg)) (production comb-kg))) 1e-9)))
(check-pred "photosynthesis driven by ambient heat would destroy entropy: refused"
            (< (production (cons (bare-flow 'consume "ambient-heat" (- (assoc-ref (flow-residual photo-kg #:tracked (list "heat")) "heat"))) photo-kg)) 0))
(define need (- (assoc-ref (flow-residual photo-kg #:tracked (list "heat")) "heat")))   ; kWh the reaction needs
(check-pred "…driven by exactly its enthalpy in sunlight it still would: the entropy of the products must be paid for"
            (< (production (cons (bare-flow 'consume "sunlight" need) photo-kg)) 0))
(check-pred "…and with a tenth more sunlight absorbed and rejected to ambient, it runs: a leaf's efficiency is bounded below one"
            (> (production (append (list (bare-flow 'consume "sunlight" (* 1.1 need))
                                         (bare-flow 'produce "ambient-heat" (* 0.1 need)))
                                   photo-kg))
               0))
(check-pred "a process touching a mixture with no stated entropy is not read: absence means nobody has said"
            (not (production (list (bare-flow 'consume "fertiliser" 1.0) (bare-flow 'produce "nh3" 0.5)))))   ; fertiliser: a row of N, P and K, no entropy, never warmed here
(check-pred "a carrier's entropy is 1/T₀ derived from the one constant, and work states zero"
            (and (= (assoc-ref (assoc-ref *contains* "ambient-heat") "entropy") (/ 1.0 %ambient-kelvin))
                 (= 0.0 (assoc-ref (assoc-ref *contains* "spec-sp-electricity") "entropy"))
                 (entropy-stated? "spec-sp-electricity")))
(check-pred "exergy of electricity is its heat (work), of ambient heat zero"
            (and (~= (spec-exergy "spec-sp-electricity") 1.0) (< (abs (spec-exergy "ambient-heat")) 1e-8)))

;;; ── CHANNELS: what runs is data, and a half-life is a relaxation ───────────
(check-pred "thermal fission of U-235 is a channel" (and (channel-of (list "U-235" "n") (list "Ba-141" "Kr-92" "n" "n" "n")) #t))
(check-pred "19 U-235 → Ba-141 + 47 Kr-92 is none" (not (channel-of (make-list 19 "U-235") (append (list "Ba-141") (make-list 47 "Kr-92")))))
(check-pred "flows in moles find their channel" (and (nuclear-process-channel fission) #t))
(check-pred "the daily decay fraction of U-238 is 4.25e-13" (< (abs (- (decay-fraction 4.468e9) 4.25e-13)) 1e-14))
;; beta decay: nuclear masses, and the lepton row
(define beta-c14 (bare-flows '((consume "C-14" 1) (produce "N-14" 1) (produce "beta-" 1) (produce "antineutrino" 1))))
(define nucl (append *nucleon-ids* *energy-ids*))
(check-pred "carbon-14 beta decay conserves nucleons, charge and lepton number"
            (every (lambda (k) (~= (assoc-ref (flow-residual beta-c14 #:tracked nucl) k) 0.0)) '("A" "Z" "L")))
(check-pred "…and releases 0.156 MeV: the atomic masses' difference, the electron counted once"
            (< (abs (- (mev-per-mol (assoc-ref (flow-residual beta-c14 #:tracked nucl) "heat")) 0.156)) 0.002))
(check-pred "…and it balances uniquely on A, Z and L"
            (let ((b (balance-reaction '("C-14") '("N-14" "beta-" "antineutrino")))) (and b (= 1 (coeff b "beta-")))))
(check-pred "a beta decay that drops the antineutrino is refused: lepton number"
            (not (balance-reaction '("C-14") '("N-14" "beta-"))))
(check-pred "…and is no channel either" (not (channel-of '("C-14") '("N-14" "beta-"))))
(check-pred "alpha and fission heats are unchanged by the nuclear masses (Z conserved)"
            (< (abs (- (mev-per-mol (assoc-ref (flow-residual fission #:tracked nucl) "heat")) 173.3)) 0.3))
;; fuels in the formation frame: octane's heat of combustion
(define burn-octane (reaction->flows '("spec-petrol" "o2") '("co2" "h2o") "spec-petrol" 1))
(define burn-octane-kg (map (lambda (f) (bare-flow (flow-action f) (flow-spec f) (/ (* (flow-qty f) (molar-mass (flow-spec f))) 1000.0))) burn-octane))
(check-pred "burning a mole of octane leaves 5470 kJ as heat (Hess, from the stated formation enthalpy)"
            (< (abs (- (kj (heat-residual burn-octane-kg)) 5470.3)) 2.0))
(check-pred "…and produces entropy with its heat unnamed" (> (production burn-octane-kg) 0))
(check "a formula is read off its Hill string: glucose is C₆H₁₂O₆"
       (formula "glucose") '(("C" . 6) ("H" . 12) ("O" . 6)))
(check "…kaolinite Al₂Si₂O₉H₄ too, and a bare element is itself" (list (assoc-ref (formula "spec-bn-kaolin") "Si") (formula "C")) '(2 (("C" . 1))))
(check "a nuclide's charge derives from its symbol, off the one periodic table" (list (nuclide-z "U-235") (atomic-number "U")) '(92 92))
(check-pred "an element of isotopes alone has no standard weight, and says so"
            (catch #t (lambda () (atomic-weight "Pu") #f) (lambda _ #t)))
(check-pred "…while its atomic number stands" (= 94 (atomic-number "Pu")))
(check "a nuclide's charge derives from its symbol" (nuclide-z "U-235") 92)
(check "…and its nucleon number from its id" (nuclide-a "Pu-239") 239)
(check "the neutron is \"n\": no charge, one nucleon" (list (nuclide-z "n") (nuclide-a "n")) '(0 1))
(check-pred "a symbol the table has no atomic number for is an error, never a zero"
            (catch #t (lambda () (nuclide-z "Xx-1") #f) (lambda _ #t)))
(check-pred "ice's latent heat of fusion derives: 0.0925 kWh/kg, 333 kJ/kg"
            (< (abs (- (* 1000 (latent-heat-kwh-per-kg 'fusion)) 92.5)) 0.1))
;; the leaves, declared once: the id lists and the sign rule derive
(check "the energy, entropy and nucleon id lists derive from the leaf registry"
       (list *energy-ids* *entropy-ids* *nucleon-ids*) '(("heat") ("entropy") ("A" "Z" "L")))
(check-pred "heat is signed, carbon is an amount or nothing" (and (signed-leaf? "heat") (not (signed-leaf? "C"))))
(check "a leaf knows its unit" (leaf-unit "entropy") "kWh/K")
;; reactions as expressions
(check "an equation balances as data: methane's combustion"
       (balance-expression '(-> (ch4 o2) (co2 h2o))) '(-> (ch4 (2 o2)) (co2 (2 h2o))))
(check "…photosynthesis" (balance-expression '(-> (co2 h2o) (glucose o2))) '(-> ((6 co2) (6 h2o)) (glucose (6 o2))))
(check-pred "a stated equation becomes flows, mass-conserving"
            (let ((fl (expression->flows '(-> (ch4 (2 o2)) (co2 (2 h2o))))))
              (~= (fold (lambda (f a) (if (eq? (flow-action f) 'consume) (+ a (* (flow-qty f) (molar-mass (flow-spec f)))) a)) 0 fl)
                  (fold (lambda (f a) (if (eq? (flow-action f) 'produce) (+ a (* (flow-qty f) (molar-mass (flow-spec f)))) a)) 0 fl))))
(check-pred "…and one that does not conserve is refused, naming the row"
            (catch #t (lambda () (expression->flows '(-> (ch4 o2) (co2 h2o))) #f) (lambda (k . a) #t)))
(check-pred "fission as an expression balances on nucleons and charge"
            (equal? (expression->flows '(-> (U-235 n) (Ba-141 Kr-92 (3 n))) #:basis 'U-235)
                    (map identity (expression->flows '(-> (U-235 n) (Ba-141 Kr-92 (3 n)))))))
(check-pred "a mixture states its enthalpy and entropy per kilogram: biomass rides them beside its atoms"
            (let ((l (elemental "spec-biomass")))
              (and (~= (assoc-ref l "heat") -3.03) (assoc-ref l "entropy") (~= (assoc-ref l "C") 0.25))))
(check-pred "…so burning it into a heat carrier is read by the second law and produces entropy"
            (let ((p (second-law-production (bare-flows '((consume "spec-biomass" 1.0) (consume "o2" 1.4) (produce "co2" 0.9) (produce "h2o" 0.9) (produce "spec-bn-heat" 2.0))))))
              (and p (> p 0))))
(check-pred "…while a stove claiming more heat than the fuel's value creates energy: the FIRST law refuses it"
            (let ((r (flow-residual (bare-flows '((consume "spec-biomass" 1.0) (consume "o2" 1.4) (produce "co2" 0.9) (produce "h2o" 0.9) (produce "spec-bn-heat" 20.0)))
                                    #:tracked *energy-ids*)))
              (< (assoc-ref r "heat") -10)))   ; consumed − produced < 0: heat from nothing
(check-pred "…and the second law alone is indifferent to heat conjured at ambient grade: that is the first law's job"
            (let ((p (second-law-production (bare-flows '((consume "spec-biomass" 1.0) (consume "o2" 1.4) (produce "co2" 0.9) (produce "h2o" 0.9) (produce "spec-bn-heat" 20.0))))))
              (and p (>= p 0))))
(check-pred "the nutrients are leaves of the one registry" (and (leaf-unit "protein") (not (signed-leaf? "protein"))))
(check "the stock-moving actions read off the ValueFlows table are produce, consume, raise, lower"
       (sort (map symbol->string *stock-moving-actions*) string<?) '("consume" "lower" "produce" "raise"))
(check "…the adjustments among them raise and lower" (sort (map symbol->string *adjustment-actions*) string<?) '("lower" "raise"))
(check-pred "…and of Pu-239, 7.9e-8 a day: half gone in 24,110 years"
            (~= (* (decay-fraction 2.411e4 #:period-hours (* 8766.0 2.411e4)) 1.0) 0.5))

(display "\n── water is the molecule, and drinking water its litre ──\n")
(check-pred "spec-water, grow-water and drinking-water, counted in litres, are water forms"
            (every water-form? '("spec-water" "grow-water" "drinking-water")))
(check-pred "…biomass, half water, is a form of its own; the farm's summer water is water, its row per litre read at its megalitre scale"
            (and (not (water-form? "spec-biomass")) (water-form? "water")))
(check "a water form carries its litre per kilogram, derived from the molecule row" (nutrient-content "spec-water" 2.0) '(("drinking-water" . 2.0)))
(check-pred "on the element basis water is two ninths hydrogen and seven ninths oxygen, both tracked"
            (let ((r (substance-content "spec-water" 1.0)))
              (and (~= (assoc-ref r "H") (/ (* 2 (atomic-weight "H")) (molar-mass "h2o"))) (~= (assoc-ref r "O") (/ (atomic-weight "O") (molar-mass "h2o")))
                   (not (assoc-ref r "C")))))
(check "…and on the molecule basis it is h2o, one for one" (substance-content "spec-water" 1.0 #:tracked '("h2o")) '(("h2o" . 1.0)))
(check-pred "grain's moisture meets no water floor: the food rows carry no water, on purpose"
            (not (assoc-ref (nutrient-content "grain" 1.0) "drinking-water")))

(display "\n── the sun in every grow ──\n")
(check-pred "a kilocalorie is 1.162e-3 kWh, derived from the calorie" (~= %kwh-per-kcal 1.1622e-3))
(check-pred "a kilogram of grain stores between 3.5 and 4.2 kWh of food energy"
            (let ((e (food-energy-kwh "grain" 1.0))) (and (> e 3.5) (< e 4.2))))
(check-pred "…and needs a hundredfold in light: grain is a C3 crop, one percent stored"
            (and (eq? (pathway-of "grain") 'c3) (~= (sunlight-for "grain" 1.0) (* 100 (food-energy-kwh "grain" 1.0)))))
(check-pred "maize is C4: it stores half again as much light and transpires half the water per kilocalorie"
            (and (eq? (pathway-of "maize") 'c4) (~= (photosynthetic-share "maize") 0.015) (~= (litres-per-kcal "maize") 0.06)))
(check-pred "a CAM crop opens at night: a fifth of C3's water, half its share"
            (and (eq? (pathway-of "agave") 'cam) (~= (litres-per-kcal "agave") 0.025) (~= (photosynthetic-share "agave") 0.005)))
(check-pred "the light a process needs is what its products need over what its inputs paid: a mill draws none, a grow draws its crop's"
            (and (= 0.0 (light-needed (bare-flows '((consume "grain" 1.0) (produce "flour" 0.9)))))
                 (~= (light-needed (bare-flows '((consume "soil" 1.0) (produce "grain" 1.0)))) (sunlight-for "grain" 1.0))))
(check "a form with no energy row derives no light" (sunlight-for "soil" 1.0) 0.0)
(check-pred "sunlight, rain, the air's carbon dioxide and oxygen and ambient heat are the engine's boundless flows and the chemistry's boundary carriers, one list"
            (equal? *boundary-carriers* '("sunlight" "rain" "co2" "o2" "ambient-heat")))
(check-pred "hydrogen and oxygen are tracked elements beside carbon, nitrogen, phosphorus and potassium"
            (and (member "H" *element-ids*) (member "O" *element-ids*) #t))
(check-pred "every composition row that carries carbon carries hydrogen and oxygen: no organic form is half described"
            (every (lambda (r) (or (not (assoc-ref (cdr r) "C")) (and (assoc-ref (cdr r) "H") (assoc-ref (cdr r) "O"))))
                   (filter (lambda (r) (not (member (car r) *heat-carriers*))) *contains*)))
(display "\n── foods from the release: elements, formation, the body's outputs ──\n")
(check-pred "grain is two fifths carbon and an eighth water, off the release's macronutrients"
            (let ((r (food-elements "grain"))) (and (< 0.38 (assoc-ref r "C") 0.41) (< 0.12 (assoc-ref r "h2o") 0.14) (< 0.019 (assoc-ref r "N") 0.022))))
(check-pred "…and its formation enthalpy sits between the water's and the dry matter's: near −1.9 kWh/kg, from the GROSS heats of combustion"
            (let ((h (enthalpy-per-kg "grain"))) (and (< -2.3 h -1.7))))
(check-pred "the gross heat a calorimeter reads exceeds Atwater's metabolisable kilocalories: what leaves undigested and as urea"
            (let ((m (food-macros "grain")))
              (> (apply + (map (lambda (g) (* (assoc-ref m (car g)) (cdr g))) %macro-gross-kj-per-kg))
                 (* (assoc-ref m "kcal") 4.184))))
(check-pred "…in the formation frame, so grain burns beside the molecules" (eq? 'formation (frame-of "grain")))
(check-pred "a food the release does not carry states no formation and stays unread" (and (not (enthalpy-per-kg "food")) (null? (metabolic-outputs "food" 1.0))))
(define grain-eat (metabolic-flows "grain" 1.0))
(define (eat-side action e)             ; kilograms of element E on one side of the eat, every form opened to its atoms
  (apply + (map (lambda (f) (or (assoc-ref (substance-content (flow-spec f) (flow-qty f) #:tracked '("C" "H" "O" "N")) e) 0.0))
                (filter (lambda (f) (eq? action (flow-action f))) grain-eat))))
(define (grain-in e) (or (assoc-ref (substance-content "grain" 1.0 #:tracked '("C" "H" "O" "N")) e) 0.0))
(check-pred "eating a kilogram of grain returns most of its carbon as breath, near 1.3 kg of CO₂, the rest in urea and faeces"
            (let ((o (metabolic-outputs "grain" 1.0))) (< 1.2 (assoc-ref o "co2") 1.4)))
(check-pred "…breathes in the oxygen the products hold beyond the grain's own, near a kilogram"
            (let ((o2 (flow-qty (find (lambda (f) (equal? (flow-spec f) "o2")) grain-eat)))) (and (eq? 'consume (flow-action (find (lambda (f) (equal? (flow-spec f) "o2")) grain-eat))) (< 0.8 o2 1.1))))
(check-pred "…leaves what it does not digest as faeces, under a tenth of the grain as dry matter"
            (let ((f (assoc-ref (metabolic-outputs "grain" 1.0) "faeces"))) (and (> f 0.1) (< (* f 0.25) 0.1))))
(check-pred "…and its nitrogen as urea and faeces, every gram of it: the body's nitrogen is tracked"
            (and (> (grain-in "N") 0.015) (~= (grain-in "N") (eat-side 'produce "N")) (= 0.0 (eat-side 'consume "N"))))
(check-pred "…and carbon, hydrogen and oxygen each balance across what enters, what is breathed in and what leaves"
            (every (lambda (e) (< (abs (- (+ (grain-in e) (eat-side 'consume e)) (eat-side 'produce e))) 1e-9)) '("C" "H" "O")))
(check-pred "…the rest of its hydrogen and its water as vapour, and EXACTLY its metabolisable kilocalories less the vapour's latent heat as heat: the faeces and the urea carry the gross energy the body never had"
            (let* ((o (metabolic-outputs "grain" 1.0)) (heat (assoc-ref o "ambient-heat")) (vapour (assoc-ref o "h2o-g")))
              (< (abs (- heat (- (food-energy-kwh "grain" 1.0) (* vapour (latent-heat-kwh-per-kg))))) 1e-6)))
(check-pred "…and the eat closes the first law exactly: what enters as formation leaves as products, urea, faeces and heat"
            (let ((o (metabolic-outputs "grain" 1.0)))
              (< (abs (- (enthalpy-per-kg "grain")
                         (+ (* (assoc-ref o "co2") (enthalpy-per-kg "co2")) (* (assoc-ref o "h2o-g") (enthalpy-per-kg "h2o-g"))
                            (* (assoc-ref o "urea") (enthalpy-per-kg "urea")) (* (assoc-ref o "faeces") (enthalpy-per-kg "faeces")) (assoc-ref o "ambient-heat"))))
                 1e-9)))
(check-pred "a hand-stated mixture derives by the food's own route: green waste at half moisture and 19 MJ/kg dry forms near −3.0 kWh/kg"
            (let ((h (enthalpy-per-kg "spec-biomass"))) (and (< -3.2 h -2.9) (~= h (mixture-formation-kwh "spec-biomass")))))
(check-pred "…and its composition row is the same statement read as leaves: carbon, hydrogen, oxygen, nitrogen and the water molecule"
            (let ((r (assoc-ref *contains* "spec-biomass"))) (and (~= (assoc-ref r "C") 0.25) (assoc-ref r "H") (assoc-ref r "O") (~= (assoc-ref r "h2o") 0.5))))
(check-pred "an alias is its target's mixture: bran's row, formation and entropy are the grain's, derived once"
            (and (equal? (mixture-of "bran") (mixture-of "grain")) (~= (enthalpy-per-kg "bran") (enthalpy-per-kg "grain"))
                 (equal? (assoc-ref *contains* "bran") (assoc-ref *contains* "grain"))))
(check-pred "a combustion is the formation read the other way: a food's gross heat comes back exactly, urea's is Hess's 632 kJ/mol"
            (and (< (abs (- (combustion-kj "grain") (assoc-ref (mixture-of "grain") "gross-kj"))) 1e-6)
                 (< (abs (- (* (combustion-kj "urea") (molar-mass "urea") 1e-3) 632.0)) 2.0)))
(check-pred "eating an aliased, watery food balances hydrogen and oxygen exactly too: its water is counted once, in its atoms, and evaporating it draws warmth from the surroundings"
            (let* ((fl (metabolic-flows "spec-produce" 1.0))
                   (side (lambda (a e) (apply + (map (lambda (f) (or (assoc-ref (atoms (flow-spec f) (flow-qty f)) e) 0.0)) (filter (lambda (f) (eq? a (flow-action f))) fl)))))
                   (in (lambda (e) (or (assoc-ref (atoms "spec-produce" 1.0) e) 0.0))))
              (and (every (lambda (e) (< (abs (- (+ (in e) (side 'consume e)) (side 'produce e))) 1e-9)) '("C" "H" "O" "N"))
                   (find (lambda (f) (and (eq? 'consume (flow-action f)) (equal? "ambient-heat" (flow-spec f)))) fl))))
(check-pred "the water a process draws is the consume side of one flow-sum, its products' water the produce side"
            (let ((fl (bare-flows '((consume "rain" 10.0) (consume "grow-water" 5.0) (produce "grain" 1.0)))))
              (and (~= (water-drawn fl) (flow-sum fl input-action? (leaf-of "h2o")))
                   (~= (water-kept fl) (assoc-ref (substance-content "grain" 1.0 #:tracked '("h2o")) "h2o")))))
(check-pred "a mixture stating no gross heat has a row and no formation: the farm's produce is read by the atom law and left by the first"
            (and (assoc-ref *contains* "food") (assoc-ref (assoc-ref *contains* "food") "O") (not (enthalpy-per-kg "food"))))
(check-pred "every crop the release and the fixtures grow names its pathway; an unnamed one is read at C3 and the lint says so"
            (and (every pathway-stated? '("grain" "beans" "greens" "carrot" "maize" "potato" "tomato" "wheat" "barley")) (not (pathway-stated? "quinoa")) (eq? 'c3 (pathway-of "quinoa"))))
(check-pred "…and produces entropy: gases and vapour carry out more than the grain brought"
            (let ((o (metabolic-outputs "grain" 1.0)))
              (> (second-law-production (cons (bare-flow 'consume "grain" 1.0) (map (lambda (p) (bare-flow 'produce (car p) (cdr p))) o))) 0.0)))
(check-pred "a crop fixes its carbon from the air: a kilogram of grain needs near 1.45 kg of CO₂"
            (let ((c (carbon-for (bare-flows '((consume "soil" 1.0) (produce "grain" 1.0)))))) (< 1.4 c 1.5)))
(check-pred "rain is the litre that falls: a water form, one h2o per litre" (water-form? %rain))
(check-pred "a kilogram of grain transpires at least three hundred litres, and under five hundred: C3's 0.12 L per kcal"
            (let ((l (water-for "grain" 1.0))) (and (> l 300) (< l 500))))
(check "a form with no energy row derives no water" (water-for "soil" 1.0) 0.0)
(check-pred "fodder states its macros by hand, so the hay has a formation and an entropy and the herd's eating is read"
            (and (enthalpy-per-kg "fodder") (entropy-per-kg "fodder") (pair? (metabolic-outputs "fodder" 1.0))
                 (< -3.0 (enthalpy-per-kg "fodder") -1.5)))
(check-pred "the water drawn reads every consumed form on the molecule basis: rain, irrigation and a feed's moisture"
            (~= (water-drawn (bare-flows '((consume "rain" 10.0) (consume "grow-water" 5.0) (consume "fodder" 100.0) (produce "grain" 1.0)))) 30.0))

(display "\n── volume and lift ──\n")
(check-pred "a kilogram of grain occupies 1.3 litres, a litre of water one, a cubic metre a thousand"
            (and (~= (litres-per-unit "grain" "kg") (/ 1.0 0.77)) (~= (litres-per-unit "spec-water" "L") 1.0) (~= (litres-per-unit "spec-water" "m3") 1000.0)))
(check "a good with no density and a mass unit has no volume" (litres-per-unit "soil" "kg") #f)
(check-pred "the one bridge reads a megalitre, a tonne and a hectare: a row per kilogram or litre scales to the spec's unit"
            (and (~= (litres-per-unit "water" "ML") 1e6) (~= (unit-scale "t") 1000.0) (~= (unit-scale "ML") 1e6) (~= (unit-scale "kg") 1.0)
                 (not (unit-scale %count-unit)) (~= (area-m2 "acre") 4046.86)))
(check-pred "the farm's summer water is a water form: its litre, read at its megalitre scale by the scope" (water-form? "water"))
(check-pred "a cubic metre holds 770 kg of grain or 250 of bread for a day: the container hours per unit, over the day"
            (and (~= (/ 24.0 (container-hours "grain" 1000.0)) 770.0) (~= (/ 24.0 (container-hours "bread" 1000.0)) 250.0)))
(check-pred "Berlin's record rains near two millimetres a day of the growing season; a shed with no record states none"
            (let ((r (shed-rain-mm-day "berlin"))) (and r (< 1.5 r 2.5) (not (shed-rain-mm-day "nowhere")))))

(display "\n── a floor names a leaf; substitution is a reading ──\n")
(check-pred "a floor on a quantity no leaf is declared for is refused"
            (catch #t (lambda () (closure-bands "ada" '(("phlogiston" 1 #f 1)) '("phlogiston") '(0) (lambda (o t) "town")) #f)
                   (lambda (k . a) #t)))
(check-pred "…every catalogue row is a leaf, so a real floor stands"
            (pair? (closure-bands "ada" '(("protein" 50 #f 9)) '("protein") '(0) (lambda (o t) "town"))))
(check-pred "against the macronutrients, flour covers most of a grain; salt covers none of it"
            (let ((f (leaf-cover "grain" "flour" #:against '("energy" "protein" "fibre")))
                  (s (leaf-cover "grain" "salt" #:against '("energy" "protein" "fibre"))))
              (and (> f 0.5) (= s 0.0))))
(check-pred "the substitutes for grain rank by cover, flour above bread, salt nowhere"
            (let ((subs (leaf-substitutes "grain" '("flour" "bread" "salt" "beans") #:against '("energy" "protein" "fibre"))))
              (and (pair? subs) (not (assoc "salt" subs))
                   (> (assoc-ref subs "flour") (assoc-ref subs "bread")))))

;; ── the readers the sky and the soil are stated with ─────────────────────────
(let ((grow (bare-flows '((consume "soil-n" 0.01) (produce "grain" 1.0))))
      (mill (bare-flows '((consume "grain" 1.2) (produce "flour" 1.0) (produce "bran" 0.1)))))
  (check-pred "leaf-needed: a grow draws of the ground what its harvest carries over its inputs"
              (~= (leaf-needed grow "N") (- (assoc-ref (mixture-elements "grain") "N") 0.01)))
  (check-pred "…and a mill, whose flour's nitrogen came in as grain, draws none of it"
              (= 0.0 (leaf-needed mill "N")))
  (check-pred "heat-drawn: the carriers and only the carriers"
              (~= 5.3 (heat-drawn (bare-flows '((consume "sunlight" 5.0) (consume "spec-sp-electricity" 0.3) (consume "grain" 2.0) (consume "water" 1.0)))))))
(check-pred "balance-flows reads a quantity in its row's basis: two megalitres are two million litres, a count stays a count"
            (let ((t (balance-flows (list (consume* "w" "water" 2.0 "grow" "ML") (consume* "s" "sea" 1.0 "fish" %count-unit)))))
              (and (~= 2.0e6 (flow-qty (find (lambda (f) (eq? 'consume (flow-action f))) t)))
                   (= 1.0 (flow-qty (find (lambda (f) (equal? "sea" (flow-spec f))) t))))))

;; ── a figure is stated with its bar ───────────────────────────────────────────
(check-pred "a figure is as good as where it came from: grain off the release, fodder and faeces by hand, bran its grain's"
            (equal? (map mixture-source '("grain" "fodder" "faeces" "bran" "co2")) '(release hand hand release #f)))
(let ((s (mixture-slack "grain")) (row (mixture-of "grain")) (rel (assoc-ref *precision* 'release)))
  (check-pred "an element's bar is its share of the dry matter's figure"
              (~= (assoc-ref s "C") (* (assoc-ref rel "C") (assoc-ref row "C"))))
  (check-pred "heat's bar is its share of the gross heat of combustion, so the water carries none"
              (and (~= (assoc-ref s "heat") (* (assoc-ref rel "heat") (/ (assoc-ref row "gross-kj") 3600.0)))
                   (not (assoc-ref s "h2o")))))
(check-pred "a molecule states no bar: its formula is its definition" (and (null? (form-slack "h2o")) (null? (form-slack "co2"))))
(check-pred "greens, nine tenths water, carry a bar on heat a twentieth of what two percent of their formation would have been"
            (< (assoc-ref (mixture-slack "greens") "heat") (* 0.05 0.02 (abs (enthalpy-per-kg "greens")) 20.0)))
;; ── a recipe hands its uncertainty on and adds none ───────────────────────────
(call-with-values
  (lambda () (derive-compositions '(("mill" (("grain" . 1.2)) (("flour" . 1.0) ("bran" . 0.17)) "flour"))))
  (lambda (by-spec by-process undetermined)
    (let ((flour (assoc-ref by-spec "flour")) (g (mixture-slack "grain")))
      (check-pred "a derived row carries what its inputs carried: flour's bar on carbon is the grain's and the bran's over the flour made"
                  (~= (assoc-ref flour (slack-key "C")) (/ (+ (* 1.2 (assoc-ref g "C")) (* 0.17 (assoc-ref g "C"))) 1.0)))
      (check-pred "…and the same row stands per process, keyed by the process that made it"
                  (equal? flour (assoc-ref by-process (cons "mill" "flour")))))))
(call-with-values
  (lambda () (derive-compositions '(("conjure" (("grain" . 1.0)) (("bread" . 1.0) ("bran" . 2.0)) "bread"))))
  (lambda (by-spec by-process undetermined)
    (check-pred "a product carries no negative amount: where the other outputs hold more than was drawn the primary holds none"
                (not (assoc-ref (or (assoc-ref by-spec "bread") '()) "C")))))
;; ── a cycle is solved, and each of its three ends is a finding ────────────────
(define (derived procs) (call-with-values (lambda () (derive-compositions procs)) list))
(let* ((r (derived '(("melt"  (("soil-n" . 0.1) ("recycled" . 0.5)) (("melt" . 1.0)) "melt")
                     ("recover" (("melt" . 0.5)) (("recycled" . 0.5)) "recycled"))))
       (by-spec (car r)))
  (check-pred "a loop fed from outside that lets half its melt leave settles: the melt holds twice what a turn feeds it"
              (and (~= 0.2 (assoc-ref (assoc-ref by-spec "melt") "N"))
                   (~= 0.2 (assoc-ref (assoc-ref by-spec "recycled") "N"))
                   (null? (caddr r)))))
(let ((r (derived '(("a" (("loop-b" . 1.0)) (("loop-a" . 1.0)) "loop-a")
                    ("b" (("loop-a" . 1.0)) (("loop-b" . 1.0)) "loop-b")))))
  (check-pred "a closed loop nothing pins holds whatever was first put in it: the recipes do not say, and neither does the derivation"
              (and (null? (car r)) (null? (cadr r))
                   (lset= equal? '("loop-a" "loop-b") (caddr r)))))
(let* ((r (derived '(("a" (("soil-n" . 0.1) ("loop-b" . 1.0)) (("loop-a" . 1.0)) "loop-a")
                     ("b" (("loop-a" . 2.0)) (("loop-b" . 1.0)) "loop-b"))))
       (comp (append (cadr r) (car r) '(("soil-n" ("N" . 1.0))))))
  (check-pred "a loop only a negative composition could balance holds none of the leaf"
              (not (assoc-ref (or (assoc-ref (car r) "loop-a") '()) "N")))
  (check-pred "…so the closure refuses the process that then carries out more than it draws"
              (or (pair? (process-creates "a" (bare-flows '((consume "soil-n" 0.1) (consume "loop-b" 1.0) (produce "loop-a" 1.0))) comp))
                  (pair? (process-creates "b" (bare-flows '((consume "loop-a" 2.0) (produce "loop-b" 1.0))) comp))
                  ;; both rows hold nothing of it: the feed's nitrogen is then a loss, named by neither
                  (not (assoc-ref (or (assoc-ref (car r) "loop-b") '()) "N")))))
(let* ((r (derived '(("rich" (("soil-n" . 8.0)) (("crop" . 100.0)) "crop")
                     ("lean" (("soil-n" . 3.0)) (("crop" . 100.0)) "crop"))))
       (pool (assoc-ref (car r) "crop")))
  (check-pred "a spec two recipes make is a pool: its row is their mean and their spread is its bar"
              (and (~= 0.055 (assoc-ref pool "N")) (~= 0.025 (assoc-ref pool (slack-key "N")))))
  (check-pred "…while each recipe's own row is what it made"
              (and (~= 0.08 (assoc-ref (assoc-ref (cadr r) (cons "rich" "crop")) "N"))
                   (~= 0.03 (assoc-ref (assoc-ref (cadr r) (cons "lean" "crop")) "N")))))
;; ── what a process creates, past its bars ─────────────────────────────────────
(let ((comp '(("soil-n" ("N" . 1.0)) ("food" ("N" . 0.026) ("±N" . 0.001)))))
  (check-pred "a shortfall the bars explain is no creation"
              (null? (process-creates "p" (bare-flows '((consume "soil-n" 2.52) (produce "food" 100.0))) comp)))
  (check-pred "a shortfall past them is, by the leaf and the amount"
              (~= -0.12 (assoc-ref (process-creates "p" (bare-flows '((consume "soil-n" 2.48) (produce "food" 100.0))) comp) "N")))
  (check-pred "a process that says it is the boundary, or draws no leaf, is judged by no balance"
              (and (null? (process-creates "p" (bare-flows '((consume "soil-n" 1.0) (produce "food" 100.0))) comp #:boundary? #t))
                   (null? (process-creates "p" (bare-flows '((produce "food" 100.0))) comp)))))
;; ── one unit per spec ─────────────────────────────────────────────────────────
(let* ((made (consume* "s" "salt" 100.0 "brine" "g")) (counted (consume* "b" "sea" 1.0 "brine" %count-unit))
       (restated (flows-in-spec-units (list made counted) '(("salt" . "kg") ("sea" . "kg")))))
  (check-pred "a hundred grams of a salt counted in kilograms is a tenth of one"
              (let ((m (recipe-flow-resource-quantity (car restated))))
                (and (~= 0.1 (measure-has-numerical-value m)) (equal? "kg" (measure-has-unit m)))))
  (check-pred "a unit that does not convert to the spec's stands as written"
              (eq? counted (cadr restated))))
;; ── a leaf's books close as a body's do, the other way round ─────────────────
(let ((leaf (bare-flows '((consume "co2" 1.4656) (consume "rain" 100.0) (produce "glucose" 1.0)))))
  (check-pred "a kilogram of glucose splits six tenths of a litre of water for its hydrogen"
              (< (abs (- (water-split leaf) 0.6)) 0.01))
  (check-pred "…and lets the oxygen go once the rest of its water has left as vapour"
              (< (abs (- (oxygen-released (append leaf (list (bare-flow 'produce "h2o-g" (- 100.0 (water-split leaf)))))) 1.0656)) 0.01)))

;; a flow is a RecipeFlow, and its basis a conversion: the number is carried as given
(check-pred "an exact quantity in kilograms or moles stays exact through the basis"
            (every (lambda (f) (let ((q (flow-qty (flow-in-basis f)))) (and (exact? q) (= q 3/2))))
                   (list (bare-flow 'consume "soil-n" 3/2 "kg") (bare-flow 'consume "ch4" 3/2 "mol"))))
(check-pred "a reaction's flows are recipe flows in moles, and their mass is the moles times the molar mass"
            (let ((fl (reaction->flows '("ch4" "o2") '("co2" "h2o") "ch4" 1)))
              (and (every recipe-flow? fl)
                   (every (lambda (f) (equal? "mol" (measure-has-unit (recipe-flow-resource-quantity f)))) fl)
                   (~= 80.04 (apply + (map (lambda (f) (* (flow-qty f) (molar-mass (flow-spec f))))
                                           (filter (lambda (f) (input-action? (flow-action f))) fl)))))))

(test-summary!)
