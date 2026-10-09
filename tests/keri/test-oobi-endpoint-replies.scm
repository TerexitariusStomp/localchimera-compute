;;; tests/keri/test-oobi-endpoint-replies.scm — OKEA endpoint replies in
;;; OOBI bodies (IMPLEMENTATION.md "Where we diverge" §4).
;;;
;;; Run: make test-keri-oobi-replies  (keri manifest: blake3 + goblins + keripy)
;;;
;;; What this proves, in three rings:
;;;   1. Builders/framing — oobi-endpoint-replies emits two rpy frames
;;;      (/end/role/add, /loc/scheme) endorsed with -F TransIdxSigGroups,
;;;      and cesr-stream-parse round-trips the full body.
;;;   2. Storage/serving — ^oobi-host stores the framed replies and
;;;      serve-static's body builder appends them after the KEL.
;;;   3. AUTHORITATIVE — keripy itself (the code KERIA runs) parses the
;;;      served body, BADA-verifies the replies against the KEL, and
;;;      registers the endpoint in db.locs / db.ends — the tables
;;;      hab.fetchUrls reads, i.e. what the witness receiptor needs.

(use-modules (playnet test harness)
             (playnet keri signify)            ; installs native crypto backend
             (playnet keri signify-portable)
             (playnet keri crypto-primitives)
             (playnet identity oobi-host)
             ((playnet keri inception)
              #:select (governance-create-scope-aid!
                        scope-inception-aid scope-inception-signed-icp))
             (playnet identity oobi-host-mirror)
             ((server serve-static) #:select ())  ; for @@ body-builder access
             (goblins)
             (json)
             (rnrs bytevectors)
             (ice-9 format)
             (ice-9 popen)
             (ice-9 regex)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define %url "http://gateway.example:8420/")
(define %dt  "2026-06-04T12:00:00.000000+00:00")

;;; ── fixture: a fresh transferable AID + its endpoint replies ────────────────

(define kp  (keri-crypto-ed25519-from-seed (make-bytevector 32 7)))
(define nkp (keri-crypto-ed25519-from-seed (make-bytevector 32 9)))

