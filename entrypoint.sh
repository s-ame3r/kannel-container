#!/bin/bash
set -e

CONF=/etc/kannel/kannel.conf
FAKESMSC_BIN="/usr/lib/kannel/test/fakesmsc"

# ------------------------------------------------------------------
# Wait for a TCP port to accept connections (bash built-in /dev/tcp)
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
    echo "[entrypoint] Starting fakesmsc -> localhost:10000"
    # Redirect stdin from /dev/null so fakesmsc never enters interactive mode.
    # -m -1  : unlimited messages (run forever)
    # -i 60  : send one MO message every 60s (just a keepalive)
    # last arg is the message: "sender receiver type data"
    "$FAKESMSC_BIN" -H localhost -r 10000 -m 0 "000 111 text nop" </dev/null &
    FS_PID=$!
    echo "[entrypoint] fakesmsc started (PID $FS_PID)"
    sleep 1
    if kill -0 "$FS_PID" 2>/dev/null; then
        echo "[entrypoint] fakesmsc is running OK"
    else
        echo "[entrypoint] ERROR: fakesmsc exited immediately"
    fi
}

# ------------------------------------------------------------------
# 1. Start bearerbox
# ------------------------------------------------------------------
echo "[entrypoint] Starting bearerbox"
bearerbox "$CONF" </dev/null &
BB_PID=$!
echo "[entrypoint] bearerbox started (PID $BB_PID)"

wait_for_port 10000 30
wait_for_port 12001 30

# ------------------------------------------------------------------
# 2. Start smsbox
# ------------------------------------------------------------------
echo "[entrypoint] Starting smsbox"
smsbox "$CONF" </dev/null &
SB_PID=$!
echo "[entrypoint] smsbox started (PID $SB_PID)"

sleep 2

# ------------------------------------------------------------------
# 3. Start fakesmsc
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
# 5. Monitor loop
# ------------------------------------------------------------------
while true; do
    if ! kill -0 "$BB_PID" 2>/dev/null; then
        echo "[entrypoint] bearerbox exited unexpectedly!"
        cleanup
        exit 1
    fi
    if ! kill -0 "$SB_PID" 2>/dev/null; then
        echo "[entrypoint] smsbox exited unexpectedly!"
        cleanup
        exit 1
    fi
    if ! kill -0 "$FS_PID" 2>/dev/null; then
        echo "[entrypoint] fakesmsc exited, restarting..."
        start_fakesmsc
    fi
    sleep 3
done
