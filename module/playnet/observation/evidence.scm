;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; evidence.scm — the picture a reading was made from, by its hash
;;;
;;; A photo read keeps its picture on the device and names it on the reading by
;;; sha256 (docs/observation/capture.md §9). The hash rides the count's events
;;; as a classification tag, evidence:<hash>, the way count-of:<resource> names
;;; what a record counts, and the observation credential carries it as a claim
;;; of its own. A verifier handed the picture later checks it against the claim.
;;;
;;; Pure over strings.

(define-module (playnet observation evidence)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet vf facts agent-tags) #:select (tag-values))
  #:export (%evidence-hash-prefix %evidence-hash-digits %evidence-tag-prefix
            evidence-hash? evidence-tag tags-evidence))

(cond-expand (guile) (else
  (define (string-every pred s)            ; whether PRED holds of every character of S (Hoot has no srfi-13)
    (let loop ((i 0))
      (or (= i (string-length s))
          (and (pred (string-ref s i)) (loop (+ i 1))))))))


(define %evidence-hash-prefix "sha256:")
(define %evidence-hash-digits 64)
(define %evidence-tag-key "evidence")
(define %evidence-tag-prefix (string-append %evidence-tag-key ":"))

(define (evidence-hash? s)
  "S is a picture's hash as a reading carries it: sha256: and sixty-four
   lower-case hex digits."
  (and (string? s)
       (= (string-length s) (+ (string-length %evidence-hash-prefix) %evidence-hash-digits))
       (string-prefix? %evidence-hash-prefix s)
       (string-every (lambda (c) (or (char-numeric? c) (memv c '(#\a #\b #\c #\d #\e #\f))))
                     (substring s (string-length %evidence-hash-prefix)))))

(define (evidence-tag hash)
  "The classification tag that names HASH on an event."
  (string-append %evidence-tag-prefix hash))

(define (tags-evidence tags)
  "The picture hash a list of classification tags names, or #f."
  (find evidence-hash? (tag-values (or tags '()) %evidence-tag-key)))
