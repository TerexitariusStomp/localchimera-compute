;;; module/playnet/interface/adapters/simple-publisher.scm — the single-step
;;; publish strategy, config-driven. A new single-call bearer platform is a CONFIG
;;; ROW (platforms.scm), not a module.
;;;
;;; Most platforms publish in one call: POST the text to an endpoint, read back the
;;; created id. This actor captures that over a ^bearer-endpoint, parameterised by:
;;;   path     — the endpoint path
;;;   field    — the flat body field the text goes in (default "status")
;;;   body-fn  — OR a (text → alist) builder, for platforms whose body is NESTED
;;;              (e.g. Bluesky's {repo, collection, record:{text, createdAt}})
;;;   format   — 'json (default) | 'form
;;;   id-path  — where the created id lives in the response (Mastodon "id",
;;;              X ("data" "id"), Bluesky ("uri"))
;;; Instagram / Threads are the exception (two-step) — see two-step-publisher.scm.

(define-module (playnet interface adapters simple-publisher)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet interface adapters bearer-endpoint)
  #:export (^simple-publisher))

(define* (^simple-publisher _bcom endpoint
                            #:key path (field "status") (body-fn #f)
                                  (format 'json) (id-path '("id")))
  (define (body text) (if body-fn (body-fn text) (list (cons field text))))
  (methods
    ((post text)
     (graph-result
      (case format
        ((form) ($ endpoint 'post-form path (body text)))
        (else   ($ endpoint 'post-json path (body text))))
      #:id-path id-path))
    ((refresh!) ($ endpoint 'refresh!))))
