;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; first-person/sybil-detect.scm — advisory analysis over the PHC + VRC graph
;;;
;;; Pure functions; nothing in this module mutates the store or revokes
;;; credentials. The output is **advisory data for human governance**:
;;; the deepest line of Sybil resistance is structural (validated labor
;;; gates voice — see III.3 of docs/governance/economy.md), so this
;;; layer's job is to *surface* anomalies, not to act unilaterally on
;;; them. Auto-revocation is explicitly out of scope.
;;;
;;; Two heuristics:
;;;
;;;   (1) **Sponsor fan-out anomaly.** A sponsor's PHC count exceeds
;;;       max(FLOOR, MULTIPLE × MEDIAN), where the median includes
;;;       silent peers (zero-padded). Surfaces "one corrupted
;;;       introducer" without false-flagging the only sponsor in a
;;;       small ecosystem.
;;;
;;;   (2) **Closed mutual clique.** A subset of PHC-holders that (a)
;;;       forms a complete mutual-vouching clique (every pair has
;;;       reciprocal VRCs) AND (b) has zero out-edges to the rest of
;;;       the ecosystem. Real communities rarely form perfect cliques
;;;       and almost always leak edges; Sybil clusters cosplay
;;;       community by mutual full-vouching inside a closed loop.
;;;
;;; Part of the OpenVTC layer.

(define-module (playnet keri first-person sybil-detect)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri first-person credentials)
  #:use-module (playnet keri first-person predicates)
  #:use-module (goblins utils hashmap)
  #:use-module (goblins)
  #:export (canon-pair sponsor-fanout-counts median-of suspicious-sponsors
            live-vrc-edges mutual-pair-set mutual-neighbours component-of
            mutual-clique? out-edge-count unique-components suspicious-clusters
            detect-suspicious-subgraphs vrc-edges))

;; =========================================================================
;; Pair canonicalization — one place, used everywhere.
;; =========================================================================

(define (canon-pair a b)
  "Order an unordered pair canonically by string< so two views of the
   same edge produce the same key."
  (if (string<? a b) (cons a b) (cons b a)))


;; =========================================================================
;; Heuristic 1 — sponsor fan-out anomaly
;; =========================================================================

