;;; module/playnet/utils/log.scm — shared structured logging
;;;
;;; Replaces the per-module (define (log! fmt . args) ...) pattern
;;; with a single factory. Every module gets consistent formatting:
;;; [prefix] message\n on stderr, with force-output.
;;;
;;; Usage:
;;;   (use-modules (playnet utils log))
;;;   (define log! (make-logger "keri"))
;;;   (log! "connected to ~a" url)
;;;   ;; → [keri] connected to http://localhost:3901

(define-module (playnet utils log)
  #:use-module (ice-9 format)
  #:export (make-logger))

(define* (make-logger prefix #:key (port (current-error-port)))
  "Returns a logging procedure that prefixes messages with [PREFIX].
Writes to PORT (default: stderr) and flushes after each line."
  (lambda (fmt . args)
    (apply format port
           (string-append "[" prefix "] " fmt "\n") args)
    (force-output port)))
