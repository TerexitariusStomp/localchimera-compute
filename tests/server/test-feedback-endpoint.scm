;;; tests/server/test-feedback-endpoint.scm
;;;
;;; Unit tests for the anonymous feedback pool in server/serve-static.scm:
;;;
;;;   POST /feedback              — append one entry (client JSON verbatim)
;;;   GET  /feedback.json         — admin list (X-Playnet-Admin header)
;;;   POST /feedback/{id}/delete  — admin prune (X-Playnet-Admin header)
;;;
;;; File-driven like the observability endpoints: sandbox the data dir,
;;; drive the handlers directly, assert the JSON shape. No HTTP / no
;;; subprocess.
;;;
;;; Run: guile -L module -L tests tests/server/test-feedback-endpoint.scm

(use-modules (playnet test harness)
             ((playnet utils paths) #:select (ensure-directory!))
             ((server serve-static)
              #:select (handle-feedback-post
                        handle-feedback-list
                        handle-feedback-delete))
             (web request)
             (web response)
             (web uri)
             (rnrs bytevectors)
             (json))

;; Sandbox the data dir (the pool follows PLAYNET_DATA_DIR).
(define %tmp-root
  (let ((p (string-append "/tmp/playnet-feedback-test-"
                          (number->string (getpid)))))
    (ensure-directory! p)
    p))
(setenv "PLAYNET_DATA_DIR" %tmp-root)

(define (call-handler thunk)
  ;; Handlers return (values response body); package the pair as a list.
  (call-with-values thunk list))

(define (status-of pair) (response-code (car pair)))
(define (body-of pair)   (cadr pair))
(define (json-of pair)   (json-string->scm (body-of pair)))

(define (post-request)
  (build-request (string->uri "http://localhost/feedback")
                 #:method 'POST
                 #:headers '((user-agent . "TestUA/1.0"))
                 ;; build-request insists a POST have a port; the handler
                 ;; only ever reads headers, so a void port satisfies it
                 #:port (%make-void-port "w")))

;; The admin gate reads a HEADER, not a query parameter — a query string
;; lands in the access log and can enter a CDN cache key, and the pool is
;; exactly the body that must not be edge-cacheable.
(define* (admin-request #:key (token #f))
  (build-request (string->uri "http://localhost/feedback.json")
                 #:method 'GET
                 #:headers (if token
                               `((x-playnet-admin . ,token))
                               '())))

(define (post! payload)
  (call-handler
   (lambda () (handle-feedback-post (post-request) (string->utf8 payload)))))

;; ── POST /feedback ───────────────────────────────────────────────────

(define %payload "{\"text\":\"the wheel froze\",\"face\":\"frag\",\"vw\":800}")

(define r1 (post! %payload))
(check "post: 200" (status-of r1) 200)
(check "post: ok" (assoc-ref (json-of r1) "ok") #t)
(define id1 (assoc-ref (json-of r1) "id"))
(check "post: returns a non-empty id"
       (and (string? id1) (not (string-null? id1))))

(check "post (empty body): 400" (status-of (post! "")) 400)
(check "post (oversize body): 400"
       (status-of (post! (make-string 262145 #\x))) 400)

;; ── admin gate ───────────────────────────────────────────────────────

(check "list (no token file): 404"
       (status-of (call-handler (lambda () (handle-feedback-list (admin-request #:token "guess")))))
       404)

(call-with-output-file (string-append %tmp-root "/feedback-admin-token")
  (lambda (p) (display "sekrit\n" p)))

(check "list (wrong token): 404"
       (status-of (call-handler (lambda () (handle-feedback-list (admin-request #:token "guess")))))
       404)
(check "list (no header at all): 404"
       (status-of (call-handler (lambda () (handle-feedback-list (admin-request)))))
       404)
;; The gate must not be reachable by naming the token where it would be
;; logged and cached — a query string is not a credential here.
(check "list (token in the query string, not the header): 404"
       (status-of (call-handler
                   (lambda ()
                     (handle-feedback-list
                      (build-request (string->uri "http://localhost/feedback.json?token=sekrit")
                                     #:method 'GET)))))
       404)

;; ── GET /feedback.json ───────────────────────────────────────────────

(define r2 (post! "{\"text\":\"second entry\"}"))
(define id2 (assoc-ref (json-of r2) "id"))
(check "post: distinct ids" (not (equal? id2 id1)))

(let* ((r (call-handler (lambda () (handle-feedback-list (admin-request #:token "sekrit")))))
       (entries (assoc-ref (json-of r) "entries")))
  (check "list: 200" (status-of r) 200)
  (check "list: both entries present" (vector-length entries) 2)
  (let ((e (vector-ref entries 0)))
    (check "list: client JSON stored verbatim"
           (assoc-ref e "json") %payload)
    (check "list: transport user-agent recorded"
           (assoc-ref e "ua") "TestUA/1.0")
    (check "list: arrival time recorded"
           (let ((t (assoc-ref e "t"))) (and (number? t) (> t 0))))))

;; ── POST /feedback/{id}/delete ───────────────────────────────────────

(check "delete (no token): 404"
       (status-of (call-handler
                   (lambda () (handle-feedback-delete id1 (admin-request #:token "guess")))))
       404)

(let ((r (call-handler (lambda () (handle-feedback-delete id1 (admin-request #:token "sekrit"))))))
  (check "delete: 200" (status-of r) 200)
  (check "delete: one entry removed" (assoc-ref (json-of r) "removed") 1))

(let* ((r (call-handler (lambda () (handle-feedback-list (admin-request #:token "sekrit")))))
       (entries (assoc-ref (json-of r) "entries")))
  (check "delete: pool holds the survivor alone" (vector-length entries) 1)
  (check "delete: the survivor is the other entry"
         (assoc-ref (vector-ref entries 0) "id") id2))

(check "delete (unknown id): 404"
       (status-of (call-handler
                   (lambda () (handle-feedback-delete id1 (admin-request #:token "sekrit")))))
       404)

;; ── the pool's ceiling is bytes, and costs nothing to check ──────────
;;
;; The write path is reachable by anyone with no credential at all, on a box
;; with no swap. So the full-pool ceiling must be answerable WITHOUT parsing
;; the pool: a count-the-entries check would read every byte of a gigabyte
;; file into a Guile list on each anonymous POST. Grow the file past the
;; ceiling with bytes alone — nothing here is even valid sexp — and the
;; endpoint must still refuse in O(1) rather than choke trying to read it.

(let ((path (string-append %tmp-root "/feedback-pool.scm")))
  (call-with-output-file path
    (lambda (p) (display (make-string (* 9 1024 1024) #\x) p)))
  (let ((r (post! "{\"text\":\"one more\"}")))
    (check "post (pool over its byte ceiling): 503" (status-of r) 503)
    (check "…and says why" (string? (assoc-ref (json-of r) "hint"))))
  ;; the ceiling is on the POOL, not on reading it: an admin can still get in
  ;; to prune, which is the only way back under the ceiling
  (delete-file path))

(check "post (pool pruned back under the ceiling): 200"
       (status-of (post! "{\"text\":\"after the prune\"}")) 200)

(test-summary!)
