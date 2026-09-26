# VitalRoute Receiver — Deployment and Operations

This is the runbook for running the receiver as a managed service on a
single host with Docker. For the HTTP contract see [API.md](API.md); for a
development overview see [README.md](README.md).

The supported installation is **Docker Compose** (the receiver container is
standard-library Python, non-root, read-only root filesystem, loopback-only
backend port). The files involved:

| File | Purpose |
|---|---|
| `server/Dockerfile` | Image: `python:3.12-slim`, dedicated UID 64000, no pip dependencies. |
| `server/deploy/docker-compose.yml` | The stack: restart policy, health check, named data volume, token secret, log rotation. |
| `server/deploy/install.sh` | Repeatable installer (clone at a pinned revision, token creation, build, health wait). |
| `server/deploy/backup.sh` | Consistent online SQLite backup (records + tombstones) with integrity check. |
| `server/deploy/restore.sh` | Verified restore over the live volume. |

## Fresh installation

Requirements on the host: Linux, root, `docker` + `docker compose` v2,
`git`, `python3`. Then:

```sh
curl -fsSL https://raw.githubusercontent.com/kaishi00/vitalroute/<full commit sha>/server/deploy/install.sh \
  | sudo env VITALROUTE_REV=<full commit sha> bash
```

Both placeholders are the same commit: the URL fetches the installer from
it and `VITALROUTE_REV` tells it what to deploy.

Or from a checkout:

```sh
git clone https://github.com/kaishi00/vitalroute.git
cd vitalroute && git checkout <full commit sha>
sudo bash server/deploy/install.sh
```

What the installer does (and re-does safely on rerun):

1. Checks prerequisites with actionable errors.
2. Deploys the pinned revision: an explicit `VITALROUTE_REV` always wins
   (fetch + checkout), wherever the script runs from; without it, the
   script deploys the checkout it lives in.
3. Creates `/srv/vitalroute` (mode 0700) and **generates a strong token
   only if none exists** (`secrets.token_urlsafe(32)`). The token file is
   owned by UID 64000 (the container user — compose file-secrets are plain
   bind mounts, so ownership is not remapped) with mode 0400: readable only
   by the receiver and by root via `sudo`. An existing token is never
   overwritten or printed; a blank/short token file is regenerated.
4. Builds the image and starts the stack (`restart: unless-stopped`, so it
   survives reboots and crashes).
5. Waits for the container health check (an authenticated, non-mutating
   `GET /v1/health` inside the container) and fails loudly otherwise.
6. Records the deployed revision in `/srv/vitalroute/.installed-revision`.

Paths and port can be overridden — see the header of `install.sh`
(`VITALROUTE_INSTALL_DIR`, `VITALROUTE_DATA_DIR`, `VITALROUTE_HOST_PORT`,
`VITALROUTE_PROJECT_NAME`).

**Layout after installation**

| Path | Contents |
|---|---|
| `/opt/vitalroute` | Code checkout at the pinned revision. |
| `/srv/vitalroute/token` | Bearer token (UID 64000, mode 0400). `sudo cat` it when configuring the app. |
| `/srv/vitalroute/backups/` | Backups created by `backup.sh` (root, 0600). |
| `/srv/vitalroute/.installed-revision` | Deployed commit + date. |
| Docker volume `<project>_vitalroute-data` | The SQLite database (`records.sqlite3`, WAL mode). Survives container recreation and upgrades. |

The backend listens on `127.0.0.1:8790` on the host only. Nothing outside
the host can reach it until you expose it over HTTPS (next section).

## HTTPS via Tailscale Serve (private, tailnet only)

The receiver requires HTTPS from the iOS app. On a host already enrolled in
a tailnet (with the HTTPS/MagicDNS certificate enabled), `tailscale serve`
gives the endpoint a publicly-trusted Let's Encrypt certificate for
`<machine>.<tailnet>.ts.net`, reachable **only from your tailnet** (no
public exposure; Funnel is not used).

Mount the receiver's two paths next to any existing handler (more specific
paths win over a `/` handler, which keeps serving):

```sh
sudo tailscale serve --bg --https=443 --set-path=/v1/records http://127.0.0.1:8790/v1/records
sudo tailscale serve --bg --https=443 --set-path=/v1/health  http://127.0.0.1:8790/v1/health
sudo tailscale serve --bg --https=443 --set-path=/mcp        http://127.0.0.1:8791/mcp
```

The path is repeated on the target deliberately: Tailscale's docs do not
specify whether a mount prefix is preserved or stripped before proxying,
and this form produces the correct request path at the receiver either way.
Verify empirically before relying on it:

```sh
tailscale serve status
curl -s -o /dev/null -w '%{http_code}\n' https://<machine>.<tailnet>.ts.net/v1/health   # expect 401 (alive, auth required)
```

