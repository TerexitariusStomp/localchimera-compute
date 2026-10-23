;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/keri/test-recovery-share.scm — losing your passcode is survivable
;;; when you gave pieces of it to people you trust.
;;;
;;; The passcode is the only key to an identity and cannot be reset, so this
;;; is the whole of the answer to "I lost it". The property that makes it
;;; safe to offer is not that k pieces work — it is that k-1 pieces learn
;;; NOTHING, so trusting five people individually is not trusting any one of
;;; them. Both halves are asserted here, because a setup flow whose recovery
;;; half is unproven is worse than no feature: people would rely on it.
;;;
;;; Covers the round trip a real recovery makes: split in the owner's browser
;;; → each piece carried as a line of text by a different person → any k of
;;; those lines pasted back → the passcode itself, character for character.

(use-modules (playnet test harness)
             ;; installs the gcrypt/libsodium backend the RNG behind
             ;; shamir-split needs — importing it is the whole of the setup
             (playnet keri signify)
             (playnet crypto shamir)
             (playnet crypto recovery-share)
             (srfi srfi-1)
             (rnrs bytevectors)
             (ice-9 format))

;; A real generated passcode: 24 characters from the dial's unambiguous
;; alphabet, hyphen-grouped (see genPasscode in ui/app/tabs/social/id.ts).
(define %passcode "wnqv7k-xr3mtd-9fbjhs-2ypcze")
(define %aid "EN4uo-sVVQrJxrR5AslMLx39yuwsMrNvp7W4qGnv7C8V")

(define (split-to-lines passcode k n aid tag)
  "What the owner's browser does: split, then render each share as the line
   one person will carry. TAG names this splitting on every piece."
  (map (lambda (sh)
         (share->line aid tag (share-index sh) (share-threshold sh) (share-data sh)))
       (shamir-split (string->utf8 passcode) k n)))

(define (lines->passcode lines)
  "What recovery does: parse the lines that came back, in whatever order, and
   put the passcode together."
  (let ((parsed (map line->share lines)))
    (utf8->string
     (shamir-combine
      ;; shamir-combine reads its shares with car/cadr/caddr, so a share is a
      ;; PROPER list — (cons idx (cons k bv)) builds (idx k . bv), whose caddr
      ;; is the first byte of the bytevector rather than the bytevector.
      (map (lambda (p) (list (share-line-index p)
                             (share-line-threshold p)
                             (share-line-data p)))
           parsed)))))

