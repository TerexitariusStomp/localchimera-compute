;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/keri/signify-portable.scm — Hoot-portable Signify core
;;;
;;; The pure-Scheme subset of signify.scm: HKDF, bran→keypair derivation,
;;; AID prefix encoding, SAID computation, ICP construction, event signing.
;;; Compiles unchanged under Hoot/WASM provided a crypto backend is
;;; installed via (playnet keri crypto-primitives).
;;;
;;; Server-only concerns (libsodium FFI, gcrypt, srfi-19 timestamps,
;;; HTTP request signing, KERIA body builders that read from
;;; (playnet keri bridge)) live in signify.scm and import from here.
;;;
;;; The exported surface here is consumed both server-side (by the
;;; existing signify.scm wrappers) and browser-side (by repl.scm).
;;;
;;; Parity: mirrors signify-ts 0.3.0 (commit ebc0f0f), specifically
;;;   src/keri/core/salter.ts    — HKDF derivation paths, salt info-strings
;;;   src/keri/core/eventing.ts  — build-icp / build-rot / build-ixn / build-exn
;;;   src/keri/core/indexing.ts  — sign-event / sign-event/indexed
;;;   src/keri/core/coring.ts    — cesr-bytes->qb64, derivation codes
;;; The salt info-strings ("signify:controller", "signify:next",
;;; "signify:aid:<name>:k0") MUST match signify-ts byte-for-byte —
;;; any drift here breaks key derivation cross-implementation.
;;; See docs/keri/SIGNIFY-PARITY.md for the drift-management process.

(define-module (playnet keri signify-portable)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils json-portable) #:select (scm->json-canonical json-read-ordered))
  #:use-module ((playnet keri cesr)
                #:select (cesr-bytes->qb64 cesr-qb64->bytes
                          b64url-encode b64url-decode b64url-char->val
                          bytevector-append
                          %b64url-alphabet))
  #:use-module ((playnet keri crypto-primitives)
                #:select (<ed25519-keypair>
                          make-ed25519-keypair
                          ed25519-keypair?
                          ed25519-keypair-public
                          ed25519-keypair-secret
                          ed25519-keypair-backend-data
                          keri-crypto-blake3-256
                          keri-crypto-hmac-sha256
                          keri-crypto-ed25519-from-seed
                          keri-crypto-ed25519-sign))
  #:re-export (<ed25519-keypair>
               make-ed25519-keypair
               ed25519-keypair?
               ed25519-keypair-public
               ed25519-keypair-secret
               ed25519-keypair-backend-data
               ;; JSON — lifted to (playnet utils json-portable)
               scm->json-canonical
               json-read-ordered)
  #:export (;; Rotation (portable subset of build-rot from signify.scm)
            build-rot
            ;; Interaction (anchors ACDC SAIDs into the KEL — §4.6)
            build-ixn
            ;; Indexed key derivation for rotation chains (browser-friendly)
            bran->rotation-keypair
            rotation-info-string
            ;; Event SAID rederivation (verification primitives live in
            ;; (playnet keri citizen-sig), which routes through the
            ;; keri-crypto backend — same path on server and browser).
            event-stripped-for-rederivation
            recompute-event-said
            array-first
            event-first-key
            event-first-next-digest
            event-sn
            ;; CESR text-stream OOBI emission
            cesr-stream-event
            cesr-stream-kel
            cesr-idx-sigs-group
            cesr-stream-parse
            keri-version-size
            ;; OOBI endpoint replies (OKEA: /end/role/add + /loc/scheme)
            build-reply
            build-end-role-reply
            build-loc-scheme-reply
            cesr-stream-reply
            cesr-stream-reply-nontrans
            ;; IPEX grant embeds (pathed-material attachments)
            cesr-pathed-group
            %ipex-path-acdc
            %ipex-path-iss
            %ipex-path-anc
            oobi-endpoint-replies
            oobi-endpoint-replies-for-icp
            oobi-endpoint-replies-for-rot
            ;; HKDF
            hkdf-extract
            hkdf-expand
            hkdf
            ;; Bran → keypairs
            bran->seed
            bran->signing-keypair
            bran->next-keypair
            bran->reticulum-seed
            bran->blob-key
            seed->ed25519-keypair
            ;; Per-AID derivation
            controller->aid-signing-keypair
            controller->aid-next-keypair
            ;; AID + key digest
            public-key->aid-prefix
            next-key-digest
            ;; SAID
            said-of
            ;; SAIDify
            saidify
            saidify-document
            saidify-schema
            saidify-block
            ;; ICP
            build-icp
            ;; Event signing
            sign-bytes
            sign-event
            sign-event/indexed
            ;; Constants reused by signify.scm
            %saidplaceholder
            %version-placeholder
            %acdc-version-placeholder))

;;; ── HKDF-SHA256 (RFC 5869) ──────────────────────────────────────────────────

(define %hash-len 32)

