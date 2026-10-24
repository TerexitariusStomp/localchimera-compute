;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/notify/rendered.scm — the rendered-notification shape.
;;;
;;; The interface between the RENDER stage (localchimera notify registry) and
;;; the TRANSPORT stage (the adapters). A rendered notification is a
;;; channel-independent alist:
;;;
;;;   ((type . <symbol>) (title . <string>) (body . <string>) (tag . <string>))
;;;
;;; Adapters depend on THIS shape, not on the template registry — that is
;;; what makes them dumb: they put pre-rendered fields on the wire and
;;; author nothing. Pure data; no dependency on the templates.

(define-module (localchimera notify rendered)
  #:use-module (ice-9 format)
  #:export (rendered-notification
            rendered?
            rendered-type
            rendered-title
            rendered-body
            rendered-tag
            rendered->text))

(define (rendered-notification type title body tag)
  `((type . ,type) (title . ,title) (body . ,body) (tag . ,tag)))

(define (rendered? x)
  "True if X is a rendered-notification alist (has title + body)."
  (and (pair? x) (pair? (car x))
       (assq 'title x) (assq 'body x) #t))

(define (rendered-type r)  (assq-ref r 'type))
(define (rendered-title r) (assq-ref r 'title))
(define (rendered-body r)  (assq-ref r 'body))
(define (rendered-tag r)   (assq-ref r 'tag))

(define (rendered->text x)
  "Collapse a rendered notification (or a bare string) into ONE text block
   for line-oriented transports (telegram, matrix, repl, sms preview)."
  (if (string? x)
      x
      (let ((title (rendered-title x))
            (body  (rendered-body x)))
        (cond
         ((and title body (string? title) (string? body)
               (not (string-null? title)) (not (string-null? body)))
          (string-append title "\n\n" body))
         ((and body (string? body) (not (string-null? body))) body)
         ((and title (string? title)) title)
         (else (format #f "~a" x))))))
