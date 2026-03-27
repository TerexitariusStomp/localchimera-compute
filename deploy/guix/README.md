# Guix System on Hetzner

Generic Guix System infrastructure deployed via `guix deploy` with native Hetzner provisioning.

## How it works

`guix deploy` handles everything:
- Creates the Hetzner server via API
- Boots into Hetzner rescue mode
- Formats disk, installs minimal Guix
- Reboots and applies the full OS config
- On subsequent runs: reconfigures in place

No manual bootstrap. No Ansible. Just Scheme.

## Prerequisites

1. A Hetzner Cloud account and API token
   (Project > Security > API Tokens > Generate API Token)

2. Guix installed locally (`guix` CLI available)

3. An SSH key pair. The public key goes in `base-system.scm` (`%admin-ssh-public-key`).

4. `guix archive --generate-key` run once (automatic on Guix System, needed on other distros):
   ```sh
   sudo guix archive --generate-key
   ```

## Setup

1. **Edit `base-system.scm`**: replace `%admin-ssh-public-key` with your actual SSH public key.

2. **Pin channels**: run `guix describe --format=channels` and paste the commit into `channels.scm`.

3. **Customize `machines.scm`**: set your SSH key path, choose a server type and location.

## Deploy

```sh
# First deploy — creates server and installs Guix (~10-15 min)
GUIX_HETZNER_API_TOKEN=<your-token> guix deploy deploy/guix/machines.scm

# Subsequent deploys — reconfigures in place
GUIX_HETZNER_API_TOKEN=<your-token> guix deploy deploy/guix/machines.scm

# Roll back last deployment
GUIX_HETZNER_API_TOKEN=<your-token> guix deploy --roll-back deploy/guix/machines.scm

# Run a command on all machines
GUIX_HETZNER_API_TOKEN=<your-token> guix deploy deploy/guix/machines.scm -x -- herd status
```

## Adding services

To add an application (e.g. xorg-relay), write a Shepherd service module and use `make-hetzner-system`:

```scheme
;; In machines.scm:
(make-hetzner-system
 #:hostname "relay"
 #:certbot-email "ops@example.com"
 #:certbot-domains '("relay.example.com")
 #:extra-services (list (service my-service-type my-config)))
```

## Useful commands on the server

```sh
# Check system generations
guix system list-generations

# Describe current system (channels + config)
guix system describe

# View shepherd service status
herd status

# View logs
herd log xorg-relay
tail -f /var/log/messages
```

## Server types

| Type   | vCPU | RAM  | Disk  | EUR/mo |
|--------|------|------|-------|--------|
| cx22   | 2    | 4GB  | 40GB  | ~4     |
| cx32   | 4    | 8GB  | 80GB  | ~8     |
| cx42   | 8    | 16GB | 160GB | ~16    |
| cax11  | 2    | 4GB  | 40GB  | ~4 (ARM) |

## Locations

- `nbg1` — Nuremberg, Germany
- `fsn1` — Falkenstein, Germany
- `hel1` — Helsinki, Finland
- `sin` — Singapore
- `ash` — Ashburn, Virginia, USA
