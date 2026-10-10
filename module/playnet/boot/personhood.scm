;;; module/playnet/boot/personhood.scm — First-Person on this gateway: the roots it honours, the founders, the issuers it trusts, the asks' rails.

(define-module (playnet boot personhood)
  #:use-module ((playnet boot site) #:select (founders log!))
  #:use-module ((playnet credentials registry) #:select (cred-signed-by-scope))
  #:use-module ((playnet doors lobby) #:select (release-contest-evidence!))
  #:use-module ((playnet economy socialization) #:select (vrc-groups-of))
  #:use-module ((playnet federation remote-scope-poller) #:select (parse-peers-env))
  #:use-module ((playnet keri acdc) #:select (cred-holder cred-issuer cred-live? cred-said cred-with-signature))
  #:use-module ((playnet keri first-person credentials) #:select (*schema-playnet-authorized-issuer* *schema-playnet-personhood*
                                                                  make-authorized-issuer-credential make-personhood-credential))
  #:use-module ((playnet keri first-person predicates) #:select (holds-any-live-phc? phc-live?))
  #:use-module ((playnet keys peers) #:select (known-uc-aid set-known-uc-aid!))
  #:use-module ((playnet personhood witnessed-work) #:select (current-vouch-reader))
  #:use-module ((playnet personhood enrollment) #:select (current-enroll-announcer))
  #:use-module ((playnet personhood witness-relay) #:select (peer-universal-commune-aid poll-peer-witness!))
  #:use-module (fibers)
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:use-module ((ice-9 threads) #:select (call-with-new-thread))
  #:use-module ((srfi srfi-1) #:select (delete-duplicates find))
  #:export (make-root-recogniser announce-enrollments! poll-peer-witnesses! stand-first-person!
            rehydrate-asks! seed-founders!))

