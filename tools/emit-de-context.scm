;;; emit-de-context.scm — write the German/Berlin context pack.
;;;
;;;   guile -L module tools/emit-de-context.scm [OUT]        (make de-pack)
;;;
;;; `make check-de-fresh` regenerates it and refuses a stale committed copy.
;;;
;;; Emits ONE drop-in file — the whole cost of teaching the legal fold a new
;;; jurisdiction:
;;;
;;;   docs/legal/contexts/de.sexp
;;;     places : world ⊃ eu ⊃ germany ⊃ berlin | brandenburg
;;;     rules  : the law that answers the food crossings there
;;;
;;; It is plain data (law/context-pack.scm), so the committed artifact reads and
;;; diffs like any other generated-and-committed table in knowledge/ (cf.
;;; worlds/berlin-derived.scm).
;;;
;;; ── PROVENANCE ────────────────────────────────────────────────────────────
;;; Every rule below carries its citation and loads at confidence 'reported: the
;;; statutes are real and named, and a steward in the jurisdiction promotes a row
;;; to 'verified once they have checked it against current practice. Confidence
;;; is load-bearing — legal/gate.scm treats an `uncertain` forbid as a soft cost
;;; instead of a hard prune.
;;;
;;; THE STRUCTURAL POINT the German rows make, against the US content: there is
;;; no cottage-food / food-freedom tier here. One proportionate hygiene regime
;;; reaches a home kitchen and a commercial one alike (852/2004 Anhang II Kap.
;;; III), and the competence rides a PERSON via §43 IfSG. So the same recipe that
;;; runs paperwork-free in Wyoming meets a registration plus a per-handler
;;; Belehrung in Berlin — a difference the fold derives, with nothing about
;;; Germany written into any recipe.

(add-to-load-path (dirname (dirname (current-filename))))
(define here (dirname (current-filename)))
(define root (dirname here))
(define (rel p) (string-append root "/" p))

(use-modules (playnet vf schemas))
(use-modules (playnet legal registry))
(use-modules (playnet legal crossings))
(use-modules (playnet vf facts places))
(use-modules (playnet knowledge law context-pack))

(use-modules (ice-9 format))

