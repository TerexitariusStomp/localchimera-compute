;;; module/playnet/crypto/recovery-share.scm — a piece of a passcode, as a line
;;; of text a person can carry.
;;;
;;; The passcode is the only key to an identity and cannot be reset, so the
;;; answer to losing it is not a reset — it is other people. `(playnet crypto
;;; shamir)` splits the secret k-of-n; this module says how one of those
;;; shares LOOKS when it leaves the browser, because that is the part a human
;;; has to handle.
;;;
;;; A piece is one line, self-describing:
;;;
;;;   pnr1.<aid>.<tag>.<index>.<k>.<base64url-data>
;;;
;;; TAG names the SPLITTING — a few random characters shared by every piece
;;; cut in the same act. Each splitting uses a fresh random polynomial, so
;;; pieces from two splittings of the SAME passcode do not fit together:
;;; shamir-combine interpolates them into a full-length WRONG secret with no
;;; complaint (proven in the tests), which would reach a person as "wrong
;;; passcode" at the worst possible moment. The tag turns that silent
;;; corruption into a refusal that says what to do: gather pieces that were
;;; made together.
;;;
;;; The separator is `.` precisely because base64url uses `-` and `_` and
;;; neither, so a piece survives being pasted anywhere a line of text
;;; survives: a chat message, a note app, a piece of paper read back by hand.
;;;
;;; It carries the AID because recovery has to know whose identity it is
;;; opening — the shares reconstitute a passcode, and a passcode alone does
;;; not say which identity it belongs to. The person holding the piece was
;;; chosen by its owner, so this tells them nothing they did not know.
;;;
;;; THE PIECES NEVER TOUCH A GATEWAY. They are produced in the owner's
;;; browser, shown to the owner, and carried to each person however those two
;;; already talk. A commune holding every piece could reconstitute the
;;; passcode, which would undo the one property the whole identity design
;;; exists for — so it is never offered them. The cost is that delivery is
;;; the owner's to do; the gain is that the trust sits exactly where they put
;;; it, in people they chose.
;;;
;;; Pure string/bytevector work, so it loads under Hoot (the browser vat
;;; produces and parses these) and under Guile (where it is tested).

(define-module (playnet crypto recovery-share)
  #:use-module (srfi srfi-1)
  #:use-module ((rnrs bytevectors) #:select (bytevector-length))
  #:use-module ((goblins contrib base64)
                #:select (base64-decode base64-encode base64-url-alphabet))
  #:export (share->line
            line->share
            share-line-aid
            share-line-tag
            share-line-index
            share-line-threshold
            share-line-data))

(define %prefix "pnr1")

(define (share->line aid tag idx k data-bv)
  "One share as a carryable line. TAG names the splitting (the same few
   characters on every piece cut together); IDX and K are the share's own
   index and the number of pieces needed; DATA-BV is the share bytes."
  (string-append %prefix "." aid "." tag "." (number->string idx) "."
                 (number->string k) "."
                 (base64-encode data-bv #:alphabet base64-url-alphabet
                                #:padding? #f)))

;; A parsed piece is (aid tag index threshold data-bv) — accessors rather
;; than positional car/cadr at every call site.
(define (share-line-aid p)       (list-ref p 0))
(define (share-line-tag p)       (list-ref p 1))
(define (share-line-index p)     (list-ref p 2))
(define (share-line-threshold p) (list-ref p 3))
(define (share-line-data p)      (list-ref p 4))

(define (line->share line)
  "Parse one line back into (aid tag index threshold data-bv), or #f.

   Returns #f rather than raising for ANY malformed input: these lines are
   retyped by hand from notes and chat messages, so a wrong one is an
   ordinary event the caller reports, not an exception. Whitespace around
   the line is trimmed for the same reason — a copied line usually arrives
   with some."
  (and (string? line)
       (let ((parts (string-split (string-trim-both line) #\.)))
         (and (= 6 (length parts))
              (string=? (car parts) %prefix)
              (let ((aid (list-ref parts 1))
                    (tag (list-ref parts 2))
                    (idx (string->number (list-ref parts 3)))
                    (k   (string->number (list-ref parts 4))))
                (and (positive? (string-length aid))
                     (positive? (string-length tag))
                     (exact-integer? idx) (exact-integer? k)
                     (> idx 0) (> k 0)
                     ;; base64-decode raises on a bad alphabet or length;
                     ;; a mistyped line must read as "not a piece", not a crash
                     (let ((data (false-if-exception
                                  (base64-decode (list-ref parts 5)
                                                 #:alphabet base64-url-alphabet
                                                 #:padding? #f))))
                       (and data (positive? (bytevector-length data))
                            (list aid tag idx k data)))))))))
