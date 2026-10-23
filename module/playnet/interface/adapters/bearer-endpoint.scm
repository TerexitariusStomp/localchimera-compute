;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/interface/adapters/bearer-endpoint.scm — a sealed OAuth2 bearer
;;; client for ANY Graph/REST API. The generic core the platform adapters sit on.
;;;
;;; NOT Instagram-specific. Any API that authenticates with a Bearer token reuses
;;; this: Instagram / Threads / Facebook Pages (Meta Graph), X API v2, Bluesky,
;;; YouTube Data, … A platform adapter is then a THIN wrapper that maps its
;;; (post …) to this client's get / post-json / post-form.
;;;
;;;   ^bearer-endpoint — seals (base-url + access-token), never leaks the token,
;;;     and supports HEADLESS refresh so token rotation needs no human. Methods:
;;;       (get path)                → parsed JSON | raw string
;;;       (post-json path alist)    → parsed JSON | raw string
;;;       (post-form path alist)    → parsed JSON | raw string  (x-www-form-urlencoded)
;;;       (refresh!)                → ((ok . bool) …); rotates the sealed token
;;;
;;; The one-time GRANT of the token is a governance/human act (mint a Meta System
;;; User token, authorise an app, …). Everything here — refresh, calls — is
;;; headless and opsec-safe: the token comes from a secret store at spawn time,
;;; never the repo, and stays inside the actor boundary.

(define-module (playnet interface adapters bearer-endpoint)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (web client)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (json)
  #:use-module (playnet utils http-auth)   ; bearer-auth-header + permissive Content-Type writer
  #:export (^bearer-endpoint
            form-encode
            graph-result))

;; form-encode — an x-www-form-urlencoded body from an alist of (string . string).
(define (form-encode params)
  (string-join
   (map (lambda (kv) (string-append (uri-encode (car kv)) "=" (uri-encode (cdr kv)))) params)
   "&"))

;; graph-result — the ONE way a Graph/REST response becomes a uniform publish
;; result: ok + the created id (+ the raw body), or an error. Shared by every
;; publisher so none re-implements the ok/id/error shaping. ID-PATH walks nested
;; objects so X's `.data.id` and Bluesky's `.uri` both work — default `("id")`.
(define* (graph-result parsed #:key (id-path '("id")))
  (let loop ((node parsed) (path id-path))
    (if (and (pair? node) (assoc (car path) node))
        (let ((v (assoc-ref node (car path))))
          (if (null? (cdr path))
              `((ok . #t) (id . ,v) (raw . ,parsed))
              (loop v (cdr path))))
        `((ok . #f) (error . ,parsed)))))

(define (parse-maybe-json s)
  (catch #t (lambda () (json-string->scm s)) (lambda _ s)))

;; refresh: #f, or a procedure (old-token → new-token | #f) that does its own
;; headless HTTP (it holds the old token). Platform-specific endpoint, generic shape.
(define* (^bearer-endpoint bcom base-url token #:key (refresh #f))

  (define (request method path content-type body-bv)
    (let ((url (string-append base-url path)))
      (call-with-values
          (lambda ()
            (if (eq? method 'get)
                (http-get url
                          #:headers (bearer-auth-header token)
                          #:streaming? #f #:decode-body? #f #:verify-certificate? #t)
                (http-post url
                           #:body body-bv
                           #:headers `((content-type . ,content-type) ,@(bearer-auth-header token))
                           #:streaming? #f #:decode-body? #f #:verify-certificate? #t)))
        (lambda (_response body)
          (parse-maybe-json (if (bytevector? body) (utf8->string body) (or body "")))))))

  (methods
    ((get path)
     (request 'get path #f #f))
    ((post-json path body-alist)
     (request 'post path "application/json" (string->utf8 (scm->json-string body-alist))))
    ((post-form path params-alist)
     (request 'post path "application/x-www-form-urlencoded" (string->utf8 (form-encode params-alist))))
    ;; headless token rotation — no human, the sealed capability is replaced in place.
    ((refresh!)
     (if refresh
         (let ((new (refresh token)))
           (if (and (string? new) (> (string-length new) 0))
               (bcom (^bearer-endpoint bcom base-url new #:refresh refresh) `((ok . #t)))
               (bcom (^bearer-endpoint bcom base-url token #:refresh refresh)
                     `((ok . #f) (error . "refresh returned no token")))))
         `((ok . #f) (error . "no refresh configured"))))))
