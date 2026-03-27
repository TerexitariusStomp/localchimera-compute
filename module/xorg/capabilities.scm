;;; module/xorg/capabilities.scm — Capability actor constructors for xorg
;;;
;;; Defines ocap-safe wrappers for HTTP and configuration access.
;;; These actors are the boundary between the org's pure world and
;;; ambient IO — only code that holds a reference can use them.
;;;
;;; Hoot/WASM compatibility: ^config-provider is fully compatible.
;;; ^http-client uses cond-expand to stub out HTTP in WASM contexts.

(define-module (xorg capabilities)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^http-client
            ^config-provider
            make-http-client
            make-config-provider))

;;; ── ^config-provider ───────────────────────────────────────────────────────
;;;
;;; Wraps a static config alist. Fully Hoot-compatible.

(define (^config-provider bcom config-alist)
  "A capability actor wrapping a static configuration alist.
   config-alist: ((key . value) ...)"
  (methods
   [(get key)
    (let ((pair (assq key config-alist)))
      (if pair (cdr pair) #f))]
   [(require key)
    (let ((pair (assq key config-alist)))
      (if pair
          (cdr pair)
          (error "Config key not found:" key)))]
   [(keys)
    (map car config-alist)]))

(define (make-config-provider vat config-alist)
  "Convenience: spawn a ^config-provider in VAT with the given config alist."
  (with-vat vat (spawn ^config-provider config-alist)))

;;; ── ^http-client ───────────────────────────────────────────────────────────
;;;
;;; Wraps HTTP POST/GET to a specific base URL with default headers.
;;; NOT Hoot-compatible — Hoot has no (web client). Uses cond-expand
;;; to provide a stub that errors in WASM contexts.

(cond-expand
  (hoot
   ;; Stub: HTTP is not available in WASM context.
   (define (^http-client bcom base-url default-headers)
     "Stub ^http-client for Hoot/WASM — all operations raise an error."
     (methods
      [(post path body-string)
       (error "HTTP not available in WASM context")]
      [(get path)
       (error "HTTP not available in WASM context")]
      [(base-url) base-url]))

   (define (make-http-client vat base-url default-headers)
     "Convenience: spawn a ^http-client in VAT (stub in WASM)."
     (with-vat vat (spawn ^http-client base-url default-headers))))

  (else
   (use-modules (web client)
                (web response)
                (rnrs bytevectors))

   (define (^http-client bcom base-url default-headers)
     "A capability actor wrapping HTTP to a specific base URL.
      base-url: string like \"https://openrouter.ai/api/v1\"
      default-headers: alist like ((authorization . (bearer sk-...)))"
     (methods
      [(post path body-string)
       (let ((url (string-append base-url path)))
         (call-with-values
             (lambda ()
               (http-post url
                          #:body (string->utf8 body-string)
                          #:headers
                          (cons '(content-type . (application/json))
                                default-headers)
                          #:streaming? #f
                          #:decode-body? #f
                          #:verify-certificate? #f))
           (lambda (response body-bv)
             (if (bytevector? body-bv)
                 (utf8->string body-bv)
                 body-bv))))]
      [(get path)
       (let ((url (string-append base-url path)))
         (call-with-values
             (lambda ()
               (http-get url
                         #:headers default-headers
                         #:streaming? #f
                         #:decode-body? #f
                         #:verify-certificate? #f))
           (lambda (response body-bv)
             (if (bytevector? body-bv)
                 (utf8->string body-bv)
                 body-bv))))]
      [(base-url) base-url]))

   (define (make-http-client vat base-url default-headers)
     "Convenience: spawn a ^http-client in VAT."
     (with-vat vat (spawn ^http-client base-url default-headers)))))
