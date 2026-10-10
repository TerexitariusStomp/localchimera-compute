;;; test-berlin-flat-key.scm — a lent flat, its oven, and the key that opens it.
;;;
;;; Alice lends her Berlin flat into the Kiez under a rule naming who may ENTER
;;; it, and lends its key under a second rule naming who may HOLD it. The two
;;; are independent: Bo may come in and work at the oven and is never handed
;;; the key; Cy and Dee may hold the key; Sam is neither. Everything rides the
;;; rails the oven already rides (test-steward-gate, test-housing-socialization):
;;;
;;;   1. TWO RULES, ONE GATE. Each grant carries its own steward rule; the gate
;;;      (make-may-steward) answers per spec. The flat's rule covers what stands
;;;      inside it — whoever may enter may use the oven — and the recipe's skill
;;;      line narrows that to someone who can bake.
;;;   2. THE PLAN ROUTES THE KEY. The key rests at Cy's. Lent to be used where
;;;      it lies, the door across town stays shut and no shift is planned; lent
;;;      `#:movable?`, the plan opens the door and states the key's move as a
;;;      commitment, origin to flat. Recalled, the door is shut again.
;;;   3. WHO. The solve keeps both means anonymous capacity; the door that
;;;      chooses a person asks the gate. The shift lands on the baker who may
;;;      enter; the opening — work that `use`s the key — lands on a person
;;;      trusted to hold it, and with nobody trusted on the roster it lands on
;;;      nobody.
;;;   5. WHAT STANDS IN A CARRIED THING COMES WITH IT. The key lies in a lockbox,
;;;      and it is the lockbox Alice lends: carried to the flat, the box bears
;;;      the key, the door opens, and the box's rule is the key's.
;;;   4. CUSTODY IS A RECORD. The key passing from hand to hand is a
;;;      `transfer-custody` event: custody moves to the receiver, rights stay
;;;      with Alice.
;;;
;;; Run:  guile --no-auto-compile -q -L module -L tests tests/planner/test-berlin-flat-key.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness)
             (playnet knowledge recipes flat-key) (playnet knowledge recipes transport) (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet doors service)
             (playnet federation plan-bundle)
             (playnet vf facts availability)
             (playnet knowledge dsl shorthand)
             (playnet knowledge dsl world)
             ((playnet knowledge recipes transport) #:select (mode-recipe))
             (playnet economy socialization) (playnet keri acdc) (playnet keri acdc-store)
             (playnet test events)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define ALICE "aid:alice")           ; owns the flat, the oven, the key
(define BO    "aid:bo")              ; may enter, bakes
(define CY    "aid:cy")              ; may hold the key
(define DEE   "aid:dee")             ; may hold the key
(define SAM   "aid:sam")             ; bakes as well as Bo; trusted with nothing
(define KIEZ  "Kiez")                ; the scope id IS the commune AID the grants name
(define FUTURE "2099-12-31T00:00:00Z")

(define ENTER   "{\"filter-rule\":[\"aid\",\"aid:bo\",\"aid:cy\",\"aid:dee\"]}")
(define HOLDERS "{\"filter-rule\":[\"aid\",\"aid:cy\",\"aid:dee\"]}")

(define day (all-week-window "08:00" "16:00"))

;; Kreuzberg to Neukölln: the flat, and the two places the key may rest
(define lockbox-carry                    ; the lockbox travels in somebody's hands
  (mode-recipe "carry the lockbox" #:good "spec-lockbox" #:skill "carried"
               #:pace 0.21 #:manner "pedestrian" #:work '("skill-errand" . 0.21)
               #:id "rp-lockbox-carry" #:pspec "pspec-carry-lockbox"))
;; the flat-key knowledge with the key's own carry left out: a scope where the
;; key travels only in what bears it
(define key-stays-boxed
  (let ((own? (lambda (pid) (equal? pid "rp-flat-key-carry"))))
    (world-with flat-key-world
                #:procs (remove (lambda (p) (own? (recipe-process-id p))) (world-procs flat-key-world))
                #:flows (remove (lambda (f) (own? (or (recipe-flow-recipe-input-of f) (recipe-flow-recipe-output-of f))))
                                (world-flows flat-key-world))
                #:recipes (remove (lambda (r) (equal? "recipe-flat-key-carry" (recipe-id r)))
                                  (world-recipes flat-key-world)))))
