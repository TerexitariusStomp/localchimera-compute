;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-keyed-id.scm — the id that names what a record is (module/playnet/utils/keyed-id.scm).
;;;
;;; Run: guile --no-auto-compile -q -L module tests/utils/test-keyed-id.scm

(use-modules (playnet test harness)
             (playnet utils keyed-id))

(check "the kind and parts joined by |"
       (keyed-id "claim" "water" "alice" "A" "2026-10-02") "claim|water|alice|A|2026-10-02")
(check "an absent part is an empty field, so positions never shift"
       (keyed-id "flow" "move" "water" #f "d" #f) "flow|move|water||d|")
(check "a symbol part is its name"
       (keyed-id "mc" 'move "water") "mc|move|water")
(check "equal terms give equal ids"
       (equal? (keyed-id "wc" "need-1" "offer-2") (keyed-id "wc" "need-1" "offer-2")) #t)
(check "terms that differ in one field give different ids"
       (equal? (keyed-id "wc" "need-1" "offer-2") (keyed-id "wc" "need-1" "offer-3")) #f)

(test-summary!)
