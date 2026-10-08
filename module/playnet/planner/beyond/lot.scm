;;; beyond/lot.scm — the lot of a resource: its batch code and its expiry.
;;;
;;; ValueFlows carries `trackingIdentifier` on a resource and defines no class for
;;; a lot. The lot record states the batch or lot code with what the code stands
;;; for: when the lot expires and which kind of date that is. An economic
;;; resource holds one as a field value.
;;;
;;; Route into the core (docs/planning/codebase-organization.md §7): the code is
;;; `trackingIdentifier`; the expiry is `expiresOn` in the older JSON-LD and has
;;; one date and no kind (valueflows-native-inventory.md C7.5).

(define-module (playnet planner beyond lot)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils records) #:select (vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields vf-record-copier))
  #:use-module ((playnet planner vf serdes) #:select (register-vf-records!))
  #:export (<batch-lot-record> make-batch-lot-record batch-lot-record?
            batch-lot-record-id batch-lot-record-batch-lot-code
            batch-lot-record-expiration-date batch-lot-record-expiration-kind))

;;; BatchLotRecord — tracking for serialized/lot-controlled resources.
;;; Fields: id (string), batch-lot-code? (string), expiration-date? (ISO datetime string),
;;;         expiration-kind? ('best-before | 'use-by): which date the label states.
;;;         A good past its best-before passes on with a notice; a good past its
;;;         use-by does not pass on (docs/planning/food/berlin-verteilstation-requirements.md).
(define <batch-lot-record>
  (vf-record-type 'BatchLotRecord
    '((immutable id)
      (immutable batch-lot-code)
      (immutable expiration-date)
      (immutable expiration-kind))))

;; Smart constructor: `expiration-kind` is keyword-only and last, so every
;; three-positional call site stands as written; serdes round-trips it through
;; the raw constructor, and a record stored before the field reads it as #f.
(define %make-batch-lot-record             (vf-record-constructor <batch-lot-record>))
(define* (make-batch-lot-record id batch-lot-code expiration-date
                                #:key (expiration-kind #f))
  (%make-batch-lot-record id batch-lot-code expiration-date
                          (and (memq expiration-kind '(best-before use-by))
                               expiration-kind)))
(define batch-lot-record?                  (vf-record-predicate   <batch-lot-record>))
(define batch-lot-record-id                (vf-record-accessor    <batch-lot-record> 'id))
(define batch-lot-record-batch-lot-code    (vf-record-accessor    <batch-lot-record> 'batch-lot-code))
(define batch-lot-record-expiration-date   (vf-record-accessor    <batch-lot-record> 'expiration-date))
(define batch-lot-record-expiration-kind   (vf-record-accessor    <batch-lot-record> 'expiration-kind))

;; ── persistence: these records register their own types ─────────────────────
(register-vf-records!
  <batch-lot-record>)
