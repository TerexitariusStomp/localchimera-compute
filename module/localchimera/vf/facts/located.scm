;;; SPDX-License-Identifier: AGPL-3.0-or-later
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

(define-module (localchimera vf facts located)
  #:use-module (srfi srfi-1)
  #:export (lg cell good-spec located-cell place-of period-of
            key-period key-date key-retime parse-located-good
            bar-fields bar-field key-prefix
            key-terms key-process key-arc key-dated
            ;; the column keys: one constructor per kind, one predicate per kind
            process-col arc-col carry-col worker-col refresh-col means-col supply-col
            train-col acquire-col floor-col pool-id arc-table-key arc-key-parts
            process-col? carry-col? worker-col? refresh-col? means-col? supply-col?
            train-col? acquire-col? crossing-col? col-prefix? lab-good-skill lab-good-cell
            claim-process claim-process? claim-process-good crossing-process crossing-process?
            bar-good bar-good? bar-spec
            svc-good svc-good? lab-good lab-good? pres-good pres-good?
            el-good el-good? credit-good credit-good?))

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
(define (key-dated k t)
  "K at period T: its period replaced, or stated where it had none (a period-less
   cap names its pool at every period; ingest lays one copy per period by this)."
  (let ((at (string-rindex k #\@)))
    (string-append (if at (substring k 0 at) k) "@" (number->string t))))

(define (parse-located-good key)
  "\"spec#place@period\" → (spec place period), or #f."
  (let ((h (string-index key #\#)) (at (string-index key #\@)))
    (and h at (list (substring key 0 h)
                    (substring key (+ h 1) at)
                    (or (string->number (substring key (+ at 1))) 0)))))

;; ── bar keys: "prefix|field|field…" ─────────────────────────────────────────
;; ── the bar keys: <kind>|<spec>… — one builder and one reader per kind ────────
;; Svc|spec   the per-period SERVICE good of a durable `use`d in a process
;; Lab|skill|cell  the located labour pool of a skill
;; Pres|w     a mover's presence (a person, a means on a ride)
;; El|e       an element row of the chemistry
;; credit|aid a citizen's labour certificate, drawn by their claim columns
(define (bar-good kind spec) (string-append kind "|" spec))
(define (bar-good? kind g) (and (string? g) (string-prefix? (string-append kind "|") g)))
(define (bar-spec g)
  "What stands after the kind of a bar key: Svc|bread → bread."
  (let ((i (string-index g #\|))) (if i (substring g (+ i 1)) g)))
(define (svc-good spec)    (bar-good "Svc" spec))
(define (svc-good? g)      (bar-good? "Svc" g))
(define (lab-good skill cell) (string-append "Lab|" skill "|" cell))
(define (lab-good? g)      (bar-good? "Lab" g))
(define (lab-good-skill g) (bar-field g 1))
(define (lab-good-cell g)  (bar-field g 2))
(define (pres-good w)      (bar-good "Pres" w))
(define (pres-good? g)     (bar-good? "Pres" g))
(define (el-good e)        (bar-good "El" e))
(define (el-good? g)       (bar-good? "El" g))
(define (credit-good aid)  (bar-good "credit" aid))
(define (credit-good? g)   (bar-good? "credit" g))

;; ── the column keys: one constructor per kind ───────────────────────────────
;; Every column the located program lays is named by one of these, and read
;; back by `key-terms` below: a key's grammar has one home, so a kind the reader
;; does not parse cannot be laid, and a site that spells a prefix by hand is a
;; site the lint finds. A field may itself carry a `|` (a hold's process is
;; keep|K~spec, a carried good Pres|w, a pool's supplier cp|rid|t): the reader
;; takes the cells from the END and the field from what stands between.
;;   p|proc|cell       a process run at a cell            (process-col)
;;   p|proc|a|b        a process spanning an arc or a hold (arc-col)
;;   m|good|a|b        a carry of a good along an arc      (carry-col)
;;   w|id|skill|cell   a worker's supply of a skill         (worker-col)
;;   wr|id|skill|cell  a worker's self-maintenance hours    (refresh-col)
;;   mv|id|svc|cell    a mobile means' supply of a service  (means-col)
;;   r|id|spec|cell    a supplier's draw on a spec           (supply-col)
;;   T|w|d@t           a worker's training in a skill        (train-col)
;;   acq|row           a row bought in                       (acquire-col)
;;   kind|spec|…#cell  a budgeted floor's own row           (floor-col)
;;   bg|rid, cp|rid|t  a container pool's supplier id        (pool-id)
;;   a|b|manner        an arc of the travel table            (arc-table-key)
(define (%col . fields) (string-join fields "|"))
(define (process-col proc cell)     (%col "p" proc cell))
(define (arc-col proc a b)          (%col "p" proc a b))
(define (carry-col good a b)        (%col "m" good a b))
(define (worker-col id skill cell)  (%col "w" id skill cell))
(define (refresh-col id skill cell) (%col "wr" id skill cell))
(define (means-col id svc cell)     (%col "mv" id svc cell))
(define (supply-col id spec cell)   (%col "r" id spec cell))
(define (train-col w d t)           (string-append (%col "T" w d) "@" (number->string t)))
(define (acquire-col row)           (%col "acq" row))
(define (floor-col kind spec cell . more) (string-append (apply %col kind spec more) "#" cell))
(define* (pool-id kind rid #:optional t) (if t (%col kind rid (number->string t)) (%col kind rid)))
(define (arc-table-key a b manner) (%col a b manner))
(define (arc-key-parts k)
  "(a b manner) of an arc key of the travel table."
  (let ((p (string-split k #\|))) (list (car p) (cadr p) (caddr p))))

(define (col-prefix? key . kinds) (and (string? key) (member (key-prefix key) kinds) #t))
(define (process-col? key) (col-prefix? key "p"))
(define (carry-col? key)   (col-prefix? key "m"))
(define (worker-col? key)  (col-prefix? key "w"))
(define (refresh-col? key) (col-prefix? key "wr"))
(define (means-col? key)   (col-prefix? key "mv"))
(define (supply-col? key)  (col-prefix? key "r"))
(define (train-col? key)   (col-prefix? key "T"))
(define (acquire-col? key) (col-prefix? key "acq"))
;; two PROCESS ids a column's process carries, each with its constructor and its readers:
;;   claim~GOOD    a claim recipe's process (scope/live.scm claim-recipes): the good a citizen claims
;;   cross-GOOD    a crossing's draw process (solve/federation-solve.scm): the good that crosses a boundary
(define (claim-process good)      (string-append "claim~" good))
(define (claim-process? proc)     (and (string? proc) (string-prefix? "claim~" proc)))
(define (claim-process-good proc) (and (claim-process? proc) (substring proc (string-length "claim~"))))
(define (crossing-process good)   (string-append "cross-" good))
(define (crossing-process? proc)  (and (string? proc) (string-prefix? "cross-" proc)))
(define (crossing-col? key)   ; a crossing's draw column: the process federation-solve lays as cross-<good>
  (let ((pr (and (process-col? key) (key-process key)))) (and pr (crossing-process? pr))))

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
(define (cell-key? s) (and (string? s) (string-index s #\@) #t))
(define (key-terms key)
  (let* ((p (string-split key #\|)) (prefix (car p)) (n (length p)))
    (cons (cons 'prefix prefix)
          (cond ;; a budgeted floor's cover column, p|spec|d#cell (engine lay-budgeted-floors):
                ;; no process runs here — the floor's own rows
                ;; (a cell is place@t and never carries a `#`; the `#` is the floor's)
                ((and (equal? prefix "p") (= n 3) (string-index (caddr p) #\#))
                 (let* ((last (caddr p)) (i (string-index last #\#)))
                   (cons* (cons 'floor (cadr p)) (cons 'source (substring last 0 i)) (cell-terms (substring last (+ i 1))))))
                ;; a process column: p|<process>|<cell>, or p|<process>|<a>|<b> for an arc.
                ;; A process id may itself carry a `|` (a hold through a container is
                ;; keep|K~spec), so the cells are the trailing segments and the process
                ;; is everything between
                ((and (equal? prefix "p") (>= n 3) (cell-key? (list-ref p (- n 1))))
                 (let* ((two? (and (>= n 4) (cell-key? (list-ref p (- n 2)))))
                        (cells (if two? (list (list-ref p (- n 2)) (list-ref p (- n 1))) (list (list-ref p (- n 1)))))
                        (process (string-join (list-head (cdr p) (- n 1 (length cells))) "|")))
                   (if two?
                       (cons* (cons 'process process) (cons 'arc (cons (car cells) (cadr cells))) (cell-terms (car cells)))
                       (cons (cons 'process process) (cell-terms (car cells))))))
                ;; a carry: the cells are the LAST two, the good everything between
                ;; (a carried good may itself carry a `|`: Pres|w, Svc|spec)
                ((and (equal? prefix "m") (>= n 4))
                 (let ((a (list-ref p (- n 2))) (b (list-ref p (- n 1))))
                   (cons* (cons 'good (string-join (list-head (cdr p) (- n 3)) "|")) (cons 'arc (cons a b)) (cell-terms a))))
                ;; a worker's supply, refresh or a mobile means' service: id|skill|cell —
                ;; the cell is the LAST field, the skill everything between (a means'
                ;; service is a bar good, Svc|spec, carrying a | of its own)
                ((and (member prefix '("w" "wr" "mv")) (>= n 4))
                 (cons* (cons 'worker (cadr p)) (cons 'skill (string-join (list-head (cddr p) (- n 3)) "|"))
                        (cell-terms (list-ref p (- n 1)))))
                ;; a supplier's draw: the cell is the LAST field, the spec the one before,
                ;; the supplier everything between (a pool's id is cp|rid|t or bg|rid)
                ((and (equal? prefix "r") (>= n 4))
                 (cons* (cons 'supplier (string-join (list-head (cdr p) (- n 3)) "|"))
                        (cons 'means (list-ref p (- n 2))) (cell-terms (list-ref p (- n 1)))))
                ;; a training: T|w|d@t — the skill carries the period
                ((and (equal? prefix "T") (= n 3))
                 (let ((at (string-rindex (caddr p) #\@)))
                   (cons* (cons 'worker (cadr p)) (cons 'skill (if at (substring (caddr p) 0 at) (caddr p)))
                          (if at (list (cons 'period (string->number (substring (caddr p) (+ at 1))))) '()))))
                ;; a row bought in: everything after the prefix is the row (Lab|cell included)
                ((and (equal? prefix "acq") (>= n 2)) (list (cons 'row (string-join (cdr p) "|"))))
                (else '())))))
;; the three readings every other site takes off a key: its prefix (the kind
;; of column), its process (#f unless a p| column), its arc (#f unless a haul
;; or a hold). A site that needs more reads key-terms whole.
(define (key-process key) (assq-ref (key-terms key) 'process))
(define (key-arc key) (assq-ref (key-terms key) 'arc))
