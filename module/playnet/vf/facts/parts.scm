;;; parts.scm — the one selector: a PART of the plan named in VF terms, and the
;;; one matcher that says which columns (or which work events) it covers.
;;;
;;; docs/planning/voice/weights-and-books.md §5 (one selector), voice-follows-work.md
;;; "Parts are drawn from shared kinds", voice-in-lean.md "The objects":
;;;
;;;   P := (k : Kind) → Option (Node k)       -- a part is a conjunction
;;;   covers π c ⇔ every stated term of π matches the column's term of that kind
;;;   π ≤ π' ⇔ π states everything π' states  -- refinement is pointwise
;;;
;;; A part holds AT MOST ONE node per shared kind, all holding at once. "Nights,
;;; at this bakery, on this kind of oven" is one part. The record has one
;;; optional slot per kind and no slot that holds two nodes, so a UNION has no
;;; representation here: a part may narrow and may never join. That is what
;;; keeps hours honest — nobody can stitch their own shifts to work they never
;;; touch (voice-in-lean theorem 8′ `union_carries_hours`, held by construction).
;;;
;;; TERMS are what a part is matched against: an alist ((kind . value) …) read
;;; off a column by the engine (`column-terms`) or off a work event by the
;;; observer (`event-terms`). A value is an atom, matched by equal?, or a LIST,
;;; matched by member — a column draws several skills, an event stands in a
;;; scope path. A window value is a pair (begin . end) of ISO instants and a
;;; part's window covers it by inclusion; an event's instant is the pair (t . t).
;;;
;;; This module is the grammar and the matcher and nothing else: no engine, no
;;; store. The engine gives it a vector of terms; it gives back indices — and a
;;; part that covers nothing this assembly is SAID, never silently zero.

(define-module (playnet vf facts parts)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils keywords) #:select (alist->kw))
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:export (*part-kinds*
            make-part part? part-node part-terms part-stated? part-empty?
            part-refines? part-meet part-equal?
            part-tag part->string string->part
            covers? compile-part compile-parts terms->part rungs-of
            validate-hand))

