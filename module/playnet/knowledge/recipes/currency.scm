;;; currency.scm — national currencies and internationally recognized stores
;;; of value (gold, silver), as ordinary substitutable medium-of-exchange
;;; ResourceSpecifications.
;;;
;;; EUR and USD already exist elsewhere — household.scm's spec-eur,
;;; the repair recipe's spec-usd — same shape this file uses. Adding a
;;; new currency here is one row, not a new pattern. Gold and silver carry the
;;; identical shape, denominated per gram: a store of value is money that
;;; happens to also be a metal, not a different kind of thing.
;;;
;;; No acquisition recipe is registered here, matching spec-eur/spec-usd's own
;;; precedent: a plain fiat spec enters a plan already-acquired (a purchase, a
;;; donation, a drop-event), the same way those two do today. A currency that
;;; instead needs a GOVERNED acquisition price — the crystallized SNLT every
;;; claim settles at, the way spec-xmr's live pool works — reuses
;;; monero/specs.scm's `bootstrap-external-asset!` directly at scope-bootstrap
;;; time; nothing here has to change for that.

(define-module (playnet knowledge recipes currency)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:export (*currency-fiat-specs* *currency-store-of-value-specs*
            seed-currency-specs))

;; (spec-id name unit) — one row per fiat currency. EUR (spec-eur,
;; household.scm) and USD (spec-usd, the repair recipe) are already
;; registered elsewhere; add a new currency here as a new row.
(define *currency-fiat-specs*
  '(("spec-gbp" "Pound Sterling"    "GBP")
    ("spec-jpy" "Japanese Yen"      "JPY")
    ("spec-chf" "Swiss Franc"       "CHF")
    ("spec-cad" "Canadian Dollar"   "CAD")
    ("spec-aud" "Australian Dollar" "AUD")
    ("spec-cny" "Renminbi"          "CNY")
    ("spec-inr" "Indian Rupee"      "INR")))

;; Same shape, denominated per gram fine metal.
(define *currency-store-of-value-specs*
  '(("spec-gold"   "Gold (fine, by gram)"   "g")
    ("spec-silver" "Silver (fine, by gram)" "g")))

(define (seed-currency-specs recipe-store)
  "Register the currency table: each row substitutable and
   medium-of-exchange, exactly like spec-eur/spec-usd/spec-xmr."
  (define (add-currency! row categories)
    ($ recipe-store 'add-resource-spec
       (make-resource-specification
        #:id (car row) #:name (cadr row) #:resource-classified-as categories #:default-unit-of-resource (caddr row) #:substitutable #t #:medium-of-exchange #t)))
  (for-each (lambda (row) (add-currency! row '("currency" "fiat")))
            *currency-fiat-specs*)
  (for-each (lambda (row) (add-currency! row '("currency" "store-of-value" "precious-metal")))
            *currency-store-of-value-specs*))
