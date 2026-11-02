#!/bin/bash
set -e

CONF=/etc/kannel/kannel.conf
FAKESMSC_BIN="/usr/lib/kannel/test/fakesmsc"

# ------------------------------------------------------------------
# 1. Start bearerbox
# ------------------------------------------------------------------
bearerbox -v 2 "$CONF" &
BB_PID=$!
echo "[entrypoint] bearerbox started (PID $BB_PID)"

# Wait until bearerbox is actually listening on the fake SMSC port (10000)
echo "[entrypoint] Waiting for bearerbox to open port 10000..."
for i in $(seq 1 30); do
    if ss -ltn 2>/dev/null | grep -q ':10000 ' || \
       cat /proc/net/tcp6 2>/dev/null | awk '{print $2}' | grep -qi "$(printf '%04X' 10000)$" || \
       cat /proc/net/tcp 2>/dev/null | awk '{print $2}' | grep -qi "$(printf '%04X' 10000)$"; then
        echo "[entrypoint] Port 10000 is open (attempt $i)"
        break
    fi
    sleep 1
done

# ------------------------------------------------------------------
# 2. Start smsbox
# ------------------------------------------------------------------
smsbox -v 2 "$CONF" &
SB_PID=$!
echo "[entrypoint] smsbox started (PID $SB_PID)"

sleep 2

# ------------------------------------------------------------------
# 3. Start fakesmsc (connects to bearerbox on port 10000)
# ------------------------------------------------------------------
echo "[entrypoint] Starting fakesmsc -> localhost:10000"
"$FAKESMSC_BIN" -r 10000 &
FS_PID=$!
echo "[entrypoint] fakesmsc started (PID $FS_PID)"

# ------------------------------------------------------------------
# 4. Cleanup handler
# ------------------------------------------------------------------
cleanup() {
    echo "[entrypoint] Caught signal, shutting down..."
    kill -TERM "$FS_PID" "$SB_PID" "$BB_PID" 2>/dev/null || true
    wait "$BB_PID" "$SB_PID" 2>/dev/null || true
    echo "[entrypoint] Done."
}

trap cleanup SIGTERM SIGINT

# ------------------------------------------------------------------
# 5. Monitor: exit if bearerbox or smsbox dies
# ------------------------------------------------------------------
while true; do
    if ! kill -0 "$BB_PID" 2>/dev/null; then
        echo "[entrypoint] bearerbox (PID $BB_PID) exited unexpectedly!"
        cleanup
        exit 1
    fi
    if ! kill -0 "$SB_PID" 2>/dev/null; then
        echo "[entrypoint] smsbox (PID $SB_PID) exited unexpectedly!"
        cleanup
        exit 1
    fi
    # Restart fakesmsc if it dies
    if ! kill -0 "$FS_PID" 2>/dev/null; then
        echo "[entrypoint] fakesmsc died, restarting..."
        "$FAKESMSC_BIN" -r 10000 &
        FS_PID=$!
        echo "[entrypoint] fakesmsc restarted (PID $FS_PID)"
    fi
    sleep 2
done
