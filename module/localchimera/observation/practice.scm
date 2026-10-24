;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; practice.scm — what a person has practised, across every scope they worked in.
;;;
;;; A work event is recorded in the scope where the work was done, so one
;;; person's practice lies in several observers. The practice of a SKILL is the
;;; person's, wherever it happened: competence decays through idle time and
;;; renews through practice anywhere (skill-law.scm), a conformance threshold
;;; asks for hours the person has, and a profile shows them. One scope's slice
;;; answers none of these.
;;;
;;; The shape is the join the identity-keyed folds use. An observer offers its
;;; practice of a person as ROWS (event-id skill instant hours), each row's
;;; hours already validated by the observer that holds the event (validation is
;;; that observer's: the intents it registered and their satisfaction). The
;;; view joins the rows of every observer by event id: an event reaching the
;;; view twice is one event, and a second scope adds its own events and no
;;; more. Competence and hours are read off the joined rows.
;;;
;;; `make-practice-view` takes the observers to read; each is asked once per
;;; person and the joined rows are kept for the view's life (a solve, a
;;; profile read), so the reads that follow cost a lookup.

(define-module (localchimera observation practice)
  #:use-module (srfi srfi-1)
  #:export (join-by-id practice-rows-join practice-rows-hours practice-rows-dated
            make-practice-view practice-view-hours practice-view-dated))

(define (row-id r) (car r))
(define (row-skill r) (cadr r))
(define (row-instant r) (caddr r))
(define (row-hours r) (cadddr r))

(define (join-by-id id-of lists)
  "LISTS, lists of records told by different scopes, as one list in which a
   record stands once by its ID-OF (the first telling of it): the join the
   identity-keyed folds use. A second scope adds its own records and no more."
  (let ((seen (make-hash-table)))
    (filter (lambda (r)
              (and (not (hash-ref seen (id-of r) #f))
                   (begin (hash-set! seen (id-of r) #t) #t)))
            (append-map identity lists))))

(define (practice-rows-join row-lists)
  "ROW-LISTS, lists of (event-id skill instant hours), as one list in which an
   event stands once."
  (join-by-id row-id row-lists))

(define (practice-rows-hours rows)
  "((skill . hours) …): the validated hours of ROWS, per skill."
  (fold (lambda (r acc)
          (let ((prior (assoc (row-skill r) acc)))
            (if prior
                (map (lambda (p) (if (eq? p prior) (cons (car p) (+ (cdr p) (row-hours r))) p)) acc)
                (append acc (list (cons (row-skill r) (row-hours r)))))))
        '() rows))

(define (practice-rows-dated rows skill)
  "((instant . hours) …): SKILL's practice in ROWS, dated, for the skill's law."
  (filter-map (lambda (r) (and (equal? (row-skill r) skill) (cons (row-instant r) (row-hours r)))) rows))

(define (make-practice-view readers)
  "A view over READERS, procedures (aid → rows): each observer's own practice of
   one person. → a view for `practice-view-hours` and `practice-view-dated`."
  (let ((joined (make-hash-table)))
    (lambda (aid)
      (or (hash-ref joined aid #f)
          (let ((rows (practice-rows-join (map (lambda (read) (read aid)) readers))))
            (hash-set! joined aid rows)
            rows)))))

(define (practice-view-hours view aid)
  "((skill . hours) …) across every scope the view reads."
  (practice-rows-hours (view aid)))

(define (practice-view-dated view aid skill)
  "((instant . hours) …) of AID's practice in SKILL across every scope the view reads."
  (practice-rows-dated (view aid) skill))
