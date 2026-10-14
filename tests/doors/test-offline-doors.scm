;;; test-offline-doors.scm — a door declared `#:offline` has a handler on the device, of its own arity.
;;;
;;; The doors the page answers with no gateway in reach are declared where every door
;;; is (doors/protocol.scm `#:offline`) and the page's table of them is generated from
;;; that (ui/app/offline-doors.ts). The device's own doors (doors/page-scope.scm) are the
;;; other half. Properties:
;;;
;;;   ANSWERED   every seam handler whose door is declared offline is a door the device
;;;              answers, so a declared door cannot be queued or read from a copy that
;;;              has no handler for it
;;;   ARITY      the device takes as many arguments as the handler sends, so what the
;;;              page asks is what the device reads
;;;   STAMPED    an act that states no instant is stamped with the one its door names, and
;;;              that argument is one the handler carries
;;;
;;; Run: guile --no-auto-compile -q -L module -L . -L tests tests/doors/test-offline-doors.scm

(use-modules (playnet test harness)
             (playnet doors protocol) (playnet doors page-scope)
             ((playnet protocol seam) #:select (handler-ref handler-arity handler-param-name))
             (srfi srfi-1))

(define device (page-doors))                         ; ((name . arity) …)

(display "\n── ANSWERED + ARITY: every offline door has a device handler of its arity ──\n")
(for-each
 (lambda (h)
   (let ((name (car h)))
     (check (string-append name " is a door the device answers") (and (assoc name device) #t) #t)
     (when (assoc name device)
       (check (string-append name " takes the arguments the page sends")
              (cdr (assoc name device)) (handler-arity (handler-ref name))))))
 (offline-handlers))

(display "\n── STAMPED: the instant an act is stamped with is an argument its handler carries ──\n")
(let ((stamped (filter caddr (offline-handlers))))
  (check "the acts that stamp an instant are the count and the observation"
         (map car stamped) '("countStock" "logObserve"))
  (for-each
   (lambda (h)
     (check (string-append (car h) " stamps an instant-named argument")
            (and (member (handler-param-name (handler-ref (car h)) (caddr h)) '("whenIso" "when")) #t) #t))
   stamped))

(test-summary!)
