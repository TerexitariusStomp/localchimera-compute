;;; identity.scm — KERI identity tab UI
;;;
;;; Pure SXML: data in, SXML out. No DOM mutation, no actor refs.
;;; Hoot/WASM compatible.
;;;
;;; The user sees: identity card, credentials, portability, security.
;;; KERI is invisible — no KELs, witnesses, OOBIs in the UI.

(define-module (playnet ui identity)
  #:export (identity-page))


;;; ── Helpers ─────────────────────────────────────────────────────────────────

(define (truncate-did prefix)
  (let ((n (string-length prefix)))
    (if (<= n 20)
        prefix
        (string-append (substring prefix 0 12) "..." (substring prefix (- n 4))))))

(define (status-dot status)
  (let ((color (cond
                 ((equal? status "verified")      "#4ade80")
                 ((equal? status "authenticated") "#4ade80")
                 ((equal? status "active")        "#facc15")
                 ((equal? status "locked")        "#64748b")
                 ((equal? status "pending")       "#facc15")
                 (else                            "#94a3b8"))))
    `(span (@ (class "id-status-dot")
              (style ,(string-append "background:" color))) "")))

(define (section-header title . extra)
  `(h3 (@ (class "id-section-title")) ,title ,@extra))


;;; ── No identity: creation form ──────────────────────────────────────────────

(define (render-create-form on-create on-recover-toggle creating? error)
  `(div (@ (class "id-create"))
        (h2 "Create your identity")
        (p (@ (class "id-subtitle"))
           "Your keys live only in this browser, derived from a passcode "
           "the server never sees.")
        (div (@ (class "id-form"))
             (input (@ (id "id-name-input")
                       (class "id-input")
                       (type "text")
                       (placeholder "username")
                       (maxlength "31")))
             (input (@ (id "id-email-input")
                       (class "id-input")
                       (type "email")
                       (placeholder "email")
                       (maxlength "120")))
             (input (@ (id "id-bran-input")
                       (class "id-input")
                       (type "password")
                       (placeholder "passcode (21+ characters)")
                       (maxlength "256")))
             (button (@ (class "id-btn id-btn-primary")
                        (click ,on-create)
                        ,@(if creating? '((disabled "true")) '()))
                     ,(if creating? "creating..." "create identity")))
        ,@(if error
              (list `(div (@ (class "id-error")) ,error))
              '())
        (div (@ (class "id-key-hint"))
             (button (@ (class "id-btn id-btn-secondary")
                        (click ,on-recover-toggle))
                     "I already have an identity"))))

(define (render-recover-form on-recover on-back recovering? error)
  `(div (@ (class "id-create"))
        (h2 "Recover your identity")
        (p (@ (class "id-subtitle"))
           "Enter the AID and passcode from your other device. "
           "Keys are re-derived locally.")
        (div (@ (class "id-form"))
             (input (@ (id "id-aid-input")
                       (class "id-input")
                       (type "text")
                       (placeholder "AID prefix (starts with E)")
                       (maxlength "64")))
             (input (@ (id "id-bran-input")
                       (class "id-input")
                       (type "password")
                       (placeholder "passcode")
                       (maxlength "256")))
             (button (@ (class "id-btn id-btn-primary")
                        (click ,on-recover)
                        ,@(if recovering? '((disabled "true")) '()))
                     ,(if recovering? "recovering..." "recover"))
             (button (@ (class "id-btn") (click ,on-back)) "back"))
        ,@(if error (list `(div (@ (class "id-error")) ,error)) '())))


;;; ── Unlock form ────────────────────────────────────────────────────────────

