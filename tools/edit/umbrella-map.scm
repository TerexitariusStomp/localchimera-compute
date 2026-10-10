;;; umbrella-map.scm — every name an umbrella module exports, and the module that defines it.
;;;
;;;   guile -L module tools/edit/umbrella-map.scm playnet boot prelude   →  NAME TAB (playnet boot prelude …)
;;;
;;; "-" marks a name the umbrella defines itself, "?" one no loaded module owns. The
;;; input of tools/edit/retire-umbrella.py.

(use-modules (ice-9 format) (srfi srfi-1))
(define umbrella-name (map string->symbol (cdr (command-line))))
(define umb (resolve-module umbrella-name))
(define iface (resolve-interface umbrella-name))
;; variable → defining module, over every loaded module
(define owner (make-hash-table))
(define (walk m)
  (hash-for-each (lambda (k v) (unless (hashq-ref owner v) (hashq-set! owner v (module-name m)))) (module-obarray m))
  (hash-for-each (lambda (k sub) (when (module? sub) (walk sub))) (module-submodules m)))
(for-each (lambda (root) (walk (resolve-module root)))
          '((playnet) (srfi) (ice-9) (rnrs) (system) (goblins) (fibers) (web) (guile)))
(define exports '())
(module-for-each (lambda (n v) (set! exports (cons (cons n v) exports))) iface)
(for-each (lambda (p)
            (let ((o (hashq-ref owner (cdr p))))
              (format #t "~a\t~a\n" (car p)
                      (cond ((not o) "?")
                            ((equal? o umbrella-name) "-")
                            (else (string-join (map symbol->string o) " "))))))
          (sort exports (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b))))))
