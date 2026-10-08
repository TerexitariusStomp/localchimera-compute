;;; federation-b.scm — Layer 1, Option B: fragment-stream federation
;;;
;;; Each scope hosts a ^fragment-leaf that, given a demand, returns a
;;; ^stream-actor emitting unit (or chunk) contributions one at a time.
;;; The coordinator fans out, opens one stream per leaf, and pulls with
;;; fair interleaving until the demand is met or every stream exhausts.
;;;
;;; Shape contrast with Option A (federation-a.scm):
;;;   A: one fan-out, each leaf returns a full ranked plan (5-8 KB/plan).
;;;      Few messages, deep per-message payloads.
;;;   B: many fan-outs (~unit-count messages), each ~100 B. Many messages,
;;;      tiny per-message payloads.
;;;
;;; Where each wins (see project_federation_ab.md):
;;;   - Fast-RTT internet, deep recipes: A (fewer RTTs dominate)
;;;   - LoRa / Reticulum, bandwidth-starved: B (tiny packets beat big)
;;;
;;; Coordinator emits the same federation-result alist shape as A, so
;;; downstream consumers (harmony aggregator, retraction, etc.) don't
;;; need to know which transport produced it.
;;;
;;; Fair interleaving rides on ^stream-actor from (playnet deprecated kanren-goblins):
;;; each pull is one turn of the stream's vat; the coordinator's queue
;;; rotation prevents any one leaf from monopolizing.
;;;
;;; NOT Hoot-compatible — uses goblins (native Guile only).

(define-module (playnet deprecated federation-b)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet deprecated kanren-goblins)
  #:use-module (playnet deprecated vat-federation)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:export (^fragment-leaf spawn-fragment-leaf
            federate-fragments federate-fragments-resilient
            combine-fragments))


;;; ── ^fragment-leaf ──────────────────────────────────────────────────
;;;
;;; Inventory-backed. `chunk-size` controls fragment granularity:
;;;   1  — pure unit fragments, maximum interleaving fairness, worst case
;;;        RTT per unit (right for LoRa).
;;;   N  — batches of N units per fragment. Fewer messages, less fairness,
;;;        still small payloads.
;;;
;;; cost-fn: optional (spec → number) attached to each fragment so the
;;; coordinator can future-stop early on cost-weighted budgets.

(define (^fragment-leaf bcom scope-id inventory cost-fn chunk-size)
  (methods
    ((describe) scope-id)
    ((stream-for demand)
     (let* ((spec (car demand))
            (have (or (assoc-ref inventory spec) 0)))
       (stream->actor
         (fragment-stream scope-id spec have cost-fn chunk-size))))))


