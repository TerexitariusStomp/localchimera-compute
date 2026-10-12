#!/usr/bin/env guile
!#
;;; lint-verbs.scm — count the sites that spell actions by hand, and let the count only fall.
;;;
;;;   guile tools/lint/lint-verbs.scm            check each file against tools/lint/verb-sites.baseline
;;;   guile tools/lint/lint-verbs.scm --write    record today's counts as the baseline, when none rose
;;;   guile tools/lint/lint-verbs.scm --write --redefine   record them as they are (the lint's own rule changed)
;;;   guile tools/lint/lint-verbs.scm --list     print every site
;;;
;;; The action table (vf/schemas.scm) says what each action does, and
;;; (playnet vf formulas actions) answers the questions code asks of it. A site
;;; that writes a quoted list of verbs, or compares an action to a verb literal, holds a
;;; copy of what the table says (docs/planning/books/beyond-valueflows.md §6.2, Appendix A).
;;; A SITE is a line of library code (module/, server/, tools/; not tests, deprecated code
;;; or the two files that state the table: vf/schemas.scm and vf/formulas/actions.scm) holding
;;; either a quoted list naming two or more of the nineteen actions (a set the table could
;;; give), or a test of something against the literal `produce` or `consume`. Those two
;;; stand for a question the table answers with more than one action: what a process
;;; makes (`making-actions`), what comes newly into being (`creating-actions`), what an
;;; input takes off hand (`consuming-actions`). A test against one other action (`work`
;;; is labour, `use` a means, `pickup` the pickup) is the vocabulary used as itself, and
;;; is no site: the count is of copies of the table, and it can reach zero. A site
;;; whose literal is meant says so on its line (`; verb-meant: reason`) and leaves the
;;; count, so what remains is what nobody has decided.
;;;
;;; The check fails when a file holds MORE sites than its baseline, or a file with no
;;; baseline holds any. A file that holds fewer is reported, and `--write` keeps the gain.

(use-modules (ice-9 regex) (ice-9 ftw) (ice-9 rdelim) (ice-9 textual-ports) (srfi srfi-1) (srfi srfi-13))

(define %verbs
  '("use" "consume" "produce" "work" "cite" "deliver-service" "pickup" "dropoff" "accept" "modify"
    "transfer" "transfer-custody" "transfer-all-rights" "move" "raise" "lower" "combine" "separate" "copy"))
(define %alt (string-join %verbs "|"))
(define %verb-rx (make-regexp (string-append "(^|[^A-Za-z0-9_-])(" %alt ")($|[^A-Za-z0-9_-])")))
(define %list-rx (make-regexp "'\\(([^()]*)\\)"))
;; an unquoted `case` clause holding two or more verbs: ((produce dropoff) 1)
(define %case-rx (make-regexp "\\(\\(([a-z-]+( [a-z-]+)+)\\)($| )"))
;; a list of verbs as strings, the record-flow door's whitelist: '("produce" "consume" …)
(define %strlist-rx (make-regexp "'\\((\"[a-z-]+\"( \"[a-z-]+\")+)\\)"))
(define %eq1-rx (make-regexp "\\((eq\\?|equal\\?) .*'(produce|consume)($|[^A-Za-z0-9_-])|\\(\\((produce|consume)\\) "))
(define %string-rx (make-regexp "\"[^\"]*\""))

(define (verbs-in s)
  "How many verb occurrences S holds (non-overlapping)."
  (let loop ((pos 0) (n 0))
    (let ((m (and (<= pos (string-length s)) (regexp-exec %verb-rx s pos))))
      (if m (loop (max (match:end m 2) (+ pos 1)) (+ n 1)) n))))

