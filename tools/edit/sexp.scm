#!/usr/bin/env -S guile --no-auto-compile -L module
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; sexp.scm — structural navigation and editing for Scheme sources.
;;;
;;; The /emacs skill's argument: tree tooling for agents is normally hard because
;;; you need a parser bridging text offsets to AST nodes. Scheme has no such gap —
;;; the text IS the tree — so this is a scanner plus `read`, not a grammar.
;;;
;;;   tools/edit/sexp.scm list    <file>                  top-level forms: kind, name, lines
;;;   tools/edit/sexp.scm read    <file> <name> [--context]  one form's text
;;;   tools/edit/sexp.scm replace <file> <name> <new-file>   swap a form, reader-validated
;;;   tools/edit/sexp.scm publishes <module>               what the LIVE module exports
;;;   tools/edit/sexp.scm origin  <name> <module>...       which module really binds a name
;;;
;;; Two rules taken from that skill, both load-bearing:
;;;
;;;   - Fetch on demand, don't bulk-attach. `read` returns ONE form, not the file.
;;;   - Outer context is a request, not a default. --context adds the module header
;;;     and sibling names; without it you get the form and nothing else.
;;;
;;; And one rule this repo learned the hard way: a depth counter that does not skip
;;; comments, strings and #\( literals is counting characters, not structure. It
;;; lands on the right paren by luck until it doesn't. See the `despaghetti` skill.

(use-modules (ice-9 match) (ice-9 rdelim) (ice-9 format) (srfi srfi-1))

;; the same reason as `slurp`: a form quoted from a French règlement must survive
;; being printed, or `read` hands the caller mojibake to paste back in.
(set-port-encoding! (current-output-port) "UTF-8")

;;; ── scanning ──────────────────────────────────────────────────────────────
;;; Top-level form boundaries as (start . end) offsets. Skips ; comments,
;;; #| block comments |#, "strings" with escapes, and #\( character literals —
;;; the four things that look like structure and are not.

