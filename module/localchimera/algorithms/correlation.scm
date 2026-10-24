;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; correlation.scm — Pearson correlation over (timestamp . value) pair streams
;;;
;;; Pure-function leaf. A <covariance-view> holds two stream procedures
;;; (each: (from-ts to-ts) → list of (ts . value) pairs) plus a bucket
;;; width and method. compute-correlation evaluates by bucket-aligning
;;; the two streams and running the method.
;;;
;;; Streams are procedure-valued to keep this module free of governance
;;; dependencies (credentials live in (localchimera credentials …); the adapter
;;; turning an ACDC source into a pairs-thunk lives there — see
;;; credential-stream->pairs-fn in index-oracle.scm).
;;;
;;; ρ(S, I) here is the load-bearing quantity for the rollover pricing
;;; in algorithms/option-premium.scm: the derivative-layer amplifier
;;; N(1-R) in the extractable-premium bound scales by ρ² (OLS R²).

(define-module (localchimera algorithms correlation)
  #:use-module (srfi srfi-1)
  #:export (series-stddev pearson-rho bucketize align-buckets correlate-pairs
            <covariance-view> make-covariance-view covariance-view? covariance-view-id
            covariance-view-stream-a covariance-view-stream-b
            covariance-view-bucket-seconds covariance-view-method compute-correlation)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9))



;; ─────────────────────────────────────────────────────────────────────
;; Pearson correlation — pure
;; ─────────────────────────────────────────────────────────────────────

;; Moved here from option-premium.scm: pure statistics with no option-pricing
;; dependency, and it was the ONLY thing correlation needed from that file —
;; which made the two a genuine import cycle. It belongs beside pearson-rho.
(define (series-stddev values)
  "Standard deviation of a list of numbers."
  (if (or (null? values) (= (length values) 1))
      0
      (let* ((n (length values))
             (mean (/ (fold + 0 values) n))
             (sq-diffs (map (lambda (v) (let ((d (- v mean))) (* d d))) values))
             (variance (/ (fold + 0 sq-diffs) (- n 1))))
        (sqrt variance))))

(define (pearson-rho xs ys)
  "Sample Pearson correlation coefficient. Returns 0 on degenerate
   input (empty, length-mismatched, or zero-variance in either series)."
  (let ((n (length xs)))
    (cond
      ((< n 2) 0)
      ((not (= n (length ys))) 0)
      (else
       (let* ((mx (/ (fold + 0 xs) n))
              (my (/ (fold + 0 ys) n))
              (dxs (map (lambda (x) (- x mx)) xs))
              (dys (map (lambda (y) (- y my)) ys))
              (numer (fold + 0 (map * dxs dys)))
              (sxx (fold + 0 (map (lambda (d) (* d d)) dxs)))
              (syy (fold + 0 (map (lambda (d) (* d d)) dys)))
              (denom (sqrt (* sxx syy))))
         (if (= denom 0) 0 (exact->inexact (/ numer denom))))))))


;; ─────────────────────────────────────────────────────────────────────
;; Timestamp bucketing + alignment
;; ─────────────────────────────────────────────────────────────────────

(define (bucketize pairs from-ts to-ts bucket-seconds)
  "Bucket (ts . value) PAIRS into a sorted (bucket-idx . mean-value)
   alist. Samples outside [from-ts, to-ts] are dropped; empty buckets
   are absent from the result."
  (let ((h (make-hash-table)))
    (for-each
      (lambda (p)
        (let ((ts (car p)) (v (cdr p)))
          (when (and ts v (>= ts from-ts) (<= ts to-ts))
            (let ((idx (inexact->exact
                         (floor (/ (- ts from-ts) bucket-seconds)))))
              (hash-set! h idx (cons v (hash-ref h idx '())))))))
      pairs)
    (sort
      (hash-map->list
        (lambda (k vs) (cons k (/ (fold + 0 vs) (length vs))))
        h)
      (lambda (a b) (< (car a) (car b))))))

(define (align-buckets ba bb)
  "Inner-join two sorted (idx . value) alists on idx.
   Returns (xs . ys) with only buckets present in both."
  (let loop ((a ba) (b bb) (xs '()) (ys '()))
    (cond
      ((or (null? a) (null? b))
       (cons (reverse xs) (reverse ys)))
      ((< (caar a) (caar b)) (loop (cdr a) b xs ys))
      ((> (caar a) (caar b)) (loop a (cdr b) xs ys))
      (else
       (loop (cdr a) (cdr b)
             (cons (cdar a) xs)
             (cons (cdar b) ys))))))


;; ─────────────────────────────────────────────────────────────────────
;; Pure correlation over (ts . value) pair lists
;; ─────────────────────────────────────────────────────────────────────

(define* (correlate-pairs pairs-a pairs-b
                          #:key (from-ts #f) (to-ts #f) (bucket-seconds 86400)
                                (method 'pearson))
  "Align two (ts . value) pair lists into common buckets and correlate.
   Returns an alist:
     ((rho . number) (n . bucket-count) (sigma-a . number) (sigma-b . number)
      (from-ts . seconds) (to-ts . seconds) (bucket-seconds . seconds))."
  (let* ((all-ts (append (map car pairs-a) (map car pairs-b)))
         (eff-from (or from-ts (if (null? all-ts) 0 (apply min all-ts))))
         (eff-to   (or to-ts   (if (null? all-ts) 0 (apply max all-ts))))
         (ba (bucketize pairs-a eff-from eff-to bucket-seconds))
         (bb (bucketize pairs-b eff-from eff-to bucket-seconds))
         (aligned (align-buckets ba bb))
         (xs (car aligned))
         (ys (cdr aligned))
         (rho (case method
                ((pearson) (pearson-rho xs ys))
                (else (error "Unknown correlation method" method)))))
    `((rho            . ,rho)
      (n              . ,(length xs))
      (sigma-a        . ,(series-stddev xs))
      (sigma-b        . ,(series-stddev ys))
      (from-ts        . ,eff-from)
      (to-ts          . ,eff-to)
      (bucket-seconds . ,bucket-seconds))))


;; ─────────────────────────────────────────────────────────────────────
;; <covariance-view> — named, reusable correlation specification
;; ─────────────────────────────────────────────────────────────────────
;;
;; stream-a, stream-b:  procedures (from-ts to-ts) → ((ts . value) ...)
;;                      from-ts / to-ts may be #f for open range.
;;                      Callers build these via credential-stream->pairs-fn
;;                      (in (localchimera credentials …)) or any custom adapter.
;; bucket-seconds:      alignment width. 86400 (daily) is a sane default.
;; method:              'pearson (extensible).

(define-record-type <covariance-view>
  (make-covariance-view id stream-a stream-b bucket-seconds method)
  covariance-view?
  (id              covariance-view-id)
  (stream-a        covariance-view-stream-a)
  (stream-b        covariance-view-stream-b)
  (bucket-seconds  covariance-view-bucket-seconds)
  (method          covariance-view-method))

(define* (compute-correlation view
                              #:key (from-ts #f) (to-ts #f))
  "Evaluate a <covariance-view>: pull both streams (optionally clipped),
   bucket-align, correlate. Returns the alist produced by correlate-pairs."
  (let ((pairs-a ((covariance-view-stream-a view) from-ts to-ts))
        (pairs-b ((covariance-view-stream-b view) from-ts to-ts)))
    (correlate-pairs pairs-a pairs-b
                     #:from-ts from-ts #:to-ts to-ts
                     #:bucket-seconds (covariance-view-bucket-seconds view)
                     #:method (covariance-view-method view))))