If the plain-target form (`--set-path=/v1/records http://127.0.0.1:8790`)
works on your Tailscale version, it is equivalent — the check above decides.

`--bg` persists the configuration across reboots. To remove only these
mounts later (the backend keeps running):

```sh
sudo tailscale serve --https=443 --set-path=/v1/records off
sudo tailscale serve --https=443 --set-path=/v1/health  off
sudo tailscale serve --https=443 --set-path=/mcp        off
```

**Do not** run `tailscale serve reset` or `--https=443 off` on a host that
serves anything else: those remove *all* handlers on the port, including
ones you did not add here.

The destination URL for the iOS app is then:

```
https://<machine>.<tailnet>.ts.net/v1/records
```

### Alternative: any reverse proxy

Terminate TLS with Caddy/nginx/traefik in front of `127.0.0.1:8790` and
point the certificate at a hostname you control. Requirements: valid
certificate (the app does not accept self-signed CAs), HTTPS only, and no
rewriting of the two paths (`/v1/records`, `/v1/health`) or headers
(`Authorization`).

## Agent access: the read-only MCP query service

> A ready-to-hand agent briefing (connect instructions, tool semantics,
> example calls, and a copy-paste system-prompt block) lives in
> [AGENT.md](AGENT.md).

The stack also runs `mcp_server.py` — a read-only Model Context Protocol
server that lets an agent query your stats without SSH and without any
write path. It opens SQLite with `mode=ro` plus `PRAGMA query_only` (the
volume is mounted read-write only because SQLite may need to recreate the
WAL sidecars the receiver removes between writes), exposes only three
fixed tools (list metrics, daily aggregates, recent records — no arbitrary
SQL), excludes samples deleted on the phone, and authenticates with its
own bearer token so agent access revokes independently of ingestion.

| Item | Value |
|---|---|
| MCP endpoint (with the serve mount above) | `https://<machine>.<tailnet>.ts.net/mcp` |
| Query token | `/srv/vitalroute/query-token` (UID 64000, 0400; `sudo cat` it) |
| Transport | MCP streamable HTTP (JSON-RPC POST; no server push) |
| Tools | `list_metrics`, `daily_stats`, `recent_records` |

