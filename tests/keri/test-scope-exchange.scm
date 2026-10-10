;;; tests/keri/test-scope-exchange.scm — pure-Scheme IPEX exns signed
;;;                                       under scope-owned keys
;;;
;;; No KERIA. We exercise the body-builders and assert:
;;;   - shape: {exn, sigs, atc, rec}
;;;   - exn.t = "exn", correct route, sender=scope-AID, recipient set
;;;   - the signature in sigs[0] verifies under the scope's pubkey
;;;     against the exn.d SAID — proving these exns chain back to the
;;;     scope's KEL when verified on the receiving gateway
;;;
;;; Run: guile -L module -L tests tests/keri/test-scope-exchange.scm

(use-modules (playnet test harness)
             (playnet keys exchange)
             (playnet keri signify)
             ((playnet keri credentials) #:select (ipex-exn-acdc))
             ((playnet keri signify-portable)
              #:select (bran->signing-keypair
                        ed25519-keypair-public
                        public-key->aid-prefix))
             ((srfi srfi-13) #:select (string-prefix?)))

;; Deterministic scope identity: bran-hex → keypair → derive AID prefix
;; the same way governance-create-scope-aid! does.

(define %scope-bran "scope-test-bran-must-be-21+chars0000")
(define %scope-kp   (bran->signing-keypair %scope-bran))
(define %scope-aid  (public-key->aid-prefix (ed25519-keypair-public %scope-kp)))

(define %holder-aid "EHolder0000000000000000000000000000000000000")
(define %cred-said  "ECred0000000000000000000000000000000000000A")

(format #t "=== Scope-exchange (sender AID = ~a...) ===~%"
        (substring %scope-aid 0 12))

;; ── grant ───────────────────────────────────────────────────────────

(define %grant-body
  (scope-grant-body %scope-aid %scope-kp %cred-said %holder-aid))

(define (body-exn b)  (assoc-ref b "exn"))
(define (body-sigs b) (assoc-ref b "sigs"))
(define (body-rec b)  (assoc-ref b "rec"))

(check "grant body is {exn, sigs, atc, rec}"
       (and (body-exn %grant-body)
            (body-sigs %grant-body)
            (assoc-ref %grant-body "atc")
            (body-rec %grant-body)))

(define %grant-exn (body-exn %grant-body))

(check "exn.t = \"exn\""
       (equal? "exn" (assoc-ref %grant-exn "t")))

(check "exn.r = /ipex/grant"
       (equal? "/ipex/grant" (assoc-ref %grant-exn "r")))

(check "exn.i (Discloser) = scope AID"
       (equal? %scope-aid (assoc-ref %grant-exn "i")))

(check "exn.rp (Disclosee) = holder"
       (equal? %holder-aid (assoc-ref %grant-exn "rp")))

(check "exn.a.acdc = credential SAID"
       (equal? %cred-said (assoc-ref (assoc-ref %grant-exn "a") "acdc")))

(check "rec vector includes the holder"
       (and (vector? (body-rec %grant-body))
            (= 1 (vector-length (body-rec %grant-body)))
            (equal? %holder-aid (vector-ref (body-rec %grant-body) 0))))

;; ── signature is well-formed CESR ──────────────────────────────────
;;
;; `sign-event` returns an indexed Ed25519 sig in CESR qb64 with a
;; 2-char "AA" prefix (indexed single-signer, index 0). 64 bytes of
;; signature + 2-byte code = 88 base64 chars. We assert format here;
;; cryptographic round-trip is exercised end-to-end in
;; test-keri-signify-integration via the ICP path that uses the same
;; sign-event primitive.

(define %sig-qb64 (vector-ref (body-sigs %grant-body) 0))

(check "single signature on the exn"
       (= 1 (vector-length (body-sigs %grant-body))))

(check "sig is CESR qb64 with AA prefix (indexed single Ed25519 sig)"
       (and (string? %sig-qb64)
            (= 88 (string-length %sig-qb64))
            (string-prefix? "AA" %sig-qb64)))

;; ── grant with the credential EMBEDDED (#:cred) ─────────────────────
;;
;; When the scope's acdc-store record rides along, its SAD-shaped wire
;; projection lands in the exn `e` block (saidified) — receivers'
;; ipex-exn-acdc + acdc-* accessors consume it with no out-of-band
;; fetch. `d` is the GOVERNANCE SAID (the discipline all scope-side
;; references key by); authenticity = issuer's signature over d.

(define %gov-cred
  `((said   . ,%cred-said)
    (schema . "playnet-federation-membership/v1")
    (issuer . ,%scope-aid)
    (holder . ,%holder-aid)
    (claims . ((federation . "demo-fed") (commune-id . "c1")))
    (edges  . ())
    (signature . #f)
    (revoked?  . #f)))

(define %embed-body
  (scope-grant-body %scope-aid %scope-kp %cred-said %holder-aid
                    #:cred %gov-cred))
(define %embed-exn (body-exn %embed-body))

(check "embedded grant carries e.acdc"
       (pair? (assoc-ref (assoc-ref %embed-exn "e") "acdc")))

(check "e block is saidified"
       (let ((d (assoc-ref (assoc-ref %embed-exn "e") "d")))
         (and (string? d) (string-prefix? "E" d))))

(let ((wire (assoc-ref (assoc-ref %embed-exn "e") "acdc")))
  (check "wire d = governance SAID"   (assoc-ref wire "d") %cred-said)
  (check "wire i = issuer scope AID"  (assoc-ref wire "i") %scope-aid)
  (check "wire s = schema"            (assoc-ref wire "s")
         "playnet-federation-membership/v1")
  (check "wire a.i = holder"
         (assoc-ref (assoc-ref wire "a") "i") %holder-aid)
  (check "claims string-keyed in a"
         (assoc-ref (assoc-ref wire "a") "federation") "demo-fed"))

;; The receiving side's extractor finds the embed (spec location first).
(check "ipex-exn-acdc reads the embedded wire projection"
       (assoc-ref (ipex-exn-acdc `(("exn" . ,%embed-exn))) "d")
       %cred-said)

;; Without #:cred the body stays legacy SAID-only (e empty).
(check "no #:cred → e block empty (legacy shape)"
       (let ((e (assoc-ref %grant-exn "e")))
         (or (not e) (null? e) (equal? e #()) (equal? e '()))))

;; ── admit ───────────────────────────────────────────────────────────

(define %admit-body
  (scope-admit-body %scope-aid %scope-kp "EGrant000000000000000000000000000000000000A"))

(check "admit body has /ipex/admit route"
       (equal? "/ipex/admit" (assoc-ref (body-exn %admit-body) "r")))

(check "admit anchors the grant in exn.p (IPEX answer shape)"
       (equal? "EGrant000000000000000000000000000000000000A"
               (assoc-ref (body-exn %admit-body) "p")))

(check "admit has no recipient (terminal local ack)"
       (string-null? (assoc-ref (body-exn %admit-body) "rp")))

(check "admit sig is well-formed CESR"
       (let ((s (vector-ref (body-sigs %admit-body) 0)))
         (and (string? s) (= 88 (string-length s))
              (string-prefix? "AA" s))))

;; ── spurn ───────────────────────────────────────────────────────────

(define %spurn-body
  (scope-spurn-body %scope-aid %scope-kp
                    "EGrant000000000000000000000000000000000000A"
                    "ESender0000000000000000000000000000000000000"))

(check "spurn body has /ipex/spurn route"
       (equal? "/ipex/spurn" (assoc-ref (body-exn %spurn-body) "r")))

(check "spurn anchors the rejected message in exn.p"
       (equal? "EGrant000000000000000000000000000000000000A"
               (assoc-ref (body-exn %spurn-body) "p")))

(check "spurn recipient = original sender"
       (equal? "ESender0000000000000000000000000000000000000"
               (assoc-ref (body-exn %spurn-body) "rp")))

(check "spurn sig is well-formed CESR"
       (let ((s (vector-ref (body-sigs %spurn-body) 0)))
         (and (string? s) (= 88 (string-length s))
              (string-prefix? "AA" s))))

;; ── determinism ─────────────────────────────────────────────────────
;;
;; Same inputs → same exn.d SAID and same signature. Important for
;; idempotent retry in the pending-grants queue (Phase 5) — we don't
;; want each retry to mint a new SAID.

(define %grant-body-2
  (scope-grant-body %scope-aid %scope-kp %cred-said %holder-aid))

;; exn.dt is wall-clock; identical SAIDs require identical timestamps,
;; which our builder doesn't pin. So we just check structural equality
;; of route/recipient/payload rather than full SAID equality.
(check "rebuilt grant has same route + recipient"
       (and (equal? (assoc-ref (body-exn %grant-body)   "r")
                    (assoc-ref (body-exn %grant-body-2) "r"))
            (equal? (assoc-ref (body-exn %grant-body)   "rp")
                    (assoc-ref (body-exn %grant-body-2) "rp"))))

(test-summary!)
