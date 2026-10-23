;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/gateway/test-allotment.scm — the week's unplanned photo reads
;;; (module/playnet/gateway/allotment.scm; docs/observation/capture.md §5).
;;;
;;; What this pins:
;;;   • a week opens on Monday 00:00 UTC, whole;
;;;   • a read spends one, and the week's last read leaves none;
;;;   • a week with none left spends no further, and what is left is never
;;;     below nothing;
;;;   • a standing kept in another week, never kept, or unreadable says
;;;     nothing of this one;
;;;   • a read given back is one more, and never more than the week began with.
;;;
;;; Run: tools/test/own-ccache.sh guile --no-auto-compile -q -L module tests/gateway/test-allotment.scm

(add-to-load-path "module")
(use-modules (playnet test harness)
             (playnet gateway allotment)
             (srfi srfi-1))

(display "\n── 1. the week ──\n")

;; Monday 2026-09-28 00:00:00 UTC
(define monday 1790553600)
(define w (allotment-week monday))
(check "a week opens on Monday at midnight" (week-opens w) monday)
(check "the second before is the week before" (allotment-week (- monday 1)) (- w 1))
(check "Sunday night is the same week" (allotment-week (+ monday (* 7 86400) -1)) w)
(check "the Monday after is the week after" (allotment-week (+ monday (* 7 86400))) (+ w 1))
(check "a clock reading with a fraction falls in its week" (allotment-week (+ monday 0.5)) w)
(check-pred "every week opens a week after the last"
            (every (lambda (k) (= (* 7 86400) (- (week-opens (+ k 1)) (week-opens k))))
                   (iota 5 w)))

(display "\n── 2. spending ──\n")

(check "a week opens whole" (allotment-remaining '() w 21) 21)
(define one (allotment-spend '() w 21))
(check "a read spends one" (allotment-remaining one w 21) 20)
(define spent
  (let loop ((doc '()) (n 0))
    (if (= n 21) doc (loop (allotment-spend doc w 21) (+ n 1)))))
(check "the week's last read leaves none" (allotment-remaining spent w 21) 0)
(check "a week with none left spends no further" (allotment-spend spent w 21) #f)
(check "what is left is never below nothing"
       (allotment-remaining (allotment-doc w 40) w 21) 0)
(check "an allotment of nothing spends nothing" (allotment-spend '() w 0) #f)
(check-pred "the default is three a day"
            (= %allotment-per-week 21))

(display "\n── 3. another week ──\n")

(check "a standing kept last week says nothing of this one"
       (allotment-remaining spent (+ w 1) 21) 21)
(check "spending in a new week starts from the whole"
       (allotment-remaining (allotment-spend spent (+ w 1) 21) (+ w 1) 21) 20)
(check "a standing never kept opens whole" (allotment-remaining #f w 21) 21)
(check "a standing that is no standing opens whole"
       (allotment-remaining '((week . "x") (used . -3)) w 21) 21)
(check "…and so does one that is not even a list" (allotment-remaining "garbage" w 21) 21)

(display "\n── 4. a read given back ──\n")

(check "a read given back is one more" (allotment-remaining (allotment-refund one w) w 21) 21)
(check "a week that spent nothing has nothing to give back"
       (allotment-remaining (allotment-refund '() w) w 21) 21)
(check "a read given back in the last week's standing opens this week whole"
       (allotment-remaining (allotment-refund spent (+ w 1)) (+ w 1) 21) 21)

(test-summary!)
