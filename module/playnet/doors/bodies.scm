;;; module/playnet/doors/bodies.scm — the body service: the planner-vat
;;; actor a session's body doors act through.
;;;
;;; The doors (doors/body.scm) run in the gateway's vat and the
;;; stores a body is read from — its scope's agent store, observer, spatial
;;; store and legal registry — in the planner's, so every act on a body is one
;;; message here, answered as (ok . wire) or (error . msg) in the shapes the
;;; page reads (string keys, vectors). The stewardship gate is read here, on
;;; the records, with the caller's AID first in every message; the gates a
;;; session can read for itself (a live personhood credential, governor
;;; standing) stay at the door.
;;;
;;; What it stands on: (playnet legal bodies) for the records and the
;;; folds, (playnet legal compliance) for the reading of what a body
;;; holds, (playnet legal adapters) for its exposure, and the ceremony
;;; desk (personhood/body-desk.scm) in the oobi-host's vat for the k-of-n
;;; inception, reached by `<-`. A body's scope is read off the records (a body
;;; is a member of its scope) and remembered.
;;;
;;;   (spawn ^body-service root-of scope-ids)   then  ($ svc 'set-desk! desk)
;;;     root-of   : scope-id → the scope's root actor, or #f (the planner
;;;                 service's `scope-root-ref`)
;;;     scope-ids : → every scope id the gateway keeps (`scope-list`)

(define-module (playnet doors bodies)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (playnet utils wire-shapes)
  #:use-module (playnet vf schemas)
  #:use-module (playnet legal bodies)
  #:use-module ((playnet legal registry)
                #:select (legal-demands legal-context demand-name demand-kind bill-ref))
  #:use-module ((playnet legal compliance) #:select (reconcile iso-date))
  #:use-module ((playnet legal adapters) #:select (adapter-exposure))
  #:use-module ((playnet legal gate) #:select (spatial-path-reader))
  #:use-module ((playnet knowledge dsl findings) #:select (findings->wire))
  #:use-module ((playnet utils clock) #:select (now instant->civil))
  #:export (^body-service body->wire))

(define (ok x) (cons 'ok x))
(define (fail msg) (cons 'error msg))
(define (today) (iso-date (instant->civil (now))))

(define (body->wire b)
  `(("id" . ,(agent-id b))
    ("name" . ,(or (agent-name b) ""))
    ("tags" . ,(vec (filter string? (or (agent-classified-as b) '()))))))

(define (exposure->wire x)
  (if (not (list? x)) '()
      `(("stance" . ,(sym->str (assq-ref x 'stance)))
        ("doors" . ,(vec (map sym->str (or (assq-ref x 'doors) '()))))
        ("holds" . ,(vec (map (lambda (p) `(("demand" . ,(car p)) ("status" . ,(sym->str (cdr p)))))
                              (or (assq-ref x 'holds) '()))))
        ("owes" . ,(vec (or (assq-ref x 'owes) '())))
        ("forbidden" . ,(vec (or (assq-ref x 'forbidden) '())))
        ("doubted" . ,(vec (or (assq-ref x 'doubted) '()))))))

(define (^body-service bcom root-of scope-ids)
  (define desk #f)
  (define scope-of-cache (make-hash-table))   ; body-id → scope-id

  ;; ── the records behind a scope ───────────────────────────────────────
  (define (stores scope-id)
    "The root's stores as an alist, or #f for an unknown scope."
    (let ((root (and (string? scope-id) (root-of scope-id))))
      (and root
           `((root . ,root)
             (agents . ,($ root 'agent-store))
             (observer . ,(false-if-exception ($ root 'observer)))
             (specs . ,(let ((rs (false-if-exception ($ root 'recipe-store))))
                         (lambda (id) (and rs ($ rs 'get-resource-spec id)))))
             (spatial . ,(false-if-exception ($ root 'spatial-thing-store)))
             (registry . ,(false-if-exception ($ root 'legal-registry)))))))
  (define (scope-of body-id)
    "The scope BODY-ID stands in: remembered, else found among the scopes."
    (or (hash-ref scope-of-cache body-id)
        (let ((found (find (lambda (sid)
                             (let ((s (stores sid)))
                               (and s ($ (assq-ref s 'agents) 'get-agent body-id))))
                           (scope-ids))))
          (when found (hash-set! scope-of-cache body-id found))
          found)))
  (define (body-and-stores body-id)
    "(values body stores) or (values #f #f)."
    (let* ((sid (scope-of body-id)) (s (and sid (stores sid)))
           (b (and s ($ (assq-ref s 'agents) 'get-agent body-id))))
      (if (and b (body? b)) (values b s) (values #f #f))))
  (define (steward? s body-id aid) (and (member aid (body-stewards (assq-ref s 'agents) body-id)) #t))
  (define (member-of? s body-id aid) (and (member aid (body-members (assq-ref s 'agents) body-id)) #t))

  ;; the act a steward performs on a body, or the refusal
  (define (as-steward aid body-id proc)
    (call-with-values (lambda () (body-and-stores body-id))
      (lambda (b s)
        (cond ((not (string? body-id)) (fail "name the body"))
              ((not b) (fail "no such body"))
              ((not (steward? s body-id aid)) (fail "only a steward of the body acts for it"))
              (else (proc b s))))))

  ;; ── the law's reading of what a body holds ───────────────────────────
  (define (body-bill b s)
    "(values bill hits crossings path) for B under its scope's rules."
    (let* ((agents (assq-ref s 'agents)) (observer (assq-ref s 'observer))
           (spatial (assq-ref s 'spatial)) (registry (assq-ref s 'registry))
           (cs (body-crossings agents observer b #:resolve-spec (assq-ref s 'specs)))
           (juris (body-jurisdiction b))
           (path (if (and spatial juris)
                     (car ((spatial-path-reader spatial) juris))
                     (if juris (list juris) '())))
           (rules (if registry ($ registry 'rules) '())))
      (call-with-values
          (lambda () (legal-demands (legal-context #:crossings cs #:place-path path #:act 'activity)
                                    #:rules rules))
        (lambda (bill hits) (values bill hits cs path rules)))))
  (define (body-standing b s)
    "ONE fold of B's bill under its scope: → (values bill hits crossings path
     rules), or #f when the scope keeps no books."
    (and (assq-ref s 'observer) (call-with-values (lambda () (body-bill b s)) list)))
  (define (holdings->wire b s standing)
    "Each entity demand of the body's bill with the status the compliance
     fold reads, then every held resource no rule asked for."
    (let ((observer (assq-ref s 'observer)) (agents (assq-ref s 'agents)))
      (if (not standing) '()
          (apply (lambda (bill hits cs path rules)
              (let* ((entries (reconcile bill hits observer (today)
                                         #:subject-of (body-reconcile-subject agents observer (list b))))
                     (held (body-holdings observer (agent-id b)))
                     (demanded (map (lambda (e)
                                      (let* ((name (list-ref e 2))
                                             (r (find (lambda (r) (equal? (economic-resource-conforms-to r) name)) held)))
                                        `(("spec" . ,name) ("kind" . ,(sym->str (list-ref e 1)))
                                          ("status" . ,(sym->str (list-ref e 3)))
                                          ("id" . ,(and r (economic-resource-id r)))
                                          ("name" . ,(or (and r (economic-resource-name r)) name)))))
                                    entries))
                     (named (map (lambda (w) (assoc-ref w "spec")) demanded))
                     (extra (filter-map (lambda (r)
                                          (and (not (member (economic-resource-conforms-to r) named))
                                               `(("spec" . ,(economic-resource-conforms-to r)) ("kind" . "held")
                                                 ("status" . "held") ("id" . ,(economic-resource-id r))
                                                 ("name" . ,(or (economic-resource-name r) "")))))
                                        held)))
                (append demanded extra)))
            standing))))
  (define (exposure b s standing)
    (let ((observer (assq-ref s 'observer)))
      (if (not standing) '()
          (apply (lambda (bill hits cs path rules)
                   (exposure->wire (adapter-exposure observer (agent-id b) #:crossings cs
                                                     #:place-path path #:rules rules #:as-of (today)
                                                     #:bill+hits (list bill hits))))
                 standing))))
  (define (body-law->wire b s)
    "What the law face reads of a body: where it stands, what it holds with
     the law's status, and its stance there — one fold of its bill."
    (let ((standing (body-standing b s)))
      `(("jurisdiction" . ,(body-jurisdiction b))
        ("holdings" . ,(vec (holdings->wire b s standing)))
        ("exposure" . ,(exposure b s standing)))))

  (methods
   ((set-desk! d) (set! desk d) #t)

   ;; A recognised person declares a body in SCOPE-ID and is its first steward.
   ((declare! aid scope-id id name alist)
    (let ((s (stores scope-id)))
      (cond ((not s) (fail "scope not found"))
            (else
             (let* ((agents (assq-ref s 'agents))
                    (b (or ($ agents 'get-agent id)
                           (declare-body! agents scope-id id name alist))))
               (hash-set! scope-of-cache id scope-id)
               (unless (steward? s id aid) (body-add-steward! agents scope-id id aid))
               (ok (body->wire b)))))))

   ((add-steward! aid id steward)
    (as-steward aid id
      (lambda (b s)
        (unless (steward? s id steward)
          (body-add-steward! (assq-ref s 'agents) (scope-of id) id steward))
        (ok #t))))

   ;; the k-of-n inception, at the desk in the oobi-host's vat
   ((open-ceremony! aid id k)
    (as-steward aid id
      (lambda (b s)
        (let ((stewards (body-stewards (assq-ref s 'agents) id)))
          (cond ((not desk) (fail "this commune holds no ceremonies"))
                ((not (and (integer? k) (> k 0))) (fail "k is a count"))
                ((> k (length stewards)) (fail (format #f "k cannot exceed the ~a stewards" (length stewards))))
                (else (on (<- desk 'open! (scope-of id) id aid stewards k)
                          (lambda (standing) (ok standing))
                          #:catch (lambda (e) (fail (format #f "~a" e)))
                          #:promise? #t)))))))
   ((preimage aid id what)
    (as-steward aid id
      (lambda (b s)
        (if (not desk) (fail "this commune holds no ceremonies")
            (on (<- desk 'preimage id what) ok
                #:catch (lambda (e) (fail (format #f "~a" e))) #:promise? #t)))))
   ((sign aid id what said sig)
    (as-steward aid id
      (lambda (b s)
        (if (not desk) (fail "this commune holds no ceremonies")
            (on (<- desk 'sign id aid what said sig) ok
                #:catch (lambda (e) (fail (format #f "~a" e))) #:promise? #t)))))
   ;; the ceremony published: the body stands under its AID
   ((close! scope-id provisional-id aid)
    (let ((s (stores scope-id)))
      (and s
           (begin (close-body! (assq-ref s 'agents) scope-id provisional-id aid)
                  (hash-remove! scope-of-cache provisional-id)
                  (hash-set! scope-of-cache aid scope-id)
                  #t))))

   ;; the bodies AID stewards or belongs to in SCOPE-ID, with any open ceremony
   ((list aid scope-id)
    (let ((s (stores scope-id)))
      (if (not s) (fail "scope not found")
          (let* ((agents (assq-ref s 'agents))
                 (bs (bodies-of agents aid))
                 (rows (map (lambda (b)
                              (append (body->wire b)
                                      `(("steward" . ,(steward? s (agent-id b) aid)))
                                      (body-law->wire b s)))
                            bs)))
            (if (or (not desk) (null? bs))
                (ok (vec (map (lambda (r) (append r '(("ceremony" . #f)))) rows)))
                (on (<- desk 'statuses (map agent-id bs))
                    (lambda (sts)
                      (ok (vec (map (lambda (r) (append r `(("ceremony" . ,(assoc-ref sts (assoc-ref r "id"))))))
                                    rows))))
                    #:catch (lambda (e) (ok (vec (map (lambda (r) (append r '(("ceremony" . #f)))) rows))))
                    #:promise? #t))))))

   ;; one body, whole, for a steward or a member
   ((read aid id)
    (call-with-values (lambda () (body-and-stores id))
      (lambda (b s)
        (cond ((not b) (fail "no such body"))
              ((not (or (steward? s id aid) (member-of? s id aid)))
               (fail "the body is read by its stewards and members"))
              (else
               (let* ((agents (assq-ref s 'agents)) (observer (assq-ref s 'observer))
                      (sid (scope-of id))
                      (base (append (body->wire b)
                                    `(("scope" . ,sid)
                                      ("stewards" . ,(vec (body-stewards agents id)))
                                      ("members" . ,(vec (body-members agents id)))
                                      ("crossings" . ,(vec (map sym->str (body-crossings agents observer b #:resolve-spec (assq-ref s 'specs)))))
                                      ("findings" . ,(findings->wire (admission-findings agents observer sid #:resolve-spec (assq-ref s 'specs)))))
                                    (body-law->wire b s))))
                 (if (not desk) (ok (append base '(("ceremony" . #f))))
                     (on (<- desk 'status id)
                         (lambda (st) (ok (append base `(("ceremony" . ,st)))))
                         #:catch (lambda (e) (ok (append base '(("ceremony" . #f)))))
                         #:promise? #t))))))))

   ;; a steward presents what the body holds
   ((present-holding! aid id spec name issuer valid-until ref)
    (as-steward aid id
      (lambda (b s)
        (let ((observer (assq-ref s 'observer)))
          (if (not observer) (fail "this scope keeps no books")
              (ok (body-present-holding! observer id spec
                                         #:name (if (and (string? name) (not (string-null? name))) name spec)
                                         #:issuer issuer #:valid-until valid-until #:ref ref)))))))

   ;; admission: the eight tests over the scope's bodies, and the body's own
   ;; facts for the credential the governor's door issues when none errs
   ;; (the governor gate and the issuing are the door's)
   ((admit! aid scope-id id)
    (let ((s (stores scope-id)))
      (cond ((not s) (fail "scope not found"))
            (else
             (let ((b ($ (assq-ref s 'agents) 'get-agent id)))
               (if (not (and b (body? b))) (fail "no such body")
                   (ok `(("findings" . ,(findings->wire
                                         (admission-findings (assq-ref s 'agents) (assq-ref s 'observer) scope-id
                                                             #:resolve-spec (assq-ref s 'specs))))
                         ("body" . ,(body->wire b))
                         ("kind" . ,(sym->str (body-kind b)))
                         ("jurisdiction" . ,(body-jurisdiction b))
                         ("quorum" . ,(body-quorum b))
                         ("legalIds" . ,(map (lambda (p) (cons (symbol->string (car p)) (cdr p)))
                                             (body-legal-ids b)))))))))))))
