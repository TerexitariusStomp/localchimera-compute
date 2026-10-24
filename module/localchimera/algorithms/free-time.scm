;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; algorithms/free-time.scm — the one arithmetic of free time.
;;;
;;; Free time is the share of the time offered that is not planned:
;;; f = 1 − hours/capacity. It is read three places, each over its own hours:
;;; the solved plan's placed hours over what its people offer
;;; (solve/report.scm), the validated hours of a scope tree over N·T
;;; (elastic.scm), and a household's declared hours over its members' time
;;; (account.scm). One function states it, so the three agree where they meet:
;;; at no capacity there is no time and none of it is free.
;;;
;;; Pure and small on purpose: the solve imports it, and the solve carries no
;;; actors.

(define-module (localchimera algorithms free-time)
  #:export (free-time-fraction))

(define (free-time-fraction hours capacity)
  "The fraction of CAPACITY hours left once HOURS are planned, in [0,1]; 0
   when there is no capacity, so no time and none of it free."
  (if (> capacity 1e-9)
      (max 0 (min 1 (- 1 (/ hours capacity))))
      0))
