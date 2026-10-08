;;; contacts.scm — KERI contacts tab UI
;;;
;;; A "contact" in KERI/KERIA is a resolved OOBI: a remote AID whose
;;; key state has been ingested locally, optionally tagged with a
;;; friendly alias. KERIA exposes them as /contacts/{aid}; in the
;;; browser-resident model we keep an in-memory + localStorage list
;;; on the client and (eventually) reconcile against the gateway.
;;;
;;; Contact alist shape:
;;;   ((alias . str) (prefix . aid) (oobi . url) (added-at . epoch-ms)
;;;    (note . str))
;;;
;;; Pure SXML — state and handlers live in hoot/repl.scm.

(define-module (playnet ui contacts)
  #:export (contacts-page
            parse-oobi-aid))

(define (truncate-aid prefix)
  (let ((n (string-length prefix)))
    (if (<= n 18)
        prefix
        (string-append (substring prefix 0 12) "…" (substring prefix (- n 4))))))

(define (parse-oobi-aid url)
  "Extract the AID from an OOBI URL. Returns the AID string or #f.
   Recognises:
     …/oobi/{AID}
     …/oobi/{AID}/...
     …/.well-known/keri/oobi/{AID}"
  (and (string? url)
       (let* ((segs (string-split-on url #\/))
              (idx (find-index segs "oobi")))
         (and idx
              (< (+ idx 1) (length segs))
              (non-empty (list-ref segs (+ idx 1)))))))

(define (non-empty s) (and (string? s) (not (string=? s "")) s))

(define (string-split-on str ch)
  (let ((n (string-length str)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond
       ((>= i n) (reverse (cons (substring str start n) acc)))
       ((char=? (string-ref str i) ch)
        (loop (+ i 1) (+ i 1) (cons (substring str start i) acc)))
       (else (loop (+ i 1) start acc))))))

(define (find-index lst x)
  (let loop ((l lst) (i 0))
    (cond
     ((null? l) #f)
     ((equal? (car l) x) i)
     (else (loop (cdr l) (+ i 1))))))

(define (assq-ref alist key)
  (let ((p (assq key alist)))
    (and p (cdr p))))

(define (contact-row c on-copy on-delete on-mesh mesh
                     on-mail on-mail-send composing?)
  (let* ((alias  (or (assq-ref c 'alias)  ""))
         (prefix (or (assq-ref c 'prefix) ""))
         (oobi   (or (assq-ref c 'oobi)   ""))
         (note   (or (assq-ref c 'note)   ""))
         ;; mesh = (dest verdict pub-hex) once resolved. The verdict is
         ;; what makes the destination trustworthy — "verified" means
         ;; everything advertised derives from the icp-anchored pubkey,
         ;; and only then is the pub kept (mail encrypts to it).
         (dest     (and (pair? mesh) (car mesh)))
         (verdict  (and (pair? mesh) (cadr mesh)))
         (mailable? (and verdict (string=? verdict "verified"))))
    `(div (@ (class "contact-card"))
          (div (@ (class "contact-card-head"))
               (div (@ (class "contact-alias"))
                    ,(if (string=? alias "") "(unnamed)" alias))
               (div (@ (class "contact-actions"))
                    (span (@ (class "contact-btn")
                             (title "Copy AID")
                             (click ,(lambda (e) (on-copy prefix))))
                          "copy")
                    ,@(if (string=? oobi "")
                          '()
                          (list `(span (@ (class "contact-btn")
                                          (title "Resolve + verify the contact's mesh endpoints from its OOBI")
                                          (click ,(lambda (e) (on-mesh c))))
                                       "mesh")))
                    ,@(if (not mailable?)
                          '()
                          (list `(span (@ (class "contact-btn")
                                          (title "Mesh mail — encrypted to the contact's verified identity")
                                          (click ,(lambda (e) (on-mail c))))
                                       "mail")))
                    (span (@ (class "contact-btn contact-btn-danger")
                             (title "Forget this contact")
                             (click ,(lambda (e) (on-delete c))))
                          "forget")))
          (div (@ (class "contact-aid"))
               (code (@ (title ,prefix)) ,(truncate-aid prefix)))
          ,@(if (string=? oobi "")
                '()
                (list `(div (@ (class "contact-oobi"))
                            (span (@ (class "contact-label")) "oobi: ")
                            (a (@ (href ,oobi) (target "_blank")) ,oobi))))
          ,@(if (not verdict)
                '()
                (list `(div (@ (class "contact-mesh"))
                            (span (@ (class "contact-label")) "mesh: ")
                            ,@(if (string=? dest "")
                                  '()
                                  (list `(code (@ (title ,dest))
                                               ,(truncate-aid dest))
                                        " "))
                            (span (@ (class ,(if mailable?
                                                 "contact-mesh-ok"
                                                 "contact-mesh-warn")))
                                  ,verdict))))
          ,@(if (not composing?)
                '()
                (list (mail-form on-mail-send)))
          ,@(if (string=? note "")
                '()
                (list `(div (@ (class "contact-note")) ,note))))))

(define (mail-form on-send)
  ;; Composed, signed, and encrypted in THIS browser; the gateway
  ;; relays ciphertext it cannot read.
  `(div (@ (class "contact-mail-form"))
        (div (@ (class "contact-add-row"))
             (input (@ (class "contact-input contact-input-wide")
                       (id "contact-mail-title")
                       (type "text")
                       (placeholder "title"))))
        (div (@ (class "contact-add-row"))
             (input (@ (class "contact-input contact-input-wide")
                       (id "contact-mail-content")
                       (type "text")
                       (placeholder "message"))))
        (div (@ (class "contact-add-row"))
             (button (@ (class "contact-submit") (click ,on-send))
                     "send over mesh"))))

(define (add-form on-add error-msg adding?)
  `(div (@ (class "contact-add-form"))
        (h3 "Add contact")
        (div (@ (class "contact-add-hint"))
             "Paste an OOBI URL. The AID is extracted from the URL "
             "and stored locally. Verification against witnesses runs "
             "in the background.")
        (div (@ (class "contact-add-row"))
             (input (@ (class "contact-input")
                       (id "contact-alias-input")
                       (type "text")
                       (placeholder "alias (e.g. alice)"))))
        (div (@ (class "contact-add-row"))
             (input (@ (class "contact-input contact-input-wide")
                       (id "contact-oobi-input")
                       (type "text")
                       (placeholder "https://…/oobi/E…"))))
        (div (@ (class "contact-add-row"))
             (input (@ (class "contact-input contact-input-wide")
                       (id "contact-note-input")
                       (type "text")
                       (placeholder "note (optional)"))))
        ,@(if error-msg
              (list `(div (@ (class "contact-error")) ,error-msg))
              '())
        (div (@ (class "contact-add-row"))
             (button (@ (class "contact-submit")
                        (disabled ,(if adding? "disabled" ""))
                        (click ,on-add))
                     ,(if adding? "adding…" "add contact")))))

(define* (contacts-page #:key
                        (contacts '())
                        (error-msg #f)
                        (adding? #f)
                        (on-add (lambda (e) #f))
                        (on-copy (lambda (aid) #f))
                        (on-delete (lambda (c) #f))
                        ;; Mesh-endpoint resolution: ON-MESH fires the
                        ;; OOBI fetch + binding check for a contact;
                        ;; MESH-OF returns its (dest verdict pub) or #f.
                        (on-mesh (lambda (c) #f))
                        (mesh-of (lambda (prefix) #f))
                        ;; Mesh mail: ON-MAIL toggles the compose form
                        ;; for a contact (MAIL-TO = that contact or #f);
                        ;; ON-MAIL-SEND submits it.
                        (on-mail (lambda (c) #f))
                        (on-mail-send (lambda (e) #f))
                        (mail-to #f)
                        (on-refresh (lambda (e) #f)))
  `(div (@ (class "contacts-view"))
        (div (@ (class "contacts-header"))
             (div (@ (class "contacts-title"))
                  "contacts "
                  (span (@ (class "contacts-count"))
                        "(" ,(number->string (length contacts)) ")"))
             (span (@ (class "contact-btn")
                      (title "Reload contact list from gateway")
                      (click ,on-refresh))
                   "refresh"))
        (div (@ (class "contacts-body"))
             (div (@ (class "contacts-list"))
                  ,(if (null? contacts)
                       `(div (@ (class "contacts-empty"))
                             "No contacts yet. Add one with an OOBI URL.")
                       `(div (@ (class "contacts-list-inner"))
                             ,@(map (lambda (c)
                                      (let ((prefix (or (assq-ref c 'prefix) "")))
                                        (contact-row
                                         c on-copy on-delete on-mesh
                                         (mesh-of prefix)
                                         on-mail on-mail-send
                                         (and mail-to
                                              (equal? prefix
                                                      (or (assq-ref mail-to 'prefix)
                                                          ""))))))
                                    contacts))))
             ,(add-form on-add error-msg adding?))))
