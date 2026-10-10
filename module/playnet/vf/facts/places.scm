;;; places.scm — ONE containment tree, shared by every legal fold.
;;;
;;; A jurisdiction path is a walk up `contained-in` (legal/registry.scm
;;; `jurisdiction-path`). This file holds the tree that walk reads: a registry of
;;; ordinary <spatial-thing> records, keyed by id, plus the `parent-of` closure
;;; the fold wants. Geography and jurisdiction are the same tree — a scope's
;;; ecological container and its legal container are one containment relation
;;; seen twice, so a shed that declares where it sits gets its jurisdiction path
;;; for free.
;;;
;;; The tree is OPEN: any knowledge file registers its own places, in any order,
;;; and the walk composes them. `world` is the root; `biosphere` sits under it, so
;;; the ecological trees (berlin.scm, worlds/doon-shed.scm, cascadia.scm — all rooted at
;;; "biosphere") join the same tree the legal fold walks, and an arc between two
;;; continents finds "world" as its common ancestor.
;;;
;;;   world
;;;   ├── biosphere ── germany ── berlin ── …        (ecological trees join here)
;;;   ├── us ── us-06 ── us-06-alameda                (nation ⊃ region ⊃ locality)
;;;   ├── mexico ── mx-tijuana
;;;   └── canada ── ca-toronto
;;;
;;; A place carries a KIND (root / nation / region / locality) and an EXTRA alist
;;; for whatever a renderer needs of it — a FIPS code, an ISO code, an AGS key.
;;; Both are open: a kind is any symbol, an extra key is any symbol, so a new
;;; country's administrative levels need no edit here.
;;;
;;; Loads after schemas.scm (for <spatial-thing>). Assumes nothing else.
;;;
;;; Run the demo:  guile -L module module/playnet/vf/facts/places.scm

;;; The four registry tables below stay PRIVATE, deliberately. `*places*` is also
;;; the name of the engine's list of place-ids (planner.scm, ~100 set! sites);
;;; they are unrelated variables, and exporting this one would collide with that
;;; in every module that imports both. Nothing outside this file reads any of the
;;; four, so the procedures are the whole interface.
(define-module (playnet vf facts places)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (playnet vf schemas)   ; <spatial-thing>
  #:export (register-place! place! place-ref place-known? place-parent-of
            place-name-of place-lat-of place-long-of place-kind
            place-extra place-extra-ref all-place-ids places-of-kind
            place-children place-nation-of spatial-parent-of
            register-nation! register-region! register-locality!
            all-nations nation-id? place->row place-row->place!))