(define* (spawn-fragment-leaf scope-id inventory
                              #:key (cost-fn #f) (chunk-size 1))
  "Spawn a ^fragment-leaf. INVENTORY is an alist of (spec . qty).
   CHUNK-SIZE sets the per-fragment batch size; default 1 (pure units)."
  (spawn ^fragment-leaf scope-id inventory cost-fn chunk-size))


(define (fragment-stream scope-id spec remaining cost-fn chunk-size)
  "Kanren-style stream of fragments (nil | pair | thunk) suitable for
   ^stream-actor. Each pair is (fragment . thunk-of-rest)."
  (cond
    ((<= remaining 0) '())
    (else
     (let ((qty (min chunk-size remaining)))
       (cons `((scope . ,scope-id)
               (spec  . ,spec)
               (qty   . ,qty)
               (cost  . ,(if cost-fn (cost-fn spec) 0)))
             (lambda ()
               (fragment-stream scope-id spec (- remaining qty)
                                cost-fn chunk-size)))))))


;;; ── Coordinator ─────────────────────────────────────────────────────

(define (federate-fragments leaf-refs demand)
  "Fan out DEMAND = (spec qty) to LEAF-REFS. Open one fragment-stream
   per leaf in parallel, then pull with fair interleaving until demand
   is met or every stream exhausts. Returns a vow of a federation-result
   structurally compatible with federation-a.scm's output.

   Strict: any broken leaf during stream-setup or pull breaks the
   federation. Use federate-fragments-resilient otherwise."
  (let ((spec (car demand))
        (need (cadr demand)))
    (on (vow-all (map (lambda (ref) (<- ref 'stream-for demand)) leaf-refs))
        (lambda (streams)
          (on (pull-until-met streams spec need)
              (lambda (fragments) (combine-fragments fragments demand))
              #:promise? #t))
        #:promise? #t)))


(define (pull-until-met streams spec need)
  "Pull fragments from STREAMS with fair queue-rotation until qty-sum
   reaches NEED or all streams exhaust. Returns a vow of a fragment list
   in pull order."
  (let-values (((p r) (spawn-promise-and-resolver)))
    (let loop ((queue streams) (remaining need) (acc '()))
      (cond
        ((or (<= remaining 0) (null? queue))
         (<-np r 'fulfill (reverse acc)))
        (else
         (on (<- (car queue) 'next)
             (lambda (cell)
               (cond
                 ((not cell)
                  (loop (cdr queue) remaining acc))
                 (else
                  (let* ((frag (car cell))
                         (tail (cdr cell))
                         (qty  (or (assq-ref frag 'qty) 0)))
                    (loop (append (cdr queue) (list tail))
                          (- remaining qty)
                          (cons frag acc))))))
             #:catch
             (lambda (e) (<-np r 'break e))))))
    p))


(define (federate-fragments-resilient leaf-refs demand)
  "Broken leaves drop out of the pull queue instead of breaking the
   federation. A broken stream-setup (leaf unreachable) becomes an
   empty stream; a broken next during pulls drops that stream from
   the queue. Returns a vow of a federation-result."
  (let ((spec (car demand))
        (need (cadr demand)))
    (with-sever-handling
      leaf-refs
      (lambda (ref reason)
        (format (current-error-port)
                "[federation-b] peer severed: ~a (reason: ~a)~%" ref reason))
      (lambda ()
        (on (vow-allsettled
              (map (lambda (ref) (<- ref 'stream-for demand)) leaf-refs))
            (lambda (outcomes)
              (let ((live-streams
                      (filter-map (lambda (o)
                                    (and (eq? (car o) 'fulfilled) (cdr o)))
                                  outcomes)))
                (on (pull-until-met/resilient live-streams spec need)
                    (lambda (fragments) (combine-fragments fragments demand))
                    #:promise? #t)))
            #:promise? #t)))))


(define (pull-until-met/resilient streams spec need)
  "Like pull-until-met, but per-stream break during `next` drops that
   stream silently rather than breaking the whole federation."
  (let-values (((p r) (spawn-promise-and-resolver)))
    (let loop ((queue streams) (remaining need) (acc '()))
      (cond
        ((or (<= remaining 0) (null? queue))
         (<-np r 'fulfill (reverse acc)))
        (else
         (on (<- (car queue) 'next)
             (lambda (cell)
               (cond
                 ((not cell)
                  (loop (cdr queue) remaining acc))
                 (else
                  (let* ((frag (car cell))
                         (tail (cdr cell))
                         (qty  (or (assq-ref frag 'qty) 0)))
                    (loop (append (cdr queue) (list tail))
                          (- remaining qty)
                          (cons frag acc))))))
             #:catch
             (lambda (_e)
               (loop (cdr queue) remaining acc))))))
    p))


;;; ── Aggregator ──────────────────────────────────────────────────────

(define (combine-fragments fragments demand)
  "Group FRAGMENTS by scope, emit a federation-result matching A's shape.
   Per-scope allocations carry the aggregated qty; fragments are preserved
   in pull order for audit / downstream inspection."
  (let* ((spec (car demand))
         (need (cadr demand))
         (per-scope (make-hash-table))
         (per-cost  (make-hash-table)))
    (for-each
      (lambda (frag)
        (let ((sid  (assq-ref frag 'scope))
              (qty  (or (assq-ref frag 'qty) 0))
              (cost (or (assq-ref frag 'cost) 0)))
          (hash-set! per-scope sid (+ (hash-ref per-scope sid 0) qty))
          (hash-set! per-cost  sid (+ (hash-ref per-cost  sid 0) cost))))
      fragments)
    (let* ((allocs (hash-map->list
                     (lambda (sid qty)
                       `((scope . ,sid)
                         (spec  . ,spec)
                         (alloc . ,qty)
                         (cost  . ,(hash-ref per-cost sid 0))))
                     per-scope))
           (total   (fold + 0 (map (lambda (a) (assq-ref a 'alloc)) allocs)))
           (residual (max 0 (- need total))))
      `((scope       . federation-b)
        (demand      . ,demand)
        (fragments   . ,fragments)
        (allocations . ,allocs)
        (deficits    . ,(if (> residual 0)
                            `(((scope-id . federation-b)
                               (spec-id  . ,spec)
                               (qty      . ,residual)))
                            '()))
        (surpluses   . ())
        (residual    . ,residual)
        (coherence   . ,(if (zero? need) 1 (/ total need)))))))
