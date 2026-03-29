---
description: Emacs + Geiser — live Goblins hacking, structural editing, server REPL connection
---

Emacs is the development interface on the server. It runs as a daemon on the `playnet` user, connected to a live Guile REPL via Geiser. Code evaluated in Emacs runs in a persistent Goblins vat — actors survive between evaluations.

## Server setup

The Emacs daemon runs on `SERVER_IP` as the `playnet` user. It is provisioned declaratively by `machines.scm` (activation service deploys `init.el` to `/home/playnet/.emacs.d/`).

Installed packages (via Guix System):

- `emacs-no-x` — terminal Emacs (no X11)
- `emacs-geiser` + `emacs-geiser-guile` — Guile REPL integration
- `emacs-smartparens` — structural editing
- `emacs-rainbow-delimiters` — colored parentheses
- `emacs-claude-code-ide` — Claude Code IDE integration

## Connecting

```bash
# SSH tunnel for emacsclient access
ssh -i ~/.ssh/id_ed25519 -L 9999:127.0.0.1:9999 playnet@SERVER_IP -N -f

# Copy auth file
scp -i ~/.ssh/id_ed25519 playnet@SERVER_IP:~/.emacs.d/server/server /tmp/emacs-playnet/server

# All commands use:
emacsclient -f /tmp/emacs-playnet/server --eval '<ELISP>'
```

See the `/repl` skill for the full connection and recovery procedure.

## Geiser — live Guile REPL

Geiser connects Emacs to a running Guile process. State persists across evaluations.

```bash
# Evaluate Scheme in the live REPL
emacsclient -f /tmp/emacs-playnet/server --eval '
(let ((proc (get-buffer-process "*Geiser Guile REPL*")))
  (comint-send-string proc "(+ 1 2)\n"))'

# Read REPL output
emacsclient -f /tmp/emacs-playnet/server --eval '(playnet-repl-output)'

# Synchronous eval via direct socket (preferred for scripting)
ssh playnet@SERVER_IP '/home/playnet/bin/repl-eval "(+ 1 2)"'
```

### Geiser commands

```elisp
;; Documentation
(geiser-doc-symbol "spawn-vat")

;; Jump to definition
(geiser-edit-symbol "spawn-vat")

;; Symbol completion
(geiser-completion--complete "spawn-" nil)

;; Import module in REPL
(geiser-repl-import-module "(goblins)")

;; Switch REPL to module context
(geiser-repl-switch-to-module "(goblins)")

;; Who calls this symbol?
(geiser-xref-callers "spawn-vat")

;; Evaluate buffer into live vat (reload module)
(with-current-buffer "actors.scm" (geiser-eval-buffer))
```

## Smartparens — structural editing

```elisp
(sp-forward-slurp-sexp)     ;; slurp next sexp into current form
(sp-forward-barf-sexp)      ;; barf last element out of current form
(sp-wrap-with-pair "(")     ;; wrap selection in parens
(sp-unwrap-sexp)            ;; remove outermost parens
(sp-splice-sexp)            ;; splice: remove parens, keep contents
(sp-kill-sexp)              ;; kill next sexp
(sp-transpose-sexp)         ;; swap two adjacent sexps
```

## File editing on server

```bash
# Open file
emacsclient -f /tmp/emacs-playnet/server --eval '(find-file "/home/playnet/playnet-repo/module/playnet/actors.scm")'

# Read buffer
emacsclient -f /tmp/emacs-playnet/server --eval '(with-current-buffer "actors.scm" (buffer-string))'

# Insert at end
emacsclient -f /tmp/emacs-playnet/server --eval '(with-current-buffer "actors.scm" (goto-char (point-max)) (insert "\n;; new\n"))'

# Save
emacsclient -f /tmp/emacs-playnet/server --eval '(with-current-buffer "actors.scm" (save-buffer))'

# Evaluate buffer into REPL
emacsclient -f /tmp/emacs-playnet/server --eval '(with-current-buffer "actors.scm" (geiser-eval-buffer))'
```

## Shell commands on server

```bash
emacsclient -f /tmp/emacs-playnet/server --eval '(shell-command-to-string "herd status")'
emacsclient -f /tmp/emacs-playnet/server --eval '(shell-command-to-string "git -C /home/playnet/playnet-repo log --oneline -5")'
```

## Recovery

```bash
# Restart Emacs daemon
ssh playnet@SERVER_IP 'kill $(pgrep -u playnet emacs) 2>/dev/null; sleep 2; emacs --daemon'

# Restart Guile REPL service
ssh deploy@SERVER_IP 'sudo herd stop playnet-repl; sudo herd enable playnet-repl; sudo herd start playnet-repl'

# Reconnect Geiser to REPL
emacsclient -f /tmp/emacs-playnet/server --eval '(geiser-connect-local (quote guile) "/var/run/playnet/repl.sock")'
```

## The user's request

$ARGUMENTS
