;;; module/playnet/push/templates.scm — Notification template DSL
;;;
;;; Declarative notification templates. Each template maps an event
;;; kind to a notification shape (type, title, body, tag) using {field}
;;; interpolation into the event alist.
;;;
;;; Usage:
;;;   (define my-templates
;;;     (make-notification-templates
;;;       '(buffer-status
;;;         #:type   alert
;;;         #:title  "Buffer status"
;;;         #:body   "{spec-id}: {onhand} on hand ({zone} zone)"
;;;         #:tag    "buffer-{spec-id}")
;;;       ...))
;;;
;;;   (my-templates event-alist) → (values type title body tag)

(define-module (playnet push templates)
  #:use-module (ice-9 match)
  #:export (render-template
            make-notification-templates
            identity-formatter))


;;; ── Template interpolation ─────────────────────────────────────────

(define (render-template template event)
  "Replace {field-name} in TEMPLATE with values from EVENT alist."
  (let loop ((s template) (out ""))
    (let ((i (string-index s #\{)))
      (if (not i)
          (string-append out s)
          (let ((j (string-index s #\} i)))
            (if (not j)
                (string-append out s)
                (let* ((field (string->symbol (substring s (+ i 1) j)))
                       (val (assq-ref event field))
                       (str (cond
                             ((not val) "?")
                             ((string? val) val)
                             ((symbol? val) (symbol->string val))
                             ((number? val) (number->string val))
                             (else (format #f "~a" val)))))
                  (loop (substring s (+ j 1))
                        (string-append out (substring s 0 i) str)))))))))


;;; ── Identity formatter ─────────────────────────────────────────────
;;;
;;; ^output-sink calls (formatter datum) before passing to send-message.
;;; By returning the datum unchanged, the adapter receives the raw alist
;;; instead of a serialized string. No serialize→parse round-trip.

(define (identity-formatter datum) datum)


;;; ── Template registry builder ──────────────────────────────────────

(define (make-notification-templates . specs)
  "Build a MULTI-STYLE notification template lookup from declarative specs.

   Each spec:
     (kind #:type t #:tag g #:title s #:body b
           [#:rich-title s #:rich b]        ; email (rich) overrides
           [#:md-title s #:markdown b])     ; telegram/matrix overrides

   #:type (severity; may be a procedure of the event) and #:tag (dedup
   key) are CHANNEL-INDEPENDENT — they belong to the notification, not
   the rendering, so they are shared across every style. #:title/#:body
   are the `terse' (default) rendering; a per-style override falls back
   to terse when absent, so a channel that does not differ costs nothing.

   Returns: (lambda* (event #:optional (style 'terse))
               -> (values type title body tag))
   with style ∈ {terse, rich, markdown}. Unknown kinds -> (values #f #f #f #f)."
  (define (parse spec)
    (let ((kind (car spec)))
      (let loop ((args (cdr spec))
                 (type 'info) (tag "") (title "playnet") (body "")
                 (rich-title #f) (rich #f) (md-title #f) (md #f))
        (match args
          (() (list kind type tag title body rich-title rich md-title md))
          ((#:type v . r)       (loop r v tag title body rich-title rich md-title md))
          ((#:tag v . r)        (loop r type v title body rich-title rich md-title md))
          ((#:title v . r)      (loop r type tag v body rich-title rich md-title md))
          ((#:body v . r)       (loop r type tag title v rich-title rich md-title md))
          ((#:rich-title v . r) (loop r type tag title body v rich md-title md))
          ((#:rich v . r)       (loop r type tag title body rich-title v md-title md))
          ((#:md-title v . r)   (loop r type tag title body rich-title rich v md))
          ((#:markdown v . r)   (loop r type tag title body rich-title rich md-title v))
          ((_ . r)              (loop r type tag title body rich-title rich md-title md))))))
  (let ((table (map parse specs)))
    (lambda* (event #:optional (style 'terse))
      (let* ((kind (assq-ref event 'kind))
             (entry (and kind (assq kind table))))
        (if entry
            (match entry
              ((_ type tag t-title t-body r-title r-body m-title m-body)
               (let ((title-tmpl (case style
                                   ((rich)     (or r-title t-title))
                                   ((markdown) (or m-title t-title))
                                   (else       t-title)))
                     (body-tmpl  (case style
                                   ((rich)     (or r-body t-body))
                                   ((markdown) (or m-body t-body))
                                   (else       t-body))))
                 (values (if (procedure? type) (type event) type)
                         (render-template title-tmpl event)
                         (render-template body-tmpl event)
                         (render-template tag event)))))
            (values #f #f #f #f))))))
