;;; module/playnet/planner/doors/service/chat.scm — topic chats, stratum-stamped. GENERIC.
;;;
;;; A chat hangs off a TOPIC — any string a host cares to name: an Intent or
;;; Commitment id, a place, a recipe, a scope-wide walkie channel. The
;;; registry neither knows nor cares what the topic denotes; it stores,
;;; replays, and notifies. Each message carries a STRATUM — the author's
;;; standing toward the topic at the moment of speaking — but resolving that
;;; standing is the CALLER's domain knowledge, passed in already-resolved.
;;; History thus preserves what the author WAS when they spoke, and filters
;;; are pure read-side selection.
;;;
;;; The first resolver (and first use case) lives below: `relation-of` reads
;;; a plannable thing's ladder straight from the plan —
;;;
;;;   public     anyone in the scope
;;;   willing    willingness expressed for the intent's (skill, cell)
;;;   committed  holds a Commitment (by id, or satisfying the intent)
;;;   satisfied  one of the author's events fulfills that commitment
;;;
;;; Other hosts bring their own resolvers (or `(const 'public)`).
;;;
;;; Storage is the gateway's house style for durable queues (pending-grants,
;;; oobi-host): append-only sexp files, one message per sexp, under
;;; <data-dir>/chats/<sanitized topic> — restart-safe with no
;;; persistence-registry coupling. Watchers are session-lived OCapN
;;; callbacks, notified on every post.

