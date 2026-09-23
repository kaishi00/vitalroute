#!/bin/bash
# Live receiver integration on ios-mac.
# - trusts the mkcert root CA inside the iPhone 17 Pro simulator (simulator
#   trust store only; production TLS validation is untouched),
# - starts the reference receiver with direct TLS on loopback,
# - runs the full XCTest suite with the integration env vars set,
# - verifies persisted rows in SQLite,
# - cleans up.
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH

UDID=$(xcrun simctl list devices | grep "iPhone 17 Pro (" | grep -oE "[0-9A-F-]{36}" | head -1)
echo "UDID=$UDID"

CAROOT=$(mkcert -CAROOT)
INTDIR=~/tmp/vitalroute-integration
cd "$INTDIR"

echo "--- Adding mkcert root CA to the simulator trust store ---"
xcrun simctl keychain "$UDID" add-root-cert "$CAROOT/rootCA.pem"
echo "root CA added"

TOKEN="integration-token-$(openssl rand -hex 12)"
DB="$INTDIR/records.sqlite3"
rm -f "$DB" "$DB-wal" "$DB-shm" receiver-integration.log

echo "--- Starting TLS receiver on 127.0.0.1:8787 ---"
cd ~/projects/vitalroute/server
VITALROUTE_TOKEN="$TOKEN" VITALROUTE_DB="$DB" \
  python3 receiver.py --host 127.0.0.1 --port 8787 \
  --tls-cert "$INTDIR/cert.pem" --tls-key "$INTDIR/key.pem" \
  > "$INTDIR/receiver-integration.log" 2>&1 &
RECEIVER_PID=$!
cd "$INTDIR"

cleanup() {
  kill "$RECEIVER_PID" 2>/dev/null || true
  wait "$RECEIVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

for i in $(seq 1 20); do
  if nc -z 127.0.0.1 8787 2>/dev/null; then break; fi
  sleep 0.5
done
echo "receiver up (pid $RECEIVER_PID)"

echo "--- Running XCTest with integration env ---"
cd ~/projects/vitalroute
# TEST_RUNNER_-prefixed variables are propagated into the simulator test process.
TEST_RUNNER_VITALROUTE_INTEGRATION_URL="https://localhost:8787/v1/records" \
TEST_RUNNER_VITALROUTE_INTEGRATION_TOKEN="$TOKEN" \
xcodebuild -project VitalRoute.xcodeproj -scheme VitalRoute \
  -destination "platform=iOS Simulator,id=$UDID" \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$INTDIR/xcodebuild-integration.log" | \
  grep -E "Test Suite 'All tests'|Executed [0-9]+ tests|ReceiverIntegrationTests|error:|failed \(" | tail -20

echo "--- Persisted records ---"
sqlite3 "$DB" "SELECT metric, COUNT(*) FROM records GROUP BY metric ORDER BY metric;"
sqlite3 "$DB" "SELECT COUNT(*) FROM records;"

echo "--- Receiver log ---"
cat "$INTDIR/receiver-integration.log"

echo "INTEGRATION_DONE"
