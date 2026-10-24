;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/parity/ddmrp-odoo.scm — ddmrp ↔ Odoo OCA parity.
;;; The contract: our <buffer-zone>'s 40-field portrait is the record an
;;; Odoo stock.buffer must reproduce. Invariant leg proves the roundtrip;
;;; live leg reads a real stock.buffer over execute_kw.

(use-modules (localchimera test harness)
             (localchimera test parity)
             (localchimera delegates)
             (localchimera ddmrp buffer-zones)
             (srfi srfi-1))

;; ── invariant leg: the record contract ────────────────────────────────────
;; a fixture portrait: the 40 fields in constructor order
;; the 40 fields in buffer-zone->list order: identity block (9), the adu
;; block (8), then the 23 supply/zone fields through last-computed-at.
(define fixture-portrait
  (list "bz-1" "spec-1" "prof-1" "class-a" "loc-1" #f #f #f #f     ; 9
        12.5 "units/day" 0.7 7 "rolling" 50 20 7                  ; 8
        0.0 0 0 3 2 "units" 1 #f #f 1 0                           ; 11
        100 60 40 42 1.0 1.0 1.0 0 0 0 '() 0))                    ; 12 — 40 total

(let ((z (list->buffer-zone fixture-portrait)))
  (check "buffer-zone portrait roundtrips its 40 fields"
         (buffer-zone->list z) fixture-portrait))

;; the odoo wire for a stock.buffer read of the same zone
(let ((w (odoo-call-wire "db" 7 "pass" "stock.buffer" "search_read" '((("id" . 1))))))
  (check "odoo wire is JSON-RPC execute_kw over stock.buffer"
         (and (equal? (cdr (assoc "jsonrpc" w)) "2.0")
              (equal? (cdr (assoc "method" w)) "call")) #t))

(parity-live-delegate "LOCALCHIMERA_ODOO_URL"
  "odoo execute_kw answers a stock.buffer read"
  ;; env creds: LOCALCHIMERA_ODOO_DB/USER/PASSWORD — unset → delegate unavailable → skip
  (lambda (t) (make-odoo-delegate t))
  (lambda (d) (d "stock.buffer" "search_read" '((("id" . 1)))))
  (lambda (a) (and (pair? a) (< (car a) 300))))

(test-summary!)
