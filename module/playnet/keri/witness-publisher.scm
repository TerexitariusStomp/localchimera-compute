;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/keri/witness-publisher.scm — HTTP push of signed
;;; KEL events to remote KERIA-style witness endpoints.
;;;
;;; Per democracy-on-keri.md §4.1 cross-internet portability: federation-
;;; peer KEL mirroring (via ^scope-witness) covers Goblins-internal
;;; verifiability. For verifiers on the open internet, we additionally
;;; POST signed events to a configurable list of witness URLs. The
;;; receiving end is expected to expose a KERIA-compatible
;;; `/identifiers/{aid}` POST endpoint that accepts `{name, icp, sigs}`
;;; bodies (or the equivalent for rot/ixn events).
;;;
;;; URLs come from the env var KERI_WITNESS_PUSH_URLS as a
;;; comma-separated list. Empty / unset = no-op.
;;;
;;; Best-effort: per-witness failures log to stderr but never raise to
;;; the caller. KEL appends are not blocked on witness reachability;
;;; production deployments should use multiple witnesses for redundancy.

(define-module (playnet keri witness-publisher)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 format)
  #:use-module (json)
  #:use-module ((srfi srfi-1) #:select (filter-map))
  #:use-module ((playnet keri signify-portable)
                #:select (cesr-stream-parse))
  #:export (witness-push-urls
            keri-publish-event!
            keri-fetch-kel-from-witness))

(define %known-event-keys '("icp" "rot" "ixn" "dip" "drt"))

(define (event-type-key event-alist)
  "Return the KEL event-type key (`icp`/`rot`/…) for EVENT-ALIST, taken
   from its `t` field. Falls back to `icp` so unknown types still land
   in a kel-store-recognised slot."
  (let ((t (and (list? event-alist) (assoc-ref event-alist "t"))))
    (if (and (string? t) (member t %known-event-keys)) t "icp")))

(define (split-csv s)
  "Comma-split a string, dropping empty entries."
  (let loop ((chars (string->list s)) (acc '()) (cur '()))
    (cond
     ((null? chars)
      (let ((final (reverse (cons (list->string (reverse cur)) acc))))
        (filter (lambda (x) (not (string=? x ""))) final)))
     ((eq? (car chars) #\,)
      (loop (cdr chars)
            (cons (list->string (reverse cur)) acc)
            '()))
     (else
      (loop (cdr chars) acc (cons (car chars) cur))))))

(define (witness-push-urls)
  "Parse the KERI_WITNESS_PUSH_URLS env var (comma-separated) into a
   list of URLs. Empty/unset → '()."
  (let ((raw (getenv "KERI_WITNESS_PUSH_URLS")))
    (if (and raw (not (string=? raw "")))
        (split-csv raw)
        '())))

(define (event-type-of body)
  "Return 'icp / 'rot / 'ixn from a signed event body, or #f."
  (cond
   ((assoc-ref body "icp") 'icp)
   ((assoc-ref body "rot") 'rot)
   ((assoc-ref body "ixn") 'ixn)
   (else #f)))

(define (cesr-frames->bodies frames)
  "Turn CESR-parsed (event-json . sigs-vector) pairs into kel-store
   bodies of the shape `((<type> . event-alist) (\"sigs\" . sigs-list))`,
   where <type> comes from the event's `t` field. Frames whose JSON
   doesn't parse are dropped — a partial KEL is more useful than none."
  (filter-map
   (lambda (pair)
     (catch #t
       (lambda ()
         (let ((event-alist (json-string->scm (car pair))))
           `((,(event-type-key event-alist) . ,event-alist)
             ("sigs" . ,(vector->list (cdr pair))))))
       (lambda _ #f)))
   frames))

(define (keri-publish-event! aid event-body)
  "POST EVENT-BODY (a {name, icp/rot/ixn, sigs} alist) as JSON to each
   URL in (witness-push-urls). Best-effort. Returns the list of URLs
   that responded with 2xx."
  (let* ((urls (witness-push-urls))
         (body-json (scm->json-string event-body))
         (body-bv   (string->utf8 body-json))
         (etype     (event-type-of event-body))
         ;; KERIA convention: icp goes to /identifiers/{aid};
         ;; rot likewise; ixn typically goes to
         ;; /identifiers/{aid}/ixn. Without a definitive endpoint
         ;; spec for external events we default to the bare aid path
         ;; per KERIA's own /identifiers POST shape, and let
         ;; deployments override KERI_WITNESS_PUSH_URLS to embed any
         ;; subpath they need.
         (succeeded '()))
    (for-each
     (lambda (base-url)
       (let ((url (cond
                   ((eq? etype 'ixn)
                    (string-append base-url "/identifiers/" aid "/ixn"))
                   (else
                    (string-append base-url "/identifiers")))))
         (catch #t
           (lambda ()
             (call-with-values
               (lambda ()
                 (http-post url
                            #:body body-bv
                            #:headers
                            '((content-type . (application/json)))))
               (lambda (resp _body)
                 (let ((status (response-code resp)))
                   (cond
                    ((and (>= status 200) (< status 300))
                     (set! succeeded (cons url succeeded)))
                    (else
                     (format (current-error-port)
                             "[witness-publisher] ~a → ~a~%" url status)))))))
           (lambda (key . args)
             (format (current-error-port)
                     "[witness-publisher] ~a errored: ~a ~a~%"
                     url key args)))))
     urls)
    (reverse succeeded)))

(define* (keri-fetch-kel-from-witness url aid)
  "GET URL/.well-known/keri/oobi/AID, which per the KERI OOBI draft
   serves a CESR text-stream KEL. Parse each frame into a kel-store
   body (one of `(icp/rot/ixn/dip/drt . event-alist)` plus a `sigs`
   list). Returns '() on transport errors or unparseable streams so
   callers can fall through to another witness."
  (let ((full (string-append url "/.well-known/keri/oobi/" aid)))
    (catch #t
      (lambda ()
        (call-with-values
          (lambda () (http-get full))
          (lambda (resp body)
            (let ((status (response-code resp)))
              (cond
               ((and (>= status 200) (< status 300))
                (let ((s (cond
                          ((string? body) body)
                          ((bytevector? body) (utf8->string body))
                          (else ""))))
                  (catch #t
                    (lambda () (cesr-frames->bodies (cesr-stream-parse s)))
                    (lambda _ '()))))
               (else '()))))))
      (lambda _ '()))))
