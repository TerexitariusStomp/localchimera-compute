;;; wisp.scm — Bidirectional Wisp/S-expression transpiler (Hoot/WASM compatible)
;;;
;;; Wisp (SRFI-119) is an indentation-based surface syntax for Scheme.
;;; This module provides conversion between wisp and parenthetical notation.

(define-module (playnet wisp)
  #:export (wisp->sexp-string
            sexp->wisp-string))

;;; ── String helpers (Hoot-compatible) ──────────────────────────────────────

(define (whitespace? c)
  (or (char=? c #\space) (char=? c #\tab)))

(define (split-lines str)
  "Split STR into a list of lines on newline boundaries.
   A trailing newline does NOT produce an extra empty element."
  (let ((len (string-length str)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond
        ((= i len)
         (let ((last (substring str start len)))
           (reverse (if (string-blank? last) acc (cons last acc)))))
        ((char=? (string-ref str i) #\newline)
         (loop (+ i 1) (+ i 1) (cons (substring str start i) acc)))
        (else
         (loop (+ i 1) start acc))))))

(define (line-indent str)
  "Count leading whitespace in STR (tabs count as 2 spaces)."
  (let ((len (string-length str)))
    (let loop ((i 0) (n 0))
      (cond
        ((= i len) n)
        ((char=? (string-ref str i) #\space) (loop (+ i 1) (+ n 1)))
        ((char=? (string-ref str i) #\tab)   (loop (+ i 1) (+ n 2)))
        (else n)))))

(define (strip-indent str)
  "Remove leading whitespace from STR."
  (let ((len (string-length str)))
    (let loop ((i 0))
      (cond
        ((= i len) "")
        ((whitespace? (string-ref str i)) (loop (+ i 1)))
        (else (substring str i len))))))

(define (string-blank? str)
  (let ((len (string-length str)))
    (let loop ((i 0))
      (cond
        ((= i len) #t)
        ((whitespace? (string-ref str i)) (loop (+ i 1)))
        (else #f)))))

(define (starts-with-char? str ch)
  (and (> (string-length str) 0)
       (char=? (string-ref str 0) ch)))

(define (ends-with-char? str ch)
  (let ((len (string-length str)))
    (and (> len 0)
         (char=? (string-ref str (- len 1)) ch))))

;;; ── Colon expansion ───────────────────────────────────────────────────────

(define (find-colon-pos str)
  "Find first \" : \" outside strings and parens. Returns index or #f."
  (let ((len (string-length str)))
    (let loop ((i 0) (in-str? #f) (depth 0))
      (cond
        ((>= i (- len 2)) #f)
        ;; Toggle string tracking on unescaped quote
        ((and (char=? (string-ref str i) #\")
              (not (and (> i 0) (char=? (string-ref str (- i 1)) #\\))))
         (loop (+ i 1) (not in-str?) depth))
        (in-str?
         (loop (+ i 1) in-str? depth))
        ((char=? (string-ref str i) #\()
         (loop (+ i 1) in-str? (+ depth 1)))
        ((char=? (string-ref str i) #\))
         (loop (+ i 1) in-str? (max 0 (- depth 1))))
        ;; Match " : " at top-level
        ((and (= depth 0)
              (char=? (string-ref str i) #\space)
              (char=? (string-ref str (+ i 1)) #\:)
              (char=? (string-ref str (+ i 2)) #\space))
         i)
        (else
         (loop (+ i 1) in-str? depth))))))

(define (expand-colons line)
  "Expand \" : rest\" into \" (rest)\" recursively."
  (let ((pos (find-colon-pos line)))
    (if pos
        (string-append (substring line 0 pos)
                       " ("
                       (expand-colons
                        (substring line (+ pos 3) (string-length line)))
                       ")")
        line)))

;;; ── Paren balance check ──────────────────────────────────────────────────

(define (paren-balanced? str)
  "Return #t if parentheses are balanced in STR, respecting strings."
  (let ((len (string-length str)))
    (let loop ((i 0) (depth 0) (in-str? #f))
      (cond
        ((= i len) (= depth 0))
        ((and (char=? (string-ref str i) #\")
              (not (and (> i 0) (char=? (string-ref str (- i 1)) #\\))))
         (loop (+ i 1) depth (not in-str?)))
        (in-str?
         (loop (+ i 1) depth in-str?))
        ((char=? (string-ref str i) #\()
         (loop (+ i 1) (+ depth 1) in-str?))
        ((char=? (string-ref str i) #\))
         (if (= depth 0)
             #f  ;; More closes than opens
             (loop (+ i 1) (- depth 1) in-str?)))
        (else
         (loop (+ i 1) depth in-str?))))))

;;; ── wisp->sexp-string ────────────────────────────────────────────────────

(define (classify-line line)
  "Return (indent content type) for a raw wisp LINE.
   Type: normal | continuation | comment | parenthesized | blank."
  (let ((indent (line-indent line))
        (content (strip-indent line)))
    (cond
      ((string-blank? line)
       (list 0 "" 'blank))
      ((starts-with-char? content #\;)
       (list indent content 'comment))
      ((and (starts-with-char? content #\.)
            (or (= (string-length content) 1)
                (and (> (string-length content) 1)
                     (whitespace? (string-ref content 1)))))
       (list indent
             (if (> (string-length content) 2)
                 (substring content 2 (string-length content))
                 "")
             'continuation))
      ((starts-with-char? content #\()
       (list indent content 'parenthesized))
      (else
       (list indent (expand-colons content) 'normal)))))

(define (wisp->sexp-string text)
  "Convert wisp text to parenthetical S-expression string.
   Already-parenthesized input passes through unchanged."
  (cond
    ((string-blank? text) "")
    ;; Passthrough: if input starts with ( and is balanced, it's already sexp
    ((let ((trimmed (strip-indent text)))
       (and (starts-with-char? trimmed #\()
            (paren-balanced? trimmed)))
     text)
    (else
     (let ((items (map classify-line (split-lines text)))
           (port (open-output-string)))
       (let loop ((items items) (stack '()) (need-sep? #f))
         (if (null? items)
             ;; Close all remaining open parens
             (begin
               (for-each (lambda (_) (display ")" port)) stack)
               (get-output-string port))
             (let ((indent  (car (car items)))
                   (content (car (cdr (car items))))
                   (type    (car (cdr (cdr (car items)))))
                   (rest    (cdr items)))
               (cond
                 ;; Blank line — close all, emit separator
                 ((eq? type 'blank)
                  (for-each (lambda (_) (display ")" port)) stack)
                  (display "\n" port)
                  (loop rest '() #f))

                 ;; Comment — pass through
                 ((eq? type 'comment)
                  (when need-sep? (display "\n" port))
                  (display content port)
                  (display "\n" port)
                  (loop rest stack #f))

                 ;; Continuation — append to current expression
                 ((eq? type 'continuation)
                  (display " " port)
                  (display content port)
                  (loop rest stack need-sep?))

                 ;; Parenthesized — emit as-is after closing deeper levels
                 ((eq? type 'parenthesized)
                  (let close ((s stack))
                    (if (or (null? s) (< (car s) indent))
                        (begin
                          (when need-sep? (display " " port))
                          (display content port)
                          (loop rest s #t))
                        (begin
                          (display ")" port)
                          (close (cdr s))))))

                 ;; Normal — open new paren after closing deeper/sibling levels
                 (else
                  (let close ((s stack))
                    (if (or (null? s) (< (car s) indent))
                        (begin
                          (when need-sep? (display " " port))
                          (display "(" port)
                          (display content port)
                          (loop rest (cons indent s) #t))
                        (begin
                          (display ")" port)
                          (close (cdr s))))))))))))))

;;; ── sexp->wisp-string ────────────────────────────────────────────────────

(define (sexp->wisp-string text)
  "Convert parenthetical S-expression string to wisp representation.
   Comment lines and blank lines pass through. S-expression lines get
   their outermost parentheses stripped."
  (if (string-blank? text)
      ""
      (let ((lines (split-lines text))
            (port (open-output-string)))
        (for-each
         (lambda (line)
           (let ((content (strip-indent line)))
             (cond
               ;; Blank line
               ((string-blank? line)
                (newline port))
               ;; Comment line
               ((starts-with-char? content #\;)
                (display line port)
                (newline port))
               ;; S-expression — strip outermost parens
               ((and (starts-with-char? content #\()
                     (ends-with-char? content #\)))
                (display (substring content 1 (- (string-length content) 1)) port)
                (newline port))
               ;; Anything else — pass through
               (else
                (display line port)
                (newline port)))))
         lines)
        ;; Trim trailing newline if original didn't have one
        (let ((result (get-output-string port)))
          (if (and (> (string-length result) 0)
                   (not (string-blank? text))
                   (not (ends-with-char? text #\newline))
                   (ends-with-char? result #\newline))
              (substring result 0 (- (string-length result) 1))
              result)))))
