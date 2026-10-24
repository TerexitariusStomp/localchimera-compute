;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/machine/challenge.scm — the storage challenge: prove you
;;; still hold the bytes.
;;;
;;; A 'store claim settles differently from an 'exec claim: running the
;;; envelope once proves nothing about whether the content is still there
;;; tomorrow. The challenge is the storage kind's replay — 'exact by
;;; construction: the verifier knows the answer before asking, because the
;;; answer is a pure function of a fresh nonce and the committed bytes.
;;;
;;;   answer = sha256(nonce-utf8 ∥ content-bytes)
;;;
;;; THE PARTS AND WHO HOLDS THEM. The door holds neither the content nor
;;; the verdict's inputs — that is deliberate, the same fail-closed seam
;;; pattern as replay's executor. The borrower who submitted the store job
;;; holds the content; the node holds a replica; the challenge record
;;; holds the COMMITMENTS: the nonce the issuer generated, the expected
;;; hash the issuer computed from the content it holds, the answer the
;;; node posted, and the verdict once they are compared. An issuer cannot
;;; frame an honest node — expected is bound to content whose sha256 is
;;; the job's inputHash, and the door checks that binding.
;;;
;;; WHAT IS HERE:
;;;   • <store-challenge> — the record: claim, issuer, nonce, expected,
;;;     answer, state, deadline, verdict.
;;;   • challenge-nonce — a fresh unpredictable nonce (32 bytes, hex).
;;;   • challenge-answer-hash — the pure function both sides compute:
;;;     sha256(nonce ∥ content).
;;;   • challenge-answer! / challenge-verify! — the record's transitions.
;;;   • challenge-verdict — name the record's outcome for the wire.
;;;
;;; States: 'open (issued, awaiting the node's answer) → 'answered →
;;; 'closed on verify. A challenge past its deadline with no answer reads
;;; 'failed — silence is a failed proof of retention, not a pending one.

(define-module (localchimera machine challenge)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (gcrypt hash)
  #:use-module (gcrypt base16)
  #:use-module (rnrs bytevectors)
  #:use-module (localchimera machine specs)
  #:export (<store-challenge> make-store-challenge store-challenge?
            store-challenge-id store-challenge-claim-id
            store-challenge-issuer store-challenge-nonce
            store-challenge-expected store-challenge-answer
            store-challenge-state store-challenge-issued-at
            store-challenge-deadline store-challenge-verdict-field
            challenge-nonce challenge-answer-hash
            challenge-answer! challenge-verify! challenge-expired?
            challenge-verdict *store-challenge-window*))


;;; ── the window ──────────────────────────────────────────────────────────
;;; The node has this long to answer. Long enough for a browser tab that
;;; polls on a 30 s lend loop, short enough that an answer is a liveness
;;; fact, not a statement about last week.

(define *store-challenge-window* (* 15 60))   ; 15 minutes, epoch seconds


;;; ── the record ──────────────────────────────────────────────────────────

(define-record-type <store-challenge>
  (%make-store-challenge id claim-id issuer nonce expected answer state
                         issued-at deadline verdict)
  store-challenge?
  (id         store-challenge-id)         ; "chal-…"
  (claim-id   store-challenge-claim-id)   ; the store claim being probed
  (issuer     store-challenge-issuer)     ; who asked — borrower or governor
  (nonce      store-challenge-nonce)      ; hex string, 32 bytes
  (expected   store-challenge-expected)   ; hex | #f — set on verify call
  (answer     store-challenge-answer)     ; hex | #f — the node's reply
  (state      store-challenge-state)      ; 'open | 'answered | 'closed
  (issued-at  store-challenge-issued-at)  ; epoch seconds
  (deadline   store-challenge-deadline)   ; epoch seconds
  (verdict    store-challenge-verdict-field)) ; #f | 'reproduced | 'mismatch

(define* (make-store-challenge #:key id claim-id issuer nonce
                               (expected #f) (answer #f)
                               issued-at (deadline #f))
  (%make-store-challenge id claim-id issuer nonce expected answer 'open
                         issued-at
                         (or deadline (+ issued-at *store-challenge-window*))
                         #f))


;;; ── the nonce and the hash ──────────────────────────────────────────────
;;; The nonce must not be predictable to the node — a predictable nonce
;;; lets a node that dropped the content precompute nothing, so /dev/urandom
;;; through Guile's random is enough: the threat is a node answering stale,
;;; not a node attacking the RNG.

(define (challenge-nonce)
  "A fresh 128-bit nonce as lowercase hex."
  (let ((bv (make-bytevector 16 0)))
    (let loop ((i 0))
      (if (< i 16)
          (begin (bytevector-u8-set! bv i (random 256)) (loop (+ i 1)))
          (bytevector->base16-string bv)))))

;;; The answer both sides compute. NONCE is the hex string; CONTENT the
;;; bytes (a bytevector). sha256 over nonce-as-utf8 then content — a plain
;;; two-block digest, so a node needs no PDP machinery, only the bytes.
;;; (bytevector-append only lands in Guile 3.0.9+ builds with r6rs; the
;;; two-arg case is five lines, write it.)
(define (bv-append a b)
  (let* ((la (bytevector-length a)) (lb (bytevector-length b))
         (out (make-bytevector (+ la lb))))
    (bytevector-copy! a 0 out 0 la)
    (bytevector-copy! b 0 out la lb)
    out))

(define (challenge-answer-hash nonce content)
  (bytevector->base16-string
   (sha256 (bv-append (string->utf8 nonce) content))))


;;; ── the transitions ─────────────────────────────────────────────────────

(define (challenge-expired? c now)
  (and (eq? (store-challenge-state c) 'open)
       (> now (store-challenge-deadline c))))

(define (challenge-answer! c answer)
  "The node posts its hash. Only an open challenge takes an answer — a
   late answer changes nothing on the record (the deadline already said
   what silence meant)."
  (unless (eq? (store-challenge-state c) 'open)
    (error "challenge: not awaiting an answer" (store-challenge-state c)))
  (%make-store-challenge
   (store-challenge-id c) (store-challenge-claim-id c)
   (store-challenge-issuer c) (store-challenge-nonce c)
   (store-challenge-expected c) answer 'answered
   (store-challenge-issued-at c) (store-challenge-deadline c) #f))

(define (challenge-verify! c expected)
  "The issuer supplies EXPECTED — sha256(nonce ∥ content) computed over the
   bytes it holds. The door that calls here has already checked those
   bytes hash to the job's inputHash — the record's half of the contract
   is only that answer and expected came from the same nonce. Closes the
   record: 'reproduced when answer = expected, 'mismatch otherwise,
   'failed when there was no answer at all."
  (unless (memq (store-challenge-state c) '(open answered))
    (error "challenge: already closed" (store-challenge-state c)))
  (let ((verdict (cond ((not (store-challenge-answer c)) 'failed)
                       ((equal? (store-challenge-answer c) expected)
                        'reproduced)
                       (else 'mismatch))))
    (%make-store-challenge
     (store-challenge-id c) (store-challenge-claim-id c)
     (store-challenge-issuer c) (store-challenge-nonce c)
     expected (store-challenge-answer c) 'closed
     (store-challenge-issued-at c) (store-challenge-deadline c) verdict)))

(define (challenge-verdict c now)
  "The wire's word on a record: its verdict field once closed, 'failed for
   an unanswered challenge past its deadline, 'pending while open,
   'answered-but-unverified while it waits on the issuer."
  (cond ((store-challenge-verdict-field c))
        ((challenge-expired? c now) 'failed)
        ((eq? (store-challenge-state c) 'answered) 'unverified)
        (else 'pending)))
