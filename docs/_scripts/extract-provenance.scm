#!/usr/bin/env guile
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; extract-provenance.scm — regenerate *provenance-facts* from greppable tags.
;;;
;;; The bridge's maintenance path. Reads the two conventions and rewrites the
;;; region between the BEGIN/END markers in module/localchimera/lang/provenance.scm:
;;;
;;;   prose (docs/**):  @claim ID grounds: REF ...     (in <!-- --> or // )
;;;                     → (grounds ID REF) for each REF, and (argues ID "path")
;;;                       an empty `grounds:` means "still only argued".
;;;   knowledge (module/**/*.scm):
;;;                     ;; @defines REF                 → (defines REF "path")
;;;                     ;; @builds  REF PARENT          → (builds  REF PARENT)
;;;
;;; Usage:
;;;   guile docs/_scripts/extract-provenance.scm            # dry run → stdout
;;;   guile docs/_scripts/extract-provenance.scm --write    # rewrite the module

(use-modules (ice-9 ftw)
             (ice-9 regex)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define %root
  (canonicalize-path
   (string-append (dirname (current-filename)) "/../..")))

(define %module "module/localchimera/lang/provenance.scm")

;;; ── scan ──────────────────────────────────────────────────────────────────────

(define claim-rx   (make-regexp "@claim[ \t]+([A-Za-z0-9_-]+)[ \t]+grounds:[ \t]*(.*)"))
(define defines-rx (make-regexp "@defines[ \t]+([A-Za-z0-9_-]+)"))
(define builds-rx  (make-regexp "@builds[ \t]+([A-Za-z0-9_-]+)[ \t]+([A-Za-z0-9_-]+)"))

(define (rel path) (string-drop path (+ 1 (string-length %root))))

