;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/monero/rpc-digest.scm — HTTP Digest auth over (web client)
;;;
;;; monero-wallet-rpc negotiates HTTP Digest when --rpc-login is set;
;;; Guile's (web client) has no built-in Digest support, so we implement
;;; RFC 2617 (qop=auth) on top of it. MD5 comes from (gcrypt hash).
;;;
;;; Usage:
;;;
;;;   (use-modules (localchimera monero rpc-digest))
;;;   (define creds (make-digest-creds "localchimera" "s3cr3t"))
;;;   (json-rpc-call "http://127.0.0.1:18082/json_rpc" creds
;;;                  "get_balance" '((account_index . 0)))
;;;
;;; Two-phase flow:
;;;
;;;   1. Send the request with no auth → server replies 401 + WWW-Authenticate
;;;      carrying a realm, nonce, qop, etc.
;;;   2. Parse the challenge, compute the response digest, resend with the
;;;      Authorization header. Server replies 200 + JSON-RPC body.
;;;
;;; The challenge is cached per (creds, realm, nonce) so subsequent calls
;;; skip phase 1 until the server rotates the nonce (triggering a 401 again).

(define-module (localchimera monero rpc-digest)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:use-module (ice-9 regex)
  #:use-module (json)
  #:use-module (gcrypt hash)
  #:use-module (localchimera utils http-auth)
  #:export (make-digest-creds
            digest-creds?
            digest-creds-user
            digest-creds-password
            parse-www-authenticate
            build-authorization-header
            json-rpc-call
            ;; For testing:
            md5-hex
            make-cnonce))

;;; ── Credentials ───────────────────────────────────────────────────────────

(define-record-type <digest-creds>
  (%make-digest-creds user password)
  digest-creds?
  (user     digest-creds-user)
  (password digest-creds-password))

(define (make-digest-creds user password)
  "Create a credentials record."
  (%make-digest-creds user password))

;;; ── MD5 helpers ───────────────────────────────────────────────────────────

(define (md5-hex str)
  "Return the lowercase hex MD5 of STR (a string)."
  (bv->hex (md5 (string->utf8 str))))

