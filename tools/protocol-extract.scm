#!/usr/bin/env -S guile -L module
!#
;;; tools/protocol-extract.scm — the door heads of the three protocol objects
;;;
;;; Reads module/playnet/gateway/lobby.scm and module/playnet/doors/service.scm
;;; as data, finds every Goblins `(methods ((name . args) …) …)` form, and
;;; prints one line per door: object, name, argument list as written. The
;;; Phase B1 declaration (playnet protocol) starts from this output, and the
;;; linter that keeps declaration and code in step reuses `door-heads`.
;;;
;;;   protocol-extract.scm            all three objects, TSV
;;;   protocol-extract.scm sexp       as an alist, for the declaration seed

(use-modules (ice-9 match) (ice-9 format) (srfi srfi-1))

(define (read-all file)
  (call-with-input-file file
    (lambda (p)
      (let loop ((acc '()))
        (let ((f (read p)))
          (if (eof-object? f) (reverse acc) (loop (cons f acc))))))))

(define (methods-forms tree)
  "Every (methods …), (declared-methods OBJECT …), (declared-methods* OBJECT
(fragment …) …), (declared-doors OBJECT …) or (home-routed OBJECT ROUTE …)
form anywhere under TREE, in order, each normalized to (methods clause …).
The forms that name their object carry it: (OBJECT . (methods clause …));
a bare `methods` form carries #f."
  (let walk ((t tree) (acc '()))
    (cond
     ((and (pair? t) (eq? (car t) 'methods))
      (walk (cdr t) (cons (cons #f t) acc)))
     ((and (pair? t) (memq (car t) '(declared-methods declared-doors)) (pair? (cdr t)))
      (walk (cddr t) (cons (cons (cadr t) (cons 'methods (cddr t))) acc)))
     ;; (declared-methods* OBJECT (fragment …) clause …): the object's own clauses,
     ;; composed with fragments declared elsewhere (declared-doors)
     ((and (pair? t) (eq? (car t) 'declared-methods*) (pair? (cdr t)) (pair? (cddr t)))
      (walk (cdddr t) (cons (cons (cadr t) (cons 'methods (cdddr t))) acc)))
     ;; (home-routed OBJECT ROUTE clause …): declared-methods behind the one routing function
     ((and (pair? t) (eq? (car t) 'home-routed) (pair? (cdr t)) (pair? (cddr t)))
      (walk (cdddr t) (cons (cons (cadr t) (cons 'methods (cdddr t))) acc)))
     ((pair? t) (walk (cdr t) (walk (car t) acc)))
     (else acc))))

(define (door-heads mform)
  "((name . args) …) for one (methods …) form, skipping non-door clauses."
  (filter-map (lambda (clause)
                (match clause
                  ((((? symbol? name) . args) . _) (cons name args))
                  (_ #f)))
              (cdr mform)))

(define (object-forms files object-name)
  "The methods forms for OBJECT-NAME across FILES: every form that names the
object, plus — for a bare `methods` form — the one whose first door marks it."
  (let* ((tagged (append-map (lambda (f) (if (file-exists? f) (methods-forms (read-all f)) '()))
                             files))
         (named  (filter-map (lambda (p) (and (eq? (car p) object-name) (cdr p))) tagged))
         (marker (case object-name
                   ((lobby) 'signup) ((session) 'whoami) ((planner) 'set-personhood-checker!)))
         (bare   (filter-map (lambda (p) (and (not (car p)) (assq marker (door-heads (cdr p))) (cdr p)))
                             tagged)))
    (let ((forms (append named bare)))
      (if (null? forms) (error "protocol-extract: object not found" object-name) forms))))

(define (object-doors files object-name)
  "((name . args) …) for OBJECT-NAME: the union of its forms' heads, in order."
  (append-map door-heads (object-forms files object-name)))

(define (clause-target name clause)
  "Where a session clause sends its own act: planner (planner! or a send to
planner-service naming NAME), governance (a send to governance-svc naming
NAME), else self."
  (let walk ((t clause) (found 'self))
    (cond
     ((not (pair? t)) found)
     ((and (eq? (car t) 'planner!) (pair? (cdr t)) (equal? (cadr t) (list 'quote name))) 'planner)
     ((and (eq? (car t) '<-) (pair? (cdr t)) (pair? (cddr t)) (equal? (caddr t) (list 'quote name)))
      (case (cadr t) ((planner-service) 'planner) ((governance-svc) 'governance) (else found)))
     (else (walk (cdr t) (walk (car t) found))))))

(define (session-targets)
  "((name . target) …) for every session door, read off its clause body."
  (append-map (lambda (m)
                (filter-map (lambda (clause)
                              (match clause
                                ((((? symbol? name) . _) . body) (cons name (clause-target name body)))
                                (_ #f)))
                            (cdr m)))
              (object-forms (assq-ref %objects 'session) 'session)))

;; An object's doors may be written in more than one file: the object's own
;; module, and the fragments it composes (declared-doors, identity/doors.scm,
;; identity/body-doors.scm).
(define %objects
  `((lobby   "module/playnet/gateway/lobby.scm" "module/playnet/identity/doors.scm")
    (session "module/playnet/gateway/lobby.scm" "module/playnet/identity/doors.scm"
             "module/playnet/identity/body-doors.scm")
    (planner "module/playnet/doors/service.scm")))

(define (all-doors)
  (append-map (lambda (o) (map (lambda (d) (cons (car o) d)) (object-doors (cdr o) (car o))))
              %objects))

(match (cdr (command-line))
  (("sexp") (for-each (lambda (d) (write d) (newline)) (all-doors)))
  (("targets") (for-each (lambda (d) (write d) (newline)) (session-targets)))
  (_ (for-each (lambda (d) (format #t "~a\t~a\t~s~%" (car d) (cadr d) (cddr d))) (all-doors))))
