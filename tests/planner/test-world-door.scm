;;; test-world-door.scm — a world is declared through ONE door, structurally.
;;;
;;; declare-world! is where a located world's identity is written: its places,
;;; periods and cells, what moves and keeps, who works and rides, the move and
;;; hold costs, the containment tree. The records door (ingest-located!, which
;;; plan-from-records and the live planner run through) derives its declaration
;;; from the records and calls declare-world!; worked-example's setup-* call it;
;;; every fixture calls it. So the guarantee that a keyword added to the door is
;;; a keyword every world gets is a fact about WHERE the globals are assigned,
;;; and that is what this file reads — the source, not a solve:
;;;
;;;   · a door global is `set!` inside declare-world! or reset!, and nowhere else
;;;     in the engine family (engine.scm and the satellites it loads), nor in any
;;;     test, bench or the demo — the layering doors (workers->riders!,
;;;     absorb-specs!, adopt-container-pools!, means-as-riders, the manners bag)
;;;     are named here as the exceptions they are, each with the one global it
;;;     layers onto;
;;;   · mkcells! has one caller, declare-world!;
;;;   · reset! has one caller, declare-world! — ingest-located! derives its
;;;     partition, resolved keys and stretch registrations as pure list math
;;;     and lets the door reset.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-world-door.scm

(use-modules (srfi srfi-1) (ice-9 format) (ice-9 rdelim) (ice-9 ftw) (ice-9 match))
(fluid-set! %default-port-encoding "UTF-8")   ; the sources are UTF-8 whatever the locale says

(define door-globals
  '(*places* *periods* *cells* *movable* *storable* *stationary* *tau* *hold*
    *workers* *riders* *mode-recipes* *resource-suppliers* *spatial-things*))

;; the layering doors: a standing world's global each is allowed to rewrite
(define layerings
  '((mkcells!               *cells*)                 ; the door's own helper
    (declare-workers!       *workers*)              ; the roster, once the spans stand
    (workers->riders!       *workers* *riders*)     ; mobile people become movers
    (means->movers!         *riders*)               ; a mobile means rides too
    (absorb-specs!          *stationary*)           ; a keep-in-place spec
    (store-recipe           *stationary*)           ; a warehouse keeps its place
    (adopt-container-pools! *resource-suppliers*))) ; containment-derived pools

;;; ── scanning: top-level forms and the (set! g …) sites inside each ────────
(define (slurp path) (call-with-input-file path read-string))
(define (forms-of path)
  (call-with-input-file path
    (lambda (p) (let loop ((acc '()))
                  (let ((f (read p))) (if (eof-object? f) (reverse acc) (loop (cons f acc))))))))
(define (defined-name form)
  (match form
    (((or 'define 'define*) (name . _) . _) name)
    (((or 'define 'define*) name . _) name)
    (_ #f)))
(define (sites-in form pred)
  "Every subform of FORM satisfying PRED."
  (let walk ((f form) (acc '()))
    (cond ((and (pair? f) (pred f)) (walk (cdr f) (cons f acc)))
          ((pair? f) (walk (car f) (walk (cdr f) acc)))
          (else acc))))
(define (calls-in form pred)
  "Every subform of FORM that PRED accepts and that stands where a call stands: not as the
   head of a list, where `(case msg ((reset!) …))` writes the datum `(reset!)`."
  (define (walk f counted? acc)           ; COUNTED? is #f for a form in head position
    (if (not (pair? f))
        acc
        (let ((acc (if (and counted? (pred f)) (cons f acc) acc)))
          (let loop ((es (if (list? f) f (list (car f)))) (first? #t) (acc acc))
            (if (null? es)
                acc
                (loop (cdr es) #f (walk (car es) (not first?) acc)))))))
  (walk form #t '()))
(define (set-of-door? f) (and (eq? (car f) 'set!) (pair? (cdr f)) (memq (cadr f) door-globals)))
(define (call-of? name) (lambda (f) (eq? (car f) name)))

;; where each door global is set!, by enclosing top-level definition
(define (writers path)
  (append-map (lambda (form)
                (let ((name (defined-name form)))
                  (map (lambda (s) (list (cadr s) (or name '<toplevel>) path))
                       (sites-in form set-of-door?))))
              (forms-of path)))

(define engine "module/playnet/planner/solve/engine.scm")
(define satellites '("module/playnet/planner/solve/engine/robust.scm" "module/playnet/planner/solve/engine/fragility.scm"
                     "module/playnet/planner/solve/engine/federation-solve.scm" "module/playnet/planner/solve/engine/worked-example.scm"))
(define (scm-files-under dir)
  (let ((acc '()))
    (ftw dir (lambda (f st flag) (when (and (eq? flag 'regular) (string-suffix? ".scm" f)) (set! acc (cons f acc))) #t))
    acc))
(define outside (append (scm-files-under "module/playnet/planner/bench")
                        (scm-files-under "tests/planner")
                        '("module/playnet/deprecated/planner/attic/demo.scm")))

(define *pass* 0) (define *fail* 0)
(define (check name ok . detail)
  (if ok (begin (set! *pass* (1+ *pass*)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (1+ *fail*)) (format #t "  ✗ ~a~%" name)
             (for-each (lambda (d) (format #t "      ~s~%" d)) detail))))

;; 1. in the engine: every set! of a door global sits in declare-world!, reset!,
;;    or a named layering door layering its own global
(let* ((w (writers engine))
       (stray (filter (lambda (s)
                        (let ((g (car s)) (in (cadr s)))
                          (not (or (memq in '(declare-world! reset!))
                                   (let ((l (assq in layerings))) (and l (memq g (cdr l))))))))
                      w)))
  (check "engine.scm: a door global is assigned in declare-world!/reset!, or by its named layering door (ingest-located! declares through the door)"
         (null? stray) stray)
  (check "…and every layering door named here still exists and still writes its global"
         (every (lambda (l) (any (lambda (s) (and (eq? (cadr s) (car l)) (memq (car s) (cdr l)))) w))
                layerings)
         (filter (lambda (l) (not (any (lambda (s) (eq? (cadr s) (car l))) w))) layerings)))

;; 2. the satellites, tests, benches and demo assign none of them
(let ((stray (append-map writers (append satellites outside))))
  (check "no satellite, test, bench or demo assigns a door global (they declare, or layer through a door)"
         (null? stray) (delete-duplicates (map (lambda (s) (list (car s) (caddr s))) stray))))

;; 3. mkcells! has one caller; reset! two — in module/
(let* ((module-files (append (list engine) satellites
                             (filter (lambda (f) (not (or (string-contains f "/tests/")
                                                          (string-contains f "/attic/"))))   ; the retired prototypes
                                     (scm-files-under "module/playnet/planner"))))
       (callers (lambda (name)
                  (delete-duplicates
                   (append-map (lambda (path)
                                 (append-map (lambda (form)
                                               (let ((n (defined-name form)))
                                                 (if (and (not (eq? n name))
                                                          (not (and (pair? form) (eq? (car form) 'define-module)))   ; the export list names it
                                                          (pair? (calls-in form (call-of? name))))
                                                     (list (or n '<toplevel>)) '())))
                                             (forms-of path)))
                               module-files)))))
  (check "mkcells! is called by declare-world! alone" (equal? (callers 'mkcells!) '(declare-world!)) (callers 'mkcells!))
  (check "reset! has ONE caller: declare-world! (a declaration IS a fresh world)"
         (equal? (callers 'reset!) '(declare-world!)) (callers 'reset!)))

(format #t "~%~a passed, ~a failed~%" *pass* *fail*)
(exit (if (= *fail* 0) 0 1))
