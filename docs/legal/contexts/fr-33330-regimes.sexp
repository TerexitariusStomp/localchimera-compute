;;; fr-33330-regimes.sexp — the regimes Pompignac stands in that are NOT its
;;; jurisdiction chain, and do not nest with each other.
;;;
;;; HAND-AUTHORED from sourced research, unlike fr-33330.sexp which is generated
;;; by tools/law/fetch-fr-gpu.py. It is here because these regimes have no single
;;; open API the way the PLU does: SAGE perimeters come from Gest'eau/Sandre, the
;;; appellation from INAO, the biosphere reserve from the MAB register. Each rule
;;; carries its source; none is `verified` — a steward re-signs them after
;;; checking the cahier des charges and the SAGE règlement.
;;;
;;; The point it demonstrates: Pompignac sits in THREE SAGE water perimeters that
;;; overlap each other, an appellation, and a biosphere transition zone. No two of
;;; them contain one another, so no single-parent `contained-in` tree can hold
;;; them — but each IS a hierarchy of its own, so a flat tag cannot answer a
;;; question about an ancestor either. They ride `within`: each becomes another
;;; endpoint, climbed by the same containment walk, unioned by the same fold.
((places
  ;; the water tree — a SAGE sits inside a SDAGE basin
  ("bassin-adour-garonne" "Bassin Adour-Garonne (SDAGE 2022-2027)" "france" region
   ((authority . "Agence de l'eau Adour-Garonne")) #f #f)
  ("sage-nappes-profondes-gironde" "SAGE Nappes profondes de Gironde"
   "bassin-adour-garonne" region ((authority . "SMEGREG") (statut . "révisé")) #f #f)
  ("sage-estuaire-gironde" "SAGE Estuaire de la Gironde et milieux associés"
   "bassin-adour-garonne" region ((statut . "mis en œuvre")) #f #f)
  ("sage-dordogne-atlantique" "SAGE Dordogne Atlantique"
   "bassin-adour-garonne" region ((statut . "en élaboration")) #f #f)
  ;; the appellation tree
  ("aoc-entre-deux-mers" "AOC Entre-deux-Mers" "france" region
   ((authority . "INAO") (communes . 133)) #f #f)
  ;; the biosphere tree — a transition zone sits inside its reserve
  ("biosphere-dordogne" "Réserve de biosphère du Bassin de la Dordogne" "france" region
   ((authority . "UNESCO MAB / EPIDOR")) #f #f)
  ("biosphere-dordogne-transition" "Bassin de la Dordogne — zone de transition"
   "biosphere-dordogne" region () #f #f)
  ;; …and the commune declares which of them it stands in. `contained-in` stays
  ;; the administrative chain (fr-33330 ⊂ EPCI ⊂ Gironde), untouched.
  ("fr-33330" "Pompignac" "fr-epci-243301355" locality
   ((insee . "33330")
    (within . ("sage-nappes-profondes-gironde" "sage-estuaire-gironde"
               "sage-dordogne-atlantique" "aoc-entre-deux-mers"
               "biosphere-dordogne-transition")))
   #f #f))
 (rules
  ;; Drawing on or emitting into the shared environment anywhere in the basin is
  ;; a declared or authorised act (code de l'environnement, régime IOTA).
  ((all-of (in-jurisdiction "bassin-adour-garonne") (on-crossing eco-draw))
   ((obtain "Déclaration ou autorisation IOTA (loi sur l'eau)" entity
     (volume-preleve point-de-prelevement)
     ((issuer . "DDTM Gironde / Agence de l'eau Adour-Garonne")
      (per . each-site) (direction . #f) (retain . #f) (renew . #f))))
   "adour-garonne/iota" "Code de l'environnement L214-1 et s.; SDAGE Adour-Garonne 2022-2027"
   "20220310" reported "fr-33330")
  ;; The deep-aquifer SAGE is stricter than the basin: its own withdrawal regime
  ;; rides ON TOP of the basin's, which is the union the fold performs.
  ((all-of (in-jurisdiction "sage-nappes-profondes-gironde") (on-crossing eco-draw))
   ((tell "Déclaration de prélèvement en nappe profonde" entity #f
     ((to . "SMEGREG") (discloses . (volume-annuel nappe))
      (direction . #f) (retain . #f) (renew . #f))))
   "sage-nappes-profondes/declaration" "SAGE Nappes profondes de Gironde (arrêté 18 juin 2013)"
   "20130618" uncertain "fr-33330")
  ;; The appellation is a land-use regime with no place in any zoning plan.
  ((all-of (in-jurisdiction "aoc-entre-deux-mers") (on-crossing plant-vines))
   ((tell "Déclaration de plantation en aire délimitée" entity #f
     ((to . "INAO") (discloses . (parcelle cepage densite))
      (direction . #f) (retain . #f) (renew . #f))))
   "inao/entre-deux-mers/plantation"
   "INAO — cahier des charges AOC Entre-deux-Mers (aire parcellaire délimitée)"
   "20091029" uncertain "fr-33330")))
