;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; folksonomy/pins.scm — collections of map pins, folded like the folksonomy.
;;;
;;; A LIST is a name and a face a citizen gives to a set of places on the map
;;; ("Squats", "Veggie eat spots", 🌱); a PIN is one thing on the map filed
;;; under it, with a note of the citizen's own. graph.scm folds each AID's
;;; term↔term nestings into a scope's taxonomy; this folds each AID's
;;; list↔subject filings into a scope's PIN BOOK, by the same monoid shape:
;;; a distinct (list · subject) assertion carries a COUNT and the AIDs that
;;; made it, an AID re-folds by clearing its own assertions first, and merge
;;; is set-aid over the other side's by-aid index.
;;;
;;; What crosses into the fold is the SHARED half of a citizen's book. A
;;; private list stays in their own doc (the lobby persists the whole book per
;;; AID; only `pins-doc-public` reaches the aggregator), and a note never
;;; folds at all — it is the citizen's own remark, not a fact about the place.
;;; So the scope's pin book reads: which lists people share, how many things
;;; each holds, how many people file a given thing there.
;;;
;;; SUBJECT ids are the map's own row ids — a pooled slot's id, a declared
;;; place's id, a drop point's id, or a bare "spot:lat,lng" for a dropped pin.
;;; The fold never resolves them: a reader joins them to what it can see.

(define-module (localchimera folksonomy pins)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (goblins utils hashmap)
  #:use-module (localchimera vf aggregation fold-node)
  #:export (make-pins pins?
            pins-entries pins-by-aid pins-lists
            pin-list pin-subject pin-count pin-by
            pins-set-aid pins-drop-aid pins-merge
            pins-lists-at pins-in
            make-pins-doc parse-pins-doc pins-doc-public
            pins-monoid ^pins))

(define (assq-ref alist key)
  (let ((p (assq key alist))) (if p (cdr p) #f)))

;;; ── a weighted pin (the aggregate's unit) ──────────────────────────────────

(define (make-pin list subject count by)
  `((list . ,list) (subject . ,subject) (count . ,count) (by . ,by)))
(define (pin-list p)    (assq-ref p 'list))
(define (pin-subject p) (assq-ref p 'subject))
(define (pin-count p)   (or (assq-ref p 'count) 0))
(define (pin-by p)      (or (assq-ref p 'by) '()))

;; a list id never carries a tab, so it is a collision-free key separator
(define (pin-key list subject) (string-append list "\t" subject))

;;; ── the aggregate ──────────────────────────────────────────────────────────
;;; entries : hashmap pin-key → weighted pin
;;; by-aid  : hashmap aid → the pin-keys it asserts (one AID re-folds cheaply)
;;; lists   : hashmap list-id → ((label . _) (emoji . _) (by . (aid …)))
;;; by-list : hashmap list-id → pin-keys (the list's members, an index lookup)

(define-record-type <pins>
  (%make-pins entries by-aid lists by-list)
  pins?
  (entries pins-entries)
  (by-aid  pins-by-aid)
  (lists   pins-lists)
  (by-list pins-by-list))

(define (make-pins) (%make-pins (hashmap) (hashmap) (hashmap) (hashmap)))

(define (adj-add adj id key) (hashmap-set adj id (cons key (hashmap-ref adj id '()))))
(define (adj-del adj id key)
  (let ((v (delete key (hashmap-ref adj id '()))))
    (if (null? v) (hashmap-remove adj id) (hashmap-set adj id v))))

;;; ── drop one AID's whole contribution ──────────────────────────────────────

(define (pins-drop-aid ps aid)
  (let loop ((ks (hashmap-ref (pins-by-aid ps) aid '()))
             (entries (pins-entries ps))
             (by-list (pins-by-list ps)))
    (if (null? ks)
        (%make-pins entries
                    (hashmap-remove (pins-by-aid ps) aid)
                    (lists-without (pins-lists ps) aid)
                    by-list)
        (let* ((k (car ks)) (p (hashmap-ref entries k #f)))
          (if (not p)
              (loop (cdr ks) entries by-list)
              (let ((by* (delete aid (pin-by p)))
                    (n*  (max 0 (- (pin-count p) 1))))
                (if (or (zero? n*) (null? by*))
                    (loop (cdr ks) (hashmap-remove entries k)
                          (adj-del by-list (pin-list p) k))
                    (loop (cdr ks)
                          (hashmap-set entries k
                                       (make-pin (pin-list p) (pin-subject p) n* by*))
                          by-list))))))))

;; a list stands while anyone shares it; its label and face are the latest word
(define (lists-without lists aid)
  (hashmap-fold
   (lambda (id row acc)
     (let ((by* (delete aid (or (assq-ref row 'by) '()))))
       (if (null? by*) acc
           (hashmap-set acc id (cons (cons 'by by*)
                                     (filter (lambda (c) (not (eq? (car c) 'by))) row))))))
   (hashmap) lists))

(define (merge-lists lists aid list-alist)
  "Fold ((id . ((label . _) (emoji . _)))…) in under AID. Latest non-empty
   label and face win, as term labels do in the taxonomy."
  (fold (lambda (pair acc)
          (let* ((id (car pair)) (row (cdr pair))
                 (old (hashmap-ref acc id '()))
                 (pick (lambda (k) (let ((v (assq-ref row k)))
                                     (if (and (string? v) (not (string-null? v))) v
                                         (or (assq-ref old k) "")))))
                 (by (or (assq-ref old 'by) '())))
            (hashmap-set acc id `((label . ,(pick 'label)) (emoji . ,(pick 'emoji))
                                  (by . ,(if (member aid by) by (cons aid by)))))))
        lists list-alist))

