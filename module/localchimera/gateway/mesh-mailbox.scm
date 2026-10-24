;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/gateway/mesh-mailbox.scm — ^mesh-mailbox
;;;
;;; Store-and-forward custody for mesh deliveries to browser personas
;;; (LXMF-STORE-AND-FORWARD.md step 3). The bridge surfaces inbound
;;; single packets for REGISTERed destinations as DELIVERY lines; the
;;; gateway stores them HERE until the persona's session drains them.
;;;
;;; Trust model: CIPHERTEXT ONLY. Payloads are encrypted to the
;;; persona's identity (Reticulum X25519+AES); this actor cannot read
;;; what it stores — same custody class as an LXMF propagation node.
;;; Ownership at drain time is the caller's burden: ^lobby-session
;;; derives the persona's destinations from its KEL-anchored pubkey,
;;; so a session can only ever name destinations it owns.
;;;
;;; Retention: per-destination cap (drop-oldest) + TTL sweep on access.
;;; Durability: one file per destination under DIR/<prefix>/<dest>.scm
;;; (the oobi-host bucket pattern), rewritten on change — message
;;; volumes here are personal-mailbox sized, not log sized.

(define-module (localchimera gateway mesh-mailbox)
  #:use-module (goblins)
  #:use-module ((localchimera utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 rdelim)
  #:use-module ((srfi srfi-1)  #:select (filter fold))
  #:use-module ((srfi srfi-13) #:select (string-suffix? string-trim-right))
  #:export (^mesh-mailbox
            mesh-mailbox-spawn-from-dir
            mesh-delivery-stream!))

(define %default-cap 1000)          ; messages per destination
(define %default-ttl (* 30 24 3600)) ; seconds (30 days)

(define (%bucket dest) (if (>= (string-length dest) 2) (substring dest 0 2) "_"))

(define (%path dir dest)
  (string-append dir "/" (%bucket dest) "/" dest ".scm"))

(define (%ensure-dir! path)
  (unless (file-exists? path) (mkdir path)))

(define (%write-box! dir dest entries)
  (when dir
    (%ensure-dir! dir)
    (%ensure-dir! (string-append dir "/" (%bucket dest)))
    (call-with-output-file (%path dir dest)
      (lambda (p) (write entries p) (newline p)))))

(define (%read-box dir dest)
  (let ((path (%path dir dest)))
    (if (file-exists? path)
        (catch #t
          (lambda () (call-with-input-file path read))
          (lambda _ '()))
        '())))

(define (%read-all-boxes dir)
  "((dest . entries) …) for every stored mailbox under DIR."
  (if (not (and dir (file-exists? dir)))
      '()
      (fold
       (lambda (bucket acc)
         (if (member bucket '("." ".."))
             acc
             (let ((bdir (string-append dir "/" bucket)))
               (fold
                (lambda (f acc)
                  (if (string-suffix? ".scm" f)
                      (let ((dest (substring f 0 (- (string-length f) 4))))
                        (cons (cons dest (%read-box dir dest)) acc))
                      acc))
                acc
                (or (scandir bdir) '())))))
       '()
       (or (scandir dir) '()))))

(define* (^mesh-mailbox bcom #:optional (boxes (hashmap))
                        #:key (durable-dir #f)
                              (cap %default-cap)
                              (ttl %default-ttl))
  ;; boxes: hashmap dest-hex → list of (payload-hex . stored-at),
  ;; oldest first.

  (define (now) (instant->unix (clock-now)))

  (define (fresh entries)
    (let ((cutoff (- (now) ttl)))
      (filter (lambda (e) (> (cdr e) cutoff)) entries)))

  (define (next! new-boxes reply)
    (bcom (^mesh-mailbox bcom new-boxes
                         #:durable-dir durable-dir #:cap cap #:ttl ttl)
          reply))

  (methods
    ;; ── store! ───────────────────────────────────────────────────────────────
    ;; Append a delivery for DEST (both hex strings). Oldest entries
    ;; drop past the cap; expired ones sweep on the way in.
    ((store! dest payload)
     (cond
      ((not (and (string? dest) (string? payload)))
       (list 'error "dest and payload must be hex strings"))
      (else
       (let* ((entries (append (fresh (hashmap-ref boxes dest '()))
                               (list (cons payload (now)))))
              (n       (length entries))
              (entries (if (> n cap) (list-tail entries (- n cap)) entries)))
         (%write-box! durable-dir dest entries)
         (next! (hashmap-set boxes dest entries) 'ok)))))

    ;; ── drain! ───────────────────────────────────────────────────────────────
    ;; Return DEST's pending payload-hex list (oldest first) and clear
    ;; the box — ack-by-drain; the session that asked owns the dest.
    ((drain! dest)
     (let ((entries (fresh (hashmap-ref boxes dest '()))))
       (%write-box! durable-dir dest '())
       (next! (hashmap-set boxes dest '())
              (map car entries))))

    ;; ── count ────────────────────────────────────────────────────────────────
    ((count dest)
     (length (fresh (hashmap-ref boxes dest '()))))

    ;; ── destinations ─────────────────────────────────────────────────────────
    ;; Every destination with pending mail — what the gateway
    ;; re-REGISTERs at the bridge after a restart.
    ((destinations)
     (hashmap-fold (lambda (k v acc) (if (pair? v) (cons k acc) acc))
                   '() boxes))))

(define* (mesh-mailbox-spawn-from-dir dir #:key (cap %default-cap)
                                            (ttl %default-ttl))
  "Spawn a ^mesh-mailbox pre-populated from DIR's stored boxes."
  (let ((boxes (fold (lambda (p acc) (hashmap-set acc (car p) (cdr p)))
                     (hashmap)
                     (%read-all-boxes dir))))
    (spawn ^mesh-mailbox boxes #:durable-dir dir #:cap cap #:ttl ttl)))

;;; ── Bridge delivery stream ──────────────────────────────────────────────────

(define (mesh-delivery-stream! control-path store!)
  "Open a dedicated SUBSCRIBE connection to the rns-bridge control
   socket at CONTROL-PATH and feed each `DELIVERY <dest> <payload>`
   line to (STORE! dest-hex payload-hex). Blocks for the connection's
   lifetime — run inside a fiber. Returns when the bridge closes the
   stream; raises on connect failure (callers decide retry policy)."
  (let ((sock (socket PF_UNIX SOCK_STREAM 0)))
    (connect sock AF_UNIX control-path)
    (display "SUBSCRIBE\n" sock)
    (force-output sock)
    (let loop ()
      (let ((line (read-line sock)))
        (unless (eof-object? line)
          (let ((parts (string-split (string-trim-right line) #\space)))
            (when (and (= 3 (length parts))
                       (string=? "DELIVERY" (car parts)))
              (store! (cadr parts) (caddr parts))))
          (loop))))))
