;;; test-provider-away.scm — a work accept whose provider is away does not pin.
;;;
;;; docs/planning/food/reproduction-of-labour-power.md §2c/§7: a sick, rest or
;;; leave declaration releases the commitments already made inside its
;;; window — the plan rebuilds around the gap rather than holding a body to
;;; a shift it declared it will not be there for. accepts->pins reads it off
;;; the scope's own agent-store, one lookup per commitment's provider, so a
;;; solve started #:scope-root never pins a person on their own away day —
;;; and, unlike a cancelled commitment, it is self-healing: the moment the
;;; declaration is lifted the very same pin computes again, with nothing to
;;; restore.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-provider-away.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet knowledge dsl shorthand))
(use-modules (playnet test harness)
             (goblins)
             (playnet scope root) (playnet vf schemas)
             (playnet vf schemas)
             ((playnet plan accepts) #:select (accepts->pins))
             (playnet scope root))

(define flows
  (list (wk* "aW" "farming" 2.0 "growB")
        (out* "aF" "food" 1.0 "growB")))

;; a plan-store-shaped work accept naming its own day (has-beginning), fields
;; in <commitment> order
(define* (mk-accept id #:key (proc "growB") (place "farm") (hours 1.0)
                    (provider "alice") (skill "farming") (beginning #f))
  (make-commitment #:id id #:action 'work #:input-of proc #:resource-conforms-to skill
                   #:effort-quantity (make-measure hours %effort-unit) #:provider provider
                   #:has-beginning beginning #:at-location place))

(define vat (spawn-vat))

(with-vat vat
  (define scope (spawn-scope-root "Bakery"))
  (define as ($ scope 'agent-store))
  ($ as 'add-agent (person* "alice" #:tags '("away:2026-09-28..2026-09-30:sick")))
  ($ as 'add-agent (person* "bo" #:tags '("general")))

  (display "\n── a provider's away day withdraws their own accept from the pin ──\n")
  (let ((pins (accepts->pins (list (mk-accept "c1" #:provider "alice"
                                              #:beginning "2026-09-29T09:00:00Z"))
                             flows #:scope-root scope)))
    (check "a work accept whose provider is away on its own day does not pin"
           (null? pins)))
  (let ((pins (accepts->pins (list (mk-accept "c2" #:provider "bo"
                                              #:beginning "2026-09-29T09:00:00Z"))
                             flows #:scope-root scope)))
    (check "the same day, a provider who is not away pins as usual"
           (= 1 (length pins))))
  (let ((pins (accepts->pins (list (mk-accept "c3" #:provider "alice"
                                              #:beginning "2026-10-01T09:00:00Z"))
                             flows #:scope-root scope)))
    (check "the same provider, a day outside their away span, pins as usual"
           (= 1 (length pins))))
  (let ((pins (accepts->pins (list (mk-accept "c4" #:provider "alice"
                                              #:beginning "2026-09-28T00:00:00Z"))
                             flows #:scope-root scope)))
    (check "the first day of the span withdraws too, inclusive"
           (null? pins)))
  (let ((pins (accepts->pins (list (mk-accept "c5" #:provider "alice"
                                              #:beginning "2026-09-29T09:00:00Z"))
                             flows)))
    (check "with no scope-root to ask, the declaration cannot be read, and the accept pins as before"
           (= 1 (length pins)))))

(display "\n── a visitor's away day is read at their home ──\n")
(with-vat vat
  (define table (spawn-scope-root "Table"))
  (define home  (spawn-scope-root "Granary"))
  ;; vic lives at the Granary and is away; the Table holds no record of them
  ($ ($ home 'agent-store) 'add-agent (person* "vic" #:tags '("away:2026-09-28..2026-09-30:sick")))
  (define (vic-agent aid) ($ ($ home 'agent-store) 'get-agent aid))
  (let ((c (mk-accept "c6" #:provider "vic" #:beginning "2026-09-29T09:00:00Z")))
    (check "read at the scope alone, a visitor's declaration is not seen and the accept pins"
           (= 1 (length (accepts->pins (list c) flows #:scope-root table))))
    (check "read through the home's record, their away day withdraws it"
           (null? (accepts->pins (list c) flows #:scope-root table #:agent-of vic-agent)))
    (check "a visitor away on another day pins as usual"
           (= 1 (length (accepts->pins (list (mk-accept "c7" #:provider "vic" #:beginning "2026-10-02T09:00:00Z"))
                                       flows #:scope-root table #:agent-of vic-agent))))))

(test-summary!)
