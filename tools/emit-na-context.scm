;;; emit-na-context.scm — write the North American context packs: the United
;;; States, Mexico and Canada.
;;;
;;;   guile -L module tools/emit-na-context.scm us|mexico|canada [OUT]     (make na-packs)
;;;
;;; `make check-na-fresh` regenerates each and refuses a stale committed copy.
;;;
;;; One pack per nation — docs/legal/contexts/{us,mexico,
;;; canada}.sexp — each carrying its places, the law that answers the food and
;;; housing crossings there, the pack's own words for federation aspects, and the
;;; statutes that shield an activity there. The packs are the law; this file is
;;; how they are written, because much of the US content is a PATTERN — a belt of
;;; states with the same act, stated once as a table and expanded to a rule a
;;; state.
;;;
;;; ── PROVENANCE ──────────────────────────────────────────────
;;; Every rule carries its citation and its confidence: `verified` where a
;;; steward has checked the statute, `reported` where it is named from the
;;; literature and awaits one. The belts are illustrative, stewardable sets.

(add-to-load-path (string-append (dirname (dirname (current-filename))) "/module"))

(use-modules (srfi srfi-1)
             (ice-9 format)
             (playnet planner legal registry)
             (playnet planner facts places)
             (playnet planner knowledge catalogues us-states-fips)
             (playnet planner knowledge law context-pack))

(define root (dirname (dirname (current-filename))))
(define (rel p) (string-append root "/" p))

(define nation
  (if (> (length (command-line)) 1) (cadr (command-line)) "us"))
(define out
  (if (> (length (command-line)) 2)
      (caddr (command-line))
      (rel (string-append "docs/legal/contexts/" nation ".sexp"))))

;;; ═══ THE UNITED STATES ═════════════════════════════════════════════════════
;;; State ids are "us-<FIPS>" so they join the map geometry by FIPS; the whole
;;; state list comes from *us-states-fips* (generated from that same geometry).
(define (state-id fips) (string-append "us-" fips))

(define %us-localities            ; that answer a crossing differently than their state
  ;; (id                  name                    parent   lat     long)
  '(("us-06-alameda"      "Alameda County, CA"    "us-06"  37.65  -121.91)
    ("us-12-ftlauderdale" "Fort Lauderdale, FL"   "us-12"  26.12   -80.14)
    ("us-48-houston"      "Houston, TX"           "us-48"  29.76   -95.37)
    ("us-36-nyc"          "New York City, NY"     "us-36"  40.71   -74.01)
    ("us-56-laramie"      "Laramie County, WY"    "us-56"  41.31  -104.69)))

