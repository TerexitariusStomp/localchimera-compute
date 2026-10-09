;;; module/playnet/utils/common.scm — tiny utilities used across pillars
;;;
;;; Three patterns that recur in modules that interact with the
;;; outside world (env vars, files, possibly-failing operations) and
;;; were beginning to duplicate. Keeping them in one home so the
;;; pattern stays consistent.
;;;
;;;   safe-call thunk [default]      — try thunk; on any error return
;;;                                    DEFAULT (#f by default), no log.
;;;                                    For "best-effort read or fall back."
;;;
;;;   for-each-catching label fn xs  — apply FN to each item in XS,
;;;                                    catching per-item errors and
;;;                                    logging them with LABEL prefix.
;;;                                    For "fan-out where one bad item
;;;                                    shouldn't kill the others."
;;;
;;;   env-int name default           — getenv NAME parsed as int, or
;;;                                    DEFAULT on absent/unparseable.
;;;
;;;   env-flag? name                 — getenv NAME as a switch: #t when set
;;;                                    to anything but "" or "0". The one
;;;                                    reading for every PLAYNET_* on/off
;;;                                    var; four modules each spelled it
;;;                                    before, two of them counting "" as
;;;                                    on.
;;;
;;;   parse-csv-env name             — getenv NAME split on commas,
;;;                                    trimmed, empties dropped.
;;;
;;;   read-sexp-file path            — one S-expression from PATH, or
;;;                                    #f on absent / parse error.
;;;
;;;   read-all-sexps-file path       — every S-expression from PATH
;;;                                    into a list, or '() on absent /
;;;                                    parse error.
;;;
;;;   capture argv                   — stdout of ARGV (a list of argv
;;;                                    strings) as a string, or #f on any
;;;                                    failure (nonzero exit, no such
;;;                                    binary, etc).
;;;
;;;   string-or-false x              — X when a non-empty string, else #f.
;;;   non-empty-lines str [char]     — STR split on CHAR (default
;;;                                    newline), each piece trimmed,
;;;                                    empties dropped.

(define-module (playnet utils common)
  #:use-module (ice-9 format)
  #:export (safe-call
            for-each-catching
            env-int
            env-flag?
            parse-csv-env
            read-sexp-file
            read-all-sexps-file
            capture
            string-or-false
            take-up-to
            non-empty-lines)
  #:use-module ((playnet utils catch) #:select (catch* throw* with-throw-handler*)))

(cond-expand (guile) (else
  ;; a page has no file system: no file is there to read, and none is written
  (define (file-exists? path) #f)
  (define (call-with-input-file path proc) (error "no file system here" path))
  (define (call-with-output-file path proc) (error "no file system here" path))
  (define (set-port-encoding! port encoding) #t)
  (define (in-vicinity dir file) (string-append dir "/" file))
  (define (%search-load-path file) #f)))


(cond-expand (guile) (else
  (define (string-trim-both s)             ; S without the whitespace at its ends (Hoot has no srfi-13)
    (let* ((n (string-length s))
           (a (let loop ((i 0)) (if (and (< i n) (char-whitespace? (string-ref s i))) (loop (+ i 1)) i)))
           (b (let loop ((j n)) (if (and (> j a) (char-whitespace? (string-ref s (- j 1)))) (loop (- j 1)) j))))
      (substring s a b)))))


(cond-expand (guile) (else (define (getenv name) #f)))   ; a page has no process environment: every switch reads as unset


(define (string-or-false x)
  "X when it is a non-empty string, else #f: a door's optional string argument
   as the value it carries, or its absence."
  (and (string? x) (not (string-null? x)) x))

(define (take-up-to lst n)
  "First N elements of LST, all of it when it has fewer; LST itself when it is
   no list."
  (cond ((not (list? lst)) lst)
        ((or (<= n 0) (null? lst)) '())
        (else (cons (car lst) (take-up-to (cdr lst) (- n 1))))))

(define* (safe-call thunk #:optional (default #f))
  "Run THUNK; return its value, or DEFAULT on any error.
   Use for read-or-fallback patterns where you don't want to log."
  (catch* #t thunk (lambda _ default)))

(define (for-each-catching label fn xs)
  "Apply FN to each item in XS. Per-item errors are caught and
   logged (to current-error-port) prefixed with LABEL. One bad item
   doesn't stop the iteration."
  (for-each
   (lambda (x)
     (catch* #t
       (lambda () (fn x))
       (lambda (key . args)
         (format (current-error-port)
                 "[~a] ~a: ~a ~a~%" label x key args))))
   xs))

(define (env-int name default)
  "Read env var NAME as an integer; return DEFAULT if unset, empty,
   or unparseable."
  (let ((v (getenv name)))
    (cond
     ((or (not v) (string=? v "")) default)
     ((string->number v))
     (else default))))

(define (env-flag? name)
  "Read env var NAME as an on/off switch: #t when it is set to anything
   other than \"\" or \"0\". Unset and empty both read as off, the same
   way env-int reads them as absent."
  (let ((v (getenv name)))
    (and v (not (string=? v "")) (not (string=? v "0")))))

(define (parse-csv-env name)
  "Parse env var NAME as a list of non-empty trimmed strings (comma-
   separated). Returns '() when the var is unset or empty."
  (filter (lambda (s) (not (string-null? s)))
          (map string-trim-both
               (string-split (or (getenv name) "") #\,))))

(define (read-sexp-file path)
  "Read one S-expression from PATH; return #f if file doesn't exist
   or reading fails. For status-file pattern: write a single sexp,
   read it back, fallback gracefully."
  (safe-call
   (lambda ()
     (and (file-exists? path)
          (call-with-input-file path read)))))

(define (read-all-sexps-file path)
  "Read every S-expression from PATH into a list; '() if file absent
   or unreadable. For append-only-log file pattern (one sexp per
   entry, eof terminates)."
  (or (safe-call
       (lambda ()
         (cond
          ((not (file-exists? path)) '())
          (else
           (call-with-input-file path
             (lambda (port)
               (let loop ((acc '()))
                 (let ((sexp (read port)))
                   (if (eof-object? sexp)
                       (reverse acc)
                       (loop (cons sexp acc))))))))))
       '())
      '()))

;; a process is a host's to run: a page has none, and there the answer is the
;; one a missing binary gives
(cond-expand
 (guile
  (use-modules (ice-9 popen) (ice-9 textual-ports))
  (define (capture argv)
    "Run ARGV (a list of argv strings, no shell involved) and return its
     stdout as a string, or #f on any failure — nonzero exit, no such
     binary, etc. For 'shell out and read the answer' where a caller can
     degrade gracefully from a missing tool or an offline remote."
    (safe-call
     (lambda ()
       (let* ((port (apply open-pipe* OPEN_READ argv))
              (out  (get-string-all port))
              (st   (close-pipe port)))
         (and (zero? (or (status:exit-val st) 1)) out))))))
 (else
  (define (capture argv) #f)))

(define* (non-empty-lines str #:optional (char #\newline))
  "STR split on CHAR, each piece trimmed, empties dropped. For turning a
   command's captured stdout into a clean list of lines."
  (filter (lambda (s) (not (string-null? s)))
          (map string-trim-both (string-split str char))))
