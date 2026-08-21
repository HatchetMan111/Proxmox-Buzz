#!/usr/bin/env bash
#
# proxmox-buzz — one-line installer
#
# Provisions a fresh Debian 13 (Trixie) QEMU VM on a Proxmox VE host and
# deploys Buzz (https://github.com/block/buzz) inside it using Buzz's own
# official Docker Compose bundle (deploy/compose in the upstream repo).
#
# Why a VM and not an LXC container? Proxmox itself recommends running
# Docker-based application stacks inside a QEMU VM rather than inside an
# LXC container, because the isolation between the container engine and
# the Proxmox host is much stronger. See:
#   https://pve.proxmox.com/wiki/Linux_Container#pct_docker_inside_lxc
#
# Usage (one-liner):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<you>/proxmox-buzz/main/install.sh)"
#
# Usage (with options):
#   bash -c "$(curl -fsSL .../install.sh)" -- --domain buzz.example.com
#
# Run install.sh --help for the full list of options.
#
# This project is an independent deployment wrapper. It is not affiliated
# with Proxmox Server Solutions GmbH or Block, Inc. It does not vendor or
# redistribute Buzz's source code — Buzz's official deployment files and
# container image are fetched from their upstream locations at install
# time. See THIRD-PARTY-NOTICES.md for details and licenses.
#
# License: MIT (see LICENSE). Buzz itself is licensed Apache-2.0 by
# Block, Inc. and is not covered by this repository's license.

set -Eeuo pipefail
IFS=$'\n\t'

# --------------------------------------------------------------------------
# Constants & defaults
# --------------------------------------------------------------------------
SCRIPT_NAME="proxmox-buzz"
SCRIPT_VERSION="1.0.6"
# Used in re-run/uninstall hints. $0 is unusable for this: when the script
# is invoked as `bash -c "$(curl -fsSL ...)"`, $0 is just "bash", not a
# script path.
INSTALL_URL="https://raw.githubusercontent.com/HatchetMan111/Proxmox-Buzz/main/install.sh"

DEBIAN_SUITE="trixie"
DEBIAN_IMAGE_BASE_URL="https://cloud.debian.org/images/cloud/${DEBIAN_SUITE}/latest"
DEBIAN_IMAGE_FILE="debian-13-genericcloud-amd64.qcow2"

BUZZ_REPO_URL="https://github.com/block/buzz.git"
BUZZ_REF="${BUZZ_REF:-main}"
BUZZ_IMAGE="${BUZZ_IMAGE:-ghcr.io/block/buzz:main}"

VMID=""
VM_NAME="buzz"
STORAGE=""
SNIPPET_STORAGE=""
BRIDGE=""
CORES="2"
MEMORY="4096"
DISK_SIZE="20G"
CPU_TYPE="x86-64-v2-AES"
DOMAIN=""
OWNER_PUBKEY=""
SSH_USER="buzzadmin"
ASSUME_YES="0"
UNINSTALL_VMID=""

