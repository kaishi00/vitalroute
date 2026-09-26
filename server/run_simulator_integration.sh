#!/bin/bash
# Live simulator-to-receiver integration on a Mac with Xcode.
#
# Runs the full XCTest suite with the ReceiverIntegrationTests enabled
# against a real reference receiver serving TLS on loopback. The receiver's
# certificate must be issued for "localhost" (mkcert works well); the CA is
# added to the SIMULATOR's trust store via `simctl keychain` — a per-simulator
# testing facility — so the app's production TLS validation is untouched.
# Records are synthetic. The simulator keychain is reset afterwards.
#
# Usage (from the repository root on macOS):
#   server/run_simulator_integration.sh [simulator-name]   # default: iPhone 17 Pro
set -euo pipefail

SIM_NAME="${1:-iPhone 17 Pro}"
PORT="${PORT:-8787}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INTDIR="$(mktemp -d "${TMPDIR:-/tmp}/vitalroute-integration.XXXXXX")"
trap 'cleanup' EXIT

cleanup() {
  if [ -n "${RECEIVER_PID:-}" ]; then
    kill "$RECEIVER_PID" 2>/dev/null || true
    wait "$RECEIVER_PID" 2>/dev/null || true
  fi
  if [ -n "${UDID:-}" ]; then
    xcrun simctl keychain "$UDID" reset 2>/dev/null || true
  fi
  rm -rf "$INTDIR"
}

echo "--- Locating simulator: $SIM_NAME ---"
UDID=$(xcrun simctl list devices | grep "$SIM_NAME (" | grep -oE "[0-9A-F-]{36}" | head -1 || true)
[ -n "$UDID" ] || { echo "Simulator not found: $SIM_NAME"; exit 1; }
xcrun simctl bootstatus "$UDID" -b >/dev/null

if ! command -v mkcert >/dev/null; then
  echo "mkcert is required (brew install mkcert)"; exit 1
fi

echo "--- Issuing localhost certificate ---"
CAROOT=$(mkcert -CAROOT)
if [ ! -f "$CAROOT/rootCA.pem" ]; then
  # Never modify the host trust store from a script: ask the developer to
  # run mkcert -install themselves if they want a host-wide local CA. This
  # script only needs an existing CA to issue the leaf certificate.
  echo "No mkcert CA found at $CAROOT."
  echo "Run 'mkcert -install' manually (installs a local CA into the macOS system trust store), then re-run."
  exit 1
fi
cd "$INTDIR"
mkcert -cert-file cert.pem -key-file key.pem localhost 127.0.0.1 ::1 >/dev/null 2>&1

echo "--- Trusting the CA inside the simulator (simulator store only) ---"
xcrun simctl keychain "$UDID" add-root-cert "$CAROOT/rootCA.pem"

TOKEN="integration-token-$(openssl rand -hex 12)"
DB="$INTDIR/records.sqlite3"

echo "--- Starting TLS receiver on 127.0.0.1:$PORT ---"
VITALROUTE_TOKEN="$TOKEN" VITALROUTE_DB="$DB" \
  python3 "$SCRIPT_DIR/receiver.py" --host 127.0.0.1 --port "$PORT" \
  --tls-cert "$INTDIR/cert.pem" --tls-key "$INTDIR/key.pem" \
  > "$INTDIR/receiver.log" 2>&1 &
RECEIVER_PID=$!

for _ in $(seq 1 30); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  sleep 0.5
done

echo "--- Running XCTest with TEST_RUNNER_ integration env ---"
cd "$SCRIPT_DIR/.."
# TEST_RUNNER_-prefixed variables propagate into the simulator test process.
TEST_RUNNER_VITALROUTE_INTEGRATION_URL="https://localhost:$PORT/v1/records" \
TEST_RUNNER_VITALROUTE_INTEGRATION_TOKEN="$TOKEN" \
xcodebuild -project VitalRoute.xcodeproj -scheme VitalRoute \
  -destination "platform=iOS Simulator,id=$UDID" \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$INTDIR/xcodebuild.log" | \
  grep -E "Test Suite 'All tests'|Executed [0-9]+ tests|ReceiverIntegrationTests|error:" | tail -20

echo "--- Persisted records ---"
sqlite3 "$DB" "SELECT metric, COUNT(*) FROM records GROUP BY metric ORDER BY metric;"
sqlite3 "$DB" "SELECT COUNT(*) AS total FROM records;"
echo "--- Tombstones (deletion propagation) ---"
sqlite3 "$DB" "SELECT COUNT(*) AS tombstones FROM deleted_ids;"
sqlite3 "$DB" "SELECT metric, COUNT(*) FROM deleted_ids GROUP BY metric ORDER BY metric;"
# The lifecycle test deletes one sample and then replays an older addition
# for the same id: exactly one tombstone must exist and no row for it.
DELETED_ID=$(sqlite3 "$DB" "SELECT id FROM deleted_ids LIMIT 1;")
if [ -n "$DELETED_ID" ]; then
  RESURRECTED=$(sqlite3 "$DB" "SELECT COUNT(*) FROM records WHERE id = '$DELETED_ID';")
  if [ "$RESURRECTED" = "0" ]; then
    echo "tombstone held: no resurrection for $DELETED_ID"
  else
    echo "RESURRECTION DETECTED for $DELETED_ID" && exit 1
  fi
fi

echo "--- Receiver log ---"
cat "$INTDIR/receiver.log"
echo "INTEGRATION_DONE"
