;;; kanren-goblins.scm — Goblins-native µKanren: vat-spanning streams
;;;
;;; Wraps the core miniKanren stream protocol so individual streams can
;;; live as actor refs, possibly on different vats. Pulling one answer
;;; from a stream is one turn of whatever vat owns it. Goblins' turn
;;; scheduler provides the temporal fairness that interleaving needs —
;;; no single stream can monopolize search time.
;;;
;;; See docs/kan-comp/KAN.md for the philosophical frame (interleaving
;;; as a temporal fairness guarantee) and docs/kan-comp/GOBLINS-KANREN.md
;;; for this wrapper's design rationale.
;;;
;;; A wrapped stream is an actor with one method:
;;;   (next)  →  #f                      ; stream exhausted
;;;           |  (cons head tail-ref)    ; tail-ref is another stream-actor
;;;
;;; Tail is always another actor ref, so laziness and remote-ness are
;;; uniform: pulling the tail means sending a message.
;;;
;;; NOT Hoot-compatible — uses goblins (native Guile only).

(define-module (playnet deprecated kanren-goblins)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-11)
  #:export (^stream-actor
            stream->actor
            run-dist-interleave))


;;; ── ^stream-actor ──────────────────────────────────────────────────────────
;;;
;;; Wraps a local kanren-style stream (one of: '(), pair, thunk) as an
;;; actor. Each actor represents one cell of the stream — calling (next)
;;; forces any thunks in front of the first pair, spawns a new
;;; stream-actor for the tail, and returns (head . tail-ref). When the
;;; underlying stream is exhausted it returns #f.

(define (^stream-actor bcom stream)
  (methods
   ((next)
    (let force ((s stream))
      (cond
       ((null? s) #f)
       ((procedure? s) (force (s)))
       ((pair? s)
        (cons (car s) (spawn ^stream-actor (cdr s))))
       (else (error "^stream-actor: malformed stream" s)))))))


;;; ── stream->actor ──────────────────────────────────────────────────────────
;;;
;;; Convenience: spawn a ^stream-actor wrapping stream S. Must be called
;;; inside a vat turn (typically via with-vat).

(define (stream->actor s)
  (spawn ^stream-actor s))


;;; ── run-dist-interleave ────────────────────────────────────────────────────
;;;
;;; Pull up to N answers from a list of stream-actor refs, interleaving
;;; fairly by queue rotation: pull from head, put tail-ref at back.
;;; Exhausted streams drop out of the queue. Returns a vow resolving to
;;; the answer list (in pull order).
;;;
;;; Fairness: each step is one message send to whichever stream is at
;;; the head of the queue. Rotation after each successful pull means no
;;; single stream dominates — if two infinite streams both produce,
;;; answers arrive alternately (modulo vat scheduling noise).
;;;
;;; This is the direct analog of microKanren's `mplus`, generalized to
;;; span vats: the "force thunk" branch becomes "await <- ref 'next".

(define (run-dist-interleave n refs)
  (let-values (((p r) (spawn-promise-and-resolver)))
    (let loop ((queue refs) (acc '()) (remaining n))
      (cond
       ((or (<= remaining 0) (null? queue))
        (<-np r 'fulfill (reverse acc)))
       (else
        (on (<- (car queue) 'next)
            (lambda (result)
              (cond
               ((not result)
                (loop (cdr queue) acc remaining))
               (else
                (loop (append (cdr queue) (list (cdr result)))
                      (cons (car result) acc)
                      (- remaining 1)))))
            #:catch
            (lambda (e) (<-np r 'break e))))))
    p))
