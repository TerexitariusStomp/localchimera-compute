#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; doc-cites.scm — a planning document's code cites resolve against the tree
;;;
;;; A map "read off the code" is a set of claims that a name lives at a line
;;; of a file.  Each claim is true on the day of the reading and rots with the
;;; next edit; the header date says when it was true and nothing holds it
;;; past that.  This lint holds it: every cite in the document is resolved
;;; against the working tree, and the run refuses when one is stale, so the
;;; document's claim "every cite is of this reading" is a property the tree
;;; checks rather than a promise.
;;;
;;; Three cite forms are read, and each carries its file:
;;;
;;;   `path/to/file.scm:NNN`          the file exists and has a line NNN
;;;   `name` (`path/to/file.scm:NNN`) as above, and NAME's first token appears
;;;                                   on lines NNN-1 .. NNN+3 of the file
;;;   `path/to/file.ext`              the file exists (a bare file cite)
;;;
;;; A path is a suffix of exactly one tracked file; a suffix that fits several
;;; (`service.scm` fits two) is refused as ambiguous, so a cite always says
;;; which file it means.  Files under docs/ and module/, tools/, server/,
;;; hoot/, ui/, tests/ resolve; a bare name with no slash and no extension is
;;; prose, and prose is left alone.
;;;
;;; Tables pinned to code (opt-in per document, by a marker line):
;;;
;;;   <!-- doc-cites: folds = make-scope-nodes -->
;;;
;;; reads the constructor field list of <scope-nodes> in doors/service.scm
;;; and requires the first word of every row's first cell in the two tables
;;; that follow the marker (the folds, then the descents) to be exactly those
;;; fields, in order.  Adding a fold is then one field, one spec, one row.
;;;
;;; Usage:
;;;   guile --no-auto-compile tools/lint/doc-cites.scm DOC.md ...
;;;
;;; Exit code 0 = every cite resolves, 1 = at least one is stale.

(use-modules (ice-9 ftw)
             (ice-9 match)
             (ice-9 rdelim)
             (ice-9 regex)
             (srfi srfi-1)
             (srfi srfi-13))

;;; ── The tree ────────────────────────────────────────────────────────────────

