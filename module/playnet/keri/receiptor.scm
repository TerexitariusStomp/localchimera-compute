;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/keri/receiptor.scm — witness receipt collection for
;;; LOCALLY-BUILT AIDs (autonomous-signer scopes).
;;;
;;; KERIA-managed AIDs get receipts via KERIA's own Receiptor. Locally-
;;; built AIDs (scope inceptions signed in the Scheme stack) had no
;;; receipt path — which is WHY they had to stay toad=0: an AID incepted
;;; with bt>0 whose served OOBI carries no receipts is ESCROWED by every
;;; resolver and its OOBI stops verifying (IMPLEMENTATION.md §"Where we
;;; diverge" #2). This module closes that gap with the witness HTTP
;;; receipt protocol keripy's witnesses serve (indirecting.py
;;; ReceiptEnd):
;;;
;;;   POST {witness}/receipts
;;;     Content-Type: application/cesr+json   (httping.CESR_CONTENT_TYPE)
;;;     CESR-ATTACHMENT: <controller idx sigs, -A…>
;;;     body: the event JSON
;;;   → 200, body = the witness's rct message stream (rct JSON +
;;;     nontrans receipt couple) — self-contained: a resolver that
;;;     parses it after the event stores the wig and the event exits
;;;     escrow. 202 = escrowed at the witness (not yet receiptable).
;;;
;;; We serve the collected rct streams verbatim after the KEL in the
;;; OOBI body — no re-framing, same trick the witness's own OOBI uses.
;;;
;;; Server-only ((web client)); the browser never collects receipts —
;;; browser personas stay toad=0 by design.

(define-module (playnet keri receiptor)
  #:use-module ((playnet utils host) #:select (string-contains))
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 format)
  #:use-module ((ice-9 binary-ports) #:select (put-bytevector get-bytevector-all))
  #:use-module ((srfi srfi-1)  #:select (filter-map))
  #:use-module ((playnet keri signify-portable)
                #:select (cesr-idx-sigs-group))
  #:export (witness-base-url
            receipt-event!
            parse-witness-env))

(define (witness-base-url oobi-url)
  "The witness's HTTP base (scheme://host[:port]) from its OOBI URL —
   keripy witnesses serve /oobi/* and /receipts on the same listener."
  (let ((u (string->uri oobi-url)))
    (unless u (error "witness-base-url: unparseable OOBI URL" oobi-url))
    (uri->string
     (build-uri (uri-scheme u) #:host (uri-host u) #:port (uri-port u)))))

(define (%post-receipt base event-json atc)
  "POST one signed event to BASE/receipts and return the rct stream body
   on a 2xx, #f otherwise.

   Reads the response over a RAW socket rather than (web client)
   http-post: keripy's CESR receipt responses carry a content-type
   guile's STRICT response-header parser rejects with
   `bad-request: Bad value for header content-type (application/cesr+json)`
   — which made http-post throw and silently drop every receipt (0/N).
   We still set the exact `application/cesr+json` content type (no
   charset suffix — falcon string-compares it against
   httping.CESR_CONTENT_TYPE) and carry the indexed sigs in the
   CESR-Attachment header, but parse only the status line ourselves."
  (catch #t
    (lambda ()
      (let* ((uri  (string->uri (string-append base "/receipts")))
             (host (uri-host uri))
             (pnum (or (uri-port uri) 80))
             (body (string->utf8 event-json))
             (head (string->utf8
                    (string-append
                     "POST " (uri-path uri) " HTTP/1.1\r\n"
                     "Host: " host ":" (number->string pnum) "\r\n"
                     "Content-Type: application/cesr+json\r\n"
                     "CESR-Attachment: " atc "\r\n"
                     "Content-Length: " (number->string (bytevector-length body)) "\r\n"
                     "Connection: close\r\n\r\n")))
             (sock (socket PF_INET SOCK_STREAM 0)))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (connect sock AF_INET (inet-pton AF_INET host) pnum)
            (put-bytevector sock head)
            (put-bytevector sock body)
            (force-output sock)
            (let ((raw (get-bytevector-all sock)))
              (if (eof-object? raw)
                  #f
                  (let* ((resp   (utf8->string raw))
                         (nl     (string-index resp #\newline))
                         (status (substring resp 0 (or nl (string-length resp))))
                         (parts  (string-split (string-trim-both status) #\space))
                         (code   (and (>= (length parts) 2) (string->number (cadr parts))))
                         (sep    (string-contains resp "\r\n\r\n")))
                    (if (and code (>= code 200) (< code 300) sep)
                        (substring resp (+ sep 4))
                        #f)))))
          (lambda () (false-if-exception (close-port sock))))))
    (lambda (key . args)
      (format (current-error-port)
              "[receiptor] witness ~a failed: ~a ~a~%" base key args)
      #f)))

(define* (receipt-event! event-json sigs witness-oobis #:key (toad 1))
  "Collect witness receipts for the signed event EVENT-JSON (SIGS = its
   indexed controller signatures, vector of qb64). WITNESS-OOBIS is the
   list of witness OOBI URLs (PLAYNET_WITNESS_OOBIS shape); each
   witness's HTTP base derives from its OOBI URL. Returns the list of
   rct stream strings. Raises unless at least TOAD receipts arrive —
   serving a bt>0 inception with fewer receipts than its threshold
   bricks the OOBI (resolvers escrow it), so failing loudly at mint
   time is the kind path."
  (let* ((atc      (cesr-idx-sigs-group sigs))
         (receipts (filter-map
                    (lambda (oobi)
                      (%post-receipt (witness-base-url oobi) event-json atc))
                    witness-oobis)))
    (when (< (length receipts) toad)
      (error (format #f "receipt-event!: only ~a/~a receipts collected (toad ~a) — refusing to mint an escrow-doomed inception"
                     (length receipts) (length witness-oobis) toad)))
    receipts))

(define (parse-witness-env)
  "Read the deployment's witness pool from the environment:
     PLAYNET_WITNESS_AIDS  — comma-separated witness AID prefixes (b field)
     PLAYNET_WITNESS_OOBIS — comma-separated witness OOBI URLs, pairwise
     PLAYNET_WITNESS_TOAD  — optional threshold; default = majority
   Returns (values aids oobis toad); ('() '() 0) when unset — the
   witnessless default every dev/test environment keeps."
  (define (split s)
    (if (or (not s) (string-null? s))
        '()
        (filter (lambda (x) (not (string-null? x)))
                (map string-trim-both (string-split s #\,)))))
  (let* ((aids  (split (getenv "PLAYNET_WITNESS_AIDS")))
         (oobis (split (getenv "PLAYNET_WITNESS_OOBIS")))
         (n     (length aids))
         (toad  (cond ((getenv "PLAYNET_WITNESS_TOAD") => string->number)
                      ((zero? n) 0)
                      (else (+ 1 (quotient n 2))))))
    (when (and (pair? aids) (not (= (length aids) (length oobis))))
      (error "PLAYNET_WITNESS_AIDS and PLAYNET_WITNESS_OOBIS must pair up"
             aids oobis))
    (values aids oobis toad)))
