;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/gateway/test-mesh-mailbox.scm — ^mesh-mailbox: ciphertext custody
;;; for mesh deliveries to offline personas (LXMF step 3).
;;;
;;; Run: make test-mesh-mailbox

(use-modules (localchimera test harness)
             (localchimera gateway mesh-mailbox)
             (goblins)
             (ice-9 format))

(define vat (spawn-vat #:name "mesh-mailbox-test"))

(define %dir (string-append (or (getenv "TMPDIR") "/tmp")
                            "/mesh-mailbox-test-" (number->string (getpid))))

(define %dest "3b63bbe29fb347d0bc6ec2206528c5d8")

(format #t "=== ^mesh-mailbox ===~%")

(define box
  (with-vat vat (spawn ^mesh-mailbox #:durable-dir %dir #:cap 3)))

(check "empty box drains empty"
       (with-vat vat ($ box 'drain! %dest)) '())

(with-vat vat
  ($ box 'store! %dest "aa01")
  ($ box 'store! %dest "aa02"))

(check "count sees both" (with-vat vat ($ box 'count %dest)) 2)

(check "destinations lists the pending box"
       (with-vat vat ($ box 'destinations)) (list %dest))

(check "drain returns oldest-first and clears"
       (with-vat vat ($ box 'drain! %dest)) '("aa01" "aa02"))

(check "drained box is empty" (with-vat vat ($ box 'count %dest)) 0)

;; Cap: oldest entries drop.
(with-vat vat
  ($ box 'store! %dest "m1") ($ box 'store! %dest "m2")
  ($ box 'store! %dest "m3") ($ box 'store! %dest "m4"))

(check "cap drops oldest (3 of 4 survive)"
       (with-vat vat ($ box 'drain! %dest)) '("m2" "m3" "m4"))

;; Durability: a fresh spawn from the same dir sees pending mail.
(with-vat vat ($ box 'store! %dest "persisted"))

(define box2 (with-vat vat (mesh-mailbox-spawn-from-dir %dir)))

(check "respawn from dir restores pending mail"
       (with-vat vat ($ box2 'drain! %dest)) '("persisted"))

;; TTL: entries older than the ttl sweep on access.
(define stale-box
  (with-vat vat (spawn ^mesh-mailbox #:ttl 0)))
(with-vat vat ($ stale-box 'store! %dest "too-old"))
(check "ttl 0 sweeps everything"
       (with-vat vat ($ stale-box 'drain! %dest)) '())

;; cleanup
(system* "rm" "-rf" %dir)

(test-summary!)
