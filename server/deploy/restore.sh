#!/usr/bin/env bash
# VitalRoute receiver — restore a SQLite backup over the live database.
#
# Usage: sudo ./restore.sh /path/to/records-<timestamp>.sqlite3
#
# Verifies the backup, stops the receiver, replaces the database inside the
# data volume (stale WAL/SHM sidecars removed first), starts the receiver
# again, and verifies health plus the restored row counts. The backup file
# is not modified. If any step fails, the receiver is restarted on the
# database currently present in the volume.
#
#   VITALROUTE_DATA_DIR / VITALROUTE_PROJECT_NAME / VITALROUTE_HOST_PORT
#   override like install.sh.
set -euo pipefail

VITALROUTE_DATA_DIR="${VITALROUTE_DATA_DIR:-/srv/vitalroute}"
VITALROUTE_PROJECT_NAME="${VITALROUTE_PROJECT_NAME:-vitalroute}"
VITALROUTE_HOST_PORT="${VITALROUTE_HOST_PORT:-8790}"
CONTAINER_UID=64000

fail() {
  echo "error: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run as root"
command -v docker >/dev/null 2>&1 || fail "docker is required but not installed"

BACKUP="${1:-}"
[ -n "$BACKUP" ] || fail "usage: $0 /path/to/records-<timestamp>.sqlite3"
[ -f "$BACKUP" ] || fail "backup file not found: $BACKUP"
# The name is used inside SQLite URI strings and shell paths; keep it to a
# strict whitelist so '?', '#', quotes, and whitespace cannot smuggle
# semantics.
case "$(basename "$BACKUP")" in
  '' | *[!A-Za-z0-9._-]*) fail "backup filename must contain only letters, digits, dot, underscore, or dash" ;;
esac

VOLUME="${VITALROUTE_PROJECT_NAME}_vitalroute-data"
docker volume inspect "$VOLUME" >/dev/null 2>&1 ||
  fail "data volume $VOLUME does not exist — is the receiver installed?"
docker image inspect vitalroute-receiver:local >/dev/null 2>&1 ||
  fail "image vitalroute-receiver:local not found — run install.sh first"

# Locate the compose file the running (or stopped) stack was created with,
# so restore works regardless of where the checkout lives. sed (not head)
# drains the pipe: with pipefail, head -1 could take docker down with
# SIGPIPE on a large listing.
CONTAINER="$(docker ps -aq --filter "label=com.docker.compose.project=$VITALROUTE_PROJECT_NAME" \
  --filter "label=com.docker.compose.service=receiver" | sed -n 1p)"
[ -n "$CONTAINER" ] || fail "no receiver container found for project '$VITALROUTE_PROJECT_NAME'"
COMPOSE_FILE="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$CONTAINER" | cut -d, -f1)"
[ -n "$COMPOSE_FILE" ] && [ -f "$COMPOSE_FILE" ] ||
  fail "could not determine the stack's docker-compose.yml (label pointed at '$COMPOSE_FILE')"

compose() {
  VITALROUTE_HOST_PORT="$VITALROUTE_HOST_PORT" \
    VITALROUTE_TOKEN_FILE="$VITALROUTE_DATA_DIR/token" \
    docker compose -p "$VITALROUTE_PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

BACKUP_DIR="$(cd "$(dirname "$BACKUP")" && pwd)"
BACKUP_NAME="$(basename "$BACKUP")"

echo "Verifying backup integrity..."
VERIFY='import os, sqlite3
db = sqlite3.connect("file:%s?immutable=1" % os.path.join("/backup", os.environ["BACKUP_NAME"]), uri=True)
assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
print("backup ok: %d records, %d tombstones" % (
    db.execute("SELECT COUNT(*) FROM records").fetchone()[0],
    db.execute("SELECT COUNT(*) FROM deleted_ids").fetchone()[0]))'
docker run --rm --user 0:0 \
  --network none \
  -v "$BACKUP_DIR":/backup:ro \
  -e BACKUP_NAME="$BACKUP_NAME" \
  --entrypoint python3 \
  vitalroute-receiver:local \
  -c "$VERIFY"

echo "Stopping the receiver..."
compose stop receiver
# Recovery net for ANY failure after this point (including fail() — exit
# inside a function does not fire the ERR trap): an EXIT trap with a
# sentinel restarts the receiver on whatever database is in the volume,
# which after the swap is the restored one and before it the old one.
restore_ok=0
on_exit() {
  if [ "$restore_ok" -ne 1 ]; then
    echo "restore failed — restarting the receiver on the database now in the volume" >&2
    compose up -d || true
  fi
}
trap on_exit EXIT

echo "Replacing the database in volume $VOLUME..."
# Stale sidecars are removed BEFORE the swap: a crash between the replace
# and a post-hoc removal would otherwise leave the restored database next
# to the previous database's -wal, which SQLite would try to apply to it.
REPLACE='import os, shutil, sqlite3
target = "/data/records.sqlite3"
for sidecar in ("-wal", "-shm"):
    try:
        os.remove(target + sidecar)
    except FileNotFoundError:
        pass
# Copy under a temp name first so a crash cannot leave a truncated database.
shutil.copyfile(os.path.join("/backup", os.environ["BACKUP_NAME"]), "/data/.restore.sqlite3")
os.chown("/data/.restore.sqlite3", int(os.environ["CONTAINER_UID"]), int(os.environ["CONTAINER_UID"]))
os.replace("/data/.restore.sqlite3", target)
db = sqlite3.connect("file:%s?immutable=1" % target, uri=True)
assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
print("restored: %d records, %d tombstones" % (
    db.execute("SELECT COUNT(*) FROM records").fetchone()[0],
    db.execute("SELECT COUNT(*) FROM deleted_ids").fetchone()[0]))'
docker run --rm --user 0:0 \
  --network none \
  -v "$VOLUME":/data \
  -v "$BACKUP_DIR":/backup:ro \
  -e BACKUP_NAME="$BACKUP_NAME" \
  -e CONTAINER_UID="$CONTAINER_UID" \
  --entrypoint python3 \
  vitalroute-receiver:local \
  -c "$REPLACE"

echo "Starting the receiver..."
compose up -d
CONTAINER="$(compose ps -q receiver 2>/dev/null || true)"
[ -n "$CONTAINER" ] || fail "receiver container not found after restore"
echo "Waiting for the receiver health check..."
status=""
for _ in $(seq 1 45); do
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$CONTAINER" 2>/dev/null || echo starting)"
  [ "$status" = "healthy" ] && break
  [ "$status" = "unhealthy" ] && break
  sleep 2
done
[ "$status" = "healthy" ] ||
  fail "receiver is not healthy after restore (status: ${status:-unknown}); check: docker compose -p $VITALROUTE_PROJECT_NAME logs receiver"
restore_ok=1
trap - EXIT
echo "Restore complete; receiver healthy."
