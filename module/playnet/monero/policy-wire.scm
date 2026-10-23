;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/monero/policy-wire.scm — the wallet policy across a process boundary
;;;
;;; The wallet and its spend policy live in their own process
;;; (server/wallet-service.scm); the gateway holds the policy through OCapN.
;;; CapTP carries Syrup, and Syrup carries strings, symbols, numbers,
;;; booleans and proper lists — it refuses a dotted pair, so every alist the
;;; policy speaks (JSON-RPC results, transfer destinations, stats) and the
;;; <balance-info> record stop at the wire.
;;;
;;; Two actors close the gap, one on each side, and every caller keeps the
;;; policy's own vocabulary:
;;;
;;;   wallet process                          gateway process
;;;   ^wallet-policy ◄─$─ ^wallet-policy-wire ◄═ OCapN ═ ^wallet-policy-client ◄─ callers
;;;
;;; A value crosses as ONE string: its `write` form, read back on the far
;;; side and checked to be plain data. A <balance-info> crosses as a tagged
;;; list and is rebuilt. The wire facet answers a fixed list of methods —
;;; the spend and read surface — so the policy's rewiring methods and its raw
;;; record stay inside the wallet process.

(define-module (playnet monero policy-wire)
  #:use-module (goblins)
  #:use-module (playnet monero wallet)
  #:use-module (srfi srfi-1)
  #:export (wire-encode
            wire-decode
            %wire-methods
            ^wallet-policy-wire
            ^wallet-policy-client))

;;; ── The codec ─────────────────────────────────────────────────────────────

(define %balance-info-tag '%balance-info)

;; A method that answers nothing (revoke-invoice, revoke-swap-deposit) still
;; has to get its answer across: the facet encodes inside the policy's turn,
;; and an error there unwinds the turn — the revocation with it.
(define %unspecified-tag '%unspecified)

(define (datum->plain v)
  "V with every <balance-info> replaced by its tagged list. Signals an
error on a value `write`/`read` would not carry faithfully."
  (cond
   ((balance-info? v)
    (list %balance-info-tag
          (balance-info-atomic v)
          (balance-info-unlocked-atomic v)
          (balance-info-blocks-to-unlock v)))
   ((unspecified? v) (list %unspecified-tag))
   ((pair? v) (cons (datum->plain (car v)) (datum->plain (cdr v))))
   ((vector? v) (vector-map datum->plain v))
   ((or (null? v) (string? v) (symbol? v) (number? v) (boolean? v)) v)
   (else (error "policy-wire: value cannot cross the wire" v))))

(define (vector-map f v)
  (list->vector (map f (vector->list v))))

(define (plain->datum v)
  "The inverse of datum->plain. Anything but plain data is refused: the
string came from another process."
  (cond
   ((and (pair? v) (eq? (car v) %balance-info-tag))
    (if (and (list? v) (= (length v) 4) (every integer? (cdr v)))
        (apply make-balance-info (cdr v))
        (error "policy-wire: malformed balance-info on the wire")))
   ((equal? v (list %unspecified-tag)) (if #f #f))
   ((pair? v) (cons (plain->datum (car v)) (plain->datum (cdr v))))
   ((vector? v) (vector-map plain->datum v))
   ((or (null? v) (string? v) (symbol? v) (number? v) (boolean? v)) v)
   (else (error "policy-wire: unexpected value on the wire"))))

(define (wire-encode v)
  "V as the one string that crosses the wire."
  (call-with-output-string
    (lambda (port) (write (datum->plain v) port))))

(define (wire-decode s)
  "The value a wire string carries."
  (unless (string? s)
    (error "policy-wire: a wire value is a string"))
  (call-with-input-string s
    (lambda (port)
      (let* ((v (read port))
             (rest (read port)))
        (unless (eof-object? rest)
          (error "policy-wire: a wire string holds one datum"))
        (plain->datum v)))))

;;; ── The two actors ────────────────────────────────────────────────────────

;; The policy's spend and read surface. Rewiring (`rewire`, `rewire-audit`,
;; `rewire-credential-check`) and the raw `policy` record are the wallet
;; process's own business.
(define %wire-methods
  '(get-balance get-address get-outgoing get-incoming stats
    transfer reserve-budget
    authorize-invoice revoke-invoice
    authorize-swap-deposit revoke-swap-deposit))

(define (^wallet-policy-wire bcom policy)
  "The facet the wallet process registers with OCapN. POLICY is a
^wallet-policy in the same vat. Arguments arrive as wire strings; the
result leaves as one."
  (lambda (method . wire-args)
    (unless (memq method %wire-methods)
      (error "wallet-policy-wire: no such method on the wire" method))
    (wire-encode (apply $ policy method (map wire-decode wire-args)))))

(define (^wallet-policy-client bcom current-remote)
  "The gateway's stand-in for the policy. CURRENT-REMOTE is a thunk that
returns the ^wallet-policy-wire to address right now (a ref, or a promise
for one), or #f while there is none. It is asked on every call: the wallet
process takes a fresh identity each time it starts, so the facet a caller
reaches is the one the wallet last announced, never one from a run that
has ended. A call returns a promise for the decoded result, so
`(<- client 'get-balance)` resolves to a <balance-info> as it always did."
  (lambda (method . args)
    (let ((remote (current-remote)))
      (unless remote
        (error "wallet-policy-client: the wallet service has announced no policy"))
      (on (apply <- remote method (map wire-encode args))
          wire-decode
          #:promise? #t))))
