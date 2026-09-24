#!/usr/bin/env bash
# VitalRoute receiver — consistent SQLite backup.
#
# Uses Python's sqlite3 online-backup API against the live database inside
# the data volume, so the receiver keeps serving while the backup runs and
# the resulting file is transactionally consistent (records AND tombstones).
#
# Usage: sudo ./backup.sh [output-directory]
#   VITALROUTE_DATA_DIR / VITALROUTE_PROJECT_NAME override like install.sh.
# Output: <output-directory>/records-<UTC timestamp>.sqlite3 (mode 0600,
# root-owned — backups contain health records; keep them protected).
set -euo pipefail

VITALROUTE_DATA_DIR="${VITALROUTE_DATA_DIR:-/srv/vitalroute}"
VITALROUTE_PROJECT_NAME="${VITALROUTE_PROJECT_NAME:-vitalroute}"
DEST="${1:-$VITALROUTE_DATA_DIR/backups}"

fail() {
  echo "error: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run as root (needs Docker and the backups directory)"
command -v docker >/dev/null 2>&1 || fail "docker is required but not installed"

VOLUME="${VITALROUTE_PROJECT_NAME}_vitalroute-data"
docker volume inspect "$VOLUME" >/dev/null 2>&1 ||
  fail "data volume $VOLUME does not exist — is the receiver installed (project name '$VITALROUTE_PROJECT_NAME')?"
docker image inspect vitalroute-receiver:local >/dev/null 2>&1 ||
  fail "image vitalroute-receiver:local not found — run install.sh first"

# Guard: sqlite3.connect() has create semantics — against an empty volume it
# would silently write a root-owned database the receiver (UID 64000) then
# cannot use. A backup requires an existing database.
docker run --rm --user 0:0 \
  -v "$VOLUME":/data:ro \
  --network none \
  --entrypoint python3 \
  vitalroute-receiver:local \
  -c 'import sys; sys.exit(0 if __import__("os").path.isfile("/data/records.sqlite3") else 1)' ||
  fail "no database found in $VOLUME — start the receiver at least once before backing up"

mkdir -p "$DEST"
chmod 700 "$DEST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"

# Both containers run as root (--user 0:0): the backup directory is
# root-owned 0700, and the volume/database handling may need CAP_CHOWN /
# WAL sidecar access. The image is the same trusted locally-built image the
# receiver itself runs. The source is mounted read-write because SQLite's
# WAL recovery can require creating -shm/-wal sidecars next to the database
# (the backup itself never writes to the source).
docker run --rm --user 0:0 \
  -v "$VOLUME":/data \
  -v "$DEST":/backup \
  --network none \
  -e STAMP="$STAMP" \
  --entrypoint python3 \
  vitalroute-receiver:local \
  -c 'import os, sqlite3
# Plain rw-context open on an rw mount: WAL recovery may need to touch the
# -shm/-wal sidecars. The database itself already exists (guarded above) and
# is never written.
src = sqlite3.connect("/data/records.sqlite3")
tmp = os.path.join("/backup", ".tmp-%s.sqlite3" % os.environ["STAMP"])
dst = sqlite3.connect(tmp)
src.backup(dst)
dst.close()
src.close()
os.chmod(tmp, 0o600)
os.rename(tmp, os.path.join("/backup", "records-%s.sqlite3" % os.environ["STAMP"]))'
OUT="$DEST/records-$STAMP.sqlite3"
[ -f "$OUT" ] || fail "backup did not produce $OUT"

# Integrity + row summary so a restored-from-backup path is verifiable.
# immutable=1: read a possibly-WAL-labelled file without creating sidecars.
docker run --rm --user 0:0 \
  -v "$DEST":/backup:ro \
  --network none \
  -e STAMP="$STAMP" \
  --entrypoint python3 \
  vitalroute-receiver:local \
  -c 'import os, sqlite3
path = os.path.join("/backup", "records-%s.sqlite3" % os.environ["STAMP"])
db = sqlite3.connect("file:%s?immutable=1" % path, uri=True)
assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
print("backup ok: %d records, %d tombstones" % (
    db.execute("SELECT COUNT(*) FROM records").fetchone()[0],
    db.execute("SELECT COUNT(*) FROM deleted_ids").fetchone()[0]))'

echo "backup written: $OUT"
