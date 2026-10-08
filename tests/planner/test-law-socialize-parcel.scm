;;; test-law-socialize-parcel.scm — taking a real parcel into common hands, and
;;; what the state asks when you do.
;;;
;;; This is the question the legal layer was built for. A commune in Pompignac
;;; decides to socialise a field: what does the law ask, what may it then be used
;;; for, and can the planner answer both from data rather than from someone's
;;; recollection?
;;;
;;; Everything here is real: parcel 33330000ZA0295 is 6.2 hectares in zone A of
;;; the PLU in force since 17 Dec 2024 (`tools/law/fetch-fr-parcels.py`), the
;;; transfer demands are cited French statute, and the zoning comes off the
;;; Géoportail de l'Urbanisme.
;;;
;;; What it does NOT show: any of this being recognised by the French state. The
;;; federation can know what would be asked and plan coherently against it. That
;;; is a different thing from a socialisation the state accepts, and the distance
;;; between them is political, not a missing feature — `legal/registry.scm` says
;;; as much when it puts `subjection` outside the fold.
;;;
;;; Run: guile -L module tests/planner/test-law-socialize-parcel.scm

(use-modules (playnet test harness) (playnet planner knowledge recipes store) (playnet planner scope spatial-things) (playnet planner legal crossings) (playnet planner vf schemas) (srfi srfi-1)
             (playnet planner legal registry) (playnet planner legal registry-actor)
             (playnet planner legal gate) (playnet planner legal crossings)
             (playnet planner knowledge law context-pack) (playnet planner facts places)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (srfi srfi-13) (ice-9 format))

(define contexts "docs/legal/contexts")
;;; The two parcels this suite actually uses, inline. The generator writes all
;;; 2,592 to data/law/fr-33330-parcels.sexp — and `/data/` is gitignored, rightly:
;;; three megabytes regenerable from an open API is not repository content, the
;;; TOOL is. But a test reading an ignored path passes here and fails on a fresh
;;; clone, which is a test that cannot run pretending it did. These two rows are
;;; verbatim from that file; `tools/qgis/check-parcels.scm` is what checks all of
;;; them, against the polygons, when someone has generated them.
(define parcel-rows
  '(("33330000ZA0295" "Parcelle ZA 295" "fr-33330" parcel
     ((section . "ZA") (numero . "295") (contenance . 62476)
      (within . ("fr-33330-A")))
     44.861633 -0.444275)
    ("33330000AB0288" "Parcelle AB 288" "fr-33330" parcel
     ((section . "AB") (numero . "288") (contenance . 997)
      (within . ("fr-33330-Ua" "fr-33330-AU")))
     44.850305 -0.438531)))

(define %field    "33330000ZA0295")   ; 6.2 ha, wholly in zone A
(define %straddle "33330000AB0288")   ; 997 m², cut by the Ua/AU line

