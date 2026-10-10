#!/usr/bin/env -S guile -L module
!#
;;; tools/door-call.scm — call a gateway door from a shell, signed by a device key
;;;
;;;   door-call.scm key <file>                make a device key in <file>
;;;                                            (a 32-byte seed, mode 0600) and
;;;                                            print its device AID — paste that
;;;                                            into the identity face's "an
;;;                                            outside interface" form
;;;   door-call.scm aid <file>                print the AID of an existing key
;;;   door-call.scm call <file> <object>/<name> [json-body] [--base URL]
;;;                                            POST the door, signed; prints the
;;;                                            reply JSON. Anonymous doors need
;;;                                            no key: pass - for <file>.
;;;
;;; The base is http://127.0.0.1:9091 (the door on the box itself) unless
;;; --base names another; reaching the box from elsewhere goes through nginx
;;; at https://<domain>/api/… — wrap the call in torsocks for the onion.
;;; The signature is the door profile (module/playnet/doors/http.scm);
;;; browser/api/openapi.json says what each door takes.

(use-modules ((playnet doors http) #:select (sign-door-request))
             ((playnet keri signify-portable) #:select (seed->ed25519-keypair))
             ((playnet keri crypto-primitives) #:select (keri-crypto-random-bytes ed25519-keypair-public))
             ((playnet keri cesr) #:select (cesr-bytes->qb64))
             (web client) (web response) (web uri)
             (rnrs bytevectors) (ice-9 match) (ice-9 format) (ice-9 binary-ports))

(define (read-seed file)
  (call-with-input-file file (lambda (p) (get-bytevector-n p 32)) #:binary #t))

(define (keypair-of file) (seed->ed25519-keypair (read-seed file)))
(define (aid-of kp) (cesr-bytes->qb64 "B" (ed25519-keypair-public kp)))

(define (make-key! file)
  (when (file-exists? file) (error "door-call: key file exists, refusing to overwrite" file))
  (let ((seed (keri-crypto-random-bytes 32)))
    (call-with-output-file file (lambda (p) (put-bytevector p seed)) #:binary #t)
    (chmod file #o600)
    (format #t "~a~%" (aid-of (seed->ed25519-keypair seed)))))

(define (call key-file door body base)
  (let* ((path (string-append "/api/" door))
         (url (string-append base path))
         (body-bv (string->utf8 body))
         (headers (append '((content-type . (application/json)))
                          (if (string=? key-file "-")
                              '()
                              (let ((kp (keypair-of key-file)))
                                (sign-door-request kp (aid-of kp) 'POST path body-bv))))))
    (call-with-values
        (lambda () (http-post url #:body body-bv #:headers headers #:decode-body? #f))
      (lambda (response reply)
        (format #t "~a~%" (if (bytevector? reply) (utf8->string reply) reply))
        (exit (if (= 200 (response-code response)) 0 1))))))

(define (base-of args)
  (let loop ((a args) (base "http://127.0.0.1:9091") (rest '()))
    (match a
      (("--base" b . more) (loop more b rest))
      ((x . more) (loop more base (cons x rest)))
      (() (cons base (reverse rest))))))

(match (cdr (command-line))
  (("key" file) (make-key! file))
  (("aid" file) (format #t "~a~%" (aid-of (keypair-of file))))
  (("call" . args)
   (match (base-of args)
     ((base key-file door) (call key-file door "{}" base))
     ((base key-file door body) (call key-file door body base))
     (_ (display "usage: door-call.scm call <key|-> <object>/<name> [json] [--base URL]\n") (exit 2))))
  (_ (display "usage: door-call.scm key <file> | aid <file> | call <key|-> <object>/<name> [json] [--base URL]\n")
     (exit 2)))
