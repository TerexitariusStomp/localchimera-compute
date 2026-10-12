;;; test-retention-disclosure.scm — retention + disclosure minimization (the
;;; compliance §13 open thread: where filing artifacts live, how long, and the
;;; pseudonymity floor).
;;;
;;; (1) DISCLOSURE MINIMIZATION: a filing carries only the fields its door
;;;     requires, and NEVER a field below the pseudonymity floor in the clear —
;;;     the scope files as a stable pseudonym, not as the natural people behind
;;;     it. A required-but-floored field with no pseudonym surfaces as a `withheld`
;;;     TENSION (the steward sees it), not a silent over-share.
;;; (2) RETENTION HORIZON: minimization across TIME — an artifact is kept only
;;;     until its obligation closes plus the statutory keep-period, then dropped;
;;;     the drop is itself a VF event so the deletion is auditable.
;;; Pure data ⇒ no blake3.
;;;
;;; Run: guile -L module tests/legal/test-retention-disclosure.scm

(use-modules (playnet test harness) (playnet vf schemas) (srfi srfi-1) (ice-9 format))

(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet legal compliance)) (use-modules (playnet legal filings))

;;; ─── (1) disclosure minimization + the pseudonymity floor ─────────────────
;; canonical data the federation holds about the scope — including things that
;; live BELOW the pseudonymity floor (the natural person, their home address).
(define canonical
  '((applicant           . "FoodCo Commons LLC")   ; the mask's own (public) name
    (site                . "12 Market St")
    (owner-legal-name    . "Jane Q. Realperson")   ; ← below the floor
    (owner-home-address  . "9 Private Lane")))      ; ← below the floor
