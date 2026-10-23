;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; server/deploy-runner.scm — auto-deploy on fleet changes via file-watch
;;;
;;; Watches /var/run/playnet/deploy-trigger for changes using inotifywait.
;;; When the fleet reconciler writes this file after updating hosts.scm,
;;; deploy-runner picks it up and runs `guix deploy`.
;;;
;;; NO MQTT. Pure filesystem event. The trigger file is owned by playnet
;;; (written by the gateway process); the deploy-runner runs as the
;;; deploy user and only needs read access.
;;;
;;; Run as Shepherd service (deploy-runner-service.scm) or manually:
;;;   sudo -u deploy guile --no-auto-compile -L module -s server/deploy-runner.scm

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 format))

(define DEPLOY_DIR
  (or (getenv "PLAYNET_DEPLOY_DIR")
      "/home/playnet/playnet-repo/deploy"))

(define TRIGGER_FILE
  (or (getenv "DEPLOY_TRIGGER_FILE")
      "/var/run/playnet/deploy-trigger"))

(define MIN_COOLDOWN_SECONDS 600)
(define last-deploy-epoch 0)

(define (current-epoch) (car (gettimeofday)))

(define (cooldown-ok?)
  (> (- (current-epoch) last-deploy-epoch) MIN_COOLDOWN_SECONDS))

(define (run-deploy!)
  (set! last-deploy-epoch (current-epoch))
  (format #t "[deploy-runner] deploying at ~a~%"
          (strftime "%Y-%m-%d %H:%M:%S" (localtime (current-epoch))))
  (let ((code (system* "guix" "deploy"
                       (string-append DEPLOY_DIR "/machines.scm"))))
    (format #t "[deploy-runner] exit code ~a~%" code)))

(define (run-runner!)
  (format #t "[deploy-runner] watching ~a via inotifywait~%" TRIGGER_FILE)
  (format #t "[deploy-runner] deploy dir: ~a~%" DEPLOY_DIR)
  (format #t "[deploy-runner] cooldown: ~a seconds~%" MIN_COOLDOWN_SECONDS)

  ;; Ensure trigger file exists (inotifywait needs it)
  (unless (file-exists? TRIGGER_FILE)
    (format #t "[deploy-runner] trigger file does not exist yet — waiting~%")
    (let loop ()
      (sleep 10)
      (unless (file-exists? TRIGGER_FILE) (loop))))

  (let ((pipe (open-pipe*
               OPEN_READ
               "inotifywait" "-m" "-e" "close_write,moved_to"
               "--format" "%e"
               TRIGGER_FILE)))
    (let loop ()
      (let ((line (read-line pipe)))
        (cond
         ((eof-object? line)
          (format #t "[deploy-runner] inotifywait EOF, restarting in 10s~%")
          (close-pipe pipe)
          (sleep 10)
          (run-runner!))
         (else
          (format #t "[deploy-runner] trigger event: ~a~%" line)
          (if (cooldown-ok?)
              (run-deploy!)
              (format #t "[deploy-runner] cooldown active, skipping~%"))
          (loop)))))))

(run-runner!)
