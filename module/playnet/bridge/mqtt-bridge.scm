;;; mqtt-bridge.scm — MQTT bridge using Goblins ^io for client lifecycle
;;;
;;; The mosquitto client is wrapped in ^io (goblins actor-lib io), which
;;; handles single-threaded, non-blocking access and init/cleanup lifecycle.
;;; The bridge actor sits on top, managing topic→observer dispatch and
;;; providing capability-gated publish.
;;;
;;; Intentionally non-persistent — the mosquitto client is an IO handle.
;;; On restart, create a new bridge via make-mqtt-bridge.
;;;
;;; Assumes codec.scm is loaded.

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib io)
             ((mosquitto client) #:prefix mqtt:)
             (srfi srfi-1))


;; =========================================================================
;; Constructor — creates ^io + ^mqtt-bridge in one step
;; =========================================================================

(define* (make-mqtt-bridge scope-id host #:key (port 1883) (client-id #f))
  "Create a connected MQTT bridge.  Returns the bridge actor ref.
   Must be called from within a vat context (with-vat)."
  (let* ((cid (or client-id (string-append "vf-" scope-id)))
         (client (mqtt:make-client #:id cid))
         (io (spawn ^io client
                    #:init (lambda (c) (mqtt:connect c host #:port port))
                    #:cleanup (lambda (c) (mqtt:disconnect c)))))
    (spawn ^mqtt-bridge io scope-id '())))


;; =========================================================================
;; ^mqtt-bridge — thin observer registry on top of ^io
;; =========================================================================

(define (^mqtt-bridge bcom io scope-id observers)
  (methods

    ((add-observer pattern observer-ref)
     ($ io (lambda (c) (mqtt:subscribe c pattern)))
     (bcom (^mqtt-bridge bcom io scope-id
                          (cons (cons pattern observer-ref) observers))))

    ((remove-observer pattern)
     ($ io (lambda (c) (mqtt:unsubscribe c pattern)))
     (bcom (^mqtt-bridge bcom io scope-id
                          (filter (lambda (p) (not (string=? (car p) pattern)))
                                  observers))))

    ((publish topic payload-string)
     ;; The ONLY path to MQTT publish — capability discipline.
     ($ io (lambda (c) (mqtt:publish c topic payload-string))))

    ((poll . rest)
     ;; Run the mosquitto network loop once.  timeout in ms (default 100).
     ($ io (lambda (c) (mqtt:loop c #:timeout
                                  (if (pair? rest) (car rest) 100)))))

    ((dispatch-message topic payload-string)
     ;; Dispatch a message to matching topic-observers.
     (map (lambda (obs-ref)
            ($ obs-ref 'receive-message topic payload-string))
          (find-matching-observers topic observers)))

    ((halt)
     ;; Disconnect and stop the IO fiber.
     ($ io 'halt))

    ((get-observers) observers)))


;; =========================================================================
;; Topic matching — exact match and MQTT # wildcard
;; =========================================================================

(define (topic-matches? pattern topic)
  (cond
    ((string=? pattern topic) #t)
    ((string=? pattern "#") #t)
    ((string-suffix? "/#" pattern)
     (let ((prefix (substring pattern 0 (- (string-length pattern) 2))))
       (or (string=? prefix topic)
           (string-prefix? (string-append prefix "/") topic))))
    (else #f)))

(define (find-matching-observers topic observers)
  (filter-map (lambda (pair)
                (and (topic-matches? (car pair) topic)
                     (cdr pair)))
              observers))
