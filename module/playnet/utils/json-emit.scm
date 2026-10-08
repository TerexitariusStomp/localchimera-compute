;;; json-emit.scm — a minimal JSON writer for the snapshot emitters: strings,
;;; numbers, booleans, arrays and objects, each returned as a string to splice.
;;;
;;; The snapshot emitters (the law face's, the matter face's, the fragility
;;; face's) build their JSON bottom-up from already-serialised pieces, which is
;;; what this is shaped for. A reader that needs to PARSE json, or to write a
;;; whole Scheme value at once, wants (json) or (playnet utils json-portable).

(define-module (playnet utils json-emit)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:export (jesc J:s J:n J:b J:a J:o J:sa J:syms))

(define (jesc s)
  (string-concatenate
   (map (lambda (ch)
          (case ch
            ((#\") "\\\"") ((#\\) "\\\\") ((#\newline) "\\n")
            ((#\return) "\\r") ((#\tab) "\\t")
            (else (string ch))))
        (string->list s))))
(define (J:s x) (string-append "\"" (jesc (if (symbol? x) (symbol->string x)
                                              (if (string? x) x (format #f "~a" x)))) "\""))
(define (J:n x) (if (and (number? x) (integer? x)) (number->string (inexact->exact x))
                    (number->string x)))
(define (J:b x) (if x "true" "false"))
(define (J:a items) (string-append "[" (string-join items ",") "]"))
(define (J:o pairs) ; pairs : list of (key . json-string)
  (string-append "{" (string-join
                      (map (lambda (kv) (string-append (J:s (car kv)) ":" (cdr kv))) pairs)
                      ",") "}"))
(define (J:sa lst) (J:a (map J:s lst)))            ; array of strings
(define (J:syms lst) (J:a (map (lambda (s) (J:s (symbol->string s))) lst)))
