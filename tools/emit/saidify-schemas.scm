#!/usr/bin/env -S guile -L module -s
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; tools/emit/saidify-schemas.scm — compute SAIDs for ACDC schema files.
;;;
;;; Reads each JSON file in module/localchimera/keri/schemas/, computes the
;;; blake3-256 SAID of the document with `$id` blanked to 44 '#' chars,
;;; and writes the file back with the real SAID substituted into `$id`.
;;;
;;; Idempotent: running on an already-saidified file yields the same
;;; file (the presence of 44 '#'s is the trigger; once replaced, the
;;; function is a no-op and --check will pass).
;;;
;;; Usage:
;;;   guile -L module tools/emit/saidify-schemas.scm           # rewrite in place
;;;   guile -L module tools/emit/saidify-schemas.scm --check   # exit 1 on drift

(use-modules (ice-9 format)
             (ice-9 textual-ports)
             (json)
             (srfi srfi-1)
             (localchimera keri signify)
             ((localchimera keri schemas)
              #:select (%schema-catalog read-schema-alist)))

(define %schema-dir "module/localchimera/keri/schemas")
;; The work list is the catalog: (localchimera keri schemas) is the one
;; place that names the schema set.
(define %schemas (map car %schema-catalog))
;; %saidplaceholder is re-exported from (localchimera keri signify); the tool
;; and the runtime SAID pipeline now share a single 44-`#` constant.
(define %placeholder %saidplaceholder)

;; Explicit UTF-8 on both ports: schemas contain non-ASCII glyphs
;; (e.g. skill.json's "⇒"), and under a C locale the default port
;; encoding silently mangles them to "?" — which rewrites the bytes,
;; changes the SAID, and reads as phantom drift. Pinning the encoding
;; makes the tool locale-independent.
(define (read-file path)
  (call-with-input-file path get-string-all #:encoding "UTF-8"))

(define (write-file path contents)
  (call-with-output-file path
    (lambda (p) (put-string p contents))
    #:encoding "UTF-8"))

(define (blank-id-field alist)
  "Ensure the `$id` field is the 44-# placeholder before saidification.
   Leaves any already-correct placeholder untouched; rewrites any other
   value (including an existing SAID) back to the placeholder so
   saidification recomputes from scratch."
  (map (lambda (pair)
         (if (equal? (car pair) "$id")
             (cons "$id" %placeholder)
             pair))
       alist))

(define (saidify-file name path)
  "Returns (values new-json old-contents said). Order-preserving parse
   comes from the catalog module (read-schema-alist); with -L module
   from the repo root it reads the same file this tool writes back."
  (let* ((raw    (read-file path))
         (alist  (blank-id-field (read-schema-alist name))))
    (call-with-values
        (lambda () (saidify-schema alist))
      (lambda (_final-str said final-alist)
        (values (string-append
                 (scm->json-string final-alist #:pretty #t)
                 "\n")
                raw
                said)))))

(define (main args)
  (let ((check? (member "--check" args))
        (drift  0))
    (for-each
     (lambda (name)
       (let ((path (string-append %schema-dir "/" name)))
         (call-with-values
             (lambda () (saidify-file name path))
           (lambda (new-json old-raw said)
             (format #t "~a  →  ~a~%" name said)
             (cond
              (check?
               (unless (string=? new-json old-raw)
                 (format #t "  DRIFT: ~a is not self-saidified~%" name)
                 (set! drift (+ 1 drift))))
              (else
               (unless (string=? new-json old-raw)
                 (write-file path new-json)
                 (format #t "  wrote ~a bytes~%" (string-length new-json)))))))))
     %schemas)
    (when (and check? (> drift 0))
      (format (current-error-port)
              "~%FAIL: ~a schema file(s) have drifted; run `make schemas`.~%"
              drift)
      (exit 1))))

(main (cdr (command-line)))
