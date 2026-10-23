;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/keri/reticulum-binding.scm — AID ↔ mesh binding verifier
;;;
;;; A persona's icp anchors its Reticulum PUBKEY (playnet-reticulum-pub,
;;; the 64-byte x25519‖ed25519 bundle as hex) and its served OOBI
;;; advertises its mesh DESTINATION as a /loc/scheme reply (scheme
;;; "reticulum", url "reticulum://<dest-hash-hex>"). This module closes
;;; the loop (RETICULUM-IDENTITIES.md §"Binding is published"): the
;;; destination a resolver discovers must be DERIVABLE from the pubkey
;;; the KEL committed to — anchor = verification root, loc reply =
;;; discovery channel.
;;;
;;; Hash recipe (rns-core 0.1.7 destination.rs / rns-crypto identity.rs,
;;; same as reference-Reticulum):
;;;
;;;   identity_hash = SHA-256(pub64)[:16]
;;;   name_hash     = SHA-256("app.aspect1...")[:10]
;;;   dest_hash     = SHA-256(name_hash ‖ identity_hash)[:16]
;;;
;;; playnet's one live destination is ("goblins", ["ocapn"]) — what the
;;; gateway publishes as ocapn://<hex>.reticulum and what rns-wasm's
;;; destHashHex returns.
;;;
;;; Portable: hashes route through keri-crypto-sha256 (gcrypt on the
;;; server, noble in the browser) and the reply fields are read with a
;;; targeted scanner instead of guile-json (absent under Hoot) — safe
;;; because every input here is OUR OWN canonical emission
;;; (scm->json-canonical: compact, double-quoted, no escapes in these
;;; fields), gate-checked by the producers.

(define-module (playnet keri reticulum-binding)
  #:use-module (rnrs bytevectors)
  #:use-module ((playnet keri crypto-primitives)
                #:select (keri-crypto-sha256 keri-crypto-ed25519-verify))
  #:use-module ((playnet keri signify-portable)
                #:select (cesr-stream-parse))
  #:use-module ((playnet utils hex) #:select (bv->hex hex->bv))
  #:use-module ((playnet utils host) #:select (string-contains))   ; Hoot has no srfi-13; one shim for both builds
  #:export (reticulum-identity-hash
            reticulum-destination-hash
            event-reticulum-pub
            kel-reticulum-pub
            icp-reticulum-pub
            json-field
            replies-mesh-locs
            oobi-body-mesh-locs
            oobi-body-reticulum-pub
            anchored-destinations
            verify-reticulum-binding
            verify-oobi-body-binding
            announce-dest-hex
            verify-announce-packet
            data-packet?))

(define (%truncate bv n)
  (let ((out (make-bytevector n 0)))
    (bytevector-copy! bv 0 out 0 n)
    out))

(define (%bv-append a b)
  (let* ((la (bytevector-length a))
         (lb (bytevector-length b))
         (out (make-bytevector (+ la lb) 0)))
    (bytevector-copy! a 0 out 0 la)
    (bytevector-copy! b 0 out la lb)
    out))

