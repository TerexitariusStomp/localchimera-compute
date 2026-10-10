;;; test-commitment-endings.scm — how a commitment leaves the decided rung:
;;; release (the provider's own), expiry (the store's own, one turn),
;;; offer-work's own max-open bound, the window at the forcing point, the
;;; deployment's bindings.
;;;
;;; docs/planning/solve/commitment-horizon.md. Fixture: (playnet test planner bread).

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness)
             (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (playnet plan accepts)
             (playnet doors offers)
             (playnet plan store)
             (playnet test planner bread)
             ((playnet utils clock) #:select (now instant->unix))
             (goblins) (goblins vat)
             (srfi srfi-1))

(define vat (spawn-vat #:name "endings"))
(define-values (scope ps als) (with-vat vat (spawn-bread-scope)))
(define (solve) (with-vat vat (plan-scope->alist scope #:demand '(("bread#town@0" . 4.0)) #:backend 'native-c)))
(define (bake-hours r) (bread-hours r "bake"))
(define nowu (instant->unix (now)))

;; a standing accept: ada, 2 h of baking (4 runs)
(define (add-bake-accept! id hours)
  (with-vat vat ($ ps 'add-commitment
                   (make-commitment #:id id #:action 'work #:input-of "bake" #:resource-conforms-to "skill-bake"
                                    #:effort-quantity (make-measure hours %effort-unit) #:provider "ada" #:receiver "town" #:at-location "town"))))


(display "\n── 1. release: the decided rung's withdrawal ──\n")

(add-bake-accept! "cmt-bake" 2.0)
(check "the accept pins: first-stage bake = 4.0 runs"
       (< (abs (- (or (assoc-ref (assq-ref (solve) 'first-stage-plan) "bake") 0) 4.0)) 1e-9))
(check "only the provider releases their own accept"
       (raises? (lambda () (with-vat vat ($ ps 'release-commitment "cmt-bake" "bob")))))
(with-vat vat ($ ps 'release-commitment "cmt-bake" "ada" nowu))
(check "the released commitment is finished — its record stays"
       (with-vat vat (commitment-finished ($ ps 'get-commitment "cmt-bake"))))
(check "…and the ending is a dated fact on the rail: (ended . released)"
       (eq? 'released (assq-ref (with-vat vat ($ ps 'get-meta "cmt-bake")) 'ended)))
(check "the pin drops where the accept was felt: the next solve is the baseline again"
       (< (bake-hours (solve)) 3.0))

(display "\n── 2. expiry: the store ends what closed unworked, in one turn ──\n")

(with-vat vat ($ ps 'add-commitment
                 (make-commitment #:id "cmt-stale" #:action 'work #:input-of "mill" #:resource-conforms-to "skill-mill"
                                  #:effort-quantity (make-measure 0.3 %effort-unit) #:provider "bob" #:receiver "town" #:has-end (- nowu 3600) #:at-location "town")))
(solve)                                           ; the sweep runs before the compile
(check "an accept whose window closed is finished, dated expired"
       (and (with-vat vat (commitment-finished ($ ps 'get-commitment "cmt-stale")))
            (eq? 'expired (assq-ref (with-vat vat ($ ps 'get-meta "cmt-stale")) 'ended))))
(check "…and no longer stands" (null? (with-vat vat (standing-accepts ps))))
(check "fulfilment is an ending too, through the same door the confirmation mile uses"
       (begin (add-bake-accept! "cmt-done" 1.0)
              (with-vat vat ($ ps 'end-commitment "cmt-done" 'fulfilled nowu))
              (eq? 'fulfilled (assq-ref (with-vat vat ($ ps 'get-meta "cmt-done")) 'ended))))
(check "…and the confirmation mile itself dates it (record-work-done → end-commitment)"
       (begin (add-bake-accept! "cmt-mile" 1.0)
              (with-vat vat (record-work-done scope
                              `((id . "cmt-mile") (effort . 1.0) (when . #f)
                                (input-of . "bake") (conforms-to . "skill-bake")
                                (provider . "ada") (at-location . "town"))))
              (eq? 'fulfilled (assq-ref (with-vat vat ($ ps 'get-meta "cmt-mile")) 'ended))))

(display "\n── 3. max-open is the door's own parameter; the window ends at the forcing point ──\n")

(check "max-open 0 refuses every fresh offer"
       (raises? (lambda () (with-vat vat (offer-work scope '((input-of . "mill") (effort . 0.3)) "bob" #:max-open 0)))))
;; bake's chain L = 0 here (undurated mock processes), so the forcing point
;; IS the row's end: an offer whose work ends in 1 h gets a ≤ 1 h window
(define near-end
  (with-vat vat (offer-work scope `((input-of . "bake") (effort . 0.5) (until . ,(+ nowu 3600))) "bob")))
(check "the window closes at the forcing point"
       (with-vat vat
         (let ((row (find (lambda (r) (equal? near-end (proposal-id (car r)))) (open-work-offers scope))))
           (<= (string->number (proposal-has-end (car row))) (+ nowu 3601)))))
(check "a row whose forcing point has passed is refused outright"
       (raises? (lambda () (with-vat vat (offer-work scope `((input-of . "bake") (effort . 0.5) (until . ,(- nowu 3600))) "farmer")))))

(display "\n── 4. deployment-bindings: accepts consume, held offers book ──\n")

(define-values (seed tentative) (with-vat vat (deployment-bindings ps)))
(check "every open offer books its proposed person tentatively, as the commitment it would become"
       (let ((open (with-vat vat (open-work-offers scope))))
         (and (= (length tentative) (length open))
              (every commitment-provider tentative)
              (every commitment-has-end tentative))))   ; promotion's field map carries the window
(add-bake-accept! "cmt-seed" 1.0)
(check "a standing accept seeds the deployment — its provider is consumed"
       (let ((seed (call-with-values (lambda () (with-vat vat (deployment-bindings ps))) (lambda (s t) s))))
         (and (= 1 (length seed)) (equal? "ada" (commitment-provider (car seed))))))

(test-summary!)
