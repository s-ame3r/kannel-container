#!/bin/bash
set -e

CONF=/etc/kannel/kannel.conf
FAKESMSC_BIN="/usr/lib/kannel/test/fakesmsc"

# ------------------------------------------------------------------
# Wait for a TCP port to accept connections (bash built-in /dev/tcp)
# Usage: wait_for_port <port> <max_seconds>
# ------------------------------------------------------------------
wait_for_port() {
    local port=$1
    local max=$2
    local i=0
    echo "[entrypoint] Waiting for port $port..."
    while [ $i -lt $max ]; do
        if (echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null; then
            echo "[entrypoint] Port $port is ready (${i}s elapsed)"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    echo "[entrypoint] ERROR: port $port not ready after ${max}s"
    return 1
}

# ------------------------------------------------------------------
# 1. Start fakesmsc FIRST — it listens on port 10000 and bearerbox
#    connects TO it (smsc = fake means bearerbox is the client)
# ------------------------------------------------------------------
echo "[entrypoint] Starting fakesmsc (listening on port 10000)"
"$FAKESMSC_BIN" &
FS_PID=$!
echo "[entrypoint] fakesmsc started (PID $FS_PID)"

# Wait for fakesmsc to open port 10000 before bearerbox tries to connect
wait_for_port 10000 15

# ------------------------------------------------------------------
# 2. Start bearerbox — connects to fakesmsc on port 10000
# ------------------------------------------------------------------
bearerbox "$CONF" &
BB_PID=$!
echo "[entrypoint] bearerbox started (PID $BB_PID)"

# Wait for bearerbox to open smsbox port before starting smsbox
wait_for_port 12001 30

# ------------------------------------------------------------------
# 3. Start smsbox
# ------------------------------------------------------------------
smsbox "$CONF" &
SB_PID=$!
echo "[entrypoint] smsbox started (PID $SB_PID)"

# ------------------------------------------------------------------
# 4. Cleanup handler
# ------------------------------------------------------------------
cleanup() {
    echo "[entrypoint] Caught signal, shutting down..."
    kill -TERM "$SB_PID" "$BB_PID" "$FS_PID" 2>/dev/null || true
    wait "$BB_PID" 2>/dev/null || true
    echo "[entrypoint] Done."
}

trap cleanup SIGTERM SIGINT

# ------------------------------------------------------------------
# 5. Monitor: restart fakesmsc if it dies; exit if bearerbox/smsbox die
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
        "$FAKESMSC_BIN" &
        FS_PID=$!
        echo "[entrypoint] fakesmsc restarted (PID $FS_PID)"
    fi
    sleep 3
done
