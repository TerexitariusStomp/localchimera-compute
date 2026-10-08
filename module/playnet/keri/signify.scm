;;; module/playnet/keri/signify.scm — KERIA Signify auth client (server)
;;;
;;; Signify is the WebOfTrust client-side auth protocol for KERIA. It
;;; covers two distinct things:
;;;
;;;   1. /boot enrollment — POST a self-signed inception event (icp)
;;;      derived from the user's passcode (bran). KERIA computes the
;;;      controller AID prefix from the icp's SAID and stores it as
;;;      the agent's owner.
;;;
;;;   2. Per-request auth — RFC 9421 HTTP Message Signatures using
;;;      Ed25519 over a canonicalized base of @method, @path,
;;;      Signify-Resource, Signify-Timestamp.
;;;
;;; Architecture (post-Phase-A refactor):
;;;
;;;   signify-portable.scm — pure-Scheme core (HKDF, ICP, saidify,
;;;     event signing). Compiles for Hoot/WASM. Calls into a pluggable
;;;     crypto backend declared in (playnet keri crypto-primitives).
;;;
;;;   crypto-primitives.scm — backend installer.
;;;
;;;   THIS FILE — server backend (libsodium + gcrypt + libblake3 FFI),
;;;     RFC 9421 request signing (server-only), KERIA body builders that
;;;     read live AID state from (playnet keri bridge), and srfi-19
;;;     timestamping. Re-exports the portable surface so existing
;;;     callers see no API change.
;;;
;;; Parity: this file mirrors signify-ts 0.3.0 (commit ebc0f0f), specifically
;;;   src/keri/core/{salter,eventing,indexing}.ts
;;;   src/keri/end/authing.ts
;;;   src/keri/app/clienting.ts
;;; When signify-ts moves, port the change here; see
;;;   docs/keri/SIGNIFY-PARITY.md
;;; for the drift-management process + the file-to-file mapping table.

(define-module (playnet keri signify)
  #:use-module (ice-9 format)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (ice-9 match)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-19)
  #:use-module (system foreign)
  #:use-module (system foreign-library)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 ftw)
  #:use-module (gcrypt mac)
  #:use-module (json)
  #:use-module ((goblins utils crypto)
                #:select (verify bytevector->crypto-public-key))
  #:use-module ((playnet keri cesr) #:select (cesr-bytes->qb64 cesr-qb64->bytes
                                              b64url-encode b64url-decode
                                              bytevector-append))
  #:use-module ((playnet keri crypto-primitives)
                #:select (set-keri-crypto-backend!
                          make-ed25519-keypair
                          ed25519-keypair?
                          ed25519-keypair-public
                          ed25519-keypair-secret
                          ed25519-keypair-backend-data))
  #:use-module ((playnet keri signify-portable)
                #:select (hkdf-extract hkdf-expand hkdf
                          bran->seed
                          bran->signing-keypair
                          bran->next-keypair
                          bran->rotation-keypair
                          rotation-info-string
                          seed->ed25519-keypair
                          controller->aid-signing-keypair
                          controller->aid-next-keypair
                          public-key->aid-prefix
                          next-key-digest
                          said-of
                          saidify
                          saidify-document
                          saidify-schema
                          saidify-block
                          build-icp
                          build-rot
                          event-sn
                          sign-bytes
                          sign-event
                          sign-event/indexed
                          cesr-pathed-group
                          %ipex-path-acdc
                          %ipex-path-iss
                          %ipex-path-anc
                          %saidplaceholder
                          %version-placeholder
                          %acdc-version-placeholder
                          scm->json-canonical))
  #:re-export (;; HKDF
               hkdf-extract hkdf-expand hkdf
               ;; Ed25519 keypair record (re-exported from primitives)
               ed25519-keypair?
               ed25519-keypair-public
               ed25519-keypair-secret
               ;; Bran → keypairs
               seed->ed25519-keypair
               bran->signing-keypair
               bran->next-keypair
               bran->rotation-keypair
               rotation-info-string
               ;; Per-AID derivation
               controller->aid-signing-keypair
               controller->aid-next-keypair
               ;; AID + key digest
               public-key->aid-prefix
               next-key-digest
               ;; SAID + saidify
               said-of
               saidify
               saidify-document
               saidify-schema
               saidify-block
               ;; Inception
               build-icp
               ;; Rotation
               build-rot
               ;; Signing
               sign-bytes
               sign-event
               sign-event/indexed
               ;; IPEX grant embeds (pathed-material attachments)
               cesr-pathed-group
               %ipex-path-acdc
               %ipex-path-iss
               %ipex-path-anc
               ;; Constants
               %saidplaceholder
               %version-placeholder
               %acdc-version-placeholder)
  #:export (;; /boot
            boot-body
            ;; RFC 9421
            signature-base
            signify-timestamp
            sign-request
            ;; AID state helpers
            %aid-next-sn
            ;; KERI event builders (server uses; need bridge state)
            build-vcp
            build-ixn
            build-acdc
            build-iss
            build-rpy
            build-exn
            ;; Signify body builders for KERIA endpoints
            identifier-body
            registry-body
            credential-body
            rotation-body
            end-role-body
            exchange-body
            scope-exchange-body
            group-body
            ;; Context
            make-signify-context
            signify-context?
            signify-context-keypair
            signify-context-next-keypair
            signify-context-aid
            signify-context-agent-aid
            set-signify-context-agent-aid!
            ;; Compatibility shim — old name for ed25519-keypair-secret
            ed25519-keypair-expanded-sk))

