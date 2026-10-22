;;; tests/parity/doors-opa.scm — domain-door authz ↔ OPA parity.
;;; The contract: a door's "may this citizen act" is a policy decision —
;;; POST /v1/data/<policy> {input}. Invariant leg pins the request wire;
;;; live leg reads a real decision.

(use-modules (playnet test harness)
             (playnet test parity)
             (playnet delegates)
             (srfi srfi-1))

(define fixture-input
  '(("citizen" . "did:key:z6MkAlice") ("door" . "compute-offer")
    ("commune" . "did:keri:EHome") ("action" . "create")))

(let ((w (opa-decision "playnet/doors/compute" fixture-input)))
  (check "opa wire posts /v1/data/<policy> with input wrapped"
         (and (equal? (cdr (assoc "path" w)) "/v1/data/playnet/doors/compute")
              (equal? (cdr (assoc "body" w)) `(("input" . ,fixture-input)))) #t))

(parity-live-delegate "PLAYNET_OPA_URL"
  "opa answers a door decision"
  (lambda (t) (make-opa-delegate t))
  (lambda (d) (d "playnet/doors/compute" fixture-input))
  (lambda (a) (and (pair? a) (< (car a) 300))))

(test-summary!)
