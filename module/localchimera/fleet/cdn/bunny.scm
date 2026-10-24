;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/fleet/cdn/bunny.scm — bunny.net adapter for the CDN protocol
;;;
;;; One adapter for (localchimera fleet cdn). A "zone" here is a bunny.net pull
;;; zone: an edge hostname that pulls from one origin URL.
;;;
;;; API: https://docs.bunny.net/reference — base https://api.bunny.net,
;;; account key in the AccessKey header.
;;;
;;;   GET  /pullzone?search=NAME         list (a JSON array)
;;;   GET  /pullzone/ID                  one zone, its EdgeRules included
;;;   POST /pullzone                     create  {Name, OriginUrl, Type}
;;;   POST /pullzone/ID                  update  {OriginUrl}
;;;   POST /pullzone/ID/edgerules/addOrUpdate
;;;   POST /pullzone/ID/purgeCache       204
;;;
;;; Egress rides whatever the calling process rides (the gateway and the
;;; deploy tool both run under torsocks on a Tor-only box).

(define-module (localchimera fleet cdn bunny)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (json)
  #:export (make-cdn))

(define %base "https://api.bunny.net")

(define (default-http credential)
  "METHOD URL BODY(string or #f) → (values status body-string)."
  (lambda (method url body)
    (call-with-values
      (lambda ()
        (http-request (string->uri url)
                      #:method method
                      #:headers `((accesskey . ,credential)
                                  (accept . ((application/json)))
                                  ,@(if body
                                        '((content-type . (application/json)))
                                        '()))
                      #:body (and body (string->utf8 body))
                      #:decode-body? #f))
      (lambda (response raw)
        (values (response-code response)
                (if (bytevector? raw) (utf8->string raw) ""))))))

(define (ok? status) (and (>= status 200) (< status 300)))

(define (parse body)
  (if (string-null? body) #f (json-string->scm body)))

(define (zone<-json z)
  "The protocol's zone alist from a pull-zone object."
  (let ((hostnames (vector->list (or (assoc-ref z "Hostnames") #()))))
    `((id . ,(number->string (assoc-ref z "Id")))
      (hostname . ,(and (pair? hostnames)
                        (assoc-ref (car hostnames) "Value")))
      (origin . ,(assoc-ref z "OriginUrl")))))

(define (no-cache-rule pattern path)
  "An edge rule: requests matching PATTERN bypass the edge cache."
  `(("ActionType" . 3)                  ; override cache time
    ("ActionParameter1" . "0")
    ("ActionParameter2" . "")
    ("Triggers" . #((("Type" . 0)       ; URL
                     ("PatternMatches" . #(,pattern))
                     ("PatternMatchingType" . 0)
                     ("Parameter1" . ""))))
    ("TriggerMatchingType" . 0)
    ("Enabled" . #t)
    ("Description" . ,(string-append "no-cache " path))))

(define (rule-patterns zone-json)
  "Every URL pattern ZONE-JSON's edge rules already match."
  (append-map
   (lambda (rule)
     (append-map (lambda (trigger)
                   (vector->list (or (assoc-ref trigger "PatternMatches") #())))
                 (vector->list (or (assoc-ref rule "Triggers") #()))))
   (vector->list (or (assoc-ref zone-json "EdgeRules") #()))))

(define* (make-cdn credential #:key (http (default-http credential)))
  "The CDN protocol over bunny.net. HTTP is (method url body) → (values
status body); tests hand in their own."

  (define (call method path . body)
    (http method (string-append %base path)
          (and (pair? body) (scm->json-string (car body)))))

  (define (find-zone name)
    (call-with-values (lambda () (call 'GET (string-append "/pullzone?search=" name)))
      (lambda (status body)
        (unless (ok? status)
          (error (format #f "cdn: listing zones answered HTTP ~a" status)))
        (let ((zones (parse body)))
          (find (lambda (z) (equal? (assoc-ref z "Name") name))
                (if (vector? zones) (vector->list zones) '()))))))

  (define (ensure-zone name origin-url)
    (let ((existing (find-zone name)))
      (if existing
          (zone<-json existing)
          (call-with-values
            (lambda ()
              (call 'POST "/pullzone"
                    `(("Name" . ,name)
                      ("OriginUrl" . ,origin-url)
                      ("Type" . 0)
                      ;; An origin answers the edge with its own
                      ;; certificate; the allowlist is what guards it.
                      ("VerifyOriginSSL" . #f))))
            (lambda (status body)
              (unless (ok? status)
                (error (format #f "cdn: creating zone ~a answered HTTP ~a"
                               name status)))
              (zone<-json (parse body)))))))

  (define (set-origin zone-id origin-url)
    (call-with-values
      (lambda () (call 'POST (string-append "/pullzone/" zone-id)
                       `(("OriginUrl" . ,origin-url))))
      (lambda (status _)
        (unless (ok? status)
          (error (format #f "cdn: setting the origin answered HTTP ~a" status)))
        #t)))

  (define (ensure-no-cache zone-id origin-url paths)
    (call-with-values (lambda () (call 'GET (string-append "/pullzone/" zone-id)))
      (lambda (status body)
        (unless (ok? status)
          (error (format #f "cdn: reading zone ~a answered HTTP ~a"
                         zone-id status)))
        (let ((have (rule-patterns (parse body))))
          (map (lambda (path)
                 (let ((pattern (string-append origin-url path)))
                   (cons path
                         (if (member pattern have)
                             'exists
                             (call-with-values
                               (lambda ()
                                 (call 'POST
                                       (string-append "/pullzone/" zone-id
                                                      "/edgerules/addOrUpdate")
                                       (no-cache-rule pattern path)))
                               (lambda (status _)
                                 (if (ok? status) 'added 'failed)))))))
               paths)))))

  (define (purge zone-id)
    (call-with-values
      (lambda () (call 'POST (string-append "/pullzone/" zone-id "/purgeCache")))
      (lambda (status _)
        (unless (ok? status)
          (error (format #f "cdn: purge answered HTTP ~a" status)))
        #t)))

  `((ensure-zone     . ,ensure-zone)
    (set-origin      . ,set-origin)
    (ensure-no-cache . ,ensure-no-cache)
    (purge           . ,purge)))
