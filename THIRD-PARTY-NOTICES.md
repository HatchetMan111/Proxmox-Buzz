# Third-Party Notices

This repository (`proxmox-buzz`) is an independent installer/deployment
wrapper. It is **not affiliated with, endorsed by, or sponsored by** Proxmox
Server Solutions GmbH or Block, Inc. "Proxmox" and "Proxmox VE" are
trademarks of Proxmox Server Solutions GmbH. "Buzz" is a project of
Block, Inc.

This repository does **not** vendor, copy, or redistribute the source code
of any of the projects below. `install.sh` downloads their official,
unmodified deployment files and container images from their respective
upstream locations at install time, on the target machine, over HTTPS.

## Buzz

- Project: https://github.com/block/buzz
- Copyright: Block, Inc.
- License: Apache License, Version 2.0 — https://www.apache.org/licenses/LICENSE-2.0
- What this installer fetches: the official `deploy/compose` bundle
  (`compose.yml`, `compose.caddy.yml`, `.env.example`, `run.sh`, `Caddyfile`)
  via a shallow, sparse `git clone`, and the official container image
  `ghcr.io/block/buzz` from GitHub Container Registry.
- This installer does not modify Buzz's compose files; it only writes
  generated secrets and domain configuration into the `.env` file that
  Buzz's own `.env.example` already defines as configurable.

## Debian

- Project: https://www.debian.org/
- The installer downloads the official Debian 13 ("Trixie") GenericCloud
  qcow2 image from `cloud.debian.org` and verifies it against Debian's
  published `SHA512SUMS` before use.

## Docker

- Project: https://www.docker.com/
- The installer adds Docker's official APT repository (with its published
  GPG signing key) inside the newly created VM and installs Docker Engine,
  the Docker CLI, containerd, Buildx and the Compose plugin from it,
  following Docker's official installation instructions.

## Caddy (only when `--domain` is used)

- Project: https://caddyserver.com/
- Deployed via Buzz's own `compose.caddy.yml`, using the official Caddy
  container image, to provide automatic HTTPS via Let's Encrypt.

## No affiliation

- Proxmox is a registered trademark of Proxmox Server Solutions GmbH.
  This project is not affiliated with or endorsed by Proxmox Server
  Solutions GmbH.
- Buzz is a project of Block, Inc. This project is not affiliated with or
  endorsed by Block, Inc.
- This repository contains an installer/deployment wrapper only, not Buzz
  itself.

## Privacy / telemetry

`install.sh` contains no telemetry, no analytics, no external calls other
than the ones documented above (Debian, Docker, GitHub/GHCR), and no
hard-coded API keys or credentials. All secrets it generates are created
locally with `openssl rand`, stored root-only (`chmod 600`) inside the VM,
and echoed once to the operator's own terminal/log so they can be saved.