(define (render-unlock-form identity on-unlock on-forget unlocking? error)
  (let ((name   (or (assq-ref identity 'name) "unnamed"))
        (prefix (or (assq-ref identity 'prefix) "")))
    `(div (@ (class "id-create"))
          (h2 ,(string-append "Welcome back, " name))
          (div (@ (class "id-card-prefix"))
               (code ,prefix))
          ,@(if error (list `(div (@ (class "id-error")) ,error)) '())
          (div (@ (class "id-form"))
               (input (@ (id "id-bran-input")
                         (class "id-input")
                         (type "password")
                         (placeholder "passcode")
                         (maxlength "256")))
               (button (@ (class "id-btn id-btn-primary")
                          (click ,on-unlock)
                          ,@(if unlocking? '((disabled "true")) '()))
                       ,(if unlocking? "unlocking..." "unlock"))
               (button (@ (class "id-btn id-btn-danger")
                          (click ,on-forget))
                       "forget this device")))))


;;; ── Bran reveal (shown once after creation) ────────────────────────────────

(define (render-bran-reveal bran on-dismiss)
  `(div (@ (class "id-create"))
        (h2 "Save your passcode now")
        (p (@ (class "id-subtitle"))
           "This is the only time it will be shown. "
           "The server cannot recover it for you.")
        (div (@ (class "id-bran-display"))
             (code (@ (class "id-bran-code")) ,bran))
        (p (@ (class "id-bran-warn"))
           "Write it down or store it in a password manager. "
           "Anyone with this passcode controls your identity.")
        (button (@ (class "id-btn id-btn-primary")
                   (click ,on-dismiss))
                "I have saved it")))


;;; ── Identity card ──────────────────────────────────────────────────────────

(define (render-identity-card identity on-authenticate authenticating?)
  (let ((name   (or (assq-ref identity 'name) "unnamed"))
        (prefix (or (assq-ref identity 'prefix) ""))
        (status (or (assq-ref identity 'status) "active")))
    `(div (@ (class "id-card"))
          (div (@ (class "id-card-header"))
               (div (@ (class "id-card-name")) ,name)
               (div (@ (class "id-card-status"))
                    ,(status-dot status)
                    ,status))
          (div (@ (class "id-card-prefix"))
               (code ,prefix)
               (button (@ (class "id-btn-copy")
                          (click ,(lambda (e) #f)))
                       "copy"))
          ,(if (equal? status "authenticated")
               `(div (@ (class "id-card-auth-ok")) "authenticated")
               `(div (@ (class "id-card-auth"))
                     (button (@ (class "id-btn")
                                (click ,on-authenticate)
                                ,@(if authenticating? '((disabled "true")) '()))
                             ,(if authenticating?
                                  "authenticating..."
                                  "authenticate")))))))


;;; ── Credentials ────────────────────────────────────────────────────────────

(define (render-credentials credentials creds-loading?
                            on-refresh-creds on-export-creds)
  `(div (@ (class "id-creds"))
        ,(section-header
          (string-append "Credentials (" (number->string (length credentials)) ")")
          `(span (@ (class "id-section-actions"))
                 (button (@ (class "id-btn-refresh")
                            (click ,on-refresh-creds)
                            ,@(if creds-loading? '((disabled "true")) '()))
                         ,(if creds-loading? "loading..." "refresh"))
                 ,@(if (pair? credentials)
                       (list `(button (@ (class "id-btn-refresh")
                                         (click ,on-export-creds))
                                      "export"))
                       '())))
        ,@(if (null? credentials)
              (list `(p (@ (class "id-empty"))
                        "Credentials issued to you will appear here."))
              (map (lambda (cred)
                     (let ((schema  (or (assq-ref cred 'schema) "?"))
                           (said    (or (assq-ref cred 'said) ""))
                           (issuer  (or (assq-ref cred 'issuer) ""))
                           (revoked (assq-ref cred 'revoked?)))
                       `(div (@ (class ,(string-append
                                         "id-cred-row"
                                         (if revoked " id-cred-revoked" ""))))
                             (div (@ (class "id-cred-schema"))
                                  ,(if (symbol? schema)
                                       (symbol->string schema)
                                       schema))
                             (div (@ (class "id-cred-said"))
                                  (code ,(if (> (string-length said) 16)
                                             (string-append
                                              (substring said 0 8) "..."
                                              (substring said (- (string-length said) 4)))
                                             said)))
                             (div (@ (class "id-cred-issuer"))
                                  "from "
                                  (code ,(if (string? issuer)
                                             (truncate-did issuer) "")))
                             ,@(if revoked
                                   '((div (@ (class "id-cred-status")) "REVOKED"))
                                   '()))))
                   credentials))))


;;; ── Portability ────────────────────────────────────────────────────────────

(define (render-portability identity show-recovery-info?
                            on-show-recovery on-close-recovery
                            on-download-backup
                            show-shamir? on-show-shamir on-close-shamir
                            on-split-shares contacts)
  (let ((prefix (or (assq-ref identity 'prefix) "")))
    `(div (@ (class "id-backup"))
          ,(section-header "Portability")
          ,(cond
            (show-recovery-info?
             `(div (@ (class "id-recovery-info"))
                   (p "To recover on a new device:")
                   (div (@ (class "id-recovery-item"))
                        (span (@ (class "id-recovery-label")) "AID")
                        (code (@ (class "id-recovery-aid")) ,prefix))
                   (div (@ (class "id-recovery-item"))
                        (span (@ (class "id-recovery-label")) "Passcode")
                        (span "the secret you chose at creation"))
                   (p (@ (class "id-subtitle"))
                      "Click 'I already have an identity' on the sign-in "
                      "screen, then enter both values.")
                   (button (@ (class "id-btn") (click ,on-close-recovery))
                           "done")))
            (show-shamir?
             `(div (@ (class "id-recovery-info"))
                   (h4 "Social recovery")
                   (p "Split your passcode into shares held by trusted "
                      "contacts. Any threshold number reconstructs it.")
                   ,@(if (null? contacts)
                         (list `(p (@ (class "id-empty"))
                                   "Add contacts first — each share goes "
                                   "to a different person."))
                         (list
                          `(p (@ (class "id-subtitle"))
                              ,(string-append
                                (number->string (length contacts))
                                " contacts available"))
                          `(div (@ (class "id-form"))
                                (input (@ (id "shamir-threshold-input")
                                          (class "id-input")
                                          (type "number")
                                          (value "2")
                                          (min "2")
                                          (max ,(number->string
                                                 (length contacts)))
                                          (placeholder "threshold (default 2)")))
                                (button (@ (class "id-btn id-btn-primary")
                                           (click ,on-split-shares))
                                        "split and send"))))
                   (button (@ (class "id-btn") (click ,on-close-shamir))
                           "back")))
            (else
             `(div
               (div (@ (class "id-backup-actions"))
                    (button (@ (class "id-btn-link")
                               (click ,on-show-recovery))
                            "recovery info")
                    (button (@ (class "id-btn-link")
                               (click ,on-download-backup))
                            "download backup")
                    (button (@ (class "id-btn-link")
                               (click ,on-show-shamir))
                            "social recovery"))
               (p (@ (class "id-subtitle"))
                  "Same passcode, any device.")))))))




;;; ── Contacts ───────────────────────────────────────────────────────────────

(define (render-contacts contacts)
  `(div (@ (class "id-contacts"))
        ,(section-header
          (string-append "Connections (" (number->string (length contacts)) ")"))
        ,@(if (null? contacts)
              (list `(p (@ (class "id-empty")) "No connections yet."))
              (map (lambda (c)
                     (let ((name   (or (assq-ref c 'name)
                                       (assq-ref c 'alias) "unknown"))
                           (prefix (or (assq-ref c 'prefix) ""))
                           (status (or (assq-ref c 'status) "pending")))
                       `(div (@ (class "id-contact-row"))
                             ,(status-dot status)
                             (span (@ (class "id-contact-name")) ,name)
                             (span (@ (class "id-contact-prefix"))
                                   ,(truncate-did prefix)))))
                   contacts))))


;;; ── Key status ─────────────────────────────────────────────────────────────

(define (render-key-status identity on-rotate)
  (let ((last-rotation (or (assq-ref identity 'last-rotation) "never"))
        (next-key-ready (or (assq-ref identity 'next-key-ready) #f)))
    `(div (@ (class "id-keys"))
          ,(section-header "Security")
          (div (@ (class "id-key-row"))
               (span "last rotation")
               (span (@ (class "id-key-value")) ,last-rotation))
          (div (@ (class "id-key-row"))
               (span "next key")
               (span (@ (class ,(string-append "id-key-value"
                                               (if next-key-ready "" " id-key-warn"))))
                     ,(if next-key-ready "pre-committed" "not ready")))
          (button (@ (class "id-btn id-btn-danger")
                     (click ,on-rotate))
                  "rotate keys")
          (p (@ (class "id-key-hint"))
             "Rotate if a device is lost or compromised."))))


;;; ── Main page ──────────────────────────────────────────────────────────────

(define* (identity-page #:key
                        (identity #f)
                        (contacts '())
                        (credentials '())
                        (creating? #f)
                        (connecting? #f)
                        (unlocking? #f)
                        (authenticating? #f)
                        (recovering? #f)
                        (recover-mode? #f)
                        (creds-loading? #f)
                        (error #f)
                        (bran-reveal #f)
                        (show-recovery-info? #f)
                        (show-shamir? #f)
                        (on-create           (lambda (e) #f))
                        (on-connect          (lambda (e) #f))
                        (on-rotate           (lambda (e) #f))
                        (on-unlock           (lambda (e) #f))
                        (on-forget           (lambda (e) #f))
                        (on-authenticate     (lambda (e) #f))
                        (on-recover-toggle   (lambda (e) #f))
                        (on-recover          (lambda (e) #f))
                        (on-refresh-creds    (lambda (e) #f))
                        (on-bran-dismiss     (lambda (e) #f))
                        (on-export-creds     (lambda (e) #f))
                        (on-show-recovery    (lambda (e) #f))
                        (on-close-recovery   (lambda (e) #f))
                        (on-download-backup  (lambda (e) #f))
                        (on-show-shamir      (lambda (e) #f))
                        (on-close-shamir     (lambda (e) #f))
                        (on-split-shares     (lambda (e) #f)))
  `(div (@ (class "id-page"))
        ,(cond
          (bran-reveal
           (render-bran-reveal bran-reveal on-bran-dismiss))
          ((and (not identity) recover-mode?)
           (render-recover-form on-recover on-recover-toggle
                                recovering? error))
          ((not identity)
           (render-create-form on-create on-recover-toggle creating? error))
          ((equal? "locked" (assq-ref identity 'status))
           (render-unlock-form identity on-unlock on-forget unlocking? error))
          (else
           `(div
             ,@(if error (list `(div (@ (class "id-error")) ,error)) '())
             ,(render-identity-card identity on-authenticate authenticating?)
             ,(render-credentials credentials creds-loading?
                                  on-refresh-creds on-export-creds)
             ,(render-portability identity show-recovery-info?
                                  on-show-recovery on-close-recovery
                                  on-download-backup
                                  show-shamir? on-show-shamir on-close-shamir
                                  on-split-shares contacts)
             ,(render-contacts contacts)
             ,(render-key-status identity on-rotate))))))
