;;; test-push-adapter.scm — whose device a Web Push reaches.
;;;
;;; The transport itself (encryption, the VAPID token) is test-push-crypto's.
;;; This holds the three decisions around it, as pure functions:
;;;   • parse-subscription — the browser's JSON is kept parsed, and what is
;;;     no subscription is refused (the sender reads endpoint and keys off it);
;;;   • subscriptions-for — a delivery addressed to a device reaches that
;;;     device, and an unaddressed one reaches all;
;;;   • deliver-to! — a subscription the push service reports gone is removed
;;;     under the id of the device it belonged to.
;;;
;;; Run: guile -L module tests/push/test-push-adapter.scm

(use-modules (playnet test harness)
             (playnet push subscriptions))

(define (sub-json endpoint)
  (string-append "{\"endpoint\":\"" endpoint "\",\"expirationTime\":null,"
                 "\"keys\":{\"p256dh\":\"BPk\",\"auth\":\"abc\"}}"))

(display "\n── parse-subscription ──\n")
(let ((sub (parse-subscription (sub-json "https://push.example/a"))))
  (check "a subscription parses to an alist" (pair? sub) #t)
  (check "…whose endpoint reads back" (assoc-ref sub "endpoint") "https://push.example/a")
  (check "…and whose keys read back" (assoc-ref (assoc-ref sub "keys") "auth") "abc"))
(check "text that is not JSON is refused" (parse-subscription "not json") #f)
(check "JSON with no endpoint is refused"
       (parse-subscription "{\"keys\":{\"p256dh\":\"x\",\"auth\":\"y\"}}") #f)
(check "JSON with no keys is refused"
       (parse-subscription "{\"endpoint\":\"https://push.example/a\"}") #f)
(check "a key missing is refused"
       (parse-subscription "{\"endpoint\":\"https://e/\",\"keys\":{\"p256dh\":\"x\"}}") #f)
(check "a non-string is refused" (parse-subscription 42) #f)

(display "\n── subscriptions-for ──\n")
(define entries
  (list (cons "dev-a" (parse-subscription (sub-json "https://push.example/a")))
        (cons "dev-b" (parse-subscription (sub-json "https://push.example/b")))))
(check "addressed to a device, it reaches that device"
       (map car (subscriptions-for entries "dev-b")) '("dev-b"))
(check "addressed to an unknown device, it reaches none"
       (subscriptions-for entries "dev-z") '())
(check "unaddressed, it reaches every device"
       (map car (subscriptions-for entries #f)) '("dev-a" "dev-b"))

(display "\n── deliver-to! ──\n")
(let ((sent '()) (gone '()))
  (deliver-to! (lambda (sub payload urgency)
                 (set! sent (cons (list (assoc-ref sub "endpoint") payload urgency) sent))
                 (if (string=? (assoc-ref sub "endpoint") "https://push.example/a") 'gone 'ok))
               entries "payload" "high"
               (lambda (device-id) (set! gone (cons device-id gone))))
  (check "every entry is sent the payload and the urgency"
         (reverse sent)
         '(("https://push.example/a" "payload" "high") ("https://push.example/b" "payload" "high")))
  (check "the expired one is removed by its device id" gone '("dev-a")))

(test-summary!)
