#!/usr/bin/env bash
# VitalRoute receiver — repeatable installation.
#
# Installs the receiver as a Docker Compose service:
#   - code checkout at   $VITALROUTE_INSTALL_DIR (default /opt/vitalroute)
#   - token + backups in $VITALROUTE_DATA_DIR    (default /srv/vitalroute)
#   - backend published on host loopback only    (default 127.0.0.1:8790)
#
# Rerunning this script is safe: the token, the SQLite data volume, and the
# data directory are never recreated, and the stack is rebuilt in place.
# Upgrade = rerun with VITALROUTE_REV=<new commit> (works both from a
# checkout and standalone; an explicit REV always wins).
#
# Environment overrides:
#   VITALROUTE_REPO          git source (default: public GitHub repository)
#   VITALROUTE_REV           commit to deploy; REQUIRED when the script runs
#                            outside a repository checkout
#   VITALROUTE_INSTALL_DIR   code checkout location
#   VITALROUTE_DATA_DIR      token + backups location
#   VITALROUTE_HOST_PORT     host loopback port (default 8790)
#   VITALROUTE_PROJECT_NAME  compose project name (default: vitalroute; use a
#                            different name for an isolated verify stack)
#
# Run as root. HTTPS exposure (Tailscale Serve or a reverse proxy) is
# configured separately — see server/DEPLOYMENT.md.
set -euo pipefail

VITALROUTE_REPO="${VITALROUTE_REPO:-https://github.com/kaishi00/vitalroute.git}"
VITALROUTE_REV="${VITALROUTE_REV:-}"
VITALROUTE_INSTALL_DIR="${VITALROUTE_INSTALL_DIR:-/opt/vitalroute}"
VITALROUTE_DATA_DIR="${VITALROUTE_DATA_DIR:-/srv/vitalroute}"
VITALROUTE_HOST_PORT="${VITALROUTE_HOST_PORT:-8790}"
VITALROUTE_PROJECT_NAME="${VITALROUTE_PROJECT_NAME:-vitalroute}"
CONTAINER_UID=64000

fail() {
  echo "error: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run as root — the installer creates the data directory and Docker resources"

for cmd in docker git python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' is required but not installed"
done
docker compose version >/dev/null 2>&1 ||
  fail "'docker compose' (v2) is required but not available; install the docker-compose-plugin package"
case "$VITALROUTE_HOST_PORT" in
  '' | *[!0-9]*) fail "VITALROUTE_HOST_PORT must be an integer (got: '$VITALROUTE_HOST_PORT')" ;;
esac
[ "$VITALROUTE_HOST_PORT" -ge 1 ] && [ "$VITALROUTE_HOST_PORT" -le 65535 ] ||
  fail "VITALROUTE_HOST_PORT must be in 1-65535 (got: '$VITALROUTE_HOST_PORT')"

# ---- source tree: this checkout, or a clone at a pinned revision -----------

checkout_rev() {
  git -C "$1" fetch origin --quiet ||
    fail "could not fetch origin in $1 (check network access to $VITALROUTE_REPO)"
  git -C "$1" checkout --quiet "$VITALROUTE_REV" ||
    fail "revision $VITALROUTE_REV not found in $1 after fetching — unknown commit, unpushed branch, or local changes blocking checkout"
}

# When piped from stdin (curl | bash), BASH_SOURCE is unset: there is no
# local checkout to prefer. Deriving SCRIPT_DIR from $0 in that mode would
# silently pick up the caller's working directory instead.
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
else
  SCRIPT_DIR=""
fi
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/../receiver.py" ]; then
  # The script lives at <repo>/server/deploy/install.sh: the source tree is
  # the repository root, two levels up from the script directory.
  SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # An explicit revision always wins, even from a checkout — this is the
  # documented upgrade path (install.sh at the old revision deploying a new
  # one). Without REV, deploy the code the operator is looking at.
  if [ -n "$VITALROUTE_REV" ]; then
    if git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
      checkout_rev "$SRC"
    else
      fail "VITALROUTE_REV was given but $SRC is not a git checkout — cannot deploy $VITALROUTE_REV"
    fi
  fi
  echo "Installing from local checkout $SRC"
