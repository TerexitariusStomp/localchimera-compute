#!/usr/bin/env guile
!#
;;; check-provenance.scm — the graph is a proof obligation, not aspiration.
;;;
;;; Every fact in *provenance-facts* must have a live referent. This fails (nonzero
;;; exit) on any dangling tag, so "grounded" provably means grounded. Static: reads
;;; files, loads no Goblins, matches the extractor's guarantees.
;;;
;;;   (defines REF PATH)   → PATH exists AND contains `@defines REF`
;;;   (grounds CLAIM REF)  → REF has a (defines …)          — no grounding into air
;;;   (argues  CLAIM PATH) → PATH exists
;;;   (realizes CLAIM ID)  → ID appears literally in a grounding ref's file
;;;
;;; Usage:  guile docs/_scripts/check-provenance.scm      (make check-provenance)

(use-modules (ice-9 textual-ports)
             (srfi srfi-1))

(define %root
  (canonicalize-path (string-append (dirname (current-filename)) "/../..")))
(add-to-load-path (string-append %root "/module"))
(use-modules (playnet lang provenance))

;;; ── helpers ─────────────────────────────────────────────────────────────────

(define (abs path) (string-append %root "/" path))
(define (exists? path) (access? (abs path) F_OK))

(define *file-cache* '())
(define (slurp path)
  (or (assoc-ref *file-cache* path)
      (let ((s (if (exists? path) (call-with-input-file (abs path) get-string-all) "")))
        (set! *file-cache* (acons path s *file-cache*)) s)))

(define (facts-of tag) (filter (lambda (f) (eq? (car f) tag)) *provenance-facts*))
(define (defines-for ref)
  (let ((d (find (lambda (f) (eq? (cadr f) ref)) (facts-of 'defines))))
    (and d (caddr d))))
(define (grounds-of claim)
  (map caddr (filter (lambda (f) (eq? (cadr f) claim)) (facts-of 'grounds))))

(define errors '())
(define (fail! fmt . args) (set! errors (cons (apply format #f fmt args) errors)))

;;; ── checks ──────────────────────────────────────────────────────────────────

;; (defines REF PATH) → file exists and re-declares the ref
(for-each
 (lambda (f)
   (let ((ref (cadr f)) (path (caddr f)))
     (cond
       ((not (exists? path)) (fail! "defines ~a → missing file ~a" ref path))
       ((not (string-contains (slurp path) (format #f "@defines ~a" ref)))
        (fail! "defines ~a → ~a lacks `;; @defines ~a`" ref path ref)))))
 (facts-of 'defines))

;; (builds REF PARENT) → both refs are defined
(for-each
 (lambda (f)
   (let ((ref (cadr f)) (parent (caddr f)))
     (unless (defines-for ref)    (fail! "builds ~a ~a → ref ~a has no defines" ref parent ref))
     (unless (defines-for parent) (fail! "builds ~a ~a → parent ~a has no defines" ref parent parent))))
 (facts-of 'builds))

;; (grounds CLAIM REF) → the ref is defined somewhere
(for-each
 (lambda (f)
   (let ((claim (cadr f)) (ref (caddr f)))
     (unless (defines-for ref)
       (fail! "grounds ~a ~a → ref ~a grounds into thin air (no defines)" claim ref ref))))
 (facts-of 'grounds))

;; (argues CLAIM PATH) → the prose file exists
(for-each
 (lambda (f)
   (let ((claim (cadr f)) (path (caddr f)))
     (unless (exists? path) (fail! "argues ~a → missing prose file ~a" claim path))))
 (facts-of 'argues))

;; (realizes CLAIM ID) → the id appears literally in a grounding ref's file
(for-each
 (lambda (f)
   (let* ((claim (cadr f)) (id (caddr f))
          (paths (filter-map defines-for (grounds-of claim)))
          (idstr (symbol->string id)))
     (cond
       ((null? paths) (fail! "realizes ~a ~a → claim has no grounded ref to realize into" claim id))
       ((not (any (lambda (p) (string-contains (slurp p) idstr)) paths))
        (fail! "realizes ~a ~a → id `~a` not found in ~a" claim id id paths)))))
 (facts-of 'realizes))

;;; ── report ────────────────────────────────────────────────────────────────────

(let ((n (length *provenance-facts*)) (e (length errors)))
  (if (null? errors)
      (begin (format #t "provenance: ~a facts, all referents live ✓~%" n) (exit 0))
      (begin
        (format #t "provenance: ~a facts, ~a DANGLING:~%" n e)
        (for-each (lambda (m) (format #t "  ✗ ~a~%" m)) (reverse errors))
        (exit 1))))
