;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/keri/test-keri-signify-integration.scm — full Signify pipeline mock test
;;;
;;; Drives the bridge through (keri-boot! → keri-create-aid) against an
;;; in-process mock KERIA, captures the raw HTTP traffic, and asserts:
;;;
;;;   1. POST /boot body has the signify-ts shape
;;;      ({icp, sig, stem, pidx, tier}) and the icp's d == i ==
;;;      our derived controller AID.
;;;   2. POST /identifiers carries the 4 Signify-* headers, in the
;;;      RFC 9421 format, with a 64-byte Ed25519 signature that
;;;      verifies against the controller pubkey when re-canonicalized.
;;;
;;; This is the "internal consistency" gate before we trust the
;;; bridge against real KERIA — if this is green and the integration
;;; suite still 4xxs, the bug is server-side, not in our auth.
;;;
;;; Run via the dev-test guix shell so libsodium/libblake3 are on path:
;;;   make test-keri-signify-integration

(use-modules (playnet test harness)
             (playnet keri bridge)
             (playnet keri cesr)
             (playnet keri signify)
             (web server)
             (web request)
             (web response)
             (web uri)
             (web http)
             (rnrs bytevectors)
             (ice-9 format)
             (ice-9 match)
             (ice-9 regex)
             (json))

;; Tell guile's HTTP parser not to break on Signify structured fields.
(declare-opaque-header! "signify-resource")
(declare-opaque-header! "signify-timestamp")
(declare-opaque-header! "signature-input")
(declare-opaque-header! "signature")

;;; ── Fixtures ─────────────────────────────────────────────────────────────────

(define %test-bran "testpasscode21charsXX")
(define %test-agent-name "integration-agent")

;; The agent AID KERIA returns. Real KERIA derives this internally; for
;; the mock it's an opaque sentinel.
(define %fake-agent-aid "EAgent000000000000000000000000000000000000")

;;; ── Capture state ────────────────────────────────────────────────────────────

