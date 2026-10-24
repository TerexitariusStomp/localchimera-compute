;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/utils/json-portable.scm — JSON for the shapes the wire carries,
;;; the same under Guile and Hoot.
;;;
;;; guile-json is not Hoot-compatible, so the canonical emitter and the
;;; order-preserving reader live here, in plain Scheme, and both builds run this
;;; code. The KERI core (signify-portable) re-exports them — SAID parity rests on
;;; their bytes — and the family face's wire reads and writes through them.

(define-module (localchimera utils json-portable)
  #:use-module (srfi srfi-1)
  #:export (scm->json-canonical json-read-ordered))

;;; ── Minimal JSON emitter (byte-compatible with guile-json) ─────────────────
;;;
;;; signify-portable doesn't depend on (json) because guile-json isn't
;;; Hoot-compatible. We emit canonical JSON for the alist/vector shapes
;;; used by KERI/ACDC events. The output is byte-identical to
;;; (scm->json-string x) for the input shapes we use:
;;;
;;;   list-of-pairs (alist) → JSON object   {"k":v,"k":v}
;;;   '() (empty list)      → JSON object   {}
;;;   vector                → JSON array    [v,v,v]
;;;   string                → escaped       "..."
;;;   exact integer         → digits        42
;;;   #t / #f               → true / false
;;;   #nil  (or 'null)      → null
;;;
;;; No spaces, no pretty-printing — KERI SAIDs depend on the exact bytes.

(define (alist? x)
  (and (list? x) (every pair? x)))

(define (json-escape-char c)
  "Return the JSON escape for C, or #f if no escape needed."
  (case c
    ((#\") "\\\"")
    ((#\\) "\\\\")
    ((#\newline) "\\n")
    ((#\return) "\\r")
    ((#\tab) "\\t")
    ((#\backspace) "\\b")
    ((#\page) "\\f")
    (else
     (let ((n (char->integer c)))
       (cond
        ((< n #x20)
         ;; Control chars get \u00XX escape
         (let ((hex "0123456789abcdef"))
           (string-append "\\u00"
                          (string (string-ref hex (logand (ash n -4) #xf))
                                  (string-ref hex (logand n #xf))))))
        (else #f))))))

;; The emitters stream into ONE string port. A 35 KB snapshot has thousands
;; of elements; joining them by repeated string-append copied the growing
;; prefix on every step (quadratic), and the dial's vat runs on the page's
;; main thread — that copy WAS the second-long stall between a solve round
;; landing and the page answering a tap. Output is byte-identical to the
;; string-append form (SAID parity rests on it).
(define (json-emit-string s)
  (let ((p (open-output-string)))
    (json-write-string s p)
    (get-output-string p)))

(define (json-write-string s p)
  (write-char #\" p)
  (string-for-each
   (lambda (c)
     (let ((esc (json-escape-char c)))
       (if esc (display esc p) (write-char c p))))
   s)
  (write-char #\" p))

(define (json-emit-vector v)
  (let ((p (open-output-string)))
    (json-write v p)
    (get-output-string p)))

(define (alist-key->string k)
  "Coerce an alist key to a string. guile-json accepts both string and
   symbol keys; we mirror that so OOBI entries with symbol keys (per
   ^oobi-host's storage shape) serialise the same way."
  (cond ((string? k) k)
        ((symbol? k) (symbol->string k))
        (else (error "alist key must be string or symbol" k))))

(define (json-emit-alist a)
  (let ((p (open-output-string)))
    (json-write a p)
    (get-output-string p)))

;; the one writer every shape goes through; scm->json-canonical is its
;; string-returning face and keeps the type law (see its docstring)
(define (json-write val p)
  (cond
   ((eq? val #t) (display "true" p))
   ((eq? val #f) (display "false" p))
   ((or (eq? val #nil) (eq? val 'null)) (display "null" p))
   ((string? val) (json-write-string val p))
   ((symbol? val) (json-write-string (symbol->string val) p))
   ((exact-integer? val) (display (number->string val) p))
   ((and (number? val) (inexact? val) (rational? val))
    (display (number->string val) p))
   ((vector? val)
    (let ((n (vector-length val)))
      (write-char #\[ p)
      (let loop ((i 0))
        (when (< i n)
          (when (> i 0) (write-char #\, p))
          (json-write (vector-ref val i) p)
          (loop (+ i 1))))
      (write-char #\] p)))
   ((null? val) (display "{}" p))
   ((alist? val)
    (write-char #\{ p)
    (let loop ((rest val) (first? #t))
      (unless (null? rest)
        (unless first? (write-char #\, p))
        (json-write-string (alist-key->string (car (car rest))) p)
        (write-char #\: p)
        (json-write (cdr (car rest)) p)
        (loop (cdr rest) #f)))
    (write-char #\} p))
   ((pair? val)
    (error "scm->json-canonical: list element is not a pair" val))
   (else
    (error "scm->json-canonical: unsupported type" val))))

(define (string-join-comma strs)
  ;; (string-join "," ...) without depending on srfi-13.
  (let ((p (open-output-string)))
    (let loop ((rest strs) (first? #t))
      (unless (null? rest)
        (unless first? (write-char #\, p))
        (display (car rest) p)
        (loop (cdr rest) #f)))
    (get-output-string p)))

(define (scm->json-canonical val)
  "Emit VAL as JSON in the canonical form used by KERI events.
   Matches guile-json's scm->json-string output byte-for-byte for the
   shapes saidify produces (string/integer/vector/alist/bool/#nil),
   plus a couple of conveniences guile-json also supports (symbol
   keys and symbol values both stringified). One known divergence
   from guile-json: control characters U+0000–U+001F are emitted as
   \\u00XX escapes (RFC 8259 §7 compliant). guile-json passes them
   through raw, which produces invalid JSON. KERI events never
   contain such bytes so the difference is irrelevant for SAID
   parity but matters when emitting arbitrary user-supplied data."
  (let ((p (open-output-string)))
    (json-write val p)
    (get-output-string p)))

;;; ── JSON reader, order-preserving ──────────────────────────────────────────
;;;
;;; The inverse of scm->json-canonical, for the shapes it emits: object →
;;; alist in source order (empty object → '()), array → vector, string,
;;; integer, true/false → #t/#f, null → 'null. Field order is load-bearing
;;; for every KERI event — the SAID and the signature are both computed over
;;; the serialized bytes — so a KEL that round-trips through storage must
;;; come back in the order it was written. guile-json's parser reverses
;;; object keys, which is why this reader exists and why it is portable:
;;; the same code parses a stored KEL under Hoot and under Guile.

(define (json-read-ordered str)
  "Parse STR (a JSON text) into the scm->json-canonical value shapes,
   preserving object key order. Raises on malformed input."
  (define n (string-length str))
  (define pos 0)
  (define (peek) (if (< pos n) (string-ref str pos) #f))
  (define (next!) (let ((c (peek))) (set! pos (+ pos 1)) c))
  (define (fail msg) (error (string-append "json-read-ordered: " msg) pos))
  (define (skip-ws!)
    (let loop ()
      (let ((c (peek)))
        (when (and c (memv c '(#\space #\tab #\newline #\return)))
          (next!) (loop)))))
  (define (expect! c)
    (skip-ws!)
    (if (eqv? (peek) c) (next!) (fail (string-append "expected " (string c)))))
  (define (read-hex4)
    (let loop ((i 0) (acc 0))
      (if (= i 4) acc
          (let* ((c (next!))
                 (d (and c (string->number (string c) 16))))
            (if d (loop (+ i 1) (+ (* acc 16) d)) (fail "bad \\u escape"))))))
  (define (read-string)
    (expect! #\")
    (let loop ((out '()))
      (let ((c (next!)))
        (cond
         ((not c) (fail "unterminated string"))
         ((char=? c #\") (list->string (reverse out)))
         ((char=? c #\\)
          (let ((e (next!)))
            (case e
              ((#\") (loop (cons #\" out)))
              ((#\\) (loop (cons #\\ out)))
              ((#\/) (loop (cons #\/ out)))
              ((#\b) (loop (cons #\backspace out)))
              ((#\f) (loop (cons (integer->char 12) out)))
              ((#\n) (loop (cons #\newline out)))
              ((#\r) (loop (cons #\return out)))
              ((#\t) (loop (cons #\tab out)))
              ((#\u) (loop (cons (integer->char (read-hex4)) out)))
              (else (fail "bad escape")))))
         (else (loop (cons c out)))))))
  (define (read-number)
    (let loop ((chars '()))
      (let ((c (peek)))
        (if (and c (or (char-numeric? c) (memv c '(#\- #\+ #\. #\e #\E))))
            (begin (next!) (loop (cons c chars)))
            (or (string->number (list->string (reverse chars)))
                (fail "bad number"))))))
  (define (read-literal word val)
    (let ((len (string-length word)))
      (if (and (<= (+ pos len) n) (string=? (substring str pos (+ pos len)) word))
          (begin (set! pos (+ pos len)) val)
          (fail (string-append "expected " word)))))
  (define (read-array)
    (expect! #\[)
    (skip-ws!)
    (if (eqv? (peek) #\])
        (begin (next!) (vector))
        (let loop ((items '()))
          (let ((v (read-value)))
            (skip-ws!)
            (case (next!)
              ((#\,) (loop (cons v items)))
              ((#\]) (list->vector (reverse (cons v items))))
              (else (fail "expected , or ]")))))))
  (define (read-object)
    (expect! #\{)
    (skip-ws!)
    (if (eqv? (peek) #\})
        (begin (next!) '())
        (let loop ((fields '()))
          (skip-ws!)
          (let ((k (read-string)))
            (expect! #\:)
            (let ((v (read-value)))
              (skip-ws!)
              (case (next!)
                ((#\,) (loop (cons (cons k v) fields)))
                ((#\}) (reverse (cons (cons k v) fields)))
                (else (fail "expected , or }"))))))))
  (define (read-value)
    (skip-ws!)
    (let ((c (peek)))
      (cond
       ((not c) (fail "unexpected end"))
       ((char=? c #\{) (read-object))
       ((char=? c #\[) (read-array))
       ((char=? c #\") (read-string))
       ((char=? c #\t) (read-literal "true" #t))
       ((char=? c #\f) (read-literal "false" #f))
       ((char=? c #\n) (read-literal "null" 'null))
       (else (read-number)))))
  (let ((v (read-value)))
    (skip-ws!)
    (if (< pos n) (fail "trailing characters") v)))
