;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/interface/command-dispatch.scm — Generic command router
;;;
;;; A layer-pure actor: holds a hashmap of command-name → handler procedure
;;; and dispatches lookups. Knows nothing about scopes, transports, or any
;;; specific command set. Backends supply their own command tables to it;
;;; the scope-handler ships with one (see backends/scope.scm), and other
;;; backends can ship their own.
;;;
;;; Handler signature:
;;;
;;;   (handler ctx args-string) → reply-string
;;;
;;; CTX is whatever the backend extended its request-ctx with — this actor
;;; doesn't care. It just passes ctx through.

(define-module (localchimera interface command-dispatch)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:export (^command-dispatch))


(define (^command-dispatch bcom command-table)
  ;; command-table: hashmap of string → handler procedure

  (methods

    ((dispatch ctx command-name args-string)
     ;; Look up command in table and execute.
     ;; Returns (list 'response text) or (list 'error reason).
     (let ((handler (hashmap-ref command-table command-name #f)))
       (if handler
           (catch #t
             (lambda ()
               (list 'response (handler ctx args-string)))
             (lambda (key . rest)
               (list 'error (format #f "~a: ~a" key rest))))
           (list 'error (format #f "Unknown command: ~a. Try /help" command-name)))))

    ((register-command name handler)
     (bcom (^command-dispatch bcom
             (hashmap-set command-table name handler))))

    ((remove-command name)
     (bcom (^command-dispatch bcom
             (hashmap-remove command-table name))))

    ((available-commands)
     (hashmap-fold (lambda (k v acc) (cons k acc)) '() command-table))))
