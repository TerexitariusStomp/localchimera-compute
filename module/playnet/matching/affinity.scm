;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; matching/affinity.scm — classification affinity between needs and offers.
;;;
;;; The taxonomy-side of matching: two slots are affine when their categories
;;; sit near each other in the folksonomy. This is the ported core of the
;;; match prototype's classifier-tree scoring (category-chain overlap with
;;; distance decay, specificity from match depth, geometric-mean composition),
;;; re-grounded on what this codebase already has:
;;;
;;;   - the chains come from the FOLKSONOMY TEMPLATE (folksonomy/graph.scm
;;;     folksonomy-template) — the commons' own spanning tree — never from a
;;;     second, private taxonomy. A term's chain is its path from the root of
;;;     the cut the caller is looking through (the lens IS the chain source);
;;;   - the categories of a slot are its VF `resource-classified-as` terms
;;;     (schemas.scm three-level model: Classification = loose tags), filtered
;;;     through the shared denylist (category-term?);
;;;   - the deterministic floor is SPEC EQUALITY: two slots naming the same
;;;     resource-specification match at distance 0 before any classifier runs
;;;     (the same floor-then-enrich shape as the log's alias scan).
;;;
;;; Scores compose by GEOMETRIC MEAN — one hard zero vetoes the match, one
;;; missing dimension abstains — which is the same composition rule the match
;;; prototype used and the reason a category gate exists at all: without a
;;; category (or same-spec) signal there is NO match, never a "1.0 because
;;; nothing disagreed".
;;;
;;; Everything here is pure and alist-shaped (the slot-row wire), so the
;;; planner service can score real intents/resources with it while a test
;;; feeds it literal rows.

(define-module (playnet matching affinity)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 hash-table)
  #:use-module ((playnet folksonomy graph) #:select (category-term?))
  #:export (chain-index
            chain-of
            category-overlap
            category-score
            match-specificity
            best-category-match
            quantity-score
            compose-scores
            slot-categories
            score-pair
            match-pool
            %max-category-distance
            %max-chain-depth))

(define (assq-ref alist key)
  (let ((p (and (list? alist) (assq key alist)))) (and p (cdr p))))


;;; ── Chains from the template ────────────────────────────────────────────────
;;; A chain is the path root-child … term through the folksonomy template
;;; (the synthetic "all" root contributes nothing, exactly as in
;;; template->doc). One walk of the tree indexes every term.