(define %boot-body          #f)
(define %create-aid-headers #f)
(define %create-aid-method  #f)
(define %create-aid-path    #f)

(define (with-json code body)
  (values
   (build-response
    #:code code
    #:headers '((content-type . (application/json))))
   (scm->json-string body)))

(define (parse-body body)
  (let ((s (if (bytevector? body) (utf8->string body) (or body ""))))
    (if (string-null? s) '() (json-string->scm s))))

(define (header-value request name)
  "Extract a header by lowercase NAME (string). guile parses opaque
   headers as their raw string value."
  (let loop ((hs (request-headers request)))
    (cond
     ((null? hs) #f)
     ((let* ((h (car hs))
             (k (car h))
             (k-str (cond ((symbol? k) (symbol->string k))
                          ((string? k) k)
                          (else        ""))))
        (string=? (string-downcase k-str) name))
      (let ((v (cdr (car hs))))
        (cond ((string? v) v)
              ((pair? v)   (format #f "~a" v))   ; some opaque fields parse to lists
              (else        (format #f "~a" v)))))
     (else (loop (cdr hs))))))

(define (handle-request request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request))))
    (cond
     ((and (eq? method 'POST) (string=? path "/boot"))
      (set! %boot-body (parse-body body))
      (with-json 200
        `(("controller" . (("state" . (("i" . ,%fake-agent-aid))))))))

     ;; Signify-authenticated request — capture full header set.
     ((and (eq? method 'POST) (string=? path "/identifiers"))
      (set! %create-aid-method method)
      (set! %create-aid-path   path)
      (set! %create-aid-headers
            (list (cons 'signify-resource  (header-value request "signify-resource"))
                  (cons 'signify-timestamp (header-value request "signify-timestamp"))
                  (cons 'signature-input   (header-value request "signature-input"))
                  (cons 'signature         (header-value request "signature"))))
      (with-json 200 `(("done" . #t) ("name" . "op-create-aid"))))

     (else
      (values (build-response #:code 404) "not found")))))

(define-values (%port %thread) (spawn-mock-server handle-request))
(define %base (format #f "http://127.0.0.1:~a" %port))

(format #t "=== KERI Signify Pipeline Integration (mock on ~a) ===~%" %base)

(keri-set-urls! %base %base)
(keri-boot! %test-agent-name %test-bran)
(keri-create-aid "alice" #:toad 0 #:witnesses '())

;;; ── /boot body assertions ────────────────────────────────────────────────────

(format #t "~%=== /boot body shape ===~%")

(check "/boot body captured" (pair? %boot-body))
(check "/boot has icp"  (assoc "icp"  %boot-body))
(check "/boot has sig"  (assoc "sig"  %boot-body))
(check "/boot has stem" (assoc "stem" %boot-body))
(check "/boot has pidx" (assoc "pidx" %boot-body))
(check "/boot has tier" (assoc "tier" %boot-body))

(let ((icp (assoc-ref %boot-body "icp")))
  (check "icp.t = icp"
         (string=? "icp" (assoc-ref icp "t")))
  (check "icp.d == icp.i (self-addressing)"
         (string=? (assoc-ref icp "d") (assoc-ref icp "i")))
  (check "icp.i starts with 'E' (blake3 SAID)"
         (string-prefix? "E" (assoc-ref icp "i")))
  (check "icp.k is a 1-element vector"
         (and (vector? (assoc-ref icp "k"))
              (= 1 (vector-length (assoc-ref icp "k")))))
  (check "icp.k[0] starts with 'D' (transferable Ed25519)"
         (string-prefix? "D" (vector-ref (assoc-ref icp "k") 0))))

(check "boot.sig starts with 'AA' (indexed Ed25519)"
       (string-prefix? "AA" (assoc-ref %boot-body "sig")))
(check "boot.stem = signify:controller"
       (string=? "signify:controller" (assoc-ref %boot-body "stem")))
(check "boot.pidx = 0"
       (= 0 (assoc-ref %boot-body "pidx")))
(check "boot.tier = low"
       (string=? "low" (assoc-ref %boot-body "tier")))

;;; The controller AID we derive locally from the same bran must match
;;; what KERIA sees in icp.i. This is the round-trip check.
(let* ((local-ctx (make-signify-context %test-bran))
       (icp       (assoc-ref %boot-body "icp")))
  (check "icp.i == locally-derived controller AID"
         (string=? (signify-context-aid local-ctx)
                   (assoc-ref icp "i"))))

;;; ── Signed request (POST /identifiers) ───────────────────────────────────────

(format #t "~%=== Signed request headers ===~%")

(check "POST /identifiers reached the mock"
       (and %create-aid-headers (eq? %create-aid-method 'POST)))

(when %create-aid-headers
  (let ((res  (assq-ref %create-aid-headers 'signify-resource))
        (ts   (assq-ref %create-aid-headers 'signify-timestamp))
        (sin  (assq-ref %create-aid-headers 'signature-input))
        (sval (assq-ref %create-aid-headers 'signature)))
    (check "Signify-Resource header present" (string? res))
    (check "Signify-Timestamp header present" (string? ts))
    (check "Signature-Input header present" (string? sin))
    (check "Signature header present" (string? sval))

    (check "Signify-Resource is the controller AID (E-prefix SAID)"
           (string-prefix? "E" res))

    (check "Signify-Timestamp is ISO-8601 with +00:00"
           (and (string-contains ts "T")
                (string-contains ts "+00:00")))

    ;; Signature-Input shape (per keripy siginput):
    ;;   signify=("Signify-Resource" "@method" "@path" "Signify-Timestamp");
    ;;   created=N;keyid=<aid>;alg=ed25519
    (check "Signature-Input starts with 'signify='"
           (string-prefix? "signify=" sin))
    (check "Signature-Input covers @method"
           (string-contains sin "\"@method\""))
    (check "Signature-Input covers @path"
           (string-contains sin "\"@path\""))
    (check "Signature-Input covers Signify-Resource"
           (string-contains sin "\"Signify-Resource\""))
    (check "Signature-Input covers Signify-Timestamp"
           (string-contains sin "\"Signify-Timestamp\""))
    (check "Signature-Input has alg=ed25519 (unquoted)"
           (string-contains sin "alg=ed25519"))
    (check "Signature-Input has created=<unix>"
           (and (string-match "created=[0-9]+" sin) #t))

    ;; Signature header shape (per keripy ending.signature):
    ;;   indexed="?0";signify="0B<base64url of 64-byte sig>"
    (check "Signature value format 'indexed=\"?0\";signify=\"0B...\"'"
           (and (string-contains sval "indexed=\"?0\"")
                (string-contains sval "signify=\"0B")))

    ;; Extract the 88-char CESR qb64 from the signify="..." section
    (let* ((start-idx (string-contains sval "signify=\""))
           (after-eq  (+ start-idx 9))
           (end-quote (string-contains sval "\"" after-eq))
           (q64       (substring sval after-eq end-quote))
           (sig-bv    ((@ (playnet keri cesr) cesr-qb64->bytes) q64)))
      (check "decoded Signature is 64 bytes"
             (= 64 (bytevector-length sig-bv)))

      ;; ── Round-trip verification ────────────────────────────────────────────
      ;; Recompute the canonical base from the captured headers + the
      ;; method/path the bridge used, and verify the captured sig
      ;; against the pubkey we'd derive locally from the same bran.
      ;; If this passes, our bridge is producing valid Signify auth
      ;; that any spec-correct verifier (incl. KERIA) should accept.
      (let* ((created-match (string-match "created=([0-9]+)" sin))
             (created       (and created-match
                                 (string->number (match:substring created-match 1))))
             (base          (signature-base 'POST "/identifiers" res ts created res))
             ;; Locally derive the same keypair so we can verify.
             (ctx           (make-signify-context %test-bran))
             (kp            (signify-context-keypair ctx))
             (pub-bv        (ed25519-keypair-public kp))
             (goblins       (resolve-interface '(goblins utils crypto)))
             (bv->pub       (module-ref goblins 'bytevector->crypto-public-key))
             (verify        (module-ref goblins 'verify))
             (pub-obj       (bv->pub pub-bv)))
        (check "captured signature verifies against bran-derived pubkey"
               (verify sig-bv base pub-obj))))))

(test-summary!)
