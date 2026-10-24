;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/utils/http-auth.scm — Permissive Authorization writer
;;;
;;; Guile's stock `Authorization` header writer (in (web http)) only
;;; accepts two shapes:
;;;   ('basic . <string>)              for Basic auth
;;;   (<scheme-symbol> . <kv-list>)    for digest-style schemes
;;;
;;; Neither models OAuth Bearer (`Bearer <opaque-token>`), and neither
;;; matches the bare-string form `(authorization . "Bearer …")` /
;;; `(authorization . "Digest …")` we use for vpsbg, monero RPC, and
;;; the LLM key-pool. Without a fix, every outbound call with one of
;;; those headers fails inside Guile's validator before a single byte
;;; reaches the wire.
;;;
;;; Importing this module redeclares the `Authorization` header once
;;; with a writer that handles three input shapes:
;;;   <string>                          — emitted verbatim
;;;   (<scheme-symbol> . <string>)      — emits "<Scheme> <token>"
;;;   ('basic . <kv-list>) etc.         — falls back to Guile's stock
;;;
;;; The redeclaration is idempotent: any number of modules can import
;;; this and the last writer wins (they're all the same).

(define-module (localchimera utils http-auth)
  #:use-module (web http)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (bearer-auth-header
            basic-auth-header))

(declare-header! "Authorization"
  ;; Inbound parsing: we don't authenticate inbound requests in this
  ;; codebase, so just carry the raw string.
  (lambda (str) str)
  ;; Validation: accept anything we know how to write below.
  (lambda (val)
    (or (string? val)
        (and (pair? val) (symbol? (car val)) (string? (cdr val)))))
  ;; Writer: dispatch on the shape.
  (lambda (val port)
    (cond
     ((string? val)
      (display val port))
     ((and (pair? val) (symbol? (car val)) (string? (cdr val)))
      (display (string-titlecase (symbol->string (car val))) port)
      (display #\space port)
      (display (cdr val) port)))))

;; Guile's stock Accept and Content-Type writers expect structured
;; alists (q-list of media-type sexps). For talking to JSON APIs we
;; only ever want to send a bare string like "application/json", so
;; redeclare both headers to WRITE either shape — a caller's bare string
;; verbatim, a native media-type list reconstructed. The PARSER stays
;; native for Content-Type: declare-header! is process-wide, and every
;; JSON response this process reads (the witness relay's peer poll, the
;; telegram/matrix adapters, monero RPC) goes through guile's response
;; reader, which hands the parsed value to code expecting the native
;; (type (param . val) …) list — a raw-string parse crashed all of them
;; the moment this module loaded first.
(define (parse-media-type str)
  (let* ((parts (map string-trim-both (string-split str #\;)))
         (params (filter-map
                  (lambda (part)
                    (let ((i (string-index part #\=)))
                      (and i (cons (string->symbol
                                    (string-downcase (substring part 0 i)))
                                   (substring part (+ i 1))))))
                  (cdr parts))))
    (cons (string->symbol (string-downcase (car parts))) params)))

(define (write-media-type val port)
  (cond
   ((string? val) (display val port))
   ((pair? val)
    (display (car val) port)
    (for-each (lambda (kv)
                (display ";" port) (display (car kv) port)
                (display "=" port) (display (cdr kv) port))
              (cdr val)))))

(define (media-type-header? val)
  (or (string? val) (and (pair? val) (symbol? (car val)))))

(declare-header! "Content-Type" parse-media-type media-type-header? write-media-type)
;; Accept is a request header this process never reads inbound; the raw
;; parse stays, the writer takes both shapes like Content-Type's.
(declare-header! "Accept" (lambda (str) str) media-type-header? write-media-type)

(define (bearer-auth-header key-string)
  "Build a Bearer Authorization headers alist suitable for http-post."
  `((authorization . (bearer . ,key-string))))

(define (basic-auth-header user-pass-string)
  "Build a Basic Authorization headers alist (string is base64(user:pass))."
  `((authorization . (basic . ,user-pass-string))))
