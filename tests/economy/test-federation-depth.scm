;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-federation-depth.scm — the federation resolver reaches arbitrarily deep.
;;;
;;; A means socialized into the commons must be findable wherever it physically
;;; sits, however deep in the federation tree — the pull twin of labour's
;;; arbitrarily-deep fold. federation-resource-resolver walks the WHOLE subtree
;;; (each ^scope = its own scope-root's resources + its members, recursively), read
;;; fresh each solve so it stays correct under refederation, and cycle-guarded so a
;;; refederated loop can't hang it. This checks: (1) a bike three levels down is
;;; found from the root; (2) two bikes in different deep branches are both found;
;;; (3) a cycle in the tree terminates.
;;;
;;; Run:  guile -L module -L tests tests/economy/test-federation-depth.scm

(use-modules ((localchimera utils units) #:select (%count-unit)))
(use-modules (localchimera test harness)
             (localchimera vf schemas) (srfi srfi-1)
             (localchimera credentials custody) (localchimera economy socialization)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define OWNER "EAlice")
(define UC    "EUniversalCommune")
(define FUTURE "2099-12-31T00:00:00Z")

;; a resource of SPEC with a distinct id, so we can count what the resolver finds.
(define (res id spec)
  (make-economic-resource #:id id #:conforms-to spec #:classified-as '()
                          #:onhand-quantity (make-measure 1 %count-unit) #:current-location "town" #:primary-accountable OWNER))

;; a COMMUNE leaf: a scope holding RESOURCES in its own observer, no sub-scopes.
(define (commune resources)
  (let* ((obs  (spawn ^mock `((all-resources . ,(lambda () resources)))))
         (root (spawn ^mock `((observer . ,(lambda () obs))))))
    (spawn ^mock `((scope-root . ,(lambda () root))
                   (members    . ,(lambda () (hashmap)))))))

;; a FEDERATION node: no economic root of its own, just sub-scopes.
(define (federation . members)
  (let ((hm (fold (lambda (m acc) (hashmap-set acc (car m) (cdr m)))
                  (hashmap) members)))
    (spawn ^mock `((scope-root . ,(lambda () #f))
                   (members    . ,(lambda () hm))))))

(define vat (spawn-vat #:name "federation-depth"))

(with-vat vat
  (let ()
    (define grant-cred (make-custody-attestation-credential #:issuing-authority-aid OWNER
                                                            #:custodian-aid UC
                                                            #:resource-spec "bike"
                                                            #:qty 4))

    ;; ── (1) a bike three levels deep, found from the root ──
    ;; UC → region → district → leaf(bike)
    (let* ((leaf     (commune (list (res "res:bike" "bike"))))
           (district (federation (cons "leaf" leaf)))
           (region   (federation (cons "district" district)))
           (uc       (federation (cons "region" region)))
           (resolve  (federation-resource-resolver uc))
           (found    (resolve grant-cred)))
      (check "a bike 3 levels deep is found from the root"
             (= 1 (length found)))
      (check "the found resource is the right one"
             (equal? "res:bike" (economic-resource-id (car found)))))

    ;; ── (2) two bikes in different deep branches, both found ──
    (let* ((leafA   (commune (list (res "res:bikeA" "bike"))))
           (leafB   (commune (list (res "res:bikeB" "bike"))))
           (branchA (federation (cons "a" leafA)))
           (branchB (federation (cons "b" leafB)))
           (uc      (federation (cons "A" branchA) (cons "B" branchB)))
           (resolve (federation-resource-resolver uc))
           (found   (resolve grant-cred)))
      (check "two bikes in different deep branches are both found"
             (= 2 (length found)))
      (check "both branches' resources are present"
             (equal? '("res:bikeA" "res:bikeB")
                     (sort (map economic-resource-id found) string<?))))

    ;; ── (3) a DAG (commune shared by two federations) is not double-counted ──
    (let* ((shared  (commune (list (res "res:bike" "bike"))))   ; ONE leaf...
           (branchA (federation (cons "s" shared)))            ; ...reached two ways
           (branchB (federation (cons "s" shared)))
           (uc      (federation (cons "A" branchA) (cons "B" branchB)))
           (resolve (federation-resource-resolver uc))
           (found   (resolve grant-cred)))
      (check "a shared commune is visited once, not double-counted"
             (= 1 (length found))))

    ;; ── (4) a refederation CYCLE terminates (no hang) ──
    ;; Build a node whose members include a proxy that points back to the root.
    (let* ((leaf (commune (list (res "res:bike" "bike"))))
           (back (make-parameter #f))
           (loopy (spawn ^mock `((scope-root . ,(lambda () #f))
                                 (members    . ,(lambda ()
                                   (hashmap-set (hashmap-set (hashmap) "leaf" leaf)
                                                "back" (back)))))))
           (_ (back loopy))                       ; loopy is a member of itself
           (resolve (federation-resource-resolver loopy))
           (found   (resolve grant-cred)))
      (check "a cycle terminates and still finds the reachable bike"
             (= 1 (length found))))))

(test-summary!)
