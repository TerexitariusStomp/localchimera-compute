;;; tests/server/test-report-endpoint.scm
;;;
;;; Reports (POST /report, GET /report.json, POST /report/{id}/delete) are a
;;; pool of their own beside feedback: own file, own admin token, own body cap,
;;; no User-Agent kept. The point of the test is the SEPARATION — a report is
;;; never in the feedback pool, and the feedback token opens nothing here.
;;;
;;; Run: guile -L module -L tests tests/server/test-report-endpoint.scm

(use-modules (playnet test harness)
             ((playnet governance paths) #:select (ensure-directory!))
             ((server serve-static)
              #:select (handle-report-post handle-report-list handle-report-delete
                        handle-feedback-post handle-feedback-list))
             (web request)
             (web response)
             (web uri)
             (rnrs bytevectors)
             (json))

(define %tmp-root
  (let ((p (string-append "/tmp/playnet-report-test-" (number->string (getpid)))))
    (ensure-directory! p)
    p))
(setenv "PLAYNET_DATA_DIR" %tmp-root)

(define (call-handler thunk) (call-with-values thunk list))
(define (status-of pair) (response-code (car pair)))
(define (json-of pair) (json-string->scm (cadr pair)))

(define (post-request path)
  (build-request (string->uri (string-append "http://localhost" path))
                 #:method 'POST
                 #:headers '((user-agent . "TestUA/1.0"))
                 #:port (%make-void-port "w")))
(define* (admin-request path #:key (token #f))
  (build-request (string->uri (string-append "http://localhost" path))
                 #:method 'GET
                 #:headers (if token `((x-playnet-admin . ,token)) '())))

(define (report! payload)
  (call-handler (lambda () (handle-report-post (post-request "/report") (string->utf8 payload)))))

(define %payload "{\"v\":1,\"kind\":\"report\",\"category\":\"child\",\"text\":\"a report\"}")

(define r1 (report! %payload))
(check "report: 200" (status-of r1) 200)
(define id1 (assoc-ref (json-of r1) "id"))
(check "report: id is its own kind (rp-…)" (and (string? id1) (string-prefix? "rp-" id1)))
(check "report (empty body): 400" (status-of (report! "")) 400)
(check "report (over its 16 KB cap): 400" (status-of (report! (make-string 16385 #\x))) 400)

;; the admin gate: no token file, wrong token, then the right one
(check "list (no token file): 404"
       (status-of (call-handler (lambda () (handle-report-list (admin-request "/report.json" #:token "x"))))) 404)
(call-with-output-file (string-append %tmp-root "/report-admin-token")
  (lambda (p) (display "rsekrit\n" p)))
(check "list (wrong token): 404"
       (status-of (call-handler (lambda () (handle-report-list (admin-request "/report.json" #:token "guess"))))) 404)

(let* ((r (call-handler (lambda () (handle-report-list (admin-request "/report.json" #:token "rsekrit")))))
       (entries (assoc-ref (json-of r) "entries")))
  (check "list: 200" (status-of r) 200)
  (check "list: the report is there" (vector-length entries) 1)
  (check "list: body stored verbatim" (assoc-ref (vector-ref entries 0) "json") %payload)
  (check "list: no User-Agent kept for a report" (assoc-ref (vector-ref entries 0) "ua") ""))

;; the separation: the report is in no feedback pool, and the feedback token
;; (once it exists) does not open the report list
(call-with-output-file (string-append %tmp-root "/feedback-admin-token")
  (lambda (p) (display "fsekrit\n" p)))
(let* ((r (call-handler (lambda () (handle-feedback-list (admin-request "/feedback.json" #:token "fsekrit")))))
       (entries (assoc-ref (json-of r) "entries")))
  (check "feedback pool does not hold the report" (vector-length entries) 0))
(check "the feedback token does not open the report list"
       (status-of (call-handler (lambda () (handle-report-list (admin-request "/report.json" #:token "fsekrit"))))) 404)
(check "a feedback post does not land in the report pool"
       (begin
         (call-handler (lambda () (handle-feedback-post (post-request "/feedback") (string->utf8 "{\"text\":\"fb\"}"))))
         (let* ((r (call-handler (lambda () (handle-report-list (admin-request "/report.json" #:token "rsekrit")))))
                (n (vector-length (assoc-ref (json-of r) "entries"))))
           n))
       1)

;; delete, with the report token only
(check "delete (feedback token): 404"
       (status-of (call-handler (lambda () (handle-report-delete id1 (admin-request "/report/x/delete" #:token "fsekrit"))))) 404)
(let ((r (call-handler (lambda () (handle-report-delete id1 (admin-request "/report/x/delete" #:token "rsekrit"))))))
  (check "delete: 200, one removed" (assoc-ref (json-of r) "removed") 1))

(test-summary!)
