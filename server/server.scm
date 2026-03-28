#!/usr/bin/env -S guile -L module
!#
;;; xorg-server.scm — Simple WebSocket server for xorg
;;; Wire protocol: signed S-expressions
;;; Run with: guile -L module xorg-server.scm [port]

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib sealers)
             (goblins actor-lib ward)
             ((xorg gplay) #:hide (generate-key-pair key-pair->public-key))
             (goblins utils crypto)
             (ice-9 receive)
             (ice-9 match)
             (ice-9 format)
             (ice-9 rdelim)
             (web server)
             (web request)
             (web response)
             (web uri)
             (rnrs bytevectors)
             (fibers)
             (fibers channels))

;;; ── Base bindings ──────────────────────────────────────────────────────────

(define server-base-bindings
  `((+ . ,+) (- . ,-) (* . ,*) (/ . ,/)
    (> . ,>) (< . ,<) (= . ,=) (>= . ,>=) (<= . ,<=)
    (not . ,not) (equal? . ,equal?) (eq? . ,eq?)
    (cons . ,cons) (car . ,car) (cdr . ,cdr)
    (list . ,list) (append . ,append) (reverse . ,reverse) (length . ,length)
    (map . ,map) (for-each . ,for-each)
    (null? . ,null?) (pair? . ,pair?)
    (number? . ,number?) (string? . ,string?) (symbol? . ,symbol?)
    (procedure? . ,procedure?) (boolean? . ,boolean?)
    (string-append . ,string-append) (string-length . ,string-length)
    (display . ,display) (newline . ,newline) (write . ,write)
    (void . ,(lambda () (if #f #f)))))

;;; ── Server state ──────────────────────────────────────────────────────────

(define *org-vat* #f)
(define *org* #f)
(define *inbox* #f)
(define *incanter* #f)
(define *clients* '())     ;; alist: name → (pubkey controller)
(define *pending* '())     ;; alist: name → pubkey (waiting for approval)

;;; ── Main ──────────────────────────────────────────────────────────────────

(define (main)
  (let ((port (if (> (length (command-line)) 1)
                  (string->number (cadr (command-line)))
                  8080)))

    ;; Create the org
    (let* ((kp (generate-key-pair))
           (pk (key-pair->public-key kp)))
      (set! *org-vat* (spawn-vat #:name "org-host"))
      (with-vat *org-vat*
        (let ((org (make-initial-org server-base-bindings #:public-key pk)))
          (receive (warden incanter)
            (spawn-warding-pair)
            (let ((inbox (spawn ^org-inbox org '() 0 warden incanter)))
              (set! *org* org)
              (set! *inbox* inbox)
              (set! *incanter* incanter))))))

    (format #t "\n════════════════════════════════════════\n")
    (format #t "  xorg server ready on port ~a\n" port)
    (format #t "  Connect browser: ?server=ws://localhost:~a\n" port)
    (format #t "  Type 'help for commands.\n")
    (format #t "════════════════════════════════════════\n\n")

    ;; TODO: Add actual WebSocket server here
    ;; For now, just the admin REPL
    (let loop ()
      (display "server> ")
      (force-output)
      (let ((input (read)))
        (cond
         ((eof-object? input) (display "\nShutting down.\n"))
         ((eq? input 'quit) (display "Shutting down.\n"))
         ((and (pair? input) (eq? (car input) 'approve))
          (let* ((name (symbol->string (cadr input)))
                 (pending-entry (assoc name *pending*)))
            (if (not pending-entry)
                (format #t "No pending join for '~a'.\n" name)
                (let ((applicant-pk (cdr pending-entry)))
                  (with-vat *org-vat*
                    (let* ((pair (create-expressor-pair *org* (string->symbol name) applicant-pk))
                           (controller (cdr pair)))
                      (set! *clients*
                        (cons (cons name (list applicant-pk controller)) *clients*))
                      (set! *pending*
                        (let rm ((lst *pending*))
                          (cond ((null? lst) '())
                                ((string=? (caar lst) name) (rm (cdr lst)))
                                (else (cons (car lst) (rm (cdr lst)))))))))
                  (format #t "Approved '~a'.\n" name)))))
         ((eq? input 'pending)
          (if (null? *pending*)
              (display "No pending requests.\n")
              (for-each (lambda (p)
                          (format #t "  ~a\n" (car p)))
                        *pending*)))
         ((eq? input 'clients)
          (if (null? *clients*)
              (display "No connected clients.\n")
              (for-each (lambda (c)
                          (format #t "  ~a\n" (car c)))
                        *clients*)))
         ((eq? input 'bindings)
          (with-vat *org-vat*
            (for-each (lambda (b)
                        (unless (procedure? (cdr b))
                          (format #t "  ~a = ~a\n" (car b) (cdr b))))
                      ($ *org* 'bindings))))
         ((eq? input 'history)
          (with-vat *org-vat*
            (for-each (lambda (e)
                        (format #t "  v~a [~a] : ~a\n"
                                (car e)
                                ($ *org* 'expressor-name (cadr e))
                                (caddr e)))
                      (reverse ($ *org* 'history)))))
         ((eq? input 'help)
          (display "Commands:\n")
          (display "  (approve name)   approve a pending join\n")
          (display "  pending          show pending requests\n")
          (display "  clients          show approved clients\n")
          (display "  bindings         show org bindings\n")
          (display "  history          show org history\n")
          (display "  quit             shut down\n"))
         (else
          (display "Unknown command. Type 'help.\n")))
        (unless (or (eof-object? input) (eq? input 'quit))
          (loop))))))

(run-fibers main)
