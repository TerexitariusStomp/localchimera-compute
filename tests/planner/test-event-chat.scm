;;; test-event-chat.scm — topic chats: the stratum ladder, stamped at post.
;;;
;;; The four levels are facts the plan already holds; the chat resolves them
;;; at post time and STAMPS them, so history preserves what the author WAS
;;; when they spoke. The ladder is walked here entirely through public
;;; service methods:
;;;
;;;   public     a scope member with no standing speaks
;;;   willing    express-willingness for the intent's (skill, cell)
;;;   committed  accept-assignment (or a journey's commitment)
;;;   satisfied  the journey's dropoff fulfills it
;;;
;;; Filters are read-side: the server hands the truth, clients select.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-event-chat.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (playnet planner vf schemas))
(use-modules (playnet planner doors service))
(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

;; isolated chat files (the registry reads PLAYNET_DATA_DIR at spawn)
(define tmp (string-append "/tmp/playnet-chat-test-" (number->string (getpid))))
(setenv "PLAYNET_DATA_DIR" tmp)

(display "\n── Setup: scope + planner service ──\n")
(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Chat Test"))
    store))

(with-vat vat
  (define svc (spawn ^planner-service (hashmap-set (hashmap) "org:test" scope)))
  (define ps ($ scope 'plan-store))

  ;; a plannable thing: care wanted at the clinic
  ($ ps 'add-intent
     (make-intent #:id "i-care" #:action 'work #:name "care" #:resource-conforms-to "doctor" #:resource-classified-as '() #:effort-quantity (make-measure 4 %effort-unit)
                  #:has-beginning "2026-06-08T09:00:00Z"
                  #:at-location "clinic" #:in-scope-of '("org:test")))

  ;; ── the ladder, on topic "i-care" ─────────────────────────────────────
  (define m1 ($ svc 'chat-post "org:test" "i-care" "bob" "what does this involve?"))
  (check "post returns ok" (car m1) 'ok)
  (check "a bystander speaks as public" (assq-ref (cdr m1) 'stratum) "public")

  ($ svc 'express-willingness "org:test" "ana" "doctor" "clinic@0" #t)
  (define m2 ($ svc 'chat-post "org:test" "i-care" "ana" "i could take this"))
  (check "willingness speaks as willing" (assq-ref (cdr m2) 'stratum) "willing")

  (define acc ($ svc 'accept-assignment "org:test" "i-care" "ana"))
  (check "accept-assignment ok" (car acc) 'ok)
  (define m3 ($ svc 'chat-post "org:test" "i-care" "ana" "on my way"))
  (check "a commitment speaks as committed" (assq-ref (cdr m3) 'stratum) "committed")

  ;; ── committed → satisfied, on a journey's own topic ──────────────────
  (define jb ($ svc 'journey-begin "org:test" "ana" "depot" "clinic" "pedestrian"))
  (define cid (assq-ref (cdr jb) 'commitment))
  (define j1 ($ svc 'chat-post "org:test" cid "ana" "departing"))
  (check "journey author speaks as committed" (assq-ref (cdr j1) 'stratum) "committed")
  (sleep 1)
  ($ svc 'journey-end "org:test" "ana" cid "depot" "clinic" "pedestrian")
  (define j2 ($ svc 'chat-post "org:test" cid "ana"
                 "arrived — note: bring gloves next time" "note"))
  (check "a fulfilled author speaks as satisfied" (assq-ref (cdr j2) 'stratum) "satisfied")
  (check "voice-note kind carried" (assq-ref (cdr j2) 'kind) "note")

  ;; ── history: order + stamped strata survive the round trip ───────────
  (define h ($ svc 'chat-history "org:test" "i-care"))
  (check "history ok" (car h) 'ok)
  (define msgs (vector->list (cdr h)))
  (check "three messages on the intent" (length msgs) 3)
  (check "strata preserved in order — the conversation's arc"
         (map (lambda (m) (assq-ref m 'stratum)) msgs)
         '("public" "willing" "committed"))

  ;; ── the walkie: a scope-wide channel is just a topic; notes are public ─
  ;; (no plannable thing behind "walkie:…", so relation-of honestly says public)
  (define w1 ($ svc 'chat-post "org:test" "walkie:org:test" "sam"
                 "east rows need water by noon" "note"))
  (check "walkie note posts as public" (assq-ref (cdr w1) 'stratum) "public")
  (check "walkie note carries the transcript kind" (assq-ref (cdr w1) 'kind) "note")
  (check "the channel is isolated from event topics"
         (length (vector->list (cdr ($ svc 'chat-history "org:test" "walkie:org:test"))))
         1)

  ;; ── live watch registers cleanly; delivery rides the standard <-np push
  ;; rail (the same one presence-update / new-message use — async by nature,
  ;; so not asserted synchronously here). What we lock: registration succeeds
  ;; and a watched topic still serves history alongside the live channel.
  (define inbox
    (spawn (lambda (_bcom)
             (methods ((chat-message topic msg) 'noted)))))
  (define wok ($ svc 'chat-watch "org:test" "walkie:org:test" inbox))
  (check "chat-watch registers without error" (car wok) 'ok)
  ($ svc 'chat-post "org:test" "walkie:org:test" "ana" "on it, taking the truck" "note")
  (check "the watched channel still accrues history"
         (length (vector->list (cdr ($ svc 'chat-history "org:test" "walkie:org:test"))))
         2)

  ;; ── read-side filtering is pure selection over stamped truth ─────────
  (check "a committed+satisfied filter selects exactly the committed post"
         (length (filter (lambda (m) (member (assq-ref m 'stratum)
                                             '("committed" "satisfied")))
                         msgs))
         1)
  (check "topics are isolated"
         (length (vector->list (cdr ($ svc 'chat-history "org:test" cid))))
         2)

  ;; ── chat-last: the WAKE's read ───────────────────────────────────────
  ;; docs/planning/faces/meeting-station.md Layer 2. The wake is an index over EVERY
  ;; live room at once, so it asks for the last line of many topics in ONE
  ;; call — a round trip per room is the cost that would make "all rooms
  ;; legible at all times" impractical, which is the whole point of the layer.
  (define lastv ($ svc 'chat-last "org:test"
                    (vector "i-care" "walkie:org:test" "never-spoken")))
  (check "chat-last ok" (car lastv) 'ok)
  (define lasts (cdr lastv))

  (check "one entry per topic that has been spoken on" (length lasts) 2)
  (check "a topic with nothing said is simply absent — not an empty row"
         (assoc-ref lasts "never-spoken") #f)

  ;; the LAST line, not the first: the wake shows what a room is saying NOW
  (check "the intent's last line is the most recent one"
         (list-ref (assoc-ref lasts "i-care") 1) "on my way")
  (check "…and carries its author" (list-ref (assoc-ref lasts "i-care") 0) "ana")
  (check "the channel's last line is its most recent too"
         (list-ref (assoc-ref lasts "walkie:org:test") 1) "on it, taking the truck")

  ;; kind rides along so the wake can mark a spoken line as spoken
  (check "the kind rides along, so a transcript reads as one"
         (list-ref (assoc-ref lasts "walkie:org:test") 2) "note")

  ;; a transcript segment is an ordinary message of kind "transcript" — the
  ;; edge transcriber posts these (app/walkie-transcript.js), and the wake
  ;; shows the newest without knowing anything about speech
  ($ svc 'chat-post "org:test" "walkie:org:test" "sam" "the van is booked" "transcript")
  (define lastv2 ($ svc 'chat-last "org:test" (vector "walkie:org:test")))
  (check "a transcript segment becomes the room's current utterance"
         (list-ref (assoc-ref (cdr lastv2) "walkie:org:test") 1) "the van is booked")
  (check "…and is marked as a transcript"
         (list-ref (assoc-ref (cdr lastv2) "walkie:org:test") 2) "transcript")

  ;; a list works as well as a vector: the wire may hand over either
  (check "chat-last accepts a plain list of topics"
         (car ($ svc 'chat-last "org:test" (list "i-care"))) 'ok)
) ;; end with-vat

(system* "rm" "-rf" tmp)
(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
