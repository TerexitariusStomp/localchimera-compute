;;; module/weave/ui/room.scm — In-meeting room SXML components
;;;
;;; Pure functions returning SXML. Hoot/WASM compatible.
;;; Video tiles are DOM-attached externally (see WEAVE_CLAUDE.md: "Video tile attachment").

(define-module (weave ui room)
  #:export (render-room
            render-video-grid
            render-video-tile-placeholder
            render-host-controls
            render-connection-overlay))

;;; ── Video grid ────────────────────────────────────────────────────────────────

(define (render-video-tile-placeholder identity display-name is-local?)
  "Render a placeholder div for a video tile. LiveKit attaches the actual
   <video>/<audio> element here after the DOM is patched.
   IDENTITY is the LiveKit participant identity (stable string)."
  `(div (@ (class ,(string-append "video-tile" (if is-local? " video-tile--local" "")))
            (id ,(string-append "tile-" identity))
            (data-identity ,identity))
     (div (@ (class "video-tile__avatar"))
       ,(string (string-ref display-name 0)))
     (div (@ (class "video-tile__name"))
       ,display-name
       ,(if is-local? `(span (@ (class "tile-badge")) " (you)") ""))))

(define (render-video-grid participants local-identity)
  "Render the video grid. PARTICIPANTS is a list of (identity display-name) pairs.
   LOCAL-IDENTITY is the local participant's LiveKit identity string."
  (let ((count (length participants)))
    `(div (@ (class ,(string-append "video-grid"
                                    " video-grid--" (number->string count))))
       ,@(map (lambda (p)
                (let ((identity     (car p))
                      (display-name (cadr p)))
                  (render-video-tile-placeholder
                   identity display-name
                   (string=? identity local-identity))))
              participants))))

;;; ── Host controls ─────────────────────────────────────────────────────────────

(define (render-host-controls on-mute-audio on-mute-video on-share-screen
                               on-leave audio-muted? video-muted?)
  "Render the bottom control bar (shown to all participants, with host-only
   controls hidden via CSS class when role ≠ convener)."
  `(div (@ (class "controls-bar"))
     (button (@ (class ,(string-append "control-btn"
                                       (if audio-muted? " control-btn--active" "")))
                (title ,(if audio-muted? "Unmute microphone" "Mute microphone"))
                (click ,on-mute-audio))
       (span (@ (class "control-icon"))
         ,(if audio-muted? "🎙️✕" "🎙️")))
     (button (@ (class ,(string-append "control-btn"
                                       (if video-muted? " control-btn--active" "")))
                (title ,(if video-muted? "Start camera" "Stop camera"))
                (click ,on-mute-video))
       (span (@ (class "control-icon"))
         ,(if video-muted? "📷✕" "📷")))
     (button (@ (class "control-btn")
                (title "Share screen")
                (click ,on-share-screen))
       (span (@ (class "control-icon")) "🖥️"))
     (div (@ (class "controls-spacer")))
     (button (@ (class "control-btn control-btn--leave")
                (title "Leave meeting")
                (click ,on-leave))
       "Leave")))

;;; ── Full room layout ──────────────────────────────────────────────────────────

(define (render-room participants local-identity role
                      audio-muted? video-muted?
                      on-mute-audio on-mute-video on-share-screen on-leave)
  "Render the full in-meeting view."
  `(div (@ (class ,(string-append "room-layout"
                                  " room-layout--" (symbol->string role))))
     (div (@ (class "room-header"))
       (span (@ (class "room-status-dot")))
       (span (@ (class "room-status-text")) "Live"))
     ,(render-video-grid participants local-identity)
     ,(render-host-controls on-mute-audio on-mute-video on-share-screen
                            on-leave audio-muted? video-muted?)))

;;; ── Overlays ──────────────────────────────────────────────────────────────────

(define (render-connection-overlay status)
  "Render a full-screen overlay for connection state.
   STATUS is one of: 'connecting 'reconnecting 'failed"
  `(div (@ (class "connection-overlay"))
     (div (@ (class "connection-overlay__card"))
       ,(case status
          ((connecting)
           `(div
              (div (@ (class "spinner")))
              (p "Connecting...")))
          ((reconnecting)
           `(div
              (div (@ (class "spinner spinner--yellow")))
              (p "Reconnecting... please wait")))
          ((failed)
           `(div
              (p (@ (class "error-text")) "Failed to connect.")
              (p "Please check your network and try again.")))))))
