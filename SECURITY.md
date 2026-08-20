# Security Policy

## Scope

This policy covers the `install.sh` installer/deployment wrapper in this
repository. It does **not** cover Buzz itself — please report Buzz
vulnerabilities directly to the [block/buzz](https://github.com/block/buzz)
project.

## What this script does with privileges

`install.sh` must run as root on your Proxmox VE host because creating VMs,
importing disk images, and writing cloud-init snippets all require root.
Concretely, it:

- Downloads a Debian cloud image over HTTPS and verifies it against
  Debian's published SHA512 checksums before use.
- Creates a new QEMU VM and a dedicated ed25519 SSH keypair for it, stored
  under `/root/.proxmox-buzz/vm-<id>/` with `chmod 700`/`600` permissions.
- Generates random secrets (`openssl rand -hex`) for Postgres, Redis,
  MinIO, the Buzz git-hook HMAC, the Buzz relay's own signing key, and (by
  default) a fresh Buzz owner identity keypair. These are written into the
  VM's `.env` file with `chmod 600` and are never sent anywhere except to
  your own terminal/log at the end of the install.
- Adds Docker's official APT repository and its published GPG key inside
  the new VM, and installs Docker from it.
- Clones Buzz's official `deploy/compose` files via a shallow, sparse
  `git clone` and runs Buzz's own `run.sh` to start the stack.

It does not phone home, does not include analytics, and does not embed any
API keys or credentials.

## Known limitations to be aware of

- **No production rate limiter in Buzz.** As of this writing, Buzz does
  not ship a production-grade rate limiter. Do not expose a relay
  installed by this script directly to the public internet without a
  firewall, VPN, or reverse proxy with its own rate limiting in front of
  it.
- **Without `--domain`, traffic is unencrypted.** If you don't pass
  `--domain`, the installer skips Caddy/TLS and Buzz listens in
  plain `ws://` on the VM's DHCP IP. Only use this for local/LAN testing.
- **Checksum, not signature, verification.** The Debian image is verified
  against a SHA512 checksum file fetched over HTTPS from the same host
  that serves the image. This protects against corrupted downloads but is
  not a substitute for a full GPG signature chain.
- **Secrets appear once in the install log.** The remote bootstrap output,
  including the generated owner secret key, is written to
  `/root/.proxmox-buzz/vm-<id>/install.log` on the Proxmox host
  (`chmod 600`). Move the owner key to a password manager and delete this
  file once you've done so.

## Reporting a vulnerability

Please open a private security advisory on this repository's GitHub
"Security" tab, or contact the maintainer listed in `README.md`, rather
than filing a public issue.
