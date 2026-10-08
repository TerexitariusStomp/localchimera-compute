;;; located.scm — a located key is a value; these are its constructors and
;;; its readers, stated once.
;;;
;;; The engine addresses everything by strings: a good at a cell
;;; ("spec#place@t"), a cell ("place@t"), a column or a labour row with bar
;;; fields ("Lab|skill|cell", "w|id|skill|cell"). Every module that once split
;;; one of these by hand reads it here, so a key's grammar has one home and a
;;; malformed one fails in one place. A key WITHOUT a period (`key-period` #f)
;;; states no period: a cap so keyed names its pool at every period the solve
;;; lays (engine ingest-located!).

(define-module (playnet planner facts located)
  #:use-module (srfi srfi-1)
  #:export (lg cell good-spec located-cell place-of period-of
            key-period key-date key-retime parse-located-good
            bar-fields bar-field key-prefix
            key-terms key-process key-arc))

;; ── constructors ────────────────────────────────────────────────────────────
(define (lg good cell) (string-append good "#" cell))                ; a good at a cell
(define (cell place t) (string-append place "@" (number->string t))) ; a place at a period

;; ── readers of a located good ───────────────────────────────────────────────
(define (good-spec g) (car (string-split g #\#)))        ; the bare spec/good of "spec#cell"
(define (located-cell g) (cadr (string-split g #\#)))    ; the cell of "spec#cell"

;; ── readers of a cell ───────────────────────────────────────────────────────
(define (place-of c) (car (string-split c #\@)))
(define (period-of c) (string->number (cadr (string-split c #\@))))

;; ── the tail after the last @: a period, a date, or nothing ─────────────────
(define (key-date k)
  "What stands after a key's last @, or #f when it has none."
  (let ((at (string-rindex k #\@))) (and at (substring k (+ at 1)))))
(define (key-period k)
  "The period a key names, or #f: none stated, or a date not yet resolved."
  (let ((d (key-date k))) (and d (string->number d))))
(define (key-retime k t)
  "K with its period replaced by T; a period-less key stays as it is."
  (let ((at (string-rindex k #\@)))
    (if at (string-append (substring k 0 at) "@" (number->string t)) k)))

(define (parse-located-good key)
  "\"spec#place@period\" → (spec place period), or #f."
  (let ((h (string-index key #\#)) (at (string-index key #\@)))
    (and h at (list (substring key 0 h)
                    (substring key (+ h 1) at)
                    (or (string->number (substring key (+ at 1))) 0)))))

;; ── bar keys: "prefix|field|field…" ─────────────────────────────────────────
(define (bar-fields k) (string-split k #\|))
(define (bar-field k i)
  "The I-th bar field of K, or #f when K has fewer."
  (let ((fs (bar-fields k))) (and (> (length fs) i) (list-ref fs i))))
(define (key-prefix key) (car (bar-fields key)))

;; ── what a column is made of: the ONE reader of a column key ─────────────────
;; Every key the engine emits is a pure function of (key, flows), so a column's
;; TERMS — the nodes of the shared classifications it stands in — are derived,
;; never stamped. `key-terms` is the single place a key is split; every door that
;; asks "which process / place / period / worker is this column" reads it, and a
;; part (parts.scm) is matched against the same alist a work event's terms are
;; read into (observer `event-terms`). One grammar for columns and hours.
;;
;;   p|proc|cell     → tag p, process, place, period
;;   p|proc|a|b      → + arc (a . b); place and period of the origin a
;;   m|good|a|b      → prefix m, good, arc
;;   w|id|skill|cell, wr|…  → worker, skill, place, period
;;   r|id|spec|cell  → supplier, means, place, period
;;   acq|row         → prefix acq, row
;;   anything else   → its prefix alone
(define (cell-terms cl)
  (if (and (string? cl) (string-index cl #\@))
      (list (cons 'cell cl) (cons 'place (place-of cl)) (cons 'period (period-of cl)))
      '()))
(define (key-terms key)
  (let* ((p (string-split key #\|)) (prefix (car p)) (n (length p)))
    (cons (cons 'prefix prefix)
          (cond ((and (equal? prefix "p") (= n 3))
                 (cons (cons 'process (cadr p)) (cell-terms (caddr p))))
                ((and (equal? prefix "p") (= n 4))
                 (cons* (cons 'process (cadr p)) (cons 'arc (cons (caddr p) (cadddr p))) (cell-terms (caddr p))))
                ((and (equal? prefix "m") (= n 4))
                 (cons* (cons 'good (cadr p)) (cons 'arc (cons (caddr p) (cadddr p))) (cell-terms (caddr p))))
                ((and (member prefix '("w" "wr")) (= n 4))
                 (cons* (cons 'worker (cadr p)) (cons 'skill (caddr p)) (cell-terms (cadddr p))))
                ((and (equal? prefix "r") (= n 4))
                 (cons* (cons 'supplier (cadr p)) (cons 'means (caddr p)) (cell-terms (cadddr p))))
                ((and (equal? prefix "acq") (= n 2)) (list (cons 'row (cadr p))))
                (else '())))))
;; the three readings every other site takes off a key: its prefix (the kind
;; of column), its process (#f unless a p| column), its arc (#f unless a haul
;; or a hold). A site that needs more reads key-terms whole.
(define (key-process key) (assq-ref (key-terms key) 'process))
(define (key-arc key) (assq-ref (key-terms key) 'arc))
