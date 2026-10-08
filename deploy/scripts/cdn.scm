;;; deploy/scripts/cdn.scm — this deployment's CDN, from the command line
;;;
;;;   guile -L module deploy/scripts/cdn.scm purge
;;;   guile -L module deploy/scripts/cdn.scm rules
;;;   guile -L module deploy/scripts/cdn.scm ensure NAME ORIGIN-URL
;;;
;;; Which CDN, which zone and which origin come from /etc/playnet/cdn.conf
;;; (os.scm writes it from the provider config's `cdn` entry); the key comes
;;; from the file that config names. A box with no CDN config has nothing to
;;; do, and says so with exit 0 — the deploy hook calls `purge` on every box.
;;;
;;; On a Tor-only box run it under torsocks:
;;;   sudo -u playnet torsocks guile -L module deploy/scripts/cdn.scm rules
;;;
;;; `purge`  — after a deploy puts new browser assets on the origin, the edge
;;;            drops its copies. The heavy assets (wasm, app/*) are cached
;;;            for days; without the purge a returning visitor never reaches
;;;            the new sw.js that would re-install them.
;;; `rules`  — the paths below bypass the edge cache, then one purge so the
;;;            newly uncached paths clear at once. Idempotent.
;;; `ensure` — a zone named NAME pulling from ORIGIN-URL exists; prints it.

(use-modules (playnet fleet cdn)
             (ice-9 format)
             (ice-9 match)
             (srfi srfi-1))

;; Paths a cached copy of which breaks correctness.
(define (satellite-rids-bare)
  "The bare RIDs deploy/satellites.scm names, beside this script's checkout."
  (let* ((file (string-append (dirname (dirname (canonicalize-path (car (command-line)))))
                              "/satellites.scm"))
         (pins (and (file-exists? file)
                    (call-with-input-file file
                      (lambda (p)
                        (let loop ((form (read p)) (last #f))
                          (if (eof-object? form) (eval last (current-module))
                              (loop (read p) form))))))))
    (filter-map (lambda (pin)
                  (let ((rid (assq-ref pin 'rid)))
                    (and rid (if (string-prefix? "rad:" rid) (substring rid 4) rid))))
                (or pins '()))))

(define (no-cache-paths)
  `(
   ;; The service-worker ratchet's trigger points. CI stamps a content
   ;; fingerprint into sw.js's CACHE each deploy; a new sw.js takes over and
   ;; the page reloads onto the fresh build. That fires only when sw.js is
   ;; fetched fresh. app.html is the shell that registers it; both are tiny.
   "/sw.js"
   "/app.html"
   "/api/*"                    ; Radicle HTTP API — the Explorer/board head
   "/entry-points.json"        ; OCapN gateway sref (changes on gateway restart)
   "/oobi/*"                   ; KERI OOBI resolution
   "/.well-known/keri/*"       ; KERI witness/endpoint discovery
   "/.well-known/did/*"        ; did:keri resolution
   "/universal-commune.json"   ; live governance doc
   "/playnet-identity.json"    ; live identity doc
   "/feedback"                 ; anonymous feedback POST
   ;; The pool itself: a token-gated GET whose body is every visitor's
   ;; feedback. The token rides a header, and headers are outside the cache
   ;; key, so an edge copy would answer callers carrying no token. no-cache
   ;; keeps the gate on the origin, where the check lives.
   "/feedback.json"
   "/feedback/*"               ; per-entry admin prune
   ;; The git mirror: a cached info/refs hands `guix pull` a stale ref
   ;; after every push, and a request that reached the edge before the route
   ;; existed leaves the site's HTML cached under that URL for a month. Every
   ;; RID the box mirrors — the core and each satellite — is kept out.
   ,(string-append "/" (or (getenv "PLAYNET_RID_BARE")
                           "z27dFkN28LQAsSsG3DVHcfBqYAArQ")
                   ".git/*")
   ;; and one entry per satellite (deploy/satellites.scm)
   ,@(map (lambda (rid) (string-append "/" rid ".git/*"))
          (satellite-rids-bare))))

(define (say fmt . args)
  (apply format #t (string-append "[cdn] " fmt "~%") args)
  (force-output))

(define (main args)
  (let* ((config (load-cdn-config))
         (cdn (and config (cdn-from-config config))))
    (cond
     ((not config)
      (say "no CDN configured on this box — nothing to do"))
     ((not cdn)
      (say "no key at ~a — nothing to do" (cdn-config-ref config 'key-file)))
     (else
      (let ((zone (cdn-config-ref config 'zone))
            (origin (cdn-config-ref config 'origin)))
        (match args
          (("purge")
           (cdn-call cdn 'purge zone)
           (say "purge OK"))
          (("rules")
           (for-each (match-lambda
                       ((path . status) (say "~a: ~a" status path)))
                     (cdn-call cdn 'ensure-no-cache zone origin (no-cache-paths)))
           (cdn-call cdn 'purge zone)
           (say "purge OK"))
          (("ensure" name origin-url)
           (let ((z (cdn-call cdn 'ensure-zone name origin-url)))
             (say "zone ~a → ~a (origin ~a)"
                  (zone-ref z 'id) (zone-ref z 'hostname) (zone-ref z 'origin))))
          (_
           (say "usage: cdn.scm purge | rules | ensure NAME ORIGIN-URL")
           (exit 2))))))))

(catch #t
  (lambda () (main (cdr (command-line))))
  (lambda (key . args)
    (say "failed: ~a ~s" key args)
    (exit 1)))