;; The shared classifications, in the order a part's string form states them:
;; the kinds are the whole grammar. `tag` is a folksonomy tag the act carries
;; (VF processClassifiedAs, compile.scm proc-tags → the engine's `tag` term):
;; a chain of recipes tagged as one way is one node, and a part naming it
;; covers every column of every act under it (voice-follows-work.md "A chain
;; of recipes is a mapped way, one tag, one stance").
(define *part-kinds* '(scope process means place window skill tag))

(define-record-type <part>
  (%make-part scope process means place window skill tag)
  part?
  (scope part-scope) (process part-process) (means part-means)
  (place part-place) (window part-window) (skill part-skill) (tag part-tag))

(define (part-node π kind)
  (case kind
    ((scope) (part-scope π)) ((process) (part-process π)) ((means) (part-means π))
    ((place) (part-place π)) ((window) (part-window π)) ((skill) (part-skill π))
    ((tag) (part-tag π))
    (else (error "parts: no such kind" kind))))

(define (check-node! kind node)
  (cond ((not node) #f)
        ((eq? kind 'window)
         (unless (and (pair? node) (string? (car node)) (string? (cdr node))
                      (string<=? (car node) (cdr node)))
           (error "parts: a window is (begin-iso . end-iso)" node))
         node)
        ((string? node)
         (when (or (string-index node #\;) (string-index node #\=) (string-index node #\/))
           (error "parts: a node may not contain ; = or /" node))
         node)
        (else (error "parts: a node is a string" kind node))))

(define* (make-part #:key scope process means place window skill tag)
  "One optional node per kind. Nothing stated is the widest part: it covers
   every column, and is what a bare scope reads as."
  (%make-part (check-node! 'scope scope) (check-node! 'process process)
              (check-node! 'means means) (check-node! 'place place)
              (check-node! 'window window) (check-node! 'skill skill)
              (check-node! 'tag tag)))

(define (part-terms π)
  "The stated slots only, ((kind . node) …), in *part-kinds* order."
  (filter-map (lambda (k) (let ((n (part-node π k))) (and n (cons k n)))) *part-kinds*))

(define (part-stated? π kind) (and (part-node π kind) #t))
(define (part-empty? π) (null? (part-terms π)))
(define (part-equal? a b) (equal? (part-terms a) (part-terms b)))

(define (window-within? inner outer)      ; (b . e) ⊆ (B . E), ISO strings of one format
  (and (pair? inner) (pair? outer)
       (string? (car inner)) (string? (cdr inner))
       (string>=? (car inner) (car outer)) (string<=? (cdr inner) (cdr outer))))

(define (part-refines? narrow wide)
  "π ≤ π': NARROW states everything WIDE states (a window of WIDE by inclusion)."
  (every (lambda (kv)
           (let ((n (part-node narrow (car kv))))
             (and n (if (eq? (car kv) 'window) (window-within? n (cdr kv)) (equal? n (cdr kv))))))
         (part-terms wide)))

(define (part-meet a b)
  "The conjunction of two parts, or #f when they state different nodes for one
   kind — there is no part that is both. Lean `parts_inf`: covers (meet a b) c
   ⇔ covers a c ∧ covers b c."
  (let loop ((ks *part-kinds*) (acc '()))
    (if (null? ks)
        (apply make-part (alist->kw (reverse acc)))
        (let* ((k (car ks)) (x (part-node a k)) (y (part-node b k)))
          (cond ((and x y (eq? k 'window))
                 (let ((lo (if (string>=? (car x) (car y)) (car x) (car y)))
                       (hi (if (string<=? (cdr x) (cdr y)) (cdr x) (cdr y))))
                   (and (string<=? lo hi) (loop (cdr ks) (cons (cons k (cons lo hi)) acc)))))
                ((and x y) (and (equal? x y) (loop (cdr ks) (cons (cons k x) acc))))
                ((or x y) (loop (cdr ks) (cons (cons k (or x y)) acc)))
                (else (loop (cdr ks) acc)))))))

;; ── the string form: what a credential carries, SAID-stable ─────────────────
(define (part->string π)
  "\"kind=node;kind=node\" in *part-kinds* order; a window as begin/end. The
   empty part is the empty string."
  (string-join
   (map (lambda (kv)
          (string-append (symbol->string (car kv)) "="
                         (if (eq? (car kv) 'window)
                             (string-append (cadr kv) "/" (cddr kv))
                             (cdr kv))))
        (part-terms π))
   ";"))

(define (string->part s)
  "Inverse of part->string. Refuses an unknown kind, a kind stated twice, and
   any node the constructor refuses."
  (if (string-null? s)
      (make-part)
      (let loop ((items (string-split s #\;)) (seen '()) (kws '()))
        (if (null? items)
            (apply make-part kws)
            (let* ((item (car items)) (eq (string-index item #\=)))
              (unless eq (error "parts: malformed term" item))
              (let* ((kind (string->symbol (substring item 0 eq)))
                     (rest (substring item (+ eq 1))))
                (unless (memq kind *part-kinds*) (error "parts: no such kind" kind))
                (when (memq kind seen) (error "parts: a kind stated twice" kind))
                (let ((node (if (eq? kind 'window)
                                (let ((sl (string-index rest #\/)))
                                  (unless sl (error "parts: a window is begin/end" rest))
                                  (cons (substring rest 0 sl) (substring rest (+ sl 1))))
                                rest)))
                  (loop (cdr items) (cons kind seen)
                        (cons (symbol->keyword kind) (cons node kws))))))))))

;; ── the matcher ─────────────────────────────────────────────────────────────
(define (term-matches? kind node value)
  (cond ((not value) #f)
        ((eq? kind 'window) (window-within? value node))
        ((pair? value) (and (member node value) #t))
        (else (equal? node value))))

(define (covers? π terms)
  "Every stated term of the part matches the term of that kind in TERMS."
  (every (lambda (kv) (term-matches? (car kv) (cdr kv) (assq-ref terms (car kv))))
         (part-terms π)))

(define (compile-part π terms-vec)
  "The indices whose terms the part covers, or the symbol `nothing` — a symbol
   rather than '(), so that a caller that walks it raises instead of quietly
   binding nothing."
  (let ((n (vector-length terms-vec)))
    (let loop ((i (- n 1)) (acc '()))
      (cond ((< i 0) (if (null? acc) 'nothing acc))
            ((covers? π (vector-ref terms-vec i)) (loop (- i 1) (cons i acc)))
            (else (loop (- i 1) acc))))))

(define (default-say! π)
  (format (current-error-port) "[parts] a part covers nothing in this assembly: ~s~%" (part->string π)))

(define* (compile-parts πs terms-vec #:key (say default-say!))
  "((π . indices) …) for the parts that cover something; each part that covers
   nothing is handed to SAY once and dropped. This is the one place the empty
   case is swallowed, and it says so."
  (filter-map (lambda (π)
                (let ((ix (compile-part π terms-vec)))
                  (if (eq? ix 'nothing) (begin (say π) #f) (cons π ix))))
              πs))

;; ── the ladder: a cell's own terms as a part, and its rungs ─────────────────
(define (terms->part terms)
  "The narrowest part a column's (or event's) terms name: its single-valued
   process, place and window, and its means and skill when it has exactly one.
   This is the origin rung of the ladder a person sees from a calendar cell."
  (define (one kind)
    (let ((v (assq-ref terms kind)))
      (cond ((not v) #f)
            ((and (pair? v) (not (eq? kind 'window))) (and (= 1 (length v)) (car v)))
            (else v))))
  (make-part #:process (one 'process) #:means (one 'means) #:place (one 'place)
             #:window (one 'window) #:skill (one 'skill) #:tag (one 'tag)))

(define (rungs-of terms)
  "Every part obtained from (terms->part terms) by releasing a subset of its
   stated terms — 2^n parts including the origin and the empty part — each of
   which covers the cell it was reached from (voice-in-lean theorem 11)."
  (let* ((origin (terms->part terms)) (stated (part-terms origin)))
    (let loop ((kvs stated) (acc (list '())))
      (if (null? kvs)
          (map (lambda (kept)
                 (apply make-part (alist->kw kept)))
               acc)
          (loop (cdr kvs) (append acc (map (lambda (kept) (cons (car kvs) kept)) acc)))))))

;; ── a hand: what a plan-part stance credential carries ──────────────────────
(define (validate-hand hand)
  "THE HAND'S CONSTRUCTOR — the one door a parsed hand comes through, at the
   rail's write (governance cast-part-signed) and at every read of the rail
   (the planner's voice fold), so a hand in flight is by construction one this
   accepted. HAND ((part-string . portion) …). Every portion a number in
   [−1, 1] (signed: dislike to like), every key a part this grammar parses.
   Returns ((part . portion) …). The hour-by-hour bound — portions over the parts
   covering any one hour sum to at most one — is applied at the fold, not here,
   because it is a fact about the person's hours, not about the statement."
  (unless (list? hand) (error "hand: an alist of (part-string . portion)" hand))
  (map (lambda (kv)
         (unless (and (pair? kv) (string? (car kv)) (real? (cdr kv)))
           (error "hand: each entry is (part-string . portion)" kv))
         (unless (<= -1 (cdr kv) 1) (error "hand: a portion lies in [-1, 1]" kv))
         (cons (string->part (car kv)) (exact->inexact (cdr kv))))
       hand))
