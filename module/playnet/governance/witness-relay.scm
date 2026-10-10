;;; witness-relay.scm — the work-witness ceremony's CROSS-GATEWAY transport,
;;; on the rail gateways actually share: state files served by the static
;;; tier, pulled by the peer poll — the same shape /scopes federation rides.
;;;
;;; ── WHY NOT /multisig/exn ───────────────────────────────────────────────
;;; The ceremony's earlier comments pointed at KERIA's exn routes. Read at
;;; the source, that rail cannot carry this: keripy's Multiplexor.add
;;; (keri/app/grouping.py) DROPS any /multisig/* exn without an embedded
;;; event block before notifying, and its catch-all route case raises
;;; unless `payload["gid"]` names a group the receiver is a member of —
;;; /multisig/exn is strictly group-key coordination, not a directed
;;; message rail. KERIA raises notifications only from its own protocol
;;; handlers (ipex, multisig groups, challenges), so an arbitrary directed
;;; exn arrives nowhere a poller can see. Proven live in the two-box
;;; harness before this module replaced that leg.
;;;
;;; ── THE SHAPE ───────────────────────────────────────────────────────────
;;; A REQUEST is a small public fact: "statement S over W's work seeks
;;; co-signers" — so it publishes as a file under <state>/witness/requests,
;;; served by serve-static at /witness/requests, and every peer's poll tick
;;; remembers what it reads. An ATTEST is the voucher's own signature over
;;; S — it publishes under <state>/witness/attests, and the ORIGIN's poll
;;; tick lands every one it can (a said with no collecting ceremony lands
;;; nowhere, silently; a bad signature refuses at the landing, exactly as a
;;; local attest does — the transport earns no leniency, and needs none:
;;; the co-signature carries its own cryptography).

(define-module (playnet governance witness-relay)
  #:use-module (playnet governance acdc-bridge)
  #:use-module (playnet governance attestation-ceremony)
  #:use-module ((playnet utils paths) #:select (playnet-state-dir))
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 format)
  #:use-module (json)
  #:use-module ((web client)   #:select (http-get))
  #:use-module ((web response) #:select (response-code))
  #:use-module ((rnrs bytevectors) #:select (utf8->string bytevector?))
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:export (publish-witness-request! retract-witness-request!
            publish-witness-attest!
            witness-dir witness-files-json ensure-dir! safe-name
            poll-peer-witness! land-remote-attests! make-federated-witness-door
            peer-universal-commune-aid))

(define (witness-dir kind)
  (string-append (playnet-state-dir) "/witness/" kind))

(define (ensure-dir! path)
  (let loop ((p path))
    (unless (file-exists? p)
      (loop (dirname p))
      (catch #t (lambda () (mkdir p)) (lambda _ #f)))))

;; File names must come from SAIDs/AIDs (qb64: alphanumeric, - and _),
;; but the writer never trusts that: anything else is dropped to _.
(define (safe-name s)
  (string-map (lambda (c)
                (if (or (char-alphabetic? c) (char-numeric? c)
                        (char=? c #\-) (char=? c #\_))
                    c #\_))
              s))

(define (write-json! path alist)
  (ensure-dir! (dirname path))
  (call-with-output-file path
    (lambda (port) (put-string port (scm->json-string alist)))))

;;; ── the writer half (what serve-static exposes) ─────────────────────────

(define (%ctx-value->string v)
  (cond ((string? v) v)
        ((number? v) (number->string v))
        ((symbol? v) (symbol->string v))
        (else "")))

(define (publish-witness-request! said ctx)
  "Publish a collecting ceremony's ask: statement SAID + the symbol-keyed
   ceremony context, as one JSON file every peer's poll can read. The
   context is carried GENERICALLY — a work ask (worker/skill/hours) and
   an enrollment ask (candidate/sponsor/evidence) ride the same file,
   distinguished by their `kind` field."
  (write-json! (string-append (witness-dir "requests") "/" (safe-name said) ".json")
               (cons (cons "said" said)
                     (map (lambda (p)
                            (cons (symbol->string (car p))
                                  (%ctx-value->string (cdr p))))
                          ctx))))

(define (retract-witness-request! said)
  "The ceremony closed: its ask leaves the served set."
  (let ((f (string-append (witness-dir "requests") "/" (safe-name said) ".json")))
    (when (file-exists? f) (delete-file f))))

(define* (publish-witness-attest! said witness-aid sig #:optional (bundle #f))
  "Publish one co-signature where the origin's poll will find it. One file
   per (statement, witness): a second witness never overwrites the first.
   BUNDLE, when given, is the witness's credential bundle as a JSON string
   (governance-service fp-my-vouches) — their personhood and key log, so
   the origin can check the signature of someone it has never seen."
  (write-json! (string-append (witness-dir "attests") "/"
                              (safe-name said) "." (safe-name witness-aid) ".json")
               `(("said" . ,said) ("witness" . ,witness-aid) ("sig" . ,sig)
                 ,@(if (string? bundle) `(("bundle" . ,bundle)) '()))))

(define (witness-files-json kind)
  "Every published file of KIND, as one JSON array string — what
   serve-static answers at /witness/KIND."
  (let* ((dir (witness-dir kind))
         (names (if (file-exists? dir)
                    (or (scandir dir (lambda (e) (string-suffix? ".json" e))) '())
                    '())))
    (string-append
     "[" (string-join
          (filter-map (lambda (n)
                        (catch #t
                          (lambda ()
                            (call-with-input-file (string-append dir "/" n)
                              (lambda (p) (get-string-all p))))
                          (lambda _ #f)))
                      names)
          ",")
     "]")))

;;; ── the reader half (one peer poll tick) ────────────────────────────────

(define (fetch-json url)
  (catch #t
    (lambda ()
      (call-with-values (lambda () (http-get url #:streaming? #f))
        (lambda (response body)
          (and (= 200 (response-code response))
               (json-string->scm
                (cond ((string? body) body)
                      ((bytevector? body) (utf8->string body))
                      (else (object->string body))))))))
    (lambda (k . a)
      ;; a fetch that cannot even be made is worth a line when someone is
      ;; watching the rail; refusal stays the default either way
      (when (getenv "PLAYNET_WITNESS_POLL_DEBUG")
        (format (current-error-port) "[witness-relay] fetch ~a: ~a ~s~%" url k a))
      #f)))

(define (as-list v)
  (cond ((vector? v) (vector->list v))
        ((list? v) v)
        (else '())))

(define* (poll-peer-witness! base-url #:key (in-vat (lambda (th) (th))) (present #f))
  "One tick against one peer: their open REQUESTS are remembered for this
   gateway's own inboxes, and every ATTEST they published is offered to the
   landing — a said with no collecting ceremony here lands nowhere, an
   already-counted witness raises and is dropped, and a finalized landing
   retracts our own request file. An attest that carries a BUNDLE is
   PRESENTed first ((witness-aid bundle-json) → the governance service's
   present-bundle), so a witness this gateway never saw becomes checkable
   before their signature lands. Returns (requests-seen . attests-landed)."
  (let ((reqs (as-list (fetch-json (string-append base-url "/witness/requests"))))
        (atts (as-list (fetch-json (string-append base-url "/witness/attests"))))
        (landed 0))
    (for-each
     (lambda (r)
       (let ((said (assoc-ref r "said")))
         (when (and (string? said) (not (remote-witness-request said)))
           ;; Rebuild the context generically — the inverse of
           ;; publish-witness-request! — so any ceremony kind survives
           ;; the round-trip; `origin` names where the co-signature
           ;; returns to.
           (remember-remote-witness-request!
            said
            (cons (cons 'origin base-url)
                  (filter-map (lambda (p)
                                (and (string? (car p))
                                     (not (equal? "said" (car p)))
                                     (cons (string->symbol (car p)) (cdr p))))
                              r))))))
     reqs)
    (set! landed (land-remote-attests! atts #:in-vat in-vat #:present present))
    (cons (length reqs) landed)))

(define* (land-remote-attests! atts #:key (in-vat (lambda (th) (th))) (present #f))
  "Offer every peer-published attest in ATTS (string-keyed alists: said,
   witness, sig, optional bundle) to the landing. A bundle is PRESENTed
   before its signature lands; a said with no collecting ceremony lands
   nowhere; a duplicate, ineligible or badly signed one is refused and
   dropped. Returns how many landed."
  (let ((landed 0))
    (for-each
     (lambda (a)
       (let ((said (assoc-ref a "said")))
         (when (string? said)
           (catch #t
             (lambda ()
               (let ((res (in-vat
                           (lambda ()
                             (let ((b (assoc-ref a "bundle")))
                               (when (and present (string? b))
                                 (present (assoc-ref a "witness") b)))
                             (land-witness-attestation!
                              said (assoc-ref a "witness") (assoc-ref a "sig"))))))
                 (when res (set! landed (+ landed 1)))
                 (when (eq? res 'finalized)
                   (retract-witness-request! said))))
             (lambda _ #f)))))     ; duplicate/ineligible/bad-sig: refused, dropped
     atts)
    landed))

(define (peer-universal-commune-aid base-url)
  "The Universal Commune a peer's static tier names (/universal-commune.json),
   or #f — read on the same tick as its witness rail, so a peer's root is
   learned by the thread that already reaches it."
  (let ((j (fetch-json (string-append base-url "/universal-commune.json"))))
    (and (list? j) (let ((a (assoc-ref j "aid"))) (and (string? a) a)))))

;;; ── the door (what ^planner-service consumes) ───────────────────────────

(define* (make-federated-witness-door #:key store-of (bundle-of #f))
  "The planner service's witness door, whole: OPEN spawns (or finds) the
   ceremony over STORE-OF's credential store and PUBLISHES the ask for
   every peer's poll to find; INBOX is the merged local+remote list;
   ATTEST lands a local said directly, and publishes a remote one where
   its origin's poll will find it — beside the witness's own bundle
   (BUNDLE-OF aid → JSON string or #f) so the origin can check them. File
   writes only — no vat turn ever waits on a network."
  `((open  . ,(lambda (scope-aid ev roster)
                (let ((said (open-work-witnessing! (store-of scope-aid)
                                                   scope-aid ev roster)))
                  (when said
                    (let ((ctx (witness-pending-context said)))
                      (when ctx (publish-witness-request! said ctx))))
                  said)))
    (inbox . ,witness-work-inbox)
    ;; a skill's social standing: what the store's witnessed work events say
    ;; about WORKER per skill, and the ceremonies still collecting over them
    ;; across SCOPE-AIDS when the caller names them (the roster): work is
    ;; witnessed where it was done, a person's standing is every scope's
    (standing . ,(lambda (scope-aid worker . scope-aids)
                   (let ((stores (map store-of (if (pair? scope-aids) (car scope-aids) (list scope-aid)))))
                     (apply skill-attestation-standing (car stores) worker (cdr stores)))))
    (outbox . ,witness-work-outbox)
    (attest . ,(lambda (said aid sig)
                 (let ((res (land-witness-attestation! said aid sig)))
                   (cond
                    (res (when (eq? res 'finalized)
                           (retract-witness-request! said))
                         res)
                    ((remote-witness-request said)
                     (publish-witness-attest! said aid sig
                                              (and bundle-of (false-if-exception (bundle-of aid))))
                     (forget-remote-witness-request! said)
                     'sent)
                    (else #f)))))))
