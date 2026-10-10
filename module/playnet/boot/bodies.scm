;;; module/playnet/boot/bodies.scm — legal bodies: the body service beside the stores, the ceremony desk beside the oobi-host.

(define-module (playnet boot bodies)
  #:use-module ((playnet boot site) #:select (log!))
  #:use-module ((playnet doors bodies) #:select (^body-service))
  #:use-module ((playnet doors body) #:select (current-body-service))
  #:use-module ((playnet personhood body-desk) #:select (^body-ceremony-desk))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (spawn-bodies!))

;; Legal bodies (docs/legal/bodies.md): the body service stands in the
;; planner's vat beside the stores it folds over, reaching each scope's
;; root through the planner service; the ceremony desk stands beside the
;; oobi-host, where a body's k-of-n inception reads and writes key logs.
;; A ceremony that publishes closes the body through the service, and
;; every session's body doors send to the service through the cell.
(define (spawn-bodies! planner-vat gateway-vat planner-service oobi-host)
  (define body-service
    (with-vat planner-vat
      (spawn ^body-service
             (lambda (sid) ($ planner-service 'scope-root-ref sid))
             (lambda () (map (lambda (r) (assq-ref r 'id)) ($ planner-service 'scope-list))))))
  (define body-desk
    (with-vat gateway-vat
      (spawn ^body-ceremony-desk oobi-host
             (lambda (scope-id provisional-id aid)
               (<-np body-service 'close! scope-id provisional-id aid)))))
  (with-vat planner-vat ($ body-service 'set-desk! body-desk))
  (current-body-service (lambda (op . args) (apply <- body-service op args)))
  (log! "  [gateway] legal bodies: service up, ceremonies at the oobi-host~%"))
