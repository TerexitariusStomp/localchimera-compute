;;; test-legal-derogation.scm — the one precedence the fold cannot express as a guard.
;;;
;;; Most apparent precedence is missing CONTEXT, not missing precedence: a
;;; threshold is two rules with complementary guards, and "unless agricultural"
;;; is `negate (act-is …)`. Both already work. A hierarchy of norms — a PLU that
;;; must conform to its SCoT — is a question of VALIDITY a prefect settles, not
;;; something the fold decides.
;;;
;;; What is irreducible is a derogation by ANOTHER AUTHORITY. France exempts a
;;; construction under 5 m² from every formality (code de l'urbanisme R421-2) and
;;; replaces the permis with a déclaration préalable under 20 m² (R421-9). Neither
;;; rule can be written into Pompignac's PLU pack: the commune did not make them
;;; and does not own that file. The commune's rule is correct at its own level,
;;; and the fold's union is still the wrong answer.
;;;
;;; The key is the demand NAME, because one national derogation must reach any
;;; number of communal rules — naming rule labels would mean naming thousands.
;;; That name is already the join key: `demand-name` IS `demand->spec-id`, the id
;;; a held permit conforms to.
;;;
;;; Run: guile -L module tests/planner/test-legal-derogation.scm

(use-modules (playnet test harness) (playnet planner knowledge recipes store) (playnet planner scope spatial-things) (playnet planner observation observer) (playnet planner vf schemas) (srfi srfi-1)
             (playnet planner legal registry) (playnet planner legal registry-actor)
             (playnet planner legal gate)
             (playnet planner knowledge law context-pack)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

(define pack "docs/legal/contexts/fr-33330.sexp")
(define %permis "Permis de construire")

;; the national derogations, as a pack from a different authority would carry them
(define* (under-5 #:key (confidence 'verified))
  (rule (all-of (in-jurisdiction "france") (on-crossing 'built-structure)
                (asset-has 'classified-as "surface:under-5m2"))
        '()                                   ; exempt: it asks for nothing at all
        #:label "fr/R421-2/exemption" #:cancels (list %permis)
        #:source "Code de l'urbanisme R421-2" #:confidence confidence
        #:steward "france"))

(define under-20
  (rule (all-of (in-jurisdiction "france") (on-crossing 'built-structure)
                (asset-has 'classified-as "surface:under-20m2"))
        ;; a derogation that REPLACES rather than removes — one rule, not two
        (list (tell #:name "Déclaration préalable" #:to "Mairie"))
        #:label "fr/R421-9/declaration" #:cancels (list %permis)
        #:source "Code de l'urbanisme R421-9" #:confidence 'verified
        #:steward "france"))

(define (spec id name tags unit)
  (make-resource-specification #:id id #:name name #:resource-classified-as tags
                               #:default-unit-of-resource unit))
(define (built id spec-id place tags)
  (make-economic-resource #:id id #:name id #:conforms-to spec-id #:classified-as tags
    #:accounting-quantity (make-measure 1 "unit") #:onhand-quantity (make-measure 1 "unit") #:current-location place #:primary-accountable "fr-33330" #:custodian-scope "fr-33330" #:state "active"))

(define (seed! rs)
  (for-each (lambda (s) ($ rs 'add-resource-spec s))
            (list (spec "spec-house" "Maison" '("crossing:built-structure") "m2")
                  (spec "spec-shed"  "Abri"   '("crossing:built-structure") "m2")))
  (for-each (lambda (p)
              ($ rs 'add-recipe-process (make-recipe-process #:id (car p) #:name (cadr p)
                                                            #:has-duration (make-duration 8 "hours")))
              ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append "rf-" (car p)) #:action 'produce
                                        #:resource-conforms-to (caddr p) #:resource-quantity (make-measure 1 "m2") #:recipe-output-of (car p) #:is-primary #t)))
            '(("rp-house" "Construire une maison" "spec-house")
              ("rp-shed"  "Construire un abri"    "spec-shed"))))

;; a scope standing under Pompignac's PLU, plus whatever national rules are given
(define (bills-under national)
  (with-vat (spawn-vat)
    (let* ((rs  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
           (sts (spawn ^spatial-thing-store (hashmap)))
           (obs (spawn ^observer (empty-observer-state) '()))
           (reg (spawn ^legal-registry (append (load-context-pack pack) national))))
      (seed! rs)
      ($ sts 'add-location (make-spatial-thing #:id "world" #:name "World"))
      (seed-pack-places! sts (pack-place-rows pack))
      ;; the things themselves carry the surface class the national rule reads
      ($ obs 'seed-resource (built "res-house" "spec-house" "fr-33330-Ud1" '()))
      ($ obs 'seed-resource (built "res-shed"  "spec-shed"  "fr-33330-Ud1"
                                   ;; under 5 m² is also under 20 — both national
                                   ;; thresholds can read the same thing
                                   '("surface:under-5m2" "surface:under-20m2")))
      (let ()
        (define (names proc)
          (let ((bh ($ reg 'demands
                       (let ((paths ((spatial-path-reader sts) "fr-33330-Ud1")))
                         (legal-context #:crossings '(built-structure)
                                        #:place-path (car paths) #:endpoints paths
                                        #:assets (legal-assets-at
                                                  obs (spatial-path-reader sts)
                                                  (legal-proc-flows rs proc)
                                                  "fr-33330-Ud1"))))))
            (sort (map demand-name (append-map cdr (car bh))) string<?)))
        (list (names "rp-house") (names "rp-shed"))))))

(display "\n── a communal demand, derogated from by the nation ──\n")
(define base (bills-under '()))
(format #t "  PLU alone      · house ~a\n                 · shed  ~a\n" (car base) (cadr base))
(check-pred "Pompignac's own PLU asks a permis for both — it knows nothing of surface"
            (and (member %permis (car base)) (member %permis (cadr base))))

(define derogated (bills-under (list (under-5))))
(format #t "  + R421-2       · house ~a\n                 · shed  ~a\n"
        (car derogated) (cadr derogated))
(check-pred "the house still needs the commune's permis"
            (member %permis (car derogated)))
(check-pred "the shed does not — a NATIONAL rule reached a COMMUNAL demand by name"
            (not (member %permis (cadr derogated))))
(check-pred "…and the commune's pack was not edited to say so"
            (member %permis (car base)))

(display "\n── a derogation may replace rather than remove ──\n")
(define replaced (cadr (bills-under (list under-20))))
(format #t "  + R421-9       · shed  ~a\n" replaced)
(check-pred "under 20 m² the permis is gone and a déclaration préalable stands in its place"
            (and (not (member %permis replaced))
                 (member "Déclaration préalable" replaced)))

(display "\n── confidence gates the strong effect ──\n")
(define unsure (bills-under (list (under-5 #:confidence 'uncertain))))
(format #t "  uncertain derogation · shed ~a\n" (cadr unsure))
(check-pred "a derogation the pack is UNCERTAIN of does not erase a demand the law is sure of"
            (member %permis (cadr unsure)))

;;; ─── the mechanism is LEVEL-AGNOSTIC ─────────────────────────────────────
;;; Every legal system this could meet has tiers between the nation and the
;;; commune, and they differ everywhere: France SRADDET → SCoT → PLU, Germany
;;; LEP → Regionalplan → Bauleitplan under an Anpassungspflicht, a US state
;;; preempting municipal zoning (SB9, ADU statutes), a Dutch province instructing
;;; municipalities, an English permitted-development order.
;;;
;;; They divide into TWO mechanics, and only one is the fold's business:
;;;
;;;   conformity — the higher plan constrains what the lower plan may SAY. It is
;;;     settled when the lower plan is adopted, before any solve reads it, so the
;;;     fold sees a conforming text either way. Not precedence; not modelled.
;;;   derogation — the higher level directly changes what an ACTIVITY needs. That
;;;     is fold-time, and it is this.
;;;
;;; A derogation is guarded on a jurisdiction like any other rule, so the level it
;;; comes from is just which id it names. Nothing distinguishes a national rule
;;; from a departmental one but the place in the guard.
(define departement
  (rule (all-of (in-jurisdiction "fr-dep-33") (on-crossing 'built-structure)
                (asset-has 'classified-as "surface:under-5m2"))
        '() #:label "gironde/derogation" #:cancels (list %permis)
        #:source "(an intermediate tier)" #:confidence 'verified #:steward "fr-dep-33"))

(display "\n── an INTERMEDIATE tier derogates the same way ──\n")
(define mid (bills-under (list departement)))
(format #t "  département    · house ~a\n                 · shed  ~a\n" (car mid) (cadr mid))
(check-pred "a département-level rule reaches the commune's demand exactly as the nation's did"
            (and (member %permis (car mid)) (not (member %permis (cadr mid)))))

;;; ─── one permit standing in for many ─────────────────────────────────────
;;; Germany's Planfeststellungsbeschluss has Konzentrationswirkung: the one
;;; decision REPLACES every other permit the project would have needed. That is a
;;; rule that cancels several demands and makes one — the same primitive, used at
;;; its limit.
(define konzentration
  (rule (all-of (in-jurisdiction "france") (on-crossing 'built-structure))
        (list (obtain #:rides 'entity #:name "Décision unique"))
        #:label "test/konzentrationswirkung"
        #:cancels (list %permis "Étude de sol — périmètre d'effondrement (carrières souterraines)")
        #:confidence 'verified #:steward "test"))

(display "\n── one decision standing in for many ──\n")
(define concentrated (car (bills-under (list konzentration))))
(format #t "  house ~a\n" concentrated)
;;; The PROPERTY, not a snapshot of the pack: everything the decision names is
;;; gone and the decision stands in its place. Asserting the bill equalled
;;; exactly one demand pinned the pack's whole contents, and broke the moment the
;;; generator learned to read one more prescription — a test failing because the
;;; data got better is a test measuring the wrong thing.
(check-pred "a single decision cancels every demand it concentrates…"
            (not (any (lambda (d) (member d concentrated))
                      (legal-rule-cancels konzentration))))
(check-pred "…and stands in their place"
            (member "Décision unique" concentrated))

(display "\n── it survives the pack format ──\n")
(define round (sexp->rule (rule->sexp (under-5))))
(check "cancels round-trips" (legal-rule-cancels round) (list %permis))
(define old-form (list-head (rule->sexp (under-5)) 7))
(check-pred "a pack written before `cancels` existed reads as cancelling nothing"
            (null? (legal-rule-cancels (sexp->rule old-form))))
(test-summary!)
