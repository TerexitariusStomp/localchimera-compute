#!/usr/bin/env -S guile -L module
!#
;;; xorg-server.scm — Host an org on a websocket netlayer
;;; Run with: guile -L module xorg-server.scm
;;; Or:       make server

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib sealers)
             (goblins actor-lib ward)
             (goblins ocapn captp)
             (goblins ocapn netlayer websocket)
             (goblins ocapn ids)
             ((xorg gplay) #:hide (generate-key-pair key-pair->public-key))
             (goblins utils crypto)
             (ice-9 receive)
             (ice-9 match)
             (fibers))

;;; ── Base bindings (same as the browser REPL) ──────────────────────────────

(define server-base-bindings
  `((+ . ,+) (- . ,-) (* . ,*) (/ . ,/)
    (> . ,>) (< . ,<) (= . ,=) (>= . ,>=) (<= . ,<=)
    (abs . ,abs) (max . ,max) (min . ,min)
    (modulo . ,modulo) (remainder . ,remainder) (expt . ,expt)
    (sqrt . ,sqrt) (floor . ,floor) (ceiling . ,ceiling) (round . ,round)
    (not . ,not) (equal? . ,equal?) (eq? . ,eq?) (eqv? . ,eqv?)
    (cons . ,cons) (car . ,car) (cdr . ,cdr)
    (list . ,list) (append . ,append) (reverse . ,reverse) (length . ,length)
    (map . ,map) (for-each . ,for-each)
    (null? . ,null?) (pair? . ,pair?) (list? . ,list?)
    (number? . ,number?) (string? . ,string?) (symbol? . ,symbol?)
    (procedure? . ,procedure?) (boolean? . ,boolean?)
    (string-append . ,string-append) (string-length . ,string-length)
    (display . ,display) (newline . ,newline) (write . ,write)
    (void . ,(lambda () (if #f #f)))))

;;; ── Server state ──────────────────────────────────────────────────────────

(define *org* #f)
(define *inbox* #f)
(define *incanter* #f)
(define *mycapn* #f)
(define *org-vat* #f)

;;; ── Main ──────────────────────────────────────────────────────────────────

(define (main)
  (let ((port (if (> (length (command-line)) 1)
                  (string->number (cadr (command-line)))
                  8080)))

    (display "Starting xorg server...\n")

    (set! *org-vat* (spawn-vat #:name "org-host"))

    (let* ((kp (generate-key-pair))
           (pk (key-pair->public-key kp)))
      (with-vat *org-vat*
        (let* ((netlayer (spawn ^websocket-netlayer
                                #:host "0.0.0.0"
                                #:port port
                                #:url (format #f "ws://localhost:~a" port)
                                #:encrypted? #f))
               (mycapn (spawn-mycapn netlayer))
               (org (make-initial-org server-base-bindings #:public-key pk)))
        (set! *mycapn* mycapn)
        (receive (warden incanter)
          (spawn-warding-pair)
          (let ((inbox (spawn ^org-inbox org '() 0 warden incanter)))
            (set! *org* org)
            (set! *inbox* inbox)
            (set! *incanter* incanter)
            ;; Register the inbox with OCapN
            (on (<- mycapn 'register inbox 'websocket)
                (lambda (sref)
                  (display "\n════════════════════════════════════════\n")
                  (display "  xorg server ready!\n")
                  (format #t "  Listening on ws://0.0.0.0:~a\n" port)
                  (display "  Sturdyref:\n  ")
                  (display (ocapn-id->string sref))
                  (display "\n════════════════════════════════════════\n\n")
                  (display "Waiting for connections...\n"))))))))


    ;; Start a simple admin REPL for approving members
    (let loop ()
      (display "server> ")
      (let ((input (read)))
        (match input
          ('quit (display "Shutting down.\n"))
          (('approve msg-id name)
           (let ((pending (with-vat *org-vat* ($ *inbox* 'pending))))
             (if (null? pending)
                 (display "No pending requests.\n")
                 (begin
                   (display (format #f "Approving ~a (msg-id: ~a)...\n" name msg-id))
                   (with-vat *org-vat*
                     (let* ((entry (let find ((es pending))
                                    (cond ((null? es) #f)
                                          ((= (assq-ref (car es) 'id) msg-id) (car es))
                                          (else (find (cdr es))))))
                            (applicant-identity (and entry (assq-ref entry 'sender)))
                            (applicant-pk (and applicant-identity
                                               ($ applicant-identity 'public-key))))
                       (if (not entry)
                           (display "Message not found.\n")
                           (let ((sealed-ctrl
                                  (approve-membership *inbox* *incanter* msg-id *org*
                                                      (string->symbol name)
                                                      (or applicant-pk "unknown")
                                                      applicant-identity)))
                             (display (format #f "Approved ~a. Sealed controller delivered.\n" name)))))))))
          ('pending
           (let ((p (with-vat *org-vat* ($ *inbox* 'pending))))
             (if (null? p)
                 (display "No pending requests.\n")
                 (for-each (lambda (e)
                             (format #t "  msg-id: ~a  sender: ~a  expr: ~a\n"
                                     (assq-ref e 'id)
                                     (assq-ref e 'sender)
                                     (assq-ref e 'expr)))
                           p))))
          ('bindings
           (with-vat *org-vat*
             (for-each (lambda (b)
                         (format #t "  ~a = ~a\n" (car b) (cdr b)))
                       ($ *org* 'bindings))))
          ('history
           (with-vat *org-vat*
             (for-each (lambda (e)
                         (format #t "  v~a [~a] : ~a\n"
                                 (car e)
                                 ($ *org* 'expressor-name (cadr e))
                                 (caddr e)))
                       (reverse ($ *org* 'history)))))
          ('help
           (display "Commands:\n")
           (display "  (approve MSG-ID \"name\")  approve membership\n")
           (display "  pending                   show pending requests\n")
           (display "  bindings                  show org bindings\n")
           (display "  history                   show org history\n")
           (display "  quit                      shut down\n"))
          (other
           (display "Unknown command. Type 'help for commands.\n")))
        (unless (eq? input 'quit)
          (loop)))))))

(run-fibers main)
