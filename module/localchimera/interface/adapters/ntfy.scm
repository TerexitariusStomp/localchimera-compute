;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/interface/adapters/ntfy.scm — ntfy transport adapter
;;;
;;; The notify layer's adopted channel: ntfy (Apache-2.0) is the push
;;; backend spec/oss-inventory.md names for the notify row — UnifiedPush-
;;; compatible, so a self-hosted ntfy or ntfy.sh both answer the same
;;; wire. Same transport interface as browser/email/matrix: a dumb
;;; adapter that puts a pre-rendered notification on the wire.
;;;
;;; channel-context = the recipient's ntfy topic.
;;;
;;; Where the server lives is the box's own setting:
;;;
;;;   LOCALCHIMERA_NTFY_URL    e.g. https://ntfy.example.org — no default;
;;;                       with it unset `ntfy-transport?' says so and the
;;;                       gateway offers no ntfy channel, exactly the
;;;                       email adapter's convention.
;;;
;;; The delegate seam in module/localchimera/delegates.scm builds the wire;
;;; THIS module owns the one concrete transport the commune runs — an
;;; http-post over Guile's web client — so the seam stops being abstract
;;; the moment the environment names a server.

(define-module (localchimera interface adapters ntfy)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (localchimera notify rendered)
  #:use-module (localchimera delegates)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (^ntfy-adapter ntfy-transport? ntfy-base-url))

(define (setting name)
  (let ((v (getenv name))) (and v (not (string-null? v)) v)))

(define (ntfy-base-url)
  "The configured ntfy server, or #f — no default; the commune names it."
  (setting "LOCALCHIMERA_NTFY_URL"))

(define (ntfy-transport?)
  "True when the box can actually reach an ntfy server — the same honest
   answer email-transport? gives the gateway for its channel."
  (and (ntfy-base-url) #t))

;;; The concrete transport the ntfy delegate consumes: (method path body)
;;; → the server's status line. A post that never lands answers #f — the
;;; router's perform! treats that like any other adapter miss.
(define (ntfy-http-transport method path body)
  (catch #t
    (lambda ()
      (call-with-values
          (lambda ()
            (http-post (string-append (ntfy-base-url) path)
                       #:body (if (bytevector? body) body
                                  (string->utf8 (if (string? body) body
                                                    (format #f "~a" body))))
                       #:headers '((content-type . (text/plain))
                                   (charset . "utf-8"))))
        (lambda (response _) (response-code response))))
    (lambda _ #f)))

(define (^ntfy-adapter _bcom)
  (let ((deliver-to (make-ntfy-delegate ntfy-http-transport)))
    (methods
     ((deliver topic rendered)
      (deliver-to topic (rendered->text rendered)))

     ((send-message topic x)
      (deliver-to topic (if (string? x) x (rendered->text x))))

     ((send-formatted topic blocks)
      (deliver-to topic
                  (string-join
                   (map (lambda (b) (if (string? b) b (format #f "~a" b)))
                        blocks)
                   "\n")))

     ((parse-command raw-text)
      ;; ntfy is publish-only for this channel — nothing comes back.
      (values #f #f)))))