(define (code-of line)
  (let* ((i (string-index line #\;))
         (line (if i (substring line 0 i) line)))
    (regexp-substitute/global #f %string-rx line 'pre "\"\"" 'post)))

;; A line that says why its literal is meant (`verb-meant: …` in its comment) is a
;; decision made and recorded where it applies: an engine step keyed to the two actions
;; the solve emits, a table's own notation, a colour per action, a count's record.
(define (meant? line) (and (string-contains line "verb-meant:") #t))

(define (uncommented line)
  (let ((i (string-index line #\;))) (if i (substring line 0 i) line)))

(define (site? line)
  (let ((code (code-of line)) (raw (uncommented line)))
    (and (not (meant? line))
         (or (any (lambda (m) (>= (verbs-in (match:substring m 1)) 2)) (list-matches %list-rx code))
             (any (lambda (m) (>= (verbs-in (match:substring m 1)) 2)) (list-matches %case-rx code))
             (any (lambda (m) (>= (verbs-in (match:substring m 1)) 2)) (list-matches %strlist-rx raw))
             (and (regexp-exec %eq1-rx code) #t)))))

(define (skip? path)
  (or (string-contains path "/tests/")
      (string-suffix? "vf/schemas.scm" path) (string-suffix? "vf/formulas/actions.scm" path)))

;; ── the page (ui/app/*.ts) ──────────────────────────────────────────────────
;; The same count over the browser's sources: a line holding an array literal of two
;; or more verbs as strings (`["consume", "use", "work"]`, a set the generated
;; ui/app/actions-catalogue.ts gives), or a test against the literal `"produce"` or
;; `"consume"`. The catalogue itself, the generated row types and the demo's fixtures
;; are no sites; a line that says why its literal is meant (`// verb-meant: …`) leaves
;; the count, as in Scheme.
(define %ts-list-rx (make-regexp "\\[(\"[a-z-]+\"(, *\"[a-z-]+\")+)\\]"))
(define %ts-eq1-rx  (make-regexp "[!=]== *\"(produce|consume)\""))
(define (ts-site? line)
  (and (not (meant? line))
       (not (string-contains line "verb-meant:"))
       (let ((code (let ((i (string-contains line "//"))) (if i (substring line 0 i) line))))
         (or (any (lambda (m) (>= (verbs-in (match:substring m 1)) 2)) (list-matches %ts-list-rx code))
             (and (regexp-exec %ts-eq1-rx code) #t)))))
(define (ts-skip? path)
  (or (string-suffix? "actions-catalogue.ts" path) (string-suffix? "wire-rows.ts" path)
      (string-contains path "/demo") (string-suffix? ".d.ts" path)))
(define (ts-files root)
  (if (not (file-exists? root)) '()
      (file-system-fold
       (lambda (path stat result) (not (string-contains path "/.")))
       (lambda (path stat result) (if (and (string-suffix? ".ts" path) (not (ts-skip? path))) (cons path result) result))
       (lambda (path stat result) result) (lambda (path stat result) result) (lambda (path stat result) result)
       (lambda (path stat errno result) result) '() root)))
(define (ts-sites-of path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((n 1) (acc '()))
        (let ((line (read-line port)))
          (cond ((eof-object? line) (reverse acc))
                ((ts-site? line) (loop (+ n 1) (cons (cons n line) acc)))
                (else (loop (+ n 1) acc))))))))

(define (scm-files root)
  (if (not (file-exists? root)) '()
      (file-system-fold
       (lambda (path stat result) (not (string-contains path "/.")))
       (lambda (path stat result) (if (and (string-suffix? ".scm" path) (not (skip? path))) (cons path result) result))
       (lambda (path stat result) result) (lambda (path stat result) result) (lambda (path stat result) result)
       (lambda (path stat errno result) result) '() root)))

(define (sites-of path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((n 1) (acc '()))
        (let ((line (read-line port)))
          (cond ((eof-object? line) (reverse acc))
                ((site? line) (loop (+ n 1) (cons (cons n line) acc)))
                (else (loop (+ n 1) acc))))))))

(define %baseline-file "tools/lint/verb-sites.baseline")
(define (counts)
  (sort (filter (lambda (p) (> (cdr p) 0))
                (append (map (lambda (f) (cons f (length (sites-of f))))
                             (append-map scm-files '("module" "server" "tools")))
                        (map (lambda (f) (cons f (length (ts-sites-of f))))
                             (ts-files "ui/app"))))
        (lambda (a b) (string<? (car a) (car b)))))

(define (read-baseline)
  (if (file-exists? %baseline-file)
      (call-with-input-file %baseline-file
        (lambda (port)
          (let loop ((acc '()))
            (let ((line (read-line port)))
              (if (eof-object? line) acc
                  (let ((i (string-index line #\space)))
                    (loop (if (and i (not (string-prefix? "#" line)))
                              (cons (cons (substring line (+ i 1)) (string->number (substring line 0 i))) acc)
                              acc))))))))
      '()))

(define (main args)
  (let ((now (counts)))
    (cond
     ((member "--list" args)
      (for-each (lambda (p) (for-each (lambda (s) (format #t "~a:~a: ~a~%" (car p) (car s) (string-trim (cdr s))))
                                      (if (string-suffix? ".ts" (car p)) (ts-sites-of (car p)) (sites-of (car p)))))
                now))
     ;; --write keeps a gain and never a loss: a file that holds more than its baseline
     ;; is named and nothing is written. --redefine records the counts as they are, for
     ;; a change to what the lint counts.
     ((and (member "--write" args) (not (member "--redefine" args))
           (let ((base (read-baseline)))
             (and (pair? base)
                  (let ((worse (filter (lambda (p) (> (cdr p) (or (assoc-ref base (car p)) 0))) now)))
                    (and (pair? worse) worse)))))
      => (lambda (worse)
           (for-each (lambda (p) (format #t "lint-verbs: ~a holds ~a sites, more than its baseline; nothing written~%" (car p) (cdr p)))
                     worse)
           (exit 1)))
     ((member "--write" args)
      (call-with-output-file %baseline-file
        (lambda (port)
          (format port "# tools/lint/lint-verbs.scm: sites that spell actions by hand, per file. The counts only fall.~%")
          (format port "# `make lint-verbs` fails when a file holds more; `guile tools/lint/lint-verbs.scm --write` keeps a gain.~%")
          (for-each (lambda (p) (format port "~a ~a~%" (cdr p) (car p))) now)))
      (format #t "lint-verbs: ~a sites in ~a files, recorded~%" (apply + (map cdr now)) (length now)))
     (else
      (let* ((base (read-baseline))
             (worse (filter (lambda (p) (> (cdr p) (or (assoc-ref base (car p)) 0))) now))
             (better (filter (lambda (b) (< (or (assoc-ref now (car b)) 0) (cdr b))) base)))
        (for-each (lambda (p) (format #t "  more sites: ~a  ~a → ~a~%" (car p) (or (assoc-ref base (car p)) 0) (cdr p))) worse)
        (for-each (lambda (b) (format #t "  fewer sites: ~a  ~a → ~a (run --write to keep the gain)~%" (car b) (cdr b) (or (assoc-ref now (car b)) 0))) better)
        (format #t "lint-verbs: ~a sites in ~a files (baseline ~a)~%" (apply + (map cdr now)) (length now) (apply + (map cdr base)))
        (exit (if (null? worse) 0 1)))))))

(main (command-line))