(define-values (icp-json aid icp-alist)
  (build-icp #:keys  (list (public-key->aid-prefix (ed25519-keypair-public kp)))
             #:nkeys (list (next-key-digest (ed25519-keypair-public nkp)))))

(define icp-sig (sign-event icp-json kp))
(define replies (oobi-endpoint-replies aid %url 0 aid kp %dt))
(define body
  (apply string-append
         (cesr-stream-event icp-json (vector icp-sig))
         replies))

;;; ── 1. builders + framing round-trip ────────────────────────────────────────

(format #t "~%-- 1. builders + cesr-stream round-trip --~%")

(check-pred "two framed replies" (= 2 (length replies)))

(let ((frames (cesr-stream-parse body)))
  (check "body parses into icp + 2 reply frames" (length frames) 3)
  (let* ((er  (json-string->scm (car (list-ref frames 1))))
         (ls  (json-string->scm (car (list-ref frames 2))))
         (era (assoc-ref er "a"))
         (lsa (assoc-ref ls "a")))
    (check "frame 1 is the icp"           (assoc-ref (json-string->scm
                                                      (car (list-ref frames 0)))
                                                     "t") "icp")
    (check "frame 2 is an rpy"            (assoc-ref er "t") "rpy")
    (check "frame 2 route /end/role/add"  (assoc-ref er "r") "/end/role/add")
    (check "end-role cid is the AID"      (assoc-ref era "cid") aid)
    (check "end-role eid is the AID"      (assoc-ref era "eid") aid)
    (check "end-role role is controller"  (assoc-ref era "role") "controller")
    (check "frame 3 route /loc/scheme"    (assoc-ref ls "r") "/loc/scheme")
    (check "loc-scheme eid is the AID"    (assoc-ref lsa "eid") aid)
    (check "loc-scheme scheme http"       (assoc-ref lsa "scheme") "http")
    (check "loc-scheme url"               (assoc-ref lsa "url") %url)
    (check-pred "reply endorsement sig present (88-char indexed)"
                (= 88 (string-length
                       (vector-ref (cdr (list-ref frames 1)) 0))))))

;;; ── 2. ^oobi-host storage + serve-static body assembly ─────────────────────

(format #t "~%-- 2. oobi-host + serving --~%")

(define vat (spawn-vat #:name "oobi-replies-test"))
(define cesr-body-of-entry (@@ (server serve-static) cesr-kel-of-entry))

(define entry
  (with-vat vat
    (let ((host (spawn ^oobi-host)))
      ($ host 'put! aid icp-alist (vector icp-sig))
      ($ host 'set-replies! aid (list->vector replies))
      ($ host 'get aid))))

(check-pred "entry stores the framed replies"
            (equal? (list->vector replies) (assq-ref entry 'replies)))
(check "served body = KEL + replies" (cesr-body-of-entry entry) body)

(check-pred "set-replies! on unknown AID errors"
            (let ((rv (with-vat vat
                        (let ((host (spawn ^oobi-host)))
                          ($ host 'set-replies! "EUnknown" (vector))))))
              (and (pair? rv) (eq? 'error (car rv)))))

;; Backward compat: entries written before the replies field serve KEL-only.
(check "pre-replies entry serves bare KEL"
       (cesr-body-of-entry `((aid  . ,aid)
                             (icp  . ,icp-alist)
                             (sigs . ,(vector icp-sig))
                             (rotations . ())))
       (cesr-stream-event icp-json (vector icp-sig)))

;;; ── 3. AUTHORITATIVE: keripy verifies + registers the endpoint ─────────────

(format #t "~%-- 3. keripy (the code KERIA runs) --~%")

(define (run-capture cmd)
  "Run CMD (list of strings) merging stderr; return (exit-code . output)."
  (let* ((port (open-input-pipe
                (string-join (append cmd '("2>&1")) " ")))
         (out  (get-string-all port))
         (code (status:exit-val (close-pipe port))))
    (cons code out)))

(define (kli-wrapper-path)
  (let ((r (run-capture '("command" "-v" "kli"))))
    (and (zero? (car r))
         (let ((s (string-trim-right (cdr r))))
           (and (not (string-null? s)) s)))))

(define verify-keripy
  ;; (verify-keripy label body-string aid url) — feed the body to keripy
  ;; (located via the kli wrapper's baked PYTHONPATH + python) and check it
  ;; registers URL for AID in db.locs/db.ends. Skips when kli is absent.
  (let ((kli (kli-wrapper-path)))
    (if (not kli)
        (lambda (label . _)
          (format #t "  SKIP ~a: kli not on PATH — run via make test-keri-oobi-replies~%"
                  label))
        (let* ((wrapper (call-with-input-file kli get-string-all))
               (grab    (lambda (rx)
                          (let ((m (string-match rx wrapper)))
                            (and m (match:substring m 1)))))
               (pypath  (grab "GUIX_PYTHONPATH=\"([^\"]+)\""))
               (real    (grab "\"(/gnu/store/[^\"]+\\.kli-real)\""))
               (pyline  (substring (call-with-input-file real
                                     (lambda (p) (get-line p)))
                                   2)))   ; strip "#!"
          (setenv "PYTHONPATH" pypath)
          (lambda (label body* aid* url*)
            (let ((tmp (string-append (or (getenv "TMPDIR") "/tmp")
                                      "/oobi-replies-body.cesr")))
              (call-with-output-file tmp (lambda (p) (display body* p)))
              (let* ((cmd (append (string-split pyline #\space)
                                  (list "tests/keri/verify-oobi-replies.py"
                                        tmp aid* url*)))
                     (r   (run-capture cmd)))
                (format #t "~a" (cdr r))
                (check label (car r) 0))
              (delete-file tmp)))))))

(verify-keripy "keripy registers the endpoint from our OOBI body"
               body aid %url)

;;; ── 4. producer: scope-AID inception with #:endpoint-url ───────────────────
;;; The real gateway path: governance-create-scope-aid! endorses the replies
;;; at mint time (the only moment the keypair is in hand), the kel-store body
;;; carries them, ^oobi-host-mirror forwards them, serve-static serves them.
;;; Note the signer here is a D-prefix basic transferable AID (scope AIDs),
;;; exercising a different prefix type than ring 1-3's E-prefix.

(format #t "~%-- 4. producer: scope-AID with #:endpoint-url --~%")

(define scope-rec
  (governance-create-scope-aid! #:endpoint-url %url))
(define scope-aid  (scope-inception-aid scope-rec))
(define scope-body (scope-inception-signed-icp scope-rec))

(check-pred "scope icp body carries 2 framed replies"
            (let ((r (assoc-ref scope-body "replies")))
              (and (vector? r) (= 2 (vector-length r)))))

(check-pred "no replies without #:endpoint-url"
            (not (assoc-ref
                  (scope-inception-signed-icp (governance-create-scope-aid!))
                  "replies")))

;; The mirror files the entry under the icp's own `i` — what a resolver
;; fetches at /oobi/{i} and keys its KEL by. `scope-aid` is the qb64 of
;; the inception key: the scope stack's internal name, held by no entry.
(define scope-i (assoc-ref (assoc-ref scope-body "icp") "i"))
(define scope-host (with-vat vat (spawn ^oobi-host)))
(define scope-mirror (with-vat vat (spawn-oobi-host-mirror scope-host)))
(with-vat vat ($ scope-mirror 'mirror scope-aid scope-body))
(check "the key label holds no entry"
       (not (with-vat vat ($ scope-host 'get scope-aid))))
;; The mirror's own writes to the host go through `<-` (the two run in
;; separate vats on the real gateway, so `$` is not an option there
;; either) — even here, in one vat, `<-` still lands on the host's
;; NEXT turn, so the entry is read back after a short poll rather than
;; straight off the `$ mirror 'mirror` call's return.
(define (scope-entry-now) (with-vat vat ($ scope-host 'get scope-i)))
(define scope-entry
  (let loop ((tries 0))
    (let ((v (scope-entry-now)))
      (cond ((pair? v) v)
            ((>= tries 50) v)
            (else (usleep 20000) (loop (+ tries 1)))))))

(check-pred "mirror filed the entry under the icp's i"
            (and (pair? scope-entry) (equal? scope-i (assq-ref scope-entry 'aid))))

(check-pred "mirror forwarded replies into the oobi-host entry"
            (let ((r (assq-ref scope-entry 'replies)))
              (and (vector? r) (= 2 (vector-length r)))))

(let ((served (cesr-body-of-entry scope-entry))
      ;; Resolvers key their KEL/location dbs by the icp's saidified `i`,
      ;; not the kq label the scope stack uses internally.
      (true-i (assoc-ref (assoc-ref scope-body "icp") "i")))
  (check "scope OOBI body parses into icp + 2 replies"
         (length (cesr-stream-parse served)) 3)
  (verify-keripy "keripy registers the scope-AID endpoint"
                 served true-i %url))

;;; ── 5. rot-era endorsements: replies re-signed after a rotation ────────────
;;; After a rotation the -F group must name the ROT as the establishment
;;; event and be signed with the rotated-TO key — Revery verifies the
;;; endorsement against exactly that est event, so this is the ring that
;;; would catch a stale-coordinate bug. Body = icp ⧺ rot ⧺ rot-era replies.

(format #t "~%-- 5. rot-era endorsements (post-rotation replies) --~%")

(define kp2 (keri-crypto-ed25519-from-seed (make-bytevector 32 11)))
(define %rot-url "http://gateway.example:9999/")

(define-values (rot-json rot-said rot-alist)
  (build-rot aid aid   ; prior est evt = the icp (i = d for saidified icp)
             #:keys  (list (public-key->aid-prefix
                            (ed25519-keypair-public nkp)))
             #:nkeys (list (next-key-digest (ed25519-keypair-public kp2)))
             #:sn 1))

(let* ((rot-replies (oobi-endpoint-replies-for-rot
                     rot-alist %rot-url nkp
                     "2026-06-04T13:00:00.000000+00:00"))
       (rot-body    (apply string-append
                           (cesr-stream-event icp-json (vector icp-sig))
                           (cesr-stream-event rot-json
                                              (vector (sign-event rot-json nkp)))
                           rot-replies)))
  (check "rot-era body parses into icp + rot + 2 replies"
         (length (cesr-stream-parse rot-body)) 4)
  (verify-keripy "keripy verifies rot-era endorsements + registers endpoint"
                 rot-body aid %rot-url))

;;; ── 6. mesh endpoint: reticulum destination as an extra /loc/scheme ────────
;;; #:extra-locs advertises non-web endpoints through the same BADA channel
;;; — the browser ships ("reticulum" . "reticulum://<dest-hash>") alongside
;;; the gateway origin. Boundary: keripy whitelists loc schemes to
;;; tcp/http/https (kering.Schemes) and rejects the reticulum rpy
;;; PER-MESSAGE — the keripy ring proves the spec-blessed pair still
;;; verifies and registers with the mesh reply in the stream (which is why
;;; extra-locs frame LAST). Playnet resolvers read all schemes.

(format #t "~%-- 6. mesh endpoint (extra /loc/scheme, scheme reticulum) --~%")

(define %ret-dest "reticulum://a079a0ed2f96e883e15bafee43a0ed06")

(let* ((mesh-replies (oobi-endpoint-replies
                      aid %url 0 aid kp %dt
                      #:extra-locs `(("reticulum" . ,%ret-dest))))
       (mesh-body    (apply string-append
                            (cesr-stream-event icp-json (vector icp-sig))
                            mesh-replies)))
  (check "extra-locs body parses into icp + 3 replies"
         (length (cesr-stream-parse mesh-body)) 4)
  (let* ((frames (cesr-stream-parse mesh-body))
         (mesh   (json-string->scm (car (list-ref frames 3))))
         (ma     (assoc-ref mesh "a")))
    (check "mesh frame is the LAST reply (keripy-safety ordering)"
           (assoc-ref mesh "r") "/loc/scheme")
    (check "mesh loc scheme is reticulum" (assoc-ref ma "scheme") "reticulum")
    (check "mesh loc url is the destination" (assoc-ref ma "url") %ret-dest)
    (check "mesh loc eid is the AID" (assoc-ref ma "eid") aid))
  ;; The authoritative boundary proof: keripy still accepts the KEL,
  ;; verifies the endorsements, and registers the HTTP endpoint with the
  ;; (rejected-by-whitelist) reticulum reply present in the same stream.
  (verify-keripy "keripy ingests http loc + end-role despite mesh reply"
                 mesh-body aid %url))

;;; ── 7. anchored ROT: keripy accepts the retrofit binding event ──────────────
;;; Pre-anchor personas seal playnet-reticulum-pub into a ROTATION
;;; (build-rot #:anchors) — the same custom seal shape keripy already
;;; accepts in our icp `a` blocks. This ring is the conformance proof
;;; for the rot case: keripy processes icp(sn0, no anchor) → anchored
;;; rot(sn1) → rot-era replies, accepts the KEL, and registers the
;;; endpoint from the rot-referenced -F endorsements.

(format #t "~%-- 7. anchored rot (pre-anchor persona retrofit) --~%")

(define r7-kp  (keri-crypto-ed25519-from-seed (make-bytevector 32 13)))
(define r7-nkp (keri-crypto-ed25519-from-seed (make-bytevector 32 17)))
(define %r7-pub
  "938ae10fe444599c43664bbeced66cce4a16aaa0858b6901e2eb439e0266442f02842c6d1536d101bb766f6ac3784687289118b9c3afc38eebab3873ef455519")

(define-values (r7-icp-json r7-icp-said r7-icp)
  (build-icp #:keys  (list (public-key->aid-prefix
                            (ed25519-keypair-public r7-kp)))
             #:nkeys (list (next-key-digest
                            (ed25519-keypair-public r7-nkp)))))

(define-values (r7-rot-json r7-rot-said r7-rot)
  (build-rot (assoc-ref r7-icp "i") r7-icp-said
             #:keys  (list (public-key->aid-prefix
                            (ed25519-keypair-public r7-nkp)))
             #:nkeys (list (next-key-digest
                            (ed25519-keypair-public r7-kp)))
             #:sn 1
             #:anchors `((("playnet-reticulum-pub" . ,%r7-pub)))))

(let* ((r7-aid     (assoc-ref r7-icp "i"))
       (r7-replies (oobi-endpoint-replies-for-rot
                    r7-rot %url r7-nkp
                    "2026-06-05T15:00:00.000000+00:00"))
       (r7-body    (apply string-append
                          (cesr-stream-event r7-icp-json
                                             (vector (sign-event r7-icp-json
                                                                 r7-kp)))
                          (cesr-stream-event r7-rot-json
                                             (vector (sign-event r7-rot-json
                                                                 r7-nkp)))
                          r7-replies)))
  (check "anchored rot carries the seal in `a`"
         (let ((a (assoc-ref r7-rot "a")))
           (and (vector? a) (= 1 (vector-length a))
                (equal? %r7-pub
                        (assoc-ref (vector-ref a 0)
                                   "playnet-reticulum-pub"))))
         #t)
  (verify-keripy "keripy accepts the anchored rot + registers endpoint"
                 r7-body r7-aid %url))

(test-summary!)
