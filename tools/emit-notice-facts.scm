#!/usr/bin/env -S guile -L module
!#
;;; tools/emit-notice-facts.scm — the figures the notices quote, written into them
;;;
;;;   emit-notice-facts.scm check      exit 1 if any marked figure is stale
;;;   emit-notice-facts.scm write      rewrite every marked figure in place
;;;
;;; module/playnet/planner/knowledge/law/product.scm states the notices' own
;;; figures (version, effective date, the age floor, how often logs rotate, the
;;; breach window, the speech model's size, the notice period for a change).
;;; The pages quote them in running prose, so each quotation is marked where it
;;; stands —
;;;
;;;     <b data-fact="document-version">1.1.0</b>
;;;
;;; — and this rewrites only the TEXT between the marked tag's own open and close,
;;; never the prose around it. The page stays plain static HTML: no script is
;;; needed to read it, and a reader without one sees the same figures.
;;; A marker naming a fact product.scm does not state is an error, so a typo in
;;; a page cannot pass for a figure. `make check-notice-facts-fresh` is in
;;; test-fast; `make notice-facts-emit` writes.

(use-modules (playnet planner knowledge law product)
             (ice-9 textual-ports) (ice-9 regex) (srfi srfi-1))

(define TARGETS '("browser/terms.html" "browser/privacy.html"))

;; <tag … data-fact="KEY" …>TEXT</tag>, TEXT having no markup of its own
(define FACT-RE
  (make-regexp "(<([a-z]+)[^>]* data-fact=\"([a-z-]+)\"[^>]*>)([^<]*)(</[a-z]+>)"))

(define (fact-text key)
  (let ((v (product-notice (string->symbol key))))
    (unless v (error "notice marks a fact product.scm does not state:" key))
    (if (number? v) (number->string v) v)))

(define (slurp path) (call-with-input-file path get-string-all))

(define (rewritten text)
  (regexp-substitute/global
   #f FACT-RE text
   'pre (lambda (m) (string-append (match:substring m 1) (fact-text (match:substring m 3)) (match:substring m 5)))
   'post))

(define (main)
  (let ((mode (if (> (length (command-line)) 1) (cadr (command-line)) "check")))
    (cond
     ((string=? mode "check")
      (let ((stale (filter (lambda (path)
                             (let ((text (slurp path)))
                               (not (string=? text (rewritten text)))))
                           TARGETS)))
        (if (null? stale)
            (format #t "notice facts: every marked figure matches product.scm~%")
            (begin (format #t "notice facts stale in: ~a — run `make notice-facts-emit`~%"
                           (string-join stale ", "))
                   (exit 1)))))
     ((string=? mode "write")
      (for-each (lambda (path)
                  (let* ((text (slurp path)) (new (rewritten text)))
                    (unless (string=? text new)
                      (call-with-output-file path (lambda (p) (display new p)))
                      (format #t "rewrote ~a~%" path))))
                TARGETS))
     (else (format #t "usage: emit-notice-facts.scm check|write~%") (exit 2)))))

(main)
