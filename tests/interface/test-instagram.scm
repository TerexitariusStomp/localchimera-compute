;;; test-instagram.scm — the RENTED-channel adapter: Instagram's two-step publish.
;;;
;;; A thin wrapper over the generic ^bearer-endpoint. Proves the Meta Graph
;;; two-step flow (create media container → publish it), that Instagram refuses a
;;; text-only post (it needs an image), and that the same fail-closed gate
;;; protects it. Runs against a mock Graph API — nothing reaches Meta.
;;;
;;; Run: guile -L module tests/interface/test-instagram.scm

(use-modules (playnet test harness)
             (playnet interface adapters platforms)
             (playnet interface adapters comms-publish)
             (goblins) (goblins vat)
             (web server) (web response) (web request) (web uri)
             (json) (rnrs bytevectors) (ice-9 format))

;; mock Meta Graph: /{ig}/media → a container id; /{ig}/media_publish → a media id
(define %steps '())
(define (handle-request request body)
  (let ((path (uri-path (request-uri request))))
    (set! %steps (cons path %steps))
    (values (build-response #:code 200)
            (cond ((string-suffix? "/media" path)         (scm->json-string '(("id" . "container-1"))))
                  ((string-suffix? "/media_publish" path) (scm->json-string '(("id" . "media-99"))))
                  (else "{}")))))

(define-values (%port %thread) (spawn-mock-server handle-request))
(define %base (format #f "http://127.0.0.1:~a" %port))
(define %ig "17841400000000000")
(define vat (spawn-vat))

(display "\n── Instagram's two-step publish (container → publish) ──\n")
(with-vat vat
  (let ((ig (spawn-instagram %base %ig "system-user-token"          ; the headless identity
                             #:image-url-for (lambda (_text) "https://cdn.example/card.jpg"))))
    (let ((r ($ ig 'post "Short 12 kg for Saturday's share! [cite:intent-food]")))
      (check "the two-step publish reports ok" (assq-ref r 'ok) #t)
      (check "it returns the created media id" (assq-ref r 'id) "media-99")
      (check "it carried the container id from step 1" (assq-ref r 'container) "container-1"))
    (check "step 1 hit /media, then step 2 hit /media_publish"
           (reverse %steps)
           (list (string-append "/" %ig "/media") (string-append "/" %ig "/media_publish")))))

(display "\n── Instagram has no text posts: it refuses without an image ──\n")
(set! %steps '())
(with-vat vat
  (let ((ig (spawn-instagram %base %ig "system-user-token")))   ; no image-url-for seam
    (check "with no image seam, instagram refuses (needs media)"
           (assq-ref ($ ig 'post "text only") 'ok) #f)
    (check "and it never contacted the Graph API" %steps '())))

(display "\n── the fail-closed gate protects the rented channel too ──\n")
(set! %steps '())
(with-vat vat
  (let ((ig (spawn-instagram %base %ig "system-user-token"
                             #:image-url-for (lambda (_t) "https://cdn.example/card.jpg"))))
    (check "an unapproved post is HELD (fail-closed)"
           (assq-ref (publish-with-gate ig "unapproved") 'held) #t)
    (check "Meta was never contacted" %steps '())))

(display "\n")
(test-summary!)