;;; ─── the places ───────────────────────────────────────────────────────────
;;; The EU sits between the world and its member states, so an intra-EU arc finds
;;; "eu" as its common ancestor and an EU-wide rule reaches every member with one
;;; guard. Adding France later is one more `register-nation!` under it.
(register-region! "eu" "European Union" "world")
(register-nation! "germany" "Germany" "276" #:parent "eu" #:lat 51.0 #:long 10.0)
(register-region! "berlin" "Berlin" "germany" #:lat 52.52 #:long 13.40
                  #:extra '((ags . "11")))
(register-region! "brandenburg" "Brandenburg" "germany" #:lat 52.40 #:long 13.00
                  #:extra '((ags . "12")))

(define %de-place-ids '("eu" "germany" "berlin" "brandenburg"))

;;; ─── the law ──────────────────────────────────────────────────────────────
(define %as-of "2026-01-01")
(define (de-rule guard demands label source)
  (rule guard demands #:label label #:source source
        #:as-of %as-of #:confidence 'reported #:steward "scope:ffd.de"))

(define %de-rules-written
  (list
   ;; ── EU : anyone who hands on food is a Lebensmittelunternehmer, free or not.
   ;;    One registration with the local authority, HACCP-based procedures.
   (de-rule (all-of (in-jurisdiction "eu")
                    (any-of (on-crossing 'share-food) (on-crossing 'congregate-meal)
                            (on-crossing 'home-kitchen) (on-crossing 'recover-surplus)))
            (list (obtain #:rides 'entity #:name "Registrierung als Lebensmittelunternehmer"
                          #:issuer "Lebensmittelüberwachung (Veterinär- und Lebensmittelaufsicht)"
                          #:per 'one-time
                          #:spec '(haccp-verfahren hygieneschulung eigenkontrolle)))
            "eu/food-business-registration"
            "VO (EG) Nr. 852/2004 Art. 6 Abs. 2 und Anhang II; LFGB §§ 5–6")

   ;; ── EU : recovered food carries one-step-back / one-step-forward records.
   ;;    The retain period rides the rule, so the filing stamps itself.
   (de-rule (all-of (in-jurisdiction "eu") (on-crossing 'recover-surplus))
            (list (obtain #:rides 'entity #:name "Rückverfolgbarkeitssystem"
                          #:issuer "Lebensmittelüberwachung" #:per 'one-time
                          #:spec '(lieferant abnehmer datum menge) #:retain 2))
            "eu/food-traceability"
            "VO (EG) Nr. 178/2002 Art. 18 (Rückverfolgbarkeit)")

   ;; ── EU : a home kitchen is permitted ground, held to proportionate hygiene.
   ;;    The structural contrast with the US cottage-food belt — no exemption
   ;;    tier, one regime scaled to the room.
   (de-rule (all-of (in-jurisdiction "eu") (on-crossing 'home-kitchen))
            (list (obtain #:rides 'entity
                          #:name "Hygienenachweis für überwiegend privat genutzte Räume"
                          #:issuer "Lebensmittelüberwachung" #:per 'one-time
                          #:spec '(reinigung schaedlingsschutz getrennte-lagerung)))
            "eu/home-kitchen-hygiene"
            "VO (EG) Nr. 852/2004 Anhang II Kapitel III")

   ;; ── DE : the competence rides a PERSON — the food-handler-card twin.
   (de-rule (all-of (in-jurisdiction "germany")
                    (any-of (on-crossing 'share-food) (on-crossing 'congregate-meal)))
            (list (obtain #:rides 'person #:name "Belehrung nach §43 IfSG"
                          #:issuer "Gesundheitsamt" #:per 'each-handler
                          #:spec '(erstbelehrung folgebelehrung) #:retain 2))
            "de/ifsg-belehrung"
            "Infektionsschutzgesetz (IfSG) §43 Abs. 1")

   ;; ── DE : serving a meal on site is a temporary Gestattung, not a Konzession.
   (de-rule (all-of (in-jurisdiction "germany") (on-crossing 'congregate-meal))
            (list (obtain #:rides 'entity #:name "Vorübergehende Gaststättengestattung"
                          #:issuer "Ordnungsamt / Bezirksamt" #:per 'each-event
                          #:spec '(hygiene sicherheit sperrzeit)))
            "de/gaststaetten-gestattung"
            "Gaststättengesetz §12; Berlin: Gaststättengesetz des Landes Berlin §4")

   ;; ── BERLIN : public street land is the crossing the city itself answers —
   ;;    the structural twin of Houston's consented-site registration.
   (de-rule (all-of (in-jurisdiction "berlin") (on-crossing 'feed-in-public))
            (list (obtain #:rides 'entity
                          #:name "Sondernutzungserlaubnis (öffentliches Straßenland)"
                          #:issuer "Bezirksamt — Straßen- und Grünflächenamt"
                          #:per 'each-site
                          #:spec '(flaeche zeitraum verkehrssicherheit rueckbau)))
            "berlin/sondernutzung"
            "Berliner Straßengesetz (BerlStrG) §11")

   ;; ── BERLIN : the VERTEILSTATION — a public fridge/shelf anyone may take from.
   ;;    Source: Verbraucherzentrale Berlin, "Leitfaden für die kostenlose
   ;;    Weitergabe von Lebensmitteln in öffentlichen Einrichtungen" (6 June 2023),
   ;;    which implements the Berliner Mindestanforderungen of the Senatsverwaltung
   ;;    für Justiz und Verbraucherschutz (2016) and was written with the
   ;;    bezirkliche Lebensmittelüberwachung Berlin-Pankow. Vendored at
   ;;    docs/reference/berlin-food/leitfaden-verteilstationen.pdf; catalogued in
   ;;    docs/planning/food/berlin-verteilstation-requirements.md.
   ;;
   ;;    The station registers once with its Bezirk, naming a responsible person
   ;;    AND a deputy. Unannounced inspection follows at any time.
   (de-rule (all-of (in-jurisdiction "berlin") (on-crossing 'public-fridge))
            (list (obtain #:rides 'entity #:name "Registrierung der Verteilstation"
                          #:issuer "Bezirksamt — Veterinär- und Lebensmittelaufsicht"
                          #:per 'each-site
                          #:spec '(verantwortliche-person vertretung)))
            "berlin/verteilstation-registrierung"
            "Berliner Mindestanforderungen (SenJustV 2016); VZ Berlin Leitfaden 2023 §6")

   ;; the hygiene competence, ANNUAL — the LMHV twin of the §43 IfSG Belehrung
   (de-rule (all-of (in-jurisdiction "berlin") (on-crossing 'public-fridge))
            (list (obtain #:rides 'person #:name "Hygiene-/HACCP-Schulung nach §4 LMHV"
                          #:issuer "Verbraucherzentrale Berlin" #:per 'each-handler
                          #:spec '(haccp-grundlagen personalhygiene reinigung)
                          #:retain 1 #:renew '(renew-before . 30)))
            "berlin/verteilstation-hygieneschulung"
            "§4 Lebensmittelhygiene-Verordnung (LMHV); VZ Berlin Leitfaden 2023 §5, jährlich zu wiederholen")

   ;; the fee on the IfSG Erstbelehrung — waived for volunteers ("weiße Karte")
   (de-rule (all-of (in-jurisdiction "berlin") (on-crossing 'public-fridge))
            (list (pay #:name "Gebühr IfSG-Erstbelehrung" #:base 'each-person #:rate 20.0))
            "berlin/ifsg-erstbelehrung-gebuehr"
            "VZ Berlin Leitfaden 2023 §5 (20 € einmalig; kostenfreie \"weiße Karte\" für Ehrenamtliche)")

   ;; supervision is a property of the SITE: in sight of staff, or locked
   (de-rule (all-of (in-jurisdiction "berlin") (on-crossing 'public-fridge))
            (list (obtain #:rides 'entity #:name "Ständige Aufsicht der Verteilstation"
                          #:issuer "die Einrichtung selbst" #:per 'each-site
                          #:spec '(sichtweite-des-personals abschliessbar geschulte-annahme)))
            "berlin/verteilstation-aufsicht"
            "VZ Berlin Leitfaden 2023 §4 (geschützter Geschäftsraum, ständige Aufsicht oder verschlossen)")

   ;; the documentation folder — kept at least a year, shown on inspection.
   ;; MONTHLY: the Gesamtkontrolle signed into the Hygieneprotokoll.
   (de-rule (all-of (in-jurisdiction "berlin") (on-crossing 'public-fridge))
            (list (obtain #:rides 'entity #:name "Dokumentation der Verteilstation"
                          #:issuer "die Einrichtung selbst" #:per 'each-site
                          #:spec '(spenden-liste id-liste reinigungs-und-temperaturkontrolle
                                   hygieneprotokoll belehrungsnachweise)
                          #:retain 1 #:renew '(every . month)))
            "berlin/verteilstation-dokumentation"
            "VZ Berlin Leitfaden 2023 §15 (Ordner, mind. 1 Jahr) und §14 (monatliche Gesamtkontrolle)")

   ;; what the station must TELL whoever walks up to it
   (de-rule (all-of (in-jurisdiction "berlin") (on-crossing 'public-fridge))
            (list (tell #:name "Hinweisschilder an der Verteilstation"
                        #:to "die Verbraucher*innen"
                        #:discloses '(zulaessige-lebensmittel mhd-kann-ueberschritten-sein
                                      keine-beruehrung-loser-lebensmittel
                                      entnahme-auf-eigene-verantwortung allergene)))
            "berlin/verteilstation-hinweise"
            "VZ Berlin Leitfaden 2023 §12 (Hinweise für Spende, für Entnahme, Allergenhinweis)")

   ;; recalls reach the station and must reach its visitors
   (de-rule (all-of (in-jurisdiction "berlin") (on-crossing 'public-fridge))
            (list (tell #:name "Lebensmittelwarnungen weitergeben"
                        #:to "die Besucher*innen der Verteilstation"
                        #:discloses '(betroffene-produkte rueckrufgrund)))
            "berlin/verteilstation-rueckrufe"
            "VZ Berlin Leitfaden 2023 §13 (lebensmittelwarnung.de bzw. Verteiler der Berliner Tafel)")

   ;; ── INSURANCE the statute makes a condition of the act. Two covers, and
   ;;    only two, are mandatory for any body in Germany; every other cover an
   ;;    e.V. buys (Vereinshaftpflicht, Gruppen-Unfall, D&O) is contractual and
   ;;    stays out of the law (docs/legal/insurance/README.md). Verified against
   ;;    the statute, so these two carry `verified`, not the pack's default.
   ;;    A titled vehicle on public ways: third-party motor liability, one policy
   ;;    a vehicle, renewed yearly.
   (rule (all-of (in-jurisdiction "germany") (on-crossing 'public-vehicle))
         (list (obtain #:rides 'entity #:name "Kfz-Haftpflichtversicherung"
                       #:issuer "Versicherer" #:per 'each-vehicle
                       #:spec '(kfz-haftpflicht) #:renew '(every . year)))
         #:label "de/kfz-haftpflicht" #:source "§ 1 Pflichtversicherungsgesetz (PflVG)"
         #:as-of %as-of #:confidence 'verified #:steward "scope:ffd.de")
   ;;    Wage labour: the employer alone pays the Berufsgenossenschaft, which
   ;;    insures the employee by law — a levy, not a policy to buy.
   (rule (all-of (in-jurisdiction "germany") (on-crossing 'wage-labour))
         (list (pay #:name "Beitrag zur gesetzlichen Unfallversicherung (Berufsgenossenschaft)"
                    #:base 'payroll #:rate #f))
         #:label "de/bg-beitrag"
         #:source "SGB VII § 2 Abs. 1 Nr. 1, §§ 121 ff., § 150 Abs. 1"
         #:as-of %as-of #:confidence 'verified #:steward "scope:ffd.de")

   ;; ── THE CHANNEL MATRIX : what may not go down a NON-PERSONAL channel ─────
   ;;    The Leitfaden's Stage 1 and foodsharing's own Stage 1 agree almost item
   ;;    for item: into a Fairteiler — a cabinet anyone may open, with nobody
   ;;    present to judge the taker — these may not go. The same goods passed hand
   ;;    to hand (Stage 2) are a judgement call, not a prohibition.
   ;;
   ;;    Each rule guards on (crossing × channel). That pairing is the whole point:
   ;;    a blanket forbid on the crossing alone would prune the chain wherever the
   ;;    good appears, and a forbid on the channel alone would ban the Fairteiler.
   ;;    Together they prune exactly the one column that is actually forbidden —
   ;;    putting THIS good into THAT cabinet — which is what the rule says.
   ;;
   ;;    The list is DATA, one row per item, because it is a list in the source
   ;;    too: the guard shape never varies, only which crossing it names. A
   ;;    steward adding the twelfth item writes one row, not one rule.
   ))

;;; ─── Stage 1 : the not-suitable list, as (crossing × channel) forbids ──────
;;; (crossing            reason (the Leitfaden's own ground)                  label-suffix          §)
(define %stage-1
  '((home-kitchen    "selbst zubereitete Speisen von Privatpersonen gehören nicht in eine Verteilstation"
                     "keine-selbstgekochten"  "§7; foodsharing Stufe 1")
    (congregate-meal "zubereitete warme und gekühlte Speisen gehören nicht in eine Verteilstation"
                     "keine-zubereiteten"     "§7; foodsharing Stufe 1 (zubereitete warme/gekühlte Speisen)")
    (past-use-by     "das Verbrauchsdatum ist überschritten — anders als das MHD eine harte Grenze"
                     "kein-verbrauchsdatum"   "§7 (überschrittenes Verbrauchsdatum); LFGB, LMIV Art. 24")
    (raw-meat        "rohes Fleisch und rohe Wurstwaren gehören nicht in eine unbeaufsichtigte Ausgabe"
                     "kein-rohfleisch"        "§7 (rohes Fleisch, rohe Wurst)")
    (raw-fish        "roher Fisch gehört nicht in eine unbeaufsichtigte Ausgabe"
                     "kein-rohfisch"          "§7 (roher Fisch)")
    (raw-eggs        "rohe Eier gehören nicht in eine unbeaufsichtigte Ausgabe"
                     "keine-roheier"          "§7 (rohe Eier)")
    (raw-milk        "Rohmilch darf nur ab Hof und mit Hinweis abgegeben werden, nicht über eine Verteilstation"
                     "keine-rohmilch"         "Tier-LMHV §17 (Abgabe nur im Milcherzeugungsbetrieb, mit Abkochhinweis)")
    (opened-packaging "geöffnete Verpackungen und angebrochene Flaschen sind nicht weiterzugeben"
                     "keine-geoeffneten"      "§7 (geöffnete Verpackungen oder Flaschen)")
    (bloated-packs   "aufgeblähte Verpackungen deuten auf Verderb — ausgenommen Sauermilchprodukte"
                     "keine-aufgeblaehten"    "§7 (Verpackung darf nicht aufgebläht sein; Ausnahme Sauermilch)")
    (open-sandwich   "belegte Brötchen nur, wenn original verpackt und vollständig gekennzeichnet"
                     "keine-belegten-broetchen" "§7 (belegte Brötchen, außer original verpackt)")
    (open-buffet     "offen angebotene Lebensmittel, die Nehmende berühren könnten, gehören nicht in eine Verteilstation"
                     "kein-offenes-buffet"    "§7 (Angebot, bei dem Kund*innen die Ware berühren können)")
    (foraged-fungi   "selbst gesammelte Pilze gehören nicht in eine Verteilstation"
                     "keine-sammelpilze"      "§7 (selbst gesammelte Pilze)")
    (alcohol         "Alkohol, auch in Pralinen, gehört nicht in eine Verteilstation"
                     "kein-alkohol"           "§7 (Alkohol, auch in Pralinen)")))

(define %stage-1-rules
  (map (lambda (row)
         (let ((crossing (car row)) (reason (cadr row))
               (suffix   (caddr row)) (§ (cadddr row)))
           (de-rule (all-of (in-jurisdiction "berlin")
                            (via-channel 'non-personal)
                            (on-crossing crossing))
                    (list (forbid #:reason reason))
                    (string-append "berlin/verteilstation-" suffix)
                    (if (string-prefix? "§" §)
                        (string-append "VZ Berlin Leitfaden 2023 " §)
                        §))))
       %stage-1))

;;; the pack is the rules written out one by one, plus the ones generated from
;;; the table above — two ways of saying the same kind of thing, and the reader
;;; can see which is which.
(define %de-rules (append %de-rules-written %stage-1-rules))

;;; ─── the pack's own words for federation aspects ──────────────────────────
;;; The rules above state their specs in the law's words. A clause listed here
;;; is another word for an aspect the federation already states
;;; (knowledge/legal-aspects.scm), which is what lets it enter the reform diff;
;;; whether the federation wants the function stays a fact about the aspect. A
;;; clause left out is UNMAPPED and the law face says so. Only a clause with a
;;; plain equivalent is mapped: a closing hour, a deposit to restore the
;;; pavement or a named deputy have no aspect to stand for yet.
(define %de-aspects
  '((hygieneschulung . hygiene-training)       ; VO 852/2004 Anh. II Kap. XII
    (erstbelehrung   . hygiene-training)       ; §43 IfSG
    (folgebelehrung  . hygiene-training)
    (haccp-grundlagen . hygiene-training)      ; §4 LMHV — the training's content
    (personalhygiene . hygiene-training)
    (haccp-verfahren . preventive-control-plan)
    (eigenkontrolle  . preventive-control-plan)
    (lieferant . traceability) (abnehmer . traceability)   ; VO 178/2002 Art. 18
    (datum . traceability) (menge . traceability)
    (reinigung . sanitation) (hygiene . sanitation) (hygieneprotokoll . sanitation)
    (getrennte-lagerung . safe-food-handling)
    (reinigungs-und-temperaturkontrolle . temperature-control)
    (kfz-haftpflicht . third-party-liability)   ; § 1 PflVG
    (unfallversicherung . injury-cover)))       ; SGB VII

;;; ─── write the pack ───────────────────────────────────────────────────────
(define pack-path (if (> (length (command-line)) 1)
                      (cadr (command-line))
                      (rel "docs/legal/contexts/de.sexp")))
(save-context-pack pack-path %de-place-ids %de-rules #:aspects %de-aspects)
(format #t "wrote ~a — ~a places, ~a rules~%"
        pack-path (length %de-place-ids) (length %de-rules))
