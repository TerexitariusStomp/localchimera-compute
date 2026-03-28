;;; store-utils.scm — Shared utilities for Goblins store actors
;;;
;;; Provides hashmap helpers, ID generation, and ISO datetime parsing
;;; used by all store actors.

(use-modules (goblins utils hashmap)
             (srfi srfi-1))

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

(define (generate-id prefix)
  "Generate a unique ID with the given prefix."
  (string-append prefix (number->string (random 1000000000))
                 "-"    (number->string (current-time))))

;; =========================================================================
;; ISO datetime parsing
;; =========================================================================

(define (iso-datetime->epoch str)
  "Parse an ISO 8601 datetime string to POSIX epoch seconds.
   Handles: \"2026-03-27T00:00:00Z\" and \"2026-03-27T12:30:00.000Z\".
   Falls back to 0 on parse failure."
  (catch #t
    (lambda ()
      (let* ((date-part (substring str 0 10))
             (time-part (if (> (string-length str) 11)
                            (substring str 11 (min 19 (string-length str)))
                            "00:00:00"))
             (year  (string->number (substring date-part 0 4)))
             (month (string->number (substring date-part 5 7)))
             (day   (string->number (substring date-part 8 10)))
             (hour  (string->number (substring time-part 0 2)))
             (min   (string->number (substring time-part 3 5)))
             (sec   (string->number (substring time-part 6 8)))
             (tm (vector sec min hour day (- month 1) (- year 1900)
                         0 0 0 0 "UTC")))
        (car (mktime tm "UTC"))))
    (lambda _args 0)))