(define* (kiez-world roster #:key (boxed? #f))
  (world-append
   (if boxed? key-stays-boxed flat-key-world)
   (if boxed?
       (world #:specs (list (spec* "spec-lockbox" "Lockbox" %count-unit))
              #:procs (list (car lockbox-carry)) #:flows (cadr lockbox-carry)
              #:recipes (list (make-recipe #:id "recipe-lockbox-carry" #:name "A lockbox carried"
                                           #:primary-output "spec-lockbox" #:recipe-processes (list "rp-lockbox-carry")))
              #:resources (list (er "res:lockbox" "spec-lockbox" ALICE #:place "cy-home" #:qty 1.0 #:unit %count-unit)))
       (world))
   (world
    #:specs (list (make-resource-specification #:id "spec-dwelling" #:name "Dwelling (flat or house)" #:image "🏠"
                                               #:default-unit-of-resource %count-unit #:keep-in-place #t))
    #:spatials (list (place* "flat"     #:lat 52.4990 #:lon 13.4180)
                     (place* "cy-home"  #:lat 52.4860 #:lon 13.4250)
                     (place* "dee-home" #:lat 52.4810 #:lon 13.4350))
    #:agents (map (lambda (p) (person* (car p) #:place (cadr p) #:window day)) roster)
    #:resources (list (er "res:flat" "spec-dwelling" ALICE #:place "flat" #:qty 1.0 #:unit %count-unit)
                      (er "res:oven" "spec-oven" ALICE #:place #f #:qty 1.0 #:unit %count-unit
                          #:contained-in "res:flat")
                      (if boxed?
                          (er "res:key" "spec-flat-key" ALICE #:place #f #:qty 1.0 #:unit %count-unit
                              #:contained-in "res:lockbox")
                          (er "res:key" "spec-flat-key" ALICE #:place "cy-home" #:qty 1.0 #:unit %count-unit))))))

;; (id place skill …)
(define FULL-ROSTER `((,BO "flat" "skill-bake") (,SAM "flat" "skill-bake")
                      (,CY "cy-home" "skill-errand") (,DEE "dee-home" "skill-errand")))

;; one fresh Kiez: the roster seeded, the flat lent under ENTER, the key lent
;; under HOLDERS (movable or fixed). Returns (values svc root store flat-grant key-grant may).
(define* (kiez #:key (roster FULL-ROSTER) (movable? #t) (enter ENTER) (boxed? #f))
  (let* ((root  (spawn-scope-root KIEZ))
         (store (spawn-acdc-store))
         (may   (make-may-steward store
                                  #:resources-of (lambda (_) ($ ($ root 'observer) 'all-resources))))
         (svc   (spawn ^planner-service (hashmap) plain-plan-fn #f
                       (cons (cons 'steward may) (socialized-readers store)))))
    (seed-world! root (kiez-world roster #:boxed? boxed?))
    ($ svc 'add-scope! KIEZ root)
    (for-each (lambda (p) (for-each (lambda (skill) ($ svc 'declare-skill KIEZ (car p) skill)) (cddr p)))
              roster)
    (let* ((flat (socialize-private-resource store ALICE KIEZ "spec-dwelling" 1
                                             #:until FUTURE #:eligible enter))
           ;; the key itself — or the lockbox it lies in, and the key with it
           (key  (socialize-private-resource store ALICE KIEZ (if boxed? "spec-lockbox" "spec-flat-key") 1
                                             #:until FUTURE #:eligible HOLDERS
                                             #:movable? movable? #:return-to "cy-home")))
      (values svc root store flat key may))))

(define SHIFT '(("spec-oven-shift#flat@0" . 1.0)))
;; an errand-runner reaches the flat on foot within the hour (the commute gate
;; reads walking times off the arc table)
(define WALKS '(("cy-home|flat|pedestrian" . 0.4) ("dee-home|flat|pedestrian" . 0.6)))
(define (solve root store)
  (plan-commune-scope root store KIEZ #:demand SHIFT
                      #:manners '((commute-hours . 1.0)) #:arc-table WALKS
                      #:backend 'native-c))
(define (met r) (let ((m (assq-ref r 'met))) (if (number? m) m 0.0)))
(define (key-moves r)                    ; the plan's own statement of where the key goes
  (filter (lambda (m) (and (memq (assq-ref m 'action) '(pickup dropoff))
                           (equal? "spec-flat-key" (assq-ref m 'conforms-to))))
          (or (assq-ref r 'material) '())))

;; a work intent on process PROC for SKILL — input-of carries the process, as
;; every work-intent the solve or an offer lays does
(define (work-intent id proc skill hours)
  (make-intent #:id id #:action 'work #:input-of proc #:resource-conforms-to skill
               #:effort-quantity (make-measure hours %effort-unit) #:planned-within "plan-1"))
;; who the UC matching lands each piece of work on: ((process . provider) …)
(define (landed svc root)
  (let ((ps ($ root 'plan-store)))
    ($ ps 'add-intent (work-intent "wi-shift" "rp-flat-oven-shift" "skill-bake" 2.0))
    ($ ps 'add-intent (work-intent "wi-open" "rp-flat-unlock" "skill-errand" 0.1))
    ($ ps 'add-intent (work-intent "wi-carry" "rp-flat-key-carry" "skill-errand" 0.4))
    ($ ps 'add-proposal (make-rising-proposal "prop-1" "plan-1" KIEZ '("wi-shift" "wi-open" "wi-carry")))
    ($ svc 'match-labour!)
    (filter-map (lambda (c) (and (equal? (commitment-planned-within c) "plan-1")
                                 (cons (commitment-input-of c) (commitment-provider c))))
                ($ ps 'all-commitments))))

(define vat (spawn-vat))

(display "\n── 1. two rules, one gate: who may enter, who may hold the key ──\n")
(with-vat vat
  (call-with-values kiez
    (lambda (svc root store flat key may)
      (check "Bo may enter the flat"                         (may KIEZ BO "spec-dwelling") #t)
      (check "…and so may use the oven that stands in it"    (may KIEZ BO "spec-oven") #t)
      (check "…and is not trusted with the key"              (may KIEZ BO "spec-flat-key") #f)
      (check "Cy may hold the key"                           (may KIEZ CY "spec-flat-key") #t)
      (check "Dee may hold the key"                          (may KIEZ DEE "spec-flat-key") #t)
      (check "Sam may not enter"                             (may KIEZ SAM "spec-dwelling") #f)
      (check "…so the oven inside is closed to him too"      (may KIEZ SAM "spec-oven") #f)
      (check "…and the key is not his to hold"               (may KIEZ SAM "spec-flat-key") #f)
      (desocialize-private-resource! store ALICE (cred-said flat))
      (check "the flat recalled, its rule binds nobody"      (may KIEZ SAM "spec-oven") #t)
      (check "…and the key's rule stands on its own"         (may KIEZ SAM "spec-flat-key") #f))))

(display "\n── 2. the plan routes the key to the door ──\n")
(with-vat vat
  (call-with-values (lambda () (kiez #:movable? #f))
    (lambda (svc root store flat key may)
      (let ((r (solve root store)))
        (format #t "  key lent in place ⇒ shift met ~,2f~%" (met r))
        (check-pred "a key lent to be used where it lies opens no door across town"
                    (< (met r) 0.01))))))
(with-vat vat
  (call-with-values kiez
    (lambda (svc root store flat key may)
      (let* ((r (solve root store)) (moves (key-moves r)))
        (format #t "  key lent movable ⇒ shift met ~,2f, ~a key move(s)~%" (met r) (length moves))
        (check-pred "lent movable, the shift behind the door is planned" (> (met r) 0.9))
        (check "the plan carries the key once: one pickup where it rests, one dropoff at the flat"
               (map (lambda (m) (list (assq-ref m 'action) (assq-ref m 'at-location))) moves)
               '((pickup "cy-home") (dropoff "flat")))
        (check-pred "…the key itself, whole"
                    (every (lambda (m) (< (abs (- 1.0 (assq-ref m 'quantity))) 1e-6)) moves))
        (check "…on a run of the carry recipe"
               (delete-duplicates (map cdr (or (assq-ref r 'runs) '())))
               '("rp-flat-key-carry"))
        (check-pred "…whose carrier's work the plan lays where the key rests"
                    (any (lambda (w) (and (equal? "rp-flat-key-carry" (assq-ref w 'input-of))
                                          (equal? "cy-home" (assq-ref w 'at-location))))
                         (or (assq-ref r 'work) '())))
        (check-pred "the opening is planned at the flat"
                    (any (lambda (m) (and (equal? "rp-flat-unlock" (assq-ref m 'output-of))
                                          (equal? "flat" (assq-ref m 'at-location))))
                         (or (assq-ref r 'material) '())))
        (desocialize-private-resource! store ALICE (cred-said key))
        (let ((r2 (solve root store)))
          (format #t "  key recalled ⇒ shift met ~,2f~%" (met r2))
          (check-pred "the key recalled, the next plan opens nothing" (< (met r2) 0.01)))))))

(display "\n── 3. who: the baker who may enter, the opener who may hold the key ──\n")
(with-vat vat
  (call-with-values kiez
    (lambda (svc root store flat key may)
      (let ((who (landed svc root)))
        (format #t "  landed: ~s~%" who)
        (check "the shift lands on Bo — Sam bakes as well and may not enter"
               (assoc-ref who "rp-flat-oven-shift") BO)
        (check-pred "the opening lands on a person trusted to hold the key"
                    (member (assoc-ref who "rp-flat-unlock") (list CY DEE)))
        (check-pred "…and so does the carry: the key travels in a trusted hand"
                    (member (assoc-ref who "rp-flat-key-carry") (list CY DEE)))))))
;; the gate steers, not the roster's order: the flat opened to Sam alone
(with-vat vat
  (call-with-values (lambda () (kiez #:enter "{\"filter-rule\":[\"aid\",\"aid:sam\"]}"))
    (lambda (svc root store flat key may)
      (check "a flat opened to Sam alone lands the shift on Sam"
             (assoc-ref (landed svc root) "rp-flat-oven-shift") SAM))))
;; the same day with nobody trusted on the roster: Bo and Sam run errands too
(with-vat vat
  (call-with-values (lambda () (kiez #:roster `((,BO "flat" "skill-bake" "skill-errand")
                                                (,SAM "flat" "skill-bake" "skill-errand"))))
    (lambda (svc root store flat key may)
      (let ((who (landed svc root)))
        (format #t "  landed, no holder on the roster: ~s~%" who)
        (check "with no holder on the roster the opening lands on nobody"
               (assoc-ref who "rp-flat-unlock") #f)
        (check "…and nobody is handed the key to carry" (assoc-ref who "rp-flat-key-carry") #f)
        (check "…while the shift still has its baker" (assoc-ref who "rp-flat-oven-shift") BO)))))

(display "\n── 5. what stands in a carried thing comes with it: the key in a lockbox ──\n")
(with-vat vat
  (call-with-values (lambda () (kiez #:boxed? #t))
    (lambda (svc root store flat box may)
      (let* ((r (solve root store))
             (carried (filter (lambda (m) (memq (assq-ref m 'action) '(pickup dropoff)))
                              (or (assq-ref r 'material) '()))))
        (format #t "  key in a lent lockbox ⇒ shift met ~,2f~%" (met r))
        (check-pred "the lockbox lent, the door opens: the box bears the key to the flat" (> (met r) 0.9))
        (check "what the plan carries is the lockbox — one pickup where it rests, one dropoff at the flat"
               (map (lambda (m) (list (assq-ref m 'action) (assq-ref m 'conforms-to) (assq-ref m 'at-location))) carried)
               '((pickup "spec-lockbox" "cy-home") (dropoff "spec-lockbox" "flat")))
        (check "the box's rule is the key's: Cy may hold it" (may KIEZ CY "spec-flat-key") #t)
        (check "…and Bo may not" (may KIEZ BO "spec-flat-key") #f)))))

(display "\n── 4. custody is a record: the key passes hand to hand, rights stay ──\n")
;; Alice hands the key to Cy; Cy, tied up at the hour, hands it on to Dee, who
;; opens the door. Each hand-over is a `transfer-custody` event the receiver's
;; own custody node takes; the fold is the observer's kernel.
(define chain
  (list (ev "open" 'raise #:rid "res:key" #:spec "spec-flat-key" #:q 1.0 #:unit %count-unit
            #:provider ALICE #:receiver ALICE)
        (ev "to-cy" 'transfer-custody #:rid "res:key" #:to-rid "res:key@cy" #:spec "spec-flat-key"
            #:q 1.0 #:unit %count-unit #:provider ALICE #:receiver CY)
        (ev "to-dee" 'transfer-custody #:rid "res:key@cy" #:to-rid "res:key@dee" #:spec "spec-flat-key"
            #:q 1.0 #:unit %count-unit #:provider CY #:receiver DEE)))
(define (hands events)                   ; who received custody of the key, in order
  (filter-map (lambda (e) (and (eq? 'transfer-custody (economic-event-action e))
                               (economic-event-receiver e)))
              events))
(let ((st (fold-events chain)))
  (check "the key is in Dee's hand" (onhand st "res:key@dee") 1.0)
  (check "…and has left Cy's" (onhand st "res:key@cy") 0.0)
  (check "…and Alice's" (onhand st "res:key") 0.0)
  (check "the rights never moved: Alice's key still counts one"
         (measure-has-numerical-value (economic-resource-accounting-quantity (resource st "res:key"))) 1.0))
(with-vat vat
  (call-with-values kiez
    (lambda (svc root store flat key may)
      (check-pred "every hand on the chain is one the key's rule admits"
                  (every (lambda (w) (may KIEZ w "spec-flat-key")) (hands chain)))
      (check-pred "a chain through Bo is one the rule refuses"
                  (not (every (lambda (w) (may KIEZ w "spec-flat-key")) (list CY BO)))))))

(test-summary!)