(define (place-us!)
  (register-nation! "us" "United States" "840")
  (for-each (lambda (fp)
              (register-region! (state-id (car fp)) (cdr fp) "us"
                                #:extra `((fips . ,(car fp)))))
            *us-states-fips*)
  (for-each (lambda (row) (apply register-locality! row)) %us-localities)
  (append '("us")
          (map (lambda (fp) (state-id (car fp))) *us-states-fips*)
          (map car %us-localities)))

;;; ─── the FOOD-FREEDOM belt : states whose food-freedom / local-food-choice
;;; acts let homemade food reach an informed end consumer with NO license,
;;; permit, inspection, or certification. Each preempts the generic permit
;;; baseline and answers the home-kitchen / share-food crossings with a bare
;;; informed-consumer notice. (fips-id  act-name  statute)
(define *ffd-food-freedom*
  '(("us-56" "Wyoming Food Freedom Act"                    "Wyo. Stat. §11-49-103 (2015; expanded 2020)")
    ("us-38" "North Dakota Food Freedom Act"               "N.D. Cent. Code ch. 4.1-47 (SB 2170, 2017)")
    ("us-49" "Utah Home Consumption & Homemade Food Act"   "Utah Code §4-5a-103 (HB 181, 2018)")
    ("us-30" "Montana Local Food Choice Act"               "Mont. Code §50-57-101 et seq. (SB 199, 2021)")
    ("us-40" "Oklahoma Homemade Food Freedom Act"          "63 O.S. §1-1101.1 (HB 1032, 2021)")
    ("us-05" "Arkansas Food Freedom Act"                   "Ark. Code §20-57-301 et seq. (Act 1040, 2021)")))
(define *food-freedom-ids* (map car *ffd-food-freedom*))

(define (food-freedom-rule entry)
  (let ((id (car entry)) (name (cadr entry)) (src (caddr entry)))
    (rule (all-of (in-jurisdiction id)
                  (any-of (on-crossing 'share-food) (on-crossing 'home-kitchen)))
          (list (tell #:name "Homemade-food notice" #:to "the recipient"
                      #:discloses '(not-licensed not-inspected)))
          #:label (string-append "food-freedom/" id) #:source src
          #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:ffd")))

;;; ─── the COTTAGE-FOOD belt : states with broad cottage-food / food-
;;; sovereignty laws — homemade food allowed with a ONE-TIME registration
;;; (and usually food-handler training + labeling) rather than a per-event
;;; permit. The middle tier between food freedom and the generic baseline.
;;; An illustrative, stewardable set (every state now has SOME cottage law;
;;; these are the notably broad ones). (fips-id  act-name  statute)
(define *ffd-cottage-food*
  '(("us-23" "Maine Food Sovereignty Act"          "7 M.R.S. §281–284 (LD 725, 2017)")
    ("us-08" "Colorado Cottage Foods Act"          "Colo. Rev. Stat. §25-4-1614 (2012; expanded)")
    ("us-48" "Texas Cottage Food Law"              "Tex. Health & Safety Code §437.001 (HB 970/2218)")
    ("us-33" "New Hampshire Homestead Food"         "N.H. RSA 143-A:12 (Rule He-P 2304)")
    ("us-17" "Illinois Home-to-Market Act"          "410 ILCS 625/4 (SB 2007, 2021)")
    ("us-19" "Iowa Home Food Establishment"         "Iowa Code §137F (HF 2431, 2022)")
    ("us-39" "Ohio Cottage Food Law"                "Ohio Rev. Code §3715.025; OAC 901:3-20")
    ("us-26" "Michigan Cottage Food Law"            "Mich. Comp. Laws §289.4102 (2010)")))
(define *cottage-food-ids* (map car *ffd-cottage-food*))

(define (cottage-food-rule entry)
  (let ((id (car entry)) (name (cadr entry)) (src (caddr entry)))
    (rule (all-of (in-jurisdiction id)
                  (any-of (on-crossing 'share-food) (on-crossing 'home-kitchen)))
          (list (obtain #:rides 'entity #:name "Cottage Food Registration"
                        #:issuer "state agriculture / health dept" #:per 'one-time
                        #:spec '(food-handler-training labeling)))
          #:label (string-append "cottage-food/" id) #:source src
          #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:ffd")))

;;; the reach of the SHARE baseline stops at a belt state: a food-freedom or a
;;; broad cottage-food act answers sharing there, while a congregate meal in the
;;; same state still meets the baseline. The exclusion is about ONE crossing, so
;;; it is a guard. (California replaces the permit for every crossing with its
;;; own — a derogation, which its rule states as `cancels`.)
(define (preempts-default)
  (apply any-of (map in-jurisdiction
                     (append *food-freedom-ids* *cottage-food-ids*))))

;;; ─── the food rules a state or a city states for itself, and the national
;;; baselines ───────────────────────────────────────────────────────────────
(define %us-food-rules
  (list
   ;; ── California — temporary food facility permit + food-handler card for
   ;;    on-site charitable meals; donation itself is shielded (AB-1219).
   (rule (all-of (in-jurisdiction "us-06")
                 (any-of (on-crossing 'congregate-meal) (on-crossing 'share-food)))
         (list (obtain #:rides 'entity #:name "Temporary Food Facility permit"
                       #:issuer "local environmental health" #:per 'each-event
                       #:spec '(handwashing temperature-control overhead-protection))
               (obtain #:rides 'person #:name "CA Food Handler Card"
                       #:issuer "ANSI-accredited provider" #:per 'each-handler
                       #:spec '(hygiene-training)))
         #:label "ca/charitable-feeding"
         #:source "Cal. Health & Safety Code §113700 et seq. (CalCode); §113948 (food handler)"
         #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:ffd.ca"
         ;; CalCode's own permit stands in place of the generic baseline
         #:cancels '("Local Temporary Food permit"))

   ;; ── Fort Lauderdale, FL — outdoor food sharing restricted to permitted
   ;;    sites with sanitation. The duress case (and a 1st-Amendment shield).
   (rule (all-of (in-jurisdiction "us-12-ftlauderdale")
                 (on-crossing 'feed-in-public))
         (list (obtain #:rides 'entity #:name "Outdoor Food Distribution permit"
                       #:issuer "City of Fort Lauderdale" #:per 'each-site
                       #:spec '(restroom-access site-approval sanitation)))
         #:label "fl-ftlauderdale/outdoor-feeding"
         #:source "Fort Lauderdale Ord. C-14-42 (2014); cf. Food Not Bombs v. Ft. Lauderdale, 901 F.3d 1235 (11th Cir. 2018)"
         #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:ffd.fl")

   ;; ── Houston, TX — charitable feeding registration + property-owner
   ;;    consent for public distribution to >5 people.
   (rule (all-of (in-jurisdiction "us-48-houston")
                 (on-crossing 'feed-in-public))
         (list (obtain #:rides 'entity #:name "Charitable Feeding Registration"
                       #:issuer "City of Houston" #:per 'organization
                       #:spec '(food-handler-trained))
               (tell #:name "Property-owner consent"
                     #:to "the City" #:discloses '(site-owner-consent)))
         #:label "tx-houston/charitable-feeding"
         #:source "Houston Code of Ordinances Ch. 20, Art. III (2012)"
         #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:ffd.tx")

   ;; ── New York City — food service establishment permit + a supervisor's
   ;;    Food Protection Certificate for a congregate kitchen.
   (rule (all-of (in-jurisdiction "us-36-nyc")
                 (on-crossing 'congregate-meal))
         (list (obtain #:rides 'entity #:name "Food Service Establishment permit"
                       #:issuer "NYC DOHMH" #:per 'each-kitchen
                       #:spec '(plan-review handwashing temperature-control))
               (obtain #:rides 'person #:name "Food Protection Certificate"
                       #:issuer "NYC DOHMH" #:per 'each-supervisor
                       #:spec '(food-protection-course)))
         #:label "ny-nyc/food-service"
         #:source "NYC Health Code Art. 81 (24 RCNY §81)"
         #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:ffd.ny")

   ;; ── the BORDER is a crossing (§2.6). The interstate case: an arc that
   ;;    crosses at the US level (state→state, same nation) — a light record.
   (rule (all-of (border-level-is "us") (on-crossing 'border))
         (list (tell #:name "Interstate food shipment record"
                     #:to "FDA" #:discloses '(origin destination)))
         #:label "us/interstate-food"
         #:source "21 CFR 1.225–1.227 (food facility registration); FDA model"
         #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:ffd.us")

   ;; ── the INTERNATIONAL case: an arc that crosses at the world level (nation
   ;;    → nation). Now import and export split by SIDE, the truest §2.6: the
   ;;    origin satisfies EXPORT demands, the destination IMPORT demands.
   ;;  EXPORT — leaving the US: a phytosanitary certificate for fresh produce.
   (rule (all-of (border-level-is "world") (on-crossing 'border) (at-origin "us"))
         (list (obtain #:rides 'entity #:name "USDA phytosanitary certificate"
                       #:issuer "USDA APHIS" #:per 'each-shipment
                       #:spec '(pest-free origin-inspected) #:direction 'export))
         #:label "us/food-export" #:source "7 CFR 352 (APHIS export certification)"
         #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:ffd.us")
   ;;  IMPORT — entering the US: FDA prior notice + a foreign-supplier program.
   (rule (all-of (border-level-is "world") (on-crossing 'border) (at-destination "us"))
         (list (tell #:name "FDA prior notice of imported food"
                     #:to "FDA" #:discloses '(shipper product origin) #:direction 'import)
               (obtain #:rides 'entity #:name "Foreign Supplier Verification"
                       #:issuer "FDA (FSMA FSVP)" #:per 'each-importer
                       #:spec '(hazard-analysis supplier-approval) #:direction 'import)
               (pay  #:name "Import duty" #:base 'customs-value #:rate 0.0 #:direction 'import))
         #:label "us/food-import"
         #:source "21 CFR 1.276 (prior notice); 21 CFR 1 subpart L (FSVP); HTSUS (USMCA: duty-free)"
         #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:ffd.us")

   ;; ── US default (congregate) — a congregate MEAL operation needs a local
   ;;    temporary food permit in most states. Food-freedom acts cover homemade
   ;;    food to end consumers, NOT large congregate feeding, so they do NOT
   ;;    preempt this; only California (its own CalCode rule, by `cancels`) does.
   (rule (all-of (in-jurisdiction "us") (on-crossing 'congregate-meal))
         (list (obtain #:rides 'entity #:name "Local Temporary Food permit"
                       #:issuer "local health department" #:per 'each-event
                       #:spec '(safe-food-handling)))
         #:label "us/temporary-food-congregate"
         #:source "state retail food codes (FDA Food Code model); often waived for nonprofit/occasional"
         #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:ffd.us")

   ;; ── US default (share) — simply SHARING food trips the same baseline;
   ;;    its reach stops at the food-freedom and cottage-food belts.
   (rule (all-of (in-jurisdiction "us") (on-crossing 'share-food)
                 (negate (preempts-default)))
         (list (obtain #:rides 'entity #:name "Local Temporary Food permit"
                       #:issuer "local health department" #:per 'each-event
                       #:spec '(safe-food-handling)))
         #:label "us/temporary-food-share"
         #:source "state retail food / cottage-food codes; often waived for nonprofit/occasional"
         #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:ffd.us")))

;;; ─── housing rules : (crossing, jurisdiction) → demand, shared library ────
;;; Building/occupancy is near-universal; ZONING is where jurisdictions diverge
;;; — a "land-use reform" belt (by-right duplex/ADU, ended single-family-only
;;; zoning) parallels the food-freedom belt. occupy-property is forbidden by
;;; default (trespass). Cited, mostly 'reported (a stewardable illustration).
(define *land-use-reform*    ; states that eased zoning → no variance needed
  '(("us-06" "California SB 9 / SB 10 (by-right duplex & lot split)" "Cal. Gov. Code §65852.21 (2021)")
    ("us-41" "Oregon HB 2001 (ended single-family-only zoning)"      "Or. Laws 2019 ch. 639")
    ("us-30" "Montana zoning reform (duplex by right)"               "Mont. SB 323 / SB 528 (2023)")
    ("us-53" "Washington middle-housing"                             "Wash. HB 1110 (2023)")
    ("us-23" "Maine LD 2003 (housing & zoning)"                      "Me. P.L. 2021 ch. 672")))
(define *land-use-reform-ids* (map car *land-use-reform*))

(define (land-use-reform-rule entry)
  (let ((id (car entry)) (name (cadr entry)) (src (caddr entry)))
    (rule (all-of (in-jurisdiction id) (on-crossing 'land-use))
          (list (tell #:name "Ministerial by-right use" #:to "the city"
                      #:discloses '(form-based-compliance)))
          #:label (string-append "land-use-reform/" id) #:source src
          #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:housing"
          ;; by-right use stands in place of the zoning permit: a derogation
          #:cancels '("Zoning compliance / use permit"))))

(define *housing-rules*
  (append
   (map land-use-reform-rule *land-use-reform*)
   (list
    ;; built-structure — a building permit + certificate of occupancy, ~everywhere.
    (rule (all-of (in-jurisdiction "us") (on-crossing 'built-structure))
          (list (obtain #:rides 'entity #:name "Building permit + occupancy certificate"
                        #:issuer "local building department" #:per 'each-structure
                        #:spec '(building-code fire-safety habitability)))
          #:label "us/building-permit" #:source "model building codes (IBC/IRC); local adoption"
          #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:housing")
    ;; land-use — zoning compliance / a use permit; a reform state's by-right
    ;; rule derogates from it (`cancels`, above).
    (rule (all-of (in-jurisdiction "us") (on-crossing 'land-use))
          (list (obtain #:rides 'entity #:name "Zoning compliance / use permit"
                        #:issuer "planning department" #:per 'each-site
                        #:spec '(permitted-use density setbacks)))
          #:label "us/zoning" #:source "local zoning ordinances (Euclidean zoning)"
          #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:housing")
    ;; occupy-property — unlawful occupancy / trespass: a prohibition by default.
    (rule (all-of (in-jurisdiction "us") (on-crossing 'occupy-property))
          (list (forbid #:reason "unlawful occupancy / criminal trespass"))
          #:label "us/trespass" #:source "state trespass codes (squatter's rights vary; adverse possession is slow)"
          #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:housing")
    ;; congregate-shelter — a public-camping ban forbids an outdoor village in
    ;; jurisdictions that enact one (constitutional after Grants Pass, 2024).
    (rule (all-of (in-jurisdiction "us-12") (on-crossing 'congregate-shelter))
          (list (forbid #:reason "public-camping ban"))
          #:label "fl/camping-ban"
          #:source "cf. City of Grants Pass v. Johnson, 603 U.S. ___ (2024) (camping bans permissible)"
          #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:housing"))))

;;; this pack's own words for federation aspects (law/aspects.scm
;;; `clause-aspect`): one function, worded per jurisdiction
(define %us-aspects
  '((food-handler-trained   . hygiene-training)      ; Houston
    (food-handler-training  . hygiene-training)      ; the cottage-food acts
    (food-protection-course . hygiene-training)))    ; NYC, the supervisor's course

;;; ─── protections : shields, NOT demands ───────────────────────────────────
;;; A shield removes risk; it is not a thing the activity must DO, so it stays
;;; out of the demand fold and rides the pack as a fact about the place.
(define %us-protections
  '(((place . "us") (activity . "free-food-distribution")
     (name . "Bill Emerson Good Samaritan Food Donation Act")
     (shields . "good-faith donation of apparently-wholesome food to nonprofits — liability protection")
     (source . "42 U.S.C. §1791 (1996)"))
    ((place . "us-06") (activity . "free-food-distribution")
     (name . "California Good Samaritan Food Donation Act")
     (shields . "donation of food incl. past-date and prepared food, beyond the federal floor")
     (source . "Cal. Health & Safety Code §114432–114434 (AB-1219, 2017)"))
    ((place . "us-12-ftlauderdale") (activity . "free-food-distribution")
     (name . "First-Amendment expressive conduct")
     (shields . "sharing food as expressive association — the outdoor-feeding ban is constitutionally constrained")
     (source . "Food Not Bombs v. Ft. Lauderdale, 901 F.3d 1235 (11th Cir. 2018)"))))

;;; ═══ MEXICO ════════════════════════════════════════════════════════════════
(define (place-mexico!)
  (register-nation! "mexico" "Mexico" "484")
  (register-locality! "mx-tijuana" "Tijuana, BC, Mexico" "mexico" 32.51 -117.04)
  '("mexico" "mx-tijuana"))

(define %mexico-rules
  (list
   ;;  IMPORT — entering Mexico: COFEPRIS sanitary import authorisation.
   (rule (all-of (border-level-is "world") (on-crossing 'border) (at-destination "mexico"))
         (list (obtain #:rides 'entity #:name "COFEPRIS sanitary import authorisation"
                       #:issuer "COFEPRIS" #:per 'each-shipment
                       #:spec '(sanitary-registration labeling-es) #:direction 'import))
         #:label "mx/food-import" #:source "Ley General de Salud, Reglamento de Control Sanitario"
         #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:ffd.mx")
   ;; ── Mexico — internal baseline: a municipal/state sanitary permit to
   ;;    handle and hand out food (the COFEPRIS system reaches down to states).
   (rule (all-of (in-jurisdiction "mexico")
                 (any-of (on-crossing 'congregate-meal) (on-crossing 'share-food)))
         (list (obtain #:rides 'entity #:name "Permiso sanitario municipal"
                       #:issuer "municipio / estado (COFEPRIS)" #:per 'each-event
                       #:spec '(manejo-higienico)))
         #:label "mx/sanitary-permit" #:source "Ley General de Salud; reglamentos estatales"
         #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:ffd.mx")))

(define %mexico-aspects
  '((manejo-higienico . safe-food-handling)))

;;; ═══ CANADA ════════════════════════════════════════════════════════════════
(define (place-canada!)
  (register-nation! "canada" "Canada" "124")
  (register-locality! "ca-toronto" "Toronto, ON, Canada" "canada" 43.65 -79.38)
  '("canada" "ca-toronto"))

(define %canada-rules
  (list
   ;;  IMPORT — entering Canada: CFIA Safe Food for Canadians licence.
   (rule (all-of (border-level-is "world") (on-crossing 'border) (at-destination "canada"))
         (list (obtain #:rides 'entity #:name "CFIA Safe Food for Canadians licence"
                       #:issuer "Canadian Food Inspection Agency" #:per 'each-importer
                       #:spec '(preventive-control-plan traceability) #:direction 'import))
         #:label "ca/food-import" #:source "Safe Food for Canadians Regulations (SOR/2018-108)"
         #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:ffd.ca-nation")
   ;; ── Canada — internal baseline: a provincial/municipal food-premises
   ;;    permit (public-health unit) for a community meal.
   (rule (all-of (in-jurisdiction "canada")
                 (any-of (on-crossing 'congregate-meal) (on-crossing 'share-food)))
         (list (obtain #:rides 'entity #:name "Provincial food-premises permit"
                       #:issuer "provincial public-health unit" #:per 'each-event
                       #:spec '(safe-food-handling)))
         #:label "ca/food-premises" #:source "provincial public health acts (e.g. Ont. Reg. 493/17)"
         #:as-of "2026-01-01" #:confidence 'reported #:steward "scope:ffd.ca-nation")))

;;; ═══ write the pack asked for ══════════════════════════════════════════════
(define-values (place-ids rules aspects protections)
  (cond ((equal? nation "us")
         (values (place-us!)
                 (append (map food-freedom-rule *ffd-food-freedom*)   ; the food-freedom belt (tier 1)
                         (map cottage-food-rule *ffd-cottage-food*)   ; the cottage-food belt  (tier 2)
                         %us-food-rules
                         *housing-rules*)
                 %us-aspects %us-protections))
        ((equal? nation "mexico") (values (place-mexico!) %mexico-rules %mexico-aspects '()))
        ((equal? nation "canada") (values (place-canada!) %canada-rules '() '()))
        (else (error "emit-na-context: a nation is us, mexico or canada" nation))))

(save-context-pack out place-ids rules #:aspects aspects #:protections protections)
(format #t "wrote ~a — ~a places, ~a rules~%" out (length place-ids) (length rules))