;;; ── Server crypto backend: libsodium + gcrypt + libblake3 ───────────────────

;; Robust FFI load: try the unversioned name (the libfoo.so dev symlink, present only with -dev),
;; then fall back to the highest versioned soname (libfoo.so.N) on the search/standard lib dirs — so a
;; system with only the RUNTIME library (libsodium.so.23, no dev symlink) still loads. Returns #f if the
;; library is genuinely absent (so callers can degrade, rather than crash the whole module at load).
(define (load-foreign-library/resilient base search-path)
  (or (false-if-exception (load-foreign-library base #:search-path search-path))
      (let ((pat (string-append base ".so.")))
        (let loop ((dirs (append search-path
                                 '("/lib/x86_64-linux-gnu" "/usr/lib/x86_64-linux-gnu"
                                   "/usr/lib" "/lib" "/usr/local/lib"))))
          (and (pair? dirs)
               (let* ((d (car dirs))
                      (hit (and (file-exists? d)
                                (let ((es (false-if-exception (scandir d))))
                                  (and es (find (lambda (f) (and (> (string-length f) (string-length pat))
                                                                 (string=? (substring f 0 (string-length pat)) pat)))
                                                (sort es string>?)))))))   ; highest version first
                 (if hit (false-if-exception (load-foreign-library (string-append d "/" hit)))
                     (loop (cdr dirs)))))))))

(define %sodium-search-path
  (filter file-exists?
          (filter-map (lambda (env) (and=> (getenv env) (lambda (p) (string-append p "/lib"))))
                      '("GUIX_ENVIRONMENT" "HOME"))))
(define %libsodium (load-foreign-library/resilient "libsodium" %sodium-search-path))

(define %crypto-sign-seed-keypair
  (foreign-library-function %libsodium "crypto_sign_seed_keypair"
                            #:return-type int
                            #:arg-types '(* * *)))

(define %crypto-sign-detached
  (foreign-library-function %libsodium "crypto_sign_detached"
                            #:return-type int
                            #:arg-types (list '* '* '* uint64 '*)))

(define (%server-ed25519-from-seed seed)
  "libsodium crypto_sign_seed_keypair: seed → keypair with 64-byte SK."
  (let ((pk (make-bytevector 32 0))
        (sk (make-bytevector 64 0)))
    (let ((rc (%crypto-sign-seed-keypair
               (bytevector->pointer pk)
               (bytevector->pointer sk)
               (bytevector->pointer seed))))
      (unless (zero? rc)
        (error "crypto_sign_seed_keypair failed" rc)))
    (make-ed25519-keypair pk seed sk)))

(define (%server-ed25519-sign keypair message)
  "libsodium crypto_sign_detached. Reads the 64-byte expanded SK from
   the keypair's backend-data slot."
  (let* ((sig (make-bytevector 64 0))
         (sk  (ed25519-keypair-backend-data keypair))
         (rc  (%crypto-sign-detached
               (bytevector->pointer sig)
               %null-pointer
               (bytevector->pointer message)
               (bytevector-length message)
               (bytevector->pointer sk))))
    (unless (zero? rc)
      (error "crypto_sign_detached failed" rc))
    sig))

(define %hmac-sha256-algo (lookup-mac-algorithm 'hmac-sha256))

(define (%server-hmac-sha256 key data)
  (sign-data key data #:algorithm %hmac-sha256-algo))

;; Plain SHA-256 (gcrypt). Reticulum hashes (identity/destination) are
;; truncated SHA-256 — the AID↔mesh binding verifier needs it.
(define %server-sha256
  (let ((fn #f))
    (lambda (bv)
      (unless fn
        (set! fn (module-ref (resolve-interface '(gcrypt hash)) 'sha256)))
      (fn bv))))

;; Lazy reference to (playnet keri blake3) so server bundles that don't
;; load this file's tests don't pay the libblake3 dlopen cost upfront.
(define %server-blake3-256
  (let ((fn #f))
    (lambda (bv)
      (unless fn
        (set! fn (module-ref (resolve-interface '(playnet keri blake3))
                             'blake3-256)))
      (fn bv))))

(define (%server-ed25519-verify pubkey-bv message-bv sig-bv)
  "Goblins-crypto-backed Ed25519 verify. Catches gnutls-error so
   malformed sigs return #f rather than raising — matching what
   noble-ed25519's verify does on the browser side."
  (catch #t
    (lambda ()
      (verify sig-bv message-bv
              (bytevector->crypto-public-key pubkey-bv)))
    (lambda _ #f)))

(define (%server-random-bytes n)
  "Read N cryptographically-strong random bytes from /dev/urandom.
   Server-only; the browser backend installs a getRandomValues-based
   implementation."
  (let ((bv   (make-bytevector n 0))
        (port (open-file "/dev/urandom" "rb")))
    (get-bytevector-n! port bv 0 n)
    (close-port port)
    bv))

;; Install at module load. Browser bundles override this by calling
;; set-keri-crypto-backend! again with FFI-backed implementations.
(set-keri-crypto-backend!
 #:blake3-256        %server-blake3-256
 #:sha256            %server-sha256
 #:hmac-sha256       %server-hmac-sha256
 #:ed25519-from-seed %server-ed25519-from-seed
 #:ed25519-sign      %server-ed25519-sign
 #:ed25519-verify    %server-ed25519-verify
 #:random-bytes      %server-random-bytes)

;;; ── Compatibility shim ──────────────────────────────────────────────────────

(define ed25519-keypair-expanded-sk ed25519-keypair-backend-data)

;;; ── Signify context record ──────────────────────────────────────────────────

(define-record-type <signify-context>
  (%make-signify-context keypair next-keypair aid icp-json icp-alist agent-aid)
  signify-context?
  (keypair       signify-context-keypair)
  (next-keypair  signify-context-next-keypair)
  (aid           signify-context-aid)
  (icp-json      signify-context-icp-json)
  (icp-alist     signify-context-icp-alist)
  (agent-aid     signify-context-agent-aid set-signify-context-agent-aid!))

;;; ── /boot body ──────────────────────────────────────────────────────────────

(define* (boot-body ctx #:key (stem "signify:controller") (pidx 0) (tier "low"))
  "Build the JSON body that signify-ts POSTs to /boot.

   Shape (per signify-ts src/keri/app/clienting.ts::Controller.boot):
     { icp, sig, stem, pidx, tier }"
  (let* ((kp    (signify-context-keypair ctx))
         (json  (signify-context-icp-json ctx))
         (alist (signify-context-icp-alist ctx)))
    (list (cons "icp"  alist)
          (cons "sig"  (sign-event json kp))
          (cons "stem" stem)
          (cons "pidx" pidx)
          (cons "tier" tier))))

;;; ── POST /identifiers body ──────────────────────────────────────────────────

(define* (identifier-body name ctx
                          #:key
                          (toad 0)
                          (witnesses '())
                          (pidx 1))
  "Build the JSON body for POST /identifiers (create a new AID)."
  (let* ((ctrl-kp (signify-context-keypair ctx))
         (kp      (controller->aid-signing-keypair ctrl-kp name))
         (nkp     (controller->aid-next-keypair ctrl-kp name))
         (kq      (public-key->aid-prefix (ed25519-keypair-public kp)))
         (nq      (next-key-digest (ed25519-keypair-public nkp)))
         (salt-bv (hkdf #:ikm (ed25519-keypair-secret ctrl-kp)
                        #:info (string->utf8
                                (string-append "signify:salt:" name))
                        #:length 24))
         (sxlt    (cesr-bytes->qb64 "0A" salt-bv)))
    (call-with-values
      (lambda ()
        (build-icp #:keys (list kq) #:nkeys (list nq)
                   #:wits witnesses #:toad toad))
      (lambda (icp-json _said icp-alist)
        (values
         (list (cons "name"  name)
               (cons "icp"   icp-alist)
               (cons "sigs"  (vector (sign-event icp-json kp)))
               (cons "salty" (list (cons "stem" (string-append "signify:aid:" name))
                                   (cons "tier" "low")
                                   (cons "sxlt" sxlt)
                                   (cons "pidx" pidx)
                                   (cons "kidx" 0)
                                   (cons "icodes" (vector "A"))
                                   (cons "ncodes" (vector "A"))
                                   (cons "dcode"  "E")
                                   (cons "transferable" #t))))
         kp)))))

;;; ── Group inception body ────────────────────────────────────────────────────

(define* (group-body ctx group-name member-aid-name member-prefixes keys ndigs
                     #:key
                     (signing-threshold 1)
                     (rotation-threshold 1)
                     (toad 0)
                     (witnesses '()))
  "Build {name, icp, sigs, group, smids, rmids, salty} for k-of-n group inception."
  (let* ((ctrl-kp  (signify-context-keypair ctx))
         (member-kp (controller->aid-signing-keypair ctrl-kp member-aid-name))
         (bridge   (resolve-interface '(playnet keri bridge)))
         (get-aid  (module-ref bridge 'keri-get-aid))
         (mhab-pre (assoc-ref (get-aid member-aid-name) "prefix"))
         (signer-idx (or (list-index (lambda (p) (equal? p mhab-pre))
                                     member-prefixes)
                         (error "group-body: member's prefix not in member-prefixes"
                                mhab-pre member-prefixes))))
    (call-with-values
      (lambda ()
        (build-icp #:keys keys #:nkeys ndigs
                   #:wits witnesses #:toad toad
                   #:isith signing-threshold
                   #:nsith rotation-threshold))
      (lambda (icp-json _said icp-alist)
        (list (cons "name"  group-name)
              (cons "icp"   icp-alist)
              (cons "sigs"  (vector (sign-event/indexed icp-json member-kp signer-idx)))
              (cons "group" (list (cons "mhab" (list (cons "prefix" mhab-pre)))
                                  (cons "keys"  (list->vector keys))
                                  (cons "ndigs" (list->vector ndigs))))
              (cons "smids" (list->vector member-prefixes))
              (cons "rmids" (list->vector member-prefixes))
              (cons "salty" (list (cons "stem" (string-append "signify:aid:" group-name))
                                  (cons "tier" "low")
                                  (cons "pidx" 1)
                                  (cons "kidx" 0)
                                  (cons "icodes" (list->vector
                                                   (make-list (length keys) "A")))
                                  (cons "ncodes" (list->vector
                                                   (make-list (length keys) "A")))
                                  (cons "dcode"  "E")
                                  (cons "transferable" #t))))))))

;;; ── VCP / IXN event builders ────────────────────────────────────────────────

(define* (build-vcp issuer-prefix #:key (nonce #f))
  "Build a KERI VCP (Verifiable Credential Pool inception) event.
   Fields: v t d i ii s c bt b n.  Self-addressing (d == i)."
  (let ((n (or nonce
               (cesr-bytes->qb64
                "0A"
                (hkdf #:ikm (string->utf8 issuer-prefix)
                      #:info (string->utf8 "signify:registry:nonce")
                      #:length 24)))))
    (saidify (list (cons "v"  %version-placeholder)
                   (cons "t"  "vcp")
                   (cons "d"  %saidplaceholder)
                   (cons "i"  %saidplaceholder)
                   (cons "ii" issuer-prefix)
                   (cons "s"  "0")
                   (cons "c"  (vector "NB"))
                   (cons "bt" "0")
                   (cons "b"  #())
                   (cons "n"  n)))))

(define* (build-ixn aid-prefix prior-said data #:key (sn 1))
  "Build a KERI IXN (interaction) event."
  (saidify (list (cons "v" %version-placeholder)
                 (cons "t" "ixn")
                 (cons "d" %saidplaceholder)
                 (cons "i" aid-prefix)
                 (cons "s" (number->string sn 16))
                 (cons "p" prior-said)
                 (cons "a" data))))

(define (%aid-next-sn state aid-data)
  "Extract the current sn from state (preferred) or aid-data, and return
   sn+1. Falls back to 1 when neither carries an `s` field. Delegates
   the string/number/missing trichotomy to signify-portable's event-sn,
   which returns -1 on parse failure → max with 0 turns that into 1."
  (+ 1 (max 0 (event-sn (or state aid-data)))))

(define* (registry-body ctx aid-name registry-name)
  "Build {name, vcp, ixn, sigs} for POST /identifiers/{name}/registries."
  (let* ((ctrl-kp   (signify-context-keypair ctx))
         (aid-kp    (controller->aid-signing-keypair ctrl-kp aid-name))
         (bridge    (resolve-interface '(playnet keri bridge)))
         (get-aid   (module-ref bridge 'keri-get-aid))
         (aid-data  (get-aid aid-name))
         (prefix    (assoc-ref aid-data "prefix"))
         (state     (assoc-ref aid-data "state"))
         (last-said (or (and state (assoc-ref state "d"))
                        (assoc-ref aid-data "d")))
         (next-sn   (%aid-next-sn state aid-data)))
    (call-with-values
      (lambda () (build-vcp prefix))
      (lambda (_vcp-json vcp-said vcp-alist)
        (let ((anchor (vector (list (cons "i" vcp-said)
                                    (cons "s" "0")
                                    (cons "d" vcp-said)))))
          (call-with-values
            (lambda () (build-ixn prefix last-said anchor #:sn next-sn))
            (lambda (ixn-json _ixn-said ixn-alist)
              (list (cons "name" registry-name)
                    (cons "vcp"  vcp-alist)
                    (cons "ixn"  ixn-alist)
                    (cons "sigs" (vector (sign-event ixn-json aid-kp)))))))))))

;;; ── ACDC + ISS + credential body ────────────────────────────────────────────

(define (%edge-spec->json-pairs edge-spec)
  "Convert a governance edge-spec alist (n/o/s keys as symbols) into
   JSON-string-keyed pairs."
  (filter
    (lambda (p) (cdr p))
    (list (cons "n" (assq-ref edge-spec 'n))
          (cons "s" (assq-ref edge-spec 's))
          (cons "o" (let ((op (assq-ref edge-spec 'o)))
                      (and op (if (symbol? op) (symbol->string op) op)))))))

(define (%build-edges-block edges)
  "Given an alist of (edge-name-symbol . edge-spec), build the ACDC `e`
   block with its own SAID."
  (cond
    ((or (not edges) (null? edges)) #f)
    (else
     (let ((named-edges (map (lambda (p)
                               (cons (symbol->string (car p))
                                     (%edge-spec->json-pairs (cdr p))))
                             edges)))
       (saidify-block (cons (cons "d" %saidplaceholder) named-edges))))))

(define* (build-acdc issuer-prefix regk schema-said holder-aid claims
                     #:key (edges '()))
  "Build an ACDC credential. Returns (values json-string said alist).

   The outer envelope (v t d i ri s a [e]) goes through `saidify` —
   the same SAID pipeline KEL events use. saidify-document now derives
   the protocol prefix from the input v field, so passing
   %acdc-version-placeholder yields a correctly-rewritten ACDC10JSON
   version string (sweep 4-cont fixed the prior hardcoded-KERI bug).
   The inner attribute block `a` is SAID-ed separately because ACDC §4
   requires it to carry its own self-addressing digest in `a.d`."
  (let* ((dt      (signify-timestamp))
         (a-final (saidify-block
                   (append `(("d" . ,%saidplaceholder)
                             ("i" . ,holder-aid)
                             ("dt" . ,dt))
                           claims)))
         (e-final (%build-edges-block edges))
         (raw     (append (list (cons "v"  %acdc-version-placeholder)
                                (cons "d"  %saidplaceholder)
                                (cons "i"  issuer-prefix)
                                (cons "ri" regk)
                                (cons "s"  schema-said)
                                (cons "a"  a-final))
                          (if e-final (list (cons "e" e-final)) '()))))
    (saidify raw)))

(define (build-iss credential-said regk)
  "Build a TEL issuance event. Fields: v t d i s ri dt."
  (saidify (list (cons "v"  %version-placeholder)
                 (cons "t"  "iss")
                 (cons "d"  %saidplaceholder)
                 (cons "i"  credential-said)
                 (cons "s"  "0")
                 (cons "ri" regk)
                 (cons "dt" (signify-timestamp)))))

(define* (credential-body ctx aid-name
                          #:key holder-aid schema-said registry-id claims
                                (edges '()))
  "Build {acdc, iss, ixn, sigs} for POST /identifiers/{name}/credentials."
  (let* ((ctrl-kp  (signify-context-keypair ctx))
         (aid-kp   (controller->aid-signing-keypair ctrl-kp aid-name))
         (bridge   (resolve-interface '(playnet keri bridge)))
         (get-aid  (module-ref bridge 'keri-get-aid))
         (aid-data (get-aid aid-name))
         (prefix   (assoc-ref aid-data "prefix"))
         (state    (assoc-ref aid-data "state"))
         (last-d   (or (and state (assoc-ref state "d"))
                       (assoc-ref aid-data "d")))
         (next-sn  (%aid-next-sn state aid-data)))
    (call-with-values
      (lambda () (build-acdc prefix registry-id schema-said holder-aid
                             (or claims '()) #:edges edges))
      (lambda (_acdc-json acdc-said acdc-alist)
        (call-with-values
          (lambda () (build-iss acdc-said registry-id))
          (lambda (_iss-json iss-said iss-alist)
            (let ((anchor (vector (list (cons "i" acdc-said)
                                       (cons "s" "0")
                                       (cons "d" iss-said)))))
              (call-with-values
                (lambda () (build-ixn prefix last-d anchor #:sn next-sn))
                (lambda (ixn-json _ixn-said ixn-alist)
                  (list (cons "acdc" acdc-alist)
                        (cons "iss"  iss-alist)
                        (cons "ixn"  ixn-alist)
                        (cons "sigs" (vector (sign-event ixn-json aid-kp)))))))))))))

;;; ── ROT (rotation) ──────────────────────────────────────────────────────────
;;; build-rot lives in (playnet keri signify-portable) and is re-exported.
;;; The server-side body builder below adds bridge-context lookup.

(define* (rotation-body ctx aid-name
                        #:key (cuts '()) (adds '()))
  "Build {rot, sigs, salty} for POST /identifiers/{name}/events."
  (let* ((ctrl-kp  (signify-context-keypair ctx))
         (next-kp  (controller->aid-next-keypair ctrl-kp aid-name))
         (next-nkp (seed->ed25519-keypair
                    (hkdf #:ikm (ed25519-keypair-secret ctrl-kp)
                          #:info (string->utf8 (string-append "signify:aid:" aid-name ":n1"))
                          #:length 32)))
         (bridge   (resolve-interface '(playnet keri bridge)))
         (get-aid  (module-ref bridge 'keri-get-aid))
         (aid-data (get-aid aid-name))
         (prefix   (assoc-ref aid-data "prefix"))
         (state    (assoc-ref aid-data "state"))
         (last-d   (or (and state (assoc-ref state "d")) (assoc-ref aid-data "d")))
         (next-sn  (%aid-next-sn state aid-data))
         (kq       (public-key->aid-prefix (ed25519-keypair-public next-kp)))
         (nq       (next-key-digest (ed25519-keypair-public next-nkp)))
         (salt-bv  (hkdf #:ikm (ed25519-keypair-secret ctrl-kp)
                         #:info (string->utf8 (string-append "signify:salt:" aid-name))
                         #:length 24))
         (sxlt     (cesr-bytes->qb64 "0A" salt-bv)))
    (call-with-values
      (lambda ()
        (build-rot prefix last-d
                   #:keys (list kq) #:nkeys (list nq)
                   #:sn next-sn #:cuts cuts #:adds adds))
      (lambda (json _said alist)
        ;; A rotation is signed with the NEW current key — i.e. next-kp, whose
        ;; public key is what `k` now lists (kq). Signing with the prior icp
        ;; key (aid-kp) makes KERIA reject the event: "No verified signatures"
        ;; (the sig is checked against the rotated-to keys in `k`).
        (list (cons "rot"   alist)
              (cons "sigs"  (vector (sign-event json next-kp)))
              (cons "salty" (list (cons "stem" (string-append "signify:aid:" aid-name))
                                  (cons "tier" "low")
                                  (cons "sxlt" sxlt)
                                  (cons "pidx" 1)
                                  (cons "kidx" 1)
                                  (cons "icodes" (vector "A"))
                                  (cons "ncodes" (vector "A"))
                                  (cons "dcode"  "E")
                                  (cons "transferable" #t))))))))

;;; ── RPY / EXN event builders ────────────────────────────────────────────────

(define* (build-rpy route attrs #:key (dt #f))
  "Build a KERI reply (rpy) event. Fields: v t d dt r a."
  (saidify (list (cons "v"  %version-placeholder)
                 (cons "t"  "rpy")
                 (cons "d"  %saidplaceholder)
                 (cons "dt" (or dt (signify-timestamp)))
                 (cons "r"  route)
                 (cons "a"  attrs))))

(define (end-role-body ctx aid-name role eid)
  "Build {rpy, sigs} for POST /identifiers/{name}/endroles."
  (let* ((ctrl-kp (signify-context-keypair ctx))
         (aid-kp  (controller->aid-signing-keypair ctrl-kp aid-name))
         (bridge  (resolve-interface '(playnet keri bridge)))
         (get-aid (module-ref bridge 'keri-get-aid))
         (prefix  (assoc-ref (get-aid aid-name) "prefix"))
         (attrs   (list (cons "cid" prefix) (cons "role" role) (cons "eid" eid))))
    (call-with-values
      (lambda () (build-rpy "/end/role/add" attrs))
      (lambda (json _said alist)
        (list (cons "rpy"  alist)
              (cons "sigs" (vector (sign-event json aid-kp))))))))

(define* (build-exn sender-prefix route
                    #:key (recipient "") (payload '()) (embeds '())
                    (prior "") (dt #f))
  "Build a KERI exchange (exn) event."
  (let ((attrs (if (string-null? recipient)
                   payload
                   (cons (cons "i" recipient) payload))))
    (saidify (list (cons "v"  %version-placeholder)
                   (cons "t"  "exn")
                   (cons "d"  %saidplaceholder)
                   (cons "i"  sender-prefix)
                   (cons "rp" recipient)
                   (cons "p"  prior)
                   (cons "dt" (or dt (signify-timestamp)))
                   (cons "r"  route)
                   (cons "q"  '())
                   (cons "a"  attrs)
                   (cons "e"  embeds)))))

(define* (exchange-body ctx aid-name route
                        #:key (recipient "") (payload '()) (embeds '())
                        (atc "") (prior "") (rec '()))
  "Build {exn, sigs, atc, rec} for POST /identifiers/{name}/ipex/{route}.
   ATC is the exn's pathed-material attachment string — one -L group per
   embed (cesr-pathed-group), \"\" when the exn embeds nothing. PRIOR is
   the exn `p` field — the SAID of the exchange message this one answers
   (admit → its grant, agree → its offer); anchoring the chain there is
   what lets commitments survive key-state changes (IPEX.md §3)."
  (let* ((ctrl-kp (signify-context-keypair ctx))
         (aid-kp  (controller->aid-signing-keypair ctrl-kp aid-name))
         (bridge  (resolve-interface '(playnet keri bridge)))
         (get-aid (module-ref bridge 'keri-get-aid))
         (prefix  (assoc-ref (get-aid aid-name) "prefix")))
    (call-with-values
      (lambda ()
        (build-exn prefix route
                   #:recipient recipient #:payload payload
                   #:embeds embeds #:prior prior))
      (lambda (json _said alist)
        (list (cons "exn"  alist)
              (cons "sigs" (vector (sign-event json aid-kp)))
              (cons "atc"  atc)
              (cons "rec"  (list->vector rec)))))))

(define* (scope-exchange-body aid-prefix aid-keypair route
                              #:key (recipient "") (payload '())
                              (embeds '()) (atc "") (prior "") (rec '()))
  "Build {exn, sigs, atc, rec} for an exchange signed by a scope's own
   keypair, bypassing the signify controller. Used when the AID is
   managed by playnet's Scheme stack (governance-create-scope-aid!),
   not by signify-ts. Counterpart of `exchange-body`.

   AID-PREFIX is the scope's transferable AID (the `i` field of the
   resulting exn). AID-KEYPAIR is the ed25519-keypair? holding the
   current signing key — typically derived via
   `(bran->signing-keypair scope-bran-hex)`.

   Returns the body alist suitable for POST to KERIA's `/exchanges`
   endpoint via `keri-submit-scope-exchange`."
  (call-with-values
    (lambda ()
      (build-exn aid-prefix route
                 #:recipient recipient #:payload payload
                 #:embeds embeds #:prior prior))
    (lambda (json _said alist)
      (list (cons "exn"  alist)
            (cons "sigs" (vector (sign-event json aid-keypair)))
            (cons "atc"  atc)
            (cons "rec"  (list->vector rec))))))

;;; ── RFC 9421 HTTP Message Signatures (server-only) ──────────────────────────

(define %covered-components
  '("Signify-Resource" "@method" "@path" "Signify-Timestamp"))

(define (signify-timestamp)
  "ISO-8601 UTC timestamp with microsecond precision and +00:00 suffix.
   Server-only: depends on (srfi srfi-19)."
  (let* ((d  (current-date 0))
         (s  (date->string d "~Y-~m-~dT~H:~M:~S"))
         (ns (date->string d "~N"))
         (us (substring (string-append ns "000000000") 0 6)))
    (string-append s "." us "+00:00")))

(define (params-fields-inner quote?)
  (let ((parts (if quote?
                   (map (lambda (c) (string-append "\"" c "\""))
                        %covered-components)
                   %covered-components)))
    (string-append "(" (string-join parts " ") ")")))

(define (params-suffix created keyid)
  (format #f ";created=~a;keyid=~a;alg=ed25519" created keyid))

(define (signature-base method path resource timestamp created keyid)
  (let* ((method-str (if (symbol? method) (symbol->string method) method))
         (params     (string-append (params-fields-inner #f)
                                    (params-suffix created keyid)))
         (lines
          (list
           (format #f "\"signify-resource\": ~a" resource)
           (format #f "\"@method\": ~a" (string-upcase method-str))
           (format #f "\"@path\": ~a" path)
           (format #f "\"signify-timestamp\": ~a" timestamp)
           (format #f "\"@signature-params: ~a\"" params)))
         (joined (string-join lines "\n")))
    (string->utf8 joined)))

(define (sign-request ctx method path)
  "Produce the 4 Signify-auth headers for an outbound request."
  (let* ((aid       (signify-context-aid ctx))
         (kp        (signify-context-keypair ctx))
         (ts        (signify-timestamp))
         (created   (inexact->exact (floor (instant->unix (clock-now)))))   ; RFC 9421 `created` is unix seconds: the instant, at the boundary
         (base      (signature-base method path aid ts created aid))
         (sig-bv    (sign-bytes base kp))
         (sig-q64   (cesr-bytes->qb64 "0B" sig-bv))
         (input-val (string-append "signify="
                                   (params-fields-inner #t)
                                   (params-suffix created aid)))
         (sig-val   (string-append "indexed=\"?0\";signify=\"" sig-q64 "\"")))
    (list (cons 'Signify-Resource aid)
          (cons 'Signify-Timestamp ts)
          (cons 'Signature-Input input-val)
          (cons 'Signature sig-val))))

;;; ── make-signify-context ────────────────────────────────────────────────────

(define* (make-signify-context bran)
  "Derive a full signing context from the passcode."
  (let* ((kp   (bran->signing-keypair bran))
         (nkp  (bran->next-keypair bran))
         (kq   (public-key->aid-prefix (ed25519-keypair-public kp)))
         (nq   (next-key-digest (ed25519-keypair-public nkp))))
    (call-with-values
      (lambda () (build-icp #:keys (list kq) #:nkeys (list nq)))
      (lambda (icp-json said icp-alist)
        (%make-signify-context kp nkp said icp-json icp-alist #f)))))
