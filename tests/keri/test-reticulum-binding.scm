;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/keri/test-reticulum-binding.scm — AID ↔ mesh binding verifier.
;;;
;;; Three rings:
;;;   1. Hash recipe against a LIVE-captured pair: the pubkey a real
;;;      browser persona anchored in its icp and the identity hash the
;;;      real rns-wasm reported for the same keys ("[reticulum] Bound
;;;      persona identity: …" — uxe2e fixture, deterministic from its
;;;      bran + k0).
;;;   2. AUTHORITATIVE cross-check: node loads the actual rns-wasm pkg
;;;      (the same Rust the browser runs), derives identity from a
;;;      fresh seed, and our Scheme derivation must reproduce its
;;;      identityHash + destHashHex. Skips when node is absent.
;;;   3. End-to-end wiring: icp with anchor + endorsed replies with the
;;;      mesh loc → verify-reticulum-binding #t; tampered destination
;;;      rejected; pre-anchor icp → 'no-anchor; no mesh loc →
;;;      'no-mesh-loc.
;;;
;;; Run: make test-keri-reticulum-binding

(use-modules (localchimera test harness)
             (localchimera keri signify-portable)
             (localchimera keri signify)              ; installs server backend
             (localchimera keri reticulum-binding)
             ((localchimera keri crypto-primitives)
              #:select (keri-crypto-ed25519-from-seed))
             ((localchimera utils hex) #:select (bv->hex hex->bv))
             (rnrs bytevectors)
             (ice-9 popen)
             (ice-9 textual-ports)
             (json)
             (srfi srfi-1)
             (srfi srfi-11))

;;; ── 1. live-captured pair ───────────────────────────────────────────────────
;;; From the signup e2e (uxe2e persona): repl.scm anchored this pubkey in
;;; the icp, and rns-wasm logged this destHashHex for the same identity
;;; ("[reticulum] Bound persona identity: …"). One pair exercises the
;;; whole recipe: identity hash + name hash + destination hash.

(format #t "=== AID ↔ mesh binding ===~%~%-- 1. live-captured pair --~%")

(define %live-pub
  "938ae10fe444599c43664bbeced66cce4a16aaa0858b6901e2eb439e0266442f02842c6d1536d101bb766f6ac3784687289118b9c3afc38eebab3873ef455519")
(define %live-dest-hash "3b63bbe29fb347d0bc6ec2206528c5d8")

(check "destination hash derivation reproduces rns-wasm's destHashHex"
       (reticulum-destination-hash (hex->bv %live-pub))
       %live-dest-hash)

(check "anchored-destinations enumerates every known scheme"
       (map car (anchored-destinations (hex->bv %live-pub)))
       '("reticulum" "lxmf"))

(check "anchored-destinations reticulum entry = the live dest"
       (assoc-ref (anchored-destinations (hex->bv %live-pub)) "reticulum")
       %live-dest-hash)

;;; ── 2. authoritative cross-check via the rns-wasm pkg (node) ────────────────

(format #t "~%-- 2. authoritative rns-wasm cross-check --~%")

(define (run-capture cmd)
  (let* ((port (open-input-pipe (string-append cmd " 2>&1")))
         (out  (get-string-all port))
         (code (status:exit-val (close-pipe port))))
    (cons code out)))

(define %node-script "
const fs = require('fs');
(async () => {
  const pkg = process.cwd() + '/rns-wasm/pkg';
  const wasm = await import('file://' + pkg + '/rns_wasm.js');
  // web-target pkg: initialize from bytes (no fetch under node).
  await wasm.default(fs.readFileSync(pkg + '/rns_wasm_bg.wasm'));
  const seed = new Uint8Array(64); seed.fill(42);
  const id = wasm.Identity.fromPrivateKey(seed);
  const announce = id.packAnnounce(BigInt(1764950400), undefined);
  const lxmfAnnounce = id.packAnnounceFor('lxmf', 'delivery',
                                          BigInt(1764950400), undefined);
  // Full LXMF round trip: mail ourselves — compose+sign+encrypt, then
  // play recipient: strip the packet header, decrypt, parse, verify.
  const mailPkt = id.packLxmfPacket(id.publicKey(), 'hi', 'hello mesh',
                                    1764950400);
  const plain = id.decrypt(mailPkt.slice(19)); // HEADER_1 = 19 bytes
  const parsed = JSON.parse(id.parseLxmf(plain));
  console.log(JSON.stringify({
    pub:  Buffer.from(id.publicKey()).toString('hex'),
    ih:   Buffer.from(id.identityHash()).toString('hex'),
    dest: id.destHashHex(),
    lxmf: id.lxmfDestHashHex(),
    announce: Buffer.from(announce).toString('hex'),
    lxmfAnnounce: Buffer.from(lxmfAnnounce).toString('hex'),
    mailPkt: Buffer.from(mailPkt).toString('hex'),
    mailParsed: parsed,
    mailVerified: id.verifyLxmf(plain, id.publicKey()),
  }));
})().catch(e => { console.error(e); process.exit(1); });
")

(let ((node (let ((r (run-capture "command -v node")))
              (and (zero? (car r))
                   (not (string-null? (string-trim-right (cdr r))))))))
  (if (not node)
      (format #t "  SKIP: node not on PATH — authoritative ring needs it~%")
      (let* ((tmp (string-append (or (getenv "TMPDIR") "/tmp")
                                 "/rns-vector.cjs"))
             (_   (call-with-output-file tmp
                    (lambda (p) (display %node-script p))))
             (r   (run-capture (string-append "node " tmp))))
        (delete-file tmp)
        (if (not (zero? (car r)))
            (begin
              (format #t "  SKIP: rns-wasm pkg not node-loadable: ~a~%" (cdr r))
              ;; not a check — environments without the wasm pkg stay green;
              ;; ring 1's live-captured pair still pins the recipe.
              )
            ;; stderr is merged (wasm-bindgen prints deprecation chatter);
            ;; the vector JSON is the last non-empty line.
            (let* ((lines (remove string-null?
                                  (string-split (cdr r) #\newline)))
                   (v     (json-string->scm (last lines)))
                   (pub   (hex->bv (assoc-ref v "pub"))))
              (check "Scheme identity hash == rns-wasm identityHash"
                     (bv->hex (reticulum-identity-hash pub))
                     (assoc-ref v "ih"))
              (check "Scheme destination hash == rns-wasm destHashHex"
                     (reticulum-destination-hash pub)
                     (assoc-ref v "dest"))
              ;; One identity, many destinations: lxmf.delivery derives
              ;; under the ("lxmf" "delivery") tuple from the same pub.
              (check "Scheme lxmf dest == rns-wasm lxmfDestHashHex"
                     (reticulum-destination-hash pub #:app "lxmf"
                                                 #:aspects '("delivery"))
                     (assoc-ref v "lxmf"))
              ;; Relay-announce round trip: the packet rns-wasm builds
              ;; and signs in the browser must verify against the same
              ;; pubkey here — the gateway's pre-relay gate.
              (let ((announce (hex->bv (assoc-ref v "announce"))))
                (check "rns-wasm packAnnounce verifies (gateway gate)"
                       (verify-announce-packet announce pub) #t)
                (let ((evil (bytevector-copy announce)))
                  ;; flip a bit inside the signed region (dest hash)
                  (bytevector-u8-set! evil 5
                                      (logxor 1 (bytevector-u8-ref evil 5)))
                  (check "tampered announce → rejected"
                         (string? (verify-announce-packet evil pub))
                         #t)))
              (check "lxmf.delivery announce verifies too"
                     (verify-announce-packet
                      (hex->bv (assoc-ref v "lxmfAnnounce")) pub)
                     #t)
              ;; LXMF round trip (composed+signed+encrypted, then
              ;; decrypted+parsed+verified — all in the real Rust):
              (let ((parsed (assoc-ref v "mailParsed"))
                    (pkt    (hex->bv (assoc-ref v "mailPkt"))))
                (check "lxmf round trip: title survives"
                       (assoc-ref parsed "title") "hi")
                (check "lxmf round trip: content survives"
                       (assoc-ref parsed "content") "hello mesh")
                (check "lxmf round trip: source = sender's mail dest"
                       (assoc-ref parsed "source") (assoc-ref v "lxmf"))
                (check "lxmf round trip: signature verifies"
                       (assoc-ref v "mailVerified") #t)
                (check "composed packet is DATA (gateway send gate)"
                       (data-packet? pkt) #t)
                (check "composed packet is NOT an announce (gate rejects)"
                       (string? (verify-announce-packet pkt pub)) #t)))))))

;;; ── 3. end-to-end wiring through icp + replies ──────────────────────────────

(format #t "~%-- 3. verify-reticulum-binding over icp + replies --~%")

(define kp (keri-crypto-ed25519-from-seed (make-bytevector 32 7)))
(define %pub-bv (hex->bv %live-pub))
(define %dest (reticulum-destination-hash %pub-bv))
(define %dt "2026-06-05T12:00:00.000000+00:00")
(define %url "http://gateway.example:8420/")

(define-values (icp-json icp-said icp-alist)
  (build-icp #:keys  (list (public-key->aid-prefix
                            (ed25519-keypair-public kp)))
             #:nkeys (list (next-key-digest (ed25519-keypair-public kp)))
             #:anchors `((("localchimera-reticulum-pub" . ,%live-pub)))))

(define aid (assoc-ref icp-alist "i"))

(define %lxmf-dest
  (reticulum-destination-hash %pub-bv #:app "lxmf" #:aspects '("delivery")))

(define replies
  (list->vector
   (oobi-endpoint-replies-for-icp
    icp-alist %url kp %dt
    #:extra-locs `(("reticulum" . ,(string-append "reticulum://" %dest))
                   ("lxmf"      . ,(string-append "lxmf://" %lxmf-dest))))))

(check "anchored pub extracted from the icp"
       (bv->hex (icp-reticulum-pub icp-alist)) %live-pub)

(check "replies expose all loc schemes"
       (map car (replies-mesh-locs replies))
       '("http" "reticulum" "lxmf"))

(check "binding verifies: BOTH destinations derive from anchored pub"
       (verify-reticulum-binding icp-alist replies) #t)

;; Tampered destination → named mismatch (impersonation guard).
(let* ((evil (string-append "reticulum://" (make-string 32 #\f)))
       (bad  (list->vector
              (oobi-endpoint-replies-for-icp
               icp-alist %url kp %dt
               #:extra-locs `(("reticulum" . ,evil))))))
  (check "tampered destination → mismatch error"
         (string? (verify-reticulum-binding icp-alist bad)) #t))

;; A correct ocapn dest does NOT excuse a wrong lxmf dest — every
;; advertised destination must derive (single-mismatch fails all).
(let ((bad (list->vector
            (oobi-endpoint-replies-for-icp
             icp-alist %url kp %dt
             #:extra-locs
             `(("reticulum" . ,(string-append "reticulum://" %dest))
               ("lxmf"      . ,(string-append "lxmf://"
                                              (make-string 32 #\f))))))))
  (check "wrong lxmf dest fails the whole binding"
         (string? (verify-reticulum-binding icp-alist bad)) #t))

;; Pre-anchor icp → 'no-anchor.
(let-values (((j s pre-anchor)
              (build-icp #:keys (list (public-key->aid-prefix
                                       (ed25519-keypair-public kp)))
                         #:nkeys (list (next-key-digest
                                        (ed25519-keypair-public kp))))))
  (check "icp without the anchor → 'no-anchor"
         (verify-reticulum-binding pre-anchor replies) 'no-anchor))

;; Replies without the mesh loc → 'no-mesh-loc.
(let ((plain (list->vector
              (oobi-endpoint-replies-for-icp icp-alist %url kp %dt))))
  (check "replies without a mesh loc → 'no-mesh-loc"
         (verify-reticulum-binding icp-alist plain) 'no-mesh-loc))

;;; ── 4. full-body verification (the browser/contact-resolve form) ────────────

(format #t "~%-- 4. verify-oobi-body-binding over a served body --~%")

(define body
  (apply string-append
         (cesr-stream-event icp-json (vector (sign-event icp-json kp)))
         (vector->list replies)))

(check "body mesh locs include the reticulum destination"
       (assoc-ref (oobi-body-mesh-locs body) "reticulum")
       (string-append "reticulum://" %dest))

(check "body anchor extraction matches the icp's"
       (bv->hex (oobi-body-reticulum-pub body)) %live-pub)

(check "full-body binding verifies"
       (verify-oobi-body-binding body) #t)

;;; ── 5. pre-anchor persona retrofits the binding via a rot anchor ────────────
;;; Identities created before the localchimera-reticulum-pub anchor verify as
;;; 'no-anchor. The remedy: the next rotation seals the pubkey
;;; (build-rot #:anchors) and verifiers read the LATEST anchor across
;;; the KEL.

(format #t "~%-- 5. rot-retrofitted anchor (pre-anchor persona) --~%")

(define-values (pre-json pre-said pre-icp)
  (build-icp #:keys  (list (public-key->aid-prefix
                            (ed25519-keypair-public kp)))
             #:nkeys (list (next-key-digest (ed25519-keypair-public kp)))))

(define-values (rot-json rot-said rot-alist)
  (build-rot (assoc-ref pre-icp "i") pre-said
             #:keys  (list (public-key->aid-prefix
                            (ed25519-keypair-public kp)))
             #:nkeys (list (next-key-digest (ed25519-keypair-public kp)))
             #:sn 1
             #:anchors `((("localchimera-reticulum-pub" . ,%live-pub)))))

;; Rot-era replies for THIS AID, exactly as the browser re-ships them
;; alongside the retrofit rotation (mesh loc included).
(define retro-replies
  (list->vector
   (oobi-endpoint-replies-for-rot
    rot-alist %url kp %dt
    #:extra-locs `(("reticulum" . ,(string-append "reticulum://" %dest))))))

(check "pre-anchor icp alone → 'no-anchor"
       (verify-reticulum-binding pre-icp retro-replies) 'no-anchor)

(check "kel-reticulum-pub finds the rot's anchor (latest wins)"
       (bv->hex (kel-reticulum-pub (list pre-icp rot-alist))) %live-pub)

(check "binding verifies against the full KEL"
       (verify-reticulum-binding (list pre-icp rot-alist) retro-replies) #t)

(check "full-body verification reads the rot anchor too"
       (let ((retro-body
              (string-append
               (cesr-stream-event pre-json (vector (sign-event pre-json kp)))
               (cesr-stream-event rot-json (vector (sign-event rot-json kp)))
               (apply string-append (vector->list retro-replies)))))
         (verify-oobi-body-binding retro-body))
       #t)

(test-summary!)
