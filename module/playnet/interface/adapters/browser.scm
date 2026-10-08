;;; module/playnet/interface/adapters/browser.scm — Browser notification adapter
;;;
;;; A DUMB transport: it maps a pre-rendered notification (see
;;; `playnet notify rendered') onto ^user-inbox's `notify'. It authors no
;;; presentation and knows nothing about event kinds or templates — the
;;; render step happens upstream in the sink formatter
;;; (`notification-formatter'), so this adapter just puts fields on the
;;; wire.
;;;
;;;   deliver ctx rendered   — the structured notification path
;;;   send-message ctx x     — freeform: a bare string, or a rendered alist

(define-module (playnet interface adapters browser)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet notify rendered)
  #:export (^browser-adapter))


;;; ── Adapter actor ──────────────────────────────────────────────────

(define (notify! inbox-ref rendered)
  "Map a rendered notification onto ^user-inbox 'notify."
  (let ((type  (or (rendered-type rendered) 'info))
        (title (or (rendered-title rendered) "playnet"))
        (body  (or (rendered-body rendered) ""))
        (tag   (or (rendered-tag rendered) "")))
    (<-np inbox-ref 'notify type title body
          (if (and (string? tag) (not (string-null? tag)))
              `((tag . ,tag))
              '()))))

(define (^browser-adapter _bcom)
  (methods
   ((deliver inbox-ref rendered)
    (notify! inbox-ref rendered))
   ((send-message inbox-ref x)
    (if (string? x)
        (<-np inbox-ref 'notify 'alert "playnet" x '())
        (notify! inbox-ref x)))
   ((send-formatted inbox-ref blocks)
    (<-np inbox-ref 'notify 'alert "playnet"
          (string-join
           (map (lambda (b) (if (string? b) b (format #f "~a" b))) blocks)
           "\n")
          '()))
   ((parse-command raw-text)
    (values #f #f))))