(define* (hkdf-extract #:optional (salt #f) (ikm #vu8()))
  "HKDF-Extract: compress IKM into a 32-byte PRK. SALT defaults to a
   32-byte zero string when #f or empty (RFC 5869 §2.2)."
  (let ((effective-salt
         (if (or (not salt)
                 (and (bytevector? salt)
                      (zero? (bytevector-length salt))))
             (make-bytevector %hash-len 0)
             salt)))
    (keri-crypto-hmac-sha256 effective-salt ikm)))

(define* (hkdf-expand prk #:optional (info #vu8()) (length 32))
  "HKDF-Expand: stretch PRK into LENGTH bytes of OKM."
  (when (> length (* 255 %hash-len))
    (error "hkdf-expand: requested length exceeds 255 * HashLen"))
  (let loop ((i 1) (prev #vu8()) (acc '()) (have 0))
    (if (>= have length)
        (let ((concat (apply bytevector-append (reverse acc))))
          (if (= (bytevector-length concat) length)
              concat
              (let ((trimmed (make-bytevector length 0)))
                (bytevector-copy! concat 0 trimmed 0 length)
                trimmed)))
        (let* ((counter (make-bytevector 1 i))
               (input   (bytevector-append prev info counter))
               (t-i     (keri-crypto-hmac-sha256 prk input)))
          (loop (+ i 1) t-i (cons t-i acc) (+ have %hash-len))))))

(define* (hkdf #:key (salt #f) (ikm #vu8()) (info #vu8()) (length 32))
  (hkdf-expand (hkdf-extract salt ikm) info length))

;;; ── Bran → keypairs ─────────────────────────────────────────────────────────
;;;
;;; signify-ts compatibility note: see the long comment in signify.scm.
;;; We use a constant info string per purpose; the AID won't match what
;;; `npx signify-ts` produces from the same passcode. KERIA accepts any
;;; valid self-signed icp.

(define %info-controller (string->utf8 "signify:controller"))
(define %info-next       (string->utf8 "signify:next"))

(define (bran->seed bran info)
  (hkdf #:ikm (string->utf8 bran) #:info info #:length 32))

(define (seed->ed25519-keypair seed)
  "Delegate to the installed crypto backend."
  (keri-crypto-ed25519-from-seed seed))

(define (bran->signing-keypair bran)
  (seed->ed25519-keypair (bran->seed bran %info-controller)))

(define (bran->next-keypair bran)
  (seed->ed25519-keypair (bran->seed bran %info-next)))

(define (bran->reticulum-seed bran aid)
  "Derive a 64-byte seed for Reticulum identity (32 X25519 + 32 Ed25519)
   from a persona's bran and AID. Stable across KERI key rotations
   because the AID prefix never changes. See RETICULUM-IDENTITIES.md."
  (hkdf #:ikm (string->utf8 bran)
        #:info (string->utf8 (string-append "playnet/reticulum/v1:" aid))
        #:length 64))

(define (bran->blob-key bran)
  "Derive the 32-byte AES key for at-rest blobs — the encrypted credential
   backup the gateway stores on our behalf (browser/lib/vault.js).

   Its own info-string, for two reasons. It must be independent of
   signing-key ROTATION, so pre-rotation never orphans a user's own
   backup; and it must be domain-separated from every other bran
   derivation here, so compromise of one never yields another.

   Deriving from the bran — rather than from browser state, or from the
   Reticulum identity — is what makes the backup recoverable from
   bran + AID and from NOTHING else: no second, weaker recovery path.
   See docs/legal/gdpr-analysis.md §\"Phase 1b\"."
  (hkdf #:ikm (string->utf8 bran)
        #:info (string->utf8 "playnet:blob:v1")
        #:length 32))

(define (controller->aid-signing-keypair ctrl-kp name)
  (seed->ed25519-keypair
   (hkdf #:ikm (ed25519-keypair-secret ctrl-kp)
         #:info (string->utf8 (string-append "signify:aid:" name ":k0"))
         #:length 32)))

(define (controller->aid-next-keypair ctrl-kp name)
  (seed->ed25519-keypair
   (hkdf #:ikm (ed25519-keypair-secret ctrl-kp)
         #:info (string->utf8 (string-append "signify:aid:" name ":n0"))
         #:length 32)))

;;; ── AID prefix + key-digest ─────────────────────────────────────────────────

(define (public-key->aid-prefix pub-bv)
  "CESR-encode a 32-byte Ed25519 public key as a transferable AID prefix
   (code \"D\")."
  (unless (and (bytevector? pub-bv) (= 32 (bytevector-length pub-bv)))
    (error "public-key->aid-prefix: need 32-byte bytevector"))
  (cesr-bytes->qb64 "D" pub-bv))

(define (next-key-digest pub-bv)
  "Next-key commitment digest for icp.n / rot.n — CESR code \"E\" qb64.

   KERI commits a NEXT key as the digest of its QB64 STRING — Diger over
   verfer.qb64b — not over the raw public-key bytes, and re-derives that same
   digest from the exposed qb64 key when the rotation lands. Hashing the raw
   bytes here passes inception (KERIA doesn't validate `n` at icp) but fails
   the prior-nsith digest check on the first rotation. So digest the qb64."
  (cesr-bytes->qb64 "E"
                    (keri-crypto-blake3-256
                     (string->utf8 (public-key->aid-prefix pub-bv)))))

(define (said-of payload-bv . args)
  "blake3-256 SAID. Default code \"E\"."
  (cesr-bytes->qb64 (if (null? args) "E" (car args))
                    (keri-crypto-blake3-256 payload-bv)))

;;; ── Saidify (shared SAID computation) ───────────────────────────────────────

(define %saidplaceholder       (make-string 44 #\#))
(define %version-placeholder   "KERI10JSON000000_")
(define %acdc-version-placeholder "ACDC10JSON000000_")

(define (hex6 n)
  (let ((s (number->string n 16)))
    (string-append (make-string (- 6 (string-length s)) #\0) s)))

(define* (string-find-substring s sub #:optional (start 0))
  "Plain index-of for SUB inside S, scanning from START. Returns the
   absolute index in S, or #f if not found. Hoot's (srfi srfi-13) is
   patchy; roll our own to avoid the dependency. The optional START
   argument lets callers (string-replace-all in particular) advance
   without allocating a fresh `(substring s start)` per iteration."
  (let* ((slen (string-length s))
         (sublen (string-length sub))
         (last (- slen sublen)))
    (let loop ((i start))
      (cond ((> i last) #f)
            ((string=? (substring s i (+ i sublen)) sub) i)
            (else (loop (+ i 1)))))))

(define (pad-size-field raw-bytes)
  "Patch the size placeholder inside a serialized event so v reads
   <PROTO>10JSON<hex6>_."
  (let* ((s   (utf8->string raw-bytes))
         (len (bytevector-length raw-bytes)))
    (let loop ((placeholders (list %version-placeholder %acdc-version-placeholder)))
      (if (null? placeholders)
          (error "pad-size-field: no version placeholder found")
          (let* ((ph  (car placeholders))
                 (idx (string-find-substring s ph)))
            (if idx
                (let* ((proto (substring ph 0 10))
                       (patched (string-append
                                 (substring s 0 idx)
                                 proto (hex6 len) "_"
                                 (substring s (+ idx (string-length ph))))))
                  (string->utf8 patched))
                (loop (cdr placeholders))))))))

(define (string-replace-all str from to)
  "Replace every occurrence of FROM in STR with TO. Single-pass —
   each call to `string-find-substring` resumes from after the
   previous match's replacement (via its #:start arg, so no
   `(substring str i)` allocation per iteration), and the result is
   built from a list of slices joined once at the end. Earlier this
   was a `replace-first` fixed-point loop, which scanned the full
   string K times and only stopped on string-equality convergence."
  (let ((from-len (string-length from))
        (str-len  (string-length str)))
    (let loop ((i 0) (parts '()))
      (let ((j (string-find-substring str from i)))
        (cond
         ((not j)
          (apply string-append
                 (reverse (cons (substring str i str-len) parts))))
         (else
          (loop (+ j from-len)
                (cons to (cons (substring str i j) parts)))))))))

(define* (saidify-document raw-alist #:key (size-patch? #t))
  "Compute and substitute SAID(s) for a KERI/ACDC document alist.
   Returns three values: final-json-string, SAID qb64, final-alist.

   The protocol prefix on the rewritten `v` field is derived from
   RAW-ALIST's incoming v value (via %protocol-of-version) so KERI
   events keep `KERI10JSON` and ACDCs keep `ACDC10JSON` — earlier
   the prefix was hardcoded to KERI10JSON, which silently corrupted
   ACDC SAID rederivation."
  (let* ((step1        (string->utf8 (scm->json-canonical raw-alist)))
         (pre-hash     (if size-patch? (pad-size-field step1) step1))
         (said         (said-of pre-hash "E"))
         (patched-str  (utf8->string pre-hash))
         (final-str    (string-replace-all patched-str %saidplaceholder said))
         (final-bv     (string->utf8 final-str))
         (in-v         (assoc-ref raw-alist "v"))
         (proto        (if (and (string? in-v) (>= (string-length in-v) 10))
                           (substring in-v 0 10)
                           "KERI10JSON"))
         (ver          (and size-patch?
                            (string-append proto
                                           (hex6 (bytevector-length final-bv)) "_")))
         (final-alist  (map (lambda (p)
                              (cond
                               ((and ver (string=? (car p) "v"))
                                (cons "v" ver))
                               ((equal? (cdr p) %saidplaceholder)
                                (cons (car p) said))
                               (else p)))
                            raw-alist)))
    (values final-str said final-alist)))

(define (saidify raw-alist)
  (saidify-document raw-alist #:size-patch? #t))

(define (saidify-schema raw-alist)
  (saidify-document raw-alist #:size-patch? #f))

(define (saidify-block raw-alist)
  "Compute and substitute the SAID for an inner sub-block (e.g. an
   ACDC `a` attribute block, or an `e` edges block). No `v` field, no
   size patch — just `d` replaced with blake3 over the canonical JSON.
   Returns the final alist directly (callers nearly always want the
   alist, not the multi-value wrapper)."
  (call-with-values (lambda () (saidify-schema raw-alist))
    (lambda (_json _said alist) alist)))

;;; ── Inception event ─────────────────────────────────────────────────────────

(define* (build-icp #:key
                    (keys '())  (nkeys '())  (wits '())
                    (toad 0)    (isith 1)    (nsith 1)
                    (anchors '()))
  "Build an icp event. Returns (values json-string said alist).

   ANCHORS — list of anchor seals to place in the inception event's
   `a` field. Each seal is an alist with KERI seal fields:
     digest seal:  ((d . SAID))
     event seal:   ((i . AID) (s . SEQ-HEX) (d . SAID))
   Seal objects are emitted in the order given. Used to gate the
   inception by predecessor-issued ratification ACDCs (see
   docs/governance/democracy-on-keri.md §4.3)."
  (saidify (list (cons "v"  %version-placeholder)
                 (cons "t"  "icp")
                 (cons "d"  %saidplaceholder)
                 (cons "i"  %saidplaceholder)
                 (cons "s"  "0")
                 (cons "kt" (number->string isith))
                 (cons "k"  (list->vector keys))
                 (cons "nt" (number->string nsith))
                 (cons "n"  (list->vector nkeys))
                 (cons "bt" (number->string toad))
                 (cons "b"  (list->vector wits))
                 (cons "c"  #())
                 (cons "a"  (list->vector anchors)))))

;;; ── Rotation event + indexed key derivation ────────────────────────────────
;;;
;;; A KERI rotation (rot) event commits a new signing key (revealed
;;; from the previous next-key digest) and a new next-key digest for
;;; the rotation after this one. Fields: v t d i s p kt k nt n bt br
;;; ba c a.
;;;
;;; To support arbitrary-depth rotation chains derived from a single
;;; bran, we parameterize the HKDF info string by rotation index N:
;;;
;;;   N=0 (signing at inception):   info = "signify:controller"  (kp_0)
;;;   N=1 (next at inception, signing at rot 1): "signify:next" (kp_1)
;;;   N=2 (next-after-rot-1):                    "signify:next-2" (kp_2)
;;;   N=3 (next-after-rot-2):                    "signify:next-3" (kp_3)
;;;   ...
;;;
;;; The labels for N=0 and N=1 match what bran->signing-keypair and
;;; bran->next-keypair already produce, so existing identities carry
;;; forward unchanged. For N>=2 we use the suffix "-N" to keep info
;;; bytes deterministic and easy to inspect.

(define (rotation-info-string n)
  "Return the bytevector info string for the keypair at rotation
   index N. N=0 is the signing key at inception; N=k means 'this
   keypair becomes the signing key at the k-th rotation event'."
  (cond
   ((= n 0) (string->utf8 "signify:controller"))
   ((= n 1) (string->utf8 "signify:next"))
   (else
    (string->utf8 (string-append "signify:next-" (number->string n))))))

(define (bran->rotation-keypair bran n)
  "Derive the keypair at rotation index N from the passcode."
  (seed->ed25519-keypair
   (hkdf #:ikm (string->utf8 bran)
         #:info (rotation-info-string n)
         #:length 32)))

(define* (build-rot aid-prefix prior-said
                    #:key (keys '()) (nkeys '())
                    (sn 1) (isith 1) (nsith 1) (toad 0)
                    (cuts '()) (adds '()) (anchors '()))
  "Build a KERI rotation (rot) event. Returns (values json-string said alist).
   AID-PREFIX stays fixed across rotations; PRIOR-SAID is the SAID of
   the immediately preceding KEL event (icp at sn=1, then chained).
   ANCHORS — list of seal alists (same shape as build-icp/build-ixn) —
   e.g. how a persona created before the playnet-reticulum-pub anchor
   retrofits its AID↔mesh binding: the next rotation seals the pubkey
   and verifiers read the LATEST anchor across the KEL."
  (saidify (list (cons "v"  %version-placeholder)
                 (cons "t"  "rot")
                 (cons "d"  %saidplaceholder)
                 (cons "i"  aid-prefix)
                 (cons "s"  (number->string sn 16))
                 (cons "p"  prior-said)
                 (cons "kt" (number->string isith))
                 (cons "k"  (list->vector keys))
                 (cons "nt" (number->string nsith))
                 (cons "n"  (list->vector nkeys))
                 (cons "bt" (number->string toad))
                 (cons "br" (list->vector cuts))
                 (cons "ba" (list->vector adds))
                 ;; NB: no `c` (config traits) — that field is establishment-
                 ;; inception-only (icp/dip). KERI's rot label set is
                 ;; [v t d i s p kt k nt n bt br ba a]; including `c` makes
                 ;; keripy reject the event with ExtraFieldError ['c'].
                 (cons "a"  (list->vector anchors)))))

(define* (build-ixn aid-prefix prior-said
                    #:key (sn 1) (anchors '()))
  "Build a KERI interaction (ixn) event. Returns (values json-string said alist).

   An interaction event anchors data into the KEL without rotating
   keys. Used by `(playnet scope keys)` to commit ballot opens,
   tally closes, and other ACDC issuance into a scope's KEL — see
   democracy-on-keri.md §4.6.

   ANCHORS — list of seal alists (`((d . SAID))` for digest seals,
   `((i . AID) (s . SEQ) (d . SAID))` for event seals). Same shape
   as `build-icp` `#:anchors`."
  (saidify (list (cons "v"  %version-placeholder)
                 (cons "t"  "ixn")
                 (cons "d"  %saidplaceholder)
                 (cons "i"  aid-prefix)
                 (cons "s"  (number->string sn 16))
                 (cons "p"  prior-said)
                 (cons "a"  (list->vector anchors)))))

;;; ── Ed25519 signing ─────────────────────────────────────────────────────────

;; The base64url alphabet — used here for the second char of
;; indexed-signature codes ("AA"…"A_") in sign-event/indexed and for
;; the 2-char ControllerIdxSigs counter (count->b64-2 below). The
;; canonical definition lives in (playnet keri cesr) which already
;; needed it for qb64 encoding; we just rebind the name locally so
;; the rest of this file reads cleanly.
(define %b64url-digits %b64url-alphabet)

(define (sign-bytes bv keypair)
  "Ed25519-sign BV with KEYPAIR. Returns the 64-byte signature."
  (keri-crypto-ed25519-sign keypair bv))

(define (sign-event event-json-str keypair)
  "Sign a serialized KERI event. Returns CESR qb64 with code \"AA\"
   (indexed single-signer Ed25519, index 0, rotation index 0)."
  (sign-event/indexed event-json-str keypair 0))

(define (sign-event/indexed event-json-str keypair index)
  "Sign and return indexed CESR qb64. INDEX in 0..63."
  (unless (and (exact-integer? index) (<= 0 index 63))
    (error "sign-event/indexed: index must be 0-63" index))
  (let* ((sig-bv   (sign-bytes (string->utf8 event-json-str) keypair))
         (idx-char (string-ref %b64url-digits index))
         (code     (string #\A idx-char)))
    (cesr-bytes->qb64 code sig-bv)))

;;; ── Event verification (paired with build-icp / build-rot) ──────────────────
;;;
;;; A KERI event coming over the wire arrives "concrete": its v field
;;; carries the actual byte length, its d (and i for icp) carry real
;;; SAIDs. To re-derive the SAID we must reverse those substitutions:
;;;
;;;   1. v   → %version-placeholder
;;;   2. d   → %saidplaceholder
;;;   3. i   → %saidplaceholder  (icp only — for rot, i stays as the AID)
;;;
;;; Then saidify-document recomputes the canonical SAID. The resulting
;;; SAID must equal the event's d field for the event to be self-consistent.
;;;
;;; Callers (e.g. signup-agent) wrap this with type/sn/p checks specific
;;; to the event kind. These primitives handle only the SAID and
;;; signature parts — the SAID/sig math is identical across icp/rot/ixn,
;;; only the surrounding event-shape rules differ.

(define (%protocol-of-version v)
  "Return the version-string placeholder matching V's protocol prefix.
   KERI events start with `KERI10JSON`, ACDCs with `ACDC10JSON`. If we
   can't tell, default to KERI10JSON (the legacy KEL-event behaviour)."
  (cond
   ((and (string? v) (>= (string-length v) 10)
         (string=? "ACDC10JSON" (substring v 0 10)))
    %acdc-version-placeholder)
   (else %version-placeholder)))

(define (event-stripped-for-rederivation event-alist)
  "Return EVENT-ALIST with v, d (and i where the event is
   self-addressing) reset to the placeholders saidify-document expects.

   Self-addressing here means d == i in the concrete event — true for
   KERI inception (`icp`) and TEL registry inception (`vcp`), false
   for rotations and ACDCs (whose `i` carries the AID prefix or the
   issuer AID, not a SAID). Detecting via d==i instead of `t=icp`
   makes this helper safe to call on any saidify-shaped alist; the
   alternative was a latent footgun where rederiving a vcp's SAID
   would silently produce the wrong bytes.

   The v field is reset to the protocol's placeholder (KERI10JSON or
   ACDC10JSON) detected from the incoming v value. Other fields are
   preserved."
  (let* ((v0   (assoc-ref event-alist "v"))
         (vp   (%protocol-of-version v0))
         (d0   (assoc-ref event-alist "d"))
         (i0   (assoc-ref event-alist "i"))
         (self-addr? (and (string? d0) (string? i0) (string=? d0 i0))))
    (map (lambda (p)
           (cond
            ((string=? "v" (car p)) (cons "v" vp))
            ((string=? "d" (car p)) (cons "d" %saidplaceholder))
            ((and self-addr? (string=? "i" (car p)))
             (cons "i" %saidplaceholder))
            (else p)))
         event-alist)))

(define (recompute-event-said event-alist)
  "Recompute the SAID of EVENT-ALIST. Returns the qb64 SAID."
  (call-with-values
   (lambda () (saidify (event-stripped-for-rederivation event-alist)))
   (lambda (_j said _a) said)))

(define (array-first x)
  "Return the first element of X (vector or list), or #f if X is empty
   or not array-shaped. Centralizes the vector/list/missing trichotomy
   that recurs whenever we read a KERI event's k/n/b array — JSON
   parses these as vectors, but locally-built events use lists."
  (cond ((and (vector? x) (positive? (vector-length x))) (vector-ref x 0))
        ((pair? x) (car x))
        (else #f)))

(define (event-first-key event-alist)
  "Extract event.k[0] handling either vector or list representations.
   Returns #f when the field is absent or empty."
  (and (pair? event-alist) (array-first (assoc-ref event-alist "k"))))

(define (event-first-next-digest event-alist)
  "Extract event.n[0] — the digest of the next signing key. Same
   vector/list/missing handling as `event-first-key`. Returns #f when
   the field is absent or empty (e.g. on a non-transferable AID)."
  (and (pair? event-alist) (array-first (assoc-ref event-alist "n"))))

(define (event-sn event-alist)
  "Parse the s field of EVENT-ALIST as a base-16 integer, or -1 if
   the field is absent or unparseable. Tolerates non-alist input
   (returns -1) so that callers can pass `(last-event entry)`
   directly without a #f-guard."
  (let ((s (and (pair? event-alist) (assoc-ref event-alist "s"))))
    (cond ((string? s) (or (string->number s 16) -1))
          ((number? s) s)
          (else -1))))

;;; ── CESR text-stream OOBI emission ──────────────────────────────────────────
;;;
;;; A KERI OOBI response (per OOBI draft §9 + KERI's KEL streaming) is
;;; the concatenation of each KEL event's serialized JSON followed by
;;; its CESR attachment frame. For toad=0 D-prefix AIDs the only
;;; attachment is the controller-indexed signature group:
;;;
;;;   <event-json>-A<count-2-char>{<indexed-qb64-sig> ...}
;;;
;;; where:
;;;   -A      = ControllerIdxSigs counter code (keripy CtrDex.ControllerIdxSigs)
;;;   count   = 2-char base64url count of sigs (e.g. "AB" = 1)
;;;   each sig = 88-char qb64 indexed signature (code "AA"/"AB"/... + 86 chars)
;;;
;;; A full KEL stream for an AID is `<icp-frame><rot-frame>...` in sn order.

(define (count->b64-2 n)
  "Encode a small non-negative integer N (0..4095) as a 2-char base64url
   string suitable for CESR counter codes."
  (unless (and (exact-integer? n) (<= 0 n 4095))
    (error "count->b64-2: out of range" n))
  (let ((hi (quotient n 64))
        (lo (modulo  n 64)))
    (string (string-ref %b64url-digits hi)
            (string-ref %b64url-digits lo))))

(define (b64-2->count s i)
  "Decode the 2-char base64url counter starting at index I of S into an
   integer 0..4095. Inverse of count->b64-2."
  (+ (* 64 (b64url-char->val (string-ref s i)))
     (b64url-char->val (string-ref s (+ i 1)))))

(define (cesr-idx-sigs-group sigs)
  "ControllerIdxSigs attachment group: \"-A\" + 2-char count + the
   concatenated indexed qb64 signatures (the form `sign-event` returns).
   The tail of every signed frame we emit — KEL events attach it
   directly; endorsed replies nest it inside their -F group. Raises on
   an empty vector: an unsigned frame is always a caller bug."
  (let ((n (vector-length sigs)))
    (when (zero? n)
      (error "cesr-idx-sigs-group: at least one signature required"))
    (string-append "-A" (count->b64-2 n)
                   (let loop ((i 0) (acc ""))
                     (if (= i n)
                         acc
                         (loop (+ i 1)
                               (string-append acc (vector-ref sigs i))))))))

(define (cesr-stream-event event-json sigs)
  "Return the CESR text-stream frame for one KEL event: the canonical
   JSON bytes of the event followed by its ControllerIdxSigs attachment."
  (string-append event-json (cesr-idx-sigs-group sigs)))

(define (cesr-stream-kel events-and-sigs)
  "Concatenate per-event CESR frames for a full KEL stream.
   EVENTS-AND-SIGS is a list of pairs (event-json . sigs-vector) in
   sequence-number order (icp first, then each rot)."
  (apply string-append
         (map (lambda (pair)
                (cesr-stream-event (car pair) (cdr pair)))
              events-and-sigs)))

;;; ── OOBI endpoint replies (OKEA: /end/role/add + /loc/scheme) ───────────────
;;;
;;; Per OOBI.md §3.4 (OKEA) and KERI §10, a spec-compliant OOBI body carries,
;;; after the KEL, BADA reply messages that authorize the AID's service
;;; endpoint: an /end/role/add rpy (cid authorizes eid in a role) and a
;;; /loc/scheme rpy (eid authorizes its URL for a scheme). A resolver
;;; (keripy/KERIA) verifies them against the KEL that precedes them in the
;;; same stream and registers the endpoint in its location db — which is
;;; exactly what KERIA's witness receiptor consults (hab.fetchUrls) when it
;;; submits key events for receipts. Without these replies an OOBI conveys
;;; key state but no address: resolvers know WHO the AID is but not WHERE
;;; to reach it. Closes IMPLEMENTATION.md "Where we diverge" §4.
;;;
;;; Signature attachment grammar (mirrors keripy hab.endorse): a TRANSFERABLE
;;; signer attaches a TransIdxSigGroups (-F) group — signer prefix, then the
;;; sequence number and SAID of its latest establishment event, then a
;;; ControllerIdxSigs (-A) group — which keripy's parser feeds to
;;; Revery.processReply as a tsg. A NON-transferable signer (B-prefix
;;; witness) attaches a NonTransReceiptCouples (-C) couple of pre+cig.

(define (build-reply route attrs dt)
  "Build a KERI reply (rpy) message {v t d dt r a}. DT is the ISO-8601
   timestamp string — explicit, so this module stays clock-free for Hoot.
   Returns (values json-string said alist) like the other builders."
  (saidify (list (cons "v"  %version-placeholder)
                 (cons "t"  "rpy")
                 (cons "d"  %saidplaceholder)
                 (cons "dt" dt)
                 (cons "r"  route)
                 (cons "a"  attrs))))

(define (build-end-role-reply cid role eid dt)
  "rpy authorizing EID as CID's endpoint provider in ROLE (\"/end/role/add\").
   Must be endorsed (signed) by CID."
  (build-reply "/end/role/add"
               (list (cons "cid" cid) (cons "role" role) (cons "eid" eid))
               dt))

(define (build-loc-scheme-reply eid scheme url dt)
  "rpy authorizing URL as EID's service endpoint for SCHEME (\"/loc/scheme\").
   Must be endorsed (signed) by EID."
  (build-reply "/loc/scheme"
               (list (cons "eid" eid) (cons "scheme" scheme) (cons "url" url))
               dt))

(define (seqner-qb64 n)
  "CESR Seqner: 128-bit big-endian N under code \"0A\" (24 qb64 chars).
   Identifies the sequence number of an establishment event in -F groups."
  (let ((bv (make-bytevector 16 0)))
    (let loop ((i 15) (n n))
      (when (> n 0)
        (bytevector-u8-set! bv i (modulo n 256))
        (loop (- i 1) (quotient n 256))))
    (cesr-bytes->qb64 "0A" bv)))

(define (cesr-stream-reply rpy-json pre sn dig sigs)
  "CESR frame for an endorsed rpy from a TRANSFERABLE signer: the rpy JSON
   followed by one TransIdxSigGroups (-F) group naming the signer PRE, the
   sequence number SN and SAID DIG of the signer's latest establishment
   event, and the indexed SIGS vector."
  (string-append rpy-json
                 "-F" (count->b64-2 1)
                 pre
                 (seqner-qb64 sn)
                 dig
                 (cesr-idx-sigs-group sigs)))

(define (cesr-stream-reply-nontrans rpy-json pre cig)
  "CESR frame for an endorsed rpy from a NON-transferable signer (B-prefix
   witness): one NonTransReceiptCouples (-C) couple of PRE + CIG, where CIG
   is the unindexed \"0B\" qb64 signature over the rpy JSON."
  (string-append rpy-json "-C" (count->b64-2 1) pre cig))

;;; ── IPEX grant embeds: pathed-material attachment groups ────────────────────
;;;
;;; A spec-complete IPEX grant exn embeds the full acdc + iss + anc SADs in
;;; its `e` block, and ships each embed's own CESR attachment as a
;;; PathedMaterialQuadlets (-L) group: counter + a Pather naming the embed's
;;; field path + the attachment. keripy's Admitter (holder's agent) looks the
;;; groups up by path label to ingest the embedded events; without them it
;;; skips ingestion (\"missing path label\"). Pather qb64s are constants for
;;; our three fixed labels — derived from keripy `Pather(path=[k]).qb64`
;;; (a Bexter over \"-<label>\", 'A'-padded to quadlet alignment).

(define %ipex-path-acdc "6AACAAA-acdc")
(define %ipex-path-iss  "4AAB-iss")
(define %ipex-path-anc  "4AAB-anc")

(define (cesr-pathed-group path-qb64 attachment)
  "One PathedMaterialQuadlets (-L) group: counter over the quadlet count
   of PATH-QB64 ⧺ ATTACHMENT, then the pathed material itself. ATTACHMENT
   is the embed's own CESR attachment string (may be \"\")."
  (let* ((pathed (string-append path-qb64
                                (if (string? attachment) attachment "")))
         (len    (string-length pathed)))
    (unless (zero? (remainder len 4))
      (error "cesr-pathed-group: pathed material not quadlet-aligned" len))
    (string-append "-L" (count->b64-2 (quotient len 4)) pathed)))

(define* (oobi-endpoint-replies-for-icp icp-alist url keypair dt
                                        #:key (extra-locs '()))
  "oobi-endpoint-replies for a FRESH inception — the shape every at-mint
   producer (scope creation, browser signup) needs: the establishment
   event is the icp itself (sn 0, dig = icp.d), and the reply identity is
   the icp's saidified `i` — the identifier resolvers key their
   KEL/location dbs by (not any pubkey-prefix label a stack keeps
   internally). Rotated AIDs call oobi-endpoint-replies directly with
   their latest establishment event's coordinates."
  (oobi-endpoint-replies (assoc-ref icp-alist "i") url
                         0 (assoc-ref icp-alist "d")
                         keypair dt #:extra-locs extra-locs))

(define* (oobi-endpoint-replies-for-rot rot-alist url keypair dt
                                        #:key (extra-locs '()))
  "oobi-endpoint-replies AFTER a rotation: the establishment event is the
   rot itself (its sn and SAID), the identity is the rot's `i`, and the
   endorsement KEYPAIR must be the rotated-TO signing key — resolvers
   verify the -F group against the est event it names, so stale
   inception-era endorsements stop verifying once the key state moves.
   Producers re-ship these alongside every rotation so the served OOBI's
   endpoint authorization tracks the current key state."
  (oobi-endpoint-replies (assoc-ref rot-alist "i") url
                         (event-sn rot-alist) (assoc-ref rot-alist "d")
                         keypair dt #:extra-locs extra-locs))

(define* (oobi-endpoint-replies aid url sn dig keypair dt
                                #:key (extra-locs '()))
  "Build the framed /end/role/add + /loc/scheme reply pair that makes AID's
   OOBI endpoint-discoverable — the self-hosted case (keripy's `curls`
   config shape): AID authorizes ITSELF as its controller-role endpoint
   provider, located at URL. SN and DIG identify AID's latest establishment
   event (0 and the icp SAID for an unrotated AID); KEYPAIR is its current
   signing keypair; DT an ISO-8601 stamp. Returns a list of framed CESR
   strings ready to append after the KEL in an OOBI body.

   EXTRA-LOCS is an alist of additional (scheme . url) endpoint pairs —
   e.g. ((\"reticulum\" . \"reticulum://<dest-hash>\")) advertises the
   AID's mesh destination through the same BADA-verified channel as its
   web endpoint. They are framed LAST: keripy whitelists loc schemes to
   tcp/http/https (kering.Schemes) and drops others per-message, so
   ordering keeps the spec-blessed pair safe even under a parser that
   aborts on the first rejected reply. Playnet resolvers read all of
   them."
  (let ((scheme (if (string-prefix? "https" url) "https" "http"))
        (frame-loc (lambda (sch u)
                     (call-with-values
                       (lambda () (build-loc-scheme-reply aid sch u dt))
                       (lambda (ls-json _ls _la)
                         (cesr-stream-reply ls-json aid sn dig
                                            (vector (sign-event ls-json
                                                                keypair))))))))
    (call-with-values
      (lambda () (build-end-role-reply aid "controller" aid dt))
      (lambda (er-json _es _ea)
        (cons* (cesr-stream-reply er-json aid sn dig
                                  (vector (sign-event er-json keypair)))
               (frame-loc scheme url)
               (map (lambda (loc) (frame-loc (car loc) (cdr loc)))
                    extra-locs))))))

;;; ── CESR text-stream parsing ────────────────────────────────────────────────
;;;
;;; The inverse of cesr-stream-event/kel: walk a concatenated KEL stream
;;; and split it into per-event (event-json-string . sigs-vector) pairs.
;;; Each event's byte length is read from its KERI version string
;;; (`<PROTO>10JSON<hex6>_` at offset 5..21 of the JSON), which is how
;;; keripy/signify-ts find frame boundaries in a stream. After the event
;;; bytes we expect one of the attachment groups we emit: `-A<count2>`
;;; (ControllerIdxSigs — KEL events), `-F<count2>` (TransIdxSigGroups —
;;; endorsed rpy from a transferable signer), or `-C<count2>`
;;; (NonTransReceiptCouples — nontrans endorsement). Anything else raises
;;; so the caller can fall back to another transport rather than silently
;;; skipping data.

(define (keri-version-size s start)
  "Read the KERI version string starting at index START of S (which must
   be the opening `{` of a serialized event) and return the total event
   byte length encoded in its hex6 size field. Returns #f if the version
   string is malformed."
  ;; A serialized KERI/ACDC event starts with `{\"v\":\"<10>10JSON<hex6>_\"`.
  ;; The version string itself is 17 chars at offset start+6 (after `{"v":"`).
  (let* ((vstart (+ start 6))
         (slen   (string-length s)))
    (and (<= (+ vstart 17) slen)
         (let* ((vstr (substring s vstart (+ vstart 17)))
                (proto-ok (and (or (string=? (substring vstr 0 10) "KERI10JSON")
                                   (string=? (substring vstr 0 10) "ACDC10JSON"))
                               (char=? (string-ref vstr 16) #\_)))
                (hex (and proto-ok (substring vstr 10 16))))
           (and hex (string->number hex 16))))))

(define (cesr-stream-parse stream)
  "Parse a CESR text-stream KEL into a list of (event-json-string .
   sigs-vector) pairs, in stream order. Empty input yields '(). Raises
   on a malformed frame so callers don't silently truncate KELs."
  (define slen (string-length stream))
  (define (need! end label)
    (when (> end slen)
      (error (string-append "cesr-stream-parse: " label " exceeds stream") end)))
  (define (read-sigs start count label)
    ;; COUNT 88-char qb64 signatures beginning at START.
    ;; Returns (values sigs-vector end-index).
    (let ((end (+ start (* 88 count))))
      (need! end label)
      (values (list->vector
               (map (lambda (k)
                      (let ((p (+ start (* k 88))))
                        (substring stream p (+ p 88))))
                    (iota count)))
              end)))
  (define (parse-frame i)
    ;; Returns (values event-json sigs-vector next-i). For -F (trans rpy
    ;; endorsement) and -C (nontrans couple) attachments the signer
    ;; pre/snu/dig metadata is consumed but not returned — this parser's
    ;; job is frame splitting; verification re-derives what it needs from
    ;; the message JSON and the preceding KEL.
    (unless (char=? (string-ref stream i) #\{)
      (error "cesr-stream-parse: expected '{' at frame start" i))
    (let* ((size       (or (keri-version-size stream i)
                           (error "cesr-stream-parse: bad version string at" i)))
           (event-end  (+ i size))
           (_          (need! event-end "event size"))
           (event-json (substring stream i event-end))
           (_          (need! (+ event-end 4) "sig counter"))
           (counter    (substring stream event-end (+ event-end 2)))
           (count      (b64-2->count stream (+ event-end 2)))
           (body-start (+ event-end 4)))
      (cond
       ;; ControllerIdxSigs: count × indexed sigs (KEL events).
       ((string=? counter "-A")
        (call-with-values (lambda () (read-sigs body-start count "sig group"))
          (lambda (sigs end) (values event-json sigs end))))
       ;; TransIdxSigGroups: count × (pre 44 + snu 24 + dig 44 +
       ;; "-A"cnt2 + sigs) — endorsed rpy from a transferable signer.
       ((string=? counter "-F")
        (let loop ((g 0) (pos body-start) (acc '()))
          (if (= g count)
              (values event-json (list->vector (reverse acc)) pos)
              (let* ((meta-end (+ pos 44 24 44))
                     (_        (need! (+ meta-end 4) "trans group"))
                     (icnt     (begin
                                 (unless (string=? (substring stream meta-end
                                                              (+ meta-end 2))
                                                   "-A")
                                   (error "cesr-stream-parse: -F group missing -A"
                                          meta-end))
                                 (b64-2->count stream (+ meta-end 2)))))
                (call-with-values
                  (lambda () (read-sigs (+ meta-end 4) icnt "trans sigs"))
                  (lambda (sigs end)
                    (loop (+ g 1) end
                          (append (reverse (vector->list sigs)) acc))))))))
       ;; NonTransReceiptCouples: count × (pre 44 + cig 88) — endorsed
       ;; rpy / receipt from a non-transferable signer.
       ((string=? counter "-C")
        (let loop ((g 0) (pos body-start) (acc '()))
          (if (= g count)
              (values event-json (list->vector (reverse acc)) pos)
              (let ((end (+ pos 44 88)))
                (need! end "nontrans couple")
                (loop (+ g 1) end
                      (cons (substring stream (+ pos 44) end) acc))))))
       (else
        (error "cesr-stream-parse: unsupported counter code" counter)))))
  (let loop ((i 0) (acc '()))
    (if (>= i slen)
        (reverse acc)
        (call-with-values (lambda () (parse-frame i))
          (lambda (ev sigs next-i)
            (loop next-i (cons (cons ev sigs) acc)))))))