(define (chain-index tree)
  "Hash term-id → chain (list of term-ids, broadest first, ending in the
   term itself) over the {id,label,count,children} template TREE."
  (let ((idx (make-hash-table)))
    (let walk ((node tree) (path '()))
      (let* ((id (assq-ref node 'id))
             (path* (if (or (not id) (equal? id "all"))
                        path
                        (append path (list id)))))
        (when (pair? path*)
          (hash-set! idx (last path*) path*))
        (for-each (lambda (c) (walk c path*))
                  (or (assq-ref node 'children) '()))))
    idx))

(define (chain-of idx term-id)
  "TERM-ID's chain in the index, or the term alone when the cut has not
   filed it yet — a flat term still matches itself at distance 0."
  (or (hash-ref idx term-id #f)
      (and (string? term-id) (list term-id))))


;;; ── Chain overlap (the match prototype's category-matcher) ─────────────────

;; Overlap deeper than this many steps above A's leaf is too generic to count
;; as a category match at all (the prototype's MAX_CATEGORY_DISTANCE).
(define %max-category-distance 1)

;; Specificity normalises match depth against the deepest chains folk build
;; in practice (the prototype's MAX_DEPTH).
(define %max-chain-depth 6)

(define (category-overlap chain-a chain-b)
  "The deepest term of CHAIN-A that CHAIN-B also contains, walking A
   leaf→root. Four values: term, distance (steps above A's leaf), and the
   1-indexed match depths in each chain — or #f #f #f #f when disjoint."
  (if (or (null? chain-a) (null? chain-b))
      (values #f #f #f #f)
      (let ((la (length chain-a)))
        (let loop ((i (- la 1)))
          (if (< i 0)
              (values #f #f #f #f)
              (let* ((term (list-ref chain-a i))
                     (j (list-index (lambda (t) (equal? t term)) chain-b)))
                (if j
                    (values term (- la 1 i) (+ i 1) (+ j 1))
                    (loop (- i 1)))))))))

(define (category-score distance)
  "Distance-decayed category score: 1.0 at the shared leaf, 0.2 off per step,
   floored at 0.5 — and #f past %max-category-distance (too generic to use)."
  (and (number? distance)
       (<= distance %max-category-distance)
       (max 0.5 (- 1.0 (* 0.2 distance)))))

(define (match-specificity depth-a depth-b)
  "How SPECIFIC a match is: deep, balanced chains score high; a leaf matched
   against a root scores low. (min/max balance) × (min / %max-chain-depth)."
  (if (or (not depth-a) (not depth-b) (<= depth-a 0) (<= depth-b 0))
      0
      (let ((lo (min depth-a depth-b)) (hi (max depth-a depth-b)))
        (* (/ lo %max-chain-depth) (/ lo hi) 1.0))))

(define (best-category-match idx cats-a cats-b)
  "The best chain overlap over every category pair — an alist
   ((term)(distance)(score)(specificity)) — or #f when no pair overlaps
   within %max-category-distance."
  (let ((best #f))
    (for-each
     (lambda (ca)
       (let ((chain-a (chain-of idx ca)))
         (for-each
          (lambda (cb)
            (call-with-values
                (lambda () (category-overlap chain-a (chain-of idx cb)))
              (lambda (term dist da db)
                (let ((s (and term (category-score dist))))
                  (when (and s (or (not best)
                                   (> s (assq-ref best 'score))
                                   (and (= s (assq-ref best 'score))
                                        (> (match-specificity da db)
                                           (assq-ref best 'specificity)))))
                    (set! best `((term . ,term)
                                 (distance . ,dist)
                                 (score . ,s)
                                 (specificity . ,(match-specificity da db)))))))))
          cats-b)))
     cats-a)
    best))


;;; ── The other dimensions ────────────────────────────────────────────────────

(define (quantity-score need-qty need-unit cap-qty cap-unit)
  "Coverage of the need by the offer: 1.0 when the offer covers it, the
   ratio when partial, 0.5 across unlike units (folk slots default to
   \"each\", so an unlike unit reads as UNKNOWN, not as a veto — the one
   deliberate softening of the prototype's 0.0), and #f (abstain) unless
   both sides are quantified."
  (and (number? need-qty) (> need-qty 0)
       (number? cap-qty) (> cap-qty 0)
       (if (equal? need-unit cap-unit)
           (min 1.0 (/ cap-qty need-qty 1.0))
           0.5)))

(define (compose-scores scores)
  "Geometric mean of the (dim . score) entries that are numbers; #f entries
   abstain. 0 when every dimension abstained or any present dimension is 0."
  (let ((vals (filter-map (lambda (e) (and (number? (cdr e)) (cdr e))) scores)))
    (cond ((null? vals) 0)
          ((any zero? vals) 0)
          (else (expt (fold * 1.0 vals) (/ 1.0 (length vals)))))))

(define (slot-categories row)
  "A slot row's usable categories: its cats, through the shared denylist."
  (filter (lambda (c) (and (string? c) (category-term? c)))
          (or (assq-ref row 'cats) '())))


;;; ── Scoring a pair, matching a pool ─────────────────────────────────────────
;;; Rows are slot-row alists: ((id)(spec)(cats)(qty)(unit) …). EXTRA is the
;;; service's seam for dimensions only it can compute (time overlap over the
;;; real availability-windows): a procedure (need cap → ((dim . score|#f) …)).

(define* (score-pair idx need cap #:key (extra (lambda (n c) '())))
  "Score NEED against CAP: an alist ((score)(term)(distance)(specificity)
   (breakdown)) — or #f when they share no category signal at all. Same
   spec is the deterministic floor: a distance-0 match on the spec itself."
  (let* ((spec-n (assq-ref need 'spec))
         (spec-c (assq-ref cap 'spec))
         (same-spec (and (string? spec-n) (not (string-null? spec-n))
                         (equal? spec-n spec-c)))
         (cat (best-category-match idx (slot-categories need)
                                   (slot-categories cap)))
         (gate (cond (same-spec `((term . ,spec-n) (distance . 0)
                                  (score . 1.0)
                                  (specificity . ,(or (and cat (assq-ref cat 'specificity))
                                                      0.5))))
                     (cat cat)
                     (else #f))))
    (and gate
         (let* ((dims `((category . ,(assq-ref gate 'score))
                        (quantity . ,(quantity-score
                                      (assq-ref need 'qty) (assq-ref need 'unit)
                                      (assq-ref cap 'qty) (assq-ref cap 'unit)))
                        ,@(extra need cap)))
                (score (compose-scores dims)))
           `((score . ,score)
             (term . ,(assq-ref gate 'term))
             (distance . ,(assq-ref gate 'distance))
             (specificity . ,(assq-ref gate 'specificity))
             (breakdown . ,dims))))))

(define* (match-pool idx needs caps #:key (threshold 0.5) (limit 20)
                     (extra (lambda (n c) '())))
  "Every need against every offer: ((need . id) (hits . (match-row …))) per
   need, hits above THRESHOLD, best first, at most LIMIT. A match-row is the
   score-pair alist plus the capacity's (id)."
  (map
   (lambda (need)
     (let* ((hits (filter-map
                   (lambda (cap)
                     (let ((m (score-pair idx need cap #:extra extra)))
                       (and m (>= (assq-ref m 'score) threshold)
                            (cons (cons 'id (assq-ref cap 'id)) m))))
                   caps))
            (sorted (sort hits (lambda (a b)
                                 (> (assq-ref a 'score) (assq-ref b 'score))))))
       `((need . ,(assq-ref need 'id))
         (hits . ,(if (> (length sorted) limit)
                      (take sorted limit)
                      sorted)))))
   needs))
