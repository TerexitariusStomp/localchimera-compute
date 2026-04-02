;;; module/playnet/interface/adapters/repl.scm — REPL transport adapter
;;;
;;; Simplest possible transport: reads parse / and , prefixed commands,
;;; writes responses to an output port. Bare text (no prefix) is treated
;;; as an eval command.

(define-module (playnet interface adapters repl)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet interface transport)
  #:export (^repl-adapter))


(define (^repl-adapter _bcom output-port)
  ;; output-port: Scheme port for response output

  (methods

    ((send-message _ctx text)
     (display text output-port)
     (newline output-port)
     (force-output output-port))

    ((send-formatted _ctx blocks)
     ;; No rich formatting in terminal — fall back to plain text
     (for-each
       (lambda (block)
         (display block output-port)
         (newline output-port))
       blocks)
     (force-output output-port))

    ((parse-command raw-text)
     ;; Try /command first, then ,command, then treat as eval
     (let ((trimmed (string-trim-both raw-text)))
       (cond
         ((string-null? trimmed)
          (values #f #f))
         ((char=? (string-ref trimmed 0) #\/)
          (parse-slash-command trimmed))
         ((char=? (string-ref trimmed 0) #\,)
          (parse-comma-command trimmed))
         (else
          ;; Bare text → eval command
          (values "eval" trimmed)))))))
