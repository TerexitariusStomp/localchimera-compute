;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; wire/rows.scm — a row of the wire, stated as a table.
;;;
;;; The page reads each reply as JSON rows with string keys. A row is written by a
;;; table over the record (or alist) it reads; the tables, their kinds and the reads
;;; and coercions under them are here, shared by the page's
;;; spine (hoot/day-boot.scm) and by whatever else speaks the same wire
;;; natively (tools/emit/demo-emit.scm). Plain Scheme. The tables over the planner's
;;; records (a commitment, a member, a recipe, …) stand in doors/record-rows.scm,
;;; the rest in wire/snapshot.scm and wire/replies.scm; the page's types are
;;; generated from all of them (tools/emit/wire-types-emit.scm).

(define-module (playnet wire rows)
  #:use-module ((playnet utils records) #:select (vf-record-type-fields vf-record-accessor))
  #:export (wire-table wire-table? wire-tables wire-table-ref wire-table-name
            wire-table-record-type wire-table-entries wire-row* wire-value row-maker
            plain->wire wire->plain
            reply-table reply-table-ref wire-type-name reply->wire finished finishing plain-reply with-context
            alist-ref
            ->list
            str-field
            int-field
            wire-row))

(define (alist-ref al key . default)
  (let ((p (and (pair? al) (assq key al))))
    (if p (cdr p) (if (pair? default) (car default) #f))))

;; a vector or a list, as a list
(define (->list x)
  (cond ((vector? x) (vector->list x)) ((pair? x) x) (else '())))

;; typed alist reads with a fallback — collapse the (let ((v …)) (if … ))
;; dance that record->wire / contact->wire repeated a dozen times.
(define (str-field al key . default)
  (let ((v (alist-ref al key)) (d (if (pair? default) (car default) "")))
    (cond ((string? v) v)
          ((symbol? v) (symbol->string v))
          (else d))))
(define (int-field al key default)
  (let ((v (alist-ref al key)))
    (if (number? v) (inexact->exact (round v)) default)))

;; ── A ROW OF THE WIRE IS A TABLE ──────────────────────────────────────────────
;; What the page reads of a thing is stated once, as a table: each entry is
;;   ("wireKey" SOURCE KIND)
;; SOURCE says where the value comes from: a symbol names a field of the record the
;; table reads (or a key of an alist, for a row with no record behind it); a
;; procedure (lambda (row ctx) …) computes it, and is the one place a join lives (a
;; specification's name, a label), CTX carrying what the reply looked up once; a
;; pair (key . procedure) computes it off the alist key it names, so the row's
;; maker admits that key.
;; KIND says how the value is written, and so what type the page reads:
;;   str       a string, "" where absent; a symbol as its name
;;   opt-str   a string, null where absent
;;   int       a whole number, 0 where absent
;;   bool      true when the field is set
;;   num       a finite number (a coordinate, a quantity, a price), a whole count
;;             as the whole number it is; null where absent, nan or infinite
;;   strs      an array of the strings among the value's elements
;;   any       the value as it stands (already in the wire's shape)
;;   (list K)  an array, each element written as kind K
;;   (map K)   an object under an alist's keys (a symbol as its name), each
;;             value written as kind K
;;   (rows T)  an array of rows, each written by table T
;;   (row T)   one row written by table T, null where absent
;;   (some-rows T)  an array of rows, false where there are none
;;   (some-row T)   one row, false where absent
;;   (gathered T)   as (rows T); the arm the spine appends across a person's
;;                  memberships (fold-snapshots), the others being one scope's own
;;   (omit-false K)  as kind K, the key left out where the value is absent
;; T is a table or the name of one (a name lets a row nest rows of its own kind).
;;
;; `wire-table` makes a table and REGISTERS it under its name with the record type
;; it reads. A table naming a field its record type lacks is refused as it is made,
;; so a field renamed in the vocabulary cannot leave a row reading nothing. The
;; registry is what the page's row types are generated from (tools/emit/wire-types-emit.scm),
;; so the page's types are what the server states.
;;
;; Plain procedures over lists and vectors: this file runs in the wasm bundles too,
;; where a record is read through (playnet utils records).

(define (%keep keep? l) (cond ((null? l) '()) ((keep? (car l)) (cons (car l) (%keep keep? (cdr l)))) (else (%keep keep? (cdr l)))))
(define %wire-tables '())                  ; ((name . table) …), newest first
(define (wire-tables) (reverse (map cdr %wire-tables)))
(define (wire-table-ref name)
  (let ((p (assq name %wire-tables)))
    (if p (cdr p) (error "wire: no table of this name" name))))

;; a table: #(name record-type entries readers), READERS one per entry
(define (wire-table? x) (and (vector? x) (= (vector-length x) 4) (symbol? (vector-ref x 0))))
(define (wire-table-name t) (vector-ref t 0))
(define (wire-table-record-type t) (vector-ref t 1))
(define (wire-table-entries t) (vector-ref t 2))

(define (entry-reader rtd entry name)
  "How ENTRY's value is read off a row: (lambda (row ctx) value)."
  (let ((source (cadr entry)))
    (cond ((procedure? source) source)
          ((and (pair? source) (symbol? (car source)) (procedure? (cdr source))) (cdr source))
          ((not (symbol? source)) (error "wire-table: a source is a field or a procedure" name (car entry)))
          (rtd
           (unless (memq source (vf-record-type-fields rtd))
             (error "wire-table: the record has no such field" name (car entry) source))
           (let ((ref (vf-record-accessor rtd source)))
             (lambda (row ctx) (ref row))))
          (else (lambda (row ctx) (alist-ref row source #f))))))

(define (wire-table name rtd entries)
  "The table NAME over record type RTD (#f: a row read off an alist), registered."
  (let ((t (vector name rtd entries (map (lambda (e) (entry-reader rtd e name)) entries))))
    (set! %wire-tables (cons (cons name t) (%keep (lambda (p) (not (eq? (car p) name))) %wire-tables)))
    t))

;; ── A ROW WITH NO RECORD BEHIND IT IS LAID BY ITS TABLE ──────────────────────
;; A producer of an alist row lays it with the table's own maker, (maker #:key
;; value …), one keyword per symbol source the table names. A key the table has
;; no entry for is refused as the row is laid, so a producer cannot state what
;; the wire would drop: the table is the one declaration of the row, and the
;; producer's keys are held to it by construction. A false value under an
;; `omit-false` entry leaves the key out, as the kind reads it.
(define (row-maker table)
  "The maker of the alist rows TABLE reads: (maker #:key value …) → the row."
  (let ((name (wire-table-name table))
        (sources (let loop ((es (wire-table-entries table)) (acc '()))
                   (cond ((null? es) acc)
                         ((symbol? (cadr (car es))) (loop (cdr es) (cons (cadr (car es)) acc)))
                         ((pair? (cadr (car es))) (loop (cdr es) (cons (car (cadr (car es))) acc)))
                         (else (loop (cdr es) acc))))))
    (lambda args
      (let loop ((a args) (acc '()))
        (cond ((null? a) (reverse acc))
              ((or (not (keyword? (car a))) (null? (cdr a)))
               (error "row-maker: keyword and value pairs" name a))
              (else
               (let ((k (keyword->symbol (car a))))
                 (unless (memq k sources)
                   (error "wire-row: the table has no such key" name k))
                 (loop (cddr a) (cons (cons k (cadr a)) acc)))))))))

(define (table-of t) (if (symbol? t) (wire-table-ref t) t))

(define (wire-value kind v ctx)
  "V written as KIND."
  (case (if (pair? kind) (car kind) kind)
    ((str)     (cond ((string? v) v) ((symbol? v) (symbol->string v)) (else "")))
    ((opt-str) (if (string? v) v 'null))
    ((int)     (if (number? v) (inexact->exact (round v)) 0))
    ((bool)    (if v #t #f))
    ((num)     (cond ((exact-integer? v) v)
                     ((and (number? v) (rational? v)) (exact->inexact v))
                     (else 'null)))
    ((strs)    (list->vector (%keep string? (->list v))))
    ((any)     v)
    ((list)    (list->vector (map (lambda (x) (wire-value (cadr kind) x ctx)) (->list v))))
    ((map)     (map (lambda (p) (cons (let ((k (car p))) (if (symbol? k) (symbol->string k) k))
                                      (wire-value (cadr kind) (cdr p) ctx)))
                    (->list v)))
    ((rows gathered) (let ((l (->list v)))
                 (if (null? l) (vector)        ; no row, no table to find
                     (let ((t (table-of (cadr kind))))
                       (list->vector (map (lambda (x) (wire-row* t x ctx)) l))))))
    ((row)     (if v (wire-row* (table-of (cadr kind)) v ctx) 'null))
    ((some-rows) (let ((l (->list v)))
                   (and (pair? l) (wire-value (list 'rows (cadr kind)) l ctx))))
    ((some-row)  (and (pair? v) (wire-row* (table-of (cadr kind)) v ctx)))
    ((omit-false) (wire-value (cadr kind) v ctx))
    (else      (error "wire-row: no such kind" kind))))

(define (wire-row* table row . ctx)
  "ROW as the page reads it, by TABLE; CTX is handed to the computed entries."
  (let ((ctx (if (pair? ctx) (car ctx) #f)))
    (let loop ((entries (wire-table-entries table)) (readers (vector-ref table 3)))
      (if (null? entries) '()
          (let* ((entry (car entries)) (kind (caddr entry)) (v ((car readers) row ctx)))
            (if (and (pair? kind) (eq? (car kind) 'omit-false) (not v))
                (loop (cdr entries) (cdr readers))
                (cons (cons (car entry) (wire-value kind v ctx))
                      (loop (cdr entries) (cdr readers)))))))))

;; ── A DOOR'S REPLY IS A TABLE FOUND BY THE DOOR'S NAME ───────────────────────
;; (reply-table 'door entries) registers the table DOOR answers with, under
;; DOOR-reply. `finished` writes a door's (ok . v) through it, and `finishing`
;; wraps an actor's dispatch so every door with a table answers the page's rows
;; at the one place the actor answers: registering the table IS finishing the
;; door; a refusal, a bare word, and a door with no table pass as they are. A
;; door that answers through a promise finishes where the promise settles
;; (`finished` on the settled reply, as the lobby's allotment door does).
(define %replies '())                      ; ((door . table) …)
(define (reply-table door entries)
  (let ((t (wire-table (string->symbol (string-append (symbol->string door) "-reply")) #f entries)))
    (set! %replies (cons (cons door t) (%keep (lambda (p) (not (eq? (car p) door))) %replies)))
    t))
(define (reply-table-ref door)
  "The table DOOR answers with, or #f where DOOR answers in its own words."
  (let ((t (assq door %replies))) (and t (cdr t))))
(define (wire-type-name table-name)
  "The page's name for TABLE-NAME's rows: plan-need → WirePlanNeed (wire-rows.ts)."
  (let loop ((parts (string-split (symbol->string table-name) #\-)) (acc "Wire"))
    (cond ((null? parts) acc)
          ((string-null? (car parts)) (loop (cdr parts) acc))
          (else (loop (cdr parts)
                      (string-append acc (string (char-upcase (string-ref (car parts) 0)))
                                     (substring (car parts) 1)))))))
(define (reply->wire door v)
  "What DOOR answered, V, as the object the page reads."
  (let ((t (assq door %replies)))
    (cond ((not t) (error "reply->wire: no such door" door))
          ((contextual? v) (wire-row* (cdr t) (vector-ref v 1) (vector-ref v 2)))
          (else (wire-row* (cdr t) v)))))

;; a reply whose rows join through a context — the stores a snapshot's record
;; rows look names up in — carries it: (with-context value ctx). The table
;; writes the value with that context; a plain reader sees the value.
(define (with-context v ctx) (vector 'with-context v ctx))
(define (contextual? v) (and (vector? v) (= (vector-length v) 3) (eq? (vector-ref v 0) 'with-context)))
(define (finished door reply)
  "REPLY written by DOOR's table: (ok . v) with V written, a bare reply (a door
   that answers its value outright, as scope-snapshot does) written whole. A
   refusal (error . …), a bare word, and a door with no table pass as they are."
  (cond ((not (assq door %replies)) reply)
        ((contextual? reply) (reply->wire door reply))
        ((not (pair? reply)) reply)
        ((eq? (car reply) 'ok) (cons 'ok (reply->wire door (cdr reply))))
        ((symbol? (car reply)) reply)
        (else (reply->wire door reply))))
(define (plain-reply reply)
  "A finished REPLY read back as plain alists (wire->plain), the inverse of
   `finished`: what a reader in the process, a test, makes of a door's rows."
  (cond ((not (pair? reply)) reply)
        ((eq? (car reply) 'ok) (cons 'ok (wire->plain (cdr reply))))
        ((symbol? (car reply)) reply)
        (else (wire->plain reply))))
(define (finishing dispatch)
  "DISPATCH, an actor's (lambda (msg . args) …), answering each door finished."
  (lambda (msg . args) (finished msg (apply dispatch msg args))))

;; a row read off an alist by a table, or by a bare list of entries
(define (wire-row al spec)
  (if (wire-table? spec)
      (wire-row* spec al)
      (map (lambda (entry) (cons (car entry) (wire-value (caddr entry) (alist-ref al (cadr entry) #f) #f)))
           spec)))

;; A reply whose keys are already the page's words (single words, as the
;; fragility face reads them), carried as it stands: an alist becomes an object
;; under its keys' names, a list an array, a symbol its name, and a number that
;; is no finite number null.
;; …and read back: a row of the wire as a plain alist under kebab-case symbols,
;; its arrays lists, its null absent (#f). A face that reads records as alists
;; (hoot/repl.scm, the calendar feed) reads a finished row through this.
(define (wire-key->symbol k)
  (string->symbol
   (list->string
    (let loop ((cs (string->list k)))
      (cond ((null? cs) '())
            ((char-upper-case? (car cs)) (cons #\- (cons (char-downcase (car cs)) (loop (cdr cs)))))
            (else (cons (car cs) (loop (cdr cs)))))))))
(define (wire->plain v)
  (cond ((contextual? v) (wire->plain (vector-ref v 1)))
        ((vector? v) (map wire->plain (vector->list v)))
        ((and (pair? v) (string? (car v))) (cons (wire-key->symbol (car v)) (wire->plain (cdr v))))
        ((pair? v) (cons (wire->plain (car v)) (wire->plain (cdr v))))
        ((eq? v 'null) #f)
        (else v)))

(define (plain->wire v)
  (define (key? k) (or (symbol? k) (string? k)))
  (define (name k) (if (symbol? k) (symbol->string k) k))
  (cond ((null? v) (vector))
        ((and (list? v) (let all ((l v)) (or (null? l) (and (pair? (car l)) (key? (caar l)) (all (cdr l))))))
         (map (lambda (p) (cons (name (car p)) (plain->wire (cdr p)))) v))
        ((list? v) (list->vector (map plain->wire v)))
        ((vector? v) (list->vector (map plain->wire (vector->list v))))
        ((symbol? v) (symbol->string v))
        ((and (number? v) (inexact? v) (not (rational? v))) 'null)
        (else v)))
