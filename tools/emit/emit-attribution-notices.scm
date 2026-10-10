#!/usr/bin/env -S guile -L module
!#
;;; tools/emit/emit-attribution-notices.scm — the shipped RID token, written into
;;; every place that quotes it outside the browser's own TS/JS.
;;;
;;;   emit-attribution-notices.scm check            exit 1 if any target is stale
;;;   emit-attribution-notices.scm write             rewrite every target in place
;;;
;;; module/playnet/knowledge/law/product.scm's `attribution` notice is
;;; already the one source for ui/app/legal-product.ts (tools/emit/emit-product-law.scm).
;;; Two more places quote the RID that string carries, verbatim or bare, and
;;; were hand-edited until now: LICENSE-ADDITIONAL-TERMS.md (the full quoted
;;; sentence Section 7b asks every deployment to preserve) and the footer of
;;; browser/info/index.html (the bare token alone). The app itself shows the
;;; sentence through ui/app/legal-product.ts, which is the first emitter's. This
;;; touches only the `rad:<id>` TOKEN in each — never the prose around it —
;;; so it rewrites cleanly regardless of how each file phrases its own
;;; sentence, including across a Radicle RID transition (the reason this
;;; exists: see docs/planning/*.local.md, "what depends on the current RID").
;;;
;;; `make check-attribution-fresh` is in test-fast; `make attribution-emit`
;;; writes. Silent regen is deliberate here, unlike a from-scratch generated
;;; file: every target already carries its OWN surrounding prose, hand-written
;;; and reviewed on its own terms — this changes only the token.

(use-modules (playnet knowledge law product)
             (ice-9 textual-ports) (ice-9 regex))

(define RID-RE (make-regexp "rad:[A-Za-z0-9]+"))

(define (canonical-rid)
  (let ((m (regexp-exec RID-RE (product-notice 'attribution))))
    (unless m (error "attribution notice carries no rad:<id> token"))
    (match:substring m)))

(define TARGETS '("LICENSE-ADDITIONAL-TERMS.md" "browser/info/index.html"))

(define (slurp path)
  (call-with-input-file path get-string-all))

(define (rewritten text rid)
  (regexp-substitute/global #f RID-RE text 'pre rid 'post))

(define (report)
  (let ((rid (canonical-rid)))
    (map (lambda (path)
           (let* ((text (slurp path)) (m (regexp-exec RID-RE text)))
             (list path
                   (and m (match:substring m))
                   (rewritten text rid))))
         TARGETS)))

(define (main)
  (let ((mode (if (> (length (command-line)) 1) (cadr (command-line)) "check")))
    (cond
     ((string=? mode "check")
      (let ((rid (canonical-rid)) (bad #f))
        (for-each
         (lambda (row)
           (let ((path (car row)) (found (cadr row)))
             (cond
              ((not found)
               (set! bad #t)
               (format #t "check-attribution-fresh: ~a carries no rad:<id> token~%" path))
              ((not (string=? found rid))
               (set! bad #t)
               (format #t "check-attribution-fresh: ~a has ~a, canonical is ~a — run: make attribution-emit~%"
                       path found rid))
              (else
               (format #t "check-attribution-fresh: ~a matches (~a)~%" path rid)))))
         (report))
        (exit (if bad 1 0))))
     ((string=? mode "write")
      (for-each
       (lambda (row)
         (let ((path (car row)) (new-text (caddr row)))
           (call-with-output-file path
             (lambda (port) (set-port-encoding! port "UTF-8") (put-string port new-text)))
           (format #t "wrote ~a~%" path)))
       (report)))
     (else (error "usage: emit-attribution-notices.scm [check|write]")))))

(main)
