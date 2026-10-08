;;; doors/demo-stage.scm — the demo neighbourhood, standing in a real scope.
;;;
;;; Spawns a scope, its planner service and its governance, seeds the demo
;;; neighbourhood (worlds/demo-neighbourhood.scm) into it and plays its acts. What
;;; comes back are the doors, so a reader asks the standing scope what a seat
;;; would ask a gateway. The neighbourhood's suite and the demo recorder
;;; (tools/demo-emit.scm) both read it here.

(define-module (playnet planner doors demo-stage)
  #:use-module (goblins)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet planner scope root)
  #:use-module (playnet planner doors service)
  #:use-module (playnet governance scope)
  #:use-module (playnet governance service)
  #:use-module (playnet keri acdc-store)
  #:use-module (playnet keri citizen-sig)
  #:use-module ((playnet keri citizen-sig)
                #:select (make-keri-identity keri-identity-keypair keri-identity-aid))
  #:use-module (playnet planner knowledge dsl world)
  #:use-module (playnet planner knowledge worlds demo-neighbourhood)
  #:export (stage-demo))

(define (stage-demo today)
  "The demo neighbourhood standing in a scope of its own, its acts played as of
   TODAY (a unix second). Returns ((planner . CALL) (governance . GOV) (root .
   SCOPE-ROOT) (replies . the acts' replies)): CALL and GOV are the two
   services' doors, (call method arg …)."
  (let* ((vat  (spawn-vat #:name "demo"))
         (kit  (with-vat vat
                 (let* ((commune (make-keri-identity))
                        (root    (spawn-scope-root "Neighbourhood"))
                        (store   (spawn-acdc-store))
                        (scope   (spawn-scope "Neighbourhood" #:kind 'commune #:scope-root-ref root
                                              #:scope-aid (keri-identity-aid commune)
                                              #:keypair (keri-identity-keypair commune)
                                              #:acdc-store store))
                        (svc     (spawn ^planner-service (hashmap-set (hashmap) %demo-scope root)))
                        (gov     (spawn-governance-service
                                  (list root) ($ root 'ballot-store)
                                  #:acdc-store store #:home-scope scope
                                  #:scope-root-of (lambda (sid) (and (equal? sid %demo-scope) root))
                                  #:governor? (lambda (a) (equal? a (keri-identity-aid commune))))))
                   (seed-world! root (demo-world-on today))
                   (list root svc gov))))
         (root (car kit)) (svc (cadr kit)) (gov (caddr kit))
         (call (lambda (method . args) (with-vat vat (apply $ svc method args))))
         (ask  (lambda (method . args) (with-vat vat (apply $ gov method args))))
         (replies (play-demo! call
                              (lambda (who event-id reason)
                                (ask 'contest-work who %demo-scope event-id reason))
                              today)))
    `((planner . ,call) (governance . ,ask) (root . ,root) (vat . ,vat) (replies . ,replies))))
