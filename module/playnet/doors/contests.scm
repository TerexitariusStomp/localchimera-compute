;;; module/playnet/doors/contests.scm — the contest doors of the governance service: work and counts contested, a worker's contrary observation against a figure
;;;
;;; A fragment of the governance service (playnet doors governance): a procedure
;;; from the actor's context to the doors it serves, composed into the service by
;;; (playnet boot governance). `with-governance-ctx` binds the actor's arguments,
;;; cells and shared helpers under their own names, so each clause reads as it did
;;; inside the actor (docs/planning/codebase-layout.md §5).

(define-module (playnet doors contests)
  #:use-module (srfi srfi-1)
  #:use-module (playnet credentials work)
  #:use-module (playnet keri acdc)
  #:use-module ((playnet observation evidence) #:select (tags-evidence))
  #:use-module ((playnet observation adjustment) #:select (count-event? count-event-of))
  #:use-module ((playnet vf formulas counting) #:select (count-base-id count-family-id? contest-ballot-id))
  #:use-module (playnet voice snapshot)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet personhood enrollment)
                #:select (spawn-enrollment-ceremony enroll-ceremony-for-candidate
                          enroll-asks expire-stale-enrollments! *self-request-evidence*
                          rehydrate-enrollment-ceremonies!))
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (playnet doors governance)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (governance-contests-doors))

