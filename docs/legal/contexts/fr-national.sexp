;;; fr-national.sexp — what France asks of ACQUIRING and TRANSFERRING real
;;; property, and the two insurances the statute makes a condition of an act.
;;; Hand-authored from cited statute, unlike a commune pack, which the
;;; adapter generates: this is code, not a dataset, and no open service publishes
;;; it as rules.
;;;
;;; It matters for socialisation specifically. A commune taking land into common
;;; hands performs a transfer of real property, which trips `own-property` — a
;;; crossing the seed catalogue has carried all along and which nothing guarded
;;; until now. Before this pack the planner would have folded such a move and
;;; found the law silent, which is the failure mode this whole layer exists to
;;; stop: silence that reads as permission.
;;;
;;; The demands are the bedrock of French conveyancing and are stated at
;;; `reported`. What is NOT here: the RATE of the mutation duty (departmental,
;;; and this pack will not guess a number it cannot cite), the notaire's own
;;; tariff, and every consequence that follows from WHO acquires — an association
;;; loi 1901, an SCI, a commune and a cooperative are taxed and empowered
;;; differently, and that turns on the entity, not on the act.
((places
  ;; the pack stands alone; a pack that also places these merges with it
  ("eu" "European Union" "world" region () #f #f)
  ("france" "France" "eu" nation ((iso . "250")) 46.6 2.3))
 (rules
  ;; A transfer of real property is void against third parties unless made by
  ;; acte authentique before a notaire — the act itself, before any tax.
  ((all-of (in-jurisdiction "france") (on-crossing own-property))
   ((obtain "Acte authentique de vente (notaire)" entity
     (identite-des-parties designation-cadastrale prix origine-de-propriete)
     ((issuer . "notaire") (per . each-transfer) (direction . #f)
      (retain . 30) (renew . #f))))
   "fr/acte-authentique"
   "Code civil; décret n° 55-22 du 4 janvier 1955 (publicité foncière)"
   "19550104" reported "france")

  ;; …and published at the service de la publicité foncière, which is what makes
  ;; the transfer good against anyone who was not party to it.
  ((all-of (in-jurisdiction "france") (on-crossing own-property))
   ((tell "Publication au service de la publicité foncière" entity #f
     ((to . "Service de la publicité foncière")
      (discloses . (acte designation-cadastrale parties))
      (direction . #f) (retain . #f) (renew . #f))))
   "fr/publicite-fonciere"
   "Décret n° 55-22 du 4 janvier 1955, art. 28"
   "19550104" reported "france")

  ;; The mutation duty. The demand is certain; its RATE is departmental and is
  ;; deliberately absent rather than guessed — a `pay` with no rate says "this is
  ;; owed" without pretending to say how much.
  ((all-of (in-jurisdiction "france") (on-crossing own-property))
   ((pay "Droits de mutation à titre onéreux" entity #f
     ((base . sale-price) (rate . #f) (direction . #f))))
   "fr/dmto"
   "Code général des impôts, art. 1594 A et s. (taux départemental)"
   "20240101" reported "france")

  ;; The SAFER holds a pre-emption over the sale of agricultural land, and the
  ;; notaire must notify it. Written ONCE, for the nation: `place-has` asks
  ;; whether any place in the chain is classified agricultural, so this reaches
  ;; every commune's A zones without naming one of them. The adapter's job is to
  ;; CLASSIFY the zone, not to repeat this sentence 36,000 times.
  ((all-of (in-jurisdiction "france") (on-crossing own-property)
           (place-has classified-as "agricultural"))
   ((tell "Notification SAFER (déclaration d'intention d'aliéner)" entity #f
     ((to . "SAFER") (discloses . (parcelle prix acquereur))
      (direction . #f) (retain . #f) (renew . #f))))
   "fr/safer-preemption"
   "Code rural et de la pêche maritime, art. L143-1 et s."
   "20240101" reported "france")

  ;; INSURANCE. Two covers are mandatory for any body in France; the rest
  ;; (responsabilité civile outside sport, minors and package travel,
  ;; individuelle accident, protection juridique, auto-mission) is contractual
  ;; and stays out of the law (docs/legal/insurance/README.md). Both verified
  ;; against the statute. A titled vehicle on public ways: third-party motor
  ;; liability, one policy a vehicle, renewed yearly.
  ((all-of (in-jurisdiction "france") (on-crossing public-vehicle))
   ((obtain "Assurance de responsabilité civile automobile" entity
     (responsabilite-civile)
     ((issuer . "assureur") (per . each-vehicle) (direction . #f)
      (retain . #f) (renew . (every . year)))))
   "fr/rc-auto"
   "Code des assurances, art. L211-1"
   "20260101" verified "france")

  ;; Wage labour: the employee is insured for accidents at work by the régime
  ;; général from the first hire, and the employer alone pays the contribution
  ;; to the URSSAF — a levy, not a policy to buy. The RATE is set per
  ;; establishment and is deliberately absent.
  ((all-of (in-jurisdiction "france") (on-crossing wage-labour))
   ((pay "Cotisation accidents du travail / maladies professionnelles (URSSAF)" entity #f
     ((base . payroll) (rate . #f) (direction . #f))))
   "fr/at-mp"
   "Code de la sécurité sociale, art. L311-2 et L411-1"
   "20260101" verified "france")

  ;; WHAT FOLLOWS FROM THE FORM. These key on the ACTOR — the body the scope
  ;; stands behind (`actor-has classified-as "kind:association"`, spelled by
  ;; `actor-kind-is`) — and stand in doubt where nobody named one. The header's
  ;; caveat is answered here: what turns on the entity is written against it.
  ;; An association déclarée may hold the premises of its administration and
  ;; the immeubles strictly necessary to its object; since 2014 one of general
  ;; interest, declared three years, may receive and hold gifts and legacies.
  ;; The law OFFERS that capacity; the fold reads it as a grant.
  ((all-of (in-jurisdiction "france") (on-crossing own-property)
           (actor-has classified-as "kind:association"))
   ((grant "Capacité à recevoir et administrer des libéralités (association d'intérêt général)" entity
     (interet-general declaree-depuis-trois-ans)
     ((issuer . "préfecture (rescrit)") (per . one-time) (base . #f) (rate . #f)
      (retain . #f) (renew . #f))))
   "fr/association-liberalites"
   "Loi du 1er juillet 1901, art. 6 (mod. loi n° 2014-856 du 31 juillet 2014, art. 74)"
   "20140731" reported "france")

  ;; A non-lucrative association with disinterested management is outside the
  ;; impôts commerciaux, and its accessory lucrative receipts are franchised up
  ;; to a ceiling the finance act indexes yearly — the BASE is the receipts, the
  ;; ceiling is not guessed here.
  ((all-of (in-jurisdiction "france") (on-crossing public-sale)
           (actor-has classified-as "kind:association"))
   ((grant "Franchise des impôts commerciaux (IS, TVA, CET)" entity
     (gestion-desinteressee activite-non-lucrative)
     ((issuer . "service des impôts (rescrit fiscal)") (per . one-time)
      (base . receipts) (rate . #f) (retain . #f) (renew . #f))))
   "fr/association-franchise-fiscale"
   "Code général des impôts, art. 206 1 bis et 261 7-1°; BOI-IS-CHAMP-10-50-10-20"
   "20240101" reported "france")

  ;; The occupancy fragment on the books (docs/legal/structure.md §6): a
  ;; personal right of use and habitation, gratuitous, opposable to the owner,
  ;; published at the service de la publicité foncière.
  ((all-of (in-jurisdiction "france") (on-crossing occupancy))
   ((grant "Droit d'usage et d'habitation" entity
     (publie gratuit personnel)
     ((issuer . "notaire; service de la publicité foncière") (per . one-time)
      (base . #f) (rate . #f) (retain . #f) (renew . #f))))
   "fr/droit-usage-habitation"
   "Code civil, art. 625 à 636; décret n° 55-22 du 4 janvier 1955, art. 28"
   "19550104" reported "france"))
 ;; France's words for federation aspects (law/aspects.scm `clause-aspect`).
 ;; The communal packs the adapter generates state a PLU's articles as clauses;
 ;; the ones with a plain equivalent are mapped here, once, for every commune.
 ;; `emprise` is the share of a plot a building may cover and `implantation`
 ;; its distance from the boundaries — the density and setback rules of a zoning
 ;; code. `cavite` and `fondations` are the ground study a collapse perimeter
 ;; asks for, a matter of structural safety. Height, outward appearance and the
 ;; content of a notarial deed have no aspect to stand for yet and stay unmapped.
 (aspects
  (emprise . density)
  (implantation . setbacks)
  (cavite . building-code)
  (fondations . building-code)
  (responsabilite-civile . third-party-liability)   ; Code des assurances L211-1
  (accidents-du-travail . injury-cover)))           ; CSS L411-1
