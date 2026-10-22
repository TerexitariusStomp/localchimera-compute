;;; module/playnet/compute/adapters.scm — the executor adapters: how a
;;; registered replay executor actually reaches a service.
;;;
;;; executors.scm is the table; THIS file is the transport half of two of
;;; its kinds. Each adapter is one pure wire-shape builder plus a thin
;;; `run` closure over an injected transport — the codebase's rule
;;; everywhere: no transport, no lie. An adapter constructed without a
;;; caller still registers (the row an operator sees is honest) but its
;;; run answers 'unavailable rather than pretending the job ran.
;;;
;;; WHAT IS HERE:
;;;   • wasimoff-task — the Wasimoff broker's task JSON: wasm module
;;;     reference, argv, stdin. Wasimoff (MIT) is the adopted
;;;     browser-WASM executor; the broker answers task results over HTTP.
;;;   • make-wasimoff-executor — (transport) → <executor>: submit the
;;;     task, await the result, return the output's hash. Transport is
;;;     (lambda (method path body) → parsed-response).
;;;   • wasmcloud-invocation — the wasmCloud actor-invocation wire:
;;;     component id + operation + payload.
;;;   • make-wasmcloud-executor — same shape against a lattice host.
;;;
;;; The repro-spec fields map where they can: a 'deterministic job pins
;;; seed + engine-version into the invocation so the service's run is the
;;; run the receipt claims. Where the wire can't carry them the field
;;; rides through verbatim for the service to honor or refuse.

(define-module (playnet compute adapters)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (gcrypt hash)
  #:use-module (gcrypt base16)
  #:use-module (rnrs bytevectors)
  #:use-module (playnet compute specs)
  #:use-module (playnet compute envelope)
  #:use-module (playnet compute receipt)
  #:use-module (playnet compute executors)
  #:export (wasimoff-task make-wasimoff-executor
            wasmcloud-invocation make-wasmcloud-executor
            %transport-unavailable))


;;; ── the fail-closed transport ────────────────────────────────────────────
;;; Same convention as %replay-unavailable / verify-quote: absent a caller
;;; the adapter says so — the replay door turns it into 'unverifiable, not
;;; a crash and never a verdict.

(define (%transport-unavailable method path body)
  (error "adapter: no transport injected — service not wired"))


;;; ── Wasimoff ─────────────────────────────────────────────────────────────
;;; Broker task = {wasm, argv, stdin, fs?}. Our envelope's image is the
;;; module reference; entrypoint maps to argv[0]'s _start convention —
;;; wasm modules export _start, entrypoint is WASI's entry name when the
;;; module carries one. stdin is the inputHash-resolved body the service
;;; fetched; the adapter asks the broker to run and returns its output
;;; hash — replay compares.

(define (wasimoff-task envelope repro-spec)
  "The broker's task JSON from our envelope + repro pinning."
  `(("module"   . ,(job-envelope-image envelope))
    ("entry"    . ,(job-envelope-entrypoint envelope))
    ("stdin"    . ,(job-envelope-input-hash envelope))
    ("seed"     . ,(and repro-spec (repro-spec-seed repro-spec)))
    ("decoding" . ,(and repro-spec (repro-spec-decoding repro-spec)))))

(define* (make-wasimoff-executor #:key (transport %transport-unavailable)
                                       (broker-url ""))
  "An <executor> whose run submits the task to a Wasimoff broker and
   answers the result's hash. transport: (method path body) → parsed."
  (make-replay-executor
   #:kind 'wasimoff
   #:name (string-append "wasimoff:" broker-url)
   #:run (lambda (env repro)
           (let ((resp (transport 'post "/tasks" (wasimoff-task env repro))))
             ;; the broker answers {taskId} on submit, then result hash —
             ;; poll collapsed into one call here; the transport owns the
             ;; await semantics.
             (assq-ref resp 'outputHash)))))


;;; ── wasmCloud ────────────────────────────────────────────────────────────
;;; Lattice invocation = {component, operation, payload, seed}. wasmCloud
;;; (Apache-2.0, CNCF) is the adopted capability-linked host — its
;;; capability-provider model mirrors our door semantics: a component only
;;; reaches what it's linked to, so the envelope's caps translate to link
;;; names rather than ambient authority.

(define (wasmcloud-invocation envelope repro-spec)
  `(("component" . ,(job-envelope-image envelope))
    ("operation" . ,(job-envelope-entrypoint envelope))
    ("payload"   . ,(job-envelope-input-hash envelope))
    ("seed"      . ,(and repro-spec (repro-spec-seed repro-spec)))
    ("caps"      . ,(job-envelope-caps envelope))))

(define* (make-wasmcloud-executor #:key (transport %transport-unavailable)
                                        (host-id ""))
  "An <executor> whose run invokes the component on a wasmCloud host and
   answers the output hash."
  (make-replay-executor
   #:kind 'wasmcloud
   #:name (string-append "wasmcloud:" host-id)
   #:run (lambda (env repro)
           (let ((resp (transport 'post "/invoke"
                                  (wasmcloud-invocation env repro))))
             (assq-ref resp 'outputHash)))))
