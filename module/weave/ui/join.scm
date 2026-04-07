;;; module/weave/ui/join.scm — Join screen SXML components
;;;
;;; Pure functions returning SXML. Hoot/WASM compatible.
;;; Rendered by the virtual-dom diffing engine in browser.scm.

(define-module (weave ui join)
  #:use-module (weave ui ffi)
  #:export (render-join-screen
            render-join-error))

(define (render-join-screen on-submit)
  "Render the pre-join screen. ON-SUBMIT is called with (name role room-id).
   Returns an SXML tree."
  `(div (@ (class "join-screen"))
     (div (@ (class "join-card"))
       (div (@ (class "join-logo"))
         (h1 "Weave"))
       (div (@ (class "join-tagline"))
         "Structured conversations for organized teams.")
       (form (@ (class "join-form")
                (submit ,(lambda (e)
                  (prevent-default! e)
                  (let* ((name-el  (get-element-by-id "join-name"))
                         (role-el  (get-element-by-id "join-role"))
                         (room-el  (get-element-by-id "join-room"))
                         (name     (element-value name-el))
                         (role     (element-value role-el))
                         (room-id  (element-value room-el)))
                    (on-submit name role room-id)))))
         (div (@ (class "form-field"))
           (label (@ (for "join-name")) "Your name")
           (input (@ (id "join-name")
                     (type "text")
                     (placeholder "Alice")
                     (autocomplete "name")
                     (required "true"))))
         (div (@ (class "form-field"))
           (label (@ (for "join-room")) "Room ID")
           (input (@ (id "join-room")
                     (type "text")
                     (placeholder "abc123")
                     (required "true"))))
         (div (@ (class "form-field"))
           (label (@ (for "join-role")) "Join as")
           (select (@ (id "join-role"))
             (option (@ (value "participant")) "Participant")
             (option (@ (value "convener"))    "Facilitator / Convener")
             (option (@ (value "observer"))    "Observer (view only)")))
         (div (@ (class "form-field attribution-field"))
           (label
             (input (@ (type "checkbox") (id "join-anonymous")))
             " Join anonymously (your name won't appear in the transcript)"))
         (button (@ (type "submit") (class "join-button"))
           "Join Meeting")))))

(define (render-join-error message)
  "Render an error banner on the join screen."
  `(div (@ (class "join-error"))
     (span (@ (class "error-icon")) "⚠")
     " " ,message))

(define (render-join-loading)
  "Render a loading indicator while connecting."
  `(div (@ (class "join-screen"))
     (div (@ (class "join-card"))
       (div (@ (class "connecting-spinner")))
       (p "Connecting to room..."))))
