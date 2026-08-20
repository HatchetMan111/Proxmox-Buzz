# proxmox-buzz

Ein Ein-Zeilen-Installer im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/),
der [Buzz](https://github.com/block/buzz) — die "Hive Mind"-Kommunikationsplattform
für Menschen und AI-Agenten von Block, Inc. — automatisch auf einem
Proxmox-VE-Host installiert.

**Nicht verbunden mit Proxmox Server Solutions GmbH oder Block, Inc.**
Siehe [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Architektur

```
Proxmox VE Host
  └─ QEMU-VM (Debian 13 "Trixie", Cloud-Init)
       └─ Docker Engine
            └─ docker compose (offizielles Buzz-Bundle)
                 ├─ Postgres
                 ├─ Redis
                 ├─ MinIO (S3-kompatibler Objektspeicher)
                 ├─ Buzz-Relay (git-data-Volume)
                 └─ Caddy (nur mit --domain, automatisches HTTPS)
```

Warum eine VM und kein LXC-Container? Proxmox selbst empfiehlt, Docker-Workloads
in einer QEMU-VM statt in einem LXC-Container zu betreiben, da die Isolation
zwischen Container-Engine und Proxmox-Host dort deutlich stärker ist. Debian 13
bietet dafür offizielle GenericCloud-Images mit Cloud-Init-Unterstützung.

`install.sh` **kopiert Buzz's Quellcode nicht in dieses Repository.** Es lädt
zur Installationszeit ausschließlich die offiziellen, unveränderten
Deployment-Dateien (`deploy/compose/`) sowie das offizielle Container-Image
direkt von `github.com/block/buzz` bzw. `ghcr.io/block/buzz` herunter.

## Installation

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/<DEIN-USER>/proxmox-buzz/main/install.sh)"
```

Mit eigener Domain (aktiviert automatisch Caddy + Let's Encrypt — DNS muss
vorher schon auf diesen Host zeigen):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/<DEIN-USER>/proxmox-buzz/main/install.sh)" -- --domain buzz.example.com
```

Das Script fragt vor jeder Änderung am System einmal um Bestätigung
(`--yes`/`-y` überspringt das).

### Was das Script automatisch macht

- prüft, dass es wirklich auf einem Proxmox-VE-8/9-Host läuft und als root
- erkennt automatisch eine passende VM-Storage, eine Storage für
  Cloud-Init-Snippets sowie die Netzwerk-Bridge (i. d. R. `vmbr0`)
- wählt automatisch eine freie VM-ID
- lädt das offizielle Debian-13-GenericCloud-Image herunter und
  verifiziert es per SHA512 gegen Debians veröffentlichte Prüfsummen
- erstellt eine QEMU-VM (Standard: 2 vCPU / 4 GB RAM / 20 GB Disk) mit
  Cloud-Init, eigenem SSH-Schlüsselpaar und deaktivierter Passwort-Anmeldung
- installiert Docker Engine + Compose-Plugin nach offizieller
  Docker-Dokumentation
- lädt Buzz's offizielle `deploy/compose`-Dateien (schlanker, sparse
  `git clone`, kein voller Repo-Checkout)
- erzeugt zufällige Secrets für Postgres, Redis, MinIO und den
  Git-Hook-HMAC-Schlüssel
- generiert über Buzz's eigenes `buzz-admin generate-key` sowohl den
  Signaturschlüssel des Relays als auch (sofern nicht per
  `--owner-pubkey` angegeben) eine neue Owner-Identität
- startet den Stack über Buzz's eigenes `run.sh`, das per
  `docker compose up -d --wait` auf gesunde Healthchecks wartet
- richtet bei `--domain` automatisch Caddy + HTTPS ein
- aktiviert den VM-Autostart
- gibt am Ende VM-ID, IP, Relay-URL sowie den einmalig sichtbaren
  Owner-Secret-Key aus

## Optionen

| Option | Beschreibung | Standard |
|---|---|---|
| `--vmid <id>` | VM-ID | nächste freie ID |
| `--name <name>` | VM-Name | `buzz` |
| `--storage <name>` | Storage für die VM-Disk | Auto-Erkennung |
| `--bridge <name>` | Netzwerk-Bridge | Auto-Erkennung (`vmbr0`) |
| `--cores <n>` | CPU-Kerne | `2` |
| `--memory <mb>` | RAM in MB | `4096` |
| `--disk <size>` | Disk-Größe | `20G` |
| `--domain <fqdn>` | Öffentliche Domain, aktiviert Caddy/HTTPS | keine |
| `--owner-pubkey <hex>` | Vorhandenen 64-stelligen Hex-Pubkey als Owner verwenden | wird generiert |
| `--ssh-user <name>` | Admin-User in der VM | `buzzadmin` |
| `--buzz-image <ref>` | Buzz-Image | `ghcr.io/block/buzz:main` |
| `--buzz-ref <ref>` | Git-Ref für die Deploy-Dateien | `main` |
| `--yes`, `-y` | Keine Rückfrage | aus |
| `--uninstall <vmid>` | VM stoppen und löschen | – |

## Nach der Installation

```bash
ssh -i /root/.proxmox-buzz/vm-<id>/id_ed25519 buzzadmin@<VM-IP>
buzzctl status
buzzctl logs
buzzctl upgrade
```

Der Owner-Secret-Key erscheint **einmalig** in der Ausgabe und zusätzlich in
`/root/.proxmox-buzz/vm-<id>/install.log` (root-only, `chmod 600`). Speichere
ihn sofort in einem Passwort-Manager, importiere ihn in die Buzz-Desktop-App
("Import an existing key") und lösche danach die Log-Datei.

## Deinstallation

```bash
bash install.sh --uninstall <vmid>
```

Stoppt und löscht die VM inklusive aller Buzz-Daten unwiderruflich.

## Wichtige Hinweise

- **Kein Production-Rate-Limiter in Buzz.** Diesen Relay nicht ohne
  Firewall/VPN/Reverse-Proxy-Schutz direkt ins offene Internet stellen.
- **Ohne `--domain` läuft der Traffic unverschlüsselt** (`ws://`, keine
  TLS). Für den produktiven Einsatz `--domain` verwenden.
- **Image-Tag `:main` ist für frühes Testing gedacht.** Für produktive
  Deployments auf einen unveränderlichen `ghcr.io/block/buzz:sha-<7>`-Tag
  pinnen (`--buzz-image`) und bei neuen Buzz-Releases selbst aktualisieren.

## Lizenz

Dieses Repository (Installer/Wrapper) steht unter der [MIT-Lizenz](LICENSE).
Buzz selbst ist ein separates Projekt von Block, Inc. unter Apache License
2.0 und ist von dieser Lizenz nicht erfasst. Details und alle verwendeten
Fremdkomponenten: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Keine Telemetrie. Keine Analytics. Keine eingebetteten API-Keys.
