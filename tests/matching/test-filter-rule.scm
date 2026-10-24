;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-filter-rule.scm — the slot's eligibility rule: the evaluator, the
;;; criteria sidecar parser, and the feasibility pre-gate that reads both.
;;; Run: guile -L module tests/matching/test-filter-rule.scm

(use-modules (localchimera test harness)
             (localchimera vf schemas)
             (localchimera matching schemas)
             (localchimera matching feasibility)
             (localchimera matching filter-rule))

(define ctx '((aid . "A1") (recognition . 0.6) (scopes . ("s1"))
              (skills . ("spec-bread")) (groups . ("friends")) (distance-km . 4)))

(display "\n── the evaluator, clause by clause ──\n")
(check "absent rule allows"          (rule-passes? #f ctx) #t)
(check "true allows"                 (rule-passes? #t ctx) #t)
(check "aid in"                      (rule-passes? #("aid" "A1" "B") ctx) #t)
(check "aid out"                     (rule-passes? #("aid" "B") ctx) #f)
(check "not-aid"                     (rule-passes? #("not-aid" "A1") ctx) #f)
(check "min-recognition met"         (rule-passes? #("min-recognition" 0.5) ctx) #t)
(check "min-recognition short"       (rule-passes? #("min-recognition" 0.7) ctx) #f)
(check "min-recognition unknown denies" (rule-passes? #("min-recognition" 0.1) '((aid . "x"))) #f)
(check "in-scope"                    (rule-passes? #("in-scope" "s9" "s1") ctx) #t)
(check "has-skill"                   (rule-passes? #("has-skill" "spec-bread") ctx) #t)
(check "in-group"                    (rule-passes? #("in-group" "family" "friends") ctx) #t)
(check "in-group, no such rel"       (rule-passes? #("in-group" "family") ctx) #f)
(check "in-group with no book denies" (rule-passes? #("in-group" "friends") '((aid . "x"))) #f)
(check "vouched, with a signed vouch" (rule-passes? #("vouched") (context #:aid "z" #:vouched #t)) #t)
(check "vouched, with none denies"   (rule-passes? #("vouched") ctx) #f)
(check "the context names groups"    (assq-ref (context #:aid "z" #:groups '("kin")) 'groups) '("kin"))
(check "within-km"                   (rule-passes? #("within-km" 5) ctx) #t)
(check "within-km too far"           (rule-passes? #("within-km" 2) ctx) #f)
(check "within-km unknown passes"    (rule-passes? #("within-km" 5) '((aid . "x"))) #t)
(check "and"                         (rule-passes? #("and" #("aid" "A1") #("has-skill" "spec-bread")) ctx) #t)
(check "or / not"                    (rule-passes? #("or" #("not" #("aid" "A1")) #("in-scope" "s1")) ctx) #t)
(check "an unknown clause denies"    (rule-passes? #("frobnicate" 1) ctx) #f)
(check "a preset by name"            (rule-passes? (rule-preset "deny-all") ctx) #f)

(display "\n── the sidecar parser ──\n")
(define c (criteria-json->alist
           "{\"filter-rule\":[\"min-recognition\",0.5],\"min-atomic-size\":2,\"online-link\":\"\",\"priority\":null}"))
(check "known keys only, blanks dropped" (map car c) '(filter-rule min-atomic-size))
(check "the rule stays an array"    (vector? (criteria-ref c 'filter-rule)) #t)
(check "absent → #f"                (criteria-json->alist "") #f)
(check "garbage → #f"               (criteria-json->alist "{nope") #f)
(check "JSON false on the rule is nobody, not absent"
       (rule-passes? (criteria-ref (criteria-json->alist "{\"filter-rule\":false}") 'filter-rule) ctx) #f)

;; ── the feasibility pre-gate: score-affinity is 0 when either side's rule
;; denies the other; recognition is read from the side's own weights.
(display "\n── feasibility reads the rule bilaterally ──\n")
(define (intent id action agent)
  ;; a bare intent: id action name … provider/receiver placed by ACTION side
  (make-intent #:id id #:action action #:resource-conforms-to "spec-bread"
               #:provider (if (eq? action 'consume) #f agent) #:receiver (if (eq? action 'consume) agent #f) #:in-scope-of '("s1")))
(define (crit rule)
  (make-intent-matching-criteria "x" #f #f #f #f #f #f #f #f #f #f '() #f #f rule))
(define need  (make-intent-binding (intent "n1" 'consume "bob")
                                   #:weights '(("carla" . 0.9) ("dev" . 0.2))))
(define offer-ok  (make-intent-binding (intent "o1" 'produce "carla")))
(define offer-locked
  (make-intent-binding (intent "o2" 'produce "carla")
                       #:criteria (crit #("not-aid" "bob"))))
(define need-trusting
  (make-intent-binding (intent "n2" 'consume "bob")
                       #:weights '(("carla" . 0.9) ("dev" . 0.2))
                       #:criteria (crit #("min-recognition" 0.5))))
(define offer-dev (make-intent-binding (intent "o3" 'produce "dev")))
(check "no rules: affinity is the trust weight"  (score-affinity need offer-ok) 0.9)
(check "the offer's rule locks the need out"     (score-affinity need offer-locked) 0)
(check "the need's trust floor admits carla"     (score-affinity need-trusting offer-ok) 0.9)
(check "…and denies dev, whom bob barely recognizes" (score-affinity need-trusting offer-dev) 0)

(display "\n")
(test-summary!)
