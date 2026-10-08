(define-module (scripts serve)
  #:use-module (web server)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1))

(define %work-dir (or (getenv "WORK_DIR") "browser"))
(define %port (string->number (or (getenv "PORT") "8080")))

(define (ext->mime-type ext)
  (assoc-ref
   '(("html" . (text/html (charset . "utf-8")))
     ("css"  . (text/css (charset . "utf-8")))
     ("js"   . (application/javascript (charset . "utf-8")))
     ("json" . (application/json (charset . "utf-8")))
     ("wasm" . (application/wasm))
     ("scm"  . (text/x-scheme (charset . "utf-8")))
     ("txt"  . (text/plain (charset . "utf-8")))
     ("svg"  . (image/svg+xml))
     ("png"  . (image/png))
     ("jpg"  . (image/jpeg))
     ("ico"  . (image/x-icon))
     ("map"  . (application/json (charset . "utf-8")))
     ("xml"  . (application/xml)))
   ext))

(define (path->mime-type path)
  (let* ((basename (uri-decode (basename path)))
         (dot (string-rindex basename #\.)))
    (if dot
        (or (ext->mime-type (substring basename (+ dot 1)))
            '(application/octet-stream))
        '(application/octet-stream))))

(define (sanitize-path path)
  (let ((decoded (uri-decode path)))
    (if (string-contains decoded "..")
        #f
        decoded)))

(define (not-found-request request request-body)
  (values (build-response #:code 404)
          "Not found"))

(define (handler request request-body)
  (let* ((path (uri-path (request-uri request)))
         (safe-path (sanitize-path path)))
    (if (not safe-path)
        (not-found-request request request-body)
        (let* ((relative-path (if (string-prefix? "/" safe-path)
                                  (substring safe-path 1)
                                  safe-path))
               (full-path (string-append %work-dir "/"
                                (if (string-null? relative-path)
                                    "index.html"
                                    relative-path))))
          (cond
           ((string-null? relative-path)
            (let ((index (string-append %work-dir "/index.html")))
              (if (file-exists? index)
                  (values (build-response
                           #:code 200
                           #:headers
                           `((content-type . (text/html (charset . "utf-8")))))
                          (call-with-input-file index get-string-all))
                  (not-found-request request request-body))))
           ((file-exists? full-path)
            (if (file-is-directory? full-path)
                (let ((index (string-append full-path "/index.html")))
                  (if (file-exists? index)
                      (values (build-response
                               #:code 200
                               #:headers
                               `((content-type . (text/html (charset . "utf-8")))))
                              (call-with-input-file index get-string-all))
                      (not-found-request request request-body)))
                (call-with-input-file full-path
                  (lambda (port)
                    (let ((body (get-bytevector-all port)))
                      (values (build-response
                               #:code 200
                               #:headers
                               `((content-type . ,(path->mime-type full-path))
                                 (access-control-allow-origin . "*")
                                 (content-length . ,(bytevector-length body))))
                              body)))
                  #:binary #t)))
           (else
            (not-found-request request request-body)))))))

(format #t "Serving ~a on http://127.0.0.1:~a~%" %work-dir %port)
(run-server handler 'http `(#:addr ,(inet-pton AF_INET "127.0.0.1") #:port ,%port))