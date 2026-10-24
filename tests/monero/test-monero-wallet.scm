;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/monero/test-monero-wallet.scm — end-to-end wallet actor test
;;;
;;; Spins up a tiny in-process HTTP server that speaks HTTP Digest auth
;;; + JSON-RPC 2.0 the way monero-wallet-rpc (epee) does, just enough to
;;; exercise the ^monero-wallet actor. The mock keeps a connection open
;;; across its 401, ties each nonce to the connection that issued it, and
;;; sends the two WWW-authenticate lines (MD5, MD5-sess) verbatim — the
;;; three behaviours the live daemon has and Guile's (web server) lacks
;;; (it closes on any 4xx). Verifies:
;;;
;;;   - Digest challenge/response handshake on ONE connection per call
;;;   - A nonce is refused on any connection but its own
;;;   - get-balance response parsing → <balance-info> record
;;;   - get-address
;;;   - create-address
;;;   - get-transfers incoming filter + height bump
;;;   - transfer encoding (destinations vector, params)
;;;   - error classification (auth failure, wallet error envelope)
;;;
;;; Run:  guile -L module -L tests tests/monero/test-monero-wallet.scm

(use-modules (goblins)
             (goblins vat)
             (goblins persistence-store memory)
             (localchimera test harness)
             (web client)
             (web request)
             (web response)
             (web http)
             (web uri)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-9)
             (ice-9 threads)
             (ice-9 format)
             (json)
             (localchimera monero rpc-digest)
             (localchimera monero wallet))

;;; ── Mock monero-wallet-rpc server ────────────────────────────────────────

(define %realm "monero-wallet-rpc")
(define %rpc-user "localchimera")
(define %rpc-pass "s3cr3t")
(define (header-ref request name)
  (assq-ref (request-headers request) name))

(define (expected-ha1)
  (md5-hex (string-append %rpc-user ":" %realm ":" %rpc-pass)))

