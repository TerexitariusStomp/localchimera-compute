;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/gateway/allotment.scm — the week's unplanned photo reads
;;;
;;; A count the plan asked for draws on the plan: the commitment is the
;;; authority, and the model call its photo read makes is part of the run. A
;;; count nobody planned is the person's own initiative, and the photo read is
;;; the one technique among the three with a cost beyond the person's own
;;; minutes (docs/observation/capture.md §5). So the unplanned photo read is
;;; rationed: a number of reads a person a week, the week being the period so
;;; that someone bringing a kitchen in spends a sitting's worth at once.
;;;
;;; One number bounds two things: the model's service the commons pays for,
;;; and the confirmation each new registration asks of the scope.
;;;
;;; The standing of one person is two integers, the week and what that week
;;; has spent, kept in the person's own file (doors/lobby.scm). This module is the
;;; arithmetic, pure over those integers and a clock reading.

(define-module (playnet gateway allotment)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils clock) #:select (epoch->civil))
  #:export (%allotment-per-week allotment-week week-opens
            allotment-doc allotment-used allotment-remaining
            allotment-spend allotment-refund allotment-reply))

;; reads a person a week; the deployment's to set
(define %allotment-per-week
  (let ((n (and=> (getenv "PLAYNET_PHOTO_ALLOTMENT") string->number)))
    (if (and (integer? n) (>= n 0)) (inexact->exact n) 21)))

(define %week 604800)
;; the epoch opened on a Thursday; three days on, the weeks open on Mondays
(define %monday-offset (* 3 86400))

(define (allotment-week unix)
  "The week UNIX (epoch seconds) falls in, as a count of weeks that open at
   Monday 00:00 UTC."
  (quotient (+ (inexact->exact (floor unix)) %monday-offset) %week))

(define (week-opens week)
  "The epoch second WEEK opens at."
  (- (* week %week) %monday-offset))

(define (allotment-doc week used)
  "A person's standing, as it is kept."
  `((week . ,week) (used . ,used)))

(define (allotment-used doc week)
  "What DOC says WEEK has spent. A standing kept in another week, or never
   kept, or unreadable, says nothing of this one: the week opens whole."
  (let ((w (and (pair? doc) (assq-ref doc 'week)))
        (u (and (pair? doc) (assq-ref doc 'used))))
    (if (and (integer? w) (= w week) (integer? u) (>= u 0)) u 0)))

(define* (allotment-remaining doc week #:optional (per-week %allotment-per-week))
  (max 0 (- per-week (allotment-used doc week))))

(define* (allotment-spend doc week #:optional (per-week %allotment-per-week))
  "DOC with one read of WEEK spent, or #f when the week has none left."
  (let ((used (allotment-used doc week)))
    (and (< used per-week)
         (allotment-doc week (+ used 1)))))

(define (allotment-refund doc week)
  "DOC with one read of WEEK given back: a read the model never answered
   was never had."
  (allotment-doc week (max 0 (- (allotment-used doc week) 1))))

(define (allotment-reply doc week sees?)
  "What the allotment door answers of a standing DOC in WEEK: the reads that
   remain, of how many, the instant the week opens again, and whether a picture
   can be read here (SEES?)."
  `((remaining . ,(allotment-remaining doc week))
    (per-week . ,%allotment-per-week)
    (opens . ,(epoch->civil (week-opens (+ week 1))))
    (sees? . ,(and sees? #t))))
