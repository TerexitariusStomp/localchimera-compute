;;; module/playnet/delegates.scm — the Tier-2 adapter seams.
;;;
;;; spec/oss-inventory.md's second tier: functionality kept, maintenance
;;; delegated to upstream OSS. Each adapter here is one pure wire-shape
;;; builder plus a run-closure over an injected transport — the same rule
;;; the compute adapters follow: no transport, no lie. A delegate built
;;; without a transport still exists (the row an operator reads is honest)
;;; but its call answers 'unavailable rather than pretending the upstream
;;; answered.
;;;
;;; The transports are all the same shape — (lambda (method path body) →
;;; parsed-response) — so one HTTP/GraphQL client injects into every seam.
;;; Where the upstream isn't an HTTP service at all (OR-Tools is a
;;; library, Cedar a policy engine) the seam documents the sidecar the
;;; deployment runs and the wire it speaks.
;;;
;;; Parity is the gate's rule: a Tier-2 module may only shrink after
;;; tests/parity/<suite>.scm proves the adapter reproduces its semantics —
;;; these builders are the half of that contract this repo owns.

(define-module (playnet delegates)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (web client)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:use-module (playnet compute adapters)
  #:export (%env-transport %json-http-transport wire->json
            sparql-request make-sparql-delegate
            opa-decision make-opa-delegate
            cedar-request make-cedar-delegate
            temporal-start-wire temporal-signal-wire make-temporal-delegate
            ntfy-wire make-ntfy-delegate
            radicale-report-wire make-radicale-delegate
            ap-activity make-ap-delegate
            decidim-ballot-wire make-decidim-delegate
            litellm-chat-wire make-litellm-delegate
            odoo-call-wire make-odoo-delegate
            bacalhau-job-wire make-bacalhau-delegate
            cpsat-wire make-cpsat-delegate))


;;; ── Apache Jena (Fuseki) — the knowledge corpus's query layer ────────────
;;; The corpus stays data; SPARQL is the query. Wire: the request body is
;;; the query itself — Fuseki answers application/sparql-results+json.

(define* (sparql-request query)
  "A Fuseki query request: POST the SPARQL text at the dataset's /sparql."
  `(("method" . "POST")
    ("accept" . "application/sparql-results+json")
    ("content-type" . "application/sparql-query")
    ("body" . ,query)))

(define* (make-sparql-delegate endpoint #:optional (transport %transport-unavailable))
  "(endpoint transport) → (lambda (query) → parsed-result).
   The corpus asks Jena; absent a transport the delegate is honest."
  (lambda (query)
    (catch #t
      (lambda ()
        (let ((req (sparql-request query)))
          (transport (cdr (assoc "method" req)) endpoint
                     (cdr (assoc "body" req)))))
      (lambda _ 'unavailable))))


;;; ── OPA — domain-door authorization ──────────────────────────────────────
;;; A door's "may I" is a policy question: POST /v1/data/<policy> {"input": …}

(define* (opa-decision policy-path input)
  "The OPA data-API request for POLICY-PATH over INPUT."
  `(("method" . "POST")
    ("path" . ,(string-append "/v1/data/" policy-path))
    ("content-type" . "application/json")
    ("body" . (("input" . ,input)))))

