# VitalRoute Reference Receiver

A small receiving server for records exported by the VitalRoute iOS app. It
is intentionally minimal: Python 3 standard library only (no pip
dependencies), one SQLite database file, one Bearer token, two operations.

The HTTP contract is specified in [API.md](API.md); this document explains
how to run and deploy the receiver.

## What it does and does not do

- Receives batched health records over HTTPS, validates them strictly,
  persists them transactionally, and acknowledges them idempotently.
- Provides a connection-test operation that sends and stores nothing.
- Runs with no accounts, no web dashboard, no outbound connections, and no
  third-party services. (Agent reads go through the separate read-only MCP
  query service — see DEPLOYMENT.md — not this ingestion surface.)

Background delivery from the client, anchored incremental sync, deletion
propagation through contract v2 (see [API.md](API.md)), and a read-only
MCP query service for agent access (`mcp_server.py`; see
[DEPLOYMENT.md](DEPLOYMENT.md)) are implemented. Not in scope: accounts,
multi-user access, or any write path beyond ingestion.

For production installation as a managed Docker Compose service — including
HTTPS exposure, upgrades, token rotation, and backups — see
[DEPLOYMENT.md](DEPLOYMENT.md). Agents that query the data should be given
[AGENT.md](AGENT.md).

## Quick start

```sh
cd server

# 1. Generate a random token (no default credentials exist).
python3 -c "import secrets; print(secrets.token_urlsafe(32))"

# 2. Start the receiver bound to loopback only.
VITALROUTE_TOKEN="<paste token>" python3 receiver.py
# Listening on http://127.0.0.1:8787 (db: ./vitalroute.sqlite3)

# 3. Send synthetic records (no real health data involved).
python3 send_synthetic_data.py \
  --url http://127.0.0.1:8787/v1/records \
  --token "$VITALROUTE_TOKEN" --count 40
# Accepted: 40 new, 0 duplicate (of 40 sent)

# 4. Inspect what was stored.
sqlite3 vitalroute.sqlite3 'SELECT metric, COUNT(*) FROM records GROUP BY metric;'
```

`examples/synthetic_payload.json` is a small checked-in example payload;
`python3 send_synthetic_data.py --count 12 --dry-run` prints a fresh one.

## Configuration

All configuration comes from the environment or command-line flags; nothing
is committed. The receiver refuses to start without a token.

| Setting | Default | Purpose |
|---|---|---|
| `VITALROUTE_TOKEN` | — (required) | Bearer token, ≥ 16 chars. Generate with `secrets.token_urlsafe(32)`. |
| `VITALROUTE_TOKEN_FILE` | — | Read the token from a file instead (mutually exclusive with `VITALROUTE_TOKEN`). Suited to systemd `LoadCredential=`. |
| `VITALROUTE_HOST` | `127.0.0.1` | Bind address. Private by default; see HTTPS below. |
| `VITALROUTE_PORT` / `--port` | `8787` | Listen port. |
| `VITALROUTE_DB` / `--db` | `./vitalroute.sqlite3` | SQLite database path. Use an absolute path under systemd. |
| `VITALROUTE_MAX_BODY_BYTES` | `10485760` (10 MiB) | Request body cap. |
| `VITALROUTE_MAX_RECORDS_PER_BATCH` | `500` | Records per batch cap. |
| `VITALROUTE_TLS_CERT`, `VITALROUTE_TLS_KEY` | — | Optional direct TLS (see below). |

## Database storage guidance

Records live in a single SQLite file (WAL mode, `synchronous=FULL`). The
database contains real health records once you use the app against this
server — treat the file, and any backups of it, as sensitive:

- Put it on encrypted storage; restrict filesystem permissions to the
  service user (`chmod 600`, or store it under a dedicated directory).
- Back it up with the same care as any health record store; the file is the
  only copy of the data (the receiver is append-only and does not re-export).
- Each stored row keeps the record `id`, category, value, unit, UTC start/end
  timestamps, source/device strings, JSON metadata, plus receiver-side
  `batch_created_at` / `first_seen_at` for auditing.

## HTTPS

The receiver speaks plain HTTP and expects TLS to be terminated in front of
it (it binds to loopback by default, which is safe for local testing behind a
proxy on the same host). For a public endpoint, terminate TLS with any
reverse proxy and proxy to loopback. Example with Caddy (automatic
Let's Encrypt certificates):

```
health.example.org {
    reverse_proxy 127.0.0.1:8787
}
```

Example systemd unit:

```ini
[Unit]
Description=VitalRoute reference receiver
After=network.target

[Service]
DynamicUser=yes
Environment=VITALROUTE_HOST=127.0.0.1
Environment=VITALROUTE_PORT=8787
Environment=VITALROUTE_DB=/var/lib/vitalroute/records.sqlite3
LoadCredential=vitalroute-token:/etc/vitalroute/token
Environment=VITALROUTE_TOKEN_FILE=%d/vitalroute-token
StateDirectory=vitalroute
ExecStart=/usr/bin/python3 /opt/vitalroute/server/receiver.py
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
```

For small private deployments without a reverse proxy, the receiver can serve
TLS directly:

```sh
VITALROUTE_TOKEN=... python3 receiver.py --host 0.0.0.0 --port 8787 \
  --tls-cert /path/fullchain.pem --tls-key /path/privkey.pem
```

The certificate must be valid for the hostname you configure in the app; the
iOS client performs normal certificate validation and does not accept
self-signed certificates unless the device itself trusts the signing
authority.

## Tests

```sh
cd server
python3 -m unittest discover -s tests -v
```

The suite runs a real server on an ephemeral port per test with an isolated
temporary database and synthetic records only. It covers authentication,
connection-test semantics, validation, atomicity, idempotency, limits, error
safety, and concurrency.

## Simulator integration (macOS with Xcode)

`run_simulator_integration.sh` runs the full XCTest suite — including the
otherwise-skipped `ReceiverIntegrationTests` — against a real receiver serving
TLS on loopback, with synthetic records only. It issues a localhost
certificate with [mkcert](https://github.com/FiloSottile/mkcert), trusts the
CA **inside the simulator's own keychain** via `xcrun simctl keychain`
(a per-simulator testing facility; the app's production TLS validation is
never weakened), verifies persisted rows in SQLite, and resets the simulator
keychain afterwards:

```sh
server/run_simulator_integration.sh "iPhone 17 Pro"
```

## Privacy notes

- Operational logs contain method, path, status, duration, and byte counts —
  never tokens, headers, or record contents.
- Error responses never echo the request payload or credentials.
- Do not deploy this receiver with real health data on a host you do not
  control, and do not commit databases, tokens, or certificates to the
  repository.