;;; ─── the registry ─────────────────────────────────────────────────────────
;;; id → <spatial-thing>, plus the side tables a renderer reads. Registration
;;; order is kept so a snapshot emits places in the order stewards declared them.
(define *places* (make-hash-table))
(define *place-kinds* (make-hash-table))
(define *place-extras* (make-hash-table))
(define *place-order* '())                       ; reversed registration order

;;; Extras ACCUMULATE across registrations, because a place is named by more than
;;; one context pack and each has something different to say about it: the pack
;;; that puts a commune in its département also gives its INSEE code and
;;; population, while a water pack says which SAGE it stands `within` and a wine
;;; pack names its appellation. If a re-registration replaced the extras
;;; wholesale, whichever file the directory listed LAST would erase the others —
;;; silently, and differently depending on what the files happened to be called.
;;;
;;; So: a key both sides give UNIONS when both values are lists (two packs each
;;; adding a `within` regime keep both), and otherwise the later one stands. That
;;; makes a folder of packs order-independent, which is the whole promise of one
;;; drop-in file per jurisdiction. Re-registering the same pack is still
;;; idempotent — a union with itself is itself.
;;;
;;; The RECORD is still replaced (last parent wins), so a pack that restates a
;;; place restates where it sits.
(define (merge-extras old new)
  (let loop ((ks (delete-duplicates (append (map car old) (map car new))))
             (acc '()))
    (if (null? ks)
        (reverse acc)
        (let* ((k (car ks))
               (o (assq k old)) (n (assq k new))
               (v (cond ((and o n (list? (cdr o)) (list? (cdr n)))
                         (delete-duplicates (append (cdr o) (cdr n))))
                        (n (cdr n))
                        (else (cdr o)))))
          (loop (cdr ks) (cons (cons k v) acc))))))

(define* (register-place! st #:key (kind 'place) (extra '()))
  "Register ST (a <spatial-thing>) in the shared tree. Re-registering an id
   replaces its record and keeps its position, so a reload is idempotent; its
   EXTRAS merge rather than replace, so packs compose in any order."
  (let ((id (spatial-thing-id st)))
    (unless (hash-ref *places* id #f)
      (set! *place-order* (cons id *place-order*)))
    (hash-set! *places* id st)
    (hash-set! *place-kinds* id kind)
    (hash-set! *place-extras* id
               (merge-extras (hash-ref *place-extras* id '()) extra))
    st))

(define* (place! id name parent #:key (kind 'place) (extra '())
                                     (lat #f) (long #f) (note #f))
  "Register a place from plain fields — the common case, no record plumbing."
  (register-place! (make-spatial-thing #:id id #:name name #:note note #:lat lat #:long long
                                       #:contained-in parent)
                   #:kind kind #:extra extra))

;;; ─── accessors ────────────────────────────────────────────────────────────
(define (place-ref id) (hash-ref *places* id #f))
(define (place-known? id) (and (place-ref id) #t))
(define (place-parent-of id)
  (let ((st (place-ref id))) (and st (spatial-thing-contained-in st))))
(define (place-name-of id)
  (let ((st (place-ref id))) (or (and st (spatial-thing-name st)) id)))
(define (place-lat-of id) (let ((st (place-ref id))) (and st (spatial-thing-lat st))))
(define (place-long-of id) (let ((st (place-ref id))) (and st (spatial-thing-long st))))
(define (place-kind id) (hash-ref *place-kinds* id 'place))
(define (place-extra id) (hash-ref *place-extras* id '()))
(define (place-extra-ref id key) (assq-ref (place-extra id) key))

(define (all-place-ids) (reverse *place-order*))
(define (places-of-kind k) (filter (lambda (id) (eq? k (place-kind id))) (all-place-ids)))
(define (place-children id)
  (filter (lambda (c) (equal? id (place-parent-of c))) (all-place-ids)))

;;; the nation a place sits in: walk up to the child of the root. #f above it.
(define (place-nation-of id)
  (let loop ((cur id) (seen '()))
    (cond ((or (not cur) (member cur seen)) #f)
          ((eq? 'nation (place-kind cur)) cur)
          (else (loop (place-parent-of cur) (cons cur seen))))))

;;; ─── the pure form : a parent-of over ANY list of <spatial-thing> ─────────
;;; The live planner keeps its own spatial-thing store; hand its records here and
;;; the same fold runs over them, registry untouched.
(define (spatial-parent-of things)
  (lambda (id)
    (let ((st (find (lambda (s) (equal? id (spatial-thing-id s))) things)))
      (and st (spatial-thing-contained-in st)))))

;;; ─── typed registrars : the levels a jurisdiction tree actually has ───────
(define* (register-nation! id name iso #:key (lat #f) (long #f) (parent "world"))
  (place! id name parent #:kind 'nation #:lat lat #:long long
          #:extra `((iso . ,iso))))
(define* (register-region! id name parent #:key (extra '()) (lat #f) (long #f))
  (place! id name parent #:kind 'region #:extra extra #:lat lat #:long long))
(define* (register-locality! id name parent lat long #:key (extra '()))
  (place! id name parent #:kind 'locality #:lat lat #:long long #:extra extra))

(define (all-nations) (places-of-kind 'nation))
(define (nation-id? id) (eq? 'nation (place-kind id)))

;;; ─── a place as a plain ROW : the on-disk shape ──────────────────────────
;;; Row:  (id name parent kind extra lat long)  — exactly the fields `place!`
;;; takes. Serialization itself lives in law/context-pack.scm, which persists a
;;; context's geography and its law together as one file.
(define (place->row id)
  (list id (place-name-of id) (place-parent-of id)
        (place-kind id) (place-extra id) (place-lat-of id) (place-long-of id)))

(define (place-row->place! row)
  (apply (lambda* (id name parent #:optional (kind 'place) (extra '()) (lat #f) (long #f))
           (place! id name parent #:kind kind #:extra extra #:lat lat #:long long))
         row))

;;; ─── the roots : the world, and the one biosphere inside it ──────────────
;;; Every ecological tree in knowledge/ roots at "biosphere"; rooting it here in
;;; turn joins those trees to the jurisdiction walk with no edit to any of them.
(place! "world" "World" #f #:kind 'root)
(place! "biosphere" "The biosphere" "world" #:kind 'root #:lat 0.0 #:long 0.0)

;;; ─── demo (only when run as a script) ────────────────────────────────────
(define (places-demo)
  (register-nation! "us" "United States" "840")
  (register-region! "us-06" "California" "us" #:extra '((fips . "06")))
  (register-locality! "us-06-alameda" "Alameda County, CA" "us-06" 37.65 -121.91)
  (register-nation! "germany" "Germany" "276" #:parent "biosphere")
  (register-region! "berlin" "Berlin/Brandenburg" "germany" #:lat 52.52 #:long 13.40)
  (format #t "~%parent chain of us-06-alameda:~%")
  (let loop ((id "us-06-alameda"))
    (when id (format #t "  ~a  (~a, ~a)~%" id (place-name-of id) (place-kind id))
              (loop (place-parent-of id))))
  (format #t "~%parent chain of berlin:~%")
  (let loop ((id "berlin"))
    (when id (format #t "  ~a  (~a, ~a)~%" id (place-name-of id) (place-kind id))
              (loop (place-parent-of id))))
  (format #t "~%nation of us-06-alameda → ~a · of berlin → ~a~%"
          (place-nation-of "us-06-alameda") (place-nation-of "berlin"))
  (format #t "nations: ~a~%" (all-nations)))

;; run as a program on a host; a page loads this as a library only
(cond-expand
 (guile
  (when (and (pair? (command-line))
             (string-suffix? "places.scm" (car (command-line))))
    (places-demo)))
 (else))