(define (sponsor-fanout-counts acdc-store ecosystem-aid)
  "Alist (sponsor-aid . count) of how many live PHCs each sponsor has
   issued in ECOSYSTEM-AID. Sponsors who issued nothing don't appear."
  (hashmap-fold
    (lambda (k v acc) (cons (cons k v) acc))
    '()
    (fold (lambda (c acc)
            (let ((sp (cred-claim c 'sponsor-aid)))
              (cond
                ((and sp (phc-live? c))
                 (hashmap-set acc sp (+ 1 (hashmap-ref acc sp 0))))
                (else acc))))
          (hashmap)
          (phcs-by-ecosystem acdc-store ecosystem-aid))))

(define (median-of nums)
  "Median of NUMS; 0 for empty (so it composes with `max FLOOR …`)."
  (cond
    ((null? nums) 0)
    (else
     (let* ((sorted (sort (list-copy nums) <))
            (n      (length sorted))
            (mid    (quotient n 2)))
       (if (odd? n)
           (list-ref sorted mid)
           (/ (+ (list-ref sorted (- mid 1))
                 (list-ref sorted mid))
              2))))))

(define* (suspicious-sponsors acdc-store ecosystem-aid
                              #:key (multiple 3) (floor 3))
  "Sponsors whose live-PHC count exceeds MAX(FLOOR, MULTIPLE × MEDIAN).
   Median is computed over all PHC-holders zero-padded — so 'one big
   sponsor among silent peers' surfaces correctly, instead of being
   masked by being its own median."
  (let* ((counts   (sponsor-fanout-counts acdc-store ecosystem-aid))
         (holders  (length (phcs-in-ecosystem acdc-store ecosystem-aid)))
         (zero-pad (max 0 (- holders (length counts))))
         (vals     (append (map cdr counts) (make-list zero-pad 0)))
         (cutoff   (max floor (* multiple (median-of vals)))))
    (filter (lambda (entry) (> (cdr entry) cutoff)) counts)))


;; =========================================================================
;; Heuristic 2 — closed mutual clique
;; =========================================================================

(define (live-vrc-edges acdc-store)
  "Live VRCs as a list of (issuer . holder) directed-edge pairs."
  (let ((now (instant->unix (clock-now))))
    (filter-map
      (lambda (c)
        (and (cred-live-at? c now)
             (cons (cred-issuer c) (cred-holder c))))
      ($ acdc-store 'by-schema *schema-playnet-relationship*))))

(define (mutual-pair-set edges)
  "Hashmap (canon-pair) → #t for every {a,b} with both directions
   present in EDGES. Hashmap-as-set: O(1) membership."
  (let ((directed (fold (lambda (e acc)
                          (hashmap-set acc e #t))
                        (hashmap) edges)))
    (fold (lambda (e acc)
            (let ((a (car e)) (b (cdr e)))
              (cond
                ((hashmap-ref directed (cons b a) #f)
                 (hashmap-set acc (canon-pair a b) #t))
                (else acc))))
          (hashmap) edges)))

(define (mutual-neighbours pair-set aids)
  "Hashmap aid → list of mutual neighbours, derived from PAIR-SET."
  (fold (lambda (a acc)
          (hashmap-set acc a
            (filter (lambda (b)
                      (and (not (equal? a b))
                           (hashmap-ref pair-set (canon-pair a b) #f)))
                    aids)))
        (hashmap) aids))

(define (component-of seed neighbours)
  "BFS the connected component of SEED in the mutual-neighbour graph.
   Returns the component as a list of AIDs."
  (let loop ((frontier (list seed)) (seen (list seed)))
    (cond
      ((null? frontier) seen)
      (else
       (let* ((ns  (hashmap-ref neighbours (car frontier) '()))
              (new (filter (lambda (n) (not (member n seen))) ns)))
         (loop (append (cdr frontier) new) (append seen new)))))))

(define (mutual-clique? cluster pair-set)
  "Every unordered pair in CLUSTER is in PAIR-SET — i.e. CLUSTER is
   complete in the mutual-vouching graph."
  (let loop ((xs cluster))
    (or (null? xs) (null? (cdr xs))
        (and (every (lambda (b)
                      (hashmap-ref pair-set (canon-pair (car xs) b) #f))
                    (cdr xs))
             (loop (cdr xs))))))

(define (out-edge-count cluster edges)
  "Directed edges (a → b) where a ∈ cluster but b ∉ cluster."
  (count (lambda (e)
           (and (member (car e) cluster)
                (not (member (cdr e) cluster))))
         edges))

(define (unique-components aids neighbours)
  "Partition AIDS into connected components in the mutual-neighbour
   graph; each reported once. Folds (components . seen) and returns
   the components on the way out."
  (car
    (fold (lambda (a acc)
            (let ((components (car acc)) (seen (cdr acc)))
              (cond
                ((member a seen) acc)
                (else
                 (let ((c (component-of a neighbours)))
                   (cons (cons c components) (append c seen)))))))
          (cons '() '())
          aids)))

(define* (suspicious-clusters acdc-store ecosystem-aid
                              #:key (min-size 3))
  "Closed mutual-vouching cliques of size ≥MIN-SIZE with zero out-edges
   to non-members. Each entry: ((members . list) (size . int)
   (out-edges . 0))."
  (let* ((aids       (map cred-holder
                          (phcs-in-ecosystem acdc-store ecosystem-aid)))
         (in-eco?    (lambda (e) (and (member (car e) aids)
                                       (member (cdr e) aids))))
         (edges      (filter in-eco? (live-vrc-edges acdc-store)))
         (pair-set   (mutual-pair-set edges))
         (neighbours (mutual-neighbours pair-set aids))
         (suspicious?
           (lambda (c)
             (and (>= (length c) min-size)
                  (mutual-clique? c pair-set)
                  (zero? (out-edge-count c edges))))))
    (filter-map
      (lambda (c)
        (and (suspicious? c)
             `((members   . ,c)
               (size      . ,(length c))
               (out-edges . 0))))
      (unique-components aids neighbours))))


;; =========================================================================
;; Top-level dispatch
;; =========================================================================

(define* (detect-suspicious-subgraphs acdc-store ecosystem-aid
                                      #:key (sponsor-multiple 3)
                                            (sponsor-floor 3)
                                            (cluster-min-size 3))
  "Run both heuristics. Result: ((suspicious-sponsors . list)
   (suspicious-clusters . list)). Empty lists ⇒ no anomalies."
  `((suspicious-sponsors
     . ,(suspicious-sponsors acdc-store ecosystem-aid
                              #:multiple sponsor-multiple
                              #:floor sponsor-floor))
    (suspicious-clusters
     . ,(suspicious-clusters acdc-store ecosystem-aid
                              #:min-size cluster-min-size))))


;; Back-compat aliases — the original API named these without the
;; `live-` / `set` prefix; keep them callable so test-sybil-detect.scm
;; and any external callers don't need to change.
(define vrc-edges    live-vrc-edges)
