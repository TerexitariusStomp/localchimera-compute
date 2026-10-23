;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; store-utils.scm — Shared utilities for Goblins store actors
;;;
;;; Provides hashmap helpers, ID generation, and ISO datetime parsing
;;; used by all store actors.

(define-module (playnet utils store-utils)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils clock) #:select (civil->instant instant->unix (now . clock-now) clock-stood?))
  #:export (hashmap-values hashmap-keys hashmap-filter hashmap-filter-pairs
            hashmap-map-values hashmap-count hashmap-find hashmap-any?
            serialize-hashmap deserialize-hashmap generate-id iso-datetime->epoch
            meta-rows-with-prefix))



;; =========================================================================
;; Hashmap helpers
;; =========================================================================

(define (hashmap-values hm)
  "Return all values in hashmap HM as a list."
  (hashmap-fold (lambda (_k v acc) (cons v acc)) '() hm))

(define (hashmap-keys hm)
  "Return all keys in hashmap HM as a list."
  (hashmap-fold (lambda (k _v acc) (cons k acc)) '() hm))

(define (hashmap-filter pred hm)
  "Return a list of values from HM where (pred value) is true."
  (hashmap-fold (lambda (_k v acc)
                  (if (pred v) (cons v acc) acc))
                '() hm))

(define (hashmap-filter-pairs pred hm)
  "Return a new hashmap containing only entries where (pred key value) is true."
  (hashmap-fold (lambda (k v acc)
                  (if (pred k v) (hashmap-set acc k v) acc))
                (hashmap)
                hm))

(define (hashmap-map-values f hm)
  "Return a new hashmap with f applied to each value."
  (hashmap-fold (lambda (k v acc)
                  (hashmap-set acc k (f v)))
                (hashmap)
                hm))

(define (hashmap-count hm)
  "Return the number of entries in hashmap HM."
  (hashmap-fold (lambda (_k _v acc) (+ acc 1)) 0 hm))

(define (hashmap-find pred hm)
  "Return the first value in HM where (pred value) is true, or #f."
  (call/cc
    (lambda (return)
      (hashmap-fold (lambda (_k v _acc)
                      (when (pred v) (return v))
                      #f)
                    #f hm)
      #f)))

(define (hashmap-any? pred hm)
  "Return #t if any value in HM satisfies pred."
  (call/cc
    (lambda (return)
      (hashmap-fold (lambda (_k v _acc)
                      (when (pred v) (return #t))
                      #f)
                    #f hm)
      #f)))

;; =========================================================================
;; Meta rows by key prefix
;; =========================================================================

(define (meta-rows-with-prefix all-meta prefix)
  "The (key . value) rows of ALL-META — a plan-store's all-meta alist — whose
   string key begins with PREFIX. Keys are composite strings like \"oi|w|s|c\"
   and \"invitation|<id>\"; the prefix is the family. Compared by hand, not
   string-prefix?, because this module is compiled for Hoot as well."
  (let ((n (string-length prefix)))
    (filter (lambda (kv)
              (let ((k (car kv)))
                (and (string? k)
                     (>= (string-length k) n)
                     (string=? (substring k 0 n) prefix))))
            all-meta)))

;; =========================================================================
;; Serialization helpers for persistence
;; =========================================================================

(define (serialize-hashmap hm record->list-fn)
  "Serialize a hashmap of id -> record to a hashmap of id -> list."
  (hashmap-map-values record->list-fn hm))

(define (deserialize-hashmap hm list->record-fn)
  "Deserialize a hashmap of id -> list back to id -> record."
  (hashmap-map-values list->record-fn hm))

;; =========================================================================
;; ID generation
;; =========================================================================

;; Hoot has no `random`: a browser mints ids from a counter spread over the range,
;; which the clock stamp beside it keeps unique across sessions.
(cond-expand (guile)
 (else
  (define %id-counter 0)
  (define (random n)
    (set! %id-counter (+ %id-counter 1))
    (modulo (* 2654435761 %id-counter) n))))

;; On a stood clock (a recording, utils/clock.scm stand-clock!) the ids are
;; counted in the order they are asked for, so the recording reads the same on
;; every run.
(define %serial 0)
(define (generate-id prefix)
  "Generate a unique ID with the given prefix."
  (string-append prefix
                 (number->string (if (clock-stood?)
                                     (begin (set! %serial (+ %serial 1)) %serial)
                                     (random 1000000000)))
                 "-"    (number->string (clock-now))))

;; =========================================================================
;; ISO datetime parsing
;; =========================================================================

(define (iso-datetime->epoch str)
  "Parse an ISO 8601 datetime string (civil UTC label) to an instant on the
   one clock — (playnet utils clock), GPS scale by default.
   Handles: \"2026-03-27T00:00:00Z\" and \"2026-03-27T12:30:00.000Z\".
   Falls back to 0 on parse failure."
  (or (civil->instant str) 0))
