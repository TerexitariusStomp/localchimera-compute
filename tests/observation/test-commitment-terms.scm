;;; test-commitment-terms.scm — the observer holds a commitment's terms; no caller reads them out of its id.
;;;
;;; A claim commitment's id spells the claim (claim|spec|claimant|place|when), and
;;; seven callers once split it to learn the claimant. The observer is told the
;;; commitment, so it answers for it. Properties:
;;;
;;;   TERMS    a registered commitment answers its action, spec, receiver, place,
;;;            when and tags; an id the books hold no target for answers #f
;;;   MATCH    fulfillments-for finds commitments by spec, receiver, place and tag,
;;;            open ones by default, every one on request; a key left off matches any
;;;   RETIRE   a retired claim leaves the books: its terms are no longer anyone's to ask
;;;   LEGACY   a snapshot taken before terms carried a tail loads with the tail laid
;;;
;;; Run: guile --no-auto-compile -q -L module -L . -L tests tests/observation/test-commitment-terms.scm

(use-modules (playnet test harness) (playnet test events)
             (playnet observation observer) (playnet vf schemas) (playnet observation states)
             ((playnet observation account) #:select (claim-commitment claim-terms claim-fulfillments open-claim-for))
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define (new-observer) (spawn ^observer (empty-observer-state) '()))
(define (cid-of fs) (fulfillment-state-commitment-id fs))
(define vat (spawn-vat))

(with-vat vat
  (display "\n── TERMS: what a commitment was registered as ──\n")
  (let ((o (new-observer))
        (c (claim-commitment "bread" "ana" 2.0 "org:t" #:place "market" #:when-iso "3" #:unit "kg")))
    ($ o 'register-commitment c)
    (let ((t ($ o 'commitment-terms (commitment-id c))))
      (check "its spec" (assq-ref t 'spec) "bread")
      (check "who it is for" (assq-ref t 'receiver) "ana")
      (check "where" (assq-ref t 'place) "market")
      (check "when" (assq-ref t 'when) "3")
      (check "its kind" (assq-ref t 'tags) '("claim"))
      (check "its action" (assq-ref t 'action) 'transfer))
    (check "a claim is a claim" (and (claim-terms o (commitment-id c)) #t) #t)
    (check "a snapshot holds a commitment's terms as the seven-field list it always held its first three of"
           (let* ((st (deserialize-observer-state-portable ($ o 'serialize))))
             (terms->list (hashmap-ref (os-terms st) (commitment-id c))))
           '(transfer "bread" () "ana" "market" "3" ("claim")))
    (check "an id the books hold nothing for answers #f" ($ o 'commitment-terms "nope") #f)
    (let ((w (make-commitment #:id "w1" #:action 'work #:resource-conforms-to "baking" #:input-of "P"
                              #:effort-quantity (make-measure 3.0 "hours") #:provider "ana")))
      ($ o 'register-commitment w)
      (check "a work commitment is no claim" (claim-terms o "w1") #f)
      (check "…but answers its own terms" (assq-ref ($ o 'commitment-terms "w1") 'action) 'work)))

  (display "\n── MATCH: by spec, receiver, place and kind ──\n")
  (let ((o (new-observer)))
    (for-each (lambda (spec who place)
                ($ o 'register-commitment (claim-commitment spec who 1.0 "org:t" #:place place #:unit "kg")))
              '("bread" "bread" "milk") '("ana" "bo" "ana") '("market" "market" "dairy"))
    ($ o 'register-commitment (make-commitment #:id "w1" #:action 'work #:resource-conforms-to "bread"
                                               #:input-of "P" #:effort-quantity (make-measure 1.0 "hours")))
    (check "bread claims: two" (length (claim-fulfillments o #:spec "bread")) 2)
    (check "ana's claims: two" (length (claim-fulfillments o #:receiver "ana")) 2)
    (check "ana's bread claim: one" (length (claim-fulfillments o #:spec "bread" #:receiver "ana")) 1)
    (check "at the dairy: one" (length (claim-fulfillments o #:place "dairy")) 1)
    (check "no key: every claim, and the work commitment is not among them" (length (claim-fulfillments o)) 3)
    (check "open-claim-for finds ana's bread" (and (open-claim-for o "bread" "ana" #:place "market") #t) #t)
    (check "…and not her bread at the dairy" (open-claim-for o "bread" "ana" #:place "dairy") #f)
    (let ((cid (cid-of (open-claim-for o "bread" "ana"))))
      ($ o 'record-event (make-economic-event #:id "e1" #:action 'transfer #:resource-conforms-to "bread"
                                              #:resource-quantity (make-measure 1.0 "kg") #:fulfills cid))
      (check "a finished claim is not open" (open-claim-for o "bread" "ana") #f)
      (check "…but stands when every state is asked for"
             (length (claim-fulfillments o #:spec "bread" #:receiver "ana" #:open-only? #f)) 1)))

  (display "\n── RETIRE: a withdrawn claim leaves the books ──\n")
  (let* ((o (new-observer))
         (c (claim-commitment "bread" "ana" 2.0 "org:t" #:unit "kg")))
    ($ o 'register-commitment c)
    ($ o 'retire-commitment (commitment-id c))
    (check "its terms are no longer asked for" ($ o 'commitment-terms (commitment-id c)) #f)
    (check "…nor does it match" (length (claim-fulfillments o #:open-only? #f)) 0))

  (display "\n── LEGACY: a snapshot from before the tail loads with it laid ──\n")
(check "a list of three reads, its tail unstated" 
       (let ((t (list->terms '(transfer "bread" ("i1"))))) (list (terms-action t) (terms-spec t) (terms-iids t) (terms-receiver t) (terms-tags t)))
       '(transfer "bread" ("i1") #f ()))
(check "…and writes back as seven" (length (terms->list (list->terms '(transfer "bread" ())))) 7)
  (let* ((o (new-observer))
         (c (claim-commitment "bread" "ana" 2.0 "org:t" #:place "market" #:when-iso "3" #:unit "kg")))
    ($ o 'register-commitment c)
    (let* ((st     (deserialize-observer-state-portable ($ o 'serialize)))
           (strip  (lambda (terms)        ; what a pre-tail build wrote: the first three fields, the tail unstated
                     (hashmap-fold (lambda (k v acc)
                                     (hashmap-set acc k (make-terms (terms-action v) (terms-spec v) (terms-iids v) #f #f #f '())))
                                   (hashmap) terms)))
           (old    (positional-snapshot (os-rebuild st #:terms (strip (os-terms st)))))
           (loaded (spawn ^observer (deserialize-observer-state old) '()))
           (t      ($ loaded 'commitment-terms (commitment-id c))))
      (check "the claimant is laid from the claim's own id, once" (assq-ref t 'receiver) "ana")
      (check "…and its place and when" (list (assq-ref t 'place) (assq-ref t 'when)) '("market" "3"))
      (check "…and its kind" (assq-ref t 'tags) '("claim"))
      (check "a claim from the old snapshot is found by fulfillments-for"
             (length (claim-fulfillments loaded #:receiver "ana")) 1))))

(test-summary!)
