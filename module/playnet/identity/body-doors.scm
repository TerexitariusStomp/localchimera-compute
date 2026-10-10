;;; module/playnet/identity/body-doors.scm — the body doors of the session
;;;
;;; A legal body — an association, a cooperative, the operator — is declared
;;; in a scope by a recognised person, stewarded by the people it names, and
;;; given its identifier by a k-of-n inception the stewards sign from their
;;; own browsers (docs/legal/bodies.md). These are the session doors of that
;;; arc, written as ONE FRAGMENT the session composes (gateway/lobby.scm
;;; ^lobby-session, protocol/dispatch.scm declared-doors), beside the identity
;;; doors of (playnet identity doors):
;;;
;;;   (body-session-doors #:aid-prefix #:acdc-store #:governance-svc #:body-service)
;;;
;;; Every door takes JSON strings where it takes a structure, replies
;;; (ok . x) or (error . msg) — as a value or as a promise of one — and is
;;; declared `device` in (playnet protocol). The gates a session reads for
;;; itself stand here: a live personhood credential to declare, governor
;;; standing to admit. The stewardship gate is read on the records, by the
;;; service, with this session's AID first in every message.
;;;
;;; THE BODY SERVICE is the one procedure these doors act through: the
;;; gateway sets `current-body-service` at boot to a sender for the
;;; ^body-service actor of (playnet planner doors bodies), which lives in the
;;; planner's vat beside the stores; the session reads the cell when it
;;; spawns. Each op is one message, answered (ok . wire) | (error . msg):
;;;
;;;   (svc 'declare! aid scope-id id name alist)         → (ok . body)
;;;   (svc 'add-steward! aid id steward-aid)             → (ok . #t)
;;;   (svc 'open-ceremony! aid id k)                     → (ok . standing)
;;;   (svc 'preimage aid id what)                        → (ok ("what" . w) ("said" . s))
;;;   (svc 'sign aid id what said sig-qb64)              → (ok . standing)
;;;   (svc 'list aid scope-id)                           → (ok . #(body …))
;;;   (svc 'read aid id)                                 → (ok . body-whole)
;;;   (svc 'present-holding! aid id spec name issuer valid-until ref) → (ok . resource-id)
;;;   (svc 'admit! aid scope-id id)                      → (ok . #(finding …))
;;;
;;; A body's id before inception is provisional: "body:<hex>", the SHA-256
;;; of its name, scope and initiator — so declaring twice names one body.

(define-module (playnet identity body-doors)
  #:use-module (goblins)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:use-module ((playnet utils boot-cell) #:select (make-boot-cell))
  #:use-module ((playnet utils hex) #:select (bv->hex))
  #:use-module ((playnet keri crypto-primitives) #:select (keri-crypto-sha256))
  #:use-module ((playnet keri first-person predicates) #:select (holds-any-live-phc?))
  #:use-module ((json parser) #:select (json-string->scm))
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:export (body-session-doors current-body-service provisional-body-id))

;; The body service the gateway sets at boot (see the header); #f on a
;; gateway that keeps no bodies, where every door answers the absence.
(define current-body-service (make-boot-cell))

(define %name-max 80)
(define %whats '("inception" "rotation" "role"))

(define (provisional-body-id name scope-id initiator)
  "The id a body carries until its inception publishes an AID."
  (string-append
   "body:"
   (bv->hex (keri-crypto-sha256
             (string->utf8 (string-append name "\n" scope-id "\n" initiator))))))

;;; ── JSON arguments ──────────────────────────────────────────────────────
(define (parse-json s)
  "The JSON object S, or #f for anything that is not one."
  (and (string? s)
       (catch #t
         (lambda () (let ((v (json-string->scm s))) (and (list? v) v)))
         (lambda _ #f))))
(define (jstr o key)
  "The string under KEY in the JSON object O, trimmed, or #f."
  (let ((v (assoc-ref o key)))
    (and (string? v) (let ((t (string-trim-both v))) (and (not (string-null? t)) t)))))
(define (jbool o key default)
  (let ((v (assoc-ref o key)))
    (cond ((boolean? v) v)
          ((string? v) (and (member v '("yes" "true" "locked" "on")) #t))
          (else default))))
(define (sym->str x) (cond ((symbol? x) (symbol->string x)) ((string? x) x) (else "")))
(define (count-of k) (if (string? k) (string->number k) k))

(define (body-session-doors* aid-prefix acdc-store governance-svc body-service)
  (define (refuse msg) (cons 'error msg))
  (define (svc . msg)
    "One message to the service; the reply is the door's, value or promise."
    (if body-service (apply body-service msg) (refuse "this commune keeps no bodies")))
  (define (person?)
    (and acdc-store (holds-any-live-phc? acdc-store aid-prefix)))
  (define (named? x) (and (string? x) (not (string-null? x))))

  (declared-doors session

   ;; A recognised person declares a body in SCOPE-ID: JSON {name kind role
   ;; jurisdiction assetLock register}. They are its first steward; the body's
   ;; id is provisional until its stewards sign the inception.
   ((declare-body scope-id json)
    (let ((o (parse-json json)))
      (cond
       ((not (named? scope-id)) (refuse "name the scope"))
       ((not o) (refuse "the body is JSON {name, kind, role, jurisdiction, assetLock, register}"))
       ((not (jstr o "name")) (refuse "give the body a name"))
       ((> (string-length (jstr o "name")) %name-max) (refuse "a name is one short line"))
       ((not (person?)) (refuse "declaring a body takes a recognised person: get vouched for first"))
       (else
        (let ((name (jstr o "name")))
          (svc 'declare! aid-prefix scope-id (provisional-body-id name scope-id aid-prefix) name
               `((kind . ,(or (jstr o "kind") "association"))
                 (role . ,(or (jstr o "role") "provider"))
                 (jurisdiction . ,(jstr o "jurisdiction"))
                 (asset-lock . ,(jbool o "assetLock" #f))
                 (register . ,(if (equal? (jstr o "register") "inspectable") 'inspectable 'closed))
                 (quorum . 1))))))))

   ;; A steward of body ID names another steward.
   ((body-add-steward id aid)
    (cond ((not (named? id)) (refuse "name the body"))
          ((not (named? aid)) (refuse "name the person"))
          (else (svc 'add-steward! aid-prefix id aid))))

   ;; A steward opens the inception of body ID: K of the stewards must sign it.
   ((body-open-ceremony id k)
    (let ((k (count-of k)))
      (cond ((not (named? id)) (refuse "name the body"))
            ((not (and (integer? k) (> k 0))) (refuse "k is a count"))
            (else (svc 'open-ceremony! aid-prefix id k)))))

   ;; The statement a steward signs for body ID: KIND ∈ inception | rotation | role.
   ((body-sign-preimage id kind)
    (let ((what (sym->str kind)))
      (cond ((not (named? id)) (refuse "name the body"))
            ((not (member what %whats)) (refuse "sign the inception, a rotation or a role"))
            (else (svc 'preimage aid-prefix id what)))))

   ;; The steward's own signature over the statement, counted at the desk;
   ;; at k the ceremony publishes.
   ((body-sign-signed id kind said signature)
    (let ((what (sym->str kind)))
      (cond ((not (named? id)) (refuse "name the body"))
            ((not (member what %whats)) (refuse "sign the inception, a rotation or a role"))
            ((not (and (string? said) (string? signature))) (refuse "the statement and its signature are strings"))
            (else (svc 'sign aid-prefix id what said signature)))))

   ;; The bodies this AID stewards or belongs to, with any open ceremony.
   ((my-bodies scope-id)
    (if (named? scope-id) (svc 'list aid-prefix scope-id) (refuse "name the scope")))

   ;; Body ID, read whole by a steward or a member.
   ((body id)
    (if (named? id) (svc 'read aid-prefix id) (refuse "name the body")))

   ;; A steward presents what body ID holds: JSON {kind name issuer validUntil ref}.
   ((body-present-holding id json)
    (let ((o (parse-json json)))
      (cond ((not (named? id)) (refuse "name the body"))
            ((not o) (refuse "a holding is JSON {kind, name, issuer, validUntil, ref}"))
            ((not (jstr o "kind")) (refuse "say what kind of holding it is"))
            (else (svc 'present-holding! aid-prefix id (jstr o "kind") (jstr o "name")
                       (jstr o "issuer") (jstr o "validUntil") (jstr o "ref"))))))

   ;; A governor admits body ID to SCOPE-ID; the reply is the admission's findings.
   ((body-admit scope-id id)
    (cond
     ((not body-service) (refuse "this commune keeps no bodies"))
     ((not governance-svc) (refuse "this commune has no governance"))
     ((not (and (named? scope-id) (named? id))) (refuse "name the scope and the body"))
     (else
      (on (<- governance-svc 'fp-status aid-prefix scope-id)
          (lambda (st)
            ;; governance replies (ok (person . …) (governor . …) …): the alist is the tail
            (let ((governor? (and (pair? st) (eq? (car st) 'ok) (list? (cdr st))
                                  (assq-ref (cdr st) 'governor))))
              (if governor?
                  (svc 'admit! aid-prefix scope-id id)
                  (refuse "a body is admitted by a governor"))))
          #:catch (lambda _ (refuse "governance could not be asked"))
          #:promise? #t))))))

(define* (body-session-doors #:key aid-prefix (acdc-store #f) (governance-svc #f)
                             (body-service (current-body-service)))
  "The session's body doors (declared `session` in (playnet protocol)) as a
   declared-doors fragment, over this session's AID-PREFIX, the commune's
   ACDC-STORE (the personhood gate), its GOVERNANCE-SVC (the governor gate)
   and the BODY-SERVICE — the boot cell's by default."
  (body-session-doors* aid-prefix acdc-store governance-svc body-service))