(define (bv->hex bv)
  (string-concatenate
   (map (lambda (i)
          (format #f "~2,'0x" (bytevector-u8-ref bv i)))
        (iota (bytevector-length bv)))))

(define %cnonce-chars
  "0123456789abcdef")

(define (make-cnonce)
  "Generate a 16-char hex client nonce. Uses /dev/urandom when available,
falls back to (random) for portability."
  (catch #t
    (lambda ()
      (call-with-input-file "/dev/urandom"
        (lambda (port)
          (let ((bv (get-bytevector-n port 8)))
            (bv->hex bv)))))
    (lambda _
      (list->string
       (map (lambda (_)
              (string-ref %cnonce-chars (random 16)))
            (iota 16))))))

;;; ── Challenge parsing ─────────────────────────────────────────────────────
;;;
;;; WWW-Authenticate: Digest realm="...", nonce="...", qop="auth", ...
;;;
;;; The header may arrive either as a string (Guile usually does this for
;;; unknown schemes) or as a parsed value depending on version. We handle
;;; both forms.

(define (header-value->string v)
  (cond
   ((string? v) v)
   ((pair? v)
    ;; ('digest . "realm=...,nonce=...") or similar
    (cond
     ((symbol? (car v))
      (let ((rest (cdr v)))
        (if (string? rest)
            (string-append (symbol->string (car v)) " " rest)
            (string-append (symbol->string (car v)) " "
                           (format #f "~a" rest)))))
     (else (format #f "~a" v))))
   (else (format #f "~a" v))))

(define %digest-prefix-rx
  (make-regexp "^[Dd]igest[[:space:]]+"))

(define (strip-digest-prefix s)
  (let ((m (regexp-exec %digest-prefix-rx s)))
    (if m (substring s (match:end m)) s)))

(define (parsed-digest-challenge header)
  "Guile's (web http) hands WWW-Authenticate back already parsed: a list
of challenges, each (SCHEME (key . value) ...) with symbol keys. Return
the params alist of the digest challenge to answer, or #f when HEADER is
some other shape. monero-wallet-rpc offers MD5 and MD5-sess side by side;
build-authorization-header computes plain MD5, so that one is chosen."
  (and (pair? header)
       (let* ((challenges (filter (lambda (c)
                                    (and (pair? c)
                                         (eq? (car c) 'digest)
                                         (list? (cdr c))
                                         (every pair? (cdr c))))
                                  header))
              (md5 (find (lambda (c)
                           (let ((algo (assq-ref (cdr c) 'algorithm)))
                             (or (not algo) (string-ci=? algo "MD5"))))
                         challenges)))
         (cond (md5 (cdr md5))
               ((pair? challenges) (cdr (car challenges)))
               (else #f)))))

(define (parse-www-authenticate header)
  "Parse a WWW-Authenticate Digest challenge into an alist keyed by
symbol (realm, nonce, qop, algorithm, opaque, stale)."
  (or (parsed-digest-challenge header)
      (let* ((s (strip-digest-prefix (header-value->string header))))
        (parse-digest-params s))))

(define (parse-digest-params s)
  "Parse comma-separated k=v or k=\"v\" pairs into an alist keyed by
symbol."
  (let loop ((i 0)
             (len (string-length s))
             (acc '()))
    (cond
     ((>= i len) (reverse acc))
     ((char-whitespace? (string-ref s i))
      (loop (+ i 1) len acc))
     ((char=? (string-ref s i) #\,)
      (loop (+ i 1) len acc))
     (else
      (let ((eq-pos (string-index s #\= i)))
        (if (not eq-pos)
            (reverse acc)
            (let* ((key (string->symbol
                         (string-trim-both (substring s i eq-pos))))
                   (vstart (+ eq-pos 1)))
              (call-with-values
                  (lambda () (read-param-value s vstart len))
                (lambda (val next)
                  (loop next len (cons (cons key val) acc)))))))))))

(define (read-param-value s start len)
  "Read a single parameter value starting at START, returning (value,
next-index). Handles both quoted and unquoted forms."
  (if (and (< start len) (char=? (string-ref s start) #\"))
      ;; Quoted: find the closing quote.
      (let loop ((i (+ start 1)))
        (cond
         ((>= i len) (values (substring s (+ start 1) len) len))
         ((char=? (string-ref s i) #\")
          (values (substring s (+ start 1) i) (+ i 1)))
         (else (loop (+ i 1)))))
      ;; Unquoted: read until comma or end.
      (let ((comma (string-index s #\, start)))
        (if comma
            (values (string-trim-both (substring s start comma)) comma)
            (values (string-trim-both (substring s start len)) len)))))

;;; ── Response construction ─────────────────────────────────────────────────
;;;
;;; RFC 2617 §3.2.2.1 — HA1 = MD5(user ":" realm ":" password)
;;;                      HA2 = MD5(method ":" uri)
;;;         response = MD5(HA1 ":" nonce ":" nc ":" cnonce ":" qop ":" HA2)

(define (build-authorization-header creds challenge method uri nc cnonce)
  "Compute the Authorization header string for the given challenge.
Returns a string suitable for an HTTP header value."
  (let* ((realm  (assq-ref challenge 'realm))
         (nonce  (assq-ref challenge 'nonce))
         (qop    (or (assq-ref challenge 'qop) "auth"))
         (algo   (or (assq-ref challenge 'algorithm) "MD5"))
         (opaque (assq-ref challenge 'opaque))
         (user   (digest-creds-user creds))
         (pass   (digest-creds-password creds))
         (ha1    (md5-hex (string-append user ":" realm ":" pass)))
         (ha2    (md5-hex (string-append method ":" uri)))
         (resp   (md5-hex
                  (string-append ha1 ":" nonce ":" nc ":" cnonce
                                 ":" qop ":" ha2))))
    (string-append
     "Digest "
     "username=\"" user "\", "
     "realm=\"" realm "\", "
     "nonce=\"" nonce "\", "
     "uri=\"" uri "\", "
     "algorithm=" algo ", "
     "qop=" qop ", "
     "nc=" nc ", "
     "cnonce=\"" cnonce "\", "
     "response=\"" resp "\""
     (if opaque (string-append ", opaque=\"" opaque "\"") ""))))

;;; ── JSON-RPC entry point ──────────────────────────────────────────────────

(define (parse-uri-path url)
  "Return just the path+query portion of URL for use in the Digest uri
field (which is scope-relative)."
  (let ((u (string->uri url)))
    (if u
        (let ((p (uri-path u))
              (q (uri-query u)))
          (if q (string-append p "?" q) p))
        url)))

;;; monero-wallet-rpc (epee) ties a Digest nonce to the TCP connection that
;;; issued it: an Authorization sent over any other connection meets a 401,
;;; whatever its arithmetic. So one call is one connection — the
;;; unauthenticated probe draws the challenge, the answer follows on the same
;;; kept-alive port, and the nonce count starts at 1 each time.

(define (http-post-body url port body headers)
  "POST BODY to URL over the open PORT, kept alive. Returns the response
and its body as a UTF-8 string."
  (call-with-values
      (lambda ()
        (http-post url
                   #:port port
                   #:keep-alive? #t
                   #:body (string->utf8 body)
                   #:headers headers
                   #:streaming? #f
                   #:decode-body? #f))
    (lambda (response body-bv)
      (values response
              (if (bytevector? body-bv) (utf8->string body-bv) body-bv)))))

(define (json-rpc-call url creds method params)
  "Call a JSON-RPC 2.0 method over HTTP Digest auth. Returns the parsed
JSON response alist (the top-level envelope including 'result' or
'error' fields). Signals an error if HTTP fails or Digest auth cannot
be negotiated."
  (let* ((uri-path (parse-uri-path url))
         (body-alist `(("jsonrpc" . "2.0")
                       ("id" . "0")
                       ("method" . ,method)
                       ("params" . ,(or params '()))))
         (body-str (scm->json-string body-alist))
         (base-headers '((content-type . (application/json))))
         (port (open-socket-for-uri (string->uri url))))

    (define (do-request auth-header)
      (http-post-body
       url port body-str
       (if auth-header
           (cons `(authorization . ,auth-header) base-headers)
           base-headers)))

    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (call-with-values
            (lambda () (do-request #f))
          (lambda (response body)
            (cond
             ((= (response-code response) 200)
              (json-string->scm body))

             ((= (response-code response) 401)
              (let* ((www (assq-ref (response-headers response) 'www-authenticate))
                     (challenge (and www (parse-www-authenticate www))))
                (unless challenge
                  (error "monero-wallet-rpc 401 with no WWW-Authenticate header"))
                (let ((auth (build-authorization-header
                             creds challenge "POST" uri-path
                             "00000001" (make-cnonce))))
                  (call-with-values
                      (lambda () (do-request auth))
                    (lambda (response2 body2)
                      (if (= (response-code response2) 200)
                          (json-string->scm body2)
                          (error (format #f "monero-wallet-rpc auth failed: ~a ~a"
                                         (response-code response2) body2))))))))
             (else
              (error (format #f "monero-wallet-rpc HTTP ~a: ~a"
                             (response-code response) body)))))))
      (lambda ()
        (false-if-exception (close-port port))))))
