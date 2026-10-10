;;; labels.scm — the code a thing is known by (docs/observation/capture.md §6)
;;;
;;; A label is six characters of Crockford's alphabet: no I, L, O or U, so a
;;; code read aloud or copied by hand has one reading, and a typed I, L or O
;;; reads as the digit it resembles. The QR symbol on a printed label carries
;;; `playnet:` and the code, and nothing else. The browser holds the same
;;; alphabet, length and scheme as generated constants (tools/emit/count-emit.scm →
;;; ui/app/count-catalogue.ts); the service draws and reads codes through this
;;; module alone.
;;;
;;; Pure over strings; uniqueness within a scope belongs to the service, which
;;; asks the observer whether a drawn code is taken.

(define-module (playnet vf facts labels)
  #:use-module (srfi srfi-1)
  #:export (%label-alphabet %label-length %label-scheme label-normal draw-label))

(cond-expand (guile) (else
  (define (string-filter pred s)           ; the characters of S that PRED keeps (Hoot has no srfi-13)
    (list->string (let loop ((cs (string->list s)))
                    (cond ((null? cs) '())
                          ((pred (car cs)) (cons (car cs) (loop (cdr cs))))
                          (else (loop (cdr cs)))))))))


(cond-expand (guile) (else
  ;; Hoot has no `random`: a page draws a code's letters from a counter spread over the range
  (define %draws 0)
  (define (random n) (set! %draws (+ %draws 1)) (modulo (* 2654435761 %draws) n))))


(define %label-alphabet "0123456789ABCDEFGHJKMNPQRSTVWXYZ")
(define %label-length 6)
(define %label-scheme "playnet:")

(define (label-normal code)
  "CODE as the books hold it: upper case, the look-alikes read as digits, and
   everything outside the alphabet dropped. #f when nothing remains."
  (and (string? code)
       (let ((s (string-filter
                 (lambda (c) (string-index %label-alphabet c))
                 (string-map (lambda (c)
                               (case (char-upcase c)
                                 ((#\I #\L) #\1)
                                 ((#\O) #\0)
                                 (else (char-upcase c))))
                             code))))
         (and (not (string-null? s)) s))))

(define (draw-label)
  "A code drawn from the alphabet with the process's random state."
  (list->string
   (map (lambda (_) (string-ref %label-alphabet (random (string-length %label-alphabet))))
        (iota %label-length))))