Adding it to an MCP client (e.g. ZCode's `~/.zcode/cli/config.json`):

```json
{
  "mcpServers": {
    "vitalroute": {
      "type": "http",
      "url": "https://<machine>.<tailnet>.ts.net/mcp",
      "headers": { "Authorization": "Bearer <query token>" }
    }
  }
}
```

Then ask the agent naturally, e.g. "what's my average resting heart rate
this week" — the tool descriptions guide it.

Rotate the query token like the ingest token (same ownership rules:
UID 64000, mode 0400, then `docker compose ... up -d --force-recreate mcp`).
To disable agent access entirely, remove the serve mount and/or run
`docker compose -p vitalroute stop mcp`; ingestion is unaffected.

## Day-2 operations

All examples assume the defaults; pass the same overrides you installed
with. Run from a checkout of the deployed revision (or `cd
/opt/vitalroute/server/deploy`).

```sh
# status / health (from the host; -f works from any directory)
docker compose -p vitalroute -f /opt/vitalroute/server/deploy/docker-compose.yml ps   # healthy = receiving
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8790/v1/health              # 401 = alive

# start / stop (data and token are preserved)
docker compose -p vitalroute -f /opt/vitalroute/server/deploy/docker-compose.yml stop receiver
docker compose -p vitalroute -f /opt/vitalroute/server/deploy/docker-compose.yml start receiver

# safe log inspection (logs contain method, path, status, sizes — never
# tokens, headers, or record contents by design)
docker compose -p vitalroute -f /opt/vitalroute/server/deploy/docker-compose.yml logs --tail 100 receiver
```

### Upgrade

```sh
sudo VITALROUTE_REV=<new full commit sha> bash /opt/vitalroute/server/deploy/install.sh
```

The checkout moves to the new revision, the image is rebuilt, and the
container is recreated in place. The data volume and the token are not
touched. The revision file is updated.

**Schema compatibility (pre-release policy).** There is no migration
machinery between storage-schema generations. When the receiver opens a
database that does not match its schema generation, it refuses to start
rather than discard health data. To proceed with a reset, start the
container once with `VITALROUTE_ALLOW_SCHEMA_RESET=1` in the environment
(e.g. add it to the compose environment for one `up -d --force-recreate`,
then remove it): the database is recreated empty and the receiver logs one
line. Then re-sync from the device, or restore from a backup taken before
the upgrade. Verify afterwards with the connection test
(`apiVersion >= 3`).

### Token rotation

1. Generate a replacement with the receiver's ownership and permissions:
   ```sh
   sudo sh -c 'umask 377; python3 -c "import secrets; print(secrets.token_urlsafe(32), end=\"\")" > /srv/vitalroute/token.new && chown 64000:64000 /srv/vitalroute/token.new && chmod 400 /srv/vitalroute/token.new'
   ```
2. Replace atomically: `sudo mv /srv/vitalroute/token.new /srv/vitalroute/token`
   (verify with `stat -c '%u %a' /srv/vitalroute/token` → `64000 400`).
3. Recreate the container:
   `docker compose -p vitalroute -f /opt/vitalroute/server/deploy/docker-compose.yml up -d --force-recreate receiver`.
   A plain `restart` is **not** enough: the secret is a bind mount, and the
   atomic replace swapped the inode — only recreation re-mounts the new
   file. The health check turns healthy only when the new token file is
   readable and valid.
4. Update the API key in the iOS app (Destination → Replace API key).

Rotation invalidates all outstanding tokens immediately on recreation. The
receiver keeps previously ingested data — records are not credential-bound.

### Backup and restore

```sh
sudo bash server/deploy/backup.sh                       # → /srv/vitalroute/backups/records-<UTC>.sqlite3
sudo bash server/deploy/restore.sh /srv/vitalroute/backups/records-<UTC>.sqlite3
```

`backup.sh` uses SQLite's online-backup API against the live volume, so the
receiver keeps serving; the output is transactionally consistent (records
and tombstones together) and integrity-checked. `restore.sh` verifies the
backup first, swaps it into the volume (WAL/SHM sidecars removed), restarts
the receiver, and confirms health — if any step fails, the receiver is
restarted on the database currently in the volume. (If the script is killed
hard mid-restore — SIGKILL cannot run traps — restart manually:
`docker compose -p vitalroute -f /opt/vitalroute/server/deploy/docker-compose.yml up -d`.)
Treat backup files like the live database: they contain health records;
keep them on the same protected storage (`/srv/vitalroute/backups` is mode
0700, files 0600).

### Uninstall (keeping data)

```sh
docker compose -p vitalroute -f /opt/vitalroute/server/deploy/docker-compose.yml down   # no -v: keeps the data volume
sudo tailscale serve --https=443 --set-path=/v1/records off   # if exposed
sudo tailscale serve --https=443 --set-path=/v1/health off
```

To also remove the data (irreversible — this deletes every received
record):

```sh
docker volume rm vitalroute_vitalroute-data
sudo rm -rf /srv/vitalroute /opt/vitalroute
```

## Verifying an installation (synthetic data only)

The installer's health check plus this sequence from a client that will use
the endpoint (never with real health data). The bearer token is passed via
a curl config file so it never appears in a process command line:

```sh
URL="https://<machine>.<tailnet>.ts.net"
hdr="$(mktemp)"; chmod 600 "$hdr"
printf 'header = "Authorization: Bearer %s"\n' "$(sudo cat /srv/vitalroute/token)" >"$hdr"

curl -s -o /dev/null -w '%{http_code}\n' "$URL/v1/health"        # 401 unauthorized
curl -s -K "$hdr" "$URL/v1/health"                                # 200 + apiVersion 3 + capabilities
rm -f "$hdr"
# The synthetic sender has no token-file option; run it from an admin
# machine where the token is already protected.
python3 send_synthetic_data.py --url "$URL/v1/records" \
  --token "$(sudo cat /srv/vitalroute/token)" --count 5
```

Preferably, run the whole verification against a **throwaway stack** so the
operational database never sees synthetic rows:

```sh
sudo VITALROUTE_PROJECT_NAME=vr-verify VITALROUTE_DATA_DIR=/srv/vitalroute-verify \
     VITALROUTE_HOST_PORT=8791 bash server/deploy/install.sh
# ...verify against 127.0.0.1:8791 (or point a serve mount at it)...
sudo docker compose -p vr-verify -f server/deploy/docker-compose.yml down -v
sudo rm -rf /srv/vitalroute-verify
```

`down -v` removes the throwaway volume; the operational stack
(`-p vitalroute`) and its data are untouched.

## Security notes

- The container runs as UID 64000 (no root), with a read-only root
  filesystem, `no-new-privileges`, all capabilities dropped, and only the
  data volume and `/tmp` tmpfs writable.
- The bearer token exists only in `/srv/vitalroute/token` (owned by the
  container UID 64000, mode 0400 — readable by the receiver and by root
  via `sudo` only); it is never in the image, the compose file, command
  lines, or logs. It is compared in constant time by the receiver.
- The backend is published to host loopback only; remote access requires
  the TLS layer above, which the tailnet already authenticates.
- Backups are root-owned 0600 under a 0700 directory; treat them exactly
  like the live database.
- Operational logs record method/path/status/sizes only.
