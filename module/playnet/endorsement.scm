;;; module/playnet/endorsement.scm — Capability-governed endorsement primitives
;;; Pure library. Hoot-compatible. Uses Goblins sealers.
;;;
;;; The ACL → Capability shift: instead of checking WHO is calling,
;;; check WHAT they hold. Endorsement = sealed capability object.
;;;
;;; Persistence-correct: all endorsement primitives return Goblins actor
;;; refs (not lambda wrappers). Sealers from spawn-sealer-triplet are
;;; already actors — serializable by Goblins persistence.

(define-module (playnet endorsement)
  #:use-module (goblins)
  #:use-module (goblins actor-lib sealers)
  #:use-module (ice-9 receive)
  #:export (make-endorsement-authority
            endorse
            endorsed-value
            endorsed-with?
            make-facet
            facet?
            facet-name-pred
            facet-sealed?-actor
            facet-matches?
            facet-satisfied?
            make-faceted-validator
            ^faceted-validator
            make-attenuated-authority
            ^name-predicate
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

(define (make-endorsement-authority)
  "Create an endorsement authority.
   Returns (values seal-actor unseal-actor sealed?-actor).
   All three are Goblins actor refs — serializable and persistent.

   Usage:
     (receive (seal unseal sealed?) (make-endorsement-authority)
       (define endorsed-val ($ seal my-value))
       (display ($ sealed? endorsed-val))  ;; #t
       (display ($ unseal endorsed-val)))  ;; my-value

   Must be called within a vat context."
  (spawn-sealer-triplet))

;;; ── Core operations ────────────────────────────────────────────────────────

(define (endorse value seal-actor)
  "Seal VALUE with SEAL-ACTOR. Returns an endorsed bundle."
  ($ seal-actor value))

(define (endorsed-with? sealed?-actor value)
  "Check if VALUE was endorsed with this authority."
  ($ sealed?-actor value))

(define (endorsed-value unseal-actor bundle)
  "Extract the value from an endorsed bundle."
  ($ unseal-actor bundle))

;;; ── Name predicate actor ──────────────────────────────────────────────────

(define-actor (^name-predicate bcom spec)
  "Data-driven name predicate. Fully serializable.
   spec: (prefix \"str\") | (suffix \"str\") | (set (sym ...)) | (any) | (none)"
  (lambda (name)
    (let ((kind (car spec)))
      (cond
       ((eq? kind 'prefix)
        (let ((p (cadr spec))
              (name-str (if (string? name) name (symbol->string name))))
          (string-prefix? p name-str)))
       ((eq? kind 'suffix)
        (let ((s (cadr spec))
              (name-str (if (string? name) name (symbol->string name))))
          (string-suffix? s name-str)))
       ((eq? kind 'set)
        (and (memv name (cadr spec)) #t))
       ((eq? kind 'any) #t)
       ((eq? kind 'none) #f)
       (else (error "Unknown name-predicate spec:" spec))))))

;;; ── Facets ─────────────────────────────────────────────────────────────────

(define (make-facet name-pred sealed?-actor)
  "A facet: governs names matching name-pred, requires endorsement by sealed?-actor.
   name-pred: actor ref (^name-predicate) or plain procedure
   sealed?-actor: the sealed? actor ref from make-endorsement-authority"
  (list 'facet name-pred sealed?-actor))

(define (facet? x) (and (pair? x) (eq? (car x) 'facet)))
(define (facet-name-pred f) (cadr f))
(define (facet-sealed?-actor f) (caddr f))

(define (facet-matches? f name)
  "Check if facet F governs NAME. Handles both actor and procedure name-preds."
  (let ((pred (facet-name-pred f)))
    (if (procedure? pred)
        (pred name)
        ($ pred name))))

(define (facet-satisfied? f value)
  "Check if VALUE satisfies facet F's endorsement requirement."
  ($ (facet-sealed?-actor f) value))

;;; ── Faceted validator ──────────────────────────────────────────────────────

(define (make-faceted-validator facets)
  "Compose a validator from a list of facets. Returns a plain lambda.
   For persistence-correct version, use (spawn ^faceted-validator facets).

   Unprotected names (no matching facet): always allowed.
   Protected names: value must be endorsed with that facet's authority.

   The expressor parameter is ignored — we check possession, not identity.
   This is the ACL -> Cap shift: identity doesn't matter, endorsement does."
  (lambda (expressor name value pre-bindings post-bindings)
    (let ((governing (%filter (lambda (f) (facet-matches? f name)) facets)))
      (if (null? governing)
          #t
          (%any (lambda (f) (facet-satisfied? f value)) governing)))))

(define-actor (^faceted-validator bcom facets)
  "Faceted validator as a Goblins actor. facets is a list of facet alists.
   Fully serializable — sealed?-actors and name-pred actors in facets
   are actor refs that persist with the vat.

   Called by ^org as: ($ validator-actor expressor name value pre post)"
  (lambda (expressor name value pre-bindings post-bindings)
    (let ((governing (%filter (lambda (f) (facet-matches? f name)) facets)))
      (if (null? governing)
          #t
          (%any (lambda (f) (facet-satisfied? f value)) governing)))))

;;; ── Attenuated authority ───────────────────────────────────────────────────

(define (make-attenuated-authority parent-sealed?-actor sub-name-pred)
  "Create an attenuated sub-authority.
   Returns (values seal-actor unseal-actor sealed?-actor).
   All three are Goblins actor refs — serializable and persistent.
   Name restriction is enforced by make-facet's name-pred, not here.
   Must be called within a vat context."
  (spawn-sealer-triplet))

;;; ── Name predicate helpers ─────────────────────────────────────────────────

(define (name-prefix-predicate prefix)
  "Spawn a ^name-predicate actor matching symbols starting with prefix.
   Must be called within a vat context."
  (spawn ^name-predicate
         `(prefix ,(if (symbol? prefix) (symbol->string prefix) prefix))))

(define (name-set-predicate names)
  "Spawn a ^name-predicate actor matching any name in the given list.
   Must be called within a vat context."
  (spawn ^name-predicate `(set ,names)))