STATE_DIR="/root/.proxmox-buzz"

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m  OK\033[0m  %s\n' "$*" >&2; }
warn() { printf '\033[1;33m  !!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

on_err() {
  local line="$1"
  printf '\033[1;31mERROR:\033[0m installation aborted (line %s).\n' "$line" >&2
  printf 'Nothing further will be changed. Fix the issue above and re-run.\n' >&2
  if [[ -n "${VMID:-}" ]] && qm status "$VMID" >/dev/null 2>&1; then
    printf 'A partially configured VM %s may exist. Inspect it with: qm config %s\n' "$VMID" "$VMID" >&2
    printf 'Remove it with:\n  bash -c "$(curl -fsSL %s)" -- --uninstall %s\n' "$INSTALL_URL" "$VMID" >&2
  fi
}
trap 'on_err $LINENO' ERR

usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Installs Buzz (https://github.com/block/buzz) into a fresh Debian 13 VM on
a Proxmox VE host, using Buzz's official Docker Compose deployment bundle.

Usage:
  install.sh [options]
  install.sh --uninstall <vmid>

Options:
  --vmid <id>            VM ID to use (default: next free id)
  --name <name>           VM name (default: buzz)
  --storage <name>        Proxmox storage for the VM disk (default: auto-detect)
  --bridge <name>         Network bridge (default: auto-detect, usually vmbr0)
  --cores <n>             CPU cores (default: 2)
  --memory <mb>           RAM in MB (default: 4096)
  --disk <size>           Disk size, e.g. 20G (default: 20G)
  --cpu-type <type>       QEMU CPU type (default: x86-64-v2-AES - the same
                          modern baseline the Proxmox 8+ GUI defaults to;
                          use 'host' for max performance on a single node,
                          or an older type only if your hardware predates
                          ~2010 Intel Westmere / AMD Opteron_G4)
  --domain <fqdn>         Public domain name. Enables Caddy + automatic HTTPS
                          (Let's Encrypt). DNS for this domain must already
                          point at this host before you run this script.
  --owner-pubkey <hex>    Use an existing 64-char hex Nostr pubkey as the
                          Buzz relay owner instead of generating a new one
                          (e.g. one you already created in Buzz Desktop).
  --ssh-user <name>       Admin username created inside the VM (default: buzzadmin)
  --buzz-image <ref>      Buzz container image
                          (default: ghcr.io/block/buzz:main — early-testing
                          tag; pin to ghcr.io/block/buzz:sha-<7> for prod)
  --buzz-ref <ref>        Git ref of block/buzz to read deploy files from
                          (default: main)
  --yes, -y               Do not ask for confirmation before making changes
  --uninstall <vmid>      Stop and permanently destroy a VM created by this
                          script (deletes all Buzz data on its disks)
  -h, --help              Show this help and exit

Examples:
  install.sh
  install.sh --domain buzz.example.com
  install.sh --storage local-zfs --bridge vmbr0 --cores 4 --memory 8192 --disk 40G
  install.sh --uninstall 110
EOF
}

confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  local prompt="$1" reply=""
  read -r -p "$prompt [y/N] " reply || true
  [[ "$reply" =~ ^[Yy]$ ]] || die "Aborted."
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
while (( $# )); do
  case "$1" in
    --vmid)          VMID="${2:?--vmid needs a value}"; shift 2 ;;
    --name)          VM_NAME="${2:?--name needs a value}"; shift 2 ;;
    --storage)       STORAGE="${2:?--storage needs a value}"; shift 2 ;;
    --bridge)        BRIDGE="${2:?--bridge needs a value}"; shift 2 ;;
    --cores)         CORES="${2:?--cores needs a value}"; shift 2 ;;
    --memory)        MEMORY="${2:?--memory needs a value}"; shift 2 ;;
    --disk)          DISK_SIZE="${2:?--disk needs a value}"; shift 2 ;;
    --cpu-type)      CPU_TYPE="${2:?--cpu-type needs a value}"; shift 2 ;;
    --domain)        DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
    --owner-pubkey)  OWNER_PUBKEY="${2:?--owner-pubkey needs a value}"; shift 2 ;;
    --ssh-user)      SSH_USER="${2:?--ssh-user needs a value}"; shift 2 ;;
    --buzz-image)    BUZZ_IMAGE="${2:?--buzz-image needs a value}"; shift 2 ;;
    --buzz-ref)      BUZZ_REF="${2:?--buzz-ref needs a value}"; shift 2 ;;
    --yes|-y)        ASSUME_YES="1"; shift ;;
    --uninstall)     UNINSTALL_VMID="${2:?--uninstall needs a vmid}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

