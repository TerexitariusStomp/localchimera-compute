;;; tests/planner/test-lint-records-door.scm — the ValueFlows lint as a planner door
;;;
;;; What this pins: `lint-records` on the service answers findings JSON over a
;;; JSON array of records, judged against THAT scope's specs and units — a spec
;;; the scope does not know is an error, a unit it counts differently a
;;; warning, a well-formed event clean — and a bad body is an error envelope,
;;; never a crash.
;;;
;;; Run: guile -L module tests/planner/test-lint-records-door.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness) (playnet scope root) (playnet vf schemas) (playnet doors service)
             (playnet vf schemas)
             (goblins) (goblins vat) (goblins utils hashmap) (json) (srfi srfi-1))

(define vat (spawn-vat))
(define-values (svc reply)
  (with-vat vat
    (let* ((sr  (spawn-scope-root "Lint Scope"))
           (rs  ($ sr 'recipe-store))
           (svc (spawn ^planner-service (hashmap))))
      ($ rs 'add-resource-spec (make-resource-specification #:id "spec-flour" #:name "Flour"
                                                            #:default-unit-of-resource "kg"))
      ($ rs 'add-resource-spec (make-resource-specification #:id "spec-baker" #:name "Baker"
                                                            #:default-unit-of-resource %effort-unit))
      ($ svc 'add-scope! "s1" sr)
      (values svc (lambda (json) ($ svc 'lint-records "s1" json))))))

(define (unwrap r) (if (and (pair? r) (eq? (car r) 'ok)) (cdr r) r))
(define (findings json) (vector->list (json-string->scm (unwrap (with-vat vat (reply json))))))
(define (kinds fs) (map (lambda (f) (assoc-ref f "kind")) fs))

(display "\n── the door judges against the scope's own specs ──\n")
(check "a well-formed event is clean"
       (findings "[{\"action\":\"consume\",\"spec\":\"spec-flour\",\"qty\":2,\"unit\":\"kg\"}]") '())
(check "a spec the scope does not know is an error"
       (kinds (findings "[{\"action\":\"consume\",\"spec\":\"spec-unicorn\",\"qty\":2,\"unit\":\"kg\"}]"))
       '("unknown-spec"))
(check "a unit the scope counts differently is a warning"
       (map (lambda (f) (assoc-ref f "severity"))
            (findings "[{\"action\":\"consume\",\"spec\":\"spec-flour\",\"qty\":2,\"unit\":\"liters\"}]"))
       '("warning"))
(check "a need's arcs are judged"
       (kinds (findings "[{\"kind\":\"need\",\"spec\":\"spec-flour\",\"qty\":1,\"unit\":\"kg\",\"arcs\":[{\"days\":[\"monday\"],\"start\":\"9\",\"end\":\"10:00\"}]}]"))
       '("bad-arc-time"))
(check-pred "a body that is not JSON is an error envelope, not a crash"
            (let ((r (with-vat vat (reply "nope"))))
              (and (pair? r) (eq? (car r) 'error))))
(check-pred "an unknown scope is an error envelope"
            (let ((r (with-vat vat ($ svc 'lint-records "nowhere" "[]"))))
              (and (pair? r) (eq? (car r) 'error))))

(test-summary!)
