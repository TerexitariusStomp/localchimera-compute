;;; module/playnet/interface/channel-manager.scm — Channel lifecycle manager
;;;
;;; Creates, destroys, and tracks channels. Takes a backend-factory
;;; function so it's not coupled to any particular backend type.
;;; The default factory creates scope-backends, but callers can
;;; supply their own for chat rooms, kanban boards, etc.
;;;
;;; Channels can also be created with a pre-existing backend ref
;;; (e.g., a remote scope on another machine via OCapN sturdyref).

(define-module (playnet interface channel-manager)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 receive)
  #:use-module (playnet interface channel)
  #:use-module (playnet interface notification-sink)
  #:export (^channel-manager))


;; =========================================================================
;; ^channel-manager
;; =========================================================================

(define (^channel-manager bcom
                           channels          ;; hashmap: channel-id string -> ^channel ref
                           backend-factory)  ;; (name) -> (values backend-ref sink-ref)

  (methods

    ((create-channel channel-id name)
     ;; Create a new channel using the backend-factory.
     ;; Returns the ^channel ref.
     (if (hashmap-ref channels channel-id #f)
         (list 'error "Channel already exists" channel-id)
         (receive (backend-ref sink-ref)
           (backend-factory name)
           (let ((chan-ref (spawn ^channel
                                  channel-id backend-ref sink-ref
                                  #f #f      ;; no transport/context yet
                                  (hashmap)))) ;; no members yet
             (bcom (^channel-manager bcom
                     (hashmap-set channels channel-id chan-ref)
                     backend-factory)
                   chan-ref)))))

    ((attach-channel channel-id backend-ref)
     ;; Attach a pre-existing backend (e.g., remote scope via OCapN sturdyref).
     ;; The caller provides the backend; we create the channel shell around it.
     (if (hashmap-ref channels channel-id #f)
         (list 'error "Channel already exists" channel-id)
         (let* ((sink-ref (spawn ^notification-sink
                                  #f #f default-alert-formatter '()))
                (chan-ref (spawn ^channel
                                 channel-id backend-ref sink-ref
                                 #f #f (hashmap))))
           ;; Wire notifications from the remote backend to our local sink
           (<-np backend-ref 'wire-notifications sink-ref)
           (bcom (^channel-manager bcom
                   (hashmap-set channels channel-id chan-ref)
                   backend-factory)
                 chan-ref))))

    ((get-channel channel-id)
     (hashmap-ref channels channel-id #f))

    ((destroy-channel channel-id)
     ;; Remove channel from registry.
     (let ((chan (hashmap-ref channels channel-id #f)))
       (when chan
         ($ chan 'unbind-transport))
       (bcom (^channel-manager bcom
               (hashmap-remove channels channel-id)
               backend-factory))))

    ((list-channels)
     (hashmap-fold (lambda (k v acc) (cons k acc)) '() channels))

    ((channel-count)
     (hashmap-fold (lambda (k v acc) (+ acc 1)) 0 channels))))
