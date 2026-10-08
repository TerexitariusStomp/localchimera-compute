;;; module/playnet/fleet/cdn-front.scm — a recorded fleet host, behind the CDN
;;;
;;; The reconciler names the hosts that want fronting on every tick
;;; ((playnet fleet reconciler) `set-host-fronting!`). This module answers:
;;; for each one without a zone on record it asks the deployment's CDN for
;;; a zone named after the host, pulling from the host's address, and writes
;;; the answer to <data-dir>/cdn-zones.scm:
;;;
;;;   (("playnet-web-1" (id . "…") (hostname . "…") (origin . "https://…")) …)
;;;
;;; The vendor call is an HTTP round trip over Tor, so it runs in its own
;;; thread, one host at a time; the reconciler's turn returns at once. A
;;; host whose zone could not be made is simply asked for again next tick —
;;; `ensure-zone` finds a zone that exists, so asking twice makes one.

(define-module (playnet fleet cdn-front)
  #:use-module (playnet fleet cdn)
  #:use-module (playnet utils files)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (make-host-fronting
            load-fronted-zones
            host-origin-url))

(define (load-fronted-zones file)
  (if (file-exists? file)
      (let ((v (call-with-input-file file read)))
        (if (list? v) v '()))
      '()))

(define (write-fronted-zones! file zones)
  (write-atomically! file (lambda (p) (write zones p) (newline p))))

(define (host-origin-url ipv4 params)
  "Where the edge pulls from: the host's own \"cdn-origin\", or its address."
  (or (assoc-ref params "cdn-origin")
      (string-append "https://" ipv4)))

(define* (make-host-fronting zones-file
                             #:key
                             (cdn-thunk (lambda ()
                                          (let ((config (load-cdn-config)))
                                            (and config (cdn-from-config config)))))
                             (log! (lambda (fmt . args) #t))
                             (spawn-thread call-with-new-thread))
  "The procedure to hand `set-host-fronting!`. CDN-THUNK answers the
deployment's CDN or #f; SPAWN-THREAD runs a thunk off the caller's thread
(a test passes one that runs it in place)."
  (define busy? #f)
  (define lock (make-mutex))

  (define (front-all! wanting)
    (let ((cdn (cdn-thunk)))
      (if (not cdn)
          (log! "  [cdn] ~a host(s) ask for fronting; this box has no CDN~%"
                (length wanting))
          (for-each
           (lambda (w)
             (let ((name (car w)) (ipv4 (cadr w)) (params (caddr w)))
               (unless (assoc name (load-fronted-zones zones-file))
                 (catch #t
                   (lambda ()
                     (let ((zone (cdn-call cdn 'ensure-zone name
                                           (host-origin-url ipv4 params))))
                       (write-fronted-zones!
                        zones-file
                        (cons (cons name zone)
                              (load-fronted-zones zones-file)))
                       (log! "  [cdn] ~a is fronted at ~a~%"
                             name (zone-ref zone 'hostname))))
                   (lambda (key . args)
                     (log! "  [cdn] fronting ~a did not complete (~a); asked again next tick~%"
                           name key))))))
           wanting))))

  (lambda (wanting)
    (let ((todo (remove (lambda (w)
                          (assoc (car w) (load-fronted-zones zones-file)))
                        wanting)))
      (when (and (pair? todo)
                 (with-mutex lock
                   (and (not busy?) (begin (set! busy? #t) #t))))
        (spawn-thread
         (lambda ()
           (dynamic-wind
             (lambda () #t)
             (lambda () (front-all! todo))
             (lambda () (with-mutex lock (set! busy? #f))))))))))
