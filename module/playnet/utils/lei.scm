;;; utils/lei.scm — the Legal Entity Identifier, as ISO 17442 states it.
;;;
;;; Twenty characters: a prefix of the issuing Local Operating Unit, the
;;; entity's own part, and two check digits by ISO 7064 MOD 97-10 over the
;;; whole, letters read as 10..35. A body (legal/bodies.scm) carries one as
;;; `legal-id:lei:<code>`; the declare door refuses a malformed one, and a
;;; verifiable LEI a body holds is joined to ours by this code
;;; (docs/legal/bodies.md).

(define-module (playnet utils lei)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (lei-valid? lei-normalize))

(define (lei-normalize s)
  "S upper-cased with surrounding blanks gone, or #f for a non-string."
  (and (string? s) (string-upcase (string-trim-both s))))

(define (char-weight c)
  "A digit as itself, a letter as 10..35 (ISO 7064 on an alphanumeric string)."
  (cond ((char-numeric? c) (string c))
        ((char-alphabetic? c) (number->string (+ 10 (- (char->integer (char-upcase c)) (char->integer #\A)))))
        (else #f)))

(define (mod-97-10 digits)
  "The ISO 7064 MOD 97-10 residue of a decimal string, folded in steps so the
   number never grows past a machine word's worth."
  (let loop ((cs (string->list digits)) (acc 0))
    (if (null? cs) acc
        (loop (cdr cs) (modulo (+ (* acc 10) (- (char->integer (car cs)) (char->integer #\0))) 97)))))

(define (lei-valid? s)
  "Is S a well-formed LEI: twenty alphanumerics whose MOD 97-10 residue is 1?"
  (let ((lei (lei-normalize s)))
    (and lei
         (= 20 (string-length lei))
         (every (lambda (c) (or (char-numeric? c) (char-upper-case? c))) (string->list lei))
         (let ((expanded (string-concatenate (map (lambda (c) (char-weight c)) (string->list lei)))))
           (= 1 (mod-97-10 expanded))))))
