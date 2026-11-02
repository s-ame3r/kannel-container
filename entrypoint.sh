#!/bin/bash
set -e

CONF=/etc/kannel/kannel.conf

# ------------------------------------------------------------------
# 1. Start bearerbox
# ------------------------------------------------------------------
bearerbox -v 2 "$CONF" &
BB_PID=$!
echo "[entrypoint] bearerbox started (PID $BB_PID)"

# Give bearerbox time to open its smsbox port and fake SMSC ports
sleep 3

# ------------------------------------------------------------------
# 2. Start smsbox
# ------------------------------------------------------------------
smsbox -v 2 "$CONF" &
SB_PID=$!
echo "[entrypoint] smsbox started (PID $SB_PID)"

sleep 2

# ------------------------------------------------------------------
# 3. Start fakesmsc instances (one per port, stay alive with -m -1)
# ------------------------------------------------------------------
START_FAKESMSC="${START_FAKESMSC:-true}"
FAKESMSC_PORTS="${FAKESMSC_PORTS:-10000 10001 10002 10003 10004}"
FAKESMSC_HOST="${FAKESMSC_HOST:-localhost}"
FAKESMSC_BIN="$(command -v fakesmsc 2>/dev/null || echo '/usr/lib/kannel/test/fakesmsc')"
FS_PIDS=()

if [ "$START_FAKESMSC" = "true" ] && [ -x "$FAKESMSC_BIN" ]; then
    for port in $FAKESMSC_PORTS; do
        echo "[entrypoint] Starting fakesmsc -> $FAKESMSC_HOST:$port"
        # -m -1 = run indefinitely (never exit after N messages)
        "$FAKESMSC_BIN" -v 0 -H "$FAKESMSC_HOST" -r "$port" -m -1 &
        FS_PIDS+=($!)
    done
elif [ "$START_FAKESMSC" = "true" ]; then
    echo "[entrypoint] WARNING: fakesmsc not found at $FAKESMSC_BIN, skipping"
fi

# ------------------------------------------------------------------
# 4. Cleanup handler
# ------------------------------------------------------------------
cleanup() {
    echo "[entrypoint] Caught signal, shutting down..."
    kill -TERM "$BB_PID" "$SB_PID" 2>/dev/null || true
    if [ ${#FS_PIDS[@]} -gt 0 ]; then
        kill -TERM "${FS_PIDS[@]}" 2>/dev/null || true
    fi
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
    sleep 2
done