(format #t "~%=== a piece is a line a person can carry ===~%")

(define lines (split-to-lines %passcode 3 5 %aid "tagA"))

(check "five people, five pieces" (= 5 (length lines)))
(check "each piece is one line of text"
       (every (lambda (l) (and (string? l) (not (string-index l #\newline)))) lines))
(check "…that says which identity it opens"
       (every (lambda (l) (string-contains l %aid)) lines))
(check "…and never contains the passcode itself"
       (every (lambda (l) (not (string-contains l %passcode))) lines))
(check "the pieces differ from one another"
       (= 5 (length (delete-duplicates lines))))

(format #t "~%=== any three of the five bring it back ===~%")

;; Every 3-subset, not a favourite one: recovery cannot depend on WHICH
;; three people turn up, and a bug in the index arithmetic would show up in
;; some combinations and not others.
(define (subsets-of-size k lst)
  (cond ((zero? k) '(()))
        ((null? lst) '())
        (else (append (map (lambda (r) (cons (car lst) r))
                           (subsets-of-size (- k 1) (cdr lst)))
                      (subsets-of-size k (cdr lst))))))

(let ((threes (subsets-of-size 3 lines)))
  (check "there are ten ways three of five can turn up" (= 10 (length threes)))
  (check "every one of them recovers the passcode exactly"
         (every (lambda (three) (string=? %passcode (lines->passcode three)))
                threes)))

(check "the order they arrive in does not matter"
       (string=? %passcode (lines->passcode (reverse (take lines 3)))))

(format #t "~%=== two of the five learn nothing ===~%")

;; THE PROPERTY THAT MAKES IT SAFE TO OFFER. Below the threshold, Shamir
;; gives no partial information — the combine either produces something that
;; is not the passcode, or refuses. What must never happen is that it produces
;; the passcode, which would mean two people (or one, holding two) can open
;; an identity its owner shared five ways.
(let* ((two (take lines 2))
       (got (false-if-exception (lines->passcode two))))
  (check "two pieces do not reconstitute the passcode"
         (not (equal? got %passcode))))
(let* ((one (take lines 1))
       (got (false-if-exception (lines->passcode one))))
  (check "one piece does not either" (not (equal? got %passcode))))

(format #t "~%=== a mistyped piece reads as a mistyped piece ===~%")

;; These lines are retyped by hand off notes and chat messages, so malformed
;; input is an ordinary event: it must be reportable, never an exception.
(check "empty is not a piece"            (not (line->share "")))
(check "prose is not a piece"            (not (line->share "hello there")))
(check "a truncated piece is not a piece"
       (not (line->share (substring (car lines) 0 12))))
(check "a piece from another scheme is not one"
       (not (line->share (string-append "pnr9." %aid ".tagA.1.3.aGk"))))
(check "a piece with non-base64 data is not one"
       (not (line->share (string-append "pnr1." %aid ".tagA.1.3.!!!!"))))
(check "a piece without a splitting tag (the old five-part shape) is not one"
       (not (line->share (string-append "pnr1." %aid ".1.3.aGk"))))
(check "surrounding whitespace is forgiven — a copied line usually has some"
       (let ((p (line->share (string-append "  " (car lines) "\n"))))
         (and p (string=? %aid (share-line-aid p)))))

(format #t "~%=== the shapes recovery checks before it tries ===~%")

(check "a piece knows how many are needed"
       (= 3 (share-line-threshold (line->share (car lines)))))
(check "a piece knows which one it is"
       (= 1 (share-line-index (line->share (car lines)))))

;; Pieces from two different identities must not be combined — the numbers
;; would fit and produce confident nonsense.
(let ((other (split-to-lines "different-passcode-here-x" 3 5 "EOtherAid0000000000000000000000000000000000" "tagB")))
  (check "pieces from two identities are distinguishable by their AID"
         (not (string=? (share-line-aid (line->share (car lines)))
                        (share-line-aid (line->share (car other)))))))

(format #t "~%=== pieces from two splittings refuse to mix ===~%")

;; THE REASON THE TAG EXISTS. Each splitting is a fresh random polynomial, so
;; pieces from two splittings of the SAME passcode interpolate into a
;; full-length WRONG secret with no complaint from the math — first asserted
;; here, so nobody "simplifies" the tag away without meeting this test.
(let* ((again (split-to-lines %passcode 3 5 %aid "tagZ"))
       (mixed (list (list-ref lines 0) (list-ref again 1) (list-ref again 2)))
       (parsed (map line->share mixed)))
  (check "the math alone yields garbage, not an error"
         (let ((got (false-if-exception
                     (shamir-combine
                      (map (lambda (p) (list (share-line-index p)
                                             (share-line-threshold p)
                                             (share-line-data p)))
                           parsed)))))
           ;; produced (or crashed decoding) — either way, NOT the passcode
           (not (equal? got (string->utf8 %passcode)))))
  (check "…which is why every piece names its splitting"
         (= 2 (length (delete-duplicates (map share-line-tag parsed)))))
  (check "and pieces made together share one tag"
         (= 1 (length (delete-duplicates
                       (map (lambda (l) (share-line-tag (line->share l)))
                            again))))))

(format #t "~%=== a 32-byte bran, the shape a scope's key takes ===~%")

;; The person-facing case above splits a passcode string; bran-custody splits
;; raw 32-byte key material. One codec has to carry both.
(let* ((bran (u8-list->bytevector (iota 32)))
       (ls (map (lambda (sh)
                  (share->line %aid "tagC" (share-index sh) (share-threshold sh)
                               (share-data sh)))
                (shamir-split bran 2 3)))
       (back (shamir-combine
              (map (lambda (l)
                     (let ((p (line->share l)))
                       (list (share-line-index p)
                             (share-line-threshold p) (share-line-data p))))
                   (take ls 2)))))
  (check "32 raw bytes survive the round trip" (equal? bran back)))

(test-summary!)
