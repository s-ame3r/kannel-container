#!/bin/bash
set -e

CONF=/etc/kannel/kannel.conf
FAKESMSC_BIN="/usr/lib/kannel/test/fakesmsc"

# ------------------------------------------------------------------
# Wait for a TCP port to accept connections (bash built-in /dev/tcp)
# Never exits with failure — only prints a warning on timeout.
# ------------------------------------------------------------------
wait_for_port() {
    local port=$1
    local max=$2
    local i=0
    echo "[entrypoint] Waiting for port $port (up to ${max}s)..."
    while [ $i -lt $max ]; do
        if (echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null; then
            echo "[entrypoint] Port $port ready after ${i}s"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    echo "[entrypoint] WARNING: port $port not ready after ${max}s, continuing anyway"
}

start_fakesmsc() {
    # -m -1  = unlimited messages (run forever)
    # -i 1   = 1 second interval between generated MO messages
    # -H/-r  = connect to bearerbox's fake SMSC listener (bearerbox is server)
    # msg arg is required or fakesmsc panics and exits immediately
    echo "[entrypoint] Starting fakesmsc -> localhost:10000"
    "$FAKESMSC_BIN"  -r 10000 &
    FS_PID=$!
    echo "[entrypoint] fakesmsc started (PID $FS_PID)"
}

# ------------------------------------------------------------------
# 1. Start bearerbox — listens on port 10000 (fake SMSC server)
#    and port 12001 (smsbox connections)
# ------------------------------------------------------------------
echo "[entrypoint] Starting bearerbox"
bearerbox "$CONF" &
BB_PID=$!
echo "[entrypoint] bearerbox started (PID $BB_PID)"

# Wait for bearerbox to open both its ports before proceeding
wait_for_port 10000 30
wait_for_port 12001 30

# ------------------------------------------------------------------
# 2. Start smsbox — connects to bearerbox on port 12001
# ------------------------------------------------------------------
echo "[entrypoint] Starting smsbox"
smsbox "$CONF" &
SB_PID=$!
echo "[entrypoint] smsbox started (PID $SB_PID)"

sleep 2

# ------------------------------------------------------------------
# 3. Start fakesmsc — connects to bearerbox on port 10000
# ------------------------------------------------------------------
start_fakesmsc

# ------------------------------------------------------------------
# 4. Cleanup handler
# ------------------------------------------------------------------
cleanup() {
    echo "[entrypoint] Shutting down..."
    kill -TERM "$FS_PID" "$SB_PID" "$BB_PID" 2>/dev/null || true
    wait "$BB_PID" 2>/dev/null || true
    echo "[entrypoint] Done."
}

trap cleanup SIGTERM SIGINT

# ------------------------------------------------------------------
# 5. Monitor loop — restart fakesmsc if it exits;
#    exit container if bearerbox or smsbox die
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
        echo "[entrypoint] fakesmsc exited, restarting..."
        start_fakesmsc
    fi
    sleep 3
done
