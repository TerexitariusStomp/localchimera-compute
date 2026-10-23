;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/machine/swarm.scm — the swarm record: the claims that
;;; compose one task no single tab could run.
;;;
;;; A swarm is a COORDINATION record, never a billing entity — one job
;;; still mints one claim, receipts still settle claim by claim, and a
;;; preempted shard requeues like any job. What the record adds is the
;;; shape the shards share: which jobs are the fan-out (borrower-opened),
;;; and — through the doors — a signal bus only the swarm's members may
;;; speak on.
;;;
;;; THE PARTS:
;;;   • <swarm> — the record: id, borrower, commune, job-ids (index in the
;;;     list IS shard-index), created-at.
;;;   • ^swarm-store — the shelf: open! / of / all. Policy (who may open,
;;;     who is a member) lives in the doors; the shelf holds records.
;;;   • swarm-bus-key — the signal-store key the doors post/read under.
;;;
;;; Member traffic rides the per-commune ^signal-store keyed "swarm:<id>"
;;; — the bus is the same rendezvous a claim's relay legs already use,
;;; just an N-party key instead of a two-party one. This module holds no
;;; registry import so registry.scm may register ^swarm-store in its
;;; persistence env without a cycle; the membership read lives door-side
;;; where the registry is already in hand.

(define-module (playnet machine swarm)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module ((playnet utils store-utils) #:select (serialize-hashmap
                                                     hashmap-filter))
  #:export (<swarm> make-swarm swarm?
            swarm-id swarm-borrower-did swarm-commune-aid
            swarm-job-ids swarm-created-at
            swarm->list list->swarm
            ^swarm-store spawn-swarm-store
            swarm-bus-key))

(define-record-type <swarm>
  (%make-swarm id borrower-did commune-aid job-ids created-at)
  swarm?
  (id          swarm-id)           ; string — the borrower's name for it
  (borrower-did swarm-borrower-did)
  (commune-aid  swarm-commune-aid)
  (job-ids      swarm-job-ids)     ; list of job ids — index = shard-index
  (created-at   swarm-created-at)) ; epoch ms

(define* (make-swarm #:key id borrower-did commune-aid job-ids created-at)
  (unless (and (string? id) (not (string-null? id)))
    (error "swarm: id must be a non-empty string" id))
  (unless (string? borrower-did)
    (error "swarm: borrower-did must be a string" borrower-did))
  (unless (string? commune-aid)
    (error "swarm: commune-aid must be a string" commune-aid))
  (unless (and (list? job-ids) (every string? job-ids))
    (error "swarm: job-ids must be a list of job id strings" job-ids))
  (unless (number? created-at)
    (error "swarm: created-at must be a number" created-at))
  (%make-swarm id borrower-did commune-aid job-ids created-at))

(define (swarm->list s)
  (list (swarm-id s) (swarm-borrower-did s) (swarm-commune-aid s)
        (swarm-job-ids s) (swarm-created-at s)))

(define (list->swarm l)
  (make-swarm #:id (list-ref l 0) #:borrower-did (list-ref l 1)
              #:commune-aid (list-ref l 2) #:job-ids (list-ref l 3)
              #:created-at (list-ref l 4)))


;;; ── the shelf ────────────────────────────────────────────────────────────

(define (^swarm-store bcom swarms)
  (methods
    ;; open! is idempotent by id — a re-open of a live swarm answers the
    ;; record already on the shelf; the swarm's jobs and their claims are
    ;; the live state, the record is only the fan-out's shape.
    ((open! s)
     (bcom (^swarm-store bcom (hashmap-set swarms (swarm-id s) s))
           s))
    ((of id)      (hashmap-ref swarms id #f))
    ((all)        (hashmap-filter (lambda (v) #t) swarms))
    ((portrait)   (list 'swarm-store (serialize-hashmap swarms swarm->list)))))

(define (spawn-swarm-store)
  (spawn ^swarm-store (hashmap)))


;;; ── the bus key ──────────────────────────────────────────────────────────

(define (swarm-bus-key swarm-id)
  (string-append "swarm:" swarm-id))