(define (governance-contests-doors ctx)
  (with-governance-ctx ctx
    ;; the members of a scope, as AIDs, and what a contest lets one of them do:
    ;; `attach` a picture when the act is theirs, `vote` when they are in the
    ;; franchise (the roster less the worker), `none` otherwise
    (define (scope-roster root)
      (if root (map agent-id ($ ($ root 'agent-store) 'all-agents)) '()))
    (define (contest-role identity-key worker roster)
      (cond ((equal? identity-key worker) 'attach)
            ((member identity-key roster) 'vote)
            (else 'none)))
    ;; ── a contrary observation: a worker's witnessed reading against a figure ──
    ;; docs/planning/voice/feasibility-follows-the-map.md. Who may speak is the
    ;; worker the WITNESS names: a work event of theirs, in this scope's record,
    ;; on the very process the figure sits on — read off the observer, never
    ;; asserted. One live statement per (observer, scope, process, action); a
    ;; restatement supersedes. What it does to the solve is the planner's
    ;; law (engine/robust.scm observed-shocks): the cautious direction only.
    (define (build-contrary-observation identity-key scope-id process action spec nominal reading witness at)
      (let* ((obs (scope-observer scope-id))
             (act (and (or (symbol? action) (string? action)) (string->symbol (format #f "~a" action))))
             (ev  (and obs (string? witness) ($ obs 'get-event witness))))
        (unless obs (error "no such scope"))
        (unless (and (string? process) (not (string-null? process))) (error "name the process the figure sits on"))
        (unless (memq act '(produce consume use work)) (error "the figure's action is produce, consume, use or work"))   ; verb-meant: the door's own list of figures
        (unless (and (real? nominal) (> nominal 0.0)) (error "the map's figure is a positive number"))
        (unless (and (real? reading) (>= reading 0.0)) (error "the reading is a number, zero or more"))
        (unless ev (error "the witness is a work event of yours in this scope's record"))
        (unless (equal? identity-key (economic-event-provider ev)) (error "the witness names another worker"))
        (unless (equal? process (economic-event-input-of ev)) (error "the witness is a run of another process"))
        (make-contrary-observation-credential #:observer-aid identity-key
                                              #:scope-id scope-id
                                              #:process process
                                              #:action act
                                              #:spec spec
                                              #:nominal nominal
                                              #:reading reading
                                              #:witness witness
                                              #:observed-at at)))
    (define (revoke-prior-contrary-observations! observer scope-id process action)
      (when acdc-store
        (revoke-where! (standing-contrary-observations acdc-store scope-id observer)
                       (lambda (c) (and (equal? process (cred-claim c 'process))
                                        (equal? (format #f "~a" action) (format #f "~a" (cred-claim c 'action))))))))
    ;; a refusal in the door's own words when the error carried them, else the bare word
    (define (attest-refusal args)
      (if (and (pair? args) (string? (car args))) (car args) "refused"))

    (declared-doors governance

      ;; The contests open in SCOPE-ID, as they stand to IDENTITY-KEY: each with
      ;; the event it names, the member who contested and why, whose act it is,
      ;; and what IDENTITY-KEY may do about it — `attach` a picture when the act
      ;; is theirs, `vote` when they are in the franchise (the roster less the
      ;; worker), `none` otherwise.
      ((contests identity-key scope-id)
       (catch #t
         (lambda ()
           (let* ((root   (scope-root scope-id))
                  (roster (scope-roster root)))
             (list 'ok
                   (filter-map
                    (lambda (p)
                      (let* ((id (car p))
                             (c  (assq-ref ($ ballot-store 'meta id) 'contest)))
                        (and c (eq? 'open (cdr p)) (equal? scope-id (assq-ref c 'scope-id))
                             `((id . ,id)
                               (event-id . ,(assq-ref c 'event-id))
                               (kind . ,(or (assq-ref c 'kind) 'work))
                               (resource . ,(or (assq-ref c 'resource) ""))
                               (worker . ,(assq-ref c 'worker))
                               (by . ,(assq-ref c 'by))
                               (reason . ,(assq-ref c 'reason))
                               (role . ,(contest-role identity-key (assq-ref c 'worker) roster))))))
                    ($ ballot-store 'list-proposals)))))
         (lambda (_k . args) (list 'error (format #f "~a" args)))))

      ;; What a contested count lets IDENTITY-KEY do with a picture: the hash the
      ;; count's events name, and the role. The counter whose act it is may
      ;; attach it; the franchise may read it; no one else may do either.
      ((contest-terms identity-key ballot-id)
       (catch #t
         (lambda ()
           (let* ((c      (assq-ref ($ ballot-store 'meta ballot-id) 'contest))
                  (open?  (and c ($ ballot-store 'get ballot-id)))
                  (root   (and c (scope-root (assq-ref c 'scope-id))))
                  (obs    (and root ($ root 'observer)))
                  (ev     (and obs ($ obs 'get-event (assq-ref c 'event-id))))
                  (role   (and c (contest-role identity-key (assq-ref c 'worker) (scope-roster root)))))
             (cond
               ((not c) (list 'error "no such contest"))
               ((not open?) (list 'error "this contest has settled"))
               ((not ev) (list 'error "event not found"))
               ((not (memq (or (assq-ref c 'kind) 'work) '(count))) (list 'error "only a count's picture is held"))
               ((eq? role 'none) (list 'error "only the counter and the scope's members see this contest's picture"))
               (else
                (list 'ok `((role . ,role) (scope-id . ,(assq-ref c 'scope-id))
                            (hash . ,(any (lambda (e) (tags-evidence (economic-event-resource-classified-as e)))
                                          (contest-family obs ev)))))))))
         (lambda (_k . args) (list 'error (format #f "~a" args)))))

      ;; ── contrary-observation doors: the vouch's three shapes, on a figure ──
      ;; preimage → the client signs the SAID with its own key → signed lands
      ;; it; the unsigned door is the fallback for a session with no resident
      ;; key. contrary-observations is the read: what stands against this
      ;; scope's map, with who saw it.
      ((observe-contrary-preimage identity-key scope-id process action spec nominal reading witness at)
       (%preimage (lambda () (build-contrary-observation identity-key scope-id process action spec nominal reading witness at))
                  #:refusal attest-refusal))

      ((observe-contrary-signed identity-key scope-id process action spec nominal reading witness at signature)
       (%signed! (lambda () (build-contrary-observation identity-key scope-id process action spec nominal reading witness at))
                 identity-key signature "observation"
                 #:before (lambda (_) (revoke-prior-contrary-observations! identity-key scope-id process action))
                 #:refusal attest-refusal))

      ((observe-contrary identity-key scope-id process action spec nominal reading witness)
       (catch #t
         (lambda ()
           (let ((c (build-contrary-observation identity-key scope-id process action spec nominal reading witness (current-time))))
             (revoke-prior-contrary-observations! identity-key scope-id process action)
             ($ acdc-store 'issue c)
             (list 'ok (cred-said c))))
         (lambda (k . a) (list 'error (attest-refusal a)))))

      ((contrary-observations identity-key scope-id)
       (cons 'ok (map (lambda (c)
                        (list (cred-issuer c) (cred-claim c 'process) (cred-claim c 'action) (cred-claim c 'spec)
                              (cred-claim c 'nominal) (cred-claim c 'reading) (cred-claim c 'witness)
                              (cred-claim c 'observed-at)))
                      (standing-contrary-observations acdc-store scope-id #f))))

      ;; ── contesting work: the record says it happened; a member says it did not ──
      ;; docs/playnet.typ §Matching's absence claim — "a labour-voice-weighted
      ;; decision to revoke accrued hours" — given its door. It opens a ballot in
      ;; the event's own scope: the franchise is that scope's roster by producer
      ;; voice THERE, the worker's own voice left out; the positions are `void`
      ;; and `stands`. The close every ballot has settles it (settle-contest!).
      ;; The criterion is the spec's — whether the person did the work; quality
      ;; is a planning question and has no door here. One contest per event.
      ((contest-work identity-key scope-id event-id reason)
       (catch #t
         (lambda ()
           (let* ((root   (scope-root scope-id))
                  (obs    (and root ($ root 'observer)))
                  (ev     (and obs ($ obs 'get-event event-id)))
                  (roster (scope-roster root))
                  (worker (and ev (economic-event-provider ev)))
                  ;; a count, or any part of one: the adjustment, its record,
                  ;; the counter's hours (planner/formulas/counting.scm)
                  (count? (and ev (count-event? ev)))
                  ;; one contest per count, whichever of its parts is named
                  (id     (contest-ballot-id event-id count?))
                  (why    (if (string? reason) reason "")))
             (cond
               ((not root) (list 'error "no such scope"))
               ((not ev) (list 'error "event not found"))
               ((not (or (eq? 'work (economic-event-action ev)) count?))
                (list 'error "only work and counts are contested"))
               ((not ($ obs 'event-standing? event-id)) (list 'error "this event has already been corrected"))
               ((not (member identity-key roster)) (list 'error "only a member of the scope may contest its work"))
               ((equal? identity-key worker) (list 'error "your own record is corrected, never contested"))
               (($ ballot-store 'get id) (list 'error "this work is already contested"))
               (($ ballot-store 'get-tally id) (list 'error "this work was contested and settled"))
               (else
                (for-each (lambda (aid) (ensure-citizen aid)) roster)
                (let* ((records (filter (lambda (r) (not (equal? (car r) worker)))
                                        (voice-data-snapshot)))
                       (data    (build-voice-snapshot records (list root))))
                  (open-proposal! 'ballot 'contest-work id
                                  (string-append "did " worker (if count? " count this as stated? " " do this work? ") why)
                                  (list 'scope scope-id)
                                  (list (string-append "event:" event-id))
                                  #:citizen-data data
                                  #:meta `((contest . ((scope-id . ,scope-id)
                                                       (kind . ,(if count? 'count 'work))
                                                       ;; the stock a count is of, for the counter's prompt
                                                       (resource . ,(and count? (count-event-of ev)))
                                                       (event-id . ,event-id)
                                                       (worker . ,worker)
                                                       (by . ,identity-key)
                                                       (reason . ,why))))))))))
         (lambda (_k . args) (list 'error (format #f "~a" args))))))))
