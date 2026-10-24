;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/machine/providers.scm — the ring-3 legs: the external
;;; networks a job may route to when every inner ring is empty.
;;;
;;; Ring 3 is the anonymous market; these are its concrete legs — the
;;; provider networks the commons already shares resources with. An
;;; adapter is a wire-shape builder plus a thin call over an INJECTED
;;; transport — the rule everywhere: no transport, no lie. A provider
;;; with no caller still names itself honestly; its call answers
;;; 'unavailable rather than pretending the network answered.
;;;
;;; WHAT IS HERE:
;;;   • *provider-specs* — the networks and the envelope kinds each can
;;;     take: golem (exec/bundle — Yagna demand+activity), mysterium
;;;     (relay egress — session API), storj (store — S3 put/uplink).
;;;   • provider-request — envelope → the provider's API wire shape.
;;;   • provider-call — (provider transport env) → result alist
;;;     {ref, outputHash} | raises %provider-unavailable.
;;;   • the transport table — register-provider-transport! /
;;;     provider-transport: the doors' injection seam, same shape as
;;;     the executor registry's register-executor!.
;;;   • ^bridge-store — the attempts ledger: which job went out to
;;;     which provider and what came back — the row a settlement
;;;     statement's payments entry names.
;;;
;;; THE ROUTE'S RULES live door-side (module/localchimera/doors/machine.scm):
;;; only a job submitted ring:3 may cross — the borrower declared the
;;; outer ring at submit, and INTERNAL/SECRET work never carries one —
;;; and only when 'match returns no inner offer. The provider sees the
;;; envelope's refs and caps, never credentials, never a price.

(define-module (localchimera machine providers)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module ((localchimera utils store-utils) #:select (serialize-hashmap
                                                     hashmap-filter))
  #:use-module (localchimera machine envelope)
  #:export (provider-for provider-serves? provider-request
            provider-call %provider-unavailable
            register-provider-transport! unregister-provider-transport!
            provider-transport
            <bridge-attempt> make-bridge-attempt bridge-attempt?
            bridge-attempt-id bridge-attempt-job-id bridge-attempt-provider
            bridge-attempt-ref bridge-attempt-output-hash
            bridge-attempt-state bridge-attempt-at
            bridge-attempt->list list->bridge-attempt
            ^bridge-store spawn-bridge-store))


;;; ── the fail-closed transport ────────────────────────────────────────────
;;; Same convention as %transport-unavailable in adapters.scm: absent a
;;; caller the provider says so — the bridge door turns it into a refusal,
;;; not a crash and never a fabricated result.

(define (%provider-unavailable . _)
  (error "provider: no transport injected — network not wired"))


;;; ── the specs — which networks take which kinds ─────────────────────────
;;; The wire each builds is the provider's own API shape; the envelope's
;;; refs cross, its params' committed fields cross, credentials never do.

