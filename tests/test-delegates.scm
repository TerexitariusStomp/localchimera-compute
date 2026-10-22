;;; tests/test-delegates.scm — the Tier-2 seams: wire shapes are pinned,
;;; fail-closed defaults refuse, injected transports answer. Same rule as
;;; the compute adapters — the thin shipped is the wire the upstream reads.

(use-modules (playnet test harness)
             (playnet delegates)
             (srfi srfi-1))

;; a transport that records what it was asked and answers a fixed body —
;; the delegate tests care that the request LANDS shaped right.
(define (capture answer)
  (let ((calls '()))
    (cons (lambda (method path body)
            (set! calls (cons (list method path body) calls))
            answer)
          (lambda () (reverse calls)))))

;; ── fail-closed: no transport → 'unavailable, never a crash ──────────────

(check "sparql delegate without a transport answers unavailable"
       ((make-sparql-delegate "http://jena/ds") "SELECT * {}") 'unavailable)
(check "opa delegate without a transport answers unavailable"
       ((make-opa-delegate) "doors/member" '(("who" . "alice"))) 'unavailable)
(check "cedar delegate without a transport answers unavailable"
       ((make-cedar-delegate) "p" "a" "r" '()) 'unavailable)
(check "ntfy delegate without a transport answers unavailable"
       ((make-ntfy-delegate) "topic" "hello") 'unavailable)
(check "litellm delegate without a transport answers unavailable"
       ((make-litellm-delegate) "llama" '()) 'unavailable)
(check "odoo delegate without a transport answers unavailable"
       ((make-odoo-delegate) "stock.buffer" "read" '()) 'unavailable)
(check "bacalhau delegate without a transport answers unavailable"
       ((make-bacalhau-delegate) '(("Engine" . "wasm"))) 'unavailable)
(check "cpsat delegate without a transport answers unavailable"
       ((make-cpsat-delegate) '(("variables" . ()))) 'unavailable)

;; ── wire shapes: the delegate's ask reaches the transport shaped right ────

(let* ((cap (capture '(("results" . (("bindings" . ()))))))
       (d (make-sparql-delegate "http://jena/ds" (car cap)))
       (ans (d "SELECT ?s {}")))
  (check "sparql delegate reaches the endpoint with the query body"
         (let ((call (car ((cdr cap)))))
           (and (equal? ans '(("results" . (("bindings" . ())))))
                (equal? (cadr call) "http://jena/ds")
                (equal? (caddr call) "SELECT ?s {}"))) #t))

(let* ((cap (capture '(("result" . #t))))
       (d (make-opa-delegate (car cap)))
       (ans (d "doors/member" '(("who" . "alice")))))
  (check "opa delegate posts /v1/data/<policy> with the input wrapped"
         (let ((call (car ((cdr cap)))))
           (and (equal? (car call) "POST")
                (equal? (cadr call) "/v1/data/doors/member")
                (equal? (caddr call) '(("input" . (("who" . "alice")))))))
         #t))

(let* ((cap (capture '(("decision" . "Allow"))))
       (d (make-cedar-delegate (car cap)))
       (ans (d "User::\"alice\"" "Action::\"lend\"" "Lane::\"gpu\"" '())))
  (check "cedar delegate posts the authorization quad"
         (let ((call (car ((cdr cap)))))
           (equal? (cadr call) "/authorization")) #t))

(let* ((cap (capture "ok"))
       (d (make-ntfy-delegate (car cap)))
       (ans (d "commune-alerts" "a claim expired")))
  (check "ntfy delegate posts the message to /<topic>"
         (let ((call (car ((cdr cap)))))
           (and (equal? (cadr call) "/commune-alerts")
                (equal? (caddr call) "a claim expired"))) #t))

(let* ((cap (capture '(("choices" . ()))))
       (d (make-litellm-delegate (car cap)))
       (ans (d "llama-3.2" '((("role" . "user") ("content" . "hi"))))))
  (check "litellm delegate posts the OpenAI wire to /v1/chat/completions"
         (let* ((call (car ((cdr cap))))
                (body (caddr call)))
           (and (equal? (cadr call) "/v1/chat/completions")
                (equal? (cdr (assoc "model" body)) "llama-3.2"))) #t))

(let* ((cap (capture '(("result" . 42))))
       (d (make-odoo-delegate (car cap)))
       (ans (d "stock.buffer" "search_read" '((("id" . 1))))))
  (check "odoo delegate wraps the call in JSON-RPC execute_kw"
         (let* ((call (car ((cdr cap))))
                (body (caddr call)))
           (equal? (cdr (assoc "method" body)) "call")) #t))

(let* ((cap (capture '(("jobID" . "j-9"))))
       (d (make-bacalhau-delegate (car cap)))
       (ans (d '(("Engine" . "wasm") ("Publisher" . "estuary")))))
  (check "bacalhau delegate PUTs the job to the orchestrator"
         (let ((call (car ((cdr cap)))))
           (equal? (car call) "PUT")) #t))

(let* ((cap (capture '((status . "OPTIMAL"))))
       (d (make-cpsat-delegate (car cap)))
       (ans (d '(("variables" . (("x" . (("domain" . (0 10))))))))))
  (check "cpsat delegate posts the model proto to /solve"
         (let ((call (car ((cdr cap)))))
           (and (equal? (cadr call) "/solve")
                (assoc "model" (caddr call)) #t)) #t))

(let* ((cap (capture '(("id" . "wf-1"))))
       (d (make-temporal-delegate (car cap)))
       (wire (temporal-start-wire "wf-1" "ClaimDeadline" "compute" '()))
       (ans (d wire)))
  (check "temporal delegate posts the start wire it was handed"
         (let ((call (car ((cdr cap)))))
           (and (equal? (car call) "POST")
                (equal? (cadr call) "/workflows/wf-1"))) #t))

(let* ((cap (capture '(("data" . (("castBallot" . (("id" . "b1"))))))))
       (d (make-decidim-delegate (car cap)))
       (ans (d "mutation { castBallot { id } }" '(("ballotId" . 7)))))
  (check "decidim delegate posts the GraphQL document to /api"
         (let ((call (car ((cdr cap)))))
           (and (equal? (cadr call) "/api")
                (assoc "query" (caddr call)) #t)) #t))

(let* ((cap (capture "201 Created"))
       (d (make-ap-delegate "/actors/alice/outbox" (car cap)))
       (act (ap-activity "Create" "https://x/actors/alice" '(("type" . "Note"))))
       (ans (d act)))
  (check "activitypub delegate posts the activity to the outbox"
         (let ((call (car ((cdr cap)))))
           (and (equal? (cadr call) "/actors/alice/outbox")
                (equal? (cdr (assoc "type" (caddr call))) "Create"))) #t))

;; %env-transport — a deployable delegate: the environment names the
;; endpoint, unset still fails closed.
(check "%env-transport answers #f when the env is silent"
       (%env-transport "PLAYNET_TEST_UNSET_URL") #f)
(begin
  (setenv "PLAYNET_TEST_SET_URL" "http://upstream:9")
  (check "%env-transport builds a live transport when the env names one"
         (procedure? (%env-transport "PLAYNET_TEST_SET_URL")) #t)
  (unsetenv "PLAYNET_TEST_SET_URL"))

(let* ((cap (capture '(("multistatus" . ()))))
       (d (make-radicale-delegate (car cap)))
       (ans (d "/cal/alice/" 1 "<c:calendar-query/>")))
  (check "radicale delegate issues REPORT with the filter body"
         (let ((call (car ((cdr cap)))))
           (and (equal? (car call) "REPORT")
                (equal? (cadr call) "/cal/alice/"))) #t))

(test-summary!)
