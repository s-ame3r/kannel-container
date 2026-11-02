#!/bin/bash
set -e

CONF=/etc/kannel/kannel.conf
FAKESMSC_BIN="/usr/lib/kannel/test/fakesmsc"

# ------------------------------------------------------------------
# Wait for a TCP port to accept connections (bash built-in /dev/tcp)
# Usage: wait_for_port <port> <max_seconds>
# Returns 0 on success, 1 on timeout (does NOT exit the script)
# ------------------------------------------------------------------
wait_for_port() {
    local port=$1
    local max=$2
    local i=0
    echo "[entrypoint] Waiting for port $port (up to ${max}s)..."
    while [ $i -lt $max ]; do
        if (echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null; then
            echo "[entrypoint] Port $port is ready (${i}s elapsed)"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    echo "[entrypoint] WARNING: port $port not ready after ${max}s, continuing anyway"
    return 0
}

# ------------------------------------------------------------------
# 1. Start fakesmsc FIRST
#    - no args = listens on port 10000
#    - -m -1   = never exit (handle unlimited messages)
#    bearerbox (smsc=fake) connects TO fakesmsc as a client
# ------------------------------------------------------------------
echo "[entrypoint] Starting fakesmsc (listening on port 10000)"
"$FAKESMSC_BIN" -m -1 &
FS_PID=$!
echo "[entrypoint] fakesmsc started (PID $FS_PID)"

# Give fakesmsc time to open its listener before bearerbox connects
wait_for_port 10000 15

# ------------------------------------------------------------------
# 2. Start bearerbox — reads config and connects to fakesmsc:10000
# ------------------------------------------------------------------
echo "[entrypoint] Starting bearerbox"
bearerbox "$CONF" &
BB_PID=$!
echo "[entrypoint] bearerbox started (PID $BB_PID)"

# Wait for bearerbox to open admin port (12000) and smsbox port (12001)
wait_for_port 12000 30
wait_for_port 12001 30

# ------------------------------------------------------------------
# 3. Start smsbox — connects to bearerbox on port 12001
# ------------------------------------------------------------------
echo "[entrypoint] Starting smsbox"
smsbox "$CONF" &
SB_PID=$!
echo "[entrypoint] smsbox started (PID $SB_PID)"

# ------------------------------------------------------------------
# 4. Cleanup handler
# ------------------------------------------------------------------
cleanup() {
    echo "[entrypoint] Shutting down..."
    kill -TERM "$SB_PID" "$BB_PID" "$FS_PID" 2>/dev/null || true
    wait "$BB_PID" 2>/dev/null || true
    echo "[entrypoint] Done."
}

trap cleanup SIGTERM SIGINT

# ------------------------------------------------------------------
# 5. Monitor loop — restart fakesmsc if it dies;
#    exit the container if bearerbox or smsbox die
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
    if ! kill -0 "$FS_PID" 2>/dev/null; then
        echo "[entrypoint] fakesmsc died, restarting..."
        "$FAKESMSC_BIN" -m -1 &
        FS_PID=$!
        echo "[entrypoint] fakesmsc restarted (PID $FS_PID)"
    fi
    sleep 3
done
