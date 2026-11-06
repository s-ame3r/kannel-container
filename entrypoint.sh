#!/bin/bash
set -e

CONF=/etc/kannel/kannel.conf
FAKESMSC_BIN="/usr/lib/kannel/test/fakesmsc"
FAKESMSC_PORTS="10000 10001 10002 10003 10004"

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

# Start one fakesmsc instance per port.
# -m 0        : send zero generated messages (connection-only, no traffic)
# </dev/null  : prevent interactive mode (fakesmsc reads stdin otherwise)
start_fakesmsc() {
    for port in $FAKESMSC_PORTS; do
        echo "[entrypoint] Starting fakesmsc -> localhost:$port"
        "$FAKESMSC_BIN" -H localhost -r "$port" -m 0 "000 111 text nop" </dev/null &
        eval "FS_PID_${port}=$!"
        echo "[entrypoint] fakesmsc:$port started (PID $!)"
    done
    sleep 1
    for port in $FAKESMSC_PORTS; do
        pid=$(eval "echo \$FS_PID_${port}")
        if kill -0 "$pid" 2>/dev/null; then
            echo "[entrypoint] fakesmsc:$port is running OK"
        else
            echo "[entrypoint] ERROR: fakesmsc:$port exited immediately"
        fi
    done
}   done
}

# ------------------------------------------------------------------
# 1. Start bearerbox — listens on ports 10000-10004 for fakesmsc
# ------------------------------------------------------------------
echo "[entrypoint] Starting bearerbox"
bearerbox "$CONF" </dev/null &
BB_PID=$!
echo "[entrypoint] bearerbox started (PID $BB_PID)"

# Wait for bearerbox to open all fake SMSC ports and the smsbox port
for port in $FAKESMSC_PORTS; do
    wait_for_port $port 30
done
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
# 3. Start one fakesmsc per port
# ------------------------------------------------------------------
start_fakesmsc

# ------------------------------------------------------------------
# 4. Cleanup handler
# ------------------------------------------------------------------
cleanup() {
    echo "[entrypoint] Shutting down..."
    for port in $FAKESMSC_PORTS; do
        pid=$(eval "echo \$FS_PID_${port}")
        kill -TERM "$pid" 2>/dev/null || true
    done
    kill -TERM "$SB_PID" "$BB_PID" 2>/dev/null || true
    wait "$BB_PID" 2>/dev/null || true
    echo "[entrypoint] Done."
}

trap cleanup SIGTERM SIGINT

# ------------------------------------------------------------------
# 5. Monitor loop — restart dead fakesmsc instances;
#    exit container if bearerbox or smsbox die
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
    for port in $FAKESMSC_PORTS; do
        pid=$(eval "echo \$FS_PID_${port}")
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "[entrypoint] fakesmsc:$port exited, restarting..."
            "$FAKESMSC_BIN" -H localhost -r "$port" -m 0 "000 111 text nop" </dev/null &
            eval "FS_PID_${port}=$!"
            echo "[entrypoint] fakesmsc:$port restarted (PID $!)"
        fi
    done
    sleep 3
done
