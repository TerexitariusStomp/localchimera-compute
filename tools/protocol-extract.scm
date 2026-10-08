#!/usr/bin/env -S guile -L module
!#
;;; tools/protocol-extract.scm — the door heads of the three protocol objects
;;;
;;; Reads module/playnet/gateway/lobby.scm and module/playnet/planner/doors/service.scm
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
  "Every (methods …), (declared-methods OBJECT …) or (home-routed OBJECT ROUTE …) form anywhere under
TREE, in order, each normalized to (methods clause …)."
  (let walk ((t tree) (acc '()))
    (cond
     ((and (pair? t) (eq? (car t) 'methods))
      (walk (cdr t) (cons t acc)))
     ((and (pair? t) (eq? (car t) 'declared-methods) (pair? (cdr t)))
      (walk (cddr t) (cons (cons 'methods (cddr t)) acc)))
     ;; (home-routed OBJECT ROUTE clause …): declared-methods behind the one routing function
     ((and (pair? t) (eq? (car t) 'home-routed) (pair? (cdr t)) (pair? (cddr t)))
      (walk (cdddr t) (cons (cons 'methods (cdddr t)) acc)))
     ((pair? t) (walk (cdr t) (walk (car t) acc)))
     (else acc))))

(define (door-heads mform)
  "((name . args) …) for one (methods …) form, skipping non-door clauses."
  (filter-map (lambda (clause)
                (match clause
                  ((((? symbol? name) . args) . _) (cons name args))
                  (_ #f)))
              (cdr mform)))

(define (object-doors file object-name)
  "The methods forms in FILE whose first door names identify OBJECT-NAME."
  (let* ((forms (methods-forms (read-all file)))
         (pick (lambda (first-door) (find (lambda (m) (assq first-door (door-heads m))) forms))))
    (door-heads
     (or (pick (case object-name
                 ((lobby) 'signup) ((session) 'whoami) ((planner) 'set-personhood-checker!)))
         (error "protocol-extract: object not found" object-name)))))

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
  (let* ((forms (methods-forms (read-all "module/playnet/gateway/lobby.scm")))
         (m (find (lambda (m) (assq 'whoami (door-heads m))) forms)))
    (filter-map (lambda (clause)
                  (match clause
                    ((((? symbol? name) . _) . body) (cons name (clause-target name body)))
                    (_ #f)))
                (cdr m))))

(define %objects
  `((lobby   . "module/playnet/gateway/lobby.scm")
    (session . "module/playnet/gateway/lobby.scm")
    (planner . "module/playnet/planner/doors/service.scm")))

(define (all-doors)
  (append-map (lambda (o) (map (lambda (d) (cons (car o) d)) (object-doors (cdr o) (car o))))
              %objects))

(match (cdr (command-line))
  (("sexp") (for-each (lambda (d) (write d) (newline)) (all-doors)))
  (("targets") (for-each (lambda (d) (write d) (newline)) (session-targets)))
  (_ (for-each (lambda (d) (format #t "~a\t~a\t~s~%" (car d) (cadr d) (cddr d))) (all-doors))))
