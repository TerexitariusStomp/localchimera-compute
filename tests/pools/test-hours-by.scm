;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-hours-by.scm — one fold of validated hours, the key an argument.
;;;
;;; observer.scm `hours-by` is the single fold behind the credit ledger
;;; (ledger-gross, keyed by provider), the skills view (skill-hours-of, keyed by
;;; skill) and producer voice (keyed by the part an hour falls in). This suite
;;; pins that the two existing readings are exactly the fold under their keys
;;; (voice-in-lean theorem 10 `scope_key_is_voice_share`, held by construction:
;;; voice-share reads validated-gross, which is this fold at the constant key),
;;; that a #f key means "not folded", that the level gate threads through, and
;;; that a corrected event leaves every keyed total at once (a correction is a
;;; signed event: -30 hours backs out a work of 30).
;;;
;;; Run:  guile -q -L module tests/pools/test-hours-by.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet pools credit-fold) (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (goblins) (goblins persistence-store memory) (srfi srfi-1))
(use-modules ((playnet pools credit-fold) #:select (voice-share))
             ((playnet observation observer) #:select (event-terms))
             ((playnet test scope) #:select (record-work!)))

(define (approx= a b) (< (abs (- a b)) 1e-9))
(define* (work! obs aid hours eid iid #:key skill place scope)
  (record-work! obs aid hours eid iid #:skill skill #:process "bake" #:place place #:scope scope))

(define mem-store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Hours Test")) mem-store))

(display "\n── the fold under the ledger's key is the ledger ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer)))
    (work! obs "alice" 10 "e1" "i1" #:skill "baker" #:place "town" #:scope "bakery")
    (work! obs "alice" 5  "e2" "i2" #:skill "miller" #:place "mill" #:scope "bakery")
    (work! obs "bob"   30 "e3" "i3" #:skill "baker" #:place "town" #:scope "bakery")
    (work! obs "bob"   3  "e4" "i4" #:place "town" #:skill #f)             ; names no skill
    (let ((by-provider ($ obs 'hours-by (lambda (ev) (economic-event-provider ev)))))
      (check "alice's hours keyed by provider = her validated-gross"
             (approx= (assoc-ref by-provider "alice") ($ obs 'validated-gross "alice")))
      (check "bob's hours keyed by provider = his validated-gross (skill-less work counts)"
             (approx= (assoc-ref by-provider "bob") ($ obs 'validated-gross "bob")))
      (check "the scope total is the sum over keys"
             (approx= (fold + 0 (map cdr by-provider)) ($ obs 'validated-gross))))
    (check "voice-share = the fold's key share (theorem 10, by construction)"
           (approx= (voice-share "alice" (list scope)) (/ 15.0 48.0)))))

(display "\n── the fold under the skills' key is the skills view ──\n")
(with-vat vat
  (let* ((obs ($ scope 'observer))
         (by-skill ($ obs 'hours-by (lambda (ev) (and (equal? (economic-event-provider ev) "bob")
                                                     (economic-event-resource-conforms-to ev))))))
    (check "entry for entry" (equal? by-skill ($ obs 'skill-hours-of "bob")))
    (check "a #f key is not folded: bob's skill-less hours are in no skill" (= 1 (length by-skill)))))

(display "\n── keyed by the terms an hour stands in ──\n")
(with-vat vat
  (let* ((obs ($ scope 'observer))
         (by-place ($ obs 'hours-by (lambda (ev) (economic-event-at-location ev)))))
    (check "hours by place" (and (approx= (assoc-ref by-place "town") 43) (approx= (assoc-ref by-place "mill") 5)))
    (check "nothing is lost between keyings"
           (approx= (fold + 0 (map cdr by-place)) ($ obs 'validated-gross)))
    (let ((terms (map (lambda (e) (cons (car e) (event-terms (cdr e))))
                      (map (lambda (id) (cons id ($ obs 'get-event id))) '("e1" "e4")))))
      (check "event-terms reads process, place, skill, window and scope"
             (equal? (assoc-ref terms "e1")
                     '((process . "bake") (place . "town") (skill . "baker")
                       (window . ("2026-03-01T08:00:00Z" . "2026-03-01T08:00:00Z")) (scope . ("bakery")))))
      (check "…and states only what the event carries"
             (equal? (assoc-ref terms "e4")
                     '((process . "bake") (place . "town")
                       (window . ("2026-03-01T08:00:00Z" . "2026-03-01T08:00:00Z"))))))))

(display "\n── the level gate threads through ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer)))
    (check "an unrecognised level counts nothing"
           (every (lambda (kv) (= 0 (cdr kv)))
                  ($ obs 'hours-by (lambda (ev) (economic-event-provider ev)) "Regional")))))

(display "\n── a corrected event leaves every keyed total at once ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'record-event
       (make-economic-event #:id "e3-void" #:action 'work #:input-of "bake"
                            #:resource-conforms-to "baker" #:provider "bob"
                            #:effort-quantity (make-measure -30 %effort-unit)
                            #:has-point-in-time "2026-03-02T08:00:00Z" #:at-location "town"
                            #:satisfies "i3" #:corrects "e3"))
    (let ((by-provider ($ obs 'hours-by (lambda (ev) (economic-event-provider ev))))
          (by-place ($ obs 'hours-by (lambda (ev) (economic-event-at-location ev)))))
      (check "bob's provider total drops" (approx= (assoc-ref by-provider "bob") 3))
      (check "town's place total drops by the same hours" (approx= (assoc-ref by-place "town") 13))
      (check "the ledger agrees" (approx= ($ obs 'validated-gross "bob") 3)))))

(display "\n── effort is hours whatever unit it was stated in ──\n")
(with-vat vat
  (let ((obs ($ scope 'observer)))
    (record-work! obs "dora" 90 "e-min" "i-min" #:skill "baker" #:process "bake" #:unit "minutes")
    (check "90 minutes of work are 1.5 hours of credit" (approx= ($ obs 'validated-gross "dora") 1.5))
    (check "effort stated in a unit that is not time is refused"
           (raises? (lambda () (record-work! obs "dora" 5 "e-kg" "i-kg" #:skill "baker" #:process "bake" #:unit "kg"))))))

(test-summary!)
