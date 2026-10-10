;;; test-declare-means.scm — self-declaring a means of production you own.
;;;
;;; The ownership a socialization grant needs: declare-means seeds an owned
;;; EconomicResource (primary-accountable = you, conforms-to = the spec) into a
;;; scope's observer — the sibling of declare-skill for productive means. This is
;;; slice 2 of "socialize for real": you own something before you can lend it.
;;;
;;; Run:  guile -L module -L tests tests/planner/test-declare-means.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1) (playnet planner doors service) (playnet test harness)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(display "\n── declare-means: seed an owned means into a scope's observer ──\n")
(with-vat (spawn-vat #:name "declare-means")
  (let* ((root   (spawn-scope-root "Commune"))
         (scopes (hashmap-set (hashmap) "commune-1" root))
         (svc    (spawn ^planner-service scopes))
         (obs    ($ root 'observer)))
    (let ((r ($ svc 'declare-means "commune-1" "EAlice" "lathe" 12 %effort-unit "town")))
      (check "declare-means returns ok + the resource id"
             (and (eq? 'ok (car r)) (equal? "means:EAlice:lathe" (cdr r)))))
    (let ((res (find (lambda (x) (equal? "means:EAlice:lathe" (economic-resource-id x)))
                     ($ obs 'all-resources))))
      (check "the means is now in the scope's observer" (and res #t))
      (check "owned by the declarer (primary-accountable = EAlice)"
             (equal? "EAlice" (economic-resource-primary-accountable res)))
      (check "conforms to the declared spec (lathe)"
             (equal? "lathe" (economic-resource-conforms-to res)))
      (check "carries the declared capacity (onhand = 12)"
             (= 12 (measure-has-numerical-value (economic-resource-onhand-quantity res))))
      (check "located where declared (town)"
             (equal? "town" (economic-resource-current-location res))))

    (display "\n── editing is an EVENT: re-declare moves on-hand through raise/lower ──\n")
    ($ svc 'declare-means "commune-1" "EAlice" "lathe" 8 %effort-unit "town")
    (let ((res ($ obs 'get-resource "means:EAlice:lathe")))
      (check "the lower landed: onhand = 8"
             (measure-has-numerical-value (economic-resource-onhand-quantity res)) 8)
      (check "history survives the edit: the lower event stands on the record"
             (any (lambda (e) (eq? 'lower (economic-event-action e)))
                  ($ obs 'events-for-resource "means:EAlice:lathe"))
             #t))
    ($ svc 'declare-means "commune-1" "EAlice" "lathe" 20 %effort-unit "shed")
    (let ((res ($ obs 'get-resource "means:EAlice:lathe")))
      (check "a raise + a metadata edit in one declare: onhand 20, at the shed"
             (list (measure-has-numerical-value (economic-resource-onhand-quantity res))
                   (economic-resource-current-location res))
             '(20 "shed")))

    (display "\n── retire-means: a lower to zero, the record standing ──\n")
    ($ svc 'retire-means "commune-1" "EAlice" "lathe")
    (let ((res ($ obs 'get-resource "means:EAlice:lathe")))
      (check "onhand is zero — withdrawn from every qty>0 reader"
             (measure-has-numerical-value (economic-resource-onhand-quantity res)) 0)
      (check "the record and its history remain"
             (and res (>= (length ($ obs 'events-for-resource "means:EAlice:lathe")) 3))
             #t))))

(test-summary!)
