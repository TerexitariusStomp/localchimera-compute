;;; module/playnet/interface/adapters/platforms.scm — every platform as a config row.
;;;
;;; The whole point of the generic substrate (bearer-endpoint + simple-publisher +
;;; two-step-publisher): a social platform is a CONFIG ROW, not a module. Each
;;; spawn-* returns a publisher answering (post text) / (refresh!), so all of them
;;; drop straight into comms-publish (the fail-closed gate) and comms-run. Run each
;;; inside a vat. Tokens are sealed inside the endpoint; the GRANT (mint/authorise
;;; the token) is the one human/governance step — everything here is headless.
;;;
;;; Sovereign (scope is primary-accountable): mastodon, self-hosted bluesky PDS.
;;; Rented   (platform is primary-accountable): x, instagram, threads.

(define-module (playnet interface adapters platforms)
  #:use-module (goblins)
  #:use-module ((playnet utils clock) #:select (iso-now))   ; the one clock: instants inside, civil at the boundary
  #:use-module (playnet interface adapters bearer-endpoint)
  #:use-module (playnet interface adapters simple-publisher)
  #:use-module (playnet interface adapters two-step-publisher)
  #:export (spawn-mastodon
            spawn-x
            spawn-bluesky
            spawn-instagram
            spawn-threads))

;; ── SOVEREIGN: Mastodon — single call, POST /api/v1/statuses {status} ────────
(define (spawn-mastodon instance-url access-token)
  (spawn ^simple-publisher (spawn ^bearer-endpoint instance-url access-token)
         #:path "/api/v1/statuses" #:field "status"))

;; ── RENTED: X (Twitter) v2 — single call, POST /2/tweets {text}; id at .data.id
(define* (spawn-x bearer-token #:key (base "https://api.twitter.com/2"))
  (spawn ^simple-publisher (spawn ^bearer-endpoint base bearer-token)
         #:path "/tweets" #:field "text" #:id-path '("data" "id")))

;; ── Bluesky (AT Protocol) — single call, but a NESTED record; id = .uri ──────
;; access-jwt + did come from com.atproto.server.createSession (the grant).
;; A self-hosted PDS makes this a SOVEREIGN channel; bsky.social a rented one.
(define %post-type "app.bsky.feed.post")
(define* (spawn-bluesky pds-base access-jwt did)
  (spawn ^simple-publisher (spawn ^bearer-endpoint pds-base access-jwt)
         #:path "/xrpc/com.atproto.repo.createRecord"
         #:id-path '("uri")
         #:body-fn (lambda (text)
                     `(("repo" . ,did) ("collection" . ,%post-type)
                       ("record" . (("$type" . ,%post-type) ("text" . ,text)
                                    ("createdAt" . ,(iso-now))))))))

;; ── RENTED: Instagram — TWO-STEP, and it needs an IMAGE (no text posts) ──────
;; image-url-for : (text → public clearnet JPEG URL); #f ⇒ refuse (needs media).
(define* (spawn-instagram graph-base ig-user-id access-token #:key (image-url-for #f))
  (spawn ^two-step-publisher (spawn ^bearer-endpoint graph-base access-token)
         #:create-path  (string-append "/" ig-user-id "/media")
         #:publish-path (string-append "/" ig-user-id "/media_publish")
         #:container-params
         (lambda (text)
           (let ((img (and image-url-for (image-url-for text))))
             (and img `(("image_url" . ,img) ("caption" . ,text)))))))

;; ── RENTED: Threads — TWO-STEP like Instagram, but text is allowed ───────────
(define (spawn-threads graph-base threads-user-id access-token)
  (spawn ^two-step-publisher (spawn ^bearer-endpoint graph-base access-token)
         #:create-path  (string-append "/" threads-user-id "/threads")
         #:publish-path (string-append "/" threads-user-id "/threads_publish")
         #:container-params (lambda (text) `(("media_type" . "TEXT") ("text" . ,text)))))
