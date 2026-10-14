;;; module/playnet/doors/planner/chat.scm — topic chats: what is said under a scope, stratum-stamped, and the wake over many topics
;;;
;;; A fragment of the planner service (playnet doors service): a procedure from
;;; the service's context to the doors it serves, composed into every service by
;;; doors/service.scm. `with-planner-ctx` binds the context's fields under their
;;; own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §12). What this fragment alone reads and
;;; writes is defined here, above its doors: the chat registry, one per service.
;;;
;;; A chat hangs off a TOPIC — any string a host cares to name: an Intent or
;;; Commitment id, a place, a recipe, a scope-wide walkie channel. The
;;; registry neither knows nor cares what the topic denotes; it stores,
;;; replays, and notifies. Each message carries a STRATUM — the author's
;;; standing toward the topic at the moment of speaking — but resolving that
;;; standing is the CALLER's domain knowledge, passed in already-resolved.
;;; History thus preserves what the author WAS when they spoke, and filters
;;; are pure read-side selection. `relation-of` reads a plannable thing's
;;; ladder straight from the plan —
;;;
;;;   public     anyone in the scope
;;;   willing    willingness expressed for the intent's (skill, cell)
;;;   committed  holds a Commitment (by id, or satisfying the intent)
;;;   satisfied  one of the author's events fulfills that commitment
;;;
;;; Storage is the gateway's house style for durable queues (pending-grants,
;;; oobi-host): append-only sexp files, one message per sexp, under
;;; <data-dir>/chats/<sanitized topic> — restart-safe with no
;;; persistence-registry coupling. Watchers are session-lived OCapN
;;; callbacks, notified on every post.

(define-module (playnet doors planner chat)
  #:use-module ((goblins actor-lib methods) #:select (methods))
  #:use-module ((goblins) #:select ($ <-np define-actor spawn))   ; spawn: the actor's, not the core's process spawn
  #:use-module ((ice-9 textual-ports) #:select (get-string-all))
  #:use-module ((playnet scope live) #:select (time->period willing-tuples))
  #:use-module ((playnet vf facts located) #:select (cell))
  #:use-module ((playnet utils clock) #:select ((now . clock-now) instant->unix))
  #:use-module ((playnet utils paths) #:select (playnet-data-dir))
  #:use-module ((playnet vf formulas actions) #:select (relocating-action?))
  #:use-module ((playnet vf formulas flows) #:select (row-satisfies?))
  #:use-module ((playnet vf schemas) #:select (commitment-action commitment-id commitment-input-of commitment-output-of commitment-provider economic-event-fulfills economic-event-has-end economic-event-has-point-in-time intent-at-location intent-has-beginning intent-id intent-resource-conforms-to))
  #:use-module ((srfi srfi-1) #:select (alist-delete any filter-map find first last second third))
  #:use-module (playnet doors planner ctx)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (planner-chat-doors ^chat-registry relation-of))

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
  (cell (or (intent-at-location i) "") (time->period (intent-has-beginning i))))

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
                                  (row-satisfies? c vf-id)
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

(define (planner-chat-doors ctx)
  (with-planner-ctx ctx
    ;; event chats ride beside the scopes: append-only files under the same
    ;; data dir the gateway runs in; strata resolved from the plan at post time
    (define chat-reg
      ;; #:default keeps a bare `guile -L module` run writing to ./data — no
      ;; root, no /var/lib. A deployment exports PLAYNET_DATA_DIR and lands
      ;; in the same directory as every other component.
      (spawn ^chat-registry (playnet-data-dir #:default "data") '()))
    (declared-doors planner

      ;; ── Topic chats: generic store, plan-resolved strata ──────────────────
      ;; A topic is ANY string under the scope (an Intent/Commitment id is the
      ;; first use case; places, recipes, a walkie channel ride the same rail).
      ;; The author's stratum is resolved HERE — relation-of reads the plan when
      ;; the topic IS a plannable thing, and honestly says `public` otherwise —
      ;; then stamped; filtering is the client's read-side choice.

      ((chat-post scope-id topic aid body #:optional (message-kind #f))
       (scoped scope-id
         (lambda (root)
($ chat-reg 'post
                           (string-append scope-id "/" topic) aid body
                           (or message-kind "text")
                           (relation-of root topic aid)))))

      ((chat-history scope-id topic #:optional (since 0))
       (scoped scope-id
         (lambda (root)
(list->vector
                         ($ chat-reg 'history
                            (string-append scope-id "/" topic)
                            since)))))

      ;; THE WAKE (docs/planning/faces/meeting-station.md, Layer 2): the last line of
      ;; each of MANY topics, in one call. The wake is an index over every live
      ;; room at once, so a round trip per room is the thing to avoid — that cost
      ;; is what would make "all rooms legible at all times" impractical.
      ;; Returns an alist topic → (author body kind t); topics with nothing said
      ;; are simply absent.
      ((chat-last scope-id topics)
       (scoped scope-id
         (lambda (root)
                (filter-map
                 (lambda (topic)
                   ;; `last` reads the file's tail; the registry owns the format,
                   ;; so the wake never parses a conversation to see its newest
                   ;; line — the cost stays flat as a meeting transcribes itself.
                   (let ((last ($ chat-reg 'last (string-append scope-id "/" topic))))
                     (and last
                          (cons topic
                                (list (or (assq-ref last 'author) "")
                                      (or (assq-ref last 'body) "")
                                      (or (assq-ref last 'kind) "text")
                                      (or (assq-ref last 't) 0))))))
                 ;; the wire may hand us a vector or a list
                 (cond ((vector? topics) (vector->list topics))
                       ((list? topics) topics)
                       (else '()))))))

      ((chat-watch scope-id topic cb)
       (scoped scope-id
         (lambda (root)
($ chat-reg 'watch (string-append scope-id "/" topic) cb)
               #t))))))