(define-module (playnet planner doors service chat)
  #:use-module (goblins)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 textual-ports)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner formulas actions)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet planner scope live) #:select (willing-tuples time->period))
  #:export (^chat-registry relation-of))

;;; ── the generic registry ─────────────────────────────────────────────

(define (sanitize s)
  (string-map (lambda (c)
                (if (or (char-alphabetic? c) (char-numeric? c)
                        (memv c '(#\- #\_ #\.)))
                    c #\_))
              (or s "_")))

(define (chat-file data-dir topic)
  (string-append data-dir "/chats/" (sanitize topic) ".scm"))

(define (append-msg! path msg)
  (let ((dir (dirname path)))
    (unless (file-exists? dir) (system* "mkdir" "-p" dir)))
  (call-with-port (open-file path "a")
    (lambda (p) (write msg p) (newline p))))

(define (read-msgs path)
  (if (not (file-exists? path)) '()
      (call-with-input-file path
        (lambda (p)
          (let loop ((acc '()))
            (let ((m (read p)))
              (if (eof-object? m) (reverse acc) (loop (cons m acc)))))))))

;; The LAST message alone, without parsing the history to reach it.
;;
;; `append-msg!` writes one `write` + newline per message, and `write` escapes
;; newlines inside strings, so the file is strictly one message per line. That
;; makes the tail readable on its own: seek near the end, keep the last
;; complete line, read that. Cost is constant in the length of the
;; conversation — which is what lets the wake ask every live room at once
;; while those same rooms are transcribing themselves into these files.
(define %tail-window 8192)

(define (read-last-msg path)
  (and (file-exists? path)
       (let* ((size (stat:size (stat path)))
              (from (max 0 (- size %tail-window))))
         (call-with-input-file path
           (lambda (p)
             (when (> from 0) (seek p from SEEK_SET))
             (let* ((text (get-string-all p))
                    (lines (filter (lambda (l) (not (string-null? l)))
                                   (string-split text #\newline))))
               (and (pair? lines)
                    (catch #t
                      (lambda ()
                        (let ((m (call-with-input-string (car (last-pair lines)) read)))
                          (and (pair? m) m)))
                      ;; a truncated first line (we seeked into the middle of
                      ;; one) or any partial write reads as "no last message"
                      ;; rather than taking the file down
                      (lambda _ #f)))))))))

(define-actor (^chat-registry bcom data-dir watchers)
  (methods
   ;; POST: stratum arrives RESOLVED — the caller owns that domain
   ;; knowledge. Persist, notify session watchers, return the message.
   ((post topic aid body kind stratum)
    ;; epoch-seconds + author collided for two messages in one second
    ;; (a voice-transcript burst) — storage is append-only so both lines
    ;; survived, but every id-keyed reader conflated them; a random tail
    ;; keeps the id shape and breaks the tie
    (let ((msg `((id      . ,(string-append "m-" (number->string (instant->unix (clock-now)))
                                            "-" (sanitize aid) "-"
                                            (number->string (random 1000000))))
                 (author  . ,aid)
                 (body    . ,body)
                 (kind    . ,kind)            ; "text" | "note" (voice transcript) | …
                 (stratum . ,(if (symbol? stratum) (symbol->string stratum) stratum))
                 (t       . ,(instant->unix (clock-now))))))
      (append-msg! (chat-file data-dir topic) msg)
      ;; watchers are inbox-shaped actors: deliver as a chat-message with the
      ;; topic (one inbox may watch several), so a receiver can route it.
      (for-each (lambda (cb) (<-np cb 'chat-message topic msg))
                (or (assoc-ref watchers topic) '()))
      msg))
   ;; HISTORY: every message since T (epoch seconds; 0 = all). Stratum
   ;; filtering is the client's read-side choice — the server hands the truth.
   ((history topic since)
    (filter (lambda (m) (>= (or (assq-ref m 't) 0) since))
            (read-msgs (chat-file data-dir topic))))
   ;; the newest line of a topic, read from the tail — what the wake asks of
   ;; every live room at once (docs/planning/faces/meeting-station.md, Layer 2)
   ((last topic) (read-last-msg (chat-file data-dir topic)))
   ;; WATCH: live messages to an OCapN callback, for this session.
   ((watch topic cb)
    (bcom (^chat-registry bcom data-dir
                          (cons (cons topic (cons cb (or (assoc-ref watchers topic) '())))
                                (alist-delete topic watchers)))))))

;;; ── the first resolver: a plannable thing's ladder ───────────────────

(define (intent-cell i)
  "The (place @ period) cell willingness is keyed by — same construction
   as the snapshot's (service.scm)."
  (string-append (or (intent-at-location i) "")
                 "@" (number->string (time->period (intent-has-beginning i)))))

(define (relation-of scope-root vf-id aid)
  "The author's HIGHEST standing toward the plannable thing VF-ID, as the
   plan knows it: satisfied ⊃ committed ⊃ willing ⊃ public."
  (let* ((ps     ($ scope-root 'plan-store))
         (obs    ($ scope-root 'observer))
         (intent (find (lambda (i) (equal? (intent-id i) vf-id))
                       ($ ps 'all-intents)))
         ;; a journey's two commitments, its departure and its arrival, are one
         ;; undertaking: the trip they share is the thing the topic names
         (trip   (let ((c (find (lambda (c) (and (equal? (commitment-id c) vf-id)
                                                 (relocating-action? (commitment-action c))))
                                ($ ps 'all-commitments))))
                   (and c (or (commitment-input-of c) (commitment-output-of c)))))
         ;; the author's commitments tied to this thing: by id, satisfying the
         ;; intent, or the other end of its trip
         (mine (filter (lambda (c)
                         (and (equal? (commitment-provider c) aid)
                              (or (equal? (commitment-id c) vf-id)
                                  (equal? (commitment-satisfies c) vf-id)
                                  (and trip (relocating-action? (commitment-action c))
                                       (equal? trip (or (commitment-input-of c) (commitment-output-of c)))))))
                       ($ ps 'all-commitments)))
         (mine-ids (map commitment-id mine)))
    (cond
     ;; satisfied: one of the author's own events COMPLETES their commitment —
     ;; it must carry a completion timestamp (has-end, or point-in-time for
     ;; recorded work). A journey's pickup also `fulfills`, but departing
     ;; isn't arriving.
     ((and (pair? mine)
           (any (lambda (e) (and (member (economic-event-fulfills e) mine-ids)
                                 (or (economic-event-has-end e)
                                     (economic-event-has-point-in-time e))))
                ($ obs 'events-for-agent aid)))
      'satisfied)
     ((pair? mine) 'committed)
     ;; willing: the author's willingness covers the intent's (skill, cell)
     ((and intent
           (let ((skill (intent-resource-conforms-to intent))
                 (cell  (intent-cell intent)))
             (any (lambda (t) (and (equal? (first t) aid)
                                   (equal? (second t) skill)
                                   (equal? (third t) cell)))
                  (willing-tuples ps))))
      'willing)
     (else 'public))))
