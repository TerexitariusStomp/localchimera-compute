;;; module/playnet/interface/adapters/two-step-publisher.scm — the two-step publish
;;; strategy (Meta Graph): create a media container, then publish it.
;;;
;;; Instagram and Threads share this exact shape — only the paths and the
;;; container params differ. So neither is a bespoke module; both are config rows
;;; (platforms.scm) over this one strategy:
;;;   create-path      — POST here with the container params → a creation_id
;;;   publish-path     — POST creation_id here → the published media id
;;;   container-params — (text → alist | #f); #f ⇒ nothing to publish (e.g. IG with
;;;                      no image), so no HTTP happens and it refuses cleanly.

(define-module (playnet interface adapters two-step-publisher)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet interface adapters bearer-endpoint)
  #:export (^two-step-publisher))

(define (publish-container endpoint create-path publish-path params)
  (let ((c (graph-result ($ endpoint 'post-form create-path params))))
    (if (not (assq-ref c 'ok))
        `((ok . #f) (step . container) (error . ,(assq-ref c 'error)))
        (let ((p (graph-result ($ endpoint 'post-form publish-path
                                 `(("creation_id" . ,(assq-ref c 'id)))))))
          (if (assq-ref p 'ok)
              `((ok . #t) (id . ,(assq-ref p 'id)) (container . ,(assq-ref c 'id)))
              `((ok . #f) (step . publish) (error . ,(assq-ref p 'error))))))))

(define* (^two-step-publisher _bcom endpoint #:key create-path publish-path container-params)
  (methods
    ((post text)
     (let ((params (container-params text)))
       (if (not params)
           `((ok . #f) (error . "no content to publish"))
           (publish-container endpoint create-path publish-path params))))
    ((refresh!) ($ endpoint 'refresh!))))