;;; ── add one AID's contribution ─────────────────────────────────────────────

(define (pins-set-aid ps aid pin-pairs list-alist)
  "Re-fold AID's entire book. PIN-PAIRS: (list-id . subject-id)…; LIST-ALIST:
   (list-id . ((label . _) (emoji . _)))…. Clears the AID's prior filings
   first, so a smaller republish drops the removed ones."
  (let* ((cleared (pins-drop-aid ps aid))
         (lists   (merge-lists (pins-lists cleared) aid list-alist)))
    (let loop ((pairs (delete-duplicates pin-pairs))
               (entries (pins-entries cleared))
               (by-list (pins-by-list cleared))
               (keys '()))
      (if (null? pairs)
          (%make-pins entries
                      (hashmap-set (pins-by-aid cleared) aid keys)
                      lists by-list)
          (let* ((l (caar pairs)) (s (cdar pairs)) (k (pin-key l s))
                 (p (hashmap-ref entries k #f)))
            (loop (cdr pairs)
                  (hashmap-set entries k
                               (if p (make-pin l s (+ 1 (pin-count p)) (cons aid (pin-by p)))
                                   (make-pin l s 1 (list aid))))
                  (if p by-list (adj-add by-list l k))
                  (cons k keys)))))))

(define (pins-merge a b)
  (hashmap-fold
   (lambda (aid keys acc)
     (pins-set-aid acc aid
                   (filter-map (lambda (k)
                                 (let ((p (hashmap-ref (pins-entries b) k #f)))
                                   (and p (cons (pin-list p) (pin-subject p)))))
                               keys)
                   (hashmap-fold (lambda (id row acc2)
                                   (if (member aid (or (assq-ref row 'by) '()))
                                       (cons (cons id row) acc2) acc2))
                                 '() (pins-lists b))))
   a (pins-by-aid b)))

;;; ── read the aggregate ─────────────────────────────────────────────────────

(define (pins-in ps list-id)
  "The weighted pins filed under LIST-ID."
  (filter-map (lambda (k) (hashmap-ref (pins-entries ps) k #f))
              (hashmap-ref (pins-by-list ps) list-id '())))

(define (pins-lists-at ps)
  "Every shared list: ((id . _) (label . _) (emoji . _) (places . n) (by . n))."
  (hashmap-fold
   (lambda (id row acc)
     (cons `((id . ,id) (label . ,(assq-ref row 'label)) (emoji . ,(assq-ref row 'emoji))
             (places . ,(length (hashmap-ref (pins-by-list ps) id '())))
             (by . ,(length (or (assq-ref row 'by) '()))))
           acc))
   '() (pins-lists ps)))

;;; ── the doc: one citizen's book ────────────────────────────────────────────
;;; ((lists . (((id . _) (label . _) (emoji . _) (shared . #t|#f)) …))
;;;  (pins  . (((list . _) (subject . _) (note . _)) …)))

(define (make-pins-doc lists pins) (list (cons 'lists lists) (cons 'pins pins)))

(define (parse-pins-doc doc)
  "→ ((lists . ((id . ((label . _) (emoji . _)))…)) (pins . ((list . subject)…)))"
  (let* ((ls (or (assq-ref doc 'lists) '()))
         (ps (or (assq-ref doc 'pins) '()))
         (lists (filter-map (lambda (l)
                              (let ((id (assq-ref l 'id)))
                                (and (string? id)
                                     (cons id `((label . ,(or (assq-ref l 'label) ""))
                                                (emoji . ,(or (assq-ref l 'emoji) "")))))))
                            ls))
         (pins (filter-map (lambda (p)
                             (let ((l (assq-ref p 'list)) (s (assq-ref p 'subject)))
                               (and (string? l) (string? s) (cons l s))))
                           ps)))
    `((lists . ,lists) (pins . ,pins))))

(define (pins-doc-public doc)
  "The half of DOC that folds: its shared lists and their pins, notes stripped."
  (let* ((shared (filter (lambda (l) (eq? #t (assq-ref l 'shared)))
                         (or (assq-ref doc 'lists) '())))
         (ids (map (lambda (l) (assq-ref l 'id)) shared)))
    (make-pins-doc
     (map (lambda (l) (filter (lambda (c) (memq (car c) '(id label emoji))) l)) shared)
     (filter-map (lambda (p)
                   (and (member (assq-ref p 'list) ids)
                        `((list . ,(assq-ref p 'list)) (subject . ,(assq-ref p 'subject)))))
                 (or (assq-ref doc 'pins) '())))))

;;; ── the actor: the scope's pin book, one fold-aggregate ────────────────────

(define pins-monoid (make-monoid (make-pins) pins-merge))

(define pins-reads
  `((lists . ,(lambda (ps) (pins-lists-at ps)))
    (pins  . ,(lambda (ps list-id) (pins-in ps list-id)))
    (graph . ,(lambda (ps) ps))))

(define pins-writes
  `((contribute . ,(lambda (ps aid doc)
                     (let ((parsed (parse-pins-doc doc)))
                       (pins-set-aid ps aid (assq-ref parsed 'pins) (assq-ref parsed 'lists)))))
    (drop-aid   . ,(lambda (ps aid) (pins-drop-aid ps aid)))))

(define ^pins (fold-aggregate pins-monoid pins-reads pins-writes #:prefix "pins"))