else
  [ -n "$VITALROUTE_REV" ] ||
    fail "VITALROUTE_REV must name the commit to deploy (or run the script from inside a repository checkout)"
  if git -C "$VITALROUTE_INSTALL_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Updating existing checkout $VITALROUTE_INSTALL_DIR"
    checkout_rev "$VITALROUTE_INSTALL_DIR"
  else
    mkdir -p "$(dirname "$VITALROUTE_INSTALL_DIR")"
    git clone --quiet "$VITALROUTE_REPO" "$VITALROUTE_INSTALL_DIR" ||
      fail "could not clone $VITALROUTE_REPO"
    git -C "$VITALROUTE_INSTALL_DIR" checkout --quiet "$VITALROUTE_REV" ||
      fail "revision $VITALROUTE_REV not found in the fresh clone"
  fi
  SRC="$VITALROUTE_INSTALL_DIR"
fi
REV="$(git -C "$SRC" rev-parse HEAD)"
COMPOSE_FILE="$SRC/server/deploy/docker-compose.yml"
[ -f "$COMPOSE_FILE" ] || fail "docker-compose.yml missing at $COMPOSE_FILE — wrong revision?"
echo "Deploying revision $REV"

# ---- data directory and token ----------------------------------------------

mkdir -p "$VITALROUTE_DATA_DIR"
chmod 700 "$VITALROUTE_DATA_DIR"
TOKEN_FILE="$VITALROUTE_DATA_DIR/token"
# Compose file-secrets are bind mounts: ownership is not remapped, so the
# token must be owned by the container UID (64000) for the receiver to read
# it. Mode 0400 keeps every other account (including non-root humans) out;
# root can still read it with sudo for configuration.
regenerate=0
if [ -f "$TOKEN_FILE" ]; then
  printable="$(tr -d '[:space:]' <"$TOKEN_FILE" | wc -c | tr -d ' ')"
  if [ "${printable:-0}" -lt 16 ]; then
    echo "existing token at $TOKEN_FILE is too short or blank — regenerating"
    regenerate=1
  fi
else
  regenerate=1
fi
if [ "$regenerate" -eq 1 ]; then
  # No default credentials ever: generate a strong token only when none
  # exists. Never printed, never logged, never committed.
  (umask 377 && python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")' >"$TOKEN_FILE")
  echo "Generated a new receiver token at $TOKEN_FILE"
else
  echo "Existing token preserved at $TOKEN_FILE"
fi
chown "$CONTAINER_UID:$CONTAINER_UID" "$TOKEN_FILE"
chmod 400 "$TOKEN_FILE"

# ---- build and start --------------------------------------------------------

compose() {
  VITALROUTE_HOST_PORT="$VITALROUTE_HOST_PORT" \
    VITALROUTE_TOKEN_FILE="$TOKEN_FILE" \
    docker compose -p "$VITALROUTE_PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

compose up -d --build

# ---- wait for the health check ---------------------------------------------

CONTAINER="$(compose ps -q receiver 2>/dev/null || true)"
[ -n "$CONTAINER" ] || fail "receiver container did not start; see: docker compose -p $VITALROUTE_PROJECT_NAME logs receiver"
echo "Waiting for the receiver health check..."
status=""
for _ in $(seq 1 45); do
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$CONTAINER" 2>/dev/null || echo starting)"
  if [ "$status" = "healthy" ]; then
    break
  fi
  [ "$status" = "unhealthy" ] && break
  sleep 2
done
if [ "$status" != "healthy" ]; then
  echo "receiver did not become healthy (status: ${status:-unknown})" >&2
  echo "inspect with: docker compose -p $VITALROUTE_PROJECT_NAME logs receiver" >&2
  exit 1
fi

printf '%s\n' "$REV" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$VITALROUTE_DATA_DIR/.installed-revision"
chmod 600 "$VITALROUTE_DATA_DIR/.installed-revision"

BACKEND="http://127.0.0.1:$VITALROUTE_HOST_PORT/v1/records"
echo
echo "VitalRoute receiver installed and healthy."
echo "  revision: $REV (recorded in $VITALROUTE_DATA_DIR/.installed-revision)"
echo "  backend:  $BACKEND  (host loopback only)"
echo "  token:    $TOKEN_FILE"
echo "             retrieve with: sudo cat $TOKEN_FILE"
echo "  data:     named volume ${VITALROUTE_PROJECT_NAME}_vitalroute-data (/var/lib/vitalroute inside the container)"
echo
echo "Next: expose the backend over HTTPS — see server/DEPLOYMENT.md."
echo "The iOS destination URL must end in /v1/records and use HTTPS."
