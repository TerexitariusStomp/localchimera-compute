;;; module/playnet/push/adapter.scm — Web Push transport adapter
;;;
;;; Implements the ^output-sink transport interface for delivering
;;; notifications via Web Push (RFC 8030 + RFC 8291 + RFC 8292).

(define-module (playnet push adapter)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet push crypto)
  #:use-module (playnet push subscriptions)
  ;; the store itself is crypto-free and lives in (playnet push store);
  ;; re-exported here so the gateway's one import of push stands
  #:use-module (playnet push store)
  #:use-module (playnet notify rendered)
  #:use-module (playnet keri cesr)
  #:use-module (rnrs bytevectors)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (json)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (^push-adapter)
  #:re-export (^push-subscription-store))


;;; ── Push delivery ──────────────────────────────────────────────────────

(define (push-to-subscription! vapid-key sub payload-bv urgency)
  (let* ((endpoint (assoc-ref sub "endpoint"))
         (keys     (assoc-ref sub "keys"))
         (p256dh   (and keys (b64url-decode (assoc-ref keys "p256dh"))))
         (auth     (and keys (b64url-decode (assoc-ref keys "auth")))))
    (unless (and endpoint p256dh auth)
      (error "push-to-subscription!: malformed subscription"))
    (let* ((body (call-with-values
                   (lambda () (web-push-encrypt payload-bv p256dh auth))
                   (lambda (b _) b)))
           (u (string->uri endpoint))
           (audience (format #f "~a://~a" (uri-scheme u) (uri-host u)))
           (auth-hdr (vapid-sign-jwt vapid-key audience (* 24 3600))))
      (catch #t
        (lambda ()
          (let ((code (response-code
                       (http-post endpoint
                                  #:body body
                                  #:headers
                                  `((content-type . (application/octet-stream))
                                    (content-encoding . "aes128gcm")
                                    (ttl . ,(if (string=? urgency "high") "86400" "3600"))
                                    (urgency . ,urgency)
                                    (authorization . ,auth-hdr))
                                  #:decode-body? #f))))
            (cond
             ((and (>= code 200) (< code 300)) 'ok)
             ((= code 410) 'gone)
             ((= code 429) 'rate-limited)
             (else (format (current-error-port)
                           "[push] ~a → ~a~%" endpoint code)
                   'error))))
        (lambda (key . args)
          (format (current-error-port)
                  "[push] ~a errored: ~a ~a~%" endpoint key args)
          'error)))))

(define (push-to! vapid-key store ctx payload urgency)
  (deliver-to! (lambda (sub payload urgency)
                 (push-to-subscription! vapid-key sub payload urgency))
               (subscriptions-for ($ store 'entries) ctx)
               payload urgency
               (lambda (device-id) (<-np store 'unregister device-id))))


;;; ── ^push-adapter ──────────────────────────────────────────────────────

(define (notification->push-payload title body)
  (string->utf8
   (scm->json-string
    `(("web_push" . 8030)
      ("notification"
       . (("title" . ,title)
          ("body" . ,body)
          ("icon" . "/assets/icons/icon-192.png")))))))

(define (text->push-payload text)
  (notification->push-payload "playnet" text))

(define (urgency-for type)
  "Web Push urgency from notification severity."
  (if (eq? type 'alert) "high" "normal"))

;; A DUMB transport: it puts a pre-rendered notification (or a bare
;; string) into a Web Push message. Rendering happens upstream in the
;; sink formatter; here we only pick title/body/urgency and encrypt.
;; CTX is the device the router addressed (the id its `push` channel was
;; bound under), or #f for every device.
(define (push-payload! vapid-key store ctx x)
  (if (string? x)
      (push-to! vapid-key store ctx (text->push-payload x) "normal")
      (push-to! vapid-key store ctx
                (notification->push-payload
                 (or (rendered-title x) "playnet")
                 (or (rendered-body x) ""))
                (urgency-for (rendered-type x)))))

(define (^push-adapter _bcom vapid-key subscription-store)
  (methods
   ((deliver ctx rendered)
    (push-payload! vapid-key subscription-store ctx rendered))
   ((send-message ctx x)
    (push-payload! vapid-key subscription-store ctx x))
   ((send-formatted ctx blocks)
    (push-to! vapid-key subscription-store ctx
              (text->push-payload
               (string-join (map (lambda (b)
                                   (if (string? b) b (format #f "~a" b)))
                                 blocks) "\n"))
              "normal"))
   ((parse-command raw-text) (values #f #f))))