;; acquiring a thing trips `own-property`; farming it draws on the environment
(define (spec id name tags unit)
  (make-resource-specification #:id id #:name name #:resource-classified-as tags
                               #:default-unit-of-resource unit))

(define (seed! rs)
  (for-each (lambda (s) ($ rs 'add-resource-spec s))
            (list (spec "spec-title" "Titre de propriété" '("crossing:own-property") "parcelle")
                  (spec "spec-crop"  "Récolte"            '("act:agriculture") "kg")
                  (spec "spec-house" "Logement"           '("crossing:built-structure") "m2")
                  (spec "spec-meal"  "Repas partagé"      '("crossing:share-food") "portion")
                  ;; the acts article 2 of the règlement actually permits in zone A
                  (spec "spec-ext"   "Extension d'habitation"
                        '("crossing:built-structure" "act:extension-habitation") "m2")
                  (spec "spec-barn"  "Bâtiment agricole"
                        '("crossing:built-structure" "act:agriculture") "m2")))
  (for-each (lambda (p)
              ($ rs 'add-recipe-process (make-recipe-process #:id (car p) #:name (cadr p)
                                                            #:has-duration (make-duration 1 "hours")))
              ($ rs 'add-recipe-flow
                 (make-recipe-flow #:id (string-append "rf-" (car p)) #:action 'produce #:resource-conforms-to (caddr p)
                                   #:resource-quantity (make-measure 1 "unit") #:recipe-output-of (car p) #:is-primary #t)))
            '(("rp-extend"  "Étendre l'habitation"  "spec-ext")
              ("rp-barn"    "Construire une grange" "spec-barn")
              ("rp-acquire" "Acquérir la parcelle" "spec-title")
              ("rp-farm"    "Cultiver"             "spec-crop")
              ("rp-build"   "Construire"           "spec-house")
              ("rp-share"   "Partager un repas"    "spec-meal"))))

(define out
  (with-vat (spawn-vat)
    (let* ((rs  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
           (sts (spawn ^spatial-thing-store (hashmap)))
           ;; every context pack, plus the commune's own parcels
           (rules (load-context-packs contexts))
           (reg (spawn ^legal-registry rules)))
      (seed! rs)
      ($ sts 'add-location (make-spatial-thing #:id "world" #:name "World"))
      (for-each (lambda (p) (seed-pack-places! sts (pack-place-rows p)))
                (pack-paths contexts))
      (seed-pack-places! sts parcel-rows)
      (for-each place-row->place! parcel-rows)
      (let* ((path-of (spatial-path-reader sts))
             (bill (lambda (proc cell)
                     (let* ((paths (path-of (legal-cell-place cell)))
                            (flows (legal-proc-flows rs proc))
                            (resolve (lambda (id) ($ rs 'get-resource-spec id)))
                            (ctx (legal-context
                                  #:crossings (recipe-crossings flows resolve)
                                  #:place-path (car paths) #:endpoints paths
                                  #:act (or (recipe-act flows resolve) 'activity))))
                       (car ($ reg 'demands ctx)))))
             ;; every demand asked, by name…
             (names (lambda (proc cell)
                      (sort (map demand-name (append-map cdr (bill proc cell))) string<?)))
             ;; …and separately WHAT IS FORBIDDEN, because "is this refused?" is a
             ;; question about the forbid bucket and not about which rule happens
             ;; to be the one refusing today. Naming the rule pinned a snapshot:
             ;; the moment a more faithful reading superseded the coarse one, the
             ;; assertion broke while the answer stayed the same.
             (forbids (lambda (proc cell)
                        (map demand-name (or (assq-ref (bill proc cell) 'forbid) '())))))
        (list (map spatial-thing-id ($ sts 'resolve-chain %field))
              (length (path-of %field))
              (names "rp-acquire" (string-append %field "@0"))
              (names "rp-build"   (string-append %field "@0"))
              (names "rp-farm"    (string-append %field "@0"))
              (names "rp-build"   (string-append %straddle "@0"))
              (names "rp-share"   "fr-33330@0")
              (length (path-of %straddle))
              (names "rp-acquire" (string-append %straddle "@0"))
              (names "rp-extend" (string-append %field "@0"))
              (names "rp-barn"   (string-append %field "@0"))
              (forbids "rp-build"  (string-append %field "@0"))
              (forbids "rp-extend" (string-append %field "@0"))
              (forbids "rp-farm"   (string-append %field "@0")))))))

(define (ref n) (list-ref out n))
(define (has? xs s) (and (member s xs) #t))

(display "\n── a real parcel, in a real chain ──\n")
(format #t "  ~a → ~a\n" %field (ref 0))
(check-pred "the parcel's own chain is administrative: parcel ⊂ commune ⊂ EPCI ⊂ dept ⊂ région ⊂ France ⊂ EU"
            (equal? (ref 0) (list %field "fr-33330" "fr-epci-243301355" "fr-dep-33"
                                  "fr-reg-75" "france" "eu" "world")))
;;; A parcel stands in: its own containment chain, the zone(s) it touches, and
;;; every regime its COMMUNE stands in — the three SAGE water perimeters, the
;;; appellation and the biosphere transition zone reach it through Pompignac,
;;; because `within` is collected at every level of a path and not just the leaf.
;;; So the number to look at is not the count but the DIFFERENCE: a parcel cut by
;;; a zone line carries exactly one endpoint more than a whole one.
(format #t "  a whole parcel stands in ~a endpoint chains; one cut by a zone line, ~a\n"
        (ref 1) (ref 7))
(check-pred "…and its ZONE is a `within` regime, not its container"
            (> (ref 1) 2))
(check-pred "…so the parcel cut by a zone line carries exactly one endpoint more"
            (= (ref 7) (+ 1 (ref 1))))

(display "\n── what France asks to take it into common hands ──\n")
(for-each (lambda (d) (format #t "    · ~a\n" d)) (ref 2))
(check-pred "the transfer needs a notarial act" (has? (ref 2) "Acte authentique de vente (notaire)"))
(check-pred "…published at the service de la publicité foncière"
            (has? (ref 2) "Publication au service de la publicité foncière"))
(check-pred "…and the mutation duty is owed"
            (has? (ref 2) "Droits de mutation à titre onéreux"))
(check-pred "…and because it is AGRICULTURAL land, the SAFER must be notified and may pre-empt"
            (has? (ref 2) "Notification SAFER (déclaration d'intention d'aliéner)"))

;;; …and the negative, which is what makes `place-has` a classification rather
;;; than a rule that fires everywhere: the same national sentence must NOT reach
;;; a parcel that is not agricultural.
(format #t "  acquiring the URBAN parcel instead:\n")
(for-each (lambda (d) (format #t "    · ~a\n" d)) (ref 8))
(check-pred "the notarial act, the publication and the duty are owed for any land"
            (and (has? (ref 8) "Acte authentique de vente (notaire)")
                 (has? (ref 8) "Publication au service de la publicité foncière")
                 (has? (ref 8) "Droits de mutation à titre onéreux")))
(check-pred "…but the SAFER does not pre-empt an urban parcel — the classification, not the chain, decides"
            (not (has? (ref 8) "Notification SAFER (déclaration d'intention d'aliéner)")))

(display "\n── and what it may then be used for ──\n")
(format #t "  build here: ~a\n  farm here : ~a\n" (ref 3) (ref 4))
(check-pred "building on it is FORBIDDEN — zone A, and the act is not farming"
            (pair? (ref 11)))
(check-pred "farming it is not forbidden at all — which is what a zone A is for"
            (null? (ref 13)))
(check-pred "…and an extension is not forbidden either, once the prose is read"
            (null? (ref 12)))

;;; ─── what the RÈGLEMENT itself says, not the category ────────────────────
;;; The generated pack knows only `typezone A` and its statutory meaning. The
;;; prose says more, and `fr-33330-reglement.sexp` carries it, read from
;;; 33330_reglement_20241212.pdf ch. 4 art. 1–2 p. 36: everything is forbidden
;;; EXCEPT what is necessary to farming and the list article 2 gives — services
;;; publics, reconstruction after a disaster, an extension of an existing
;;; dwelling, annexes. Each is an act, and rides the recipe's own `act:` tag.
(display "\n── what the règlement itself permits ──\n")
(format #t "  a new house  : ~a\n" (ref 3))
(format #t "  an extension : ~a\n" (ref 9))
(format #t "  a barn       : ~a\n" (ref 10))
(check-pred "a new dwelling is refused — by the category rule AND by article 1 read from the text"
            (has? (ref 3) "Zone A — toute occupation du sol autre que celles des articles 1 et 2"))
(check-pred "an EXTENSION of an existing dwelling is permitted — article 2, which the category rule could not know"
            (not (has? (ref 9) "Zone A — toute occupation du sol autre que celles des articles 1 et 2")))
(check-pred "…and the faithful reading SUPERSEDES the coarse one, or the union would forbid it anyway"
            (not (has? (ref 9) "construction non nécessaire à l'exploitation agricole")))
(check-pred "…and a farm building is permitted by both readings"
            (and (not (has? (ref 10) "construction non nécessaire à l'exploitation agricole"))
                 (not (has? (ref 10) "Zone A — toute occupation du sol autre que celles des articles 1 et 2"))))

(display "\n── the parcel cut by a zone line meets both zones ──\n")
(check-pred "…and is doubly wrapped: the permis of its urban zone still reaches it"
            (has? (ref 5) "Permis de construire"))

(display "\n── France is in the EU, and that is not decoration ──\n")
(for-each (lambda (d) (format #t "    · ~a\n" d)) (ref 6))
;;; The EU food-safety rules were in `de.sexp` all along, guarded on
;;; `in-jurisdiction "eu"`. While the adapter placed France under `world` they
;;; could never reach a French cell — a whole body of law loaded and unreachable,
;;; and nothing would have said so. One edge in the chain is the difference.
(check-pred "sharing food in Pompignac meets the EU food-business registration"
            (has? (ref 6) "Registrierung als Lebensmittelunternehmer"))
(test-summary!)
