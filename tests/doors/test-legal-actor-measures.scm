;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-legal-actor-measures.scm — the law reads WHO acts and HOW MUCH, and
;;; sometimes it gives.
;;;
;;; Properties over legal/registry.scm, compliance.scm and adapters.scm:
;;;   · the actor and its measures are askable facts: a guard on them answers
;;;     yes, no, or unknown, and unknown is doubt, named by what was not stated;
;;;   · a threshold is two rules over one measure, and exactly one fires;
;;;   · a levy's amount is rate × the base's measure, and nothing else;
;;;   · `grant` is the fifth kind: its own bill key, no weight, no change of
;;;     stance, a transfer the authority provides, a holding read as unclaimed;
;;;   · an obtain that comes `after` another is blocked while that one is unmet.
;;;
;;; Run: guile -L module tests/doors/test-legal-actor-measures.scm

(use-modules (playnet test harness)
             (playnet legal registry) (playnet legal compliance) (playnet legal adapters)
             (playnet observation observer) (playnet vf schemas)
             ((playnet vf facts agent-tags) #:select (tag))
             (goblins) (goblins vat)
             (srfi srfi-1) (ice-9 format))

(define here "place:test")
(define (ctx . kw) (apply legal-context #:crossings '(stance-test) #:place-path (list here) kw))
(define (says form . kw) ((compile-guard form) (apply ctx kw)))
(define (actor-of kind)
  `((id . ,(string-append "b:" (symbol->string kind))) (type . organization)
    (classified-as . ("body" ,(tag "kind" kind))) (primary-location . #f)))
(define assoc (actor-of 'association))
(define coop  (actor-of 'cooperative))

;;; ─── the actor ───────────────────────────────────────────────────────────
(display "\n── the actor is an askable fact ──\n")
(check "actor-has: named and so, named and not, nobody named"
       (list (says '(actor-has classified-as "kind:association") #:actor assoc)
             (says '(actor-has classified-as "kind:cooperative") #:actor assoc)
             (says '(actor-has classified-as "kind:association")))
       '(#t #f unknown))
(check "actor-kind-is spells the tag the one way the writer spells it"
       (actor-kind-is 'association) `(actor-has classified-as ,(tag "kind" 'association)))
(check "a holder is not the actor: an agent at the cell answers agent-has, not actor-has"
       (list (says '(agent-has classified-as "kind:association") #:agents (list assoc))
             (says '(actor-has classified-as "kind:association") #:agents (list assoc)))
       '(#t unknown))

;;; ─── the measures ────────────────────────────────────────────────────────
(display "\n── a measure is an askable fact; a threshold is two rules ──\n")
(define m '((members . 12) (balance-sheet . 1500000)))
(check "at-least / under: each side, the line itself, nobody measured, nobody counted this one"
       (list (says '(measure-at-least members 10) #:measures m)
             (says '(measure-at-least members 12) #:measures m)
             (says '(measure-at-least members 13) #:measures m)
             (says '(measure-under balance-sheet 2000000) #:measures m)
             (says '(measure-under balance-sheet 1500000) #:measures m)
             (says '(measure-under balance-sheet 2000000))
             (says '(measure-under employees 5) #:measures m))
       '(#t #t #f #t #f unknown unknown))
(check "guard-asks names the actor and the measures a form reads, under a negate too"
       (guard-asks `(all-of ,(actor-kind-is 'association) (negate (measure-under members 3))))
       '(actor measures))
(check "guard-measures names the keys, for the lint"
       (guard-measures '(all-of (measure-under balance-sheet 1) (any-of (measure-at-least members 2))))
       '(members balance-sheet))
(check-pred "every key a pack may name is registered"
            (every (lambda (k) (memq k %measure-keys)) '(members receipts balance-sheet employees)))

(define small
  (rule (all-of (on-crossing 'stance-test) (actor-kind-is 'cooperative) (measure-under 'balance-sheet 2000000))
        (list (tell #:name "Audit" #:renew '(every . 2-years))) #:label "t/small"))
(define big
  (rule (all-of (on-crossing 'stance-test) (actor-kind-is 'cooperative) (measure-at-least 'balance-sheet 2000000))
        (list (tell #:name "Audit" #:renew '(every . year))) #:label "t/big"))
(define (fold . kw)
  (call-with-values (lambda () (legal-demands (apply ctx kw) #:rules (list small big))) list))
(check "under the line one rule fires, sure" (map legal-rule-label (cadr (fold #:actor coop #:measures m))) '("t/small"))
(check "over it, the other" (map legal-rule-label (cadr (fold #:actor coop #:measures '((balance-sheet . 3000000))))) '("t/big"))
(check "for an association neither" (cadr (fold #:actor assoc #:measures m)) '())
(check "nobody named: both in doubt, and the doubt names what was not stated"
       (let ((hits (cadr (fold))))
         (list (map legal-rule-confidence hits) (hit-unknowns hits (ctx))))
       '((uncertain uncertain) (("t/small" actor measures) ("t/big" actor measures))))
(check "named but not measured: in doubt over the measure alone"
       (hit-unknowns (cadr (fold #:actor coop)) (ctx #:actor coop))
       '(("t/small" measures) ("t/big" measures)))

;;; ─── the amount ──────────────────────────────────────────────────────────
(display "\n── a levy's amount is rate × the base's measure ──\n")
(define levy (pay #:name "Fee" #:base 'members #:rate 20.0))
(check "rate × measure; and #f without a rate, a base, any measures, or that measure"
       (list (demand-amount levy m)
             (demand-amount (pay #:name "x" #:base 'members) m)
             (demand-amount (pay #:name "x" #:rate 2.0) m)
             (demand-amount levy #f)
             (demand-amount levy '((stewards . 1))))
       '(240.0 #f #f #f #f))

;;; ─── grant, the fifth kind ───────────────────────────────────────────────
(display "\n── grant: what the law offers ──\n")
(define offer (grant #:name "Relief" #:spec '(selfless)))
(define offer-rule (rule (on-crossing 'stance-test) (list offer) #:label "t/offer"))
(define (one-rule-bill r) (call-with-values (lambda () (legal-demands (ctx) #:rules (list r))) list))
(check "its own bill key; it weighs nothing; the stance stays open"
       (let ((bh (one-rule-bill offer-rule)))
         (list (map demand-name (bill-ref (car bh) 'grant)) (bill-weight (car bh)) (bill-stance (car bh) (cadr bh))))
       '(("Relief") 0.0 open))
(check "it lowers to a transfer — the authority provides" (demand-kind->vf-action 'grant) 'transfer)
(check "a grant round-trips through the pack serialisation"
       (let ((d (car (legal-rule-demands (sexp->rule (rule->sexp offer-rule))))))
         (list (demand-kind d) (demand-name d) (demand-spec d)))
       '(grant "Relief" (selfless)))
(check "the vocabulary is five kinds, and the bill six keys"
       (list %demand-kinds %bill-keys)
       '((obtain pay tell forbid grant) (obtain-entity obtain-person pay tell forbid grant)))
(check "a recurring grant is a commitment the authority provides and we receive"
       (let ((c (obligation-for "Relief" '(every . year) "2027-01-01" "us" "authority" #:kind 'grant)))
         (list (commitment-provider c) (commitment-receiver c) (commitment-action c)))
       '("authority" "us" transfer))

;;; ─── reconcile: unclaimed, and blocked ───────────────────────────────────
(display "\n── holding: an offer unclaimed, an obtain blocked behind its forerunner ──\n")
(define vat (spawn-vat))
(define obs (with-vat vat (spawn ^observer (empty-observer-state) '())))
(define first-permit  (obtain #:rides 'entity #:name "First"))
(define second-permit (obtain #:rides 'entity #:name "Second" #:after "First"))
(define seq-rule (rule (on-crossing 'stance-test) (list first-permit second-permit offer levy) #:label "t/seq"))
(define (statuses)
  (with-vat vat
    (let ((bh (one-rule-bill seq-rule)))
      (map (lambda (e) (cons (list-ref e 2) (entry-status e)))
           (reconcile (car bh) (cadr bh) obs "2026-10-10" #:subject-of (lambda (d k) "scope:t"))))))
(check "unheld: the first missing, the second blocked behind it, the offer unclaimed"
       (statuses)
       '(("First" . missing) ("Second" . blocked) ("Fee" . obligation) ("Relief" . unclaimed)))
(check-pred "a blocked obtain is a gap; an unclaimed grant is not"
            (let ((gaps (with-vat vat
                          (let ((bh (one-rule-bill seq-rule)))
                            (map (lambda (e) (list-ref e 2))
                                 (reconcile-gaps (reconcile (car bh) (cadr bh) obs "2026-10-10"
                                                            #:subject-of (lambda (d k) "scope:t"))))))))
              (and (member "Second" gaps) (not (member "Relief" gaps)))))
(with-vat vat
  ($ obs 'record-resource
     (make-economic-resource #:id "r:first" #:name "First permit" #:conforms-to "First"
                             #:primary-accountable "scope:t" #:state "active"
                             #:onhand-quantity (make-measure 1 "u") #:accounting-quantity (make-measure 1 "u"))))
(check "the forerunner held: the second is now merely missing"
       (assoc-ref (statuses) "Second") 'missing)

(display "\n── the exposure prices the levy and lists the offer ──\n")
(define x (with-vat vat
            (let ((bh (one-rule-bill seq-rule)))
              (adapter-exposure obs "scope:t" #:crossings '(stance-test) #:place-path (list here)
                                #:bill+hits bh #:measures m #:as-of "2026-10-10"))))
(check "amounts: the fee at rate × members" (assq-ref x 'amounts) '(("Fee" . 240.0)))
(check "offered: the relief, unclaimed" (assq-ref x 'offered) '(("Relief" . unclaimed)))
(check "owes still names the levy by name" (assq-ref x 'owes) '("Fee"))

(test-summary!)
