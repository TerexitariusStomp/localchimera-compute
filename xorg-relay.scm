#!/usr/bin/env -S guile -L module
!#
;;; xorg-relay.scm — Prelay relay server for xorg
;;; A pure routing relay. No org logic — just connects peers.
;;; Run with: guile -L module xorg-relay.scm
;;; Or:       make relay

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib facet)
             (goblins ocapn captp)
             (goblins ocapn netlayer websocket)
             (goblins ocapn netlayer prelay-utils)
             (goblins ocapn ids)
             (ice-9 match)
             (ice-9 format)
             (fibers))

(define *relay-vat* #f)
(define *mycapn* #f)
(define *admin* #f)

(define (main)
  (let ((port (if (> (length (command-line)) 1)
                  (string->number (cadr (command-line)))
                  8080)))

    (display "Starting xorg prelay relay...\n")

    (set! *relay-vat* (spawn-vat #:name "relay"))

    (with-vat *relay-vat*
      (let* ((netlayer (spawn ^websocket-netlayer
                              #:host "0.0.0.0"
                              #:port port
                              #:encrypted? #f))
             (mycapn (spawn-mycapn netlayer))
             (enliven-facet (spawn ^facet mycapn 'enliven))
             (register-facet (spawn (lambda (bcom)
                                      (methods
                                       [(register obj)
                                        ($ mycapn 'register obj 'websocket)])))))
        (set! *mycapn* mycapn)
        (set! *admin* (spawn ^prelay-admin enliven-facet register-facet))))

    (format #t "\n════════════════════════════════════════\n")
    (format #t "  xorg relay ready on ws://0.0.0.0:~a\n" port)
    (format #t "  Type 'help for commands.\n")
    (format #t "════════════════════════════════════════\n\n")

    ;; Admin REPL
    (let loop ()
      (display "relay> ")
      (force-output)
      (let ((input (read)))
        (cond
         ((eof-object? input) (display "\nShutting down.\n"))
         ((eq? input 'quit) (display "Shutting down.\n"))
         ((and (pair? input) (eq? (car input) 'add-account))
          (let ((name (cadr input)))
            (with-vat *relay-vat*
              (on (<- *admin* 'add-account (symbol->string name))
                  (lambda (setup-sref)
                    (format #t "\nAccount '~a' created.\nSetup sturdyref:\n  ~a\n\nrelay> "
                            name (ocapn-id->string setup-sref))
                    (force-output))))
            (loop)))
         ((eq? input 'accounts)
          (with-vat *relay-vat*
            (let ((accts ($ *admin* 'get-accounts)))
              (if (null? accts)
                  (display "No accounts.\n")
                  (for-each (lambda (name)
                              (format #t "  ~a\n" name))
                            accts))))
          (loop))
         ((eq? input 'help)
          (display "Commands:\n")
          (display "  (add-account name)   create a relay account\n")
          (display "  accounts             list accounts\n")
          (display "  quit                 shut down\n")
          (loop))
         (else
          (display "Unknown command. Type 'help.\n")
          (loop)))))))

(run-fibers main)