(define %roots '("module" "tools" "server" "hoot" "ui" "tests" "docs" "deploy" "browser"))

(define (tree-files)
  "Every file under the cited roots, as a repo-relative path."
  (append-map
   (lambda (root)
     (if (file-exists? root)
         (let ((acc '()))
           (ftw root (lambda (path stat flag)
                       (when (eq? flag 'regular) (set! acc (cons path acc)))
                       #t))
           acc)
         '()))
   %roots))

(define %files (tree-files))

(define (resolve-path suffix)
  "The one tracked file whose path ends in SUFFIX at a path-component
boundary; 'ambiguous when several fit, #f when none."
  (let* ((hits (filter (lambda (p)
                         (or (string=? p suffix)
                             (string-suffix? (string-append "/" suffix) p)))
                       %files)))
    (cond ((null? hits) #f)
          ((null? (cdr hits)) (car hits))
          (else 'ambiguous))))

(define %line-cache (make-hash-table))
(define (file-lines path)
  (or (hash-ref %line-cache path)
      (let ((lines (call-with-input-file path
                     (lambda (port)
                       (let loop ((acc '()))
                         (let ((l (read-line port)))
                           (if (eof-object? l)
                               (list->vector (reverse acc))
                               (loop (cons l acc)))))))))
        (hash-set! %line-cache path lines)
        lines)))

;;; ── Cites ───────────────────────────────────────────────────────────────────

;; `name` (`path:NNN`)
(define rx-named (make-regexp "`([^`]+)` \\(`([A-Za-z0-9_./-]+\\.[a-z]+):([0-9]+)`\\)"))
;; `path:NNN`
(define rx-lined (make-regexp "`([A-Za-z0-9_./-]+\\.[a-z]+):([0-9]+)`"))
;; `path.ext` — a slash or a known extension marks it as a file cite
(define rx-file  (make-regexp "`([A-Za-z0-9_./-]+\\.(scm|ts|md|mjs|typ|lean|sh|py|js))`"))

(define (first-token s)
  (car (string-tokenize s (char-set-complement (char-set #\space)))))

(define (check-line-exists path n where)
  (let ((lines (file-lines path)))
    (if (<= n (vector-length lines)) '()
        (list (format #f "~a: `~a:~a` — the file has ~a lines" where path n (vector-length lines))))))

(define (check-name-near path n name where)
  (let* ((lines (file-lines path))
         (tok   (first-token name))
         (lo    (max 0 (- n 2)))
         (hi    (min (vector-length lines) (+ n 3))))
    (if (any (lambda (i) (string-contains (vector-ref lines i) tok))
             (iota (- hi lo) lo))
        '()
        (list (format #f "~a: `~a` is on none of lines ~a..~a of ~a" where tok (+ lo 1) hi path)))))

(define (relative-to doc suffix)
  "SUFFIX, a `./x` or `../x` cite, as the repo-relative path it names from the
directory of DOC; #f for any other cite."
  (and (or (string-prefix? "../" suffix) (string-prefix? "./" suffix))
       (let loop ((dir (reverse (string-split (dirname doc) #\/))) (rest (string-split suffix #\/)))
         (cond ((null? rest) (string-join (reverse dir) "/"))
               ((string=? (car rest) "..") (and (pair? dir) (loop (cdr dir) (cdr rest))))
               ((string=? (car rest) ".") (loop dir (cdr rest)))
               (else (loop (cons (car rest) dir) (cdr rest)))))))

(define* (check-path suffix where #:optional (doc #f))
  "Resolved path, or a refusal string. A `../` cite is read from the directory of DOC."
  (let ((p (let ((rel (and doc (relative-to doc suffix))))
             (if rel
                 (and (file-exists? rel) rel)
                 (resolve-path suffix)))))
    (cond ((eq? p 'ambiguous) (format #f "~a: `~a` fits several files; say which" where suffix))
          ((not p) (format #f "~a: `~a` is no file in the tree" where suffix))
          (else p))))

(define (all-matches rx s)
  (let loop ((start 0) (acc '()))
    (let ((m (regexp-exec rx s start)))
      (if m (loop (match:end m) (cons m acc)) (reverse acc)))))

(define (check-cites doc)
  "Every refusal in DOC's cites."
  (let ((lines (file-lines doc)))
    (append-map
     (lambda (i)
       (let* ((line  (vector-ref lines i))
              (where (format #f "~a:~a" doc (+ i 1)))
              (named (all-matches rx-named line))
              ;; a lined cite inside a named one is the same cite; keep the rest
              (named-spans (map (lambda (m) (cons (match:start m) (match:end m))) named))
              (inside? (lambda (m) (any (lambda (sp) (and (>= (match:start m) (car sp))
                                                          (<= (match:end m) (cdr sp))))
                                        named-spans)))
              (lined (remove inside? (all-matches rx-lined line)))
              (lined-spans (append named-spans
                                   (map (lambda (m) (cons (match:start m) (match:end m))) lined)))
              (inside-any? (lambda (m) (any (lambda (sp) (and (>= (match:start m) (car sp))
                                                              (<= (match:end m) (cdr sp))))
                                            lined-spans)))
              (files (remove inside-any? (all-matches rx-file line))))
         (append
          (append-map
           (lambda (m)
             (let ((name (match:substring m 1))
                   (p    (check-path (match:substring m 2) where doc))
                   (n    (string->number (match:substring m 3))))
               (if (string? p)
                   (if (file-exists? p)
                       (append (check-line-exists p n where)
                               (if (null? (check-line-exists p n where))
                                   (check-name-near p n name where) '()))
                       (list p))
                   (list p))))
           named)
          (append-map
           (lambda (m)
             (let ((p (check-path (match:substring m 1) where doc))
                   (n (string->number (match:substring m 2))))
               (if (and (string? p) (file-exists? p))
                   (check-line-exists p n where)
                   (list p))))
           lined)
          (append-map
           (lambda (m)
             (let ((p (check-path (match:substring m 1) where doc)))
               (if (and (string? p) (file-exists? p)) '() (list p))))
           files))))
     (iota (vector-length lines)))))

;;; ── Tables pinned to the record ─────────────────────────────────────────────

(define rx-marker (make-regexp "<!-- doc-cites: folds = make-scope-nodes -->"))

(define (scope-nodes-fields)
  "The constructor's field names, read off doors/service.scm textually."
  (let* ((lines (file-lines "module/playnet/doors/service.scm"))
         (n     (vector-length lines))
         (ctor  (let loop ((i 0))
                  (cond ((>= i n) #f)
                        ((string-contains (vector-ref lines i) "(make-scope-nodes ")
                         (vector-ref lines i))
                        (else (loop (+ i 1)))))))
    (and ctor
         (let* ((m (regexp-exec (make-regexp "\\(make-scope-nodes ([^)]*)\\)") ctor)))
           (and m (string-tokenize (match:substring m 1)))))))

(define (table-first-words lines start)
  "First word of the first cell of every body row of the table beginning at
or after START; returns (words . index-after-table)."
  (let* ((n (vector-length lines))
         (head (let loop ((i start))
                 (cond ((>= i n) #f)
                       ((string-prefix? "|" (vector-ref lines i)) i)
                       (else (loop (+ i 1)))))))
    (if (not head) (cons '() n)
        (let loop ((i (+ head 2)) (acc '()))
          (if (and (< i n) (string-prefix? "|" (vector-ref lines i)))
              (let* ((cell (cadr (string-split (vector-ref lines i) #\|)))
                     (word (first-token (string-trim-both cell))))
                (loop (+ i 1) (cons word acc)))
              (cons (reverse acc) i))))))

(define (check-tables doc)
  (let* ((lines (file-lines doc))
         (n     (vector-length lines))
         (mark  (let loop ((i 0))
                  (cond ((>= i n) #f)
                        ((regexp-exec rx-marker (vector-ref lines i)) i)
                        (else (loop (+ i 1)))))))
    (if (not mark) '()
        (let ((fields (scope-nodes-fields)))
          (if (not fields)
              (list (format #f "~a: make-scope-nodes is not in doors/service.scm" doc))
              (let* ((folds    (table-first-words lines mark))
                     (descents (table-first-words lines (cdr folds)))
                     (rows     (append (car folds) (car descents))))
                (if (equal? rows fields) '()
                    (list (format #f "~a: fold+descent rows ~s differ from <scope-nodes> fields ~s"
                                  doc rows fields)))))))))

;;; ── Main ────────────────────────────────────────────────────────────────────

(define (main args)
  (let* ((docs (if (null? (cdr args))
                   '("docs/planning/federation/federation-flow-map.md")
                   (cdr args)))
         (refusals (append-map (lambda (d) (append (check-cites d) (check-tables d))) docs)))
    (for-each (lambda (r) (format #t "~a\n" r)) refusals)
    (format #t "doc-cites: ~a document(s), ~a refusal(s)\n" (length docs) (length refusals))
    (exit (if (null? refusals) 0 1))))

(main (command-line))
