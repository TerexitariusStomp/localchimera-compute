;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/interface/channel-manager.scm — Channel lifecycle manager
;;;
;;; Creates, destroys, and tracks channels. Takes a backend-factory
;;; function so it's not coupled to any particular backend type.
;;; The default factory creates scope-handlers, but callers can
;;; supply their own for chat rooms, kanban boards, etc.
;;;
;;; Channels can also be created with a pre-existing backend ref
;;; (e.g., a remote scope on another machine via OCapN sturdyref).
;;;
;;; An optional flow-runner-factory lets every channel get its own
;;; ^flow-runner — a per-channel state machine for multi-turn
;;; conversational flows (see (playnet interface flow)).

(define-module (playnet interface channel-manager)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 receive)
  #:use-module ((playnet interface channel) #:select (make-channel))
  #:use-module (playnet interface output-sink)
  #:export (^channel-manager))


;; =========================================================================
;; ^channel-manager
;; =========================================================================

(define (^channel-manager bcom
                          channels              ;; hashmap channel-id → ^channel
                          backend-factory       ;; (name) → (values backend sink)
                          flow-runner-factory)  ;; (channel-id) → ^flow-runner, or #f

  (define (spawn-channel-with channel-id backend-ref sink-ref)
    "Build a fresh ^channel via `make-channel`. The flow-runner (if a
     factory was supplied) is wired in at construction time."
    (make-channel channel-id backend-ref sink-ref
                  #:flow-runner (and flow-runner-factory
                                     (flow-runner-factory channel-id))))

  (methods

    ((create-channel channel-id name)
     ;; Create a new channel using the backend-factory.
     (if (hashmap-ref channels channel-id #f)
         (list 'error "Channel already exists" channel-id)
         (receive (backend-ref sink-ref)
           (backend-factory name)
           (let ((chan-ref (spawn-channel-with channel-id
                                               backend-ref sink-ref)))
             (bcom (^channel-manager bcom
                     (hashmap-set channels channel-id chan-ref)
                     backend-factory flow-runner-factory)
                   chan-ref)))))

    ((attach-channel channel-id backend-ref)
     ;; Attach a pre-existing backend (e.g., remote scope via OCapN).
     (if (hashmap-ref channels channel-id #f)
         (list 'error "Channel already exists" channel-id)
         (let* ((sink-ref (spawn ^output-sink
                                 #f #f passthrough-formatter '()))
                (chan-ref (spawn-channel-with channel-id
                                              backend-ref sink-ref)))
           (<-np backend-ref 'wire-output sink-ref)
           (bcom (^channel-manager bcom
                   (hashmap-set channels channel-id chan-ref)
                   backend-factory flow-runner-factory)
                 chan-ref))))

    ((get-channel channel-id)
     (hashmap-ref channels channel-id #f))

    ((destroy-channel channel-id)
     (let ((chan (hashmap-ref channels channel-id #f)))
       (when chan
         ($ chan 'unbind-transport))
       (bcom (^channel-manager bcom
               (hashmap-remove channels channel-id)
               backend-factory flow-runner-factory))))

    ((list-channels)
     (hashmap-fold (lambda (k v acc) (cons k acc)) '() channels))

    ((channel-count)
     (hashmap-fold (lambda (k v acc) (+ acc 1)) 0 channels))

    ((set-flow-runner-factory factory)
     ;; Lets callers attach (or replace) the flow-runner factory after
     ;; the manager has been spawned. Existing channels are not touched.
     (bcom (^channel-manager bcom channels
             backend-factory factory)))))