;; the door asks for four fields; two are below the floor.
(define required '(applicant site owner-legal-name owner-home-address))
(define floor    '(owner-legal-name owner-home-address))
;; we can file the responsible party as a stable steward-pseudonym, but we have
;; NO pseudonym to stand in for a raw home address — so that one must be withheld.
(define pseudonyms '((owner-legal-name . "scope:food.foodville (responsible steward)")))

(define d (minimize-disclosure canonical required #:floor floor #:pseudonyms pseudonyms))
(define disclosed (assq-ref d 'disclosed))
(define withheld  (assq-ref d 'withheld))

(display "\n── (1) disclosure minimization: only the door's fields, floor respected ──\n")
(format #t "  disclosed: ~s\n" disclosed)
(format #t "  withheld : ~s\n" withheld)
(check-pred "the public fields pass through verbatim"
            (and (equal? (assq-ref disclosed 'applicant) "FoodCo Commons LLC")
                 (equal? (assq-ref disclosed 'site) "12 Market St")))
(check-pred "the natural person's legal name is replaced by the scope pseudonym, never raw"
            (and (string-prefix? "scope:" (assq-ref disclosed 'owner-legal-name))
                 (not (equal? (assq-ref disclosed 'owner-legal-name) "Jane Q. Realperson"))))
(check-pred "the raw home address never appears in the disclosed set"
            (not (assq-ref disclosed 'owner-home-address)))
(check "a required-but-floored field with no pseudonym surfaces as a withheld tension"
       withheld '(owner-home-address))
(check-pred "nothing beyond the four required keys is disclosed (no over-share)"
            (null? (lset-difference eq? (map car disclosed) required)))

;; a door that asks for nothing sensitive discloses cleanly, withholds nothing.
(define clean (minimize-disclosure canonical '(applicant site) #:floor floor))
(check-pred "a door needing only public fields withholds nothing"
            (null? (assq-ref clean 'withheld)))

;;; ─── (1b) the template OWNS its disclosure surface (declarative field-spec) ─
;; the field-map is DATA — form-field ← canonical key, floor/pseudonym inline —
;; so render + disclosure both derive from it, and it serializes to a country-pack.
(define permit-tmpl
  (filing-template "Food Establishment Permit Application"
    #:jurisdiction 'foodville #:demand-name "Food Establishment Permit" #:version "2026.1"
    #:fields '((applicant   (canonical applicant))
               (site        (canonical site))
               (activity    (const "retail food vending"))
               (responsible (canonical owner-legal-name floor "scope:food.foodville (responsible steward)"))
               (home        (canonical owner-home-address floor)))   ; floored, NO pseudonym → withheld
    #:source "foodville Health Code §4" #:as-of "2026-01-01"
    #:confidence 'verified #:steward "scope:food.foodville"))
(define pv (filing-preview permit-tmpl canonical #:filer "scope:foodco"))
(define pv-fields   (assq-ref pv 'fields))
(define pv-withheld (assq-ref pv 'withheld))
(display "\n── (1b) a declarative template owns its disclosure surface ──\n")
(format #t "  fields  : ~s\n" pv-fields)
(format #t "  withheld: ~s\n" pv-withheld)
(check-pred "the template renders public fields + a constant — no caller-supplied render"
            (and (equal? (assq-ref pv-fields 'applicant) "FoodCo Commons LLC")
                 (equal? (assq-ref pv-fields 'activity) "retail food vending")))
(check-pred "a floored identity field is pseudonymized by the template itself"
            (string-prefix? "scope:" (assq-ref pv-fields 'responsible)))
(check-pred "the raw home address never renders" (not (assq-ref pv-fields 'home)))
(check "the template SURFACES the floored-without-pseudonym field as withheld"
       pv-withheld '(home))
;; the payoff: a declarative template SERIALIZES to a country-pack and back.
(check-pred "the template round-trips through write/read (a portable country-pack)"
            (filing-template->sexp permit-tmpl))
(check "…and the reloaded template renders identically"
       (call-with-values (lambda () (template-disclose (sexp->filing-template (filing-template->sexp permit-tmpl))
                                                        canonical))
         (lambda (f w) f))
       pv-fields)

;;; ─── (2) retention horizon: keep as long as required, then drop ───────────
;; three held artifacts, closed on the same day, different statutory windows.
(define filings
  (list `((said . "E-tax")    (demand . "Sales Tax Return")          (closed . "2020-03-01"))  ; 7y → 2027
        `((said . "E-permit") (demand . "Food Establishment Permit") (closed . "2020-03-01"))  ; 3y → 2023
        `((said . "E-vendor") (demand . "Vendor Registration")       (closed . "2024-03-01")))) ; 3y → 2027

(define sweep-2024 (retention-sweep filings "2024-06-01" #:filer "scope:foodco"))
(define sweep-2028 (retention-sweep filings "2028-06-01" #:filer "scope:foodco"))
(define (swept s) (map (lambda (e) (assq-ref e 'said)) s))

(display "\n── (2) retention sweep: drop only artifacts past their statutory horizon ──\n")
(format #t "  as-of 2024-06: horizons ~s → drop ~s\n"
        (map (lambda (f) (retain-until (assq-ref f 'closed) (assq-ref f 'demand))) filings) (swept sweep-2024))
(format #t "  as-of 2028-06:                         → drop ~s\n" (swept sweep-2028))
(check "as-of 2024, only the 3-year permit (horizon 2023) is past its window"
       (swept sweep-2024) '("E-permit"))
(check "as-of 2028, every window (2027/2023/2027) has passed — all three drop"
       (sort (swept sweep-2028) string<?) '("E-permit" "E-tax" "E-vendor"))
(check-pred "the drop is a `lower` EconomicEvent classed \"dropped\" (auditable deletion)"
            (let ((ev (assq-ref (car sweep-2024) 'drop)))
              (and (eq? (economic-event-action ev) 'lower)
                   (member "dropped" (economic-event-resource-classified-as ev)))))
(check "the tax return is retained the full 7 years, not dropped early"
       (retain-until "2020-03-01" "Sales Tax Return") "2027-03-01")

;; retention travels WITH the rule: a demand carries its own statutory keep-period,
;; stamped onto the filing; that per-artifact window overrides the fallback library.
(define d-tax (obtain #:rides 'entity #:name "Sales Tax Return" #:retain 10))
(check "a demand carries its statutory keep-period as data (not a global side-table)"
       (demand-retain d-tax) 10)
(define stamped (list `((said . "E-stamped") (demand . "Food Establishment Permit")
                        (retain . 10) (closed . "2020-03-01"))))   ; library default is 3y → 2023
(check-pred "a filing's OWN stamped window (10y → 2030) overrides the 3y library default"
            (null? (retention-sweep stamped "2028-06-01")))         ; still within 10y — not swept

(display "\n")
(test-summary!)
