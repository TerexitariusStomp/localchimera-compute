;;; tests/fleet/test-cdn.scm — the CDN protocol, through an adapter
;;;
;;; What has to hold, whichever adapter stands behind the protocol:
;;;
;;;   - ensure-zone creates a zone once; asked again, it finds the same one
;;;   - ensure-no-cache adds a rule once per path
;;;   - a refusal from the vendor is an error the caller can catch
;;;   - the adapter is found by name, and a box with no CDN config has none
;;;
;;; Run:  guile -L module tests/fleet/test-cdn.scm

(use-modules (playnet test harness)
             (playnet fleet cdn)
             (playnet fleet cdn-front)
             (playnet fleet records)
             (playnet fleet reconciler)
             (json)
             (srfi srfi-1)
             (srfi srfi-13)
             (ice-9 regex))

;;; ── A vendor that remembers ───────────────────────────────────────────────

(define %zones '())                     ; list of JSON alists
(define %purged '())
(define %calls 0)
(define %refuse? #f)

(define (zone-by-id id)
  (find (lambda (z) (equal? (number->string (assoc-ref z "Id")) id)) %zones))

(define (fake-http method url body)
  (set! %calls (+ %calls 1))
  (let ((path (substring url (string-length "https://api.bunny.net")))
        (json (and body (json-string->scm body))))
    (cond
     (%refuse? (values 401 "{\"Message\":\"no\"}"))
     ((and (eq? method 'GET) (string-prefix? "/pullzone?search=" path))
      (values 200 (scm->json-string (list->vector %zones))))
     ((and (eq? method 'POST) (string=? path "/pullzone"))
      (let ((z `(("Id" . ,(+ 100 (length %zones)))
                 ("Name" . ,(assoc-ref json "Name"))
                 ("OriginUrl" . ,(assoc-ref json "OriginUrl"))
                 ("Hostnames" . #((("Value" . ,(string-append (assoc-ref json "Name")
                                                              ".edge.example")))))
                 ("EdgeRules" . #()))))
        (set! %zones (append %zones (list z)))
        (values 201 (scm->json-string z))))
     ((string-match "^/pullzone/([0-9]+)/purgeCache$" path)
      => (lambda (m) (set! %purged (cons (match:substring m 1) %purged))
                 (values 204 "")))
     ((string-match "^/pullzone/([0-9]+)/edgerules/addOrUpdate$" path)
      => (lambda (m)
           (let* ((z (zone-by-id (match:substring m 1)))
                  (rules (vector->list (assoc-ref z "EdgeRules"))))
             (set! %zones
                   (map (lambda (x)
                          (if (eq? x z)
                              (acons "EdgeRules" (list->vector (append rules (list json)))
                                     (alist-delete "EdgeRules" x))
                              x))
                        %zones))
             (values 204 ""))))
     ((string-match "^/pullzone/([0-9]+)$" path)
      => (lambda (m)
           (let ((z (zone-by-id (match:substring m 1))))
             (cond
              ((not z) (values 404 ""))
              ((eq? method 'GET) (values 200 (scm->json-string z)))
              (else
               (set! %zones
                     (map (lambda (x)
                            (if (eq? x z)
                                (acons "OriginUrl" (assoc-ref json "OriginUrl")
                                       (alist-delete "OriginUrl" x))
                                x))
                          %zones))
               (values 200 "{}"))))))
     (else (values 404 "")))))

(define cdn (make-cdn-by-name "bunny" "test-credential" #:http fake-http))

;;; ── Zones ─────────────────────────────────────────────────────────────────

(define zone (cdn-call cdn 'ensure-zone "playnet-web-1" "https://203.0.113.7"))

(check "ensure-zone answers a zone with an id, an edge hostname and its origin"
       (and (string? (zone-ref zone 'id))
            (equal? "playnet-web-1.edge.example" (zone-ref zone 'hostname))
            (equal? "https://203.0.113.7" (zone-ref zone 'origin))))

(check "asked again, it is the same zone — one was ever made"
       (and (equal? (zone-ref zone 'id)
                    (zone-ref (cdn-call cdn 'ensure-zone "playnet-web-1"
                                        "https://203.0.113.7")
                              'id))
            (= 1 (length %zones))))

(check "a second host gets its own zone"
       (not (equal? (zone-ref zone 'id)
                    (zone-ref (cdn-call cdn 'ensure-zone "playnet-web-2"
                                        "https://203.0.113.8")
                              'id))))

(cdn-call cdn 'set-origin (zone-ref zone 'id) "https://203.0.113.9")
(check "set-origin moves the zone to a new origin"
       (equal? "https://203.0.113.9"
               (zone-ref (cdn-call cdn 'ensure-zone "playnet-web-1" "ignored")
                         'origin)))

;;; ── No-cache rules ────────────────────────────────────────────────────────

(define paths '("/sw.js" "/api/*"))
(define origin "https://example.org")

(check "each path gains a rule the first time"
       (equal? '(("/sw.js" . added) ("/api/*" . added))
               (cdn-call cdn 'ensure-no-cache (zone-ref zone 'id) origin paths)))

(check "and is left alone after that; a new path is added beside them"
       (equal? '(("/sw.js" . exists) ("/api/*" . exists) ("/oobi/*" . added))
               (cdn-call cdn 'ensure-no-cache (zone-ref zone 'id) origin
                         (append paths '("/oobi/*")))))

(check "three rules stand on the zone"
       (= 3 (vector-length (assoc-ref (zone-by-id (zone-ref zone 'id)) "EdgeRules"))))

;;; ── Purge, refusal ────────────────────────────────────────────────────────

(check "purge reaches the zone it names"
       (and (cdn-call cdn 'purge (zone-ref zone 'id))
            (equal? (list (zone-ref zone 'id)) %purged)))

(set! %refuse? #t)
(check-error "a refused purge is an error"
             (lambda () (cdn-call cdn 'purge (zone-ref zone 'id))))
(check-error "a refused ensure-zone is an error"
             (lambda () (cdn-call cdn 'ensure-zone "playnet-web-3" "https://x")))
(set! %refuse? #f)

;;; ── Finding the adapter ───────────────────────────────────────────────────

(check-error "an adapter nobody wrote is an error"
             (lambda () (make-cdn-by-name "no-such-cdn" "k")))
(check-error "the protocol has four operations and no others"
             (lambda () (cdn-call cdn 'delete-everything)))

(check "a box with no CDN config has no CDN"
       (not (load-cdn-config "/nonexistent/cdn.conf")))

(let* ((dir (format #f "/tmp/playnet-test-cdn-~a" (getpid)))
       (key (string-append dir "/key"))
       (conf (string-append dir "/cdn.conf")))
  (mkdir dir)
  (call-with-output-file key (lambda (p) (display "test-credential\n" p)))
  (call-with-output-file conf
    (lambda (p) (write `((adapter . "bunny") (zone . "100")
                         (origin . "https://example.org") (key-file . ,key)) p)))
  (let ((config (load-cdn-config conf)))
    (check "a deployment's config names its zone and origin"
           (and (equal? "100" (cdn-config-ref config 'zone))
                (equal? "https://example.org" (cdn-config-ref config 'origin))))
    (check "and yields a CDN holding the key file's credential"
           (let ((c (cdn-from-config config #:http fake-http)))
             (and c (cdn-call c 'purge "100"))))
    (call-with-output-file key (lambda (p) #t))
    (check "an empty key file yields none"
           (not (cdn-from-config config #:http fake-http))))
  (delete-file key) (delete-file conf) (rmdir dir))

;;; ── A recorded fleet host, behind the CDN ─────────────────────────────────
;;;
;;; The reconciler names the hosts that ask; (playnet fleet cdn-front) makes
;;; each one zone and remembers it. Here the thread runs in place.

(define %zones-file (format #f "/tmp/playnet-test-cdn-zones-~a.scm" (getpid)))
(when (file-exists? %zones-file) (delete-file %zones-file))
(set! %zones '())

(define %cdn-up? #t)
(define %front-log '())

(define fronting
  (make-host-fronting %zones-file
                      #:cdn-thunk (lambda () (and %cdn-up? cdn))
                      #:log! (lambda (fmt . args)
                               (set! %front-log (cons fmt %front-log)))
                      #:spawn-thread (lambda (thunk) (thunk))))

(define (host name . params)
  (desired-host #:name name #:flavor "f" #:provider "p"
                #:provider-params params))
(define (recorded name ipv4)
  (materialized-host #:name name #:machine-id (string-append "m-" name)
                     #:ipv4 ipv4 #:provider "p" #:flavor "f" #:created-at 0))

(define desired
  (list (host "web-1" '("cdn-front" . #t))
        (host "db-1")
        (host "web-2" '("cdn-front" . #t) '("cdn-origin" . "https://web-2.example"))
        (host "web-3" '("cdn-front" . #t))))
(define materialized
  (list (recorded "web-1" "203.0.113.11")
        (recorded "db-1"  "203.0.113.12")
        (recorded "web-2" "203.0.113.13")))   ; web-3 is still being provisioned

(define front! (@@ (playnet fleet reconciler) front-recorded-hosts!))

(set-host-fronting! fronting)
(front! desired materialized)

(let ((fronted (load-fronted-zones %zones-file)))
  (check "the hosts that ask, and are recorded, are fronted — and no others"
         (lset= equal? '("web-1" "web-2") (map car fronted)))
  (check "a host's zone pulls from its address"
         (equal? "https://203.0.113.11"
                 (zone-ref (assoc-ref fronted "web-1") 'origin)))
  (check "or from the origin it names"
         (equal? "https://web-2.example"
                 (zone-ref (assoc-ref fronted "web-2") 'origin))))

(let ((calls %calls))
  (front! desired materialized)
  (front! desired materialized)
  (check "later ticks find them on record and ask the vendor nothing"
         (and (= calls %calls) (= 2 (length %zones)))))

;; The CDN is down when web-3 is recorded; then it is back.
(set! %refuse? #t)
(let ((more (append materialized (list (recorded "web-3" "203.0.113.14")))))
  (front! desired more)
  (check "a vendor refusal leaves the host unfronted, and nothing is raised"
         (not (assoc "web-3" (load-fronted-zones %zones-file))))
  (set! %refuse? #f)
  (front! desired more)
  (check "the next tick fronts it"
         (and (assoc "web-3" (load-fronted-zones %zones-file)) #t))
  (set! %cdn-up? #f)
  (delete-file %zones-file)
  (front! desired more)
  (check "on a box with no CDN, asking is a log line and nothing else"
         (and (not (file-exists? %zones-file)) (pair? %front-log))))

(set-host-fronting! #f)
(front! desired materialized)
(check "with no fronting procedure set, the reconciler fronts nothing"
       (not (file-exists? %zones-file)))

(test-summary!)
