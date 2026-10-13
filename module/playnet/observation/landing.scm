;;; landing.scm — an act lands once: the books answer a repeat with what already stands.
;;;
;;; The observer's log is a set keyed by event id: told an event it already holds,
;;; it takes nothing (told a DIFFERENT event under that id, it refuses). So an act
;;; that is named by what it is (who, what, when, the figure found) is the same
;;; act wherever and however often it arrives: a device flushing its queue, a tap
;;; retried after a lost reply. What the door must add is the order: ask the
;;; books FIRST, before any derivation or refusal that could differ on a replay,
;;; and answer a repeat with what stands rather than with a second landing or an
;;; error. This is that one question, so the doors that name their acts (the count,
;;; the log, a confirmed row, an effort) ask it the same way.

(define-module (playnet observation landing)
  #:use-module ((goblins) #:select ($))
  #:export (standing-event land-once))

(define (standing-event obs id)
  "The event the books hold under ID, or #f."
  (and (string? id) ($ obs 'get-event id)))

(define (land-once obs witness replay land!)
  "The act, landed once. WITNESS is an event id the act always leaves behind (#f
   where the act has no name of its own to repeat under). When the books hold it,
   the act has landed: REPLAY, given that event, answers. Otherwise LAND! lands
   the act and answers."
  (let ((standing (standing-event obs witness)))
    (if standing (replay standing) (land!))))