;; Hand-rolled list helpers — this module compiles into the Hoot bundle,
;; whose environment is not guaranteed to carry srfi-1's filter-map /
;; append-map (signify-portable takes the same precaution).
(define (%filter-map f lst)
  (let loop ((l lst) (acc '()))
    (if (null? l)
        (reverse acc)
        (let ((v (f (car l))))
          (loop (cdr l) (if v (cons v acc) acc))))))

(define (%append-map f lst)
  (let loop ((l lst) (acc '()))
    (if (null? l)
        (reverse acc)
        (loop (cdr l) (append (reverse (f (car l))) acc)))))

(define (%any f lst)
  (and (pair? lst) (or (f (car lst)) (%any f (cdr lst)))))

(define (%dot-join parts)
  (if (null? parts)
      ""
      (let loop ((l (cdr parts)) (acc (car parts)))
        (if (null? l)
            acc
            (loop (cdr l) (string-append acc "." (car l)))))))

;;; ── Hash recipe ─────────────────────────────────────────────────────────────

(define (reticulum-identity-hash pub-bv)
  "The 16-byte Reticulum identity hash of the 64-byte public-key
   bundle PUB-BV (x25519 ‖ ed25519): SHA-256(pub)[:16]."
  (unless (and (bytevector? pub-bv) (= 64 (bytevector-length pub-bv)))
    (error "reticulum-identity-hash: need the 64-byte pubkey bundle"))
  (%truncate (keri-crypto-sha256 pub-bv) 16))

(define* (reticulum-destination-hash pub-bv
                                     #:key (app "goblins")
                                           (aspects '("ocapn")))
  "The hex destination hash for PUB-BV's identity under APP/ASPECTS —
   defaults to playnet's OCapN destination, matching rns-wasm's
   destHashHex and the gateway's ocapn://<hex>.reticulum sturdyrefs."
  (let* ((name      (%dot-join (cons app aspects)))
         (name-hash (%truncate (keri-crypto-sha256 (string->utf8 name)) 10))
         (ih        (reticulum-identity-hash pub-bv)))
    (bv->hex (%truncate (keri-crypto-sha256 (%bv-append name-hash ih)) 16))))

;;; ── Targeted JSON field reads (own canonical emission only) ─────────────────

;; Local string-index (char, from START) — same Hoot-absence reason.
(define (string-index s ch start)
  (let ((n (string-length s)))
    (let loop ((i start))
      (cond ((>= i n) #f)
            ((char=? (string-ref s i) ch) i)
            (else (loop (+ i 1)))))))

(define (json-field json key)
  "The string value of \"KEY\":\"…\" in JSON, or #f. A targeted scan,
   not a parser — valid ONLY for playnet's own canonical emission
   (compact separators, plain string values, no escaped quotes in the
   fields read here: routes, schemes, urls, hex pubkeys)."
  (let* ((needle (string-append "\"" key "\":\""))
         (start  (string-contains json needle)))
    (and start
         (let* ((vstart (+ start (string-length needle)))
                (vend   (string-index json #\" vstart)))
           (and vend (substring json vstart vend))))))

;;; ── Extraction ──────────────────────────────────────────────────────────────

(define (event-reticulum-pub event-alist)
  "The anchored playnet-reticulum-pub from EVENT-ALIST's `a` seal block
   (icp / rot / ixn alike), as a 64-byte bytevector — or #f. The `a`
   field is a vector/list of seal alists; the anchor is the alist
   carrying the \"playnet-reticulum-pub\" key."
  (let* ((a     (assoc-ref event-alist "a"))
         (seals (cond ((vector? a) (vector->list a))
                      ((list? a)   a)
                      (else        '())))
         (hex   (%any (lambda (seal)
                        (and (pair? seal)
                             (assoc-ref seal "playnet-reticulum-pub")))
                      seals)))
    (and (string? hex)
         (= 128 (string-length hex))
         (hex->bv hex))))

(define (kel-reticulum-pub events)
  "The LATEST anchored playnet-reticulum-pub across EVENTS (KEL order,
   icp first), or #f. Later anchors supersede earlier ones — this is
   how personas created before the anchor existed retrofit the binding:
   a rotation seals the pubkey (build-rot #:anchors) and verifiers pick
   it up from here on."
  (let loop ((l events) (found #f))
    (if (null? l)
        found
        (loop (cdr l) (or (event-reticulum-pub (car l)) found)))))

;; Compatible name: most callers hold just the icp.
(define icp-reticulum-pub event-reticulum-pub)

(define (%frames-mesh-locs frames)
  "((scheme . url) …) from parsed (json . sigs) frames, keeping every
   /loc/scheme rpy regardless of scheme."
  (%filter-map
   (lambda (frame)
     (let ((j (car frame)))
       (and (equal? "rpy" (json-field j "t"))
            (equal? "/loc/scheme" (json-field j "r"))
            (let ((scheme (json-field j "scheme"))
                  (url    (json-field j "url")))
              (and scheme url (cons scheme url))))))
   frames))

(define (%parse-or-empty thunk)
  ;; with-exception-handler, not catch — this module also runs under
  ;; Hoot, where catch is unimplemented.
  (with-exception-handler (lambda (_exn) '()) thunk #:unwind? #t))

(define (replies-mesh-locs replies)
  "((scheme . url) …) from REPLIES — a vector (or list) of framed CESR
   reply strings as stored in an oobi-host entry. Unparseable frames
   are skipped: resolvers must not choke on replies they didn't
   produce."
  (let ((frames (if (vector? replies) (vector->list replies) replies)))
    (%append-map
     (lambda (frame)
       (%parse-or-empty
        (lambda () (%frames-mesh-locs (cesr-stream-parse frame)))))
     frames)))

(define (oobi-body-mesh-locs body)
  "((scheme . url) …) from a full served OOBI BODY (KEL ⧺ replies) —
   what a browser fetching a contact's /oobi/{aid} works from."
  (%parse-or-empty
   (lambda () (%frames-mesh-locs (cesr-stream-parse body)))))

(define (oobi-body-reticulum-pub body)
  "The LATEST anchored playnet-reticulum-pub across BODY's event frames
   (icp + rotations; rpy frames skipped), as a 64-byte bytevector — or
   #f. Latest wins, so rot-retrofitted anchors supersede (and personas
   that predate the anchor entirely yield #f)."
  (%parse-or-empty
   (lambda ()
     (let loop ((frames (cesr-stream-parse body)) (found #f))
       (if (null? frames)
           found
           (let* ((j   (caar frames))
                  (t   (json-field j "t"))
                  (hex (and (member t '("icp" "rot" "ixn"))
                            (json-field j "playnet-reticulum-pub"))))
             (loop (cdr frames)
                   (if (and (string? hex) (= 128 (string-length hex)))
                       (hex->bv hex)
                       found))))))))

;;; ── Verification ────────────────────────────────────────────────────────────
;;;
;;; One anchored identity, many destinations: each advertised mesh
;;; scheme maps to the (app, aspects) tuple its destination derives
;;; under. EVERY advertised destination of a known scheme must derive
;;; from the one anchored pubkey — a single mismatch fails the whole
;;; binding (it is the impersonation signature).

(define %mesh-schemes
  ;; scheme → (app aspects...) — extend as destinations are added.
  '(("reticulum" "goblins" "ocapn")     ; OCapN actor traffic
    ("lxmf"      "lxmf"    "delivery"))) ; store-and-forward mail

(define (%strip-scheme-prefix scheme url)
  (let ((prefix (string-append scheme "://")))
    (if (string-prefix? prefix url)
        (substring url (string-length prefix))
        url)))

(define (anchored-destinations pub-bv)
  "((scheme . dest-hex) …) — every destination PUB-BV's identity owns
   under the known tuples. THE enumeration of a persona's mesh
   addresses (mailbox draining, registration, advertisement all key
   off this one list)."
  (map (lambda (entry)
         (cons (car entry)
               (reticulum-destination-hash
                pub-bv #:app (cadr entry) #:aspects (cddr entry))))
       %mesh-schemes))

(define (%verify pub locs)
  (let ((known (filter (lambda (loc) (assoc (car loc) %mesh-schemes)) locs)))
    (cond
     ((not pub)     'no-anchor)
     ((null? known) 'no-mesh-loc)
     (else
      (let ((owned (anchored-destinations pub)))
        (let loop ((l known))
          (if (null? l)
              #t
              (let* ((scheme     (caar l))
                     (derived    (cdr (assoc scheme owned)))
                     (advertised (%strip-scheme-prefix scheme (cdar l))))
                (if (string=? derived advertised)
                    (loop (cdr l))
                    (string-append "advertised " scheme " destination "
                                   advertised
                                   " does not derive from the anchored pubkey"
                                   " (expected " derived ")"))))))))))

(define (verify-reticulum-binding kel replies)
  "Check the AID↔mesh binding: the reticulum destination advertised in
   REPLIES must equal the destination derived from the pubkey anchored
   in KEL — either a single event alist (the icp) or the full event
   list in KEL order, where the LATEST anchor wins (rot-retrofitted
   bindings supersede). Returns:
     #t           — advertised and derived destinations match
     'no-anchor   — no event carries playnet-reticulum-pub (predates it)
     'no-mesh-loc — no reticulum /loc/scheme among the replies
     an error string — mismatch (possible impersonation: the loc reply
                       endorsement verified under the AID's key, but
                       the destination is not the anchored identity's)"
  (%verify (if (and (pair? kel) (pair? (car kel)) (pair? (caar kel)))
               ;; a LIST of event alists (each event = list of pairs)
               (kel-reticulum-pub kel)
               (event-reticulum-pub kel))
           (replies-mesh-locs replies)))

(define (verify-oobi-body-binding body)
  "verify-reticulum-binding over a full served OOBI body string — the
   form a browser resolving a contact's /oobi/{aid} uses. Same
   verdicts."
  (%verify (oobi-body-reticulum-pub body) (oobi-body-mesh-locs body)))

;;; ── Relay-announce packet verification ──────────────────────────────────────
;;;
;;; Browsers can't reach the mesh, so the gateway relay-announces
;;; personas: rns-wasm packAnnounce builds + SIGNS the announce packet
;;; with the browser-held identity key; the gateway verifies it against
;;; the persona's KEL-anchored pubkey before injecting it via the
;;; bridge's ANNOUNCE_RAW. Packet layout (rns-core RawPacket, HEADER_1):
;;;
;;;   [flags 1][hops 1][dest_hash 16][context 1]
;;;   [pub 64][name_hash 10][random_hash 10][sig 64][app_data *]
;;;
;;; flags for our announce = 0x01 (HEADER_1, no context flag, broadcast,
;;; SINGLE destination, PACKET_TYPE_ANNOUNCE). Announce signature covers
;;; dest_hash ‖ pub ‖ name_hash ‖ random_hash ‖ app_data (no ratchet).

(define (%subbv bv start end)
  (let ((out (make-bytevector (- end start) 0)))
    (bytevector-copy! bv start out 0 (- end start))
    out))

;; HEADER_1 announce layout offsets (bytes). One place for the magic.
(define %ann-dest-start   2)  ; after [flags][hops]
(define %ann-dest-end    18)
(define %ann-pub-start   19)  ; after [context]
(define %ann-pub-end     83)
(define %ann-name-end    93)
(define %ann-random-end 103)
(define %ann-sig-end    167)

(define (announce-dest-hex packet-hex)
  "The destination hash (hex) named by an announce packet given as a
   hex string — the field the gateway REGISTERs after verification.
   Layout knowledge stays in this module."
  (substring packet-hex (* 2 %ann-dest-start) (* 2 %ann-dest-end)))

(define (data-packet? packet-bv)
  "Is PACKET-BV a HEADER_1 single-destination DATA packet? The gateway's
   send gate: outbound browser-composed packets must be DATA (flags
   0x00) — anything else (an announce in particular) would bypass the
   verified relay-announce path."
  (and (bytevector? packet-bv)
       (> (bytevector-length packet-bv) %ann-pub-start)
       (zero? (bytevector-u8-ref packet-bv 0))))

(define (%scheme-of-announce dest-hex nameh expected-pub-bv)
  "Which %mesh-schemes entry does this announce's destination + name
   hash belong to, derived from EXPECTED-PUB-BV? #f when neither
   matches — an announce for a tuple we don't recognize is refused
   (the relay only vouches for destinations the binding model covers)."
  (let loop ((schemes %mesh-schemes))
    (and (pair? schemes)
         (let* ((entry (car schemes))
                (tuple (cdr entry))
                (name  (%dot-join tuple)))
           (if (and (equal? nameh
                            (%truncate
                             (keri-crypto-sha256 (string->utf8 name)) 10))
                    (string=? dest-hex
                              (reticulum-destination-hash
                               expected-pub-bv
                               #:app (car tuple) #:aspects (cdr tuple))))
               (car entry)
               (loop (cdr schemes)))))))

(define (verify-announce-packet packet-bv expected-pub-bv)
  "Validate a relay-announce PACKET-BV against the persona's
   KEL-anchored pubkey EXPECTED-PUB-BV (64 bytes). Checks: layout +
   flags, embedded pubkey equality, destination + name hash matching
   one of the KNOWN destination tuples (%mesh-schemes — goblins.ocapn
   or lxmf.delivery) derived from the anchored pubkey, and the Ed25519
   announce signature under the bundle's signing half. Returns #t or
   an error string — the gateway MUST refuse to relay on anything but
   #t (an attacker-supplied packet would otherwise announce an
   arbitrary destination under the gateway's transport)."
  (let ((len (bytevector-length packet-bv)))
    (cond
     ((< len %ann-sig-end) "announce packet too short")
     ((not (= #x01 (bytevector-u8-ref packet-bv 0)))
      "flags are not a HEADER_1 single-destination announce")
     (else
      (let* ((dest   (%subbv packet-bv %ann-dest-start %ann-dest-end))
             (pub    (%subbv packet-bv %ann-pub-start  %ann-pub-end))
             (nameh  (%subbv packet-bv %ann-pub-end    %ann-name-end))
             (randh  (%subbv packet-bv %ann-name-end   %ann-random-end))
             (sig    (%subbv packet-bv %ann-random-end %ann-sig-end))
             (app    (if (> len %ann-sig-end)
                         (%subbv packet-bv %ann-sig-end len)
                         #f))
             (ed-pub (%subbv pub 32 64)))
        (cond
         ((not (equal? pub expected-pub-bv))
          "announce pubkey does not match the KEL-anchored bundle")
         ((not (%scheme-of-announce (bv->hex dest) nameh expected-pub-bv))
          "announce destination/name is not a known tuple derived from the anchored pubkey")
         (else
          (let ((signed (let* ((alen (if app (bytevector-length app) 0))
                               (out  (make-bytevector (+ 16 64 10 10 alen) 0)))
                          (bytevector-copy! dest  0 out 0  16)
                          (bytevector-copy! pub   0 out 16 64)
                          (bytevector-copy! nameh 0 out 80 10)
                          (bytevector-copy! randh 0 out 90 10)
                          (when app (bytevector-copy! app 0 out 100 alen))
                          out)))
            (if (keri-crypto-ed25519-verify ed-pub signed sig)
                #t
                "announce signature does not verify under the anchored key")))))))))