(define *provider-specs*
  `((golem     . ((kinds . (exec bundle))
                  (path  . "/demand")))
    (mysterium . ((kinds . (relay))
                  (path  . "/session")))
    (storj     . ((kinds . (store))
                  (path  . "/objects")))))

(define (provider-for name)
  "The provider spec NAME (string or symbol) names, or #f."
  (let ((n (if (symbol? name) name (and (string? name) (string->symbol name)))))
    (and n (assoc n *provider-specs*))))

(define (provider-serves? name kind)
  "Does provider NAME take envelopes of KIND?"
  (let ((spec (provider-for name)))
    (and spec (memq kind (assq-ref (cdr spec) 'kinds)) #t)))

(define (provider-request name envelope)
  "The provider's API body for ENVELOPE — refs and committed fields only."
  (case (if (symbol? name) name (string->symbol name))
    ((golem)
     `(("image"     . ,(job-envelope-image envelope))
       ("entry"     . ,(job-envelope-entrypoint envelope))
       ("inputHash" . ,(job-envelope-input-hash envelope))
       ("caps"      . ,(job-envelope-caps envelope))))
    ((mysterium)
     `(("destination" . ,(params-ref (job-envelope-params envelope) 'destination))
       ("inputHash"   . ,(job-envelope-input-hash envelope))))
    ((storj)
     `(("inputHash" . ,(job-envelope-input-hash envelope))
       ("cid"       . ,(params-ref (job-envelope-params envelope) 'cid))))
    (else (error "provider: unknown network" name))))

(define (provider-call name transport envelope)
  "POST the provider's request wire; answer ((outputHash . …) (ref . …)).
   TRANSPORT is (method path body) → parsed response — absent, the call
   is %provider-unavailable's honest error."
  (let ((spec (provider-for name)))
    (unless spec (error "provider: unknown network" name))
    (let ((resp (transport 'post (assq-ref (cdr spec) 'path)
                           (provider-request name envelope))))
      (list (cons "outputHash" (or (assq-ref resp 'outputHash)
                                   (assoc-ref resp "outputHash")))
            (cons "ref"        (or (assq-ref resp 'ref)
                                   (assoc-ref resp "ref")
                                   (assq-ref resp 'taskId)
                                   (assoc-ref resp "taskId")
                                   (assq-ref resp 'id)
                                   (assoc-ref resp "id")))))))


;;; ── the transport table — the doors' injection seam ─────────────────────
;;; Same shape as executors.scm's register-executor!: the operator (or a
;;; test) registers a caller per provider name; unset reads fail closed.

(define *provider-transports* (make-hash-table))

(define (register-provider-transport! name transport)
  (hash-set! *provider-transports*
             (if (symbol? name) name (string->symbol name)) transport))

(define (unregister-provider-transport! name)
  (hash-remove! *provider-transports*
                (if (symbol? name) name (string->symbol name))))

(define (provider-transport name)
  "The registered caller for NAME, or #f — the door passes #f through to
   the fail-closed call."
  (hash-ref *provider-transports*
            (if (symbol? name) name (string->symbol name)) #f))


;;; ── the attempts ledger ──────────────────────────────────────────────────
;;; One row per outbound bridge: the job, the network, the provider's ref,
;;; the result hash when it answered. The settlement statement's payments
;;; entries point at these rows — the money side stays the treasury edge's.

(define-record-type <bridge-attempt>
  (%make-bridge-attempt id job-id provider ref output-hash state at)
  bridge-attempt?
  (id          bridge-attempt-id)
  (job-id      bridge-attempt-job-id)
  (provider    bridge-attempt-provider)   ; symbol
  (ref         bridge-attempt-ref)        ; provider's task/session id | #f
  (output-hash bridge-attempt-output-hash); what the network answered | #f
  (state       bridge-attempt-state)      ; 'answered | 'unavailable
  (at          bridge-attempt-at))        ; epoch ms

(define* (make-bridge-attempt #:key id job-id provider ref output-hash state at)
  (unless (and (string? id) (not (string-null? id)))
    (error "bridge-attempt: id must be a non-empty string" id))
  (unless (string? job-id)
    (error "bridge-attempt: job-id must be a string" job-id))
  (unless (symbol? provider)
    (error "bridge-attempt: provider must be a symbol" provider))
  (unless (memq state '(answered unavailable))
    (error "bridge-attempt: state must be 'answered or 'unavailable" state))
  (%make-bridge-attempt id job-id provider ref output-hash state at))

(define (bridge-attempt->list a)
  (list (bridge-attempt-id a) (bridge-attempt-job-id a)
        (symbol->string (bridge-attempt-provider a))
        (bridge-attempt-ref a) (bridge-attempt-output-hash a)
        (symbol->string (bridge-attempt-state a)) (bridge-attempt-at a)))

(define (list->bridge-attempt l)
  (make-bridge-attempt #:id (list-ref l 0) #:job-id (list-ref l 1)
                       #:provider (string->symbol (list-ref l 2))
                       #:ref (list-ref l 3) #:output-hash (list-ref l 4)
                       #:state (string->symbol (list-ref l 5))
                       #:at (list-ref l 6)))

(define (^bridge-store bcom attempts)
  (methods
    ((put! a)
     (bcom (^bridge-store bcom (hashmap-set attempts (bridge-attempt-id a) a))
           (bridge-attempt-id a)))
    ((of id)      (hashmap-ref attempts id #f))
    ((by-job jid) (hashmap-filter
                   (lambda (a) (equal? (bridge-attempt-job-id a) jid)) attempts))
    ((all)        (hashmap-filter (lambda (v) #t) attempts))
    ((portrait)   (list 'bridge-store
                        (serialize-hashmap attempts bridge-attempt->list)))))

(define (spawn-bridge-store)
  (spawn ^bridge-store (hashmap)))
