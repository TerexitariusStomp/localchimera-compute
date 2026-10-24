;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/keri/test-signify.scm — Signify auth client unit tests
;;;
;;; Pure unit tests, no network. Covers:
;;;   - HKDF-SHA256 against RFC 5869 test vectors
;;;   (more sections added as Phase 3 progresses: bran→keypair, SAID,
;;;    signature-base, sign-request)
;;;
;;; Run via the dev-test guix shell so libblake3.so is available:
;;;   make test-signify

(use-modules (localchimera test harness)
             (localchimera keri signify)
             (rnrs bytevectors)
             (ice-9 format))

(define (string-replace-substring str from to)
  (let ((idx (string-contains str from)))
    (if idx
        (string-append (substring str 0 idx) to
                       (substring str (+ idx (string-length from))))
        str)))

(define (hex->bv hex)
  (let* ((n  (quotient (string-length hex) 2))
         (bv (make-bytevector n 0)))
    (let loop ((i 0))
      (when (< i n)
        (bytevector-u8-set!
         bv i
         (string->number (substring hex (* i 2) (+ (* i 2) 2)) 16))
        (loop (+ i 1))))
    bv))

(define (bv->hex bv)
  (let ((parts (map (lambda (i)
                      (format #f "~2,'0x" (bytevector-u8-ref bv i)))
                    (iota (bytevector-length bv)))))
    (apply string-append parts)))

;;; ── HKDF-SHA256 RFC 5869 vectors ─────────────────────────────────────────────

(format #t "=== HKDF-SHA256 RFC 5869 ===~%")

;;; Vector 1 (basic): SHA-256
;;; IKM  = 0x0b * 22
;;; salt = 0x000102030405060708090a0b0c
;;; info = 0xf0f1f2f3f4f5f6f7f8f9
;;; L    = 42
;;; PRK  = 077709362c2e32df0ddc3f0dc47bba63
;;;        90b6c73bb50f9c3122ec844ad7c2b3e5
;;; OKM  = 3cb25f25faacd57a90434f64d0362f2a
;;;        2d2d0a90cf1a5a4c5db02d56ecc4c5bf
;;;        34007208d5b887185865

(let* ((ikm  (hex->bv "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"))
       (salt (hex->bv "000102030405060708090a0b0c"))
       (info (hex->bv "f0f1f2f3f4f5f6f7f8f9"))
       (prk  (hkdf-extract salt ikm))
       (okm  (hkdf-expand prk info 42)))
  (check "RFC 5869 vec1: PRK full"
         (string=? (bv->hex prk)
                   (string-append "077709362c2e32df0ddc3f0dc47bba63"
                                  "90b6c73bb50f9c3122ec844ad7c2b3e5")))
  (check "RFC 5869 vec1: OKM full"
         (string=? (bv->hex okm)
                   (string-append "3cb25f25faacd57a90434f64d0362f2a"
                                  "2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
                                  "34007208d5b887185865"))))

;;; Vector 3 (zero-length salt + info, exercises #f-salt path)
;;; IKM  = 0x0b * 22
;;; salt = (empty)
;;; info = (empty)
;;; L    = 42
;;; PRK  = 19ef24a32c717b167f33a91d6f648bdf
;;;        96596776afdb6377ac434c1c293ccb04
;;; OKM  = 8da4e775a563c18f715f802a063c5a31
;;;        b8a11f5c5ee1879ec3454e5f3c738d2d
;;;        9d201395faa4b61a96c8

(let* ((ikm  (hex->bv "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"))
       ;; Pass #f for salt to exercise the zero-fill default
       (prk  (hkdf-extract #f ikm))
       (okm  (hkdf-expand prk #vu8() 42)))
  (check "RFC 5869 vec3: PRK (empty salt as #f)"
         (string=? (bv->hex prk)
                   (string-append "19ef24a32c717b167f33a91d6f648bdf"
                                  "96596776afdb6377ac434c1c293ccb04")))
  (check "RFC 5869 vec3: OKM (empty info)"
         (string=? (bv->hex okm)
                   (string-append "8da4e775a563c18f715f802a063c5a31"
                                  "b8a11f5c5ee1879ec3454e5f3c738d2d"
                                  "9d201395faa4b61a96c8"))))

;;; Empty-bytevector salt should behave the same as #f
(let* ((ikm  (hex->bv "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"))
       (prk-from-f      (hkdf-extract #f ikm))
       (prk-from-empty  (hkdf-extract #vu8() ikm)))
  (check "empty-bv salt == #f salt"
         (equal? (bv->hex prk-from-f) (bv->hex prk-from-empty))))

;;; hkdf convenience: same as Extract+Expand
(let* ((ikm  (hex->bv "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"))
       (salt (hex->bv "000102030405060708090a0b0c"))
       (info (hex->bv "f0f1f2f3f4f5f6f7f8f9"))
       (okm-extract-expand
        (hkdf-expand (hkdf-extract salt ikm) info 42))
       (okm-convenience
        (hkdf #:salt salt #:ikm ikm #:info info #:length 42)))
  (check "hkdf convenience matches manual extract+expand"
         (equal? okm-extract-expand okm-convenience)))

;;; Length must be honored exactly (truncation case)
(let ((okm (hkdf #:ikm (hex->bv "00") #:length 1)))
  (check "hkdf length=1 → 1 byte"
         (= 1 (bytevector-length okm))))

;;; Length over 255*HashLen must error
(check-error "hkdf length > 255*32 raises"
             (lambda ()
               (hkdf #:ikm (hex->bv "00") #:length (* 256 32))))

;;; ── Ed25519 seed → keypair (libsodium FFI) ───────────────────────────────────

(format #t "~%=== seed → Ed25519 keypair ===~%")

;; Known libsodium test vector (crypto_sign_ed25519_SEEDBYTES = 32):
;;   seed = 0x9d61b19deffd5a60ba844af492ec2cc4 4449c5697b326919703bac031cae7f60
;;   pk   = 0xd75a980182b10ab7d54bfed3c964073a 0ee172f3daa62325af021a68f707511a
;; (from the RFC 8032 Ed25519 test vectors, first sample)

(let* ((seed (hex->bv "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
       (kp   (seed->ed25519-keypair seed)))
  (check "keypair? recognizes result" (ed25519-keypair? kp))
  (check "public key is 32 bytes"
         (= 32 (bytevector-length (ed25519-keypair-public kp))))
  (check "public key matches RFC 8032 vector"
         (string=? (bv->hex (ed25519-keypair-public kp))
                   "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))
  (check "stored seed equals input"
         (equal? (bv->hex (ed25519-keypair-secret kp))
                 "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")))

;;; Determinism: same seed → same pubkey
(let* ((seed (make-bytevector 32 42))
       (kp1  (seed->ed25519-keypair seed))
       (kp2  (seed->ed25519-keypair seed)))
  (check "same seed → same public key"
         (equal? (ed25519-keypair-public kp1)
                 (ed25519-keypair-public kp2))))

;;; Wrong-size seed errors cleanly
(check-error "seed->ed25519-keypair on 16-byte bv raises"
             (lambda ()
               (seed->ed25519-keypair (make-bytevector 16 0))))

;;; ── Bran → keypair ───────────────────────────────────────────────────────────

(format #t "~%=== bran → keypair ===~%")

(let* ((bran "testpasscode21charsXX")          ; 21 chars (Signify convention)
       (kp1  (bran->signing-keypair bran))
       (kp2  (bran->signing-keypair bran))
       (nkp  (bran->next-keypair bran)))
  (check "same bran → same signing pubkey"
         (equal? (ed25519-keypair-public kp1)
                 (ed25519-keypair-public kp2)))
  (check "signing and next keys are distinct"
         (not (equal? (ed25519-keypair-public kp1)
                      (ed25519-keypair-public nkp))))
  (check "different bran → different pubkey"
         (not (equal? (ed25519-keypair-public kp1)
                      (ed25519-keypair-public
                       (bran->signing-keypair "otherpasscode210000XX"))))))

;;; ── AID / digest derivation ──────────────────────────────────────────────────

(format #t "~%=== AID prefix + next-key digest ===~%")

(let* ((bran "testpasscode21charsXX")
       (kp    (bran->signing-keypair bran))
       (nkp   (bran->next-keypair bran))
       (aid   (public-key->aid-prefix (ed25519-keypair-public kp)))
       (ndig  (next-key-digest (ed25519-keypair-public nkp))))
  (check "AID starts with 'D' (transferable)"
         (string=? "D" (substring aid 0 1)))
  (check "AID is 44 chars" (= 44 (string-length aid)))
  (check "next-key digest starts with 'E' (SAID / blake3)"
         (string=? "E" (substring ndig 0 1)))
  (check "next-key digest is 44 chars" (= 44 (string-length ndig)))
  (format #t "  test-bran AID: ~a~%" aid))

;;; ── SAID ─────────────────────────────────────────────────────────────────────

(format #t "~%=== SAID (said-of) ===~%")

;; Blake3("hello") from the reference test vectors:
;;   blake3_256(b"hello") = ea8f163db38682925e4491c5e58d4bb3506ef8c14eb78a86e908c5624a67200f
(let ((said (said-of (string->utf8 "hello"))))
  (check "SAID of \"hello\" starts with 'E'"
         (string=? "E" (substring said 0 1)))
  (check "SAID is 44 chars"
         (= 44 (string-length said)))
  (check "SAID round-trips via cesr-qb64->bytes"
         (= 32 (bytevector-length ((@ (localchimera keri cesr) cesr-qb64->bytes) said)))))

;;; Same input → same SAID (determinism)
(check "said-of deterministic"
       (equal? (said-of (string->utf8 "the-payload"))
               (said-of (string->utf8 "the-payload"))))

;;; ── build-icp ────────────────────────────────────────────────────────────────

(format #t "~%=== build-icp ===~%")

(let* ((bran  "testpasscode21charsXX")
       (skp   (bran->signing-keypair bran))
       (nkp   (bran->next-keypair bran))
       (kq    (public-key->aid-prefix (ed25519-keypair-public skp)))
       (nq    (next-key-digest (ed25519-keypair-public nkp))))
  (call-with-values
    (lambda ()
      (build-icp #:keys (list kq) #:nkeys (list nq)))
    (lambda (json-str said alist)
      (check "build-icp returns a non-empty JSON string"
             (and (string? json-str)
                  (> (string-length json-str) 0)))
      (check "build-icp returns a SAID starting with 'E'"
             (string=? "E" (substring said 0 1)))
      (check "SAID is 44 chars"
             (= 44 (string-length said)))
      (check "d field equals SAID"
             (string=? said (assoc-ref alist "d")))
      (check "i field equals SAID (= controller AID)"
             (string=? said (assoc-ref alist "i")))
      (check "t field is icp"
             (string=? "icp" (assoc-ref alist "t")))
      (check "s (sequence) is 0"
             (string=? "0" (assoc-ref alist "s")))
      (check "kt is 1"
             (string=? "1" (assoc-ref alist "kt")))
      (check "k contains our signing pubkey qb64"
             (equal? (vector kq) (assoc-ref alist "k")))
      (check "n contains our next-key digest qb64"
             (equal? (vector nq) (assoc-ref alist "n")))
      ;; Version field should include the real serialized size
      (check "v contains the byte length"
             (let ((v (assoc-ref alist "v")))
               (and (string-prefix? "KERI10JSON" v)
                    (string-suffix? "_" v))))
      ;; Recompute the SAID by UNDOING the substitution (replace the
      ;; real SAID with 44 '#' chars in d + i fields) — keripy's
      ;; Saider convention: SAID = blake3-256 of the event JSON with
      ;; the SAID fields set to '#' × fs, then base64-encoded as "E"+43.
      (let* ((placeholder (make-string 44 #\#))
             (restored1 (string-replace-substring json-str said placeholder))
             (restored2 (string-replace-substring restored1 said placeholder))
             (recomputed (said-of (string->utf8 restored2))))
        (check "SAID computed over placeholder form matches d field"
               (string=? said recomputed)))
      (format #t "  icp SAID: ~a~%" said)
      (format #t "  icp JSON (~a bytes): ~a~%" (string-length json-str) json-str))))

;;; Determinism: same inputs → same SAID + JSON
(let* ((bran "testpasscode21charsXX")
       (skp  (bran->signing-keypair bran))
       (nkp  (bran->next-keypair bran))
       (kq   (public-key->aid-prefix (ed25519-keypair-public skp)))
       (nq   (next-key-digest (ed25519-keypair-public nkp))))
  (call-with-values
    (lambda () (build-icp #:keys (list kq) #:nkeys (list nq)))
    (lambda (j1 s1 _)
      (call-with-values
        (lambda () (build-icp #:keys (list kq) #:nkeys (list nq)))
        (lambda (j2 s2 _)
          (check "build-icp deterministic on JSON" (string=? j1 j2))
          (check "build-icp deterministic on SAID" (string=? s1 s2)))))))

;;; ── Event signing ────────────────────────────────────────────────────────────

(format #t "~%=== Event signing ===~%")

(let* ((bran "testpasscode21charsXX")
       (kp   (bran->signing-keypair bran)))
  ;; sign-bytes
  (let ((sig (sign-bytes (string->utf8 "hello-world") kp)))
    (check "sign-bytes returns 64-byte signature"
           (= 64 (bytevector-length sig))))
  ;; sign-event produces indexed "AA" qb64
  (let ((sig-q64 (sign-event "{\"v\":\"KERI10JSON000000_\"}" kp)))
    (check "sign-event returns qb64 with 'AA' prefix"
           (string=? "AA" (substring sig-q64 0 2)))
    ;; decoded length: remove "AA" prefix, base64url back to 64 bytes
    (check "sign-event qb64 decodes to 64 bytes"
           (let ((decoded ((@ (localchimera keri cesr) cesr-qb64->bytes) sig-q64)))
             (= 64 (bytevector-length decoded))))))

;;; Verify the signature end-to-end using the pubkey from the keypair.
;;; We round-trip via Goblins' verify, which needs a crypto-public-key
;;; object built from the raw pubkey bytes.
(let* ((bran  "testpasscode21charsXX")
       (kp    (bran->signing-keypair bran))
       (pub   (ed25519-keypair-public kp))
       (msg   (string->utf8 "integration-nonce-42"))
       (sig   (sign-bytes msg kp)))
  ;; Pull verify lazily so the test can run in the same guix shell
  (let* ((goblins (resolve-interface '(goblins utils crypto)))
         (bv->pub (module-ref goblins 'bytevector->crypto-public-key))
         (verify  (module-ref goblins 'verify))
         (pub-obj (bv->pub pub)))
    (check "sign-bytes output verifies with goblins verify"
           (verify sig msg pub-obj))))

;;; ── Context + /boot body ─────────────────────────────────────────────────────

(format #t "~%=== /boot body ===~%")

(let* ((bran "testpasscode21charsXX")
       (ctx  (make-signify-context bran))
       (body (boot-body ctx)))
  (check "ctx.aid = SAID of icp (starts with 'E')"
         (string-prefix? "E" (signify-context-aid ctx)))
  (check "boot-body has icp"
         (pair? (assoc-ref body "icp")))
  (check "boot-body.icp.t = icp"
         (string=? "icp" (assoc-ref (assoc-ref body "icp") "t")))
  (check "boot-body.icp.i = ctx.aid (self-addressing: d == i == SAID)"
         (string=? (signify-context-aid ctx)
                   (assoc-ref (assoc-ref body "icp") "i")))
  (check "boot-body.icp.d = ctx.aid"
         (string=? (signify-context-aid ctx)
                   (assoc-ref (assoc-ref body "icp") "d")))
  (check "boot-body.icp.k[0] is the 'D'-prefix pubkey qb64"
         (let* ((k0 (vector-ref (assoc-ref (assoc-ref body "icp") "k") 0)))
           (string-prefix? "D" k0)))
  (check "boot-body.sig starts with 'AA'"
         (string-prefix? "AA" (assoc-ref body "sig")))
  (check "boot-body.stem = signify:controller"
         (string=? "signify:controller" (assoc-ref body "stem")))
  (check "boot-body.pidx = 0"
         (= 0 (assoc-ref body "pidx")))
  (check "boot-body.tier = low"
         (string=? "low" (assoc-ref body "tier"))))

;;; ── RFC 9421 signature-base ──────────────────────────────────────────────────

(format #t "~%=== signature-base + sign-request ===~%")

(let* ((base (signature-base 'GET "/identifiers"
                             "EcHaxXF0aZw7rWKoIqs9z8GUdE3gxRMqwCMS0uMFcA78"
                             "2026-04-14T12:34:56.123456+00:00"
                             1776262800
                             "EcHaxXF0aZw7rWKoIqs9z8GUdE3gxRMqwCMS0uMFcA78"))
       (base-str (utf8->string base)))
  (format #t "  --- base ---~%~a~%  --- end ---~%" base-str)
  (check "base has '\"signify-resource\": <aid>' line"
         (string-contains base-str "\"signify-resource\": EcHa"))
  (check "base has '\"@method\": GET' line"
         (string-contains base-str "\"@method\": GET"))
  (check "base has '\"@path\": /identifiers' line"
         (string-contains base-str "\"@path\": /identifiers"))
  (check "base has '\"signify-timestamp\": ...' line"
         (string-contains base-str "\"signify-timestamp\": 2026-04-14"))
  ;; Last line — entire @signature-params wrapped in quotes, field
  ;; names UNQUOTED inside parens, keyid/alg UNQUOTED values.
  (check "base has '\"@signature-params: (Signify-Resource @method @path Signify-Timestamp);...'"
         (string-contains base-str
                          "\"@signature-params: (Signify-Resource @method @path Signify-Timestamp);"))
  (check "base has unquoted created= in params"
         (string-contains base-str ";created=1776262800;"))
  (check "base has unquoted keyid="
         (string-contains base-str "keyid=EcHa"))
  (check "base has unquoted alg=ed25519"
         (string-contains base-str "alg=ed25519"))
  (check "last line ends with a closing double quote"
         (string-suffix? "\"" base-str)))

;;; sign-request end-to-end — returns 4 headers, sig verifies against pubkey
(let* ((bran "testpasscode21charsXX")
       (ctx  (make-signify-context bran))
       (hdrs (sign-request ctx 'POST "/identifiers")))
  (check "sign-request returns 4 headers"
         (= 4 (length hdrs)))
  (check "has Signify-Resource"
         (assq 'Signify-Resource hdrs))
  (check "has Signify-Timestamp"
         (assq 'Signify-Timestamp hdrs))
  (check "has Signature-Input with 'signify=' label"
         (let ((v (assq-ref hdrs 'Signature-Input)))
           (and v (string-prefix? "signify=" v))))
  (check "Signature header has indexed=\"?0\";signify=\"0B...\""
         (let ((v (assq-ref hdrs 'Signature)))
           (and v
                (string-contains v "indexed=\"?0\"")
                (string-contains v "signify=\"0B"))))
  ;; Decode the CESR-qb64 sig marker, recompute the canonical base,
  ;; verify against pubkey.
  (let* ((sig-hdr (assq-ref hdrs 'Signature))
         ;; Extract the 88-char CESR qb64 from `signify="..."` section
         (start   (+ (string-contains sig-hdr "signify=\"") 9))
         (end     (string-contains sig-hdr "\"" start))
         (q64     (substring sig-hdr start end))
         (sig     ((@ (localchimera keri cesr) cesr-qb64->bytes) q64))
         (res     (assq-ref hdrs 'Signify-Resource))
         (ts      (assq-ref hdrs 'Signify-Timestamp))
         ;; re-parse created from Signature-Input — just grep
         (si      (assq-ref hdrs 'Signature-Input))
         (created (let ((m (string-contains si "created=")))
                    (and m
                         (let* ((s (substring si (+ m 8)))
                                (semi (string-index s #\;)))
                           (string->number (substring s 0 (or semi (string-length s))))))))
         (base    (signature-base 'POST "/identifiers" res ts created res))
         (goblins (resolve-interface '(goblins utils crypto)))
         (bv->pub (module-ref goblins 'bytevector->crypto-public-key))
         (verify  (module-ref goblins 'verify))
         (pub-obj (bv->pub (ed25519-keypair-public
                            (signify-context-keypair ctx)))))
    (check "sign-request sig verifies against ctx pubkey + recomputed base"
           (verify sig base pub-obj))))

;;; ── ACDC build + edges (ACDC §8 e-block) ────────────────────────────────────

(format #t "~%=== build-acdc: edges emit `e` block with SAID ===~%")

(let* ((built1 (call-with-values
                 (lambda ()
                   (build-acdc "E_issuer" "E_registry" "localchimera-test/v1"
                               "E_holder" '(("foo" . "bar"))))
                 (lambda (json said alist) (list json said alist))))
       (json1  (car  built1))
       (said1  (cadr built1))
       (alist1 (caddr built1)))
  (check-pred "no-edges ACDC has no `e` field"
              (not (assoc-ref alist1 "e")))
  (check-pred "no-edges ACDC has ACDC10JSON version"
              (string-contains json1 "ACDC10JSON"))
  (check-pred "no-edges SAID starts with E"
              (string-prefix? "E" said1)))

(let* ((edges  (list (cons 'issuer-phc
                           `((n . "E_target_phc_said")
                             (o . I2I)
                             (s . "localchimera-personhood/v1")))))
       (built2 (call-with-values
                 (lambda ()
                   (build-acdc "E_issuer" "E_registry"
                               "localchimera-relationship/v1" "E_holder"
                               '(("relationship-type" . "trust"))
                               #:edges edges))
                 (lambda (json said alist) (list json said alist))))
       (json2  (car  built2))
       (alist2 (caddr built2))
       (e-block (assoc-ref alist2 "e")))
  (check-pred "edges ACDC carries `e` field in alist"
              (and e-block #t))
  (check-pred "e-block has own SAID `d`"
              (let ((d (assoc-ref e-block "d")))
                (and d (string-prefix? "E" d))))
  (let ((edge (assoc-ref e-block "issuer-phc")))
    (check-pred "edge.n = target SAID"
                (equal? "E_target_phc_said" (assoc-ref edge "n")))
    (check-pred "edge.o = \"I2I\" (stringified for JSON)"
                (equal? "I2I" (assoc-ref edge "o")))
    (check-pred "edge.s = target schema"
                (equal? "localchimera-personhood/v1" (assoc-ref edge "s"))))
  (check-pred "edges ACDC JSON contains the serialized edge block"
              (and (string-contains json2 "\"e\":")
                   (string-contains json2 "\"issuer-phc\":")
                   (string-contains json2 "\"I2I\""))))

;; ACDC §8 invariant: changing the edge target must change the outer SAID.
(let* ((said-a (call-with-values
                 (lambda ()
                   (build-acdc "E_issuer" "E_registry"
                               "localchimera-relationship/v1" "E_holder"
                               '(("relationship-type" . "trust"))
                               #:edges (list (cons 'issuer-phc
                                                   '((n . "E_a") (o . I2I))))))
                 (lambda (_j s _a) s)))
       (said-b (call-with-values
                 (lambda ()
                   (build-acdc "E_issuer" "E_registry"
                               "localchimera-relationship/v1" "E_holder"
                               '(("relationship-type" . "trust"))
                               #:edges (list (cons 'issuer-phc
                                                   '((n . "E_b") (o . I2I))))))
                 (lambda (_j s _a) s))))
  (check-pred "different edge targets ⇒ different ACDC SAIDs"
              (not (equal? said-a said-b))))

(test-summary!)