;; Example tags in the bridge's own prose/docstrings are angle-bracketed
;; (<REF>, <ID>) so the regexes below never match them — which lets provenance.scm
;; and provenance-bridge.md carry REAL tags and ground their own claims. Nothing
;; needs excluding; the list is kept as a safety valve.
(define %ignore '())
(define (ignored? file) (member (rel file) %ignore))

(define (refs-of str)
  "Split the tail of a `grounds:` tag into ref tokens, dropping comment closers."
  (filter (lambda (t) (and (> (string-length t) 0)
                           (not (string=? t "-->"))
                           (not (string=? t "*/"))))
          (string-split (string-trim-both str) #\space)))

(define (for-each-line file proc)
  (call-with-input-file file
    (lambda (port)
      (let loop ()
        (let ((line (read-line port)))
          (unless (eof-object? line) (proc line) (loop)))))))

;; accumulators (reverse-order lists of facts)
(define grounds '()) (define argues '()) (define realizes '())
(define defines '()) (define builds '())

(define (scan-file file)
  (define is-scm (string-suffix? ".scm" file))
  (for-each-line file
    (lambda (line)
      (let ((m (regexp-exec claim-rx line)))
        (when m
          (let ((id (string->symbol (match:substring m 1))))
            (set! argues (cons (list id (rel file)) argues))
            ;; each grounds token is REF or REF#PLANNER-ID; `#` splits the finer
            ;; realizes edge (the concrete id the convex model is built from).
            (for-each
             (lambda (tok)
               (let* ((parts (string-split tok #\#))
                      (ref   (string->symbol (car parts))))
                 (set! grounds (cons (list id ref) grounds))
                 (when (and (pair? (cdr parts)) (> (string-length (cadr parts)) 0))
                   (set! realizes (cons (list id (string->symbol (cadr parts))) realizes)))))
             (refs-of (match:substring m 2))))))
      (when is-scm
        (let ((d (regexp-exec defines-rx line)))
          (when d
            (set! defines (cons (list (string->symbol (match:substring d 1)) (rel file))
                                defines))))
        (let ((b (regexp-exec builds-rx line)))
          (when b
            (set! builds (cons (list (string->symbol (match:substring b 1))
                                     (string->symbol (match:substring b 2)))
                               builds))))))))

(define (walk dir pred)
  (ftw dir (lambda (fn sb flag)
             (when (and (eq? flag 'regular) (pred fn) (not (ignored? fn)))
               (scan-file fn))
             #t)))

(walk (string-append %root "/docs")
      (lambda (f) (or (string-suffix? ".md" f) (string-suffix? ".typ" f))))
(walk (string-append %root "/module")
      (lambda (f) (string-suffix? ".scm" f)))

;;; ── render ──────────────────────────────────────────────────────────────────

(define (sym<? a b) (string<? (symbol->string (car a)) (symbol->string (car b))))
(define (fact tag args)
  (string-append "    (" (symbol->string tag) " "
                 (string-join (map (lambda (a)
                                     (if (symbol? a) (symbol->string a)
                                         (string-append "\"" a "\"")))
                                   args) " ") ")"))

(define grounded-ids (delete-duplicates (map car grounds)))
(define (grounded? id) (memq id grounded-ids))

(define lines
  (append
   (list "(define *provenance-facts*"
         "  '(;; ── grounded claims ──")
   ;; DEDUPED, because `grounds` names the SUBJECT while the finer anchor goes to
   ;; its own `realizes` fact just below. Two anchors in one file — say a claim
   ;; grounded in stone-paper#recipe-stone-paper-bio AND
   ;; stone-paper#recipe-stone-paper-compost — are one grounding of that file and
   ;; two realizations, so emitting `(grounds claim stone-paper)` twice says
   ;; nothing the second time. (Two anchors in DIFFERENT files stay two facts:
   ;; they are two groundings.)
   (append-map (lambda (g) (list (fact 'grounds g)))
               (sort (delete-duplicates grounds) sym<?))
   (map (lambda (r) (fact 'realizes r)) (sort realizes sym<?))
   (map (lambda (a) (fact 'argues a))
        (sort (filter (lambda (a) (grounded? (car a))) argues) sym<?))
   (list "" "    ;; ── still only argued (no `grounds` edge yet) ──")
   (map (lambda (a) (fact 'argues a))
        (sort (filter (lambda (a) (not (grounded? (car a)))) argues) sym<?))
   (list "" "    ;; ── how the executable refs build on one another ──")
   (map (lambda (b) (fact 'builds b)) (sort builds sym<?))
   (list "" "    ;; ── where each ref's facts live ──")
   (let* ((ds (sort (delete-duplicates defines) sym<?))
          (n  (length ds)))
     (map (lambda (d i) (string-append (fact 'defines d) (if (= i (- n 1)) "))" "")))
          ds (iota n)))))

(define block (string-join lines "\n"))

;;; ── emit or write ─────────────────────────────────────────────────────────────

(define begin-mark ";;; BEGIN generated")
(define end-mark   ";;; END generated")

(if (member "--write" (command-line))
    (let* ((path (string-append %root "/" %module))
           (src  (call-with-input-file path get-string-all))
           (b    (string-contains src begin-mark))
           (e    (string-contains src end-mark)))
      (unless (and b e) (error "markers not found in" %module))
      (let ((before (substring src 0 b))
            (after  (substring src (+ e (string-length end-mark)))))
        (call-with-output-file path
          (lambda (p)
            (display before p)
            (display begin-mark p) (newline p)
            (display "(define *provenance-facts*" p) (newline p)
            ;; block already opens with the define; strip its first line
            (display (string-join (cdr lines) "\n") p) (newline p)
            (display end-mark p)
            (display after p))))
      (format #t "wrote ~a facts → ~a~%"
              (+ (length grounds) (length argues) (length builds) (length defines))
              %module))
    (begin
      (format #t ";;; dry run — ~a grounds, ~a argues, ~a builds, ~a defines~%~%"
              (length grounds) (length argues) (length builds) (length defines))
      (display block) (newline)))