(define* (make-opa-delegate #:optional (transport %transport-unavailable))
  "() → (lambda (policy-path input) → decision-alist | 'unavailable)."
  (lambda (policy-path input)
    (catch #t
      (lambda ()
        (let ((req (opa-decision policy-path input)))
          (transport "POST" (cdr (assoc "path" req))
                     (cdr (assoc "body" req)))))
      (lambda _ 'unavailable))))


;;; ── Cedar — the alternate policy engine for the same door seam ───────────
;;; cedar-agent (upstream) answers /authorization with principals, actions,
;;; resources, entities, and the policy store id. Same verdict shape the
;;; doors consume: allow/deny + diagnostics.

(define* (cedar-request principal action resource entities)
  "The cedar-agent authorization wire."
  `(("method" . "POST")
    ("path" . "/authorization")
    ("content-type" . "application/json")
    ("body" . (("principal" . ,principal)
               ("action" . ,action)
               ("resource" . ,resource)
               ("entities" . ,entities)))))

(define* (make-cedar-delegate #:optional (transport %transport-unavailable))
  "() → (lambda (principal action resource entities) → verdict | 'unavailable)."
  (lambda (principal action resource entities)
    (catch #t
      (lambda ()
        (transport "POST" "/authorization"
                   (cdr (assoc "body" (cedar-request principal action resource entities)))))
      (lambda _ 'unavailable))))


;;; ── Temporal — side-effecting door bodies + claim-deadline workflows ─────
;;; Durable timers for the 72h challenge / 4d review / 7d closure clocks.
;;; Wire: the workflow-start and signal payloads the HTTP bridge speaks.

(define* (temporal-start-wire workflow-id workflow-type task-queue args)
  `(("method" . "POST")
    ("path" . ,(string-append "/workflows/" workflow-id))
    ("body" . (("workflowType" . ,workflow-type)
               ("taskQueue" . ,task-queue)
               ("args" . ,args)))))

(define* (temporal-signal-wire workflow-id signal-name payload)
  `(("method" . "POST")
    ("path" . ,(string-append "/workflows/" workflow-id "/signal/" signal-name))
    ("body" . ,payload)))

(define* (make-temporal-delegate #:optional (transport %transport-unavailable))
  "() → (lambda (wire) → response | 'unavailable) — caller builds the wire
   with temporal-start-wire / temporal-signal-wire."
  (lambda (wire)
    (catch #t
      (lambda ()
        (transport (cdr (assoc "method" wire))
                   (cdr (assoc "path" wire))
                   (cdr (assoc "body" wire))))
      (lambda _ 'unavailable))))


;;; ── ntfy / UnifiedPush — the notify seam ─────────────────────────────────
;;; POST /<topic> with the body as the message; headers carry title/priority.

(define* (ntfy-wire topic message #:optional title priority)
  `(("method" . "POST")
    ("path" . ,(string-append "/" topic))
    ("body" . ,message)
    ("headers" . ,(filter cdr
                    `(("X-Title" . ,(or title #f))
                      ("X-Priority" . ,(or priority #f)))))))

(define* (make-ntfy-delegate #:optional (transport %transport-unavailable))
  "() → (lambda (topic message) → response | 'unavailable)."
  (lambda (topic message)
    (catch #t
      (lambda ()
        (transport "POST" (string-append "/" topic) message))
      (lambda _ 'unavailable))))


;;; ── Radicale — the calendar's CalDAV ─────────────────────────────────────
;;; REPORT for range queries, PUT for writes. Wire carries both so the
;;; transport doesn't need to know which verb a given ask uses.

(define* (radicale-report-wire calendar-path depth filter-xml)
  `(("method" . "REPORT")
    ("path" . ,calendar-path)
    ("headers" . (("Depth" . ,(number->string depth))
                  ("Content-Type" . "application/xml")))
    ("body" . ,filter-xml)))

(define* (make-radicale-delegate #:optional (transport %transport-unavailable))
  "() → (lambda (calendar-path depth filter-xml) → response | 'unavailable)."
  (lambda (calendar-path depth filter-xml)
    (catch #t
      (lambda ()
        (let ((w (radicale-report-wire calendar-path depth filter-xml)))
          (transport (cdr (assoc "method" w))
                     (cdr (assoc "path" w))
                     (cdr (assoc "body" w)))))
      (lambda _ 'unavailable))))


;;; ── ActivityPub — the federation's outbox ────────────────────────────────
;;; Any AP-speaking server takes a signed activity POST at the actor's
;;; outbox. The wire is the activity; signing rides the transport's auth.

(define* (ap-activity type actor object #:optional to)
  `(("type" . ,type)
    ("actor" . ,actor)
    ("object" . ,object)
    ("to" . ,(or to '()))))

(define* (make-ap-delegate outbox-path #:optional (transport %transport-unavailable))
  "(outbox-path transport) → (lambda (activity) → response | 'unavailable)."
  (lambda (activity)
    (catch #t
      (lambda () (transport "POST" outbox-path activity))
      (lambda _ 'unavailable))))


;;; ── Decidim — ballots and sortitions ─────────────────────────────────────
;;; GraphQL: the wire is a mutation document + variables.

(define* (decidim-ballot-wire mutation variables)
  `(("method" . "POST")
    ("path" . "/api")
    ("content-type" . "application/json")
    ("body" . (("query" . ,mutation) ("variables" . ,variables)))))

(define* (make-decidim-delegate #:optional (transport %transport-unavailable))
  "() → (lambda (mutation variables) → graphql-result | 'unavailable)."
  (lambda (mutation variables)
    (catch #t
      (lambda ()
        (transport "POST" "/api"
                   (cdr (assoc "body" (decidim-ballot-wire mutation variables)))))
      (lambda _ 'unavailable))))


;;; ── LiteLLM — the inference key-pool ─────────────────────────────────────
;;; OpenAI-compatible /v1/chat/completions; the pool's routing keys ride
;;; the transport's auth header, never the wire.

(define* (litellm-chat-wire model messages #:optional opts)
  `(("model" . ,model)
    ("messages" . ,messages)
    ,@(or opts '())))

(define* (make-litellm-delegate #:optional (transport %transport-unavailable))
  "() → (lambda (model messages) → completion | 'unavailable).
   ⚠ verify the needed endpoints are OSS-tier before adopting — LiteLLM's
   key rotation is Enterprise; see spec/oss-inventory.md flags."
  (lambda (model messages)
    (catch #t
      (lambda ()
        (transport "POST" "/v1/chat/completions" (litellm-chat-wire model messages)))
      (lambda _ 'unavailable))))


;;; ── Odoo OCA — DDMRP inventory ───────────────────────────────────────────
;;; /jsonrpc object-execute: the wire is the standard service/method/args
;;; triple; the adapter is this thin because Odoo's own RPC is the contract.

(define* (odoo-call-wire model method args)
  `(("jsonrpc" . "2.0")
    ("method" . "call")
    ("params" . (("service" . "object")
                 ("method" . "execute_kw")
                 ("args" . (,model ,method ,args))))))

(define* (make-odoo-delegate #:optional (transport %transport-unavailable))
  "() → (lambda (model method args) → result | 'unavailable)."
  (lambda (model method args)
    (catch #t
      (lambda ()
        (transport "POST" "/jsonrpc" (odoo-call-wire model method args)))
      (lambda _ 'unavailable))))


;;; ── Bacalhau — ring-3 compute-over-data orchestration ────────────────────
;;; The job submission carries the spec the envelope already describes:
;;; engine, image/module, inputs, outputs. Bacalhau is Apache-2.0.

(define* (bacalhau-job-wire spec)
  `(("method" . "PUT")
    ("path" . "/api/v1/orchestrator/jobs")
    ("content-type" . "application/json")
    ("body" . (("Job" . ,spec)))))

(define* (make-bacalhau-delegate #:optional (transport %transport-unavailable))
  "() → (lambda (job-spec) → submission | 'unavailable)."
  (lambda (job-spec)
    (catch #t
      (lambda ()
        (transport "PUT" "/api/v1/orchestrator/jobs"
                   (cdr (assoc "body" (bacalhau-job-wire job-spec)))))
      (lambda _ 'unavailable))))


;;; ── OR-Tools CP-SAT — the general solver ─────────────────────────────────
;;; OR-Tools is a LIBRARY, not a service — the seam presumes the CP-SAT
;;; sidecar the deployment runs (or an in-process FFI binding; same wire
;;; either way). The request is the model proto's JSON form + a hint of
;;; the objective; the answer is the solver's status + assignment.

(define* (cpsat-wire model-proto #:optional params)
  `(("model" . ,model-proto)
    ("params" . ,(or params '()))))

(define* (make-cpsat-delegate #:optional (transport %transport-unavailable))
  "() → (lambda (model-proto) → solution | 'unavailable)."
  (lambda (model-proto)
    (catch #t
      (lambda ()
        (transport "POST" "/solve" (cpsat-wire model-proto)))
      (lambda _ 'unavailable))))


;;; ── the shared concrete transports ───────────────────────────────────────
;;; Every delegate's transport is (method path body) → response — one HTTP
;;; shape serves them all. %json-http-transport is the concrete client over
;;; Guile's web stack: JSON in, status out. %env-transport builds it from
;;; the box's own setting so a delegate can deploy by configuration alone —
;;; PLAYNET_<SERVICE>_URL names the endpoint, and unset still means
;;; 'unavailable: the seam never lies about a service that isn't there.

(define (wire->json x)
  "A wire alist → JSON: pairs keyed by strings encode as objects, plain
   lists as arrays, symbols/keywords as strings, #t/#f as booleans.
   guile-json's own scm->json-string can't take a list that isn't an
   alist — domain lists like (0 4) are exactly that."
  (cond
   ((and (pair? x) (pair? (car x))
         (or (string? (caar x)) (symbol? (caar x))))
    ;; an alist of string/symbol keys → a JSON object, emitted by hand
    (string-append "{"
      (string-join
       (map (lambda (p) (string-append
                         (scm->json-string
                          (if (symbol? (car p)) (symbol->string (car p)) (car p)))
                         ":" (wire->json (cdr p)))) x) ",") "}"))
   ((list? x)
    (string-append "[" (string-join (map wire->json x) ",") "]"))
   ((or (symbol? x) (keyword? x))
    (scm->json-string (symbol->string (if (keyword? x) (keyword->symbol x) x))))
   (else (scm->json-string x))))

(define* (%json-http-transport base-url #:key (headers '((content-type . (application/json)))))
  "(base-url #:headers) → (method path body) → (status . body) | raises.
   BODY is JSON-encoded when an alist, verbatim when a
   string/bytevector. HEADERS merges service-specific fields the wire
   requires — content-type is overridable (SPARQL is not JSON)."
  (lambda (method path body)
    (call-with-values
        (lambda ()
          (http-request (string->uri (string-append base-url path))
                        #:method (string->symbol method)
                        #:body (cond ((string? body) (string->utf8 body))
                                     ((bytevector? body) body)
                                     (else (string->utf8 (wire->json body))))
                        #:headers (append headers
                                          '((charset . "utf-8")))
                        #:streaming? #t))
      (lambda (response port)
        (let ((text (get-string-all port)))
          (cons (response-code response) text))))))

(define (%env-transport env-name)
  "The %json-http-transport for the endpoint ENV-NAME names, or #f when
   the environment doesn't set it — callers pass the #f through to the
   fail-closed default."
  (let ((base (getenv env-name)))
    (and base (not (string-null? base))
         (%json-http-transport base))))
