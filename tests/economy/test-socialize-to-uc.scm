;;; test-socialize-to-uc.scm — socializing to THE WHOLE COMMONS (UC), and where
;;; the custody concretely has to be for a scope's solve to see it.
;;;
;;; Closes the caveat behind the socialize interface's "to whom → the whole
;;; commons (UC)" default. Two claims, honestly:
;;;
;;;  (A) POSITIVE — grant to UC, solve the commons as ONE problem (the single
;;;      global solve the docs favour, playnet.typ §5011), and the means is
;;;      usable by any demand in the commons, bounded by the grant qty. This is
;;;      the same live path as test-socialization-live, with holder = UC.
;;;
;;;  (B) BOUNDARY — a grant is seen ONLY by its HOLDER scope. commune-socialized-
;;;      caps filters grants by (equal? commune-aid (cred-holder c)) — no walk-up
;;;      the containment tree. So a LEAF commune solving its OWN scope in
;;;      isolation does NOT see a UC-held grant. In a DECOMPOSED solve the means
;;;      reaches the leaf either because the global UC solve allocates it (A), or
;;;      because custody is HANDED DOWN to the leaf (transfer-custody, the moving
;;;      assignment) — at which point the leaf, now the holder, sees it (C).
;;;
;;; The pair is the precise shape of "offer to UC; custody hops between scopes":
;;; visibility follows the holder, and the plan (global solve) or a custody
;;; push-down is what puts the holder where the work is.
;;;
;;; Run:  guile -L module -L tests tests/economy/test-socialize-to-uc.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet vf schemas)
             (playnet scope live)
             (playnet economy socialization) (playnet keri acdc-store)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define OWNER  "EAlice")
(define UC     "EUniversalCommune")   ; the whole commons — the root/universal scope
(define LEAF   "ELeafCommune")        ; a sub-commune, solved on its own
(define FUTURE "2099-12-31T00:00:00Z")

;; a delivery recipe: `use` the bike (1 bike-hour/parcel) → produce a delivered parcel
(define procs (list (make-recipe-process #:id "deliver" #:name "Deliver")))
(define flows
  (list (make-recipe-flow #:id "d-use" #:action 'use #:resource-conforms-to "bike" #:resource-quantity (make-measure 1.0 %count-unit) #:effort-quantity (make-measure 1.0 %effort-unit)
                          #:recipe-input-of "deliver")
        (make-recipe-flow #:id "d-out" #:action 'produce #:resource-conforms-to "delivered" #:resource-quantity (make-measure 1.0 "kg")
                          #:recipe-output-of "deliver" #:is-primary #t)))
(define recipes (list (make-recipe #:id "deliver-recipe" #:name "Deliver"
                                   #:primary-output "delivered" #:recipe-processes '()
                                   #:recipe-exchanges '())))

;; Alice owns the bike (primary-accountable = Alice); no custodian; at "town".
(define (bike)
  (make-economic-resource #:id "res:bike" #:conforms-to "bike" #:classified-as '()
                          #:onhand-quantity (make-measure 1 %count-unit) #:current-location "town" #:primary-accountable OWNER))
(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))

(define vat (spawn-vat #:name "socialize-to-uc"))

;; the federation seam: Alice's bike lives in her own commune's books; a resolver
;; fetches it cross-scope so ANY holder scope's view can assemble own ∪ granted.
(define (make-resolver)
  (let* ((m-obs  (spawn ^mock `((all-resources . ,(lambda () (list (bike)))))))
         (m-root (mock-scope-root #:observer m-obs))
         (m-comm (spawn ^mock `((scope-root . ,(lambda () m-root)))))
         (fed    (spawn ^mock `((members . ,(lambda () (hashmap-set (hashmap) "commA" m-comm)))))))
    (federation-resource-resolver fed)))

;; one live solve of the commons as ONE problem, custody granted to HOLDER.
(define (run-global qty holder)
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (_ (when qty (socialize-private-resource store OWNER holder "bike" qty #:until FUTURE)))
           (obs (spawn ^mock `((all-resources . ,(lambda () '())) (record-event . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents . ,(lambda () '())))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs (mock-recipe-store #:recipes recipes #:procs procs #:flows flows))
           (ps  (spawn ^mock `((all-meta . ,(lambda () '())) (all-commitments . ,(lambda () '())))))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps))
           (resolve (make-resolver))
           (view (lambda (own) (commune-resource-view own store holder resolve)))
           (caps (commune-socialized-caps store holder (view '()) '(0)))
           (result (plan-scope->alist scope
                     #:resource-view view #:eco-caps caps
                     #:demand '(("delivered#town@0" . 5.0)) #:backend 'native-c)))
      (assq-ref result 'met))))

;; ── (A) grant to the whole commons → the commons' plan uses it ───────────────
(display "\n── (A) socialize to UC, solved as one commons: usable, bounded by the grant ──\n")
(define uc-2 (run-global 2 UC))
(define uc-4 (run-global 4 UC))
(format #t "  to UC, lent 2 ⇒ demand met ~,2f   (≈ 2/5)~%" uc-2)
(format #t "  to UC, lent 4 ⇒ demand met ~,2f   (≈ 4/5)~%" uc-4)
(check "grant to UC, lent 2 ⇒ the commons uses ~2/5 of demand" (and (> uc-2 0.35) (< uc-2 0.45)))
(check "grant to UC, lent 4 ⇒ more lent, more used, ~4/5"      (and (> uc-4 0.75) (< uc-4 0.85)))
(check "lending more to the commons raises use"                (> uc-4 uc-2))

;; ── (B) a grant is seen only by its HOLDER scope (no walk-up) ────────────────
;; Same store, same resolved resources; vary only WHICH scope asks for its caps.
(display "\n── (B) the holder scope sees the grant; a leaf solved alone does not ──\n")
(with-vat vat
  (let* ((store (spawn-acdc-store))
         (_ (socialize-private-resource store OWNER UC "bike" 4 #:until FUTURE))  ; held by UC
         (resolve (make-resolver))
         (res (commune-resource-view '() store UC resolve))   ; the resolved bike
         (caps-uc   (commune-socialized-caps store UC   res '(0)))
         (caps-leaf (commune-socialized-caps store LEAF res '(0))))
    (format #t "  caps seen by UC   (the holder): ~a~%" (length caps-uc))
    (format #t "  caps seen by LEAF (solved alone): ~a~%" (length caps-leaf))
    (check "UC (the holder) sees the socialized capacity"        (= 1 (length caps-uc)))
    (check "a LEAF solving in isolation sees NO UC-held grant"   (null? caps-leaf))))

;; ── (C) custody handed down to the leaf → the leaf now sees it ───────────────
;; What transfer-custody does concretely: credit a new custodian. Once the leaf
;; holds the grant, its own solve sees the capacity — the moving assignment.
(display "\n── (C) push custody down to the leaf → the leaf's own solve sees it ──\n")
(with-vat vat
  (let* ((store (spawn-acdc-store))
         (_ (socialize-private-resource store OWNER LEAF "bike" 4 #:until FUTURE))  ; now held by the leaf
         (resolve (make-resolver))
         (res (commune-resource-view '() store LEAF resolve))
         (caps-leaf (commune-socialized-caps store LEAF res '(0))))
    (format #t "  caps seen by LEAF once it holds custody: ~a~%" (length caps-leaf))
    (check "custody at the leaf ⇒ the leaf's own solve sees the capacity" (= 1 (length caps-leaf)))))

(test-summary!)