if [[ -n "$OWNER_PUBKEY" && ! "$OWNER_PUBKEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
  die "--owner-pubkey must be exactly 64 hex characters (got ${#OWNER_PUBKEY})."
fi
if [[ -n "$DOMAIN" && ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
  die "--domain does not look like a valid hostname: $DOMAIN"
fi

# --------------------------------------------------------------------------
# Pre-flight checks
# --------------------------------------------------------------------------
require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Please run as root (e.g. via sudo -i)."
}

require_proxmox() {
  command -v pveversion >/dev/null 2>&1 || command -v qm >/dev/null 2>&1 \
    || die "This does not look like a Proxmox VE host (qm/pveversion not found)."
  local major
  major="$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9]+' || true)"
  [[ -n "$major" ]] || die "Could not determine the Proxmox VE version from 'pveversion'."
  (( major >= 8 )) || die "Proxmox VE 8 or newer is required (found major version ${major})."
  ok "Proxmox VE ${major}.x detected"
}

require_cmds() {
  local need_pkgs=() c
  declare -A pkg_for=( [curl]=curl [openssl]=openssl [ssh]=openssh-client
                       [ssh-keygen]=openssh-client [jq]=jq [git]=git
                       [sha512sum]=coreutils )
  for c in curl openssl ssh ssh-keygen jq git sha512sum awk sed grep gpg; do
    command -v "$c" >/dev/null 2>&1 || need_pkgs+=("${pkg_for[$c]:-$c}")
  done
  if (( ${#need_pkgs[@]} )); then
    local dedup_pkgs=()
    mapfile -t dedup_pkgs < <(printf '%s\n' "${need_pkgs[@]}" | sort -u)
    log "Installing missing prerequisites: ${dedup_pkgs[*]}"
    apt-get update -qq
    apt-get install -y -qq "${dedup_pkgs[@]}" \
      || die "Failed to install prerequisites. Install them manually and re-run."
  fi
  ok "All required host tools are present"
}

# --------------------------------------------------------------------------
# Proxmox storage / network discovery
# --------------------------------------------------------------------------
parse_storage_cfg() {
  # Emits: name<TAB>content<TAB>disabled(0/1) for every storage in
  # /etc/pve/storage.cfg. Pure awk, no external deps.
  awk '
    /^[A-Za-z0-9_.-]+:[[:space:]]/ {
      if (name != "") print name "\t" content "\t" disabled
      split($0, a, ":[[:space:]]*")
      name = a[2]; content = ""; disabled = "0"
      next
    }
    /^[[:space:]]+content[[:space:]]/ {
      s = $0; sub(/^[[:space:]]+content[[:space:]]+/, "", s); content = s
    }
    /^[[:space:]]+disable([[:space:]]|$)/ { disabled = "1" }
    END { if (name != "") print name "\t" content "\t" disabled }
  ' /etc/pve/storage.cfg
}

find_storage_with_content() {
  local want="$1" name content disabled
  while IFS=$'\t' read -r name content disabled; do
    [[ "$disabled" == "1" ]] && continue
    [[ ",${content}," == *",${want},"* ]] && { echo "$name"; return 0; }
  done < <(parse_storage_cfg)
  return 1
}

pick_image_storage() {
  local candidates=() name content disabled
  while IFS=$'\t' read -r name content disabled; do
    [[ "$disabled" == "1" ]] && continue
    [[ ",${content}," == *",images,"* ]] && candidates+=("$name")
  done < <(parse_storage_cfg)
  (( ${#candidates[@]} )) || return 1
  local pref c
  for pref in local-zfs local-lvm; do
    for c in "${candidates[@]}"; do [[ "$c" == "$pref" ]] && { echo "$c"; return 0; }; done
  done
  echo "${candidates[0]}"
}

ensure_snippet_storage() {
  local s
  s="$(find_storage_with_content snippets)" && { echo "$s"; return 0; }
  # Most default installs only have 'local' as a directory storage that can
  # hold snippets. Try to enable that content type on it automatically.
  if pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx local; then
    local cur
    cur="$(parse_storage_cfg | awk -F'\t' '$1=="local"{print $2}')"
    [[ -n "$cur" ]] && cur="${cur},"
    pvesm set local --content "${cur}snippets" >/dev/null 2>&1 || true
    s="$(find_storage_with_content snippets)" && { echo "$s"; return 0; }
  fi
  return 1
}

get_storage_path() {
  pvesh get "/storage/$1" --output-format json 2>/dev/null | jq -r '.path // empty'
}

detect_bridge() {
  local bridges
  bridges="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep '^vmbr' || true)"
  grep -qx 'vmbr0' <<<"$bridges" && { echo vmbr0; return 0; }
  head -n1 <<<"$bridges"
}

# --------------------------------------------------------------------------
# Debian cloud image
# --------------------------------------------------------------------------
download_debian_image() {
  local dir="$1"
  log "Downloading the official Debian 13 (Trixie) generic-cloud image"
  curl -fsSL -o "${dir}/${DEBIAN_IMAGE_FILE}" "${DEBIAN_IMAGE_BASE_URL}/${DEBIAN_IMAGE_FILE}" \
    || die "Failed to download the Debian cloud image from ${DEBIAN_IMAGE_BASE_URL}."
  curl -fsSL -o "${dir}/SHA512SUMS" "${DEBIAN_IMAGE_BASE_URL}/SHA512SUMS" \
    || die "Failed to download SHA512SUMS for verification."
  log "Verifying image integrity (SHA512)"
  ( cd "$dir" && grep -E " \\*?${DEBIAN_IMAGE_FILE}\$" SHA512SUMS | sha512sum -c - ) \
    || die "Checksum verification FAILED for the Debian cloud image. Refusing to continue."
  ok "Image verified against Debian's published SHA512SUMS"
}

# --------------------------------------------------------------------------
# Cloud-init snippet (user-data) — creates the admin user & SSH key,
# installs qemu-guest-agent, and hardens SSH. Everything else (Docker,
# Buzz) is done afterwards over SSH so that its output streams live and
# any error stops the installer with a clear message.
# --------------------------------------------------------------------------
write_cloud_init_snippet() {
  local storage_path snippet_dir pubkey
  storage_path="$(get_storage_path "$SNIPPET_STORAGE")"
  [[ -n "$storage_path" ]] || die "Storage '${SNIPPET_STORAGE}' has no local filesystem path; it cannot hold cloud-init snippets. Pick a directory-based storage."
  snippet_dir="${storage_path}/snippets"
  mkdir -p "$snippet_dir"
  pubkey="$(cat "${SSH_KEY_FILE}.pub")"
  SNIPPET_FILE="buzz-${VMID}.user.yaml"
  cat > "${snippet_dir}/${SNIPPET_FILE}" <<CLOUDINIT
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
package_update: true
packages:
  - qemu-guest-agent
  - ca-certificates
users:
  - name: ${SSH_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ${pubkey}
ssh_pwauth: false
disable_root: true
runcmd:
  - systemctl enable --now qemu-guest-agent
  - sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  - systemctl restart ssh
CLOUDINIT
  ok "Cloud-init snippet written to ${snippet_dir}/${SNIPPET_FILE}"
}

# --------------------------------------------------------------------------
# VM creation
# --------------------------------------------------------------------------
create_vm() {
  log "Creating VM ${VMID} (${VM_NAME})"
  qm create "$VMID" \
    --name "$VM_NAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --cpu "$CPU_TYPE" \
    --ostype l26 \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-pci \
    --agent enabled=1 \
    --description "Buzz (https://github.com/block/buzz) - deployed by proxmox-buzz $(date -Iseconds)"

  qm importdisk "$VMID" "${TMP_DIR}/${DEBIAN_IMAGE_FILE}" "$STORAGE" >/dev/null

  local disk_ref
  disk_ref="$(qm config "$VMID" | awk -F': ' '/^unused0:/{print $2}')"
  [[ -n "$disk_ref" ]] || die "Could not find the imported disk in the VM config."

  qm set "$VMID" --scsi0 "${disk_ref},discard=on,ssd=1" >/dev/null
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit" >/dev/null
  qm set "$VMID" --boot order=scsi0 >/dev/null
  qm set "$VMID" --ipconfig0 ip=dhcp >/dev/null
  qm set "$VMID" --cicustom "user=${SNIPPET_STORAGE}:snippets/${SNIPPET_FILE}" >/dev/null
  qm resize "$VMID" scsi0 "$DISK_SIZE" >/dev/null
  ok "VM ${VMID} created (disk: ${disk_ref}, resized to ${DISK_SIZE})"
}

wait_for_ip() {
  log "Waiting for the VM to boot and report an IP address (guest agent)"
  local ip="" tries=0
  until [[ -n "$ip" ]]; do
    if (( tries++ >= 60 )); then
      die "Timed out after 5 minutes waiting for an IP via the QEMU guest agent. Check the VM console with: qm terminal ${VMID}"
    fi
    ip="$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null \
      | jq -r '.[] | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"' 2>/dev/null \
      | grep -v '^169\.254\.' | head -n1 || true)"
    if [[ -z "$ip" ]]; then
      printf '.' >&2
      sleep 5
    fi
  done
  printf '\n' >&2
  echo "$ip"
}

wait_for_ssh() {
  local ip="$1" tries=0
  until ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      -i "$SSH_KEY_FILE" "${SSH_USER}@${ip}" true 2>/dev/null; do
    if (( tries++ >= 60 )); then
      printf '\n' >&2
      die "Timed out after 5 minutes waiting for SSH on ${ip}. If ${ip} was used by an earlier VM, remove the stale key with: ssh-keygen -R ${ip}"
    fi
    printf '.' >&2
    sleep 5
  done
  printf '\n' >&2
}

# --------------------------------------------------------------------------
# Remote bootstrap (Docker + Buzz), rendered from a template and streamed
# over SSH so failures abort the installer immediately with real output.
# --------------------------------------------------------------------------
render_remote_bootstrap() {
  local out="$1"
  cat > "$out" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

BUZZ_IMAGE="@@BUZZ_IMAGE@@"
BUZZ_REF="@@BUZZ_REF@@"
BUZZ_REPO_URL="@@BUZZ_REPO_URL@@"
DOMAIN="@@DOMAIN@@"
OWNER_PUBKEY="@@OWNER_PUBKEY@@"
VM_IP="@@VM_IP@@"

log() { printf '\n==> %s\n' "$*"; }

log "Installing prerequisites (gnupg, ca-certificates, curl)"
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl gnupg

log "Installing Docker Engine (official Docker apt repository)"
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin git openssl

# Also usable without sudo on a fresh login (group membership needs a new
# session to take effect - this bootstrap keeps using sudo explicitly so
# it doesn't depend on that).
sudo usermod -aG docker "$(whoami)"

log "Fetching Buzz's official deployment files (ref: ${BUZZ_REF})"
sudo mkdir -p /opt/buzz
sudo chown "$(id -u):$(id -g)" /opt/buzz
cd /opt/buzz
if [[ ! -d src/.git ]]; then
  rm -rf src
  git clone --quiet --filter=blob:none --sparse --branch "$BUZZ_REF" --depth 1 "$BUZZ_REPO_URL" src
fi
cd src
git sparse-checkout set deploy/compose >/dev/null
cd deploy/compose
[[ -f compose.yml ]] || { echo "compose.yml missing after checkout - upstream repo layout may have changed. Aborting." >&2; exit 1; }

# Upstream pins a minio/minio image release (2025-09) that no longer ships
# curl, but still uses a curl-based healthcheck - so the minio container
# never reports healthy (see minio/minio#18373 upstream). Patch it to the
# officially recommended replacement, which the same image does support.
# Scoped to only the minio block (found via the unique curl/URL line, then
# a small line window after it) since other services share the same
# 'retries: 12' value and must not be touched.
MINIO_HC_LINE="$(grep -n '"curl", "-f", "http://127.0.0.1:9000/minio/health/live"' compose.yml | head -n1 | cut -d: -f1)"
if [[ -n "$MINIO_HC_LINE" ]]; then
  log "Patching the upstream MinIO healthcheck (curl -> mc ready local) and widening its start-up budget"
  END_LINE=$((MINIO_HC_LINE + 5))
  sed -i "${MINIO_HC_LINE},${END_LINE}s#\[\"CMD\", \"curl\", \"-f\", \"http://127.0.0.1:9000/minio/health/live\"\]#[\"CMD\", \"mc\", \"ready\", \"local\"]#" compose.yml
  sed -i "${MINIO_HC_LINE},${END_LINE}s/retries: 12/retries: 30/" compose.yml
  sed -i "${MINIO_HC_LINE},${END_LINE}s/start_period: 10s/start_period: 60s/" compose.yml
else
  echo "NOTE: expected MinIO healthcheck line not found in compose.yml (upstream may have already fixed this) - left untouched." >&2
fi

cp -n .env.example .env

set_env() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$val" '
    BEGIN { done = 0 }
    index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' .env > "$tmp"
  mv "$tmp" .env
}

randhex() { openssl rand -hex "$1"; }

log "Generating random secrets for Postgres, Redis, MinIO and git hooks"
set_env POSTGRES_PASSWORD         "$(randhex 24)"
set_env REDIS_PASSWORD            "$(randhex 24)"
set_env BUZZ_S3_ACCESS_KEY        "$(randhex 16)"
set_env BUZZ_S3_SECRET_KEY        "$(randhex 32)"
set_env BUZZ_GIT_HOOK_HMAC_SECRET "$(randhex 32)"
set_env BUZZ_IMAGE                "$BUZZ_IMAGE"

log "Pulling the Buzz image (${BUZZ_IMAGE})"
sudo docker pull -q "$BUZZ_IMAGE" >/dev/null

genkey() {
  sudo docker run --rm --entrypoint /usr/local/bin/buzz-admin "$BUZZ_IMAGE" generate-key
}

log "Generating the relay's own signing key (BUZZ_RELAY_PRIVATE_KEY)"
RELAY_KEY_OUT="$(genkey)"
RELAY_SECRET="$(printf '%s\n' "$RELAY_KEY_OUT" | awk -F': ' '/^Secret key:/{print $2}')"
[[ -n "$RELAY_SECRET" ]] || { echo "Could not parse a secret key from 'buzz-admin generate-key'." >&2; exit 1; }
set_env BUZZ_RELAY_PRIVATE_KEY "$RELAY_SECRET"

OWNER_SECRET=""
if [[ -z "$OWNER_PUBKEY" ]]; then
  log "Generating a fresh owner identity - this becomes YOUR login for Buzz Desktop"
  OWNER_KEY_OUT="$(genkey)"
  OWNER_PUBKEY="$(printf '%s\n' "$OWNER_KEY_OUT" | awk -F': ' '/^Public key:/{print $2}')"
  OWNER_SECRET="$(printf '%s\n' "$OWNER_KEY_OUT" | awk -F': ' '/^Secret key:/{print $2}')"
  [[ -n "$OWNER_PUBKEY" && -n "$OWNER_SECRET" ]] || { echo "Could not parse the generated owner keypair." >&2; exit 1; }
else
  log "Using the owner pubkey supplied on the command line"
fi
set_env RELAY_OWNER_PUBKEY "$OWNER_PUBKEY"

COMPOSE_TLS=false
if [[ -n "$DOMAIN" ]]; then
  set_env BUZZ_DOMAIN            "$DOMAIN"
  set_env RELAY_URL              "wss://${DOMAIN}"
  set_env BUZZ_MEDIA_BASE_URL    "https://${DOMAIN}/media"
  set_env BUZZ_MEDIA_SERVER_DOMAIN "$DOMAIN"
  set_env BUZZ_CORS_ORIGINS      "https://${DOMAIN}"
  COMPOSE_TLS=true
else
  set_env BUZZ_DOMAIN            "$VM_IP"
  set_env RELAY_URL              "ws://${VM_IP}:3000"
  set_env BUZZ_MEDIA_BASE_URL    "http://${VM_IP}:3000/media"
  set_env BUZZ_MEDIA_SERVER_DOMAIN "$VM_IP"
  set_env BUZZ_CORS_ORIGINS      "http://${VM_IP}:3000"
fi

chmod 600 .env
chmod +x run.sh

COMPOSE_FILES=(-f compose.yml)
[[ "$COMPOSE_TLS" == "true" ]] && COMPOSE_FILES+=(-f compose.caddy.yml)
compose_raw() { sudo docker compose --env-file .env "${COMPOSE_FILES[@]}" "$@"; }

dump_diagnostics() {
  echo
  echo "===================== DIAGNOSTICS (start failed) ====================="
  echo "--- container status ---"
  compose_raw ps -a || true
  echo
  echo "--- compose logs, all services, last 200 lines each ---"
  compose_raw logs --no-color --tail=200 || true
  echo
  echo "--- MinIO container health-check detail (if present) ---"
  local minio_cid
  minio_cid="$(compose_raw ps -q minio 2>/dev/null || true)"
  if [[ -n "$minio_cid" ]]; then
    sudo docker inspect --format '{{json .State.Health}}' "$minio_cid" || true
  else
    echo "(no minio container id found)"
  fi
  echo "========================================================================"
}

log "Pulling all images first (Postgres, Redis, MinIO, Buzz$( [[ "$COMPOSE_TLS" == "true" ]] && echo ", Caddy"))"
if [[ "$COMPOSE_TLS" == "true" ]]; then
  sudo BUZZ_COMPOSE_TLS=true ./run.sh pull
else
  sudo ./run.sh pull
fi

log "Starting Buzz with Docker Compose"
START_OK=1
if [[ "$COMPOSE_TLS" == "true" ]]; then
  sudo BUZZ_COMPOSE_TLS=true ./run.sh start || START_OK=0
else
  sudo ./run.sh start || START_OK=0
fi

if [[ "$START_OK" != "1" ]]; then
  dump_diagnostics
  echo "Buzz failed to start. The diagnostics above show the actual container" >&2
  echo "logs and health-check output - please include them when reporting this." >&2
  exit 1
fi

sudo ln -sf "$(pwd)/run.sh" /usr/local/bin/buzzctl

echo
echo "===================== BUZZ INSTALL SUMMARY ====================="
sudo ./run.sh status || true
echo "-------------------------------------------------------------"
if [[ -n "$DOMAIN" ]]; then
  echo "Relay URL:        wss://${DOMAIN}"
else
  echo "Relay URL:        ws://${VM_IP}:3000"
  echo "NOTE: no --domain was given, so there is no TLS/Caddy in front of"
  echo "      this relay. Traffic is unencrypted. Re-run with --domain"
  echo "      once you have DNS pointed at this host for production use."
fi
echo "Owner public key:  ${OWNER_PUBKEY}"
if [[ -n "$OWNER_SECRET" ]]; then
  echo
  echo "*** OWNER SECRET KEY - SAVE THIS NOW, IT WILL NOT BE SHOWN AGAIN ***"
  echo "${OWNER_SECRET}"
  echo "Import this into the Buzz Desktop app ('Import an existing key') to"
  echo "sign in as the relay owner/admin."
fi
echo
echo "Buzz currently ships without a production rate limiter. Do not"
echo "expose this relay to the open internet without a firewall, VPN,"
echo "or reverse-proxy protection in front of it."
echo "==================================================================="
REMOTE
}

run_remote_bootstrap() {
  local ip="$1" rendered="${TMP_DIR}/remote-bootstrap.rendered.sh"
  render_remote_bootstrap "${TMP_DIR}/remote-bootstrap.sh"
  sed \
    -e "s#@@BUZZ_IMAGE@@#${BUZZ_IMAGE}#g" \
    -e "s#@@BUZZ_REF@@#${BUZZ_REF}#g" \
    -e "s#@@BUZZ_REPO_URL@@#${BUZZ_REPO_URL}#g" \
    -e "s#@@DOMAIN@@#${DOMAIN}#g" \
    -e "s#@@OWNER_PUBKEY@@#${OWNER_PUBKEY}#g" \
    -e "s#@@VM_IP@@#${ip}#g" \
    "${TMP_DIR}/remote-bootstrap.sh" > "$rendered"

  local logfile="${STATE_DIR}/vm-${VMID}/install.log"
  install -m 600 /dev/null "$logfile"

  log "Installing Docker and Buzz inside the VM (this takes a few minutes)"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_FILE" \
      "${SSH_USER}@${ip}" 'bash -s' < "$rendered" | tee "$logfile"
}

# --------------------------------------------------------------------------
# Uninstall
# --------------------------------------------------------------------------
do_uninstall() {
  require_root
  require_proxmox
  local id="$UNINSTALL_VMID"
  qm status "$id" >/dev/null 2>&1 || die "VM ${id} does not exist."
  confirm "This will STOP and PERMANENTLY DESTROY VM ${id}, including all Buzz data on its disks. Continue?"
  qm stop "$id" --timeout 30 >/dev/null 2>&1 || true
  qm destroy "$id" --purge >/dev/null
  rm -rf "${STATE_DIR:?}/vm-${id}"
  ok "VM ${id} destroyed."
  exit 0
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
  require_root
  require_proxmox
  require_cmds

  [[ -n "$UNINSTALL_VMID" ]] && do_uninstall

  [[ -n "$VMID" ]] || VMID="$(pvesh get /cluster/nextid)"
  qm status "$VMID" >/dev/null 2>&1 && die "VMID ${VMID} already exists. Pick another with --vmid."

  if [[ -z "$STORAGE" ]]; then
    STORAGE="$(pick_image_storage)" \
      || die "No storage with content type 'images' found. Specify one with --storage <name>."
  fi
  SNIPPET_STORAGE="$(ensure_snippet_storage)" \
    || die "No storage supports 'snippets' and enabling it on 'local' failed. Run: pvesm set local --content <existing-content>,snippets"
  [[ -n "$BRIDGE" ]] || BRIDGE="$(detect_bridge)"
  [[ -n "$BRIDGE" ]] || die "No network bridge found. Specify one with --bridge <name>."

  log "Planned configuration"
  cat <<SUMMARY
    VM ID:              ${VMID}
    VM name:             ${VM_NAME}
    Disk storage:        ${STORAGE}
    Cloud-init snippets:  ${SNIPPET_STORAGE}
    Network bridge:       ${BRIDGE}
    CPU / RAM / Disk:     ${CORES} cores (${CPU_TYPE}) / ${MEMORY} MB / ${DISK_SIZE}
    Domain:               ${DOMAIN:-<none - uses the VM DHCP IP, no TLS>}
    Buzz container image: ${BUZZ_IMAGE}
    Buzz owner identity:  ${OWNER_PUBKEY:-<will be generated for you>}
SUMMARY
  confirm "Create this VM and install Buzz now?"

  TMP_DIR="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$TMP_DIR'" EXIT
  download_debian_image "$TMP_DIR"

  mkdir -p "${STATE_DIR}/vm-${VMID}"
  chmod 700 "$STATE_DIR" "${STATE_DIR}/vm-${VMID}"
  SSH_KEY_FILE="${STATE_DIR}/vm-${VMID}/id_ed25519"
  ssh-keygen -q -t ed25519 -N "" -C "proxmox-buzz-${VMID}" -f "$SSH_KEY_FILE"
  ok "Generated a dedicated SSH key for this VM: ${SSH_KEY_FILE}"

  write_cloud_init_snippet
  create_vm

  log "Starting VM ${VMID}"
  qm start "$VMID" >/dev/null

  VM_IP="$(wait_for_ip)"
  ok "VM is up at ${VM_IP}"
  wait_for_ssh "$VM_IP"
  ok "SSH is ready"

  # Let cloud-init finish package installs before we pile Docker on top.
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_FILE" \
    "${SSH_USER}@${VM_IP}" 'sudo cloud-init status --wait >/dev/null 2>&1 || true'

  run_remote_bootstrap "$VM_IP"

  qm set "$VMID" --onboot 1 >/dev/null

  cat <<DONE

Done. VM ${VMID} (${VM_NAME}) is running Buzz.

SSH in any time with:
  ssh -i ${SSH_KEY_FILE} ${SSH_USER}@${VM_IP}

Manage the stack from inside the VM with:
  sudo buzzctl status | logs | stop | start | upgrade | backup-hint

Full install log (contains secrets - move it to a password manager, then
delete it from disk):
  ${STATE_DIR}/vm-${VMID}/install.log

Remove this VM entirely with:
  bash -c "\$(curl -fsSL ${INSTALL_URL})" -- --uninstall ${VMID}
DONE
}

main "$@"
