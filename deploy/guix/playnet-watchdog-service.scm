;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/playnet-watchdog-service.scm — health check + auto-restart
;;;
;;; Polls the gateway's /federation-status.json endpoint every
;;; PLAYNET_WATCHDOG_INTERVAL_SEC (default 60s). On 3 consecutive
;;; failures (timeout / non-200 / malformed JSON), restarts
;;; playnet-gateway via `herd restart`.
;;;
;;; This is the deferred-task-#52 deliverable: shepherd doesn't have a
;;; native WatchdogSec equivalent (that's systemd's). We get the same
;;; semantics with a tiny shepherd service that exec's a polling script.
;;;
;;; Usage in machines.scm:
;;;   (service playnet-watchdog-service-type
;;;            (playnet-watchdog-configuration
;;;             (gateway-url "http://127.0.0.1:8080")
;;;             (interval-sec 60)
;;;             (failure-threshold 3)))

(define-module (playnet-watchdog-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages base)        ; coreutils, grep
  #:use-module (gnu packages curl)        ; curl
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (playnet-watchdog-configuration
            playnet-watchdog-configuration?
            playnet-watchdog-service-type))

(define-record-type* <playnet-watchdog-configuration>
  playnet-watchdog-configuration make-playnet-watchdog-configuration
  playnet-watchdog-configuration?
  ;; URL the watchdog probes (must serve /federation-status.json)
  (gateway-url   playnet-watchdog-configuration-gateway-url
                 (default "http://127.0.0.1:8080"))
  ;; Seconds between probes
  (interval-sec  playnet-watchdog-configuration-interval-sec
                 (default 60))
  ;; Consecutive failures before triggering a restart
  (failure-threshold playnet-watchdog-configuration-failure-threshold
                     (default 3))
  ;; HTTP timeout per probe (seconds)
  (timeout-sec   playnet-watchdog-configuration-timeout-sec
                 (default 10))
  ;; Shepherd service name to restart on failure
  (target        playnet-watchdog-configuration-target
                 (default 'playnet-gateway))
  ;; User to run as
  (user          playnet-watchdog-configuration-user
                 (default "playnet")))

(define (watchdog-script config)
  "Bash script body — polls in a loop, restarts on threshold."
  (let* ((url        (playnet-watchdog-configuration-gateway-url config))
         (interval   (playnet-watchdog-configuration-interval-sec config))
         (threshold  (playnet-watchdog-configuration-failure-threshold config))
         (timeout    (playnet-watchdog-configuration-timeout-sec config))
         (target     (symbol->string
                      (playnet-watchdog-configuration-target config))))
    #~(string-append
       "#!" #$(file-append (canonical-package bash) "/bin/sh") "\n"
       "set -u\n"
       "URL='" #$url "/federation-status.json'\n"
       "INTERVAL=" #$(number->string interval) "\n"
       "THRESHOLD=" #$(number->string threshold) "\n"
       "TIMEOUT=" #$(number->string timeout) "\n"
       "TARGET='" #$target "'\n"
       "FAILS=0\n"
       "while true; do\n"
       "  if " #$(file-append curl "/bin/curl")
              " -fsS --max-time \"$TIMEOUT\" \"$URL\""
              " | " #$(file-append grep "/bin/grep") " -q '\"boot-time\"'; then\n"
       "    FAILS=0\n"
       "  else\n"
       "    FAILS=$((FAILS + 1))\n"
       "    echo \"[watchdog] probe failed ($FAILS/$THRESHOLD): $URL\" 1>&2\n"
       "    if [ \"$FAILS\" -ge \"$THRESHOLD\" ]; then\n"
       "      echo \"[watchdog] restarting $TARGET after $FAILS consecutive failures\" 1>&2\n"
       "      "
       ;; Restart by invoking herd; the watchdog user needs passwordless
       ;; sudo on `herd restart <target>` (set this in deploy/os.scm's
       ;; sudoers, same pattern as radicle-ci uses).
       #$(file-append shadow "/bin/sudo")
       " /run/current-system/profile/bin/herd restart \"$TARGET\" || true\n"
       "      FAILS=0\n"
       "    fi\n"
       "  fi\n"
       "  sleep \"$INTERVAL\"\n"
       "done\n")))

(define (playnet-watchdog-shepherd-service config)
  "Build the shepherd service definition."
  (let ((script (program-file "playnet-watchdog.sh"
                              #~(call-with-output-file %output
                                  (lambda (port)
                                    (display #$(watchdog-script config)
                                             port)
                                    (chmod port #o755)))))
        (user   (playnet-watchdog-configuration-user config)))
    (list (shepherd-service
           (provision '(playnet-watchdog))
           (requirement '(networking playnet-gateway))
           (start #~(make-forkexec-constructor
                    (list #$script)
                    #:user #$user
                    #:log-file "/var/log/playnet/watchdog.log"))
           (stop #~(make-kill-destructor))
           (respawn? #t)))))

(define playnet-watchdog-service-type
  (service-type
   (name 'playnet-watchdog)
   (extensions
    (list (service-extension shepherd-root-service-type
                             playnet-watchdog-shepherd-service)))
   (default-value (playnet-watchdog-configuration))
   (description
    "Polls playnet-gateway's /federation-status.json every
INTERVAL-SEC seconds; if FAILURE-THRESHOLD consecutive probes fail
(timeout, non-200, malformed JSON), restarts the gateway via
`herd restart`.")))
