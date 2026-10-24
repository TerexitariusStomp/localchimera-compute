;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/utils/alist.scm — generic alist helpers
;;;
;;; Extracted from the (now-deprecated) DDMRP module, where they lived
;;; alongside buffer-zone math but were always generic list-of-pairs
;;; helpers with no DDMRP-specific meaning. UI modules that only need
;;; alist plumbing (not zone classification) should use this instead of
;;; reaching into the retired buffer planner.
;;;
;;; Hoot/WASM compatible.

(define-module (localchimera utils alist)
  #:export (alist-ref
            alist-set
            alist-update
            assq-replace assv-replace assoc-replace))

(define (alist-ref al key . default)
  "Look up KEY in alist AL. Return default (or #f) if not found."
  (let ((pair (assq key al)))
    (if pair
        (cdr pair)
        (if (null? default) #f (car default)))))

(define (alist-set al key val)
  "Return a new alist with KEY set to VAL (replaces existing or adds)."
  (cons (cons key val)
        (filter (lambda (p) (not (eq? (car p) key))) al)))

(define (alist-update al key fn default)
  "Update KEY in AL by applying FN to its current value (or DEFAULT)."
  (alist-set al key (fn (alist-ref al key default))))

;; The core `assq-set!`/`assv-set!`/`assoc-set!` return the updated alist and
;; mutate the pair they find; Hoot has none of them. These return a NEW alist
;; and leave the argument alone: the pair for KEY is replaced where it stands
;; (order kept), or consed on the front when KEY is new — the same result
;; every caller here reads, since each uses only the returned list.
(define (%replace alist key val same?)
  (if (let loop ((l alist)) (and (pair? l) (or (same? (caar l) key) (loop (cdr l)))))
      (map (lambda (p) (if (same? (car p) key) (cons key val) p)) alist)
      (cons (cons key val) alist)))
(define (assq-replace alist key val)  (%replace alist key val eq?))
(define (assv-replace alist key val)  (%replace alist key val eqv?))
(define (assoc-replace alist key val) (%replace alist key val equal?))
