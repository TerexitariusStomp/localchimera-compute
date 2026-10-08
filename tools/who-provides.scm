#!/usr/bin/env -S guile --no-auto-compile -L module -s
!#
;;; who-provides.scm — for each NAME, which candidate module exports it?
;;;
;;;   tools/who-provides.scm --names a,b,c --mods '(mod one)' '(mod two)' …
;;;
;;; The point of a lift is that a file states what it needs. Deriving that list
;;; by hand from a compile's unbound-variable list is the slow half of the job,
;;; and it is exactly the question the module system can answer directly: ask
;;; each candidate interface whether it binds the name. Static inspection cannot
;;; do this — re-exports, #:select and #:replace all move where a name lives.
;;;
;;; Prints one line per resolved name, then a MODULES: line with the minimal
;;; import set, and an UNRESOLVED: line for names no candidate provides (those
;;; are either core Guile, or real defects — see the despaghetti skill).

;; A plain script, not a module: `-e main` would look for main in guile-user
;; while a define-module would have put it somewhere else.
(use-modules (ice-9 format) (srfi srfi-1))

(define (split-commas s)
  (let loop ((cs (string->list s)) (cur '()) (out '()))
    (cond ((null? cs)
           (reverse (if (null? cur) out (cons (list->string (reverse cur)) out))))
          ((char=? (car cs) #\,)
           (loop (cdr cs) '() (if (null? cur) out (cons (list->string (reverse cur)) out))))
          (else (loop (cdr cs) (cons (car cs) cur) out)))))

(define (safe-interface m)
  (catch #t (lambda () (resolve-interface m)) (lambda _ #f)))

(define (main args)
  (let* ((tail (cdr args))
         (names (let loop ((a tail))
                  (cond ((null? a) '())
                        ((string=? (car a) "--names")
                         (map string->symbol (split-commas (cadr a))))
                        (else (loop (cdr a))))))
         (mods (let loop ((a tail) (acc '()) (on #f))
                 (cond ((null? a) (reverse acc))
                       ((string=? (car a) "--mods") (loop (cdr a) acc #t))
                       ((string=? (car a) "--names") (loop (cddr a) acc #f))
                       (on (loop (cdr a) (cons (with-input-from-string (car a) read) acc) #t))
                       (else (loop (cdr a) acc on)))))
         (ifaces (filter-map (lambda (m) (let ((i (safe-interface m))) (and i (cons m i)))) mods))
         (used '()) (unresolved '()))
    (for-each
     (lambda (n)
       ;; FIRST match wins, and candidates are given in the caller's preferred
       ;; order — for these fragments that is the umbrella's own import order,
       ;; which is the order the includer resolved them in too.
       (let ((hit (find (lambda (p) (module-variable (cdr p) n)) ifaces)))
         (if hit
             (begin (format #t "~a  <- ~a~%" n (car hit))
                    (unless (member (car hit) used) (set! used (cons (car hit) used))))
             (set! unresolved (cons n unresolved)))))
     names)
    (format #t "~%MODULES: ~a~%" (reverse used))
    (format #t "UNRESOLVED: ~a~%" (reverse unresolved))))

(main (command-line))
