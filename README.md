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
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Proxmox-Buzz/main/install.sh)"
```

Mit eigener Domain (aktiviert automatisch Caddy + Let's Encrypt — DNS muss
vorher schon auf diesen Host zeigen):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Proxmox-Buzz/main/install.sh)" -- --domain buzz.example.com
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
sudo buzzctl status
sudo buzzctl logs
sudo buzzctl upgrade
```

`sudo` ist nötig, weil `buzzadmin` erst nach einem *neuen* Login zur
`docker`-Gruppe gehört (die während der Installation gesetzte
Gruppenmitgliedschaft wirkt erst ab der nächsten Anmeldung). Da der
Cloud-Init-User passwortlosen Sudo-Zugriff hat, fragt das nicht nach
einem Passwort.

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

## Fehlerbehebung

**Script scheint bei "Waiting for the VM to boot..." oder beim SSH-Warten
hängen zu bleiben:** Seit Version 1.0.1 gibt das Script während der
Wartezeit Fortschritts-Punkte (`....`) auf der Konsole aus, damit klar ist,
dass es noch arbeitet. Wenn es nach ca. 5 Minuten einen Timeout-Fehler
wirft: Prüfe, ob die VM überhaupt eine IP bekommen hat
(`qm guest cmd <vmid> network-get-interfaces`) und ob dein SSH-Client die
Verbindung ablehnt, weil unter derselben IP früher schon mal eine andere
VM lief (`ssh-keygen -R <ip>` entfernt den alten Host-Key aus
`known_hosts`).

**Nach einem fehlgeschlagenen/abgebrochenen Lauf bleibt eine halb
eingerichtete VM zurück:** Mit `install.sh --uninstall <vmid>` sauber
entfernen und danach erneut installieren.

**"WARNING: Sum of all thin volume sizes ... exceeds the size of thin pool"**
beim Erstellen der VM: Das ist eine reguläre Proxmox-Warnung bei
Thin-Provisioning (dein Storage ist überbucht, aber noch nicht voll) und
kein Installationsfehler — die Installation läuft trotzdem normal weiter.

## Bekannte Fixes (Changelog)

- **1.0.4** — Behoben: `dependency failed to start: container
  buzz-prod-minio-1 is unhealthy` beim Start des Compose-Stacks. Das ist
  ein **Upstream-Bug in Buzz's `compose.yml`**: dort ist für den
  MinIO-Container ein `curl`-basierter Healthcheck hinterlegt, aber die
  gepinnte `minio/minio`-Image-Version (September 2025) enthält seit Ende
  2023 gar kein `curl` mehr ([minio/minio#18373](https://github.com/minio/minio/issues/18373))
  — der Healthcheck kann dadurch nie erfolgreich sein. Der Installer
  patcht `compose.yml` jetzt automatisch auf den offiziell von MinIO
  empfohlenen Ersatz-Healthcheck `mc ready local` (das MinIO-Image bringt
  den `mc`-Client mit). Der Patch ist defensiv: Falls Buzz das
  irgendwann selbst behebt, findet der Installer die alte Zeile nicht
  mehr und lässt `compose.yml` unangetastet.

- **1.0.3** — Behoben: `permission denied while trying to connect to the
  docker API at unix:///var/run/docker.sock` beim Start des Stacks. Die
  vorherigen Schritte (Image-Pull, `buzz-admin generate-key`) liefen
  explizit mit `sudo docker ...` und funktionierten deshalb, aber
  `./run.sh start` selbst rief `docker compose` ohne `sudo` auf — und der
  frisch angelegte VM-User war zu diesem Zeitpunkt der laufenden
  SSH-Sitzung noch nicht wirksam Mitglied der `docker`-Gruppe (das greift
  erst nach einem neuen Login). `run.sh` wird jetzt konsequent mit `sudo`
  aufgerufen; der User wird zusätzlich per `usermod -aG docker` in die
  Gruppe aufgenommen, damit ein *neuer* SSH-Login später auch ohne
  `sudo` funktioniert. `buzzctl`-Befehle in dieser README nutzen daher
  vorsorglich `sudo`.
- **1.0.2** — Behoben: `gpg: command not found` beim Einrichten des
  Docker-APT-Repos, weil das Debian-13-GenericCloud-Image `gnupg` nicht
  vorinstalliert hat. Wird jetzt vorher explizit installiert. Außerdem:
  die Hinweistexte zum Entfernen einer fehlgeschlagenen VM verwendeten
  `$0`, was bei `bash -c "$(curl ...)"`-Aufrufen nur `bash` ergibt und
  keinen funktionierenden Befehl liefert — jetzt wird der volle,
  copy-paste-fähige Befehl ausgegeben. Außerdem: `<DEIN-USER>`-Platzhalter
  in dieser README durch die echte Repo-URL ersetzt.
- **1.0.1** — Behoben: `log()`/`ok()`-Statusmeldungen wurden versehentlich
  über stdout statt stderr ausgegeben. Da die IP-Ermittlung
  (`wait_for_ip`) ihren Rückgabewert per `$(...)`-Befehlssubstitution
  einliest, landete die Log-Zeile *innerhalb* der ermittelten IP-Adresse,
  wodurch der anschließende SSH-Verbindungsaufbau fehlschlug und das
  Script wie eingefroren wirkte. Zusätzlich gibt es jetzt
  Fortschritts-Punkte während der Wartezeit.



Dieses Repository (Installer/Wrapper) steht unter der [MIT-Lizenz](LICENSE).
Buzz selbst ist ein separates Projekt von Block, Inc. unter Apache License
2.0 und ist von dieser Lizenz nicht erfasst. Details und alle verwendeten
Fremdkomponenten: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Keine Telemetrie. Keine Analytics. Keine eingebetteten API-Keys.
