;;; fr-33330-reglement.sexp — zone A as the RÈGLEMENT actually writes it.
;;;
;;; The generated pack (fr-33330.sexp) says of a zone A only what the vector
;;; layer carries: `typezone A`, and the statutory meaning of that category —
;;; no building unless it is necessary to farming. That is the principal rule and
;;; it is right, but a règlement is prose and the prose says more.
;;;
;;; This pack is read from the document itself:
;;;   33330_reglement_20241212.pdf, Chapitre 4 « Dispositions applicables en
;;;   zone A », articles 1 and 2, p. 36. Révision approuvée 2013, 1ère
;;;   modification approuvée le 12/12/2024, envoyée en préfecture le 13/12/2024.
;;;
;;; Article 1 — « Sont interdites toutes les occupations et utilisation du sol
;;; exceptées les constructions et installations nécessaires à l'exploitation
;;; agricole et celles prévues à l'article 2. » The generated rule already says
;;; this. What follows is article 2's list, which it could not know, and one
;;; further PROHIBITION the generated pack does not carry at all.
;;;
;;; Each exception is an ACT, and rides the `act:` tag a recipe carries about
;;; itself — the same door zone A's farming exception already uses. A recipe that
;;; says what it is escapes the prohibition; one that says nothing does not.
;;;
;;; NOT ENCODED, and stated rather than dropped:
;;;   · the QUANTITATIVE conditions on an extension — 50% of existing floor area,
;;;     the extension itself ≤100 m², a cumulative ≤300 m² emprise au sol; and on
;;;     annexes — at most 3 per dwelling, ≤60 m² cumulative, never exceeding the
;;;     main building. The demand vocabulary has no comparator, and inventing an
;;;     asset classification to fake one would claim precision this pack has not
;;;     got. They are recorded in each rule's source so a reader meets them.
;;;   · the 2021 flood sectors below are a real prohibition whose GEOMETRY this
;;;     pack does not have: the règlement names « les secteurs qui ont été
;;;     impactés par les inondations de 2021 » without the vector layer marking
;;;     them. The sector is DECLARED as a place with no boundary and no members,
;;;     so the rule is grounded but inert: recorded, lintable, and live the day
;;;     a parcel is said to stand within it.
((places
  ("fr-33330" "Pompignac" "fr-epci-243301355" locality ((insee . "33330")) #f #f)
  ;; A place we know exists and cannot locate. The règlement names the sectors
  ;; the 2021 floods hit; no layer draws them. Declaring it — with no boundary
  ;; and nothing standing within it — records the law and leaves the rule inert
  ;; until someone says which parcels are in it, at which point it begins working
  ;; with no edit here. The alternative was a guard on an unplaced id, which the
  ;; lint rightly calls an error: a rule that can never fire and never says so.
  ("fr-33330-A-inondations-2021" "Pompignac — secteurs inondés en 2021"
   "fr-33330" locality ((geometry . "unlocated") (source . "règlement ch. 4 art. 1")) #f #f))
 (rules
  ;; FIRST, and separately: over zone A this pack's reading REPLACES the generated
  ;; one. That rule reads `typezone A` and excepts only farming, because the
  ;; vector layer carries nothing else; this pack reads article 2 and excepts four
  ;; acts more. Both speak to the same zone and the same crossing, and the fold is
  ;; a union — so the coarser reading would go on forbidding an extension the
  ;; règlement plainly allows.
  ;;
  ;; It must be its OWN rule, carrying no demand. A derogation only takes effect
  ;; from a rule whose guard MATCHED, and the prohibition below deliberately does
  ;; not match an extension — so hanging the cancellation on it would cancel
  ;; nothing in exactly the case that needs it. Supersession is a fact about which
  ;; reading governs here, not about what is forbidden today.
  ((all-of (in-jurisdiction "fr-33330-A") (on-crossing built-structure))
   ()
   "33330/A/reglement-supersedes"
   "Règlement du PLU de Pompignac, ch. 4 — the prose reading of zone A replaces the vector layer's category reading over the same ground."
   "20241212" reported "fr-33330" #f
   ("construction non nécessaire à l'exploitation agricole"))

  ;; ARTICLE 1 + 2, as one prohibition with the exceptions the prose names.
  ;; `act-is` matches an unspecified act, so `any-of` over the permitted acts is
  ;; false when a recipe says nothing about itself — and the prohibition stands.
  ((all-of (in-jurisdiction "fr-33330-A")
           (on-crossing built-structure)
           (negate (any-of (act-is agriculture)
                           (act-is service-public)
                           (act-is reconstruction)
                           (act-is extension-habitation)
                           (act-is annexe))))
   ((forbid "Zone A — toute occupation du sol autre que celles des articles 1 et 2" #f #f
     ((reason . "Zone A — toute occupation du sol autre que celles des articles 1 et 2")
      (direction . #f))))
   "33330/A/reglement-art1"
   "Règlement du PLU de Pompignac, ch. 4 art. 1, p. 36 — « Sont interdites toutes les occupations et utilisation du sol exceptées les constructions et installations nécessaires à l'exploitation agricole et celles prévues à l'article 2. » Article 2 permits: services publics ou d'intérêt collectif (sans compromettre le caractère agricole); reconstruction après sinistre et restauration; extension d'habitation existante (≤50% de la surface de plancher, ≤100 m² d'extension, ≤300 m² d'emprise au sol cumulée); annexes (≤3 par habitation, ≤60 m² cumulés, jamais plus que le bâtiment principal)."
   "20241212" reported "fr-33330")

  ;; …and the prohibition the generated pack does not carry: in the sectors the
  ;; 2021 floods hit, even an extension is refused. No act escapes it.
  ((all-of (in-jurisdiction "fr-33330-A-inondations-2021")
           (on-crossing built-structure))
   ((forbid "Secteur inondé en 2021 — constructions nouvelles et extensions interdites" #f #f
     ((reason . "Secteur inondé en 2021 — constructions nouvelles et extensions interdites")
      (direction . #f))))
   "33330/A/inondations-2021"
   "Règlement du PLU de Pompignac, ch. 4 art. 1, p. 36 — « Dans les secteurs qui ont été impactées par les inondations de 2021, les nouvelles constructions et les extensions des constructions existantes sont interdites. » The sector's geometry is not in the vector layer, so the place is declared without a boundary and nothing stands within it — the rule is recorded and inert until a parcel is said to be in it."
   "20241212" reported "fr-33330")))