(define (make-root-recogniser planner-vat governance-svc)
  "recognise-root!: the roots this gateway honours, as a growing set — its
own UC, and every peer's — one word to GOVERNANCE-SVC each time."
  (let ((roots '()))
    (lambda (aid)
      (when (and (string? aid) (not (member aid roots)))
        (set! roots (cons aid roots))
        (with-vat planner-vat
          ($ governance-svc 'set-fp-root! (if (null? (cdr roots)) (car roots) roots)))
        (log! "  [gateway] FP roots: ~a~%" (length roots))))))

;; ── being recognised: the ask's rails beyond the inbox ──────────
;; An enrollment ask is told to every recognised person through the
;; notify-router — their bound channels, the people who already vouch
;; for the candidate first — and the inbox says whether the reader
;; already vouches. Both read the gateway's credential store; the
;; announcer runs inside the planner vat (where ceremonies spawn), so
;; the store read is near and the router call crosses async.
(define (announce-enrollments! store notify-router)
  (current-vouch-reader
   (lambda (reader subject)
     (pair? (vrc-groups-of store reader subject))))
  (current-enroll-announcer
   (lambda (ctx)
     (let* ((cand  (assq-ref ctx 'worker))
            (people (delete-duplicates
                     (filter (lambda (a) (not (equal? a cand)))
                             (map cred-holder
                                  (filter phc-live?
                                          ($ store 'by-schema
                                             *schema-playnet-personhood*))))))
            (first (filter (lambda (a) (pair? (vrc-groups-of store a cand))) people))
            (rest  (filter (lambda (a) (not (member a first))) people)))
       (<-np notify-router 'notify-scope (append first rest)
             `((kind . enroll-ask)
               (said . ,(or (assq-ref ctx 'said) ""))
               (candidate . ,cand)
               (scope . ,(assq-ref ctx 'scope))))))))

(define (poll-peer-witnesses! planner-vat governance-svc recognise-root!)
  "…and the pull half: every peer's published requests and attests, on the
same cadence-and-trust shape the /scopes federation rides. A REAL THREAD
(blocking HTTP), landing inside the planner vat, where the ceremonies live."
  (let ((peers (parse-peers-env)))
    (when (pair? peers)
      (call-with-new-thread
       (lambda ()
         (let loop ()
           (for-each
            (lambda (peer)
              (catch #t
                (lambda ()
                  (let ((r (poll-peer-witness! peer
                             #:in-vat (lambda (th) (with-vat planner-vat (th)))
                             ;; a remote witness's bundle is presented before
                             ;; their signature lands (governance present-bundle)
                             #:present (lambda (witness bundle)
                                         ($ governance-svc 'present-bundle witness bundle)))))
                    (when (getenv "PLAYNET_WITNESS_POLL_DEBUG")
                      (log! "  [gateway] witness poll ~a → ~a~%" peer r)))
                  ;; a PEER is the operator's word that another graph is
                  ;; ours to recognise: its Universal Commune joins the
                  ;; roots this gateway honours (multi-root
                  ;; cross-recognition), learned on this same tick
                  (let ((uc (peer-universal-commune-aid peer)))
                    (when uc (recognise-root! uc))))
                (lambda (key . args)
                  (log! "  [gateway] witness poll ~a failed: ~a ~a~%"
                        peer key args))))
            peers)
           ;; PLAYNET_WITNESS_POLL_SECS: the harness runs two gateways
           ;; and cannot wait half a minute per hop
           (sleep (or (string->number (or (getenv "PLAYNET_WITNESS_POLL_SECS") "")) 30))
           (loop))))
      (log! "  [gateway] witness relay polling ~a peer(s): ~a~%" (length peers) peers))))

(define (rehydrate-asks! planner-vat governance-svc)
  "Every open enrollment ask comes back from its record — with the vouches
already gathered — now that the scope that signs its outcome stands."
  (with-vat planner-vat
    (let ((back (cdr ($ governance-svc 'fp-rehydrate!))))
      (when (pair? back)
        (log! "  [gateway] ~a enrollment ask(s) restored~%" (length back))))))

(define (seed-founders! planner-vat store fc-aid fc-scope)
  "Operator bootstrap: PLAYNET_FOUNDERS=aid1,aid2 each receive a founder PHC
in the founding commune FC-AID, signed by FC-SCOPE, starting the trust graph
and activating the personhood gate."
  (with-vat planner-vat
    (for-each
     (lambda (faid)
       ;; idempotent: one founder PHC per AID, not a new one
       ;; (fresh timestamp → fresh SAID) on every boot.
       (when (and (> (string-length faid) 0)
                  (not (holds-any-live-phc? store faid)))
         (catch #t
           (lambda ()
             ;; The founder PHC is the root of the trust
             ;; graph and the credential the personhood
             ;; gate reads, so it carries the founding
             ;; commune's signature. The scope signs it
             ;; through its own sign-said — the key stays
             ;; in the actor, and the issuer here IS
             ;; fc-aid, so the signature binds. The
             ;; signature is added after the SAID is
             ;; computed, so the idempotency above still
             ;; sees one PHC per founder.
             (let ()
               ($ store 'issue
                  (cred-signed-by-scope
                   (make-personhood-credential
                    fc-aid faid (current-time)
                    #:enrollment-evidence-digest "founder")
                   fc-scope))
               (log! "  [gateway] seeded founder PHC: ~a (~a)~%"
                     faid
                     (if fc-scope "signed" "unsigned — no scope key"))))
           (lambda (k . a)
             (log! "  [gateway] founder seed failed (~a): ~a ~a~%"
                   faid k a)))))
     (founders))))

(define* (stand-first-person! #:key planner-vat gateway-vat governance-svc planner-service store
                              uc-ref fc-aid recognise-root!)
  "First-Person's trust anchors once the durable tree stands: the contest
evidence release, the UC subtree's communes as trusted issuers, the UC as
the trust-registry root, its blessing of the founding commune FC-AID as an
issuer, and PLAYNET_FP_STRICT_ROOT."
  ;; First-Person: the UC subtree's commune AIDs are the issuers
  ;; whose PHCs we honour when a holder PRESENTS one from another
  ;; gateway (slice-2 trust anchor).
  ;; A counter's picture, attached to the contest of their count, is
  ;; held only for the ballot's life: when it settles, it is let go.
  (with-vat planner-vat
    ($ governance-svc 'set-contest-settled!
       release-contest-evidence!))
  (with-vat planner-vat
    (let ((aids (map (lambda (s) (assq-ref s 'id))
                     ($ planner-service 'scope-list))))
      ($ governance-svc 'set-fp-trusted-issuers! aids)
      (log! "  [gateway] FP trusted issuers: ~a commune(s)~%"
            (length aids))))
  ;; First-Person: the Universal Commune is the trust-registry
  ;; ROOT — an ecosystem is a legitimate PHC issuer iff it chains
  ;; to it (holds a live authorized-issuer credential). The
  ;; whitelist above stays as a fallback for pre-root flows.
  ;; the UC this gateway minted or restored IS the one it federates
  ;; with — unless the operator named another (PLAYNET_UC_AID)
  (when (and uc-ref (not (known-uc-aid)))
    (set-known-uc-aid! (with-vat gateway-vat ($ uc-ref 'scope-aid))))
  (when (known-uc-aid)
    (recognise-root! (known-uc-aid))
    (log! "  [gateway] FP trust-registry root = UC ~a~%"
          (known-uc-aid)))
  ;; the root's blessing of its founding commune — the
  ;; authorized-issuer credential a personhood issued here chains
  ;; through, held in the store every presentation reads, signed
  ;; by the UC's own key. Once: a standing live blessing stands.
  (when (and uc-ref fc-aid)
    (catch #t
      (lambda ()
        (let* ((uc-aid (known-uc-aid))
               (standing
                (with-vat planner-vat
                  (find (lambda (c) (and (equal? uc-aid (cred-issuer c))
                                         (equal? fc-aid (cred-holder c))
                                         (cred-live? c)))
                        ($ store 'by-schema *schema-playnet-authorized-issuer*)))))
          (unless standing
            (let* ((aic (make-authorized-issuer-credential uc-aid fc-aid (current-time)))
                   (sig (with-vat gateway-vat
                          ($ uc-ref 'sign-said (cred-said aic)))))
              (with-vat planner-vat
                ($ store 'issue (cred-with-signature aic sig)))
              (log! "  [gateway] UC blesses the founding commune as an issuer~%")))))
      (lambda (k . a)
        (log! "  [gateway] founding-commune blessing skipped: ~a ~a~%" k a))))
  ;; Retire the flat whitelist once the live root chain is
  ;; populated: PLAYNET_FP_STRICT_ROOT=1 makes trust derive ONLY
  ;; from chaining to root (see deployment.md Step 6).
  (when (member (getenv "PLAYNET_FP_STRICT_ROOT") '("1" "true" "yes"))
    (with-vat planner-vat
      ($ governance-svc 'set-fp-strict-root! #t))
    (log! "  [gateway] FP strict-root ON — whitelist retired~%")))
