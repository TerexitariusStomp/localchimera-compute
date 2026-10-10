;;; test-lei.scm — the Legal Entity Identifier's check digits (utils/lei.scm).
;;;
;;; Twenty alphanumerics whose ISO 7064 MOD 97-10 residue is 1. GLEIF's own
;;; LEI is the known-good; one changed character fails; length and alphabet
;;; are refused before the arithmetic.
;;;
;;; Run: guile -L module tests/playnet/test-lei.scm

(use-modules (playnet test harness) (playnet utils lei))

(define gleif "506700GE1G29325QX363")
(check "GLEIF's own LEI verifies" (lei-valid? gleif) #t)
(check "lower case and blanks are normalised" (lei-valid? (string-append "  " (string-downcase gleif) " ")) #t)
(check "one character changed fails the check digits" (lei-valid? "506700GE1G29325QX364") #f)
(check "two characters swapped fail" (lei-valid? "506700GE1G29325XQ363") #f)
(check "nineteen characters are no LEI" (lei-valid? "506700GE1G29325QX36") #f)
(check "a character outside the alphabet is refused" (lei-valid? "506700GE1G29325QX36-") #f)
(check "nothing is no LEI" (lei-valid? #f) #f)
(check "normalize gives the canonical form" (lei-normalize " 506700ge1g29325qx363 ") gleif)

(test-summary!)
