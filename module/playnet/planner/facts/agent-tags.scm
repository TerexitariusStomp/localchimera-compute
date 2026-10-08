;;; agent-tags.scm — the "key:value" tags an agent carries.
;;;
;;; A person's profile reaches the planner as typed tags on their Agent record
;;; ("age:34", "sleep:23:00-07:00", "away:2026-09-28..2026-09-30:sick"). This
;;; module is the one place that reads them: the subsistence context, the
;;; schedule and the labour pool all take a value the same way.
;;;
;;; Pure: no I/O, no mutation. Hoot/WASM compatible.

(define-module (playnet planner facts agent-tags)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner vf schemas)     ; agent-classified-as
  #:export (tag-value tag-values tag-number agent-tag-value agent-tag-values))

(define (prefix-of key) (string-append key ":"))

(define (tag-values tags key)
  "Every value of a \"key:value\" tag in TAGS, in order, as strings."
  (let* ((pfx (prefix-of key)) (n (string-length pfx)))
    (filter-map (lambda (t)
                  (and (string? t) (>= (string-length t) n) (string=? (substring t 0 n) pfx)
                       (substring t n)))
                tags)))

(define (tag-value tags key)
  "The value of the first \"key:value\" tag, as a string, or #f."
  (let ((vs (tag-values tags key))) (and (pair? vs) (car vs))))

(define (tag-number tags key fallback)
  (let* ((v (tag-value tags key)) (n (and v (string->number v))))
    (if (and n (real? n)) n fallback)))

(define (agent-tags a) (or (agent-classified-as a) '()))
(define (agent-tag-value a key) (tag-value (agent-tags a) key))
(define (agent-tag-values a key) (tag-values (agent-tags a) key))
