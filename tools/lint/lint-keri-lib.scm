#!/usr/bin/env -S guile --no-auto-compile -e main -s
!#
;;; lint-keri-lib.scm — the import gate for the KERI library boundary.
;;;
;;; module/playnet/keri/ is a self-contained Guile KERI/ACDC/Signify library
;;; (docs/planning/identity/keri-openvtc-library-split.md). This gate holds that: every
;;; file in the library names only library modules and a short list of
;;; dependency-free support modules. Playnet wiring that speaks KERI lives in
;;; module/playnet/keys/ and imports the library from outside.
;;;
;;; A module name counts wherever it appears in CODE — a #:use-module, a
;;; use-modules, or a quoted '(playnet …) handed to resolve-module / @ / @@ —
;;; so a lazy import is held to the same rule as a static one. Comments and
;;; strings are prose and pass freely.
;;;
;;;   tools/lint/lint-keri-lib.scm              gate: exit 1 on any outside import
;;;   tools/lint/lint-keri-lib.scm --manifest   the published path set, one per line
;;;
;;; Run from the repo root.

(use-modules (ice-9 ftw) (ice-9 match) (ice-9 format) (srfi srfi-1))

(define %lib-dir "module/playnet/keri")
(define %first-person-dir "module/playnet/keri/first-person")

;; Dependency-free modules the library stands on; they ship with it.
(define %support
  '(((playnet utils clock)  . "module/playnet/utils/clock.scm")
    ((playnet utils hex)    . "module/playnet/utils/hex.scm")
    ((playnet utils common) . "module/playnet/utils/common.scm")
    ((playnet utils said-store) . "module/playnet/utils/said-store.scm")
    ((playnet test harness) . "module/playnet/test/harness.scm")))

(define (scm-files dir)
  (if (file-exists? dir)
      (map (lambda (f) (string-append dir "/" f))
           (sort (or (scandir dir (lambda (f) (string-suffix? ".scm" f))) '())
                 string<?))
      '()))

(define (read-forms file)
  (call-with-input-file file
    (lambda (p)
      (let loop ((acc '()))
        (let ((f (read p)))
          (if (eof-object? f) (reverse acc) (loop (cons f acc))))))))

(define (playnet-names form)
  "Every (playnet sym …) list of symbols anywhere inside FORM."
  (let walk ((x form) (acc '()))
    (cond
     ((and (pair? x) (eq? (car x) 'playnet) (list? x) (pair? (cdr x))
           (every symbol? x))
      (cons x acc))
     ((pair? x) (walk (cdr x) (walk (car x) acc)))
     ((vector? x) (walk (vector->list x) acc))
     (else acc))))

(define (names-in file)
  (delete-duplicates (append-map (lambda (f) (playnet-names f)) (read-forms file))))

(define (lib-name? n allowed-roots)
  (or (assoc n %support)
      (any (lambda (root)
             (and (>= (length n) (length root))
                  (equal? (list-head n (length root)) root)))
           allowed-roots)))

(define (check files allowed-roots label)
  "Return the list of (file . outside-name) violations."
  (append-map
   (lambda (file)
     (filter-map (lambda (n) (and (not (lib-name? n allowed-roots)) (cons file n)))
                 (names-in file)))
   files))

(define (pure-tests dir allowed-roots)
  (filter (lambda (f) (null? (check (list f) allowed-roots "")))
          (scm-files dir)))

(define (main args)
  (let* ((keri-files    (scm-files %lib-dir))
         (openvtc-files (scm-files %first-person-dir))
         (support-files (map cdr %support))
         ;; the KERI library stands alone; the OpenVTC layer stands on it
         (bad (append (check keri-files    '((playnet keri)) "keri")
                      (check openvtc-files '((playnet keri)) "first-person")
                      (check support-files '() "support"))))
    (cond
     ((member "--manifest" args)
      (for-each (lambda (f) (display f) (newline))
                (append keri-files openvtc-files support-files
                        (list "module/playnet/keri/schemas")
                        (pure-tests "tests/keri" '((playnet keri))))))
     ((null? bad)
      (format #t "keri-lib gate: ~a library + ~a first-person + ~a support files, every import inside the boundary\n"
              (length keri-files) (length openvtc-files) (length support-files)))
     (else
      (for-each (lambda (v) (format #t "~a: outside import ~s\n" (car v) (cdr v))) bad)
      (format #t "keri-lib gate: ~a import(s) reach outside the library\n" (length bad))
      (exit 1)))))
