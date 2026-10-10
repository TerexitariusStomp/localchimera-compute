;;; federation/crossing-set.scm — which goods cross, read off the records.
;;;
;;; The supply a scope holds is not the scope's to withhold: the stock and the
;;; stated demand are already in its records, so the goods it DEALS IN are a
;;; reading of those records and not a declaration anyone makes. A good crosses
;;; when at least two scopes deal in it, and which of them gives and which
;;; draws is the solve's answer, read off the sign of a flow. No roles, no
;;; lists to keep: a scope that asks for bread deals in the flour that bakes it,
;;; and the scope that holds the flour has it to cross.
;;;
;;; Pure over the VF records (playnet vf schemas).
;;;
;;; What a scope deals in is what it HOLDS and what it ASKS FOR, with what its
;;; asking needs: the inputs of the recipes that make a good it asks for, and
;;; of those that make those, to the raw. The recipes themselves are shared
;;; knowledge, the same catalogue in every scope, so a recipe alone says
;;; nothing about the scope that carries it; the demand it is read from does.
;;; Reading the whole catalogue would make every good every scope's.
;;;
;;; Left out: the labour that does the work (a `work` flow's skill, and the
;;; resource that records someone holding the skill) and the capacity a `use`
;;; or `cite` flow draws on. Labour has its own fold and means have their own
;;; consensus row; neither is a good that changes hands.

(define-module (playnet federation crossing-set)
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet vf facts partition)
  #:use-module ((playnet solve compile) #:select (upstream-closure))
  #:export (commune-goods crossing-goods))

(define (commune-goods resources flows demand-specs)
  "The goods a scope deals in, as a sorted list of spec ids: what RESOURCES
   (economic resources) hold and DEMAND-SPECS (the specs its stated demand asks
   for) with what FLOWS (recipe flows) consume to make them, less every skill a
   `work` flow names and every spec only a `use` or `cite` flow draws on."
  (let* ((spec-of   recipe-flow-resource-conforms-to)
         (act       (lambda (f) (recipe-flow-action f)))
         (labour    (filter-map (lambda (f) (and (eq? (act f) 'work) (spec-of f))) flows))
         (capacity  (filter-map (lambda (f) (and (memq (act f) nonconsuming-input-actions) (spec-of f))) flows))
         (material  (filter-map (lambda (f) (and (memq (act f) *flow-actions*) (spec-of f))) flows))
         (held      (filter-map economic-resource-conforms-to resources))
         (dealt     (append held (call-with-values (lambda () (upstream-closure flows demand-specs))
                                          (lambda (specs _procs) specs))))
         (structural (lset-difference equal? (delete-duplicates (append labour capacity))
                                      material)))
    (sort (lset-difference equal? (delete-duplicates dealt) structural) string<?)))

(define (crossing-goods censuses)
  "CENSUSES is ((scope good …) …). The goods at least two scopes deal in,
   sorted — what crosses. A good one scope deals in alone has nobody to cross
   to. (The count is `held-twice`: a good is a record held by more than one
   scope.)"
  (sort (map car (held-twice censuses)) string<?))
