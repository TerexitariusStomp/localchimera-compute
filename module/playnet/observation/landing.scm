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
  #:use-module ((playnet utils keyed-id) #:select (keyed-id))
  #:export (standing-event land-once tap-event-id tap?))

(define (standing-event obs id)
  "The event the books hold under ID, or #f."
  (and (string? id) ($ obs 'get-event id)))

;; A KEYED act (a door declared `#:keyed`, doors/protocol.scm) is named by the thing
;; it acts on and the token its caller minted for this one act, so a repeat of the
;; request names the event that already stands. The prefix cannot meet the
;; numbered ids (`ev-<cid>-<n>`), and a token is the plain characters a URL keeps.
(define (tap? token)
  "TOKEN is a well-formed key: 1 to 64 of letters, digits, `_` and `-`. (No srfi-13:
   this module is in the page's scope bundle.)"
  (and (string? token)
       (<= 1 (string-length token) 64)
       (let loop ((i 0))
         (or (= i (string-length token))
             (let ((c (string-ref token i)))
               (and (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9)
                        (char=? c #\_) (char=? c #\-))
                    (loop (+ i 1))))))))

(define (tap-event-id subject token)
  "The id of the event the act keyed by TOKEN leaves on SUBJECT (a commitment id)."
  (keyed-id "ev-tap" subject token))

(define (land-once obs witness replay land!)
  "The act, landed once. WITNESS is an event id the act always leaves behind (#f
   where the act has no name of its own to repeat under). When the books hold it,
   the act has landed: REPLAY, given that event, answers. Otherwise LAND! lands
   the act and answers."
  (let ((standing (standing-event obs witness)))
    (if standing (replay standing) (land!))))