(define (scan-toplevel src)
  (define n (string-length src))
  (let loop ((i 0) (start #f) (depth 0) (acc '()))
    (if (>= i n)
        (reverse acc)
        (let ((c (string-ref src i)))
          (cond
            ;; line comment
            ((char=? c #\;)
             (let ((nl (string-index src #\newline i)))
               (loop (if nl (+ nl 1) n) start depth acc)))
            ;; block comment #| ... |#
            ((and (char=? c #\#) (< (+ i 1) n) (char=? (string-ref src (+ i 1)) #\|))
             (let scan ((j (+ i 2)))
               (cond ((>= j (- n 1)) (loop n start depth acc))
                     ((and (char=? (string-ref src j) #\|)
                           (char=? (string-ref src (+ j 1)) #\#))
                      (loop (+ j 2) start depth acc))
                     (else (scan (+ j 1))))))
            ;; character literal #\x — including #\( and #\;
            ((and (char=? c #\#) (< (+ i 1) n) (char=? (string-ref src (+ i 1)) #\\))
             (loop (+ i 3) start depth acc))
            ;; string
            ((char=? c #\")
             (let scan ((j (+ i 1)))
               (cond ((>= j n) (loop n start depth acc))
                     ((char=? (string-ref src j) #\\) (scan (+ j 2)))
                     ((char=? (string-ref src j) #\") (loop (+ j 1) start depth acc))
                     (else (scan (+ j 1))))))
            ((char=? c #\()
             (loop (+ i 1) (if (= depth 0) i start) (+ depth 1) acc))
            ((char=? c #\))
             (let ((d (- depth 1)))
               (if (= d 0)
                   (loop (+ i 1) #f 0 (cons (cons start (+ i 1)) acc))
                   (loop (+ i 1) start (max d 0) acc))))
            (else (loop (+ i 1) start depth acc)))))))

;;; Ports carry an ENCODING, and Guile's default is the locale's — which on a box
;;; with no locale installed is ASCII. Reading a form and writing it back then
;;; dropped every non-ASCII character silently, reported "replaced", and left the
;;; file valid Scheme with its prose quietly mutilated: 14 em-dashes out of this
;;; very file on the first three edits, and it would have done the same to a
;;; context pack full of French statute. A tool whose whole argument is "validate
;;; before the write" has to mean the bytes too.
(define (slurp path)
  (call-with-input-file path
    (lambda (p) (set-port-encoding! p "UTF-8") (read-string p))))

(define (spit path text)
  (call-with-output-file path
    (lambda (p) (set-port-encoding! p "UTF-8") (display text p))))

(define (line-of src off)
  (1+ (string-count (substring src 0 off) #\newline)))

;;; ── naming ────────────────────────────────────────────────────────────────
;;; What a form binds. Mirrors lift-fragment.py's definer set — including
;;; define-actor, whose omission once made a module silently export everything
;;; EXCEPT its actor constructors.

(define (form-kind+name form)
  (match form
    (('define-actor (name . _) . _)            (list 'define-actor name))
    (('define-module name . _)                 (list 'define-module name))
    ((and (k . _) (? (lambda (f) (memq (car f) '(define define* define-public
                                                 define-syntax define-inlinable)))))
     (match form
       ((_ (name . _) . _) (list k name))
       ((_ name . _)       (list k name))
       (_                  (list k '?))))
    (('define-record-type name . _)            (list 'define-record-type name))
    (('include-from-path p)                    (list 'include p))
    ((k . _)                                   (list k '—))
    (_                                         (list '? '—))))

(define (forms-of path)
  "((kind name start end) …) for every top-level form."
  (let ((src (slurp path)))
    (filter-map
      (lambda (span)
        (let* ((text (substring src (car span) (cdr span)))
               (form (catch #t (lambda () (call-with-input-string text read))
                            (lambda _ #f))))
          (and (pair? form)
               (let ((kn (form-kind+name form)))
                 (list (car kn) (cadr kn) (car span) (cdr span))))))
      (scan-toplevel src))))

(define (find-form path name)
  "The top-level form NAME identifies. Matched on the PRINTED name, not on symbol
   identity — because the form you most often need to edit structurally is the
   `define-module`, and a module's name is a LIST. Comparing with eq? against a
   symbol could never match it, so the one header carrying every #:export was the
   one form this tool could not address. `(playnet legal gate)` works, and
   so does the shorthand `module` for whatever module the file declares."
  (let* ((forms (forms-of path))
         (printed (lambda (f) (format #f "~a" (cadr f)))))
    (or (and (string=? name "module")
             (find (lambda (f) (eq? (car f) 'define-module)) forms))
        (find (lambda (f) (string=? (printed f) name)) forms)
        (begin (format (current-error-port)
                       "sexp: no top-level form named ~a in ~a~%" name path)
               (exit 1)))))

;;; ── commands ──────────────────────────────────────────────────────────────

(define (cmd-list path)
  (let ((src (slurp path)))
    (for-each
      (lambda (f)
        (format #t "~4d  ~a ~a~%" (line-of src (caddr f))
                (string-pad-right (format #f "~a" (car f)) 22) (cadr f)))
      (forms-of path))))

(define (cmd-read path name context?)
  (let* ((src (slurp path))
         (f   (find-form path name)))
    (when context?
      ;; the compass, not the encyclopedia: module header + sibling names only
      (let ((hdr (find (lambda (g) (eq? (car g) 'define-module)) (forms-of path))))
        (when hdr
          (format #t ";; ── enclosing module ──~%~a~%~%"
                  (substring src (caddr hdr) (cadddr hdr)))))
      (format #t ";; ── siblings ──~%;; ~a~%~%"
              (string-join (map (lambda (g) (format #f "~a" (cadr g)))
                                (remove (lambda (g) (eq? (cadr g) (cadr f)))
                                        (forms-of path)))
                           " ")))
    (display (substring src (caddr f) (cadddr f)))
    (newline)))

(define (cmd-replace path name new-path)
  (let* ((src (slurp path))
         (f   (find-form path name))
         (new (string-trim-right (slurp new-path))))
    ;; validate BEFORE the write: the replacement must read as exactly one form,
    ;; and must still bind the name it claims to.
    (let ((form (catch #t (lambda () (call-with-input-string new read))
                       (lambda (k . a)
                         (format (current-error-port) "sexp: replacement does not parse: ~a ~a~%" k a)
                         (exit 1)))))
      (unless (pair? form)
        (format (current-error-port) "sexp: replacement is not a form~%") (exit 1))
      ;; …compared on the PRINTED name, the same way find-form matches. A module's
      ;; name is a list, so a symbol comparison refused every header edit even
      ;; after the finder learned to address one — fixing the finder and not the
      ;; validator left the tool able to FIND a define-module and unable to write
      ;; one. It refused rather than corrupting, which is the right failure.
      (let* ((bound (cadr (form-kind+name form)))
             (printed (format #f "~a" bound)))
        (unless (or (string=? printed name)
                    (and (string=? name "module") (eq? (car form) 'define-module)))
          (format (current-error-port)
                  "sexp: replacement binds ~a, not ~a — refusing~%" bound name)
          (exit 1))))
    (let ((out (string-append (substring src 0 (caddr f)) new
                              (substring src (cadddr f)))))
      ;; and the whole file must still read
      (catch #t
        (lambda ()
          (call-with-input-string out
            (lambda (p) (let loop () (unless (eof-object? (read p)) (loop))))))
        (lambda (k . a)
          (format (current-error-port) "sexp: file would not parse after edit: ~a ~a~%" k a)
          (exit 1)))
      (spit path out)
      (format #t "replaced ~a in ~a (~a lines -> ~a)~%" name path
              (line-of src (caddr f))
              (1+ (string-count new #\newline))))))

;;; the semantic oracle. Structure cannot answer these; only the live image can.
(define (cmd-publishes mod)
  ;; resolve-module HAPPILY INVENTS an empty module when it cannot find the
  ;; source, so the answer has to be refused rather than guessed. Two ways it
  ;; used to get that wrong, both found by pointing this at a real module:
  ;;
  ;;   - `module-public-interface` returns #f for an invented module, and
  ;;     module-map on #f raised `struct-vtable: Wrong type argument` — a
  ;;     backtrace where a sentence belongs. Worse than a wrong answer, because
  ;;     a caller grepping the output counts the backtrace lines as exports.
  ;;   - "fewer than 5 exports ⇒ it did not load" is a number standing where a
  ;;     test belongs. (playnet legal policy) publishes exactly two
  ;;     names and is perfectly loaded; the guard called it broken.
  ;;
  ;; What actually distinguishes a loaded module from an invented one is whether
  ;; it came from a FILE. `module-filename` says so directly, at any size.
  (let* ((spec (with-input-from-string mod read))
         (m (catch #t (lambda () (resolve-module spec #:ensure #f)) (lambda _ #f))))
    (unless m
      (format (current-error-port)
              "sexp.scm publishes: ~a does not resolve — is it on the load path? (-L module)~%"
              mod)
      (exit 2))
    (unless (module-filename m)
      (format (current-error-port)
              "sexp.scm publishes: ~a resolved but was never loaded from a file — an empty module, invented by resolve-module. Check the name and the load path.~%"
              mod)
      (exit 2))
    (let ((iface (module-public-interface m)))
      (unless iface
        (format (current-error-port)
                "sexp.scm publishes: ~a has no public interface — it defines no #:export.~%"
                mod)
        (exit 2))
      (module-for-each
        (lambda (k v)
          (format #t "~a~a~%" k (if (variable-bound? v) "" "   *** UNBOUND (hollow export) ***")))
        iface))))

(define (cmd-origin name mods)
  "Which of these modules publishes NAME, and is it the SAME binding?

   This is the override question. Two modules exporting one name look identical
   until you compare variable identity: `re-exported` means the umbrella hands
   out the first module's variable, so a local (define name …) in an included
   fragment never reaches the interface. That is how nine deliberate overrides
   in relational/compute.scm were silently shadowed."
  (let ((s (string->symbol name)) (first #f))
    (for-each
      (lambda (m)
        (let* ((spec (with-input-from-string m read))
               (v (catch #t (lambda () (module-variable (resolve-interface spec) s))
                         (lambda _ #f))))
          (when v
            (let ((ref? (not first)))
              (unless first (set! first v))
              (format #t "~a  ~a~%" (string-pad-right m 46)
                      (cond ((not (variable-bound? v)) "UNBOUND — hollow export")
                            ;; the FIRST module given is the reference. Saying
                            ;; "re-exported" of it would be trivially true and
                            ;; would read as a verdict — it is not one.
                            (ref? "reference — compare the rest against this")
                            ((eq? v first) "same variable (re-exported)")
                            (else "DISTINCT variable (own definition)")))))))
      mods)))

(match (cdr (command-line))
  (("list" path)                  (cmd-list path))
  (("read" path name)             (cmd-read path name #f))
  (("read" path name "--context") (cmd-read path name #t))
  (("replace" path name new)      (cmd-replace path name new))
  (("publishes" mod)              (cmd-publishes mod))
  (("origin" name . mods)         (cmd-origin name mods))
  (_ (display "usage: sexp.scm list|read|replace|publishes|origin …\n"
              (current-error-port))
     (exit 1)))
