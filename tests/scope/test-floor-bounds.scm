;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-floor-bounds.scm — what a person may declare about their own floor.
;;;
;;; A floor is a hard requirement the commons must meet, so what lifts it is
;;; bounded:
;;;   • the historical-moral STANDARD is a ratified, scope-governed number that
;;;     only raises. A person's own `standard:` tag does not set it: a body that
;;;     declared "standard:3" would otherwise lift its energy floor to three
;;;     times the reference, with the ceiling lifted after it;
;;;   • stacked self-conditions may lift a floor, never above its own ceiling:
;;;     a floor above its ceiling is a plan no one can meet, and it says so
;;;     (`subsistence-clamped`) instead of failing silently.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/scope/test-floor-bounds.scm
(use-modules (playnet test harness)
             (playnet knowledge catalogues subsistence)
             ((playnet scope live) #:select (agent->subsistence-ctx scope-standard))
             ((playnet scope policy) #:select (*governance-policy-defaults*))
             (playnet vf schemas)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define (row bands n) (find (lambda (b) (equal? (car b) n)) bands))
(define (floor-of bands n) (cadr (row bands n)))
(define (ceiling-of bands n) (caddr (row bands n)))
(define (near? a b) (< (abs (- a b)) 1e-6))

(define ada (make-agent #:id "ada" #:type 'person #:classified-as '("sex:F" "age:30" "standard:3")))

(display "\n── the standard is governed, not declared ──\n")
(check "a person's own standard: tag does not lift their floor"
       (near? 1 (assq-ref (agent->subsistence-ctx ada) 'standard)))
(check "the scope's governed standard does, through the one keyword"
       (near? 1.5 (assq-ref (agent->subsistence-ctx ada 0 #f #:standard 1.5) 'standard)))
(check "…and it lifts the energy floor by exactly that factor"
       (near? (* 1.5 (floor-of (subsistence-bands (agent->subsistence-ctx ada)) "energy"))
              (floor-of (subsistence-bands (agent->subsistence-ctx ada 0 #f #:standard 1.5)) "energy")))
(check "the standard only raises: a governed value below 1 reads as 1"
       (near? 1 (assq-ref (agent->subsistence-ctx ada 0 #f #:standard 0.5) 'standard)))
(check "the policy registry states the default: survival, 1"
       (near? 1.0 (or (assq-ref *governance-policy-defaults* 'standard) 0)))
(define vat (spawn-vat #:name "floor-bounds"))
(with-vat vat
  (let ((ps (spawn ^mock `((get-meta . ,(lambda (name) '((standard . 1.4))))))))
    (check "a scope with no plan-store reads the default" (near? 1 (scope-standard #f)))
    (check "a scope that has ratified a standard reads it" (near? 1.4 (scope-standard ps)))))

(display "\n── a floor never stands above its ceiling ──\n")
(define base '((sex . "F") (age . 30)))
(define stacked (append base '((self . ("heavy-menses" "malabsorption" "acid-reducers")))))
(define stacked-bands (subsistence-bands stacked))
(check "stacked conditions leave every floor at or under its ceiling"
       (every (lambda (b) (or (not (caddr b)) (<= (cadr b) (+ (caddr b) 1e-9)))) stacked-bands))
(check "iron, lifted 1.5 × 1.5 × 1.3, is held at its ceiling"
       (near? (floor-of stacked-bands "iron") (ceiling-of stacked-bands "iron")))
(check "the clamp is said, by name: iron was clamped"
       (and (member "iron" (subsistence-clamped stacked)) #t))
(check "a person with no stacked conditions is clamped nowhere"
       (null? (subsistence-clamped base)))
(check "a floor under its ceiling is lifted as stated: zinc, once, by malabsorption's 1.5"
       (near? (floor-of stacked-bands "zinc") (* 1.5 (floor-of (subsistence-bands base) "zinc"))))

(test-summary!)
