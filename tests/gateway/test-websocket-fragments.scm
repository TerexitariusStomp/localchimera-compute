;;; test-websocket-fragments.scm — a fragmented WebSocket message arrives whole
;;;
;;; A browser splits a large send into frames: Chromium sent a 100 KB CapTP
;;; request as a first frame of 80 490 bytes (fin=0, binary) and a continuation
;;; of 19 599 (fin=1, op=0).  guile-websocket 0.3.0's read-data-frame built the
;;; message from the fragments read BEFORE the final one, so the last
;;; fragment's bytes were lost, the syrup decode failed, and the gateway never
;;; answered (deploy/UPSTREAM-ISSUES.md #14).  module/web/socket/frame.scm
;;; carries the one-line fix; this file pins it, over a real socket pair with
;;; the masking a browser applies.
;;;
;;; Run: guile -L module -L tests tests/gateway/test-websocket-fragments.scm

(use-modules (playnet test harness)
             (web socket frame)
             (rnrs bytevectors)
             (ice-9 binary-ports)
             (srfi srfi-1)
             (srfi srfi-13))

(define key (bytevector-copy #vu8(17 34 51 68)))   ; a client's masking key

(define (bytes n seed)
  (let ((bv (make-bytevector n)))
    (do ((i 0 (+ i 1))) ((= i n) bv)
      (bytevector-u8-set! bv i (modulo (+ seed (* i 7)) 251)))))

(define (join . bvs)
  (let* ((len (fold + 0 (map bytevector-length bvs)))
         (out (make-bytevector len)))
    (let loop ((bvs bvs) (at 0))
      (if (null? bvs) out
          (begin (bytevector-copy! (car bvs) 0 out at (bytevector-length (car bvs)))
                 (loop (cdr bvs) (+ at (bytevector-length (car bvs)))))))))

(define (send-and-read frames)
  "Write FRAMES down one end of a socket pair; return (values the message
   read-data-frame yields at the other end, the writer's port)."
  (define-values (reader writer) (apply values (let ((p (socketpair PF_UNIX SOCK_STREAM 0))) (list (car p) (cdr p)))))
  (for-each (lambda (f) (write-frame f writer)) frames)
  (force-output writer)
  (values (read-data-frame reader #:echo-close? #t) writer))

(display "\n── the patched copy is the first on the load path ──\n")
(check "web/socket/frame.scm is found under module/ before any installed guile-websocket"
       (let ((f (search-path %load-path "web/socket/frame.scm")))
         (and f (string-contains f "module/web/socket/frame.scm"))))

(display "\n── an unfragmented frame is unchanged ──\n")
(let ((a (bytes 1000 1)))
  (call-with-values (lambda () (send-and-read (list (make-frame #t 'binary key a))))
    (lambda (m w)
      (check "one frame, one message" (frame-data m) a))))

(display "\n── a message in two fragments keeps its last fragment ──\n")
(let ((a (bytes 80490 3)) (b (bytes 19599 9)))        ; the sizes seen on the wire
  (call-with-values
      (lambda () (send-and-read (list (make-frame #f 'binary key a)
                                      (make-frame #t 'continuation key b))))
    (lambda (m w)
      (check "the reassembled message is 100089 bytes" (bytevector-length (frame-data m)) 100089)
      (check "...and is exactly first fragment ++ last fragment"
             (bytevector=? (frame-data m) (join a b)) #t)
      (check "the message is a binary frame" (frame-type m) 'binary))))

(display "\n── three fragments ──\n")
(let ((a (bytes 5000 1)) (b (bytes 3000 2)) (c (bytes 700 3)))
  (call-with-values
      (lambda () (send-and-read (list (make-frame #f 'binary key a)
                                      (make-frame #f 'continuation key b)
                                      (make-frame #t 'continuation key c))))
    (lambda (m w)
      (check "first ++ middle ++ last" (bytevector=? (frame-data m) (join a b c)) #t))))

(display "\n── a ping between fragments is answered and the message still arrives whole ──\n")
(let ((a (bytes 4000 5)) (b (bytes 900 6)))
  (call-with-values
      (lambda () (send-and-read (list (make-frame #f 'binary key a)
                                      (make-ping-frame #vu8(1 2 3))
                                      (make-frame #t 'continuation key b))))
    (lambda (m w)
      (check "the message is whole" (bytevector=? (frame-data m) (join a b)) #t)
      (let ((pong (read-frame w)))
        (check "the ping was answered with a pong carrying its data"
               (and (pong-frame? pong) (frame-data pong)) #vu8(1 2 3))))))

(display "\n── a final fragment with an empty payload ──\n")
(let ((a (bytes 2000 8)))
  (call-with-values
      (lambda () (send-and-read (list (make-frame #f 'binary key a)
                                      (make-frame #t 'continuation key #vu8()))))
    (lambda (m w)
      (check "the first fragment alone is the message" (bytevector=? (frame-data m) a) #t))))

(test-summary!)
