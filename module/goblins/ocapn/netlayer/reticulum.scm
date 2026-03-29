;;; Reticulum netlayer for Goblins OCapN
;;;
;;; Enables Goblins actors over Reticulum mesh networks (LoRa, serial,
;;; I2P, packet radio, TCP, etc.) via an external Python bridge daemon.
;;;
;;; Follows the same pattern as (goblins ocapn netlayer libp2p):
;;; - Control socket to bridge daemon (line-delimited text)
;;; - Per-connection Unix socket pairs for data
;;; - ^base-port-netlayer handles the common interface
;;;
;;; See docs/RETICULUM-NETLAYER.md for architecture details.

(define-module (goblins ocapn netlayer reticulum)
  #:use-module (ice-9 match)
  #:use-module (rnrs io ports)
  #:use-module (goblins)
  #:use-module (goblins vat)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib io)
  #:use-module (goblins actor-lib swappable)
  #:use-module (goblins actor-lib on)
  #:use-module (goblins ocapn ids)
  #:use-module (goblins ocapn netlayer utils)
  #:use-module (goblins ocapn netlayer base-port)
  #:export (^reticulum-netlayer
            reticulum-netlayer-env))

(define default-control-path "/var/run/reticulum-bridge.sock")
(define default-socket-dir "/tmp/goblins-reticulum")

(define (build-path . parts)
  (string-join parts file-name-separator-string))

;;; Set up the bridge connection: send NEW command, receive our destination hash,
;;; prepare incoming/outgoing socket paths.
(define (setup-bridge control-path socket-dir)
  ;; Ensure socket directory exists
  (unless (file-exists? socket-dir)
    (mkdir socket-dir))

  ;; Generate unique socket paths for this session
  (define incoming-path
    (random-tmp-filename socket-dir
                         #:format-name
                         (lambda (name)
                           (format #f "ocapn-in-~a-~a.sock" (getuid) name))))
  (define outgoing-path
    (random-tmp-filename socket-dir
                         #:format-name
                         (lambda (name)
                           (format #f "ocapn-out-~a-~a.sock" (getuid) name))))

  ;; Server socket for incoming connections (bridge connects here)
  (define incoming-server
    (spawn ^io (make-server-unix-domain-socket incoming-path)
           #:cleanup close-port))

  ;; Control socket to bridge daemon
  (define control-sock
    (spawn ^line-delimited-port (make-client-unix-domain-socket control-path)))

  ;; Send NEW command
  (define new-msg
    (format #f "NEW incoming:~a outgoing:~a protocol:ocapn version:1.0"
            incoming-path outgoing-path))
  (<-np control-sock 'write-line new-msg)

  ;; Parse response: "destination:<hex-hash>"
  (define-values (dest-hash-vow dest-hash-resolver)
    (spawn-promise-and-resolver))

  (on (<- control-sock 'read-line)
      (lambda (response)
        (match (string-split response #\:)
          (("destination" hash)
           ($ dest-hash-resolver 'fulfill hash))
          (else
           ($ dest-hash-resolver 'break
              (format #f "Unexpected bridge response: ~a" response))))))

  (values dest-hash-vow control-sock incoming-server outgoing-path))

;;; Set up an outgoing connection: connect to the outgoing socket,
;;; send CONNECT command. The bridge establishes the Reticulum Link
;;; and proxies data through this socket.
(define (setup-outgoing-sock sock dest-hash)
  (display (format #f "CONNECT ~a\n" dest-hash) sock)
  (flush-output-port sock))

;;; The netlayer actor (setup phase — has our destination hash)
(define-actor (^reticulum-netlayer:setup bcom
                                         dest-hash control-path socket-dir
                                         #:optional
                                         init-control-sock
                                         init-incoming-server
                                         init-outgoing-path)
  #:portrait (lambda ()
               (list dest-hash control-path socket-dir))

  (define-values (_hash _control-sock incoming-server outgoing-path)
    (if (and init-control-sock init-incoming-server init-outgoing-path)
        (values #f #f init-incoming-server init-outgoing-path)
        (let-values (((dv cs is op) (setup-bridge control-path socket-dir)))
          (values dv cs is op))))

  (define our-location
    (make-ocapn-peer 'reticulum dest-hash #f))

  (define (incoming-accept)
    (on (<- incoming-server
            (lambda (port)
              (accept port O_NONBLOCK)))
        (match-lambda
          ((client . addr)
           (setvbuf client 'block 1024)
           client))
        #:promise? #t))

  (define (outgoing-connect-location location)
    (unless (eq? (ocapn-peer-transport location) 'reticulum)
      (error "Wrong netlayer! Expected reticulum" location))
    (spawn-fibrous-vow
     (lambda ()
       (let ((dest (ocapn-peer-designator location))
             (sock (make-client-unix-domain-socket outgoing-path)))
         (setup-outgoing-sock sock dest)
         sock))))

  (^base-port-netlayer bcom our-location
                       incoming-accept outgoing-connect-location))

;;; The fresh netlayer (no destination hash yet — needs setup)
(define-actor (^reticulum-netlayer:fresh _bcom swap-to control-path socket-dir)
  (define-values (setup-vow setup-resolver)
    (spawn-promise-and-resolver))

  (define-values (dest-hash-vow control-sock incoming-server outgoing-path)
    (setup-bridge control-path socket-dir))

  (let-on ((dest-hash dest-hash-vow))
          (let ((ready (spawn ^reticulum-netlayer:setup
                              dest-hash control-path socket-dir
                              control-sock incoming-server outgoing-path)))
            (<-np swap-to ready)
            (<-np setup-resolver 'fulfill ready)))

  (lambda args
    (match args
      [('netlayer-name) 'reticulum]
      [args (apply <- setup-vow args)])))

;;; Public constructor
(define* (^reticulum-netlayer _bcom
                              #:key
                              [control-path default-control-path]
                              [socket-dir default-socket-dir])
  "Spawn a Reticulum netlayer. Connects to reticulum-bridge.py via
   the control socket. Enables Goblins actors over any Reticulum transport."
  (define-values (swap-to-vow swap-to-resolver)
    (spawn-promise-and-resolver))

  (define netlayer
    (spawn ^reticulum-netlayer:fresh swap-to-vow control-path socket-dir))

  (define-values (proxy swap-to)
    (swappable netlayer '^reticulum-netlayer))
  ($ swap-to-resolver 'fulfill swap-to)
  proxy)

;;; Persistence environment
(define reticulum-netlayer-env
  (persistence-env-compose
   (namespace-env
    (goblins ocapn netlayer reticulum)
    ^reticulum-netlayer:fresh
    ^reticulum-netlayer:setup)
   swappable-env))
