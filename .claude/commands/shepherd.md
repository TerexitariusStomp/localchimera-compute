---
description: GNU Shepherd — service management, herd commands, xorg service definitions
---

Shepherd is Guix System's init and service manager. Every process on the server — SSH, nginx, Mosquitto, the Guile REPL, xorg org instances — is a Shepherd service declared in Scheme.

## Essential herd commands

```bash
# Run on the server (ssh deploy@SERVER_IP):
sudo herd status                    # list all services
sudo herd status <service>          # detailed status of one service
sudo herd start <service>           # start a stopped service
sudo herd stop <service>            # stop a running service
sudo herd restart <service>         # stop then start
sudo herd enable <service>          # allow service to be started
sudo herd disable <service>         # prevent service from starting
sudo herd log <service>             # show service log (if supported)

# Via guix deploy (from local machine):
guix deploy -L deploy/guix deploy/guix/machines.scm -x -- herd status
```

## Current services on the server

| Service | Provision symbol | Auto-start | User |
|---------|-----------------|------------|------|
| SSH | `openssh` | yes | root |
| DHCP | `dhcpcd` | yes | root |
| MQTT broker | `mosquitto` | yes | root |
| Guile REPL | `playnet-repl` | no (manual) | playnet |
| xorg host org | `xorg-host` | yes | xorg |

## Defining a Shepherd service

In `machines.scm`, add to the `(services (cons* ...))` list:

```scheme
;; Simple inline service
(simple-service 'my-service
                shepherd-root-service-type
                (list (shepherd-service
                       (provision '(my-service))
                       (documentation "What this service does")
                       (requirement '(networking user-processes))
                       (start #~(make-forkexec-constructor
                                 (list #$(file-append guile-3.0 "/bin/guile")
                                       "-s" "/path/to/script.scm")
                                 #:user "xorg"
                                 #:log-file "/var/log/my-service.log"))
                       (stop #~(make-kill-destructor))
                       (respawn? #t)
                       (auto-start? #t))))
```

## xorg-service-type

`deploy/guix/xorg-service.scm` defines a reusable service type for xorg org processes:

```scheme
(service xorg-service-type
         (xorg-configuration
          (name "host")
          (entry-point (local-file "host-org-entry.scm"))
          (socket-path "/var/run/xorg-host.sock")
          (user "xorg")))
```

This creates a Shepherd service named `xorg-host` running the entry-point script as the `xorg` user, with optional OCapN Unix socket.

## Key patterns

- **`make-forkexec-constructor`** — start a process. Takes a command list, optional `#:user`, `#:group`, `#:log-file`, `#:environment-variables`.
- **`make-kill-destructor`** — stop by sending SIGTERM.
- **`#:requirement '(networking user-processes)`** — declare dependencies. Service won't start until requirements are met.
- **`(respawn? #t)`** — restart if the process dies.
- **`(auto-start? #f)`** — don't start on boot; require manual `herd start`.

## Gotchas

- Services run as root by default. Always specify `#:user` for non-root services.
- `#~(...)` code runs on the server at service start time, not at deploy time.
- After `guix deploy`, changed services are automatically restarted. New services start if `auto-start?` is `#t`.
- The `playnet-repl` service is `auto-start? #f` — after a reboot you must manually: `sudo herd enable playnet-repl && sudo herd start playnet-repl`.

## The user's request

$ARGUMENTS
