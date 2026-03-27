;;; module/xorg/endorsement.scm — Capability-governed endorsement primitives
;;; Pure library. Hoot-compatible. Uses Goblins sealers.
;;;
;;; The ACL → Capability shift: instead of checking WHO is calling,
;;; check WHAT they hold. Endorsement = sealed capability object.

(define-module (xorg endorsement)
  #:use-module (goblins)
  #:use-module (goblins actor-lib sealers)
  #:use-module (ice-9 receive)
  #:export (make-endorsement-authority
            endorse
            endorsed?
            endorsed-value
            endorsed-with?
            make-facet
            facet?
            facet-name-pred
            facet-sealed?-proc
            make-faceted-validator
            make-attenuated-authority
            name-prefix-predicate
            name-set-predicate))

;;; ── Local helpers (Hoot-compatible, no srfi-1 dependency) ──────────────────

(define (%any pred lst)
  (cond ((null? lst) #f)
        ((pred (car lst)) #t)
        (else (%any pred (cdr lst)))))

(define (%filter pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (%filter pred (cdr lst))))
        (else (%filter pred (cdr lst)))))

;;; ── Endorsement authority ──────────────────────────────────────────────────

(define (make-endorsement-authority name)
  "Create an endorsement authority for a governance domain.
   Returns (values seal-proc unseal-proc sealed?-proc).
   seal-proc:   (lambda (value) -> endorsed-bundle)
   unseal-proc: (lambda (bundle) -> value)
   sealed?-proc: (lambda (bundle) -> bool)
   All three are plain lambdas wrapping Goblins sealer actors.
   Must be called within a vat context."
  (receive (seal unseal sealed?)
    (spawn-sealer-triplet)
    (values
     (lambda (value) ($ seal (cons name value)))
     (lambda (bundle) (cdr ($ unseal bundle)))
     (lambda (value) ($ sealed? value)))))

;;; ── Core operations ────────────────────────────────────────────────────────

(define (endorse value seal-proc)
  "Wrap value with an endorsement using seal-proc.
   The result is opaque — only endorsed-with? and endorsed-value can inspect it."
  (seal-proc value))

(define (endorsed-with? sealed?-proc value)
  "Check if value was endorsed with the authority whose sealed? is sealed?-proc."
  (sealed?-proc value))

(define (endorsed-value unseal-proc bundle)
  "Extract the value from an endorsed bundle.
   Raises error if bundle was not endorsed with this authority."
  (unseal-proc bundle))

(define (endorsed? x . sealed?-procs)
  "Is x endorsed by any of the given sealed? predicates?"
  (%any (lambda (sp) (sp x)) sealed?-procs))

;;; ── Facets ─────────────────────────────────────────────────────────────────

(define (make-facet name-pred sealed?-proc)
  "A facet: governs names matching name-pred, requires endorsement by sealed?-proc.
   name-pred: (lambda (name) -> bool) — which binding names this facet governs
   sealed?-proc: the sealed? predicate from make-endorsement-authority"
  (list 'facet name-pred sealed?-proc))

(define (facet? x) (and (pair? x) (eq? (car x) 'facet)))
(define (facet-name-pred f) (cadr f))
(define (facet-sealed?-proc f) (caddr f))

;;; ── Faceted validator ──────────────────────────────────────────────────────

(define (make-faceted-validator facets)
  "Compose a validator from a list of facets.
   Signature matches current validator: (expressor name value pre post) -> bool

   Unprotected names (no matching facet): always allowed.
   Protected names: value must be endorsed with that facet's authority.

   The expressor parameter is ignored — we check possession, not identity.
   This is the ACL -> Cap shift: identity doesn't matter, endorsement does."
  (lambda (expressor name value pre-bindings post-bindings)
    (let ((governing (%filter (lambda (f)
                                ((facet-name-pred f) name))
                              facets)))
      (if (null? governing)
          #t  ;; no facet governs this name — freely modifiable
          ;; any one satisfied facet is sufficient
          (%any (lambda (f)
                  ((facet-sealed?-proc f) value))
                governing)))))

;;; ── Attenuated authority ───────────────────────────────────────────────────

(define (make-attenuated-authority parent-sealed?-proc sub-name-pred)
  "Create an attenuated sub-authority.
   Returns (values seal-proc unseal-proc sealed?-proc).
   The sub-authority uses its own independent sealer triplet.
   Name restriction is enforced by make-facet's name-pred, not here.
   Must be called within a vat context.

   Usage: Alice holds full econ authority, creates treasury-only sub-authority
   and gives it to Bob. Bob can endorse treasury-* names. Not econ-* in general."
  (receive (sub-seal sub-unseal sub-sealed?)
    (spawn-sealer-triplet)
    (values
     (lambda (value) ($ sub-seal value))
     (lambda (bundle) ($ sub-unseal bundle))
     (lambda (value) ($ sub-sealed? value)))))

;;; ── Name predicate helpers ─────────────────────────────────────────────────

(define (name-prefix-predicate prefix)
  "Returns a name predicate matching symbols starting with prefix."
  (let ((prefix-str (if (string? prefix) prefix (symbol->string prefix))))
    (lambda (name)
      (let ((name-str (if (string? name) name (symbol->string name))))
        (string-prefix? prefix-str name-str)))))

(define (name-set-predicate names)
  "Returns a name predicate matching any name in the given list."
  (lambda (name) (and (member name names) #t)))
