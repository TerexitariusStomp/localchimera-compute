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
  #:use-module ((playnet utils records) #:select (define-vf-record vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields vf-record-copier))
  #:use-module ((playnet planner vf serdes) #:select (register-vf-records! register-vf-record!))
  #:export (make-batch-lot-record))

;;; BatchLotRecord — tracking for serialized/lot-controlled resources.
;;; Fields: id (string), batch-lot-code? (string), expiration-date? (ISO datetime string),
;;;         expiration-kind? ('best-before | 'use-by): which date the label states.
;;;         A good past its best-before passes on with a notice; a good past its
;;;         use-by does not pass on (docs/planning/food/berlin-verteilstation-requirements.md).
(define-vf-record <batch-lot-record> BatchLotRecord
  (id batch-lot-code expiration-date expiration-kind)
  #:register register-vf-record!)

;; Smart constructor: `expiration-kind` is keyword-only and last, so every
;; three-positional call site stands as written; serdes round-trips it through
;; the raw constructor, and a record stored before the field reads it as #f.
(define %make-batch-lot-record             (vf-record-constructor <batch-lot-record>))
(define* (make-batch-lot-record id batch-lot-code expiration-date
                                #:key (expiration-kind #f))
  (%make-batch-lot-record id batch-lot-code expiration-date
                          (and (memq expiration-kind '(best-before use-by))
                               expiration-kind)))

;; ── persistence: these records register their own types ─────────────────────
;; each type registers itself as it is declared (define-vf-record #:register)