(define (parse-auth-header s)
  (let ((ix (string-contains s "Digest ")))
    (if (not ix)
        '()
        (let ((rest (substring s (+ ix 7))))
          (let loop ((i 0) (len (string-length rest)) (acc '()))
            (cond
             ((>= i len) (reverse acc))
             ((char-whitespace? (string-ref rest i)) (loop (+ i 1) len acc))
             ((char=? (string-ref rest i) #\,) (loop (+ i 1) len acc))
             (else
              (let ((eq-pos (string-index rest #\= i)))
                (if (not eq-pos)
                    (reverse acc)
                    (let* ((key (string->symbol (substring rest i eq-pos)))
                           (vstart (+ eq-pos 1)))
                      (if (and (< vstart len)
                               (char=? (string-ref rest vstart) #\"))
                          (let ((end (string-index rest #\" (+ vstart 1))))
                            (loop (+ end 1) len
                                  (cons (cons key (substring rest (+ vstart 1) end))
                                        acc)))
                          (let ((comma (or (string-index rest #\, vstart) len)))
                            (loop comma len
                                  (cons (cons key (substring rest vstart comma))
                                        acc))))))))))))))

(define (auth-params auth-hdr)
  "The Digest params of an Authorization header as a symbol-keyed alist.
Guile parses the header into (digest (key . value) ...); a string is
parsed here."
  (cond
   ((and (pair? auth-hdr) (eq? (car auth-hdr) 'digest) (list? (cdr auth-hdr)))
    (cdr auth-hdr))
   ((string? auth-hdr) (parse-auth-header auth-hdr))
   (else '())))

(define (verify-digest auth-hdr method uri connection-nonce)
  "Recompute the expected digest response and compare. The nonce has to
be the one THIS connection issued."
  (let* ((parts (auth-params auth-hdr))
         (nonce (assq-ref parts 'nonce))
         (nc (assq-ref parts 'nc))
         (cnonce (assq-ref parts 'cnonce))
         (qop (assq-ref parts 'qop))
         (got-resp (assq-ref parts 'response))
         (ha1 (expected-ha1))
         (ha2 (md5-hex (string-append method ":" uri)))
         (expected (md5-hex (string-append ha1 ":" nonce ":" nc ":"
                                           cnonce ":" qop ":" ha2))))
    (and nonce nc cnonce qop got-resp
         (string=? nonce connection-nonce)
         (string=? got-resp expected))))

(define %request-count 0)
(define %challenge-count 0)

(define (handle-request request body nonce)
  "Returns (values CODE EXTRA-HEADER-LINES BODY-STRING)."
  (set! %request-count (+ 1 %request-count))
  (let* ((path (uri-path (request-uri request)))
         (auth-hdr (header-ref request 'authorization)))
    (cond
     ((not (string=? path "/json_rpc"))
      (values 404 '() "not found"))

     ;; No auth → the challenge, as monero-wallet-rpc words it.
     ((not auth-hdr)
      (set! %challenge-count (+ 1 %challenge-count))
      (values
       401
       (map (lambda (algo)
              (format #f "WWW-authenticate: Digest qop=\"auth\",algorithm=~a,realm=\"~a\",nonce=\"~a\",stale=false"
                      algo %realm nonce))
            '("MD5" "MD5-sess"))
       "<html><body><h1>401 Unauthorized</h1></body></html>"))

     ;; Auth present → verify and dispatch.
     ((not (verify-digest auth-hdr "POST" "/json_rpc" nonce))
      (values 401 '() "bad digest"))

     (else
      (let* ((body-str (if (bytevector? body)
                           (utf8->string body)
                           (or body "")))
             (req (json-string->scm body-str))
             (method (assoc-ref req "method"))
             (params (assoc-ref req "params"))
             (result (dispatch-method method params)))
        (values
         200
         '("Content-Type: application/json")
         (scm->json-string
          `(("jsonrpc" . "2.0")
            ("id" . "0")
            ("result" . ,result)))))))))

(define %balance-atomic 1500000000000)   ; 1.5 XMR
(define %address "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A")

(define (dispatch-method method params)
  (cond
   ((equal? method "get_balance")
    `(("balance" . ,%balance-atomic)
      ("unlocked_balance" . ,%balance-atomic)
      ("blocks_to_unlock" . 0)))

   ((equal? method "get_address")
    `(("address" . ,%address)
      ("addresses" . #())))

   ((equal? method "create_address")
    `(("address" . ,(string-append %address "-sub"))
      ("address_index" . 1)))

   ((equal? method "get_transfers")
    ;; Return a fake incoming transfer.
    (let* ((subaddr (list (cons "major" 0) (cons "minor" 0)))
           (one     (list (cons "txid" "deadbeef00000000000000000000000000000000000000000000000000000000")
                          (cons "amount" 500000000000)   ; 0.5 XMR
                          (cons "height" 3100001)
                          (cons "subaddr_index" subaddr))))
      (list (cons "in" (vector one)))))

   ((equal? method "get_height")
    `(("height" . 3100042)))

   ((equal? method "transfer")
    (let* ((dests (assoc-ref params "destinations"))
           (amount (if (and dests (vector? dests) (> (vector-length dests) 0))
                       (or (assoc-ref (vector-ref dests 0) "amount") 0)
                       0)))
      (list
       (cons "tx_hash" "cafef00d00000000000000000000000000000000000000000000000000000000")
       (cons "amount" amount)
       (cons "fee" 10000000))))

   (else
    (error "mock server: unsupported method" method))))

;;; ── The server loop ──────────────────────────────────────────────────────

(define %connection-count 0)

(define (reason-phrase code)
  (case code
    ((200) "OK") ((401) "Unauthorized") ((404) "Not Found") (else "Status")))

(define (serve-connection client)
  "One TCP connection: its own nonce, and every request on it answered
until the peer closes — the 401 included."
  (set! %connection-count (+ 1 %connection-count))
  (let ((nonce (format #f "nonce-of-connection-~a" %connection-count)))
    (let loop ()
      (let ((request (false-if-exception (read-request client))))
        (when request
          (let ((body (read-request-body request)))
            (call-with-values
                (lambda () (handle-request request body nonce))
              (lambda (code header-lines body-str)
                (let ((bv (string->utf8 body-str)))
                  (put-bytevector
                   client
                   (string->utf8
                    (string-append
                     (format #f "HTTP/1.1 ~a ~a\r\n" code (reason-phrase code))
                     (string-concatenate
                      (map (lambda (l) (string-append l "\r\n")) header-lines))
                     (format #f "Content-Length: ~a\r\n\r\n"
                             (bytevector-length bv)))))
                  (put-bytevector client bv)
                  (force-output client)))))
          (loop))))
    (false-if-exception (close-port client))))

(define %listener
  (let ((sock (socket PF_INET SOCK_STREAM 0)))
    (setsockopt sock SOL_SOCKET SO_REUSEADDR 1)
    (bind sock AF_INET INADDR_LOOPBACK 0)   ; port 0: the kernel picks, and holds it
    (listen sock 16)
    sock))

(define %port (vector-ref (getsockname %listener) 2))

(define %server-thread
  (call-with-new-thread
   (lambda ()
     (let accept-loop ()
       (let ((client (car (accept %listener))))
         (call-with-new-thread (lambda () (serve-connection client))))
       (accept-loop)))))

(define %base-url (format #f "http://127.0.0.1:~a" %port))

(format #t "=== Starting mock monero-wallet-rpc on ~a ===~%" %base-url)


;;; ── Exercise the wallet actor ────────────────────────────────────────────

(format #t "~%=== Spawn ^monero-wallet and exercise methods ===~%")

(define wallet-vat (spawn-vat))

(define wallet
  (with-vat wallet-vat
    (spawn ^monero-wallet
           (make-wallet-provider
            #:base-url %base-url
            #:rpc-user %rpc-user
            #:rpc-password %rpc-pass))))

;; get-balance
(let ((bi (with-vat wallet-vat ($ wallet 'get-balance))))
  (check "get-balance returns balance-info record" (balance-info? bi))
  (check "get-balance atomic = 1.5e12"
         (= (balance-info-atomic bi) %balance-atomic))
  (check "get-balance unlocked = 1.5e12"
         (= (balance-info-unlocked-atomic bi) %balance-atomic))
  (check "atomic->xmr conversion" (= (atomic->xmr %balance-atomic) 3/2)))

;; Digest handshake: the 401 and the answer, on one connection.
(check "first call triggered a Digest challenge" (= %challenge-count 1))
(check "first call produced 2 HTTP requests (401 + 200)"
       (= %request-count 2))
(check "first call used exactly one connection" (= %connection-count 1))

;; get-address
(let ((a (with-vat wallet-vat ($ wallet 'get-address))))
  (check "get-address returns primary address string"
         (and (string? a) (string=? a %address))))

;; A nonce lives and dies with its connection, so the second call opens
;; its own and draws its own challenge.
(check "second call drew its own challenge" (= %challenge-count 2))
(check "second call produced 2 more HTTP requests" (= %request-count 4))
(check "second call used its own connection" (= %connection-count 2))

;; The rule the live daemon enforces: an answer computed for one
;; connection's nonce, presented on another connection, is refused.
(let* ((creds (make-digest-creds %rpc-user %rpc-pass))
       (url (string-append %base-url "/json_rpc"))
       (stale-answer (build-authorization-header
                      creds
                      `((realm . ,%realm) (nonce . "nonce-of-connection-1")
                        (qop . "auth") (algorithm . "MD5"))
                      "POST" "/json_rpc" "00000001" (make-cnonce)))
       (port (open-socket-for-uri (string->uri url))))
  (call-with-values
      (lambda ()
        (http-post url #:port port #:keep-alive? #t
                   #:body (string->utf8 "{}")
                   #:headers `((authorization . ,stale-answer)
                               (content-type . (application/json)))
                   #:decode-body? #f))
    (lambda (response _)
      (check "a nonce from another connection is refused (401)"
             (= (response-code response) 401))))
  (close-port port))

;; create-address
(let ((result (with-vat wallet-vat ($ wallet 'create-address "donor-1"))))
  (check "create-address returns (address . index)"
         (and (pair? result)
              (string? (car result))
              (number? (cdr result)))))

;; get-transfers — use the poller-style filter.
(let ((r (with-vat wallet-vat
           ($ wallet 'get-transfers
              '(("in" . #t)
                ("filter_by_height" . #t)
                ("min_height" . 0))))))
  (check "get-transfers returned a result alist" (pair? r))
  (let ((ins (assoc-ref r "in")))
    (check "get-transfers 'in is non-empty"
           (or (and (vector? ins) (> (vector-length ins) 0))
               (and (list? ins) (pair? ins))))))

;; transfer
(let ((r (with-vat wallet-vat
           ($ wallet 'transfer
              `((("address" . ,%address)
                 ("amount" . ,(xmr->atomic 0.1))))))))
  (check "transfer returned result alist" (pair? r))
  (check "transfer returned tx_hash"
         (string? (assoc-ref r "tx_hash"))))

;; ── Error paths ─────────────────────────────────────────────────────────
(format #t "~%=== Error paths ===~%")

;; Wrong password → auth failure → exception.
(define bad-wallet
  (with-vat wallet-vat
    (spawn ^monero-wallet
           (make-wallet-provider
            #:base-url %base-url
            #:rpc-user %rpc-user
            #:rpc-password "wrong"))))

(check "wrong password raises an error"
       (catch #t
         (lambda ()
           (with-vat wallet-vat ($ bad-wallet 'get-balance))
           #f)
         (lambda _ #t)))

(check "bad-wallet last-error is populated"
       (string? (with-vat wallet-vat ($ bad-wallet 'last-error))))

;;; ── Persistence round-trip ───────────────────────────────────────────────
;;;
;;; Same mock server, but now the wallet lives inside a persistent vat.
;;; We snapshot it, halt the vat, spawn a fresh vat from the same store,
;;; and check that the restored wallet ref still makes live RPC calls —
;;; proving that #:portrait / #:restore reconstitute the URL + creds
;;; correctly from the serialized fields + the on-disk password file.

(format #t "~%=== Persistence round-trip ===~%")

;; Password file the restore path will re-read. 0600, process-local.
(define %pw-file (string-append "/tmp/test-monero-rpc-pw-"
                                (number->string (getpid))))
(call-with-output-file %pw-file
  (lambda (port) (display %rpc-pass port)))
(chmod %pw-file #o600)

(define pstore (make-memory-store))

(define-values (pvat pwallet)
  (spawn-persistent-vat
   monero-wallet-env
   (lambda ()
     (values (spawn ^monero-wallet
                    (make-wallet-provider
                     #:base-url %base-url
                     #:rpc-user %rpc-user
                     #:rpc-password-file %pw-file))))
   pstore
   #:name "test-monero-wallet"
   #:version 1))

;; Exercise the wallet through the persistent vat before snapshotting.
(let ((bi (with-vat pvat ($ pwallet 'get-balance))))
  (check "persistent wallet: get-balance returns balance-info"
         (and (balance-info? bi)
              (= (balance-info-atomic bi) %balance-atomic))))

(check "persistent wallet: provider-name is set"
       (equal? "monero-wallet-rpc"
               (with-vat pvat ($ pwallet 'provider-name))))

(vat-halt! pvat)

;; Second "run": spawn a new persistent vat from the same store.
;; The restore thunk MUST NOT be called — the wallet is rehydrated from
;; the portrait, which has no password, and the #:restore clause re-reads
;; %pw-file to rebuild the digest creds.
(define-values (pvat2 pwallet2)
  (spawn-persistent-vat
   monero-wallet-env
   (lambda () (error "restore thunk should not run on the second call"))
   pstore
   #:name "test-monero-wallet"
   #:version 1))

(let ((bi (with-vat pvat2 ($ pwallet2 'get-balance))))
  (check "restored wallet: get-balance still hits the server"
         (and (balance-info? bi)
              (= (balance-info-atomic bi) %balance-atomic))))

(check "restored wallet: address matches"
       (equal? %address
               (with-vat pvat2 ($ pwallet2 'get-address))))

(check "restored wallet: provider-name survived portrait"
       (equal? "monero-wallet-rpc"
               (with-vat pvat2 ($ pwallet2 'provider-name))))

(check "restored wallet: last-error starts fresh (#f)"
       (not (with-vat pvat2 ($ pwallet2 'last-error))))

(vat-halt! pvat2)
(when (file-exists? %pw-file) (delete-file %pw-file))

;;; ── Summary ──────────────────────────────────────────────────────────────

(test-summary!)
